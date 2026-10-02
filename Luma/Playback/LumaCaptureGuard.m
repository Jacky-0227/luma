#import "LumaCaptureGuard.h"
#import <MobileVLCKit/MobileVLCKit.h>

BOOL LumaRequestSnapshot(VLCMediaPlayer *player, NSString *path) {
    @try {
        if (!player.hasVideoOut) { return NO; }
        [player saveVideoSnapshotAt:path withWidth:0 andHeight:0];
        return YES;
    } @catch (NSException *exception) {
        // SDK exception strings may contain stream details; never expose them.
        return NO;
    }
}
