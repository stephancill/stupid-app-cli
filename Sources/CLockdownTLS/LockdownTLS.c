#include "CLockdownTLS.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct stupid_app_lockdown_tls_connection {
  SSL_CTX *context;
  SSL *ssl;
  int socket_fd;
  int timeout_milliseconds;
  pthread_mutex_t socket_mutex;
};

struct stupid_app_lockdown_pairing_material {
  uint8_t *host_certificate;
  size_t host_certificate_length;
  uint8_t *host_private_key;
  size_t host_private_key_length;
  uint8_t *device_certificate;
  size_t device_certificate_length;
  uint8_t *root_certificate;
  size_t root_certificate_length;
  uint8_t *root_private_key;
  size_t root_private_key_length;
};

static int add_certificate_extension(X509 *certificate, int nid, const char *value) {
  X509V3_CTX context;
  X509V3_set_ctx_nodb(&context);
  X509V3_set_ctx(&context, certificate, certificate, NULL, NULL, 0);
  X509_EXTENSION *extension = X509V3_EXT_conf_nid(NULL, &context, nid, value);
  if (extension == NULL) return 0;
  int result = X509_add_ext(certificate, extension, -1);
  X509_EXTENSION_free(extension);
  return result == 1;
}

static int configure_certificate(
  X509 *certificate,
  EVP_PKEY *public_key,
  EVP_PKEY *issuer_key,
  int is_root,
  int is_device
) {
  if (certificate == NULL || public_key == NULL || issuer_key == NULL ||
      X509_set_version(certificate, 2) != 1 ||
      ASN1_INTEGER_set(X509_get_serialNumber(certificate), 0) != 1 ||
      X509_gmtime_adj(X509_getm_notBefore(certificate), 0) == NULL ||
      X509_gmtime_adj(X509_getm_notAfter(certificate), 60L * 60L * 24L * 365L * 10L) == NULL ||
      X509_set_pubkey(certificate, public_key) != 1 ||
      !add_certificate_extension(
        certificate,
        NID_basic_constraints,
        is_root ? "critical,CA:TRUE" : "critical,CA:FALSE"
      )) {
    return 0;
  }
  if (!is_root && is_device &&
      !add_certificate_extension(certificate, NID_subject_key_identifier, "hash")) {
    return 0;
  }
  if (!is_root &&
      !add_certificate_extension(
        certificate,
        NID_key_usage,
        "critical,digitalSignature,keyEncipherment"
      )) {
    return 0;
  }
  return X509_sign(certificate, issuer_key, EVP_sha256()) > 0;
}

static int copy_bio(BIO *bio, uint8_t **output, size_t *output_length) {
  char *bytes = NULL;
  long length = BIO_get_mem_data(bio, &bytes);
  if (length <= 0 || bytes == NULL || output == NULL || output_length == NULL) return 0;
  *output = malloc((size_t)length);
  if (*output == NULL) return 0;
  memcpy(*output, bytes, (size_t)length);
  *output_length = (size_t)length;
  return 1;
}

static int serialize_certificate(X509 *certificate, uint8_t **output, size_t *output_length) {
  BIO *bio = BIO_new(BIO_s_mem());
  int result = bio != NULL && PEM_write_bio_X509(bio, certificate) == 1 &&
    copy_bio(bio, output, output_length);
  if (bio != NULL) BIO_free(bio);
  return result;
}

static int serialize_private_key(EVP_PKEY *key, uint8_t **output, size_t *output_length) {
  BIO *bio = BIO_new(BIO_s_mem());
  int result = bio != NULL && PEM_write_bio_PrivateKey(bio, key, NULL, NULL, 0, NULL, NULL) == 1 &&
    copy_bio(bio, output, output_length);
  if (bio != NULL) BIO_free(bio);
  return result;
}

