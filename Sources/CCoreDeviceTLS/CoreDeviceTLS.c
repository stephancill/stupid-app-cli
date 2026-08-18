#include "CCoreDeviceTLS.h"
#include "CTUN.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define POLL_SLICE_MILLISECONDS 50

struct stupid_app_coredevice_tls_connection {
  char *host;
  uint16_t port;
  uint8_t psk[256];
  size_t psk_length;
  int timeout_milliseconds;
  atomic_bool cancelled;
  pthread_mutex_t socket_mutex;
  int socket_fd;
};

static int64_t monotonic_milliseconds(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
    return -1;
  }
  return ((int64_t)time.tv_sec * 1000) + (time.tv_nsec / 1000000);
}

static int cancellation_result(stupid_app_coredevice_tls_connection *connection) {
  return atomic_load(&connection->cancelled) ? STUPID_APP_COREDEVICE_TLS_CANCELLED : 0;
}

static int deadline_result(
  stupid_app_coredevice_tls_connection *connection,
  int64_t deadline
) {
  int cancelled = cancellation_result(connection);
  if (cancelled != 0) {
    return cancelled;
  }
  int64_t now = monotonic_milliseconds();
  return now < 0 || now >= deadline ? STUPID_APP_COREDEVICE_TLS_TIMED_OUT : 0;
}

static void close_socket(stupid_app_coredevice_tls_connection *connection) {
  pthread_mutex_lock(&connection->socket_mutex);
  int socket_fd = connection->socket_fd;
  connection->socket_fd = -1;
  if (socket_fd >= 0) {
    close(socket_fd);
  }
  pthread_mutex_unlock(&connection->socket_mutex);
}

static void set_socket(stupid_app_coredevice_tls_connection *connection, int socket_fd) {
  pthread_mutex_lock(&connection->socket_mutex);
  connection->socket_fd = socket_fd;
  pthread_mutex_unlock(&connection->socket_mutex);
}

static int wait_for_socket(
  stupid_app_coredevice_tls_connection *connection,
  int socket_fd,
  short events,
  int64_t deadline
) {
  while (1) {
    int state = deadline_result(connection, deadline);
    if (state != 0) {
      return state;
    }
    int64_t now = monotonic_milliseconds();
    int remaining = (int)(deadline - now);
    int interval = remaining < POLL_SLICE_MILLISECONDS ? remaining : POLL_SLICE_MILLISECONDS;
    struct pollfd descriptor = {.fd = socket_fd, .events = events};
    int result = poll(&descriptor, 1, interval);
    if (result > 0) {
      return STUPID_APP_COREDEVICE_TLS_OK;
    }
    if (result < 0 && errno != EINTR) {
      return cancellation_result(connection) != 0
        ? STUPID_APP_COREDEVICE_TLS_CANCELLED
        : STUPID_APP_COREDEVICE_TLS_CONNECT_FAILED;
    }
  }
}

static int connect_socket(
  stupid_app_coredevice_tls_connection *connection,
  int64_t deadline,
  int *connected_socket
) {
  char port_string[6];
  snprintf(port_string, sizeof(port_string), "%u", connection->port);
  struct addrinfo hints = {0};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_NUMERICHOST;
  struct addrinfo *addresses = NULL;
  if (getaddrinfo(connection->host, port_string, &hints, &addresses) != 0) {
    return STUPID_APP_COREDEVICE_TLS_RESOLUTION_FAILED;
  }

  int result = STUPID_APP_COREDEVICE_TLS_CONNECT_FAILED;
  for (struct addrinfo *address = addresses; address != NULL; address = address->ai_next) {
    if (cancellation_result(connection) != 0) {
      result = STUPID_APP_COREDEVICE_TLS_CANCELLED;
      break;
    }
    int state = deadline_result(connection, deadline);
    if (state != 0) {
      result = state;
      break;
    }
    int socket_fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (socket_fd < 0) {
      continue;
    }
    set_socket(connection, socket_fd);
    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(socket_fd, F_SETFD, FD_CLOEXEC) < 0) {
      close_socket(connection);
      continue;
    }
#ifdef SO_NOSIGPIPE
    int no_sigpipe = 1;
    if (setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0) {
      close_socket(connection);
      continue;
    }
#endif
    int connect_result = connect(socket_fd, address->ai_addr, address->ai_addrlen);
    if (connect_result < 0 && errno == EINPROGRESS) {
      result = wait_for_socket(connection, socket_fd, POLLOUT, deadline);
      if (result == STUPID_APP_COREDEVICE_TLS_OK) {
        int error = 0;
        socklen_t error_length = sizeof(error);
        if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &error, &error_length) != 0 || error != 0) {
          result = STUPID_APP_COREDEVICE_TLS_CONNECT_FAILED;
        }
      }
    } else if (connect_result == 0) {
      result = STUPID_APP_COREDEVICE_TLS_OK;
    }
    if (result == STUPID_APP_COREDEVICE_TLS_OK) {
      *connected_socket = socket_fd;
      break;
    }
    close_socket(connection);
    if (result == STUPID_APP_COREDEVICE_TLS_CANCELLED ||
        result == STUPID_APP_COREDEVICE_TLS_TIMED_OUT) {
      break;
    }
  }
  freeaddrinfo(addresses);
  return result;
}

