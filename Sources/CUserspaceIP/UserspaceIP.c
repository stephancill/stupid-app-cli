#include "CUserspaceIP.h"
#include "lwip/init.h"
#include "lwip/ip6.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_BRIDGES 16
#define BRIDGE_BUFFER 32768
#ifdef __APPLE__
#define SEND_FLAGS 0
#else
#define SEND_FLAGS MSG_NOSIGNAL
#endif

struct bridge {
  struct stupid_app_userspace_ip *stack;
  struct tcp_pcb *pcb;
  int fd;
  int client_fd;
  int connecting;
  uint64_t deadline;
  uint8_t outbound[BRIDGE_BUFFER];
  size_t outbound_length;
  // A pbuf is retained until the local stream accepts it. tcp_recved is
  // deliberately delayed so the device receives real backpressure.
  struct pbuf *inbound;
  size_t inbound_offset;
  bool remote_eof;
};

struct stupid_app_userspace_ip {
  int packet_fd;
  struct netif interface;
  ip_addr_t client;
  ip_addr_t server;
  uint16_t mtu;
  pthread_t worker;
  pthread_mutex_t mutex;
  pthread_mutex_t dial_mutex;
  pthread_cond_t condition;
  atomic_bool stopping;
  bool stopped;
  bool ready;
  int startup_error;
  bool dial_pending;
  bool dial_requested;
  int dial_result;
  uint16_t dial_port;
  int dial_timeout;
  struct bridge bridges[MAX_BRIDGES];
};

// lwIP's NO_SYS raw API has process-global state. The spike admits exactly one
// active stack and runs every lwIP operation and timer on its joined worker.
static pthread_mutex_t ownership_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool owned = false;
static bool initialized = false;

