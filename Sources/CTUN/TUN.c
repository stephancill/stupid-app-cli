#include "CTUN.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__linux__)

#include <arpa/inet.h>
#include <linux/if_tun.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

struct stupid_app_tun_device {
  int descriptor;
  char name[IFNAMSIZ];
};

static int open_socket_ioctl(void) {
  return socket(AF_INET, SOCK_DGRAM, 0);
}

static int get_ifindex(const char *name, int *index) {
  int sock = open_socket_ioctl();
  if (sock < 0) {
    return -1;
  }
  struct ifreq request = {0};
  strncpy(request.ifr_name, name, IFNAMSIZ - 1);
  int result = ioctl(sock, SIOCGIFINDEX, &request);
  int saved = errno;
  close(sock);
  if (result != 0) {
    errno = saved;
    return -1;
  }
  *index = request.ifr_ifindex;
  return 0;
}

static int set_mtu(const char *name, int mtu) {
  int sock = open_socket_ioctl();
  if (sock < 0) {
    return -1;
  }
  struct ifreq request = {0};
  strncpy(request.ifr_name, name, IFNAMSIZ - 1);
  request.ifr_mtu = mtu;
  int result = ioctl(sock, SIOCSIFMTU, &request);
  int saved = errno;
  close(sock);
  if (result != 0) {
    errno = saved;
    return -1;
  }
  return 0;
}