int stupid_app_lockdown_pairing_material_create(
  const uint8_t *device_public_key_pem,
  size_t device_public_key_length,
  stupid_app_lockdown_pairing_material **output
) {
  if (device_public_key_pem == NULL || device_public_key_length == 0 ||
      device_public_key_length > INT_MAX || output == NULL ||
      stupid_app_lockdown_tls_validate_openssl() != STUPID_APP_LOCKDOWN_TLS_OK) {
    return STUPID_APP_LOCKDOWN_TLS_INVALID_INPUT;
  }
  *output = NULL;
  BIO *device_bio = BIO_new_mem_buf(device_public_key_pem, (int)device_public_key_length);
  EVP_PKEY *device_key = device_bio == NULL ? NULL : PEM_read_bio_PUBKEY(device_bio, NULL, NULL, NULL);
  EVP_PKEY *root_key = EVP_RSA_gen(2048);
  EVP_PKEY *host_key = EVP_RSA_gen(2048);
  X509 *root_certificate = X509_new();
  X509 *host_certificate = X509_new();
  X509 *device_certificate = X509_new();
  stupid_app_lockdown_pairing_material *material = calloc(1, sizeof(*material));
  int valid = device_key != NULL && root_key != NULL && host_key != NULL &&
    material != NULL &&
    configure_certificate(root_certificate, root_key, root_key, 1, 0) &&
    configure_certificate(host_certificate, host_key, root_key, 0, 0) &&
    configure_certificate(device_certificate, device_key, root_key, 0, 1) &&
    serialize_certificate(
      host_certificate,
      &material->host_certificate,
      &material->host_certificate_length
    ) &&
    serialize_private_key(
      host_key,
      &material->host_private_key,
      &material->host_private_key_length
    ) &&
    serialize_certificate(
      device_certificate,
      &material->device_certificate,
      &material->device_certificate_length
    ) &&
    serialize_certificate(
      root_certificate,
      &material->root_certificate,
      &material->root_certificate_length
    ) &&
    serialize_private_key(
      root_key,
      &material->root_private_key,
      &material->root_private_key_length
    );
  if (device_bio != NULL) BIO_free(device_bio);
  if (device_key != NULL) EVP_PKEY_free(device_key);
  if (root_key != NULL) EVP_PKEY_free(root_key);
  if (host_key != NULL) EVP_PKEY_free(host_key);
  if (root_certificate != NULL) X509_free(root_certificate);
  if (host_certificate != NULL) X509_free(host_certificate);
  if (device_certificate != NULL) X509_free(device_certificate);
  if (!valid) {
    stupid_app_lockdown_pairing_material_destroy(material);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  *output = material;
  return STUPID_APP_LOCKDOWN_TLS_OK;
}

#define PAIRING_ACCESSOR(name) \
const uint8_t *stupid_app_lockdown_pairing_##name( \
  const stupid_app_lockdown_pairing_material *material, \
  size_t *length \
) { \
  if (material == NULL || length == NULL) return NULL; \
  *length = material->name##_length; \
  return material->name; \
}

PAIRING_ACCESSOR(host_certificate)
PAIRING_ACCESSOR(host_private_key)
PAIRING_ACCESSOR(device_certificate)
PAIRING_ACCESSOR(root_certificate)
PAIRING_ACCESSOR(root_private_key)

void stupid_app_lockdown_pairing_material_destroy(
  stupid_app_lockdown_pairing_material *material
) {
  if (material == NULL) return;
  if (material->host_private_key != NULL) {
    OPENSSL_cleanse(material->host_private_key, material->host_private_key_length);
  }
  if (material->root_private_key != NULL) {
    OPENSSL_cleanse(material->root_private_key, material->root_private_key_length);
  }
  free(material->host_certificate);
  free(material->host_private_key);
  free(material->device_certificate);
  free(material->root_certificate);
  free(material->root_private_key);
  free(material);
}

static int block_sigpipe(sigset_t *blocked, sigset_t *previous) {
  sigemptyset(blocked);
  sigaddset(blocked, SIGPIPE);
  return pthread_sigmask(SIG_BLOCK, blocked, previous) == 0;
}

static void restore_sigpipe(const sigset_t *blocked, const sigset_t *previous) {
  if (sigismember(previous, SIGPIPE) == 0) {
    sigset_t pending;
    if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 1) {
      int received = 0;
      sigwait(blocked, &received);
    }
  }
  pthread_sigmask(SIG_SETMASK, previous, NULL);
}

static int64_t monotonic_milliseconds(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
    return -1;
  }
  return ((int64_t)value.tv_sec * 1000) + (value.tv_nsec / 1000000);
}

static int wait_for_socket(int socket_fd, short events, int64_t deadline) {
  while (1) {
    int64_t now = monotonic_milliseconds();
    if (now < 0 || now >= deadline) {
      return STUPID_APP_LOCKDOWN_TLS_TIMED_OUT;
    }
    int remaining = (int)(deadline - now);
    struct pollfd descriptor = {.fd = socket_fd, .events = events};
    int result = poll(&descriptor, 1, remaining);
    if (result > 0) {
      return STUPID_APP_LOCKDOWN_TLS_OK;
    }
    if (result == 0) {
      return STUPID_APP_LOCKDOWN_TLS_TIMED_OUT;
    }
    if (errno != EINTR) {
      return STUPID_APP_LOCKDOWN_TLS_HANDSHAKE_FAILED;
    }
  }
}

