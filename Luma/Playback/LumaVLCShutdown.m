#import "LumaVLCShutdown.h"
#import <MobileVLCKit/MobileVLCKit.h>

// MobileVLCKit 3.7.3 exposes this selector in VLCLibVLCBridging.h and
// implements it in VLCMediaPlayer.m. The pinned SDK links this libVLC API.
// Keep this small compatibility boundary here rather than exposing a native
// pointer or unsafe Sendable conformance to application code.
@interface VLCMediaPlayer (LumaShutdown)
@property (readonly) void *libVLCMediaPlayer;
@end
extern void libvlc_media_player_stop(void *player);

BOOL LumaStopVLCInput(VLCMediaPlayer *player) {
    NSCAssert(![NSThread isMainThread], @"VLC shutdown must not block the UI");
    if (![player respondsToSelector:@selector(libVLCMediaPlayer)]) { return NO; }
    void *nativePlayer = player.libVLCMediaPlayer;
    if (nativePlayer == NULL) { return NO; }
    libvlc_media_player_stop(nativePlayer);
    return YES;
}
