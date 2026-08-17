#include "CCoreDeviceTLS.h"

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
