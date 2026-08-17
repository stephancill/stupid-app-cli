#ifndef CCOREDEVICETLS_H
#define CCOREDEVICETLS_H

#include <stddef.h>
#include <stdint.h>

enum stupid_app_coredevice_tls_result {
  STUPID_APP_COREDEVICE_TLS_OK = 0,
  STUPID_APP_COREDEVICE_TLS_INVALID_INPUT = 1,
  STUPID_APP_COREDEVICE_TLS_RESOLUTION_FAILED = 2,
  STUPID_APP_COREDEVICE_TLS_CONNECT_FAILED = 3,
  STUPID_APP_COREDEVICE_TLS_CONFIGURATION_FAILED = 4,
  STUPID_APP_COREDEVICE_TLS_HANDSHAKE_FAILED = 5,
  STUPID_APP_COREDEVICE_TLS_WRITE_FAILED = 6,
  STUPID_APP_COREDEVICE_TLS_READ_FAILED = 7,
  STUPID_APP_COREDEVICE_TLS_RESPONSE_TOO_LARGE = 8,
  STUPID_APP_COREDEVICE_TLS_UNEXPECTED_PROTOCOL = 9,
  STUPID_APP_COREDEVICE_TLS_TIMED_OUT = 10,
  STUPID_APP_COREDEVICE_TLS_CANCELLED = 11,
  STUPID_APP_COREDEVICE_TLS_INVALID_RESPONSE = 12,
  STUPID_APP_COREDEVICE_TLS_UNSUPPORTED_OPENSSL = 13,
};

typedef struct stupid_app_coredevice_tls_connection stupid_app_coredevice_tls_connection;

int stupid_app_coredevice_tls_create(
  const char *host,
  uint16_t port,
  const uint8_t *psk,
  size_t psk_length,
  int timeout_milliseconds,
  stupid_app_coredevice_tls_connection **connection
);

int stupid_app_coredevice_tls_start(
  stupid_app_coredevice_tls_connection *connection,
  const uint8_t *request,
  size_t request_length,
  uint8_t *response,
  size_t response_capacity,
  size_t *response_length
);

void stupid_app_coredevice_tls_cancel(stupid_app_coredevice_tls_connection *connection);
void stupid_app_coredevice_tls_destroy(stupid_app_coredevice_tls_connection *connection);
int stupid_app_coredevice_tls_validate_openssl(void);

#endif