static uint64_t milliseconds(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
u32_t sys_now(void) { return (u32_t)milliseconds(); }
uint32_t stupid_app_lwip_random(void) { return arc4random(); }

static void complete_dial(struct bridge *bridge, int result) {
  if (!bridge->connecting)
    return;
  bridge->connecting = 0;
  pthread_mutex_lock(&bridge->stack->mutex);
  bridge->stack->dial_result = result;
  bridge->stack->dial_pending = false;
  pthread_cond_broadcast(&bridge->stack->condition);
  pthread_mutex_unlock(&bridge->stack->mutex);
}

static void release_bridge(struct bridge *bridge) {
  complete_dial(bridge, -ECONNRESET);
  if (bridge->pcb) {
    tcp_arg(bridge->pcb, NULL);
    tcp_err(bridge->pcb, NULL);
    tcp_abort(bridge->pcb);
    bridge->pcb = NULL;
  }
  if (bridge->inbound)
    pbuf_free(bridge->inbound);
  bridge->inbound = NULL;
  if (bridge->fd >= 0) {
    shutdown(bridge->fd, SHUT_RDWR);
    close(bridge->fd);
  }
  if (bridge->client_fd >= 0)
    close(bridge->client_fd);
  bridge->fd = bridge->client_fd = -1;
  bridge->outbound_length = bridge->inbound_offset = 0;
  bridge->remote_eof = false;
}

static void connection_error(void *argument, err_t error) {
  (void)error;
  struct bridge *bridge = argument;
  // lwIP has already freed the pcb when invoking its error callback.
  bridge->pcb = NULL;
  release_bridge(bridge);
}

static err_t connection_received(void *argument, struct tcp_pcb *pcb,
                                 struct pbuf *buffer, err_t error) {
  (void)pcb;
  (void)error;
  struct bridge *bridge = argument;
  if (!buffer) {
    bridge->remote_eof = true;
    return ERR_OK;
  }
  if (bridge->inbound) {
    if ((size_t)bridge->inbound->tot_len + buffer->tot_len > 65535)
      return ERR_MEM;
    pbuf_cat(bridge->inbound, buffer);
  } else {
    bridge->inbound = buffer;
    bridge->inbound_offset = 0;
  }
  return ERR_OK;
}

static err_t connection_ready(void *argument, struct tcp_pcb *pcb,
                              err_t error) {
  (void)pcb;
  struct bridge *bridge = argument;
  if (error != ERR_OK) {
    complete_dial(bridge, -ECONNREFUSED);
    release_bridge(bridge);
    return ERR_ABRT;
  }
  int descriptor = bridge->client_fd;
  bridge->client_fd = -1;
  complete_dial(bridge, descriptor);
  return ERR_OK;
}

static err_t output_packet(struct netif *interface, struct pbuf *buffer,
                           const ip6_addr_t *destination) {
  (void)destination;
  struct stupid_app_userspace_ip *stack = interface->state;
  uint8_t packet[1500];
  if (buffer->tot_len > sizeof(packet))
    return ERR_IF;
  pbuf_copy_partial(buffer, packet, buffer->tot_len, 0);
  ssize_t sent = send(stack->packet_fd, packet, buffer->tot_len, SEND_FLAGS);
  return sent == buffer->tot_len ? ERR_OK : ERR_IF;
}

static err_t initialize_interface(struct netif *interface) {
  struct stupid_app_userspace_ip *stack = interface->state;
  interface->name[0] = 'u';
  interface->name[1] = 's';
  interface->mtu = stack->mtu;
  // Direct L3 output: no Ethernet shim, neighbor discovery, or host routes.
  interface->output_ip6 = output_packet;
  return ERR_OK;
}

static void begin_dial(struct stupid_app_userspace_ip *stack) {
  struct bridge *bridge = NULL;
  for (int i = 0; i < MAX_BRIDGES; i++) {
    if (stack->bridges[i].fd < 0) {
      bridge = &stack->bridges[i];
      break;
    }
  }
  int pair[2];
  int failure = EMFILE;
  if (bridge && socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0) {
    bridge->fd = pair[0];
    bridge->client_fd = pair[1];
    bridge->stack = stack;
    fcntl(bridge->fd, F_SETFL, O_NONBLOCK);
    fcntl(pair[0], F_SETFD, FD_CLOEXEC);
    fcntl(pair[1], F_SETFD, FD_CLOEXEC);
#ifdef __APPLE__
    int enabled = 1;
    setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    bridge->connecting = 1;
    bridge->deadline = milliseconds() + stack->dial_timeout;
    bridge->pcb = tcp_new_ip_type(IPADDR_TYPE_V6);
    if (bridge->pcb) {
      tcp_arg(bridge->pcb, bridge);
      tcp_err(bridge->pcb, connection_error);
      tcp_recv(bridge->pcb, connection_received);
      tcp_nagle_disable(bridge->pcb);
      tcp_bind_netif(bridge->pcb, &stack->interface);
      err_t result = tcp_bind(bridge->pcb, &stack->client, 0);
      if (result == ERR_OK)
        result = tcp_connect(bridge->pcb, &stack->server, stack->dial_port,
                             connection_ready);
      if (result == ERR_OK)
        return;
    }
    failure = ENOMEM;
    complete_dial(bridge, -failure);
    release_bridge(bridge);
    return;
  }
  pthread_mutex_lock(&stack->mutex);
  stack->dial_result = -failure;
  stack->dial_pending = false;
  pthread_cond_broadcast(&stack->condition);
  pthread_mutex_unlock(&stack->mutex);
}

static void pump_bridge(struct bridge *bridge) {
  if (!bridge->pcb || bridge->connecting)
    return;
  if (bridge->inbound) {
    uint8_t buffer[BRIDGE_BUFFER];
    size_t remaining = bridge->inbound->tot_len - bridge->inbound_offset;
    size_t length = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
    pbuf_copy_partial(bridge->inbound, buffer, (u16_t)length,
                      (u16_t)bridge->inbound_offset);
    ssize_t sent = send(bridge->fd, buffer, length, SEND_FLAGS);
    if (sent > 0) {
      bridge->inbound_offset += sent;
      tcp_recved(bridge->pcb, (u16_t)sent);
      if (bridge->inbound_offset == bridge->inbound->tot_len) {
        pbuf_free(bridge->inbound);
        bridge->inbound = NULL;
      }
    } else if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
               errno != EINTR) {
      release_bridge(bridge);
      return;
    }
  }
  if (bridge->remote_eof && !bridge->inbound)
    shutdown(bridge->fd, SHUT_WR);
  if (!bridge->outbound_length && tcp_sndbuf(bridge->pcb) > 0) {
    ssize_t received =
        recv(bridge->fd, bridge->outbound, sizeof(bridge->outbound), 0);
    if (received > 0)
      bridge->outbound_length = received;
    else if (received == 0 ||
             (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
      release_bridge(bridge);
      return;
    }
  }
  if (bridge->outbound_length) {
    size_t length = tcp_sndbuf(bridge->pcb);
    if (length > bridge->outbound_length)
      length = bridge->outbound_length;
    if (length) {
      err_t result = tcp_write(bridge->pcb, bridge->outbound, (u16_t)length,
                               TCP_WRITE_FLAG_COPY);
      if (result == ERR_OK) {
        memmove(bridge->outbound, bridge->outbound + length,
                bridge->outbound_length - length);
        bridge->outbound_length -= length;
        tcp_output(bridge->pcb);
      } else if (result != ERR_MEM)
        release_bridge(bridge);
    }
  }
}

static void *run_stack(void *argument) {
  struct stupid_app_userspace_ip *stack = argument;
  if (!initialized) {
    lwip_init();
    initialized = true;
  }
  struct netif *interface = netif_add_noaddr(&stack->interface, stack,
                                             initialize_interface, ip6_input);
  if (interface) {
    netif_ip6_addr_set(interface, 0, ip_2_ip6(&stack->client));
    netif_ip6_addr_set_state(interface, 0, IP6_ADDR_PREFERRED);
    netif_set_default(interface);
    netif_set_up(interface);
    netif_set_link_up(interface);
  }
  pthread_mutex_lock(&stack->mutex);
  stack->startup_error = interface ? 0 : ENOMEM;
  stack->ready = true;
  pthread_cond_broadcast(&stack->condition);
  pthread_mutex_unlock(&stack->mutex);
  while (interface && !atomic_load(&stack->stopping)) {
    pthread_mutex_lock(&stack->mutex);
    bool requested = stack->dial_requested;
    stack->dial_requested = false;
    pthread_mutex_unlock(&stack->mutex);
    if (requested)
      begin_dial(stack);
    struct pollfd descriptor = {.fd = stack->packet_fd, .events = POLLIN};
    poll(&descriptor, 1, 2);
    // Bound each drain so packet bursts cannot starve timers or local streams.
    for (int i = 0; i < 128; i++) {
      uint8_t packet[65576];
      ssize_t length = recv(stack->packet_fd, packet, sizeof(packet), 0);
      if (length < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
          atomic_store(&stack->stopping, true);
        break;
      }
      if (length == 0) {
        atomic_store(&stack->stopping, true);
        break;
      }
      if (length < 40 || length > 65535 || packet[0] >> 4 != 6 ||
          length != 40 + ((int)packet[4] << 8) + packet[5])
        continue;
      struct pbuf *buffer = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_RAM);
      if (!buffer)
        continue;
      pbuf_take(buffer, packet, (u16_t)length);
      if (interface->input(buffer, interface) != ERR_OK)
        pbuf_free(buffer);
    }
    sys_check_timeouts();
    for (int i = 0; i < MAX_BRIDGES; i++) {
      struct bridge *bridge = &stack->bridges[i];
      if (bridge->connecting && milliseconds() >= bridge->deadline) {
        complete_dial(bridge, -ETIMEDOUT);
        release_bridge(bridge);
      }
      if (bridge->fd >= 0)
        pump_bridge(bridge);
    }
  }
  for (int i = 0; i < MAX_BRIDGES; i++)
    release_bridge(&stack->bridges[i]);
  if (interface)
    netif_remove(interface);
  pthread_mutex_lock(&stack->mutex);
  if (stack->dial_pending) {
    stack->dial_result = -ECANCELED;
    stack->dial_pending = false;
  }
  pthread_cond_broadcast(&stack->condition);
  pthread_mutex_unlock(&stack->mutex);
  return NULL;
}

