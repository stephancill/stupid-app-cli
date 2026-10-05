#include <stdint.h>

typedef struct stupid_app_test_tls_peer stupid_app_test_tls_peer;
int stupid_app_test_tls_peer_create(uint16_t *port,
                                    stupid_app_test_tls_peer **peer);
void stupid_app_test_tls_peer_destroy(stupid_app_test_tls_peer *peer);
int stupid_app_test_tls_seed_error(void);
