#import <Foundation/Foundation.h>
@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN
/// Must run on the session's SDK queue, never the main thread. Unlike
/// VLCKit's stop (stop_async), this waits for the input thread to close.
FOUNDATION_EXPORT BOOL LumaStopVLCInput(VLCMediaPlayer *player);
NS_ASSUME_NONNULL_END