static unsigned int provide_psk(
  SSL *ssl,
  const char *hint,
  char *identity,
  unsigned int maximum_identity_length,
  unsigned char *psk,
  unsigned int maximum_psk_length
) {
  (void)hint;
  stupid_app_coredevice_tls_connection *connection = SSL_get_app_data(ssl);
  if (connection == NULL || identity == NULL || maximum_identity_length == 0 ||
      connection->psk_length == 0 || connection->psk_length > maximum_psk_length) {
    return 0;
  }
  identity[0] = '\0';
  memcpy(psk, connection->psk, connection->psk_length);
  return (unsigned int)connection->psk_length;
}

static int wait_for_ssl(
  stupid_app_coredevice_tls_connection *connection,
  SSL *ssl,
  int operation_result,
  int socket_fd,
  int64_t deadline,
  int phase_failure
) {
  int error = SSL_get_error(ssl, operation_result);
  if (error == SSL_ERROR_WANT_READ) {
    return wait_for_socket(connection, socket_fd, POLLIN, deadline);
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return wait_for_socket(connection, socket_fd, POLLOUT, deadline);
  }
  return cancellation_result(connection) != 0
    ? STUPID_APP_COREDEVICE_TLS_CANCELLED
    : phase_failure;
}

static int perform_handshake(
  stupid_app_coredevice_tls_connection *connection,
  SSL *ssl,
  int socket_fd,
  int64_t deadline
) {
  while (1) {
    int state = deadline_result(connection, deadline);
    if (state != 0) {
      return state;
    }
    int operation_result = SSL_connect(ssl);
    if (operation_result == 1) {
      return STUPID_APP_COREDEVICE_TLS_OK;
    }
    int result = wait_for_ssl(
      connection,
      ssl,
      operation_result,
      socket_fd,
      deadline,
      STUPID_APP_COREDEVICE_TLS_HANDSHAKE_FAILED
    );
    if (result != STUPID_APP_COREDEVICE_TLS_OK) {
      return result;
    }
  }
}

static int write_all(
  stupid_app_coredevice_tls_connection *connection,
  SSL *ssl,
  int socket_fd,
  const uint8_t *bytes,
  size_t length,
  int64_t deadline
) {
  size_t offset = 0;
  while (offset < length) {
    int state = deadline_result(connection, deadline);
    if (state != 0) {
      return state;
    }
    size_t written = 0;
    int operation_result = SSL_write_ex(ssl, bytes + offset, length - offset, &written);
    if (operation_result == 1 && written > 0) {
      offset += written;
      continue;
    }
    int result = wait_for_ssl(
      connection,
      ssl,
      operation_result,
      socket_fd,
      deadline,
      STUPID_APP_COREDEVICE_TLS_WRITE_FAILED
    );
    if (result != STUPID_APP_COREDEVICE_TLS_OK) {
      return result;
    }
  }
  return STUPID_APP_COREDEVICE_TLS_OK;
}

static int read_all(
  stupid_app_coredevice_tls_connection *connection,
  SSL *ssl,
  int socket_fd,
  uint8_t *bytes,
  size_t length,
  int64_t deadline
) {
  size_t offset = 0;
  while (offset < length) {
    int state = deadline_result(connection, deadline);
    if (state != 0) {
      return state;
    }
    size_t received = 0;
    int operation_result = SSL_read_ex(ssl, bytes + offset, length - offset, &received);
    if (operation_result == 1 && received > 0) {
      offset += received;
      continue;
    }
    int result = wait_for_ssl(
      connection,
      ssl,
      operation_result,
      socket_fd,
      deadline,
      STUPID_APP_COREDEVICE_TLS_READ_FAILED
    );
    if (result != STUPID_APP_COREDEVICE_TLS_OK) {
      return result;
    }
  }
  return STUPID_APP_COREDEVICE_TLS_OK;
}

