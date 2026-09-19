#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "avf-display-color.h"
#include <assert.h>

@interface DisplayColorTarget : CALayer {
    CGColorSpaceRef _space;
}
- (void)setColorSpace:(CGColorSpaceRef)space;
@end

@implementation DisplayColorTarget
- (void)setColorSpace:(CGColorSpaceRef)space
{
    CGColorSpaceRelease(_space);
    _space = CGColorSpaceRetain(space);
}
- (CGColorSpaceRef)_retainColorSpace { return CGColorSpaceRetain(_space); }
- (void)dealloc { CGColorSpaceRelease(_space); [super dealloc]; }
@end

int main(void)
{
    @autoreleasepool {
        CGColorSpaceRef spaces[] = { CGColorSpaceCreateWithName(kCGColorSpaceSRGB), CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB) };
        const OSType formats[] = { kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB };
        const size_t widths[] = { 7, 17, 320 };
        WKAVFDisplayColor *matcher = [[WKAVFDisplayColor alloc] init];
        DisplayColorTarget *layer = [DisplayColorTarget layer];
        unsigned cases = 0;
        for (unsigned source = 0; source < 2; ++source)
            for (unsigned target = 0; target < 2; ++target)
                for (unsigned format = 0; format < 2; ++format)
                    for (unsigned size = 0; size < 3; ++size)
                        for (unsigned translucent = 0; translucent < 2; ++translucent) {
                            @autoreleasepool {
                                size_t width = widths[size], height = 19;
                                [layer setColorSpace:spaces[target]];
                                CVPixelBufferRef input = NULL;
                                assert(!CVPixelBufferCreate(NULL, width, height, formats[format], NULL, &input));
                                CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, spaces[source], kCVAttachmentMode_ShouldPropagate);
                                CVBufferSetAttachment(input, CFSTR("DisplayColorGeometry"), CFSTR("preserved"), kCVAttachmentMode_ShouldPropagate);
                                assert(!CVPixelBufferLockBaseAddress(input, 0));
                                CGBitmapInfo info;
                                assert(wkAVFRGBBitmapInfo(formats[format], &info));
                                CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(input), width, height, 8,
                                    CVPixelBufferGetBytesPerRow(input), spaces[source], info);
                                assert(context);
                                CGContextSetBlendMode(context, kCGBlendModeCopy);
                                // Every column differs, including across SIMD and row-alignment boundaries.
                                for (size_t y = 0; y < height; ++y)
                                    for (size_t x = 0; x < width; ++x) {
                                        CGContextSetRGBFillColor(context, ((x * 37 + y * 11) % 256) / 255.,
                                            ((x * 19 + y * 43) % 256) / 255., ((x * 71 + y * 7) % 256) / 255.,
                                            translucent ? ((x + y) % 3) / 2. : 1.);
                                        CGContextFillRect(context, CGRectMake(x, y, 1, 1));
                                    }
                                CGImageRef image = CGBitmapContextCreateImage(context);
                                NSData *snapshot = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(input)
                                    length:CVPixelBufferGetBytesPerRow(input) * height];
                                CGContextRelease(context);
                                CVPixelBufferUnlockBaseAddress(input, 0);
                                CMVideoFormatDescriptionRef description = NULL;
                                assert(!CMVideoFormatDescriptionCreateForImageBuffer(NULL, input, &description));
                                CMSampleTimingInfo timing = { CMTimeMake(1, 25), CMTimeMake(3, 2), kCMTimeInvalid };
                                CMSampleBufferRef sample = NULL;
                                assert(!CMSampleBufferCreateForImageBuffer(NULL, input, YES, NULL, NULL, description, &timing, &sample));
                                CMSetAttachment(sample, CFSTR("DisplayColorPrivate"), CFSTR("preserved"), kCMAttachmentMode_ShouldNotPropagate);
                                CFMutableDictionaryRef flags = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample, YES), 0);
                                CFDictionarySetValue(flags, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
                                CMSampleBufferRef matched = [matcher copySample:sample forLayer:layer];
                                assert(matched && ![matcher error]);
                                CVPixelBufferRef output = CMSampleBufferGetImageBuffer(matched);
                                assert(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(matched), timing.presentationTimeStamp) == 0);
                                assert(CMTimeCompare(CMSampleBufferGetDuration(matched), timing.duration) == 0);
                                assert(CFEqual(CMSampleBufferGetSampleAttachmentsArray(matched, NO), CMSampleBufferGetSampleAttachmentsArray(sample, NO)));
                                assert(CFEqual(CMGetAttachment(matched, CFSTR("DisplayColorPrivate"), NULL), CFSTR("preserved")));
                                assert(CFEqual(CVBufferGetAttachment(output, CFSTR("DisplayColorGeometry"), NULL), CFSTR("preserved")));
                                assert(!CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly));
                                CGBitmapInfo outputInfo;
                                assert(wkAVFRGBBitmapInfo(CVPixelBufferGetPixelFormatType(output), &outputInfo));
                                CGContextRef reference = CGBitmapContextCreate(NULL, width, height, 8, width * 4, spaces[target], outputInfo);
                                assert(reference);
                                CGContextDrawImage(reference, CGRectMake(0, 0, width, height), image);
                                const unsigned char *expected = CGBitmapContextGetData(reference);
                                const unsigned char *actual = CVPixelBufferGetBaseAddress(output);
                                unsigned alphaChannel = CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32ARGB ? 0 : 3;
                                // Native color engines round premultiplied channels differently; alpha is unchanged.
                                int colorTolerance = translucent ? 3 : 2;
                                for (size_t y = 0; y < height; ++y)
                                    for (size_t x = 0; x < width * 4; ++x) {
                                        int delta = abs(actual[y * CVPixelBufferGetBytesPerRow(output) + x] - expected[y * width * 4 + x]);
                                        if (delta > (x % 4 == alphaChannel ? 0 : colorTolerance)) {
                                            fprintf(stderr, "source=%u target=%u format=%u width=%zu alpha=%u byte=%zu row=%zu delta=%d\n",
                                                source, target, format, width, translucent, x, y, delta);
                                            return 1;
                                        }
                                    }
                                CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
                                assert(!CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly));
                                assert(!memcmp(snapshot.bytes, CVPixelBufferGetBaseAddress(input), snapshot.length));
                                CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                                CGContextRelease(reference);
                                CGImageRelease(image);
                                CFRelease(matched);
                                CFRelease(sample);
                                CFRelease(description);
                                CVPixelBufferRelease(input);
                                ++cases;
                            }
                        }
        [matcher flushForLayer:layer];
        assert(![matcher error]);
        [matcher release];
        for (unsigned i = 0; i < 2; ++i)
            CGColorSpaceRelease(spaces[i]);
        printf("PASS %u patterned frames: colors, alpha, strides, timing, attachments and source preservation\n", cases);
    }
    return 0;
}
