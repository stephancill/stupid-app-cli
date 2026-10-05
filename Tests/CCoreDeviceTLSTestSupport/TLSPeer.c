#include "CCoreDeviceTLSTestSupport.h"
#include <arpa/inet.h>
#include <errno.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct stupid_app_test_tls_peer {
  int listener;
  int client;
  pthread_t worker;
  pthread_mutex_t mutex;
};

static unsigned provide_test_psk(SSL *ssl, const char *identity,
                                 unsigned char *psk, unsigned maximum) {
  (void)ssl;
  (void)identity;
  if (maximum < 32)
    return 0;
  memset(psk, 7, 32);
  return 32;
}

static int read_exact(SSL *ssl, void *output, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    size_t count = 0;
    ERR_clear_error();
    if (SSL_read_ex(ssl, (char *)output + offset, length - offset, &count) !=
            1 ||
        !count)
      return -1;
    offset += count;
  }
  return 0;
}

static void *serve(void *argument) {
  struct stupid_app_test_tls_peer *peer = argument;
  int client = accept(peer->listener, NULL, NULL);
  if (client < 0)
    return NULL;
  pthread_mutex_lock(&peer->mutex);
  peer->client = client;
  pthread_mutex_unlock(&peer->mutex);
  struct timeval timeout = {.tv_sec = 10};
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef __APPLE__
  int enabled = 1;
  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
  SSL_CTX *context = SSL_CTX_new(TLS_server_method());
  SSL *ssl = NULL;
  if (!context)
    goto finished;
  if (SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_max_proto_version(context, TLS1_2_VERSION) != 1 ||
      SSL_CTX_set_cipher_list(context, "PSK-AES128-GCM-SHA256") != 1)
    goto finished;
  SSL_CTX_set_psk_server_callback(context, provide_test_psk);
  ssl = SSL_new(context);
  if (!ssl || SSL_set_fd(ssl, client) != 1 || SSL_accept(ssl) != 1)
    goto finished;
  unsigned char header[10], body[8192];
  if (read_exact(ssl, header, sizeof(header)) != 0 ||
      memcmp(header, "CDTunnel", 8))
    goto finished;
  size_t length = ((size_t)header[8] << 8) | header[9];
  if (length > sizeof(body) || read_exact(ssl, body, length) != 0)
    goto finished;
  const char response[] =
      "{\"clientParameters\":{\"address\":\"fd00::1\",\"mtu\":1500},"
      "\"serverAddress\":\"fd00::2\",\"serverRSDPort\":6000}";
  unsigned char frame[10 + sizeof(response) - 1];
  memcpy(frame, "CDTunnel", 8);
  frame[8] = (sizeof(response) - 1) >> 8;
  frame[9] = (sizeof(response) - 1) & 255;
  memcpy(frame + 10, response, sizeof(response) - 1);
  size_t count = 0;
  if (SSL_write_ex(ssl, frame, sizeof(frame), &count) != 1 ||
      count != sizeof(frame))
    goto finished;
  // Wait for the relay's outbound packet. Its initial read must return
  // WANT_READ before it can forward this packet, even when its worker starts
  // with stale errors.
  unsigned char packet[60];
  if (read_exact(ssl, packet, sizeof(packet)) != 0)
    goto finished;
  if (SSL_write_ex(ssl, packet, sizeof(packet), &count) != 1 ||
      count != sizeof(packet))
    goto finished;
  SSL_shutdown(
      ssl); // Send close_notify without waiting for the client's reply.
finished:
  if (ssl)
    SSL_free(ssl);
  if (context)
    SSL_CTX_free(context);
  pthread_mutex_lock(&peer->mutex);
  peer->client = -1;
  shutdown(client, SHUT_RDWR);
  close(client);
  pthread_mutex_unlock(&peer->mutex);
  return NULL;
}

int stupid_app_test_tls_peer_create(uint16_t *port,
                                    stupid_app_test_tls_peer **output) {
  struct stupid_app_test_tls_peer *peer = calloc(1, sizeof(*peer));
  if (!peer)
    return ENOMEM;
  peer->client = -1;
  peer->listener = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {.sin_family = AF_INET,
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  socklen_t length = sizeof(address);
  if (peer->listener < 0 ||
      bind(peer->listener, (struct sockaddr *)&address, length) ||
      listen(peer->listener, 1) ||
      getsockname(peer->listener, (struct sockaddr *)&address, &length)) {
    int error = errno;
    if (peer->listener >= 0)
      close(peer->listener);
    free(peer);
    return error;
  }
  pthread_mutex_init(&peer->mutex, NULL);
  int error = pthread_create(&peer->worker, NULL, serve, peer);
  if (error) {
    close(peer->listener);
    pthread_mutex_destroy(&peer->mutex);
    free(peer);
    return error;
  }
  *port = ntohs(address.sin_port);
  *output = peer;
  return 0;
}

void stupid_app_test_tls_peer_destroy(stupid_app_test_tls_peer *peer) {
  if (!peer)
    return;
  pthread_mutex_lock(&peer->mutex);
  if (peer->client >= 0)
    shutdown(peer->client, SHUT_RDWR);
  shutdown(peer->listener, SHUT_RDWR);
  pthread_mutex_unlock(&peer->mutex);
  pthread_join(peer->worker, NULL);
  close(peer->listener);
  pthread_mutex_destroy(&peer->mutex);
  free(peer);
}

int stupid_app_test_tls_seed_error(void) {
  ERR_clear_error();
  SSL_CTX *context = SSL_CTX_new(TLS_client_method());
  if (!context)
    return 0;
  SSL_CTX_set_cipher_list(context, "deliberately-invalid-test-cipher");
  SSL_CTX_free(context);
  return ERR_peek_error() != 0;
}