int stupid_app_userspace_ip_create(int packet_fd, const char *client_address,
                                   const char *server_address, uint16_t mtu,
                                   stupid_app_userspace_ip **output) {
  if (packet_fd < 0 || !client_address || !server_address || !output ||
      mtu < 1280 || mtu > 1500)
    return EINVAL;
  struct stupid_app_userspace_ip *stack = calloc(1, sizeof(*stack));
  if (!stack)
    return ENOMEM;
  if (!ipaddr_aton(client_address, &stack->client) ||
      !IP_IS_V6(&stack->client) ||
      !ipaddr_aton(server_address, &stack->server) ||
      !IP_IS_V6(&stack->server)) {
    free(stack);
    return EINVAL;
  }
  pthread_mutex_lock(&ownership_mutex);
  if (owned) {
    pthread_mutex_unlock(&ownership_mutex);
    free(stack);
    return EBUSY;
  }
  owned = true;
  pthread_mutex_unlock(&ownership_mutex);
  stack->packet_fd = packet_fd;
  stack->mtu = mtu;
  for (int i = 0; i < MAX_BRIDGES; i++)
    stack->bridges[i].fd = stack->bridges[i].client_fd = -1;
  atomic_init(&stack->stopping, false);
  pthread_mutex_init(&stack->mutex, NULL);
  pthread_mutex_init(&stack->dial_mutex, NULL);
  pthread_cond_init(&stack->condition, NULL);
  fcntl(packet_fd, F_SETFL, O_NONBLOCK);
  fcntl(packet_fd, F_SETFD, FD_CLOEXEC);
  int result = pthread_create(&stack->worker, NULL, run_stack, stack);
  if (!result) {
    pthread_mutex_lock(&stack->mutex);
    while (!stack->ready)
      pthread_cond_wait(&stack->condition, &stack->mutex);
    result = stack->startup_error;
    pthread_mutex_unlock(&stack->mutex);
  }
  if (result) {
    if (stack->ready)
      pthread_join(stack->worker, NULL);
    pthread_mutex_destroy(&stack->mutex);
    pthread_mutex_destroy(&stack->dial_mutex);
    pthread_cond_destroy(&stack->condition);
    free(stack);
    pthread_mutex_lock(&ownership_mutex);
    owned = false;
    pthread_mutex_unlock(&ownership_mutex);
    return result;
  }
  *output = stack;
  return 0;
}

