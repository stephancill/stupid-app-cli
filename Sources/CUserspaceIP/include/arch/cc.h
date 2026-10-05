#ifndef STUPID_APP_LWIP_ARCH_H
#define STUPID_APP_LWIP_ARCH_H
#include <stdio.h>
#include <stdlib.h>
#define LWIP_PLATFORM_DIAG(message)                                            \
  do {                                                                         \
    fprintf(stderr, "lwIP: ");                                                 \
    printf message;                                                            \
  } while (0)
#define LWIP_PLATFORM_ASSERT(message)                                          \
  do {                                                                         \
    fprintf(stderr, "lwIP assertion: %s\n", message);                          \
    abort();                                                                   \
  } while (0)
#endif
