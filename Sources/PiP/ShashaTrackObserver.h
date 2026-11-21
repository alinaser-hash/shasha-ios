#import <Foundation/Foundation.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

/// VLCMediaPlayerDelegate written in Objective-C so that ids VLC may pass as nil reach Swift as optionals (no crash).
/// Reports every track selection change and state change made by the engine.
@interface ShashaTrackObserver : NSObject <VLCMediaPlayerDelegate>
/// type: "audio" / "video" / "text" / "?"; selected / unselected may be nil.
@property (nonatomic, copy, nullable) void (^onTrackSelected)(NSString *type, NSString * _Nullable selected, NSString * _Nullable unselected);
@property (nonatomic, copy, nullable) void (^onTrackAdded)(NSString *type, NSString * _Nullable trackId);
@end

NS_ASSUME_NONNULL_END
