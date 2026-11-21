#import "ShashaPiPView.h"

@implementation ShashaPiPView

- (id<VLCPictureInPictureMediaControlling>)mediaController {
    return self;
}

- (void (^)(id<VLCPictureInPictureWindowControlling>))pictureInPictureReady {
    __weak typeof(self) weakSelf = self;
    return ^(id<VLCPictureInPictureWindowControlling> controller) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.windowController = controller;
            if (s.onReady) s.onReady(controller);
        });
    };
}

- (void)play {
    if (self.onPlay) self.onPlay(); else [self.player play];
}

- (void)pause {
    if (self.onPause) self.onPause(); else [self.player pause];
}

- (void)seekBy:(int64_t)offset completion:(dispatch_block_t)completion {
    if (self.liveStream || ![self.player jumpWithOffset:(int)offset completion:completion]) {
        if (completion) completion();
    }
}

- (int64_t)mediaLength {
    if (self.liveStream) return 0;
    return (int64_t)self.player.media.length.intValue;
}

- (int64_t)mediaTime {
    return (int64_t)self.player.time.intValue;
}

- (BOOL)isMediaSeekable {
    return !self.liveStream && self.player.isSeekable;
}

- (BOOL)isMediaPlaying {
    return self.player.isPlaying;
}

@end
