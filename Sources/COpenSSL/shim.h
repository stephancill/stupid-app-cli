#include <openssl/ssl.h>

#if OPENSSL_VERSION_MAJOR != 3
#error "DeviceKit requires OpenSSL 3.x"
#endif