static int wait_for_ssl(
  stupid_app_lockdown_tls_connection *connection,
  int operation_result,
  int64_t deadline,
  int failure
) {
  int error = SSL_get_error(connection->ssl, operation_result);
  if (error == SSL_ERROR_WANT_READ) {
    return wait_for_socket(connection->socket_fd, POLLIN, deadline);
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return wait_for_socket(connection->socket_fd, POLLOUT, deadline);
  }
  return failure;
}

static int deadline(stupid_app_lockdown_tls_connection *connection, int64_t *result) {
  int64_t now = monotonic_milliseconds();
  if (now < 0 || connection->timeout_milliseconds > INT64_MAX - now) {
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  *result = now + connection->timeout_milliseconds;
  return STUPID_APP_LOCKDOWN_TLS_OK;
}

int stupid_app_lockdown_tls_validate_openssl(void) {
  return OPENSSL_version_major() == 3
    ? STUPID_APP_LOCKDOWN_TLS_OK
    : STUPID_APP_LOCKDOWN_TLS_UNSUPPORTED_OPENSSL;
}

static int create_connection(
  int socket_fd,
  const uint8_t *certificate_pem,
  size_t certificate_length,
  const uint8_t *private_key_pem,
  size_t private_key_length,
  int timeout_milliseconds,
  stupid_app_lockdown_tls_connection **output
) {
  if (socket_fd < 0 || certificate_pem == NULL || certificate_length == 0 ||
      certificate_length > INT_MAX || private_key_pem == NULL || private_key_length == 0 ||
      private_key_length > INT_MAX || timeout_milliseconds <= 0 || output == NULL) {
    if (socket_fd >= 0) close(socket_fd);
    return STUPID_APP_LOCKDOWN_TLS_INVALID_INPUT;
  }
  if (stupid_app_lockdown_tls_validate_openssl() != STUPID_APP_LOCKDOWN_TLS_OK) {
    close(socket_fd);
    return STUPID_APP_LOCKDOWN_TLS_UNSUPPORTED_OPENSSL;
  }

  stupid_app_lockdown_tls_connection *connection = calloc(1, sizeof(*connection));
  if (connection == NULL) {
    close(socket_fd);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  if (pthread_mutex_init(&connection->socket_mutex, NULL) != 0) {
    free(connection);
    close(socket_fd);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  connection->socket_fd = socket_fd;
  connection->timeout_milliseconds = timeout_milliseconds;
  connection->context = SSL_CTX_new(TLS_client_method());
  BIO *certificate_bio = BIO_new_mem_buf(certificate_pem, (int)certificate_length);
  BIO *private_key_bio = BIO_new_mem_buf(private_key_pem, (int)private_key_length);
  X509 *certificate = certificate_bio == NULL ? NULL : PEM_read_bio_X509(certificate_bio, NULL, NULL, NULL);
  EVP_PKEY *private_key = private_key_bio == NULL
    ? NULL
    : PEM_read_bio_PrivateKey(private_key_bio, NULL, NULL, NULL);

  int configured = connection->context != NULL && certificate != NULL && private_key != NULL &&
    SSL_CTX_set_min_proto_version(connection->context, TLS1_2_VERSION) == 1 &&
    SSL_CTX_set_max_proto_version(connection->context, TLS1_3_VERSION) == 1 &&
    SSL_CTX_set_cipher_list(connection->context, "ALL:!aNULL:!eNULL:@SECLEVEL=0") == 1 &&
    SSL_CTX_use_certificate(connection->context, certificate) == 1 &&
    SSL_CTX_use_PrivateKey(connection->context, private_key) == 1 &&
    SSL_CTX_check_private_key(connection->context) == 1;
  if (certificate != NULL) X509_free(certificate);
  if (private_key != NULL) EVP_PKEY_free(private_key);
  if (certificate_bio != NULL) BIO_free(certificate_bio);
  if (private_key_bio != NULL) BIO_free(private_key_bio);
  if (!configured) {
    stupid_app_lockdown_tls_destroy(connection);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }

  SSL_CTX_set_verify(connection->context, SSL_VERIFY_NONE, NULL);
  connection->ssl = SSL_new(connection->context);
  int flags = fcntl(socket_fd, F_GETFL, 0);
  if (connection->ssl == NULL || flags < 0 ||
      fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) < 0 || SSL_set_fd(connection->ssl, socket_fd) != 1) {
    stupid_app_lockdown_tls_destroy(connection);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }

  int64_t operation_deadline;
  int result = deadline(connection, &operation_deadline);
  while (result == STUPID_APP_LOCKDOWN_TLS_OK) {
    int operation_result = SSL_connect(connection->ssl);
    if (operation_result == 1) {
      *output = connection;
      return STUPID_APP_LOCKDOWN_TLS_OK;
    }
    result = wait_for_ssl(
      connection,
      operation_result,
      operation_deadline,
      STUPID_APP_LOCKDOWN_TLS_HANDSHAKE_FAILED
    );
  }
  stupid_app_lockdown_tls_destroy(connection);
  return result;
}

static int read_connection(
  stupid_app_lockdown_tls_connection *connection,
  uint8_t *bytes,
  size_t length
) {
  if (connection == NULL || bytes == NULL) return STUPID_APP_LOCKDOWN_TLS_INVALID_INPUT;
  int64_t operation_deadline;
  int result = deadline(connection, &operation_deadline);
  size_t offset = 0;
  while (result == STUPID_APP_LOCKDOWN_TLS_OK && offset < length) {
    size_t received = 0;
    int operation_result = SSL_read_ex(connection->ssl, bytes + offset, length - offset, &received);
    if (operation_result == 1 && received > 0) {
      offset += received;
    } else {
      result = wait_for_ssl(connection, operation_result, operation_deadline, STUPID_APP_LOCKDOWN_TLS_READ_FAILED);
    }
  }
  return result;
}

static int write_connection(
  stupid_app_lockdown_tls_connection *connection,
  const uint8_t *bytes,
  size_t length
) {
  if (connection == NULL || bytes == NULL) return STUPID_APP_LOCKDOWN_TLS_INVALID_INPUT;
  int64_t operation_deadline;
  int result = deadline(connection, &operation_deadline);
  size_t offset = 0;
  while (result == STUPID_APP_LOCKDOWN_TLS_OK && offset < length) {
    size_t written = 0;
    int operation_result = SSL_write_ex(connection->ssl, bytes + offset, length - offset, &written);
    if (operation_result == 1 && written > 0) {
      offset += written;
    } else {
      result = wait_for_ssl(connection, operation_result, operation_deadline, STUPID_APP_LOCKDOWN_TLS_WRITE_FAILED);
    }
  }
  return result;
}

int stupid_app_lockdown_tls_create(
  int socket_fd,
  const uint8_t *certificate_pem,
  size_t certificate_length,
  const uint8_t *private_key_pem,
  size_t private_key_length,
  int timeout_milliseconds,
  stupid_app_lockdown_tls_connection **output
) {
  sigset_t blocked;
  sigset_t previous;
  if (!block_sigpipe(&blocked, &previous)) {
    if (socket_fd >= 0) close(socket_fd);
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  int result = create_connection(
    socket_fd,
    certificate_pem,
    certificate_length,
    private_key_pem,
    private_key_length,
    timeout_milliseconds,
    output
  );
  restore_sigpipe(&blocked, &previous);
  return result;
}

int stupid_app_lockdown_tls_read(
  stupid_app_lockdown_tls_connection *connection,
  uint8_t *bytes,
  size_t length
) {
  sigset_t blocked;
  sigset_t previous;
  if (!block_sigpipe(&blocked, &previous)) {
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  int result = read_connection(connection, bytes, length);
  restore_sigpipe(&blocked, &previous);
  return result;
}

int stupid_app_lockdown_tls_write(
  stupid_app_lockdown_tls_connection *connection,
  const uint8_t *bytes,
  size_t length
) {
  sigset_t blocked;
  sigset_t previous;
  if (!block_sigpipe(&blocked, &previous)) {
    return STUPID_APP_LOCKDOWN_TLS_CONFIGURATION_FAILED;
  }
  int result = write_connection(connection, bytes, length);
  restore_sigpipe(&blocked, &previous);
  return result;
}

void stupid_app_lockdown_tls_cancel(stupid_app_lockdown_tls_connection *connection) {
  if (connection == NULL) {
    return;
  }
  pthread_mutex_lock(&connection->socket_mutex);
  int socket_fd = connection->socket_fd;
  if (socket_fd >= 0) {
    shutdown(socket_fd, SHUT_RDWR);
  }
  pthread_mutex_unlock(&connection->socket_mutex);
}

void stupid_app_lockdown_tls_destroy(stupid_app_lockdown_tls_connection *connection) {
  if (connection == NULL) return;
  if (connection->ssl != NULL) {
    SSL_free(connection->ssl);
    connection->ssl = NULL;
  }
  if (connection->context != NULL) {
    SSL_CTX_free(connection->context);
    connection->context = NULL;
  }
  pthread_mutex_lock(&connection->socket_mutex);
  int socket_fd = connection->socket_fd;
  connection->socket_fd = -1;
  if (socket_fd >= 0) {
    close(socket_fd);
  }
  pthread_mutex_unlock(&connection->socket_mutex);
  pthread_mutex_destroy(&connection->socket_mutex);
  free(connection);
}
