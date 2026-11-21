#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The view VLC draws into. Conforms to VLCKit 4's picture-in-picture protocols (written in Objective-C so the
/// protocol methods `bounds` / `addSubview:` are satisfied by UIView exactly as VLCKit declares them).
@interface ShashaPiPView : UIView <VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling>

@property (nonatomic, weak, nullable) VLCMediaPlayer *player;
/// Set by VLC once picture in picture can be started for the current video.
@property (nonatomic, strong, nullable) id<VLCPictureInPictureWindowControlling> windowController;
@property (nonatomic, copy, nullable) void (^onReady)(id<VLCPictureInPictureWindowControlling> controller);
/// Play / pause from the floating window go through the app's single play/pause path.
@property (nonatomic, copy, nullable) void (^onPlay)(void);
@property (nonatomic, copy, nullable) void (^onPause)(void);
/// Live channels are not seekable in the floating window.
@property (nonatomic) BOOL liveStream;

@end

NS_ASSUME_NONNULL_END
