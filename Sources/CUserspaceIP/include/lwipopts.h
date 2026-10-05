#ifndef STUPID_APP_LWIP_OPTIONS_H
#define STUPID_APP_LWIP_OPTIONS_H
#include <stdio.h>
#define NO_SYS 1
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS 1
#define SYS_LIGHTWEIGHT_PROT 0
#define LWIP_IPV4 0
#define LWIP_ETHERNET 0
#define LWIP_ARP 0
#define LWIP_IPV6 1
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_RAW 0
#define LWIP_DNS 0
#define LWIP_DHCP 0
#define LWIP_AUTOIP 0
#define LWIP_NETCONN 0
#define LWIP_SOCKET 0
#define LWIP_IPV6_MLD 0
#define LWIP_IPV6_AUTOCONFIG 0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT 0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS 0
#define LWIP_IPV6_NUM_ADDRESSES 1
#define IPV6_FRAG_COPYHEADER 1
#define MEM_ALIGNMENT 8
#define MEM_SIZE (8 * 1024 * 1024)
#define MEMP_NUM_TCP_PCB 32
#define MEMP_NUM_TCP_SEG 2048
#define PBUF_POOL_SIZE 1024
#define TCP_MSS 1440
#define TCP_WND 65535
#define LWIP_WND_SCALE 1
#define TCP_RCV_SCALE 3
#define TCP_SND_BUF 65535
#define TCP_SND_QUEUELEN 512
#define LWIP_TCP_SACK_OUT 1
#define LWIP_NETIF_LOOPBACK 0
#define LWIP_STATS 0
#define LWIP_RAND() stupid_app_lwip_random()
#include <stdint.h>
uint32_t stupid_app_lwip_random(void);
#endif
