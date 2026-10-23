#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc != 3 && argc != 4)
            return 2;
        AVPlayerItem* item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]];
        AVPlayerItemVideoOutput* output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [item addOutput:output];
        AVPlayer* player = [AVPlayer playerWithPlayerItem:item];
        unsigned webKitImages = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char* name = _dyld_get_image_name(i);
            if (strstr(name, "/WebKit.framework/") || strstr(name, "/WebCore.framework/") || strstr(name, "/JavaScriptCore.framework/")) {
                ++webKitImages;
                printf("DEPENDENCY %s\n", name);
            }
        }
        printf("NATIVE pid=%d webkitImages=%u\n", getpid(), webKitImages);
        fflush(stdout);
        [player play];
        double end = [NSDate timeIntervalSinceReferenceDate] + atof(argv[2]);
        double next = 0;
        unsigned frames = 0;
        NSUInteger errors = 0;
        while ([NSDate timeIntervalSinceReferenceDate] < end) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            CMTime time = item.currentTime;
            if ([output hasNewPixelBufferForItemTime:time]) {
                CVPixelBufferRef pixels = [output copyPixelBufferForItemTime:time itemTimeForDisplay:NULL];
                if (pixels) { ++frames; CVPixelBufferRelease(pixels); }
            }
            double now = [NSDate timeIntervalSinceReferenceDate];
            if (now < next)
                continue;
            next = now + 5;
            AVPlayerItemAccessLogEvent* access = item.accessLog.events.lastObject;
            AVPlayerItemErrorLogEvent* error = item.errorLog.events.lastObject;
            if (item.errorLog.events.count != errors) {
                errors = item.errorLog.events.count;
                NSString* comment = error.errorComment ?: @"";
                NSRegularExpression* urls = [NSRegularExpression regularExpressionWithPattern:@"https?://[^[:space:]]+" options:0 error:NULL];
                comment = [urls stringByReplacingMatchesInString:comment options:0 range:NSMakeRange(0, comment.length) withTemplate:@"<url>"];
                NSString* kind = [error.URI rangeOfString:@"/manifest/"].location != NSNotFound ? @"playlist" : @"media";
                printf("ERROR domain=%s code=%ld resource=%s comment=%s\n", error.errorDomain.UTF8String, (long)error.errorStatusCode, kind.UTF8String, comment.UTF8String);
                if (argc == 4 && error.URI)
                    [error.URI writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
            printf("OUTPUT time=%.3f frames=%u rate=%.2f status=%ld bufferEmpty=%d keepUp=%d indicated=%.0f observed=%.0f stalls=%ld errors=%lu lastError=%ld itemError=%ld underlying=%ld\n",
                CMTimeGetSeconds(time), frames, player.rate, (long)item.status, item.playbackBufferEmpty, item.playbackLikelyToKeepUp,
                access.indicatedBitrate, access.observedBitrate, (long)access.numberOfStalls, (unsigned long)item.errorLog.events.count, (long)error.errorStatusCode,
                (long)item.error.code, (long)((NSError*)item.error.userInfo[NSUnderlyingErrorKey]).code);
            fflush(stdout);
            frames = 0;
        }
        [player pause];
        [item.asset cancelLoading];
        return item.status == AVPlayerItemStatusFailed ? 1 : 0;
    }
}
