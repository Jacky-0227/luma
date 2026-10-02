#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
/// Resolves the route's local IPv4 using UDP connect + getsockname, without
/// sending application data. The result stays in memory, in network byte order.
FOUNDATION_EXPORT BOOL LumaRTSPLocalIPv4(NSString *host, uint16_t port, uint32_t *address);
/// Must be called on the SDK queue only while there are zero live RTSP inputs.
/// Requires the exported live555 symbol in pinned MobileVLCKit 3.7.3.
FOUNDATION_EXPORT void LumaSetRTSPReceivingInterface(uint32_t address);
NS_ASSUME_NONNULL_END
