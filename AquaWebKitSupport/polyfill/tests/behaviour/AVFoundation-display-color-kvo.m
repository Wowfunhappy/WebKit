#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>

// A CMYK destination cannot be represented by the display layer's packed BGRA output.
@interface UnsupportedDisplayColor : AVSampleBufferDisplayLayer
@end
@implementation UnsupportedDisplayColor
- (CGColorSpaceRef)_retainColorSpace { return CGColorSpaceCreateDeviceCMYK(); }
@end

@interface DisplayColorObserver : NSObject {
@public
    unsigned renderingStatus;
    unsigned initialStatus;
    unsigned initialError;
    unsigned priorStatus;
    unsigned priorError;
    unsigned failedStatus;
    unsigned failedError;
    unsigned clearedStatus;
    unsigned clearedError;
}
@end
@implementation DisplayColorObserver
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    AVSampleBufferDisplayLayer *observed = object;
    assert(context == self);
    assert((observed.status == AVQueuedSampleBufferRenderingStatusFailed) == (observed.error != nil));
    BOOL isStatus = [key isEqualToString:@"status"];
    id old = [change objectForKey:NSKeyValueChangeOldKey];
    if ([[change objectForKey:NSKeyValueChangeNotificationIsPriorKey] boolValue]) {
        assert(![change objectForKey:NSKeyValueChangeNewKey]);
        assert([old isEqual:([object valueForKey:key] ?: [NSNull null])]);
        if (isStatus)
            ++priorStatus;
        else
            ++priorError;
        return;
    }
    if (!old) {
        if (isStatus)
            ++initialStatus;
        else
            ++initialError;
    }
    id value = [change objectForKey:NSKeyValueChangeNewKey];
    if ([key isEqualToString:@"status"]) {
        assert([value isKindOfClass:[NSNumber class]]);
        assert([value integerValue] == observed.status);
        if ([value integerValue] == AVQueuedSampleBufferRenderingStatusFailed)
            ++failedStatus;
        else if ([value integerValue] == AVQueuedSampleBufferRenderingStatusUnknown)
            ++clearedStatus;
        else if ([value integerValue] == AVQueuedSampleBufferRenderingStatusRendering)
            ++renderingStatus;
    } else {
        assert([key isEqualToString:@"error"]);
        if (value == [NSNull null]) {
            assert(!observed.error);
            ++clearedError;
        } else {
            assert([value isKindOfClass:[NSError class]]);
            assert([[value domain] isEqualToString:NSOSStatusErrorDomain]);
            assert([value isEqual:observed.error]);
            ++failedError;
        }
    }
}
@end

int main(void)
{
    @autoreleasepool {
        UnsupportedDisplayColor *layer = [UnsupportedDisplayColor layer];
        DisplayColorObserver *observer = [[[DisplayColorObserver alloc] init] autorelease];
        [layer addObserver:observer forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionPrior context:observer];
        [layer addObserver:observer forKeyPath:@"error" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionPrior context:observer];
        assert(layer.status == AVQueuedSampleBufferRenderingStatusUnknown && !layer.error);
        assert([[layer valueForKey:@"status"] isEqual:@0]);
        assert(![layer valueForKey:@"error"]);
        assert(observer->initialStatus == 1 && observer->initialError == 1);
        CVPixelBufferRef buffer = NULL;
        assert(!CVPixelBufferCreate(NULL, 4, 4, kCVPixelFormatType_32BGRA, (CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &buffer));
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRelease(space);
        CMVideoFormatDescriptionRef format = NULL;
        assert(!CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &format));
        CMSampleTimingInfo timing = { CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid };
        CMSampleBufferRef sample = NULL;
        assert(!CMSampleBufferCreateForImageBuffer(NULL, buffer, YES, NULL, NULL, format, &timing, &sample));
        for (unsigned removeImage = 0; removeImage < 2; ++removeImage) {
            observer->failedStatus = observer->failedError = observer->clearedStatus = observer->clearedError = 0;
            [layer enqueueSampleBuffer:sample];
            assert(layer.status == AVQueuedSampleBufferRenderingStatusFailed && layer.error);
            assert(observer->failedStatus == 1 && observer->failedError == 1);
            NSError *failure = [[layer.error retain] autorelease];
            [layer enqueueSampleBuffer:sample];
            assert(layer.error == failure);
            assert(observer->failedStatus == 1 && observer->failedError == 1);
            if (removeImage)
                [layer flushAndRemoveImage];
            else
                [layer flush];
            assert(layer.status == AVQueuedSampleBufferRenderingStatusUnknown && !layer.error);
            assert(observer->clearedStatus == 1 && observer->clearedError == 1);
            [layer flush];
            assert(observer->clearedStatus == 1 && observer->clearedError == 1);
        }
        assert(observer->priorStatus == 4 && observer->priorError == 4);
        [layer removeObserver:observer forKeyPath:@"status"];
        [layer removeObserver:observer forKeyPath:@"error"];
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 64, 64)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        AVSampleBufferDisplayLayer *native = [AVSampleBufferDisplayLayer layer];
        [[window contentView] setWantsLayer:YES];
        [[window contentView] setLayer:native];
        [window makeKeyAndOrderFront:nil];
        DisplayColorObserver *nativeObserver = [[[DisplayColorObserver alloc] init] autorelease];
        NSKeyValueObservingOptions options = NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionPrior;
        [native addObserver:nativeObserver forKeyPath:@"status" options:options context:nativeObserver];
        [native addObserver:nativeObserver forKeyPath:@"error" options:options context:nativeObserver];
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
            kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        [native enqueueSampleBuffer:sample];
        assert(native.status == AVQueuedSampleBufferRenderingStatusRendering && !native.error);
        assert(nativeObserver->renderingStatus == 1);

        [native removeObserver:nativeObserver forKeyPath:@"status"];
        [native removeObserver:nativeObserver forKeyPath:@"error"];
        [native flushAndRemoveImage];
        [window orderOut:nil];
        [window release];
        CFRelease(sample);
        CFRelease(format);
        CVPixelBufferRelease(buffer);
        puts("PASS status/error KVO initial/prior/old/new, conversion failure, rendering, and flush recovery");
    }
}
