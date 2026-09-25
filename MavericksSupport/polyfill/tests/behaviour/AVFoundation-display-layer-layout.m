#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>

// A sample of a new size enqueued on one thread while the main thread sets the layer's bounds leaves
// the content layer laid out for the final presentation size and bounds once the main queue has run.
// Core Animation posts the bounds change while holding its lock; an observer reading the layer's
// rendering status there does not deadlock against the enqueue.

@interface BoundsObserver : NSObject {
@public
    unsigned notifications;
}
@end
@implementation BoundsObserver
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([object respondsToSelector:@selector(status)])
        (void)[(AVSampleBufferDisplayLayer *)object status];
    ++notifications;
}
@end

static CMSampleBufferRef createSample(size_t width, size_t height)
{
    CVPixelBufferRef buffer = NULL;
    assert(!CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
        (CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &buffer));
    CMVideoFormatDescriptionRef format = NULL;
    assert(!CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &format));
    CMSampleTimingInfo timing = { kCMTimeInvalid, CMTimeMake(1, 30), kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    assert(!CMSampleBufferCreateForImageBuffer(NULL, buffer, YES, NULL, NULL, format, &timing, &sample));
    CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample, YES), 0);
    CFDictionarySetValue(attachments, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFRelease(format);
    CVPixelBufferRelease(buffer);
    return sample;
}

static CALayer *contentLayer(AVSampleBufferDisplayLayer *layer)
{
    id internal = object_getIvar(layer, class_getInstanceVariable([AVSampleBufferDisplayLayer class], "_sampleBufferDisplayLayerInternal"));
    return object_getIvar(internal, class_getInstanceVariable(object_getClass(internal), "contentLayer"));
}

static BOOL sameLayout(CALayer *a, CALayer *b)
{
    return CGRectEqualToRect(a.bounds, b.bounds) && CGPointEqualToPoint(a.position, b.position)
        && CATransform3DEqualToTransform(a.sublayerTransform, b.sublayerTransform) && a.hidden == b.hidden;
}

int main(void)
{
    @autoreleasepool {
        CMSampleBufferRef samples[2] = { createSample(320, 240), createSample(640, 360) };
        CGRect bounds[2] = { CGRectMake(0, 0, 300, 200), CGRectMake(0, 0, 200, 300) };

        // expected[sample][bounds]: the layout for that presentation size and those bounds.
        AVSampleBufferDisplayLayer *expected[2][2];
        for (int s = 0; s < 2; ++s) {
            for (int b = 0; b < 2; ++b) {
                expected[s][b] = [AVSampleBufferDisplayLayer layer];
                [expected[s][b] enqueueSampleBuffer:samples[s]];
                expected[s][b].bounds = bounds[b];
                assert(!contentLayer(expected[s][b]).hidden && !CGRectIsEmpty(contentLayer(expected[s][b]).bounds));
            }
        }
        assert(!sameLayout(contentLayer(expected[0][0]), contentLayer(expected[1][0])));
        assert(!sameLayout(contentLayer(expected[0][0]), contentLayer(expected[0][1])));

        AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
        [layer enqueueSampleBuffer:samples[1]];
        layer.bounds = bounds[1];
        BoundsObserver *observer = [[BoundsObserver alloc] init];
        [layer addObserver:observer forKeyPath:@"bounds" options:0 context:NULL];
        __block volatile int finished = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (finished)
                return;
            printf("display layer layout: deadlocked\n");
            abort();
        });
        dispatch_queue_t queue = dispatch_queue_create("enqueue", DISPATCH_QUEUE_SERIAL);
        const int iterations = 4000;
        int stale = 0;
        for (int i = 0; i < iterations; ++i) {
            @autoreleasepool {
                int s = i % 2;
                int b = (i / 2) % 2;
                CMSampleBufferRef sample = samples[s];
                __block volatile int go = 0;
                int delay = (i / 4) % 64 * 40;
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                [CATransaction begin];
                dispatch_async(queue, ^{
                    while (!go) { }
                    for (volatile int spin = 0; spin < delay; ++spin) { }
                    [layer enqueueSampleBuffer:sample];
                    dispatch_semaphore_signal(done);
                });
                __sync_synchronize();
                go = 1;
                layer.bounds = bounds[b];
                dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
                dispatch_release(done);
                [CATransaction commit];
                while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) == kCFRunLoopRunHandledSource) { }
                if (!sameLayout(contentLayer(layer), contentLayer(expected[s][b])))
                    ++stale;
            }
        }
        finished = 1;
        [layer removeObserver:observer forKeyPath:@"bounds"];
        assert(observer->notifications >= iterations / 2);
        [observer release];
        dispatch_release(queue);
        printf("display layer layout: %d of %d size changes kept a stale content layout\n", stale, iterations);
        assert(!stale);
    }
    return 0;
}