static int netlink_socket(void) {
  int sock = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
  if (sock < 0) {
    return -1;
  }
  struct sockaddr_nl address = {0};
  address.nl_family = AF_NETLINK;
  if (bind(sock, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(sock);
    return -1;
  }
  return sock;
}

// Dumps the IPv6 address table to stderr when STUPID_APP_TUN_DEBUG is set,
// so the caller can verify whether an address was actually applied.
static void dump_addresses_if_debug(void) {
  if (getenv("STUPID_APP_TUN_DEBUG") == NULL) {
    return;
  }
  int sock = netlink_socket();
  if (sock < 0) {
    return;
  }
  struct {
    struct nlmsghdr header;
    struct ifaddrmsg address_message;
  } request = {0};
  request.header.nlmsg_type = RTM_GETADDR;
  request.address_message.ifa_family = AF_INET6;
  size_t message_length = NLMSG_LENGTH(sizeof(request.address_message));
  request.header.nlmsg_len = (uint32_t)message_length;
  request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  struct sockaddr_nl address = {0};
  address.nl_family = AF_NETLINK;
  struct iovec iovec = {.iov_base = &request, .iov_len = message_length};
  struct msghdr message = {0};
  message.msg_name = &address;
  message.msg_namelen = sizeof(address);
  message.msg_iov = &iovec;
  message.msg_iovlen = 1;
  if (sendmsg(sock, &message, 0) < 0) {
    close(sock);
    return;
  }
  char buffer[8192];
  fprintf(stderr, "[tun addr dump]\n");
  while (1) {
    ssize_t length = recv(sock, buffer, sizeof(buffer), 0);
    if (length < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    for (struct nlmsghdr *current = (struct nlmsghdr *)buffer; NLMSG_OK(current, (size_t)length);
         current = NLMSG_NEXT(current, length)) {
      if (current->nlmsg_type == NLMSG_DONE) {
        close(sock);
        return;
      }
      if (current->nlmsg_type != RTM_NEWADDR) {
        continue;
      }
      struct ifaddrmsg *ifa = (struct ifaddrmsg *)NLMSG_DATA(current);
      if (ifa->ifa_family != AF_INET6) {
        continue;
      }
      int remaining = (int)(current->nlmsg_len - NLMSG_LENGTH(sizeof(*ifa)));
      struct rtattr *attribute = (struct rtattr *)(((char *)ifa) + NLMSG_ALIGN(sizeof(*ifa)));
      char address_string[INET6_ADDRSTRLEN] = "-";
      for (; RTA_OK(attribute, remaining); attribute = RTA_NEXT(attribute, remaining)) {
        if (attribute->rta_type == IFA_ADDRESS && RTA_PAYLOAD(attribute) >= 16) {
          inet_ntop(AF_INET6, RTA_DATA(attribute), address_string, sizeof(address_string));
        }
      }
      fprintf(stderr, "  ifindex=%u addr=%s\n", ifa->ifa_index, address_string);
    }
  }
  close(sock);
}

static int netlink_request(int sock, struct nlmsghdr *header, size_t message_length) {
  header->nlmsg_len = (uint32_t)message_length;
  header->nlmsg_flags |= NLM_F_REQUEST | NLM_F_ACK;
  struct sockaddr_nl address = {0};
  address.nl_family = AF_NETLINK;
  struct iovec iovec = {.iov_base = header, .iov_len = header->nlmsg_len};
  struct msghdr message = {0};
  message.msg_name = &address;
  message.msg_namelen = sizeof(address);
  message.msg_iov = &iovec;
  message.msg_iovlen = 1;
  if (sendmsg(sock, &message, 0) < 0) {
    return -1;
  }

  char buffer[4096];
  while (1) {
    ssize_t length = recv(sock, buffer, sizeof(buffer), 0);
    if (length < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    for (struct nlmsghdr *current = (struct nlmsghdr *)buffer; NLMSG_OK(current, (size_t)length);
         current = NLMSG_NEXT(current, length)) {
      if (current->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *error = (struct nlmsgerr *)NLMSG_DATA(current);
        if (error->error != 0) {
          errno = -error->error;
          return -1;
        }
        return 0;
      }
      if (current->nlmsg_type == NLMSG_DONE) {
        return 0;
      }
    }
  }
}

// Dumps the IPv6 route table to stderr when STUPID_APP_TUN_DEBUG is set.
static void dump_routes_if_debug(void) {
  if (getenv("STUPID_APP_TUN_DEBUG") == NULL) {
    return;
  }
  int sock = netlink_socket();
  if (sock < 0) {
    return;
  }
  struct {
    struct nlmsghdr header;
    struct rtmsg route_message;
  } request = {0};
  request.header.nlmsg_type = RTM_GETROUTE;
  request.route_message.rtm_family = AF_INET6;
  size_t message_length = NLMSG_LENGTH(sizeof(request.route_message));
  request.header.nlmsg_len = (uint32_t)message_length;
  request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  struct sockaddr_nl address = {0};
  address.nl_family = AF_NETLINK;
  struct iovec iovec = {.iov_base = &request, .iov_len = message_length};
  struct msghdr message = {0};
  message.msg_name = &address;
  message.msg_namelen = sizeof(address);
  message.msg_iov = &iovec;
  message.msg_iovlen = 1;
  if (sendmsg(sock, &message, 0) < 0) {
    close(sock);
    return;
  }
  char buffer[8192];
  fprintf(stderr, "[tun route dump]\n");
  while (1) {
    ssize_t length = recv(sock, buffer, sizeof(buffer), 0);
    if (length < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    for (struct nlmsghdr *current = (struct nlmsghdr *)buffer; NLMSG_OK(current, (size_t)length);
         current = NLMSG_NEXT(current, length)) {
      if (current->nlmsg_type == NLMSG_DONE) {
        close(sock);
        return;
      }
      if (current->nlmsg_type != RTM_NEWROUTE) {
        continue;
      }
      struct rtmsg *rtm = (struct rtmsg *)NLMSG_DATA(current);
      if (rtm->rtm_family != AF_INET6 ||
          (rtm->rtm_table != RT_TABLE_MAIN && rtm->rtm_table != RT_TABLE_UNSPEC)) {
        continue;
      }
      int remaining = (int)(current->nlmsg_len - NLMSG_LENGTH(sizeof(*rtm)));
      struct rtattr *attribute = (struct rtattr *)(((char *)rtm) + NLMSG_ALIGN(sizeof(*rtm)));
      char destination[INET6_ADDRSTRLEN] = "-";
      int interface = -1;
      for (; RTA_OK(attribute, remaining); attribute = RTA_NEXT(attribute, remaining)) {
        if (attribute->rta_type == RTA_DST && RTA_PAYLOAD(attribute) >= 16) {
          inet_ntop(AF_INET6, RTA_DATA(attribute), destination, sizeof(destination));
        }
        if (attribute->rta_type == RTA_OIF && RTA_PAYLOAD(attribute) >= 4) {
          interface = (int)(*(uint32_t *)RTA_DATA(attribute));
        }
      }
      fprintf(stderr, "  dst=%s/%u oif=%d\n", destination, rtm->rtm_dst_len, interface);
    }
  }
  close(sock);
}

static int add_ipv6_address(const char *name, const char *address, int prefixlen) {
  struct in6_addr packed;
  if (inet_pton(AF_INET6, address, &packed) != 1) {
    errno = EINVAL;
    return -1;
  }
  int index = 0;
  if (get_ifindex(name, &index) != 0) {
    return -1;
  }
  int sock = netlink_socket();
  if (sock < 0) {
    return -1;
  }
  struct {
    struct nlmsghdr header;
    struct ifaddrmsg address_message;
    char attributes[128];
  } request = {0};
  request.header.nlmsg_type = RTM_NEWADDR;
  request.header.nlmsg_flags = NLM_F_CREATE | NLM_F_EXCL;
  request.address_message.ifa_family = AF_INET6;
  request.address_message.ifa_prefixlen = (uint8_t)prefixlen;
  request.address_message.ifa_scope = 0;
  request.address_message.ifa_index = (uint32_t)index;
  size_t offset = 0;
  struct rtattr *address_attribute = (struct rtattr *)request.attributes;
  address_attribute->rta_type = IFA_LOCAL;
  address_attribute->rta_len = RTA_LENGTH(16);
  memcpy(RTA_DATA(address_attribute), &packed, 16);
  offset += address_attribute->rta_len;
  struct rtattr *peer_attribute = (struct rtattr *)(request.attributes + offset);
  peer_attribute->rta_type = IFA_ADDRESS;
  peer_attribute->rta_len = RTA_LENGTH(16);
  memcpy(RTA_DATA(peer_attribute), &packed, 16);
  offset += peer_attribute->rta_len;
  size_t message_length = NLMSG_LENGTH(sizeof(request.address_message)) + offset;
  int result = netlink_request(sock, &request.header, message_length);
  int saved = errno;
  close(sock);
  if (result != 0) {
    errno = saved;
    return -1;
  }
  return 0;
}

static int add_ipv6_route(const char *name, const char *destination, int prefixlen) {
  struct in6_addr packed;
  if (inet_pton(AF_INET6, destination, &packed) != 1) {
    errno = EINVAL;
    return -1;
  }
  int index = 0;
  if (get_ifindex(name, &index) != 0) {
    return -1;
  }
  int sock = netlink_socket();
  if (sock < 0) {
    return -1;
  }
  struct {
    struct nlmsghdr header;
    struct rtmsg route_message;
    char attributes[64];
  } request = {0};
  request.header.nlmsg_type = RTM_NEWROUTE;
  request.header.nlmsg_flags = NLM_F_CREATE | NLM_F_EXCL;
  request.route_message.rtm_family = AF_INET6;
  request.route_message.rtm_dst_len = (uint8_t)prefixlen;
  request.route_message.rtm_table = RT_TABLE_MAIN;
  request.route_message.rtm_protocol = RTPROT_STATIC;
  request.route_message.rtm_scope = RT_SCOPE_UNIVERSE;
  request.route_message.rtm_type = RTN_UNICAST;
  struct rtattr *destination_attribute = (struct rtattr *)request.attributes;
  destination_attribute->rta_type = RTA_DST;
  destination_attribute->rta_len = RTA_LENGTH(16);
  memcpy(RTA_DATA(destination_attribute), &packed, 16);
  size_t attributes_length = destination_attribute->rta_len;
  struct rtattr *interface_attribute = (struct rtattr *)(request.attributes + attributes_length);
  interface_attribute->rta_type = RTA_OIF;
  interface_attribute->rta_len = RTA_LENGTH(4);
  uint32_t ifindex = (uint32_t)index;
  memcpy(RTA_DATA(interface_attribute), &ifindex, 4);
  attributes_length += interface_attribute->rta_len;
  size_t message_length = NLMSG_LENGTH(sizeof(request.route_message)) + attributes_length;
  int result = netlink_request(sock, &request.header, message_length);
  int saved = errno;
  close(sock);
  if (result != 0) {
    errno = saved;
    return -1;
  }
  return 0;
}

static int set_link_up(const char *name, bool up) {
  int index = 0;
  if (get_ifindex(name, &index) != 0) {
    return -1;
  }
  int sock = netlink_socket();
  if (sock < 0) {
    return -1;
  }
  struct {
    struct nlmsghdr header;
    struct ifinfomsg interface_message;
  } request = {0};
  request.header.nlmsg_type = RTM_NEWLINK;
  request.interface_message.ifi_family = AF_UNSPEC;
  request.interface_message.ifi_index = index;
  request.interface_message.ifi_flags = IFF_UP;
  request.interface_message.ifi_change = IFF_UP;
  if (!up) {
    request.interface_message.ifi_flags = 0;
  }
  int result = netlink_request(sock, &request.header, sizeof(request));
  int saved = errno;
  close(sock);
  if (result != 0) {
    errno = saved;
    return -1;
  }
  return 0;
}

#endif  // __linux__

int stupid_app_tun_create(
  const char *name,
  const char *ipv6_address,
  int mtu,
  stupid_app_tun_device **output
) {
#if defined(__linux__)
  if (name == NULL || ipv6_address == NULL || mtu <= 0 || mtu > 65535 ||
      output == NULL) {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  int descriptor = open("/dev/net/tun", O_RDWR);
  if (descriptor < 0) {
    return STUPID_APP_TUN_OPEN_FAILED;
  }
  struct ifreq request = {0};
  strncpy(request.ifr_name, name, IFNAMSIZ - 1);
  request.ifr_flags = (short)(IFF_TUN | IFF_NO_PI);
  if (ioctl(descriptor, TUNSETIFF, &request) != 0) {
    int saved = errno;
    close(descriptor);
    errno = saved;
    return STUPID_APP_TUN_OPEN_FAILED;
  }

  stupid_app_tun_device *device = calloc(1, sizeof(*device));
  if (device == NULL) {
    close(descriptor);
    return STUPID_APP_TUN_CONFIGURATION_FAILED;
  }
  device->descriptor = descriptor;
  strncpy(device->name, request.ifr_name, IFNAMSIZ - 1);

  int mtu_result = set_mtu(device->name, mtu);
  int address_result = add_ipv6_address(device->name, ipv6_address, 64);
  int up_result = set_link_up(device->name, true);
  if (getenv("STUPID_APP_TUN_DEBUG") != NULL) {
    char netns_link[64];
    ssize_t netns_len = readlink("/proc/self/ns/net", netns_link, sizeof(netns_link) - 1);
    if (netns_len < 0) {
      netns_len = 0;
    }
    netns_link[netns_len] = '\0';
    fprintf(stderr,
            "tun create: name=%s addr=%s mtu=%d addr_result=%d up_result=%d errno=%d (%s) netns=%s\n",
            device->name, ipv6_address, mtu_result, address_result, up_result, errno,
            strerror(errno), netns_link);
  }
  if (mtu_result != 0 || address_result != 0 || up_result != 0) {
    int saved = errno;
    stupid_app_tun_destroy(device);
    errno = saved;
    return STUPID_APP_TUN_CONFIGURATION_FAILED;
  }
  if (getenv("STUPID_APP_TUN_DEBUG") != NULL) {
    dump_addresses_if_debug();
    dump_routes_if_debug();
  }
  *output = device;
  return STUPID_APP_TUN_OK;
#else
  (void)name;
  (void)ipv6_address;
  (void)mtu;
  (void)output;
  return STUPID_APP_TUN_UNSUPPORTED;
#endif
}

int stupid_app_tun_add_route(
  stupid_app_tun_device *device,
  const char *destination
) {
#if defined(__linux__)
  if (device == NULL || destination == NULL || destination[0] == '\0') {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  if (add_ipv6_route(device->name, destination, 128) != 0) {
    return STUPID_APP_TUN_CONFIGURATION_FAILED;
  }
  return STUPID_APP_TUN_OK;
#else
  (void)device;
  (void)destination;
  return STUPID_APP_TUN_UNSUPPORTED;
#endif
}

int stupid_app_tun_name(
  const stupid_app_tun_device *device,
  char *buffer,
  size_t capacity
) {
#if defined(__linux__)
  if (device == NULL || buffer == NULL || capacity == 0) {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  size_t length = strlen(device->name);
  if (length >= capacity) {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  memcpy(buffer, device->name, length);
  buffer[length] = '\0';
  return STUPID_APP_TUN_OK;
#else
  (void)device;
  (void)buffer;
  (void)capacity;
  return STUPID_APP_TUN_UNSUPPORTED;
#endif
}

int stupid_app_tun_read(
  stupid_app_tun_device *device,
  uint8_t *buffer,
  size_t capacity
) {
#if defined(__linux__)
  if (device == NULL || buffer == NULL || capacity == 0) {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  ssize_t result = read(device->descriptor, buffer, capacity);
  if (result < 0) {
    return STUPID_APP_TUN_READ_FAILED;
  }
  return (int)result;
#else
  (void)device;
  (void)buffer;
  (void)capacity;
  return STUPID_APP_TUN_UNSUPPORTED;
#endif
}

int stupid_app_tun_write(
  stupid_app_tun_device *device,
  const uint8_t *bytes,
  size_t length
) {
#if defined(__linux__)
  if (device == NULL || bytes == NULL || length == 0) {
    return STUPID_APP_TUN_INVALID_INPUT;
  }
  size_t offset = 0;
  while (offset < length) {
    ssize_t written = write(device->descriptor, bytes + offset, length - offset);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return STUPID_APP_TUN_WRITE_FAILED;
    }
    offset += (size_t)written;
  }
  return STUPID_APP_TUN_OK;
#else
  (void)device;
  (void)bytes;
  (void)length;
  return STUPID_APP_TUN_UNSUPPORTED;
#endif
}

void stupid_app_tun_destroy(stupid_app_tun_device *device) {
#if defined(__linux__)
  if (device == NULL) {
    return;
  }
  if (device->descriptor >= 0) {
    set_link_up(device->name, false);
    close(device->descriptor);
  }
  free(device);
#else
  (void)device;
#endif
}
