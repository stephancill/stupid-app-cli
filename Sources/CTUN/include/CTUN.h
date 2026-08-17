#ifndef CTUN_H
#define CTUN_H

#include <stdint.h>
#include <stddef.h>

enum stupid_app_tun_result {
  STUPID_APP_TUN_OK = 0,
  STUPID_APP_TUN_INVALID_INPUT = 1,
  STUPID_APP_TUN_OPEN_FAILED = 2,
  STUPID_APP_TUN_CONFIGURATION_FAILED = 3,
  STUPID_APP_TUN_READ_FAILED = 4,
  STUPID_APP_TUN_WRITE_FAILED = 5,
  STUPID_APP_TUN_UNSUPPORTED = 6,
};

typedef struct stupid_app_tun_device stupid_app_tun_device;

/// Opens and configures a Linux TUN device with the given name (or an assigned
/// name when `name` is empty). The device is brought up and assigned the given
/// IPv6 address and MTU. Returns a handle that owns the descriptor.
int stupid_app_tun_create(
  const char *name,
  const char *ipv6_address,
  int mtu,
  stupid_app_tun_device **output
);

/// Returns the assigned interface name into the provided buffer.
int stupid_app_tun_name(
  const stupid_app_tun_device *device,
  char *buffer,
  size_t capacity
);

/// Adds an IPv6 host route for `destination` through the device's interface.
int stupid_app_tun_add_route(
  stupid_app_tun_device *device,
  const char *destination
);

/// Reads one IPv6 packet into the provided buffer. Returns the number of bytes
/// read, or a negative error code.
int stupid_app_tun_read(
  stupid_app_tun_device *device,
  uint8_t *buffer,
  size_t capacity
);

/// Writes one IPv6 packet to the device.
int stupid_app_tun_write(
  stupid_app_tun_device *device,
  const uint8_t *bytes,
  size_t length
);

void stupid_app_tun_destroy(stupid_app_tun_device *device);

#endif
