#ifndef STUPID_APP_USERSPACE_IP_H
#define STUPID_APP_USERSPACE_IP_H
#include <stdint.h>

typedef struct stupid_app_userspace_ip stupid_app_userspace_ip;
// Takes ownership of packet_fd on success only. It must be a connected datagram
// socket carrying one bare IPv6 packet per datagram, never a kernel interface.
int stupid_app_userspace_ip_create(int packet_fd, const char *client_address,
                                   const char *server_address, uint16_t mtu,
                                   stupid_app_userspace_ip **output);
// Returns an owned connected AF_UNIX stream descriptor, or a negative errno.
int stupid_app_userspace_ip_connect(stupid_app_userspace_ip *stack,
                                    uint16_t port, int timeout_milliseconds);
// Cancels I/O and joins the worker. Serialize calls to stop/destroy.
void stupid_app_userspace_ip_stop(stupid_app_userspace_ip *stack);
// Frees the stopped stack and releases singleton ownership. No API call may
// start after destroy; callers must join dial calls first.
void stupid_app_userspace_ip_destroy(stupid_app_userspace_ip *stack);
#endif