int stupid_app_userspace_ip_connect(stupid_app_userspace_ip *stack,
                                    uint16_t port, int timeout_milliseconds) {
  if (!stack || !port || timeout_milliseconds <= 0)
    return -EINVAL;
  pthread_mutex_lock(&stack->dial_mutex);
  pthread_mutex_lock(&stack->mutex);
  if (atomic_load(&stack->stopping)) {
    pthread_mutex_unlock(&stack->mutex);
    pthread_mutex_unlock(&stack->dial_mutex);
    return -ECANCELED;
  }
  stack->dial_port = port;
  stack->dial_timeout = timeout_milliseconds;
  stack->dial_pending = true;
  stack->dial_requested = true;
  while (stack->dial_pending)
    pthread_cond_wait(&stack->condition, &stack->mutex);
  int result = stack->dial_result;
  pthread_mutex_unlock(&stack->mutex);
  pthread_mutex_unlock(&stack->dial_mutex);
  return result;
}

void stupid_app_userspace_ip_stop(stupid_app_userspace_ip *stack) {
  if (!stack || stack->stopped)
    return;
  atomic_store(&stack->stopping, true);
  pthread_join(stack->worker, NULL);
  stack->stopped = true;
}

void stupid_app_userspace_ip_destroy(stupid_app_userspace_ip *stack) {
  if (!stack)
    return;
  stupid_app_userspace_ip_stop(stack);
  pthread_mutex_lock(&stack->dial_mutex);
  pthread_mutex_unlock(&stack->dial_mutex);
  close(stack->packet_fd);
  pthread_mutex_destroy(&stack->mutex);
  pthread_mutex_destroy(&stack->dial_mutex);
  pthread_cond_destroy(&stack->condition);
  free(stack);
  pthread_mutex_lock(&ownership_mutex);
  owned = false;
  pthread_mutex_unlock(&ownership_mutex);
}
