#import <Foundation/Foundation.h>
@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN
/// VLCKit's snapshot API raises an Objective-C exception if video disappears
/// between checking hasVideoOut and requesting the snapshot. Swift cannot catch it.
FOUNDATION_EXPORT BOOL LumaRequestSnapshot(VLCMediaPlayer *player, NSString *path);
NS_ASSUME_NONNULL_END
