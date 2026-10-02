#import "LumaRTSPRoute.h"
#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

// live555 2016.10.21, groupsock/include/GroupsockHelper.hh. This is an
// exported data symbol in the pinned MobileVLCKit binary, not interposition.
extern uint32_t ReceivingInterfaceAddr;

BOOL LumaRTSPLocalIPv4(NSString *host, uint16_t port, uint32_t *address) {
    NSCAssert(![NSThread isMainThread], @"Route lookup must not block the UI");
    *address = INADDR_ANY;
    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    char service[6];
    snprintf(service, sizeof(service), "%u", (unsigned)port);
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host.UTF8String, service, &hints, &addresses) != 0) { return NO; }

    BOOL found = NO;
    for (const struct addrinfo *item = addresses; item != NULL; item = item->ai_next) {
        int socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socketFD < 0) { continue; }
        // UDP connect selects a route; it does not transmit a datagram.
        if (connect(socketFD, item->ai_addr, item->ai_addrlen) == 0) {
            struct sockaddr_in local = {0};
            socklen_t length = sizeof(local);
            if (getsockname(socketFD, (struct sockaddr *)&local, &length) == 0
                && local.sin_family == AF_INET && local.sin_addr.s_addr != INADDR_ANY
                && local.sin_addr.s_addr != INADDR_BROADCAST) {
                *address = local.sin_addr.s_addr;
                found = YES;
            }
        }
        close(socketFD);
        if (found) { break; }
    }
    freeaddrinfo(addresses);
    return found;
}

void LumaSetRTSPReceivingInterface(uint32_t address) {
    NSCAssert(![NSThread isMainThread], @"The SDK queue owns the RTSP interface");
    NSCAssert(address != INADDR_ANY, @"A concrete route address is required");
    ReceivingInterfaceAddr = address;
}
