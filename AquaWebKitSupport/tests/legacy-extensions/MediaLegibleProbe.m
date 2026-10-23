#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface MediaLegibleProbe : NSObject <AVPlayerItemLegibleOutputPushDelegate>
@end

@implementation MediaLegibleProbe
- (void)legibleOutput:(AVPlayerItemLegibleOutput *)output didOutputAttributedStrings:(NSArray *)strings nativeSampleBuffers:(NSArray *)buffers forItemTime:(CMTime)time
{
    NSLog(@"CAPTION %f %@", CMTimeGetSeconds(time), strings);
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: MediaLegibleProbe URL [seconds]\n");
            return 2;
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]] options:nil];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        AVPlayerItemLegibleOutput *output = [[AVPlayerItemLegibleOutput alloc] init];
        MediaLegibleProbe *probe = [MediaLegibleProbe new];
        [output setDelegate:probe queue:dispatch_get_main_queue()];
        [item addOutput:output];
        AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
        [asset loadValuesAsynchronouslyForKeys:@[@"availableMediaCharacteristicsWithMediaSelectionOptions"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
                NSLog(@"GROUP %@", group.options);
                if (group.options.count)
                    [item selectMediaOption:group.options[0] inMediaSelectionGroup:group];
                [player play];
            });
        }];
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:argc > 2 ? atof(argv[2]) : 15];
        while ([end timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        NSLog(@"DONE status %ld time %f error %@ log %@", (long)item.status, CMTimeGetSeconds(item.currentTime), item.error, item.errorLog);
        BOOL played = item.status == AVPlayerItemStatusReadyToPlay && CMTimeGetSeconds(item.currentTime) > 0;
        [player pause];
        [asset cancelLoading];
        return played ? 0 : 1;
    }
}
