#ifndef CLOCKDOWNTLS_H
#define CLOCKDOWNTLS_H

#include <stddef.h>
#include <stdint.h>

enum stupid_app_lockdown_tls_result {
  STUPID_APP_LOCKDOWN_TLS_OK = 0,
  STUPID_APP_LOCKDOWN_TLS_INVALID_INPUT = 1,
  STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED = 2,
  STUPID_APP_LOCKDOWN_TLS_HANDSHAKE_FAILED = 3,
  STUPID_APP_LOCKDOWN_TLS_READ_FAILED = 4,
  STUPID_APP_LOCKDOWN_TLS_WRITE_FAILED = 5,
  STUPID_APP_LOCKDOWN_TLS_TIMED_OUT = 6,
  STUPID_APP_LOCKDOWN_TLS_UNSUPPORTED_OPENSSL = 7,
};

typedef struct stupid_app_lockdown_tls_connection stupid_app_lockdown_tls_connection;
typedef struct stupid_app_lockdown_pairing_material stupid_app_lockdown_pairing_material;

int stupid_app_lockdown_pairing_material_create(
  const uint8_t *device_public_key_pem,
  size_t device_public_key_length,
  stupid_app_lockdown_pairing_material **material
);
const uint8_t *stupid_app_lockdown_pairing_host_certificate(
  const stupid_app_lockdown_pairing_material *material,
  size_t *length
);
const uint8_t *stupid_app_lockdown_pairing_host_private_key(
  const stupid_app_lockdown_pairing_material *material,
  size_t *length
);
const uint8_t *stupid_app_lockdown_pairing_device_certificate(
  const stupid_app_lockdown_pairing_material *material,
  size_t *length
);
const uint8_t *stupid_app_lockdown_pairing_root_certificate(
  const stupid_app_lockdown_pairing_material *material,
  size_t *length
);
const uint8_t *stupid_app_lockdown_pairing_root_private_key(
  const stupid_app_lockdown_pairing_material *material,
  size_t *length
);
void stupid_app_lockdown_pairing_material_destroy(
  stupid_app_lockdown_pairing_material *material
);

int stupid_app_lockdown_tls_create(
  int socket_fd,
  const uint8_t *certificate_pem,
  size_t certificate_length,
  const uint8_t *private_key_pem,
  size_t private_key_length,
  int timeout_milliseconds,
  stupid_app_lockdown_tls_connection **connection
);

int stupid_app_lockdown_tls_read(
  stupid_app_lockdown_tls_connection *connection,
  uint8_t *bytes,
  size_t length
);

int stupid_app_lockdown_tls_write(
  stupid_app_lockdown_tls_connection *connection,
  const uint8_t *bytes,
  size_t length
);

/// Relays IPv6 packets between the TLS tunnel connection and a TUN device using
/// a single thread. OpenSSL forbids concurrent SSL_read and SSL_write, so both
/// directions are serviced by polling the descriptors in one loop. Runs until
/// `*stop` becomes nonzero, the peer closes, or the connection deadline passes.
int stupid_app_lockdown_tls_relay_tun(
  stupid_app_lockdown_tls_connection *connection,
  int tun_fd,
  volatile int *stop
);

void stupid_app_lockdown_tls_cancel(stupid_app_lockdown_tls_connection *connection);

void stupid_app_lockdown_tls_destroy(stupid_app_lockdown_tls_connection *connection);
int stupid_app_lockdown_tls_validate_openssl(void);

#endif
