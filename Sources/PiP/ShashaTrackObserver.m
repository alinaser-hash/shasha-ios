#import "ShashaTrackObserver.h"

static NSString *TypeName(VLCMediaTrackType t) {
    switch (t) {
        case VLCMediaTrackTypeAudio: return @"audio";
        case VLCMediaTrackTypeVideo: return @"video";
        case VLCMediaTrackTypeText: return @"text";
        default: return @"?";
    }
}

@implementation ShashaTrackObserver

- (void)mediaPlayerTrackSelected:(VLCMediaTrackType)trackType selectedId:(NSString *)selectedId unselectedId:(NSString *)unselectedId {
    NSString *s = [selectedId isKindOfClass:[NSString class]] ? selectedId : nil;
    NSString *u = [unselectedId isKindOfClass:[NSString class]] ? unselectedId : nil;
    if (self.onTrackSelected) self.onTrackSelected(TypeName(trackType), s, u);
}

- (void)mediaPlayerTrackAdded:(NSString *)trackId withType:(VLCMediaTrackType)trackType {
    NSString *t = [trackId isKindOfClass:[NSString class]] ? trackId : nil;
    if (self.onTrackAdded) self.onTrackAdded(TypeName(trackType), t);
}

@end