int stupid_app_coredevice_tls_validate_openssl(void) {
  if (OPENSSL_version_major() != 3) {
    return STUPID_APP_COREDEVICE_TLS_UNSUPPORTED_OPENSSL;
  }
  SSL_CTX *context = SSL_CTX_new(TLS_client_method());
  if (context == NULL) {
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  int supported = SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 &&
    SSL_CTX_set_max_proto_version(context, TLS1_2_VERSION) == 1 &&
    SSL_CTX_set_cipher_list(context, "PSK-AES128-GCM-SHA256") == 1;
  SSL_CTX_free(context);
  return supported
    ? STUPID_APP_COREDEVICE_TLS_OK
    : STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
}

int stupid_app_coredevice_tls_create(
  const char *host,
  uint16_t port,
  const uint8_t *psk,
  size_t psk_length,
  int timeout_milliseconds,
  stupid_app_coredevice_tls_connection **output
) {
  if (host == NULL || host[0] == '\0' || port == 0 || psk == NULL || psk_length == 0 ||
      psk_length > 256 || timeout_milliseconds <= 0 || output == NULL) {
    return STUPID_APP_COREDEVICE_TLS_INVALID_INPUT;
  }
  int version_result = stupid_app_coredevice_tls_validate_openssl();
  if (version_result != STUPID_APP_COREDEVICE_TLS_OK) {
    return version_result;
  }
  stupid_app_coredevice_tls_connection *connection = calloc(1, sizeof(*connection));
  if (connection == NULL) {
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  connection->host = strdup(host);
  if (connection->host == NULL) {
    free(connection);
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  connection->port = port;
  memcpy(connection->psk, psk, psk_length);
  connection->psk_length = psk_length;
  connection->timeout_milliseconds = timeout_milliseconds;
  atomic_init(&connection->cancelled, false);
  connection->socket_fd = -1;
  if (pthread_mutex_init(&connection->socket_mutex, NULL) != 0) {
    OPENSSL_cleanse(connection->psk, sizeof(connection->psk));
    free(connection->host);
    free(connection);
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  *output = connection;
  return STUPID_APP_COREDEVICE_TLS_OK;
}

static int start_exchange(
  stupid_app_coredevice_tls_connection *connection,
  const uint8_t *request,
  size_t request_length,
  uint8_t *response,
  size_t response_capacity,
  size_t *response_length
) {
  static const uint8_t magic[] = {'C', 'D', 'T', 'u', 'n', 'n', 'e', 'l'};
  if (connection == NULL || request == NULL || request_length < 10 || response == NULL ||
      response_capacity < 10 || response_length == NULL ||
      memcmp(request, magic, sizeof(magic)) != 0 ||
      request_length != 10 + (((size_t)request[8] << 8) | request[9])) {
    return STUPID_APP_COREDEVICE_TLS_INVALID_INPUT;
  }
  int64_t now = monotonic_milliseconds();
  if (now < 0 || connection->timeout_milliseconds > INT64_MAX - now) {
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  int64_t deadline = now + connection->timeout_milliseconds;
  int socket_fd = -1;
  int result = connect_socket(connection, deadline, &socket_fd);
  if (result != STUPID_APP_COREDEVICE_TLS_OK) {
    return result;
  }

  SSL_CTX *context = SSL_CTX_new(TLS_client_method());
  SSL *ssl = NULL;
  if (context == NULL || SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_max_proto_version(context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_cipher_list(context, "PSK-AES128-GCM-SHA256") != 1) {
    result = STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
    goto cleanup;
  }
  SSL_CTX_set_verify(context, SSL_VERIFY_NONE, NULL);
  SSL_CTX_set_psk_client_callback(context, provide_psk);
  ssl = SSL_new(context);
  if (ssl == NULL || SSL_set_fd(ssl, socket_fd) != 1) {
    result = STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
    goto cleanup;
  }
  SSL_set_app_data(ssl, connection);
  result = perform_handshake(connection, ssl, socket_fd, deadline);
  if (result != STUPID_APP_COREDEVICE_TLS_OK) {
    goto cleanup;
  }
  if (SSL_version(ssl) != TLS1_2_VERSION ||
      strcmp(SSL_get_cipher_name(ssl), "PSK-AES128-GCM-SHA256") != 0) {
    result = STUPID_APP_COREDEVICE_TLS_UNEXPECTED_PROTOCOL;
    goto cleanup;
  }
  result = write_all(connection, ssl, socket_fd, request, request_length, deadline);
  if (result != STUPID_APP_COREDEVICE_TLS_OK) {
    goto cleanup;
  }
  result = read_all(connection, ssl, socket_fd, response, 10, deadline);
  if (result != STUPID_APP_COREDEVICE_TLS_OK) {
    goto cleanup;
  }
  if (memcmp(response, magic, sizeof(magic)) != 0) {
    result = STUPID_APP_COREDEVICE_TLS_INVALID_RESPONSE;
    goto cleanup;
  }
  size_t body_length = ((size_t)response[8] << 8) | response[9];
  if (body_length > response_capacity - 10) {
    result = STUPID_APP_COREDEVICE_TLS_RESPONSE_TOO_LARGE;
    goto cleanup;
  }
  result = read_all(connection, ssl, socket_fd, response + 10, body_length, deadline);
  if (result == STUPID_APP_COREDEVICE_TLS_OK) {
    *response_length = 10 + body_length;
  }

cleanup:
  if (ssl != NULL) {
    SSL_free(ssl);
  }
  if (context != NULL) {
    SSL_CTX_free(context);
  }
  close_socket(connection);
  return result;
}

int stupid_app_coredevice_tls_start(
  stupid_app_coredevice_tls_connection *connection,
  const uint8_t *request,
  size_t request_length,
  uint8_t *response,
  size_t response_capacity,
  size_t *response_length
) {
  sigset_t blocked;
  sigset_t previous;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  if (pthread_sigmask(SIG_BLOCK, &blocked, &previous) != 0) {
    return STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED;
  }
  int result = start_exchange(
    connection,
    request,
    request_length,
    response,
    response_capacity,
    response_length
  );
  if (sigismember(&previous, SIGPIPE) == 0) {
    sigset_t pending;
    if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 1) {
      int received = 0;
      sigwait(&blocked, &received);
    }
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  return result;
}

void stupid_app_coredevice_tls_cancel(stupid_app_coredevice_tls_connection *connection) {
  if (connection == NULL) {
    return;
  }
  atomic_store(&connection->cancelled, true);
  pthread_mutex_lock(&connection->socket_mutex);
  int socket_fd = connection->socket_fd;
  if (socket_fd >= 0) {
    shutdown(socket_fd, SHUT_RDWR);
  }
  pthread_mutex_unlock(&connection->socket_mutex);
}

void stupid_app_coredevice_tls_destroy(stupid_app_coredevice_tls_connection *connection) {
  if (connection == NULL) {
    return;
  }
  close_socket(connection);
  pthread_mutex_destroy(&connection->socket_mutex);
  OPENSSL_cleanse(connection->psk, sizeof(connection->psk));
  free(connection->host);
  free(connection);
}

// ---------------------------------------------------------------------------
// Persistent remote-pairing TCP tunnel
// ---------------------------------------------------------------------------

struct stupid_app_coredevice_tls_tunnel {
  SSL *ssl;
  SSL_CTX *context;
  int socket_fd;
  int timeout_milliseconds;
  atomic_bool cancelled;
  pthread_mutex_t socket_mutex;
};

enum stupid_app_coredevice_tls_tunnel_result {
  STUPID_APP_COREDEVICE_TLS_TUNNEL_OK = 0,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_INPUT = 1,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_CONNECT_FAILED = 2,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED = 3,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_HANDSHAKE_FAILED = 4,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_WRITE_FAILED = 5,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_READ_FAILED = 6,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_TIMED_OUT = 7,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_CANCELLED = 8,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_UNEXPECTED_PROTOCOL = 9,
  STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_RESPONSE = 10,
};

static void tunnel_close_socket(stupid_app_coredevice_tls_tunnel *tunnel) {
  pthread_mutex_lock(&tunnel->socket_mutex);
  int socket_fd = tunnel->socket_fd;
  tunnel->socket_fd = -1;
  if (socket_fd >= 0) {
    close(socket_fd);
  }
  pthread_mutex_unlock(&tunnel->socket_mutex);
}

static void tunnel_set_socket(stupid_app_coredevice_tls_tunnel *tunnel, int socket_fd) {
  pthread_mutex_lock(&tunnel->socket_mutex);
  tunnel->socket_fd = socket_fd;
  pthread_mutex_unlock(&tunnel->socket_mutex);
}

static int tunnel_cancellation(stupid_app_coredevice_tls_tunnel *tunnel) {
  return atomic_load(&tunnel->cancelled) ? STUPID_APP_COREDEVICE_TLS_TUNNEL_CANCELLED : 0;
}

static int tunnel_deadline(stupid_app_coredevice_tls_tunnel *tunnel, int64_t deadline) {
  int cancelled = tunnel_cancellation(tunnel);
  if (cancelled != 0) {
    return cancelled;
  }
  int64_t now = monotonic_milliseconds();
  return now < 0 || now >= deadline ? STUPID_APP_COREDEVICE_TLS_TUNNEL_TIMED_OUT : 0;
}

static int tunnel_wait_for_socket(
  stupid_app_coredevice_tls_tunnel *tunnel,
  int socket_fd,
  short events,
  int64_t deadline
) {
  while (1) {
    int state = tunnel_deadline(tunnel, deadline);
    if (state != 0) {
      return state;
    }
    int64_t now = monotonic_milliseconds();
    int remaining = (int)(deadline - now);
    int interval = remaining < POLL_SLICE_MILLISECONDS ? remaining : POLL_SLICE_MILLISECONDS;
    struct pollfd descriptor = {.fd = socket_fd, .events = events};
    int result = poll(&descriptor, 1, interval);
    if (result > 0) {
      return STUPID_APP_COREDEVICE_TLS_TUNNEL_OK;
    }
    if (result < 0 && errno != EINTR) {
      return tunnel_cancellation(tunnel);
    }
  }
}

static int tunnel_wait_for_ssl(
  stupid_app_coredevice_tls_tunnel *tunnel,
  int operation_result,
  int64_t deadline,
  int phase_failure
) {
  int error = SSL_get_error(tunnel->ssl, operation_result);
  if (error == SSL_ERROR_WANT_READ) {
    return tunnel_wait_for_socket(tunnel, tunnel->socket_fd, POLLIN, deadline);
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return tunnel_wait_for_socket(tunnel, tunnel->socket_fd, POLLOUT, deadline);
  }
  return tunnel_cancellation(tunnel) != 0
    ? STUPID_APP_COREDEVICE_TLS_TUNNEL_CANCELLED
    : phase_failure;
}

int stupid_app_coredevice_tls_tunnel_connect(
  const char *host,
  uint16_t port,
  const uint8_t *psk,
  size_t psk_length,
  int timeout_milliseconds,
  uint8_t *handshake_response,
  size_t handshake_capacity,
  size_t *handshake_length,
  stupid_app_coredevice_tls_tunnel **tunnel_output
) {
  if (host == NULL || host[0] == '\0' || port == 0 || psk == NULL || psk_length == 0 ||
      psk_length > 256 || timeout_milliseconds <= 0 || handshake_response == NULL ||
      handshake_capacity < 10 || handshake_length == NULL || tunnel_output == NULL) {
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_INPUT;
  }
  int version_result = stupid_app_coredevice_tls_validate_openssl();
  if (version_result != STUPID_APP_COREDEVICE_TLS_OK) {
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }

  stupid_app_coredevice_tls_connection *connection = NULL;
  int create_result = stupid_app_coredevice_tls_create(
    host, port, psk, psk_length, timeout_milliseconds, &connection);
  if (create_result != STUPID_APP_COREDEVICE_TLS_OK) {
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }

  stupid_app_coredevice_tls_tunnel *tunnel = calloc(1, sizeof(*tunnel));
  if (tunnel == NULL) {
    stupid_app_coredevice_tls_destroy(connection);
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }
  tunnel->socket_fd = -1;
  tunnel->timeout_milliseconds = timeout_milliseconds;
  atomic_init(&tunnel->cancelled, false);
  if (pthread_mutex_init(&tunnel->socket_mutex, NULL) != 0) {
    free(tunnel);
    stupid_app_coredevice_tls_destroy(connection);
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }

  int64_t now = monotonic_milliseconds();
  if (now < 0 || timeout_milliseconds > INT64_MAX - now) {
    stupid_app_coredevice_tls_destroy(connection);
    pthread_mutex_destroy(&tunnel->socket_mutex);
    free(tunnel);
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }
  int64_t deadline = now + timeout_milliseconds;

  int socket_fd = -1;
  int result = connect_socket(connection, deadline, &socket_fd);
  if (result != STUPID_APP_COREDEVICE_TLS_OK) {
    stupid_app_coredevice_tls_destroy(connection);
    pthread_mutex_destroy(&tunnel->socket_mutex);
    free(tunnel);
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONNECT_FAILED;
  }
  tunnel_set_socket(tunnel, socket_fd);

  tunnel->context = SSL_CTX_new(TLS_client_method());
  if (tunnel->context == NULL ||
      SSL_CTX_set_min_proto_version(tunnel->context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_max_proto_version(tunnel->context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_cipher_list(tunnel->context, "PSK-AES128-GCM-SHA256") != 1) {
    result = STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
    goto cleanup;
  }
  SSL_CTX_set_verify(tunnel->context, SSL_VERIFY_NONE, NULL);
  SSL_CTX_set_psk_client_callback(tunnel->context, provide_psk);
  tunnel->ssl = SSL_new(tunnel->context);
  if (tunnel->ssl == NULL || SSL_set_fd(tunnel->ssl, socket_fd) != 1) {
    result = STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
    goto cleanup;
  }
  SSL_set_app_data(tunnel->ssl, connection);

  // TLS 1.2 PSK handshake.
  for (;;) {
    int state = tunnel_deadline(tunnel, deadline);
    if (state != 0) {
      result = state;
      goto cleanup;
    }
    int operation_result = SSL_connect(tunnel->ssl);
    if (operation_result == 1) {
      break;
    }
    int wait = tunnel_wait_for_ssl(
      tunnel, operation_result, deadline, STUPID_APP_COREDEVICE_TLS_TUNNEL_HANDSHAKE_FAILED);
    if (wait != STUPID_APP_COREDEVICE_TLS_TUNNEL_OK) {
      result = wait;
      goto cleanup;
    }
  }
  if (SSL_version(tunnel->ssl) != TLS1_2_VERSION ||
      strcmp(SSL_get_cipher_name(tunnel->ssl), "PSK-AES128-GCM-SHA256") != 0) {
    result = STUPID_APP_COREDEVICE_TLS_TUNNEL_UNEXPECTED_PROTOCOL;
    goto cleanup;
  }

  // CDTunnel handshake: write clientHandshakeRequest, read the response header
  // and body, then return the response bytes for Swift to parse.
  static const uint8_t magic[] = {'C', 'D', 'T', 'u', 'n', 'n', 'e', 'l'};
  static const uint8_t request_body[] =
    "{\"mtu\":16000,\"type\":\"clientHandshakeRequest\"}";
  uint8_t request[10 + sizeof(request_body) - 1];
  memcpy(request, magic, 8);
  request[8] = (uint8_t)(((sizeof(request_body) - 1) >> 8) & 0xFF);
  request[9] = (uint8_t)((sizeof(request_body) - 1) & 0xFF);
  memcpy(request + 10, request_body, sizeof(request_body) - 1);

  size_t written = 0;
  while (written < sizeof(request)) {
    size_t part = 0;
    int write_result =
      SSL_write_ex(tunnel->ssl, request + written, sizeof(request) - written, &part);
    if (write_result == 1 && part > 0) {
      written += part;
      continue;
    }
    int wait = tunnel_wait_for_ssl(
      tunnel, write_result, deadline, STUPID_APP_COREDEVICE_TLS_TUNNEL_WRITE_FAILED);
    if (wait != STUPID_APP_COREDEVICE_TLS_TUNNEL_OK) {
      result = wait;
      goto cleanup;
    }
  }

  size_t received = 0;
  while (received < 10) {
    size_t part = 0;
    int read_result =
      SSL_read_ex(tunnel->ssl, handshake_response + received, 10 - received, &part);
    if (read_result == 1 && part > 0) {
      received += part;
      continue;
    }
    int wait = tunnel_wait_for_ssl(
      tunnel, read_result, deadline, STUPID_APP_COREDEVICE_TLS_TUNNEL_READ_FAILED);
    if (wait != STUPID_APP_COREDEVICE_TLS_TUNNEL_OK) {
      result = wait;
      goto cleanup;
    }
  }
  if (memcmp(handshake_response, magic, sizeof(magic)) != 0) {
    result = STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_RESPONSE;
    goto cleanup;
  }
  size_t body_length = ((size_t)handshake_response[8] << 8) | handshake_response[9];
  if (body_length > handshake_capacity - 10) {
    result = STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_RESPONSE;
    goto cleanup;
  }
  size_t response_offset = 10;
  while (response_offset < 10 + body_length) {
    size_t part = 0;
    int read_result = SSL_read_ex(
      tunnel->ssl,
      handshake_response + response_offset,
      10 + body_length - response_offset,
      &part);
    if (read_result == 1 && part > 0) {
      response_offset += part;
      continue;
    }
    int wait = tunnel_wait_for_ssl(
      tunnel, read_result, deadline, STUPID_APP_COREDEVICE_TLS_TUNNEL_READ_FAILED);
    if (wait != STUPID_APP_COREDEVICE_TLS_TUNNEL_OK) {
      result = wait;
      goto cleanup;
    }
  }
  *handshake_length = 10 + body_length;

  // The connection object is no longer needed. Detach its socket (now owned by
  // the retained tunnel) and its PSK so destruction cannot double-close the
  // socket that carries the live tunnel.
  connection->socket_fd = -1;

  // The connection object is no longer needed; its psk/socket are now owned by
  // the retained SSL and tunnel socket.
  stupid_app_coredevice_tls_cancel(connection);
  stupid_app_coredevice_tls_destroy(connection);
  *tunnel_output = tunnel;
  return STUPID_APP_COREDEVICE_TLS_TUNNEL_OK;

cleanup:
  if (tunnel->ssl != NULL) {
    SSL_free(tunnel->ssl);
  }
  if (tunnel->context != NULL) {
    SSL_CTX_free(tunnel->context);
  }
  tunnel_close_socket(tunnel);
  pthread_mutex_destroy(&tunnel->socket_mutex);
  connection->socket_fd = -1;
  stupid_app_coredevice_tls_destroy(connection);
  free(tunnel);
  return result;
}

int stupid_app_coredevice_tls_tunnel_relay(
  stupid_app_coredevice_tls_tunnel *tunnel,
  int tun_fd,
  volatile int *stop
) {
  if (tunnel == NULL || tunnel->ssl == NULL || tunnel->socket_fd < 0 || tun_fd < 0 ||
      stop == NULL) {
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_INVALID_INPUT;
  }
  signal(SIGPIPE, SIG_IGN);
  int debug = getenv("STUPID_APP_TUNNEL_DEBUG") != NULL;
  int64_t relay_deadline;
  int64_t now = monotonic_milliseconds();
  if (now < 0 || tunnel->timeout_milliseconds > INT64_MAX - now) {
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }
  relay_deadline = now + tunnel->timeout_milliseconds;

  uint8_t *inbound = malloc(131072);
  size_t inbound_length = 0;
  uint8_t *outbound = malloc(65536);
  if (inbound == NULL || outbound == NULL) {
    free(inbound);
    free(outbound);
    return STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
  }
  int result = STUPID_APP_COREDEVICE_TLS_TUNNEL_OK;
  while (!*stop) {
    int64_t loop_now = monotonic_milliseconds();
    if (loop_now < 0 || loop_now >= relay_deadline) {
      result = STUPID_APP_COREDEVICE_TLS_TUNNEL_TIMED_OUT;
      break;
    }
    int remaining = (int)(relay_deadline - loop_now);

    struct pollfd descriptors[2] = {
      {.fd = tunnel->socket_fd, .events = POLLIN},
      {.fd = tun_fd, .events = POLLIN},
    };
    int waited = poll(descriptors, 2, remaining < 2 ? remaining : 2);
    if (waited < 0) {
      if (errno == EINTR) {
        continue;
      }
      result = STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
      break;
    }

    // Device -> host. Drain every available decrypted byte. The drain is
    // attempted even when poll did not report the socket as readable: OpenSSL
    // can hold decrypted data in its internal buffer with no new socket bytes,
    // and SSL_read_ex must return it or the peer-info would sit unread.
    int tunnel_closed = 0;
    while (1) {
      size_t received = 0;
      int read_result =
        SSL_read_ex(tunnel->ssl, inbound + inbound_length, 131072 - inbound_length, &received);
      if (read_result == 1 && received > 0) {
        if (debug) {
          size_t buffered = inbound_length + received;
          fprintf(stderr, "[relay] device->host chunk=%zu buffered=%zu raw:", received, buffered);
          for (size_t i = 0; i < received && i < 40; i++) {
            fprintf(stderr, " %02x", inbound[inbound_length + i]);
          }
          fprintf(stderr, "\n");
          size_t o = 0;
          while (o + 40 <= buffered) {
            size_t plen2 = ((size_t)inbound[o + 4] << 8) | inbound[o + 5];
            if (o + 40 + plen2 > buffered) break;
            unsigned int seq = ((unsigned int)inbound[o + 44] << 24) | ((unsigned int)inbound[o + 45] << 16) |
              ((unsigned int)inbound[o + 46] << 8) | inbound[o + 47];
            unsigned int ack = ((unsigned int)inbound[o + 48] << 24) | ((unsigned int)inbound[o + 49] << 16) |
              ((unsigned int)inbound[o + 50] << 8) | inbound[o + 51];
            unsigned int flags = ((unsigned int)inbound[o + 52] << 8) | inbound[o + 53];
            unsigned int tcp_len = ((unsigned int)inbound[o + 52] >> 4) * 4;
            fprintf(stderr,
              "[relay]   pkt len=%zu src=%02x%02x dst=%02x%02x seq=%08x ack=%08x flags=%04x tcplen=%u payload=%zu\n",
              plen2 + 40, inbound[o + 40], inbound[o + 41], inbound[o + 42], inbound[o + 43],
              seq, ack, flags & 0x0fff, tcp_len, plen2 > tcp_len ? plen2 - tcp_len : 0);
            o += 40 + plen2;
          }
        }
        inbound_length += received;
        size_t offset = 0;
        while (offset + 40 <= inbound_length) {
          size_t payload = ((size_t)inbound[offset + 4] << 8) | inbound[offset + 5];
          size_t packet_length = 40 + payload;
          if (packet_length > inbound_length - offset) {
            break;
          }
          int packet_written = stupid_app_tun_relay_write(tun_fd, inbound + offset, packet_length);
          if (packet_written != 0) {
            result = STUPID_APP_COREDEVICE_TLS_TUNNEL_WRITE_FAILED;
            offset = inbound_length;
            break;
          }
          offset += packet_length;
        }
        if (offset < inbound_length) {
          memmove(inbound, inbound + offset, inbound_length - offset);
          inbound_length -= offset;
        } else {
          inbound_length = 0;
        }
        continue;
      }
      // read_result <= 0. Distinguish a real peer close from a would-block on
      // the non-blocking socket: SSL_read_ex returns 0 for both SSL_ERROR_WANT_READ
      // and SSL_ERROR_ZERO_RETURN, so the error must be inspected explicitly.
      int error = SSL_get_error(tunnel->ssl, read_result);
      if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) {
        break;
      }
      if (error == SSL_ERROR_ZERO_RETURN) {
        if (debug) fprintf(stderr, "[relay] device->host clean close\n");
        tunnel_closed = 1;
      } else {
        if (debug)
          fprintf(stderr, "[relay] device->host SSL error %d\n", error);
        result = STUPID_APP_COREDEVICE_TLS_TUNNEL_READ_FAILED;
        tunnel_closed = 1;
      }
      break;
    }
    if (tunnel_closed) break;

    // Host -> device.
    if (descriptors[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t packet_length = stupid_app_tun_relay_read(tun_fd, outbound, 65536);
      if (packet_length > 0) {
        if (debug) {
          fprintf(stderr, "[relay] host->device %zd bytes", packet_length);
          if (packet_length >= 44) {
            unsigned int seq = ((unsigned int)outbound[44] << 24) | ((unsigned int)outbound[45] << 16) |
              ((unsigned int)outbound[46] << 8) | outbound[47];
            unsigned int ack = ((unsigned int)outbound[48] << 24) | ((unsigned int)outbound[49] << 16) |
              ((unsigned int)outbound[50] << 8) | outbound[51];
            unsigned int flags = ((unsigned int)outbound[52] << 8) | outbound[53];
            fprintf(stderr, " src=%02x%02x dst=%02x%02x seq=%08x ack=%08x flags=%04x",
              outbound[40], outbound[41], outbound[42], outbound[43], seq, ack, flags & 0x0fff);
            fprintf(stderr, " srcIP=%02x%02x:%02x%02x...%02x%02x dstIP=%02x%02x:%02x%02x...%02x%02x",
              outbound[8], outbound[9], outbound[10], outbound[11], outbound[22], outbound[23],
              outbound[24], outbound[25], outbound[26], outbound[27], outbound[38], outbound[39]);
          }
          fprintf(stderr, "\n");
        }
        size_t offset = 0;
        while (offset < (size_t)packet_length) {
          size_t written_chunk = 0;
          int write_result = SSL_write_ex(
            tunnel->ssl, outbound + offset, (size_t)packet_length - offset, &written_chunk);
          if (write_result == 1 && written_chunk > 0) {
            offset += written_chunk;
            continue;
          }
          int error = SSL_get_error(tunnel->ssl, write_result);
          if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) {
            short events = error == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
            int64_t write_deadline;
            int64_t write_now = monotonic_milliseconds();
            if (write_now < 0 || tunnel->timeout_milliseconds > INT64_MAX - write_now) {
              result = STUPID_APP_COREDEVICE_TLS_TUNNEL_CONFIGURATION_FAILED;
              offset = (size_t)packet_length;
              break;
            }
            write_deadline = write_now + tunnel->timeout_milliseconds;
            if (tunnel_wait_for_socket(tunnel, tunnel->socket_fd, events, write_deadline) !=
                STUPID_APP_COREDEVICE_TLS_TUNNEL_OK) {
              result = STUPID_APP_COREDEVICE_TLS_TUNNEL_TIMED_OUT;
              offset = (size_t)packet_length;
              break;
            }
            continue;
          }
          result = STUPID_APP_COREDEVICE_TLS_TUNNEL_WRITE_FAILED;
          offset = (size_t)packet_length;
          break;
        }
      } else if (packet_length < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        result = STUPID_APP_COREDEVICE_TLS_TUNNEL_READ_FAILED;
        break;
      }
    }
  }
  free(inbound);
  free(outbound);
  return result;
}

void stupid_app_coredevice_tls_tunnel_cancel(stupid_app_coredevice_tls_tunnel *tunnel) {
  if (tunnel == NULL) {
    return;
  }
  atomic_store(&tunnel->cancelled, true);
  pthread_mutex_lock(&tunnel->socket_mutex);
  int socket_fd = tunnel->socket_fd;
  if (socket_fd >= 0) {
    shutdown(socket_fd, SHUT_RDWR);
  }
  pthread_mutex_unlock(&tunnel->socket_mutex);
}

void stupid_app_coredevice_tls_tunnel_destroy(stupid_app_coredevice_tls_tunnel *tunnel) {
  if (tunnel == NULL) {
    return;
  }
  if (tunnel->ssl != NULL) {
    SSL_free(tunnel->ssl);
  }
  if (tunnel->context != NULL) {
    SSL_CTX_free(tunnel->context);
  }
  tunnel_close_socket(tunnel);
  pthread_mutex_destroy(&tunnel->socket_mutex);
  free(tunnel);
}
