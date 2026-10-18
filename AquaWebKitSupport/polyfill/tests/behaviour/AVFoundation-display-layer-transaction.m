#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// A display layer whose samples, flushes and status changes come from a dispatch queue is released by its
// owner on the main thread, and is deallocated there: no transaction left open on the queue's thread
// keeps it alive into a later commit on that thread, where its dealloc would race the main thread's
// commit. When the queue's block has a transaction of its own open, the layer's methods leave it open:
// its completion block is still that transaction's, and has not run, when they return.

static volatile int deallocations;
static volatile int deallocationsOffMain;

@interface TrackedDisplayLayer : AVSampleBufferDisplayLayer
@end
@implementation TrackedDisplayLayer
- (void)dealloc
{
    if (!pthread_main_np())
        __sync_fetch_and_add(&deallocationsOffMain, 1);
    __sync_fetch_and_add(&deallocations, 1);
    [super dealloc];
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

static void drainMainRunLoop(void)
{
    for (int i = 0; i < 20; ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}

int main(void)
{
    @autoreleasepool {
        CMSampleBufferRef sample = createSample(320, 240);
        dispatch_queue_t queue = dispatch_queue_create("enqueue", DISPATCH_QUEUE_SERIAL);
        CALayer *root = [CALayer layer];
        CALayer *unrelated = [CALayer layer];
        const int layers = 48;

        for (int i = 0; i < layers; ++i) {
            TrackedDisplayLayer *layer = [[TrackedDisplayLayer alloc] init];
            layer.bounds = CGRectMake(0, 0, 320, 240);
            [root addSublayer:layer];
            drainMainRunLoop();

            int operation = i % 3;
            BOOL callerTransaction = i >= layers / 2;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(queue, ^{
                assert(!pthread_main_np());
                __block volatile int completed = 0;
                void (^completion)(void) = nil;
                if (callerTransaction) {
                    completion = [^{ completed = 1; } copy];
                    [CATransaction setCompletionBlock:completion];
                    unrelated.opacity = unrelated.opacity == 1 ? 0.5 : 1;
                }
                [layer enqueueSampleBuffer:sample];
                if (operation == 1)
                    [layer flush];
                else if (operation == 2)
                    [layer flushAndRemoveImage];
                if (callerTransaction) {
                    // A committed transaction takes its completion block with it.
                    if (completed || [CATransaction completionBlock] != completion) {
                        printf("display layer transaction: the caller's transaction committed inside the layer's methods\n");
                        abort();
                    }
                    [CATransaction flush];
                    [completion release];
                }
                dispatch_semaphore_signal(done);
            });
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
            // Complete the queue block and its captured references before the owner releases the layer.
            dispatch_sync(queue, ^{ });
            dispatch_release(done);

            [layer removeFromSuperlayer];
            [layer release];
            drainMainRunLoop();
            assert(deallocations == i + 1);
        }

        dispatch_release(queue);
        CFRelease(sample);
        drainMainRunLoop();
        printf("display layer transaction: %d of %d layers deallocated off the main thread\n", deallocationsOffMain, layers);
        assert(deallocations == layers);
        assert(!deallocationsOffMain);
    }
    return 0;
}
