#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "avf-display-color.h"
#include <assert.h>
#include <math.h>

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
        // Y'CbCr decodes with its matrix and range, then is matched from the colour its attachments describe:
        // one colour tagged with two sets of primaries shows two different colours.
        const OSType ycbcrFormats[] = { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8 };
        CFStringRef ycbcrPrimaries[] = { kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferColorPrimaries_SMPTE_C };
        unsigned ycbcrCases = 0;
        [layer setColorSpace:spaces[0]];
        for (unsigned format = 0; format < 3; ++format) {
            uint8_t shown[2][4];
            bool fullRange = ycbcrFormats[format] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
            const uint8_t yValue = 120, cbValue = 110, crValue = 165;
            for (unsigned primaries = 0; primaries < 2; ++primaries) {
                @autoreleasepool {
                    size_t width = 17, height = 9;
                    CVPixelBufferRef input = NULL;
                    assert(!CVPixelBufferCreate(NULL, width, height, ycbcrFormats[format], NULL, &input));
                    assert(!CVPixelBufferLockBaseAddress(input, 0));
                    if (CVPixelBufferIsPlanar(input)) {
                        memset(CVPixelBufferGetBaseAddressOfPlane(input, 0), yValue, CVPixelBufferGetBytesPerRowOfPlane(input, 0) * height);
                        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(input, 1);
                        for (size_t i = 0; i + 1 < CVPixelBufferGetBytesPerRowOfPlane(input, 1) * CVPixelBufferGetHeightOfPlane(input, 1); i += 2) {
                            chroma[i] = cbValue;
                            chroma[i + 1] = crValue;
                        }
                    } else {
                        uint8_t *bytes = CVPixelBufferGetBaseAddress(input);
                        for (size_t i = 0; i + 3 < CVPixelBufferGetBytesPerRow(input) * height; i += 4) {
                            bytes[i] = cbValue;
                            bytes[i + 1] = yValue;
                            bytes[i + 2] = crValue;
                            bytes[i + 3] = yValue;
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(input, 0);
                    CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
                    CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
                    CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey, ycbcrPrimaries[primaries], kCVAttachmentMode_ShouldPropagate);
                    CMVideoFormatDescriptionRef description = NULL;
                    assert(!CMVideoFormatDescriptionCreateForImageBuffer(NULL, input, &description));
                    CMSampleTimingInfo timing = { CMTimeMake(1, 25), CMTimeMake(3, 2), kCMTimeInvalid };
                    CMSampleBufferRef sample = NULL;
                    assert(!CMSampleBufferCreateForImageBuffer(NULL, input, YES, NULL, NULL, description, &timing, &sample));
                    CMSampleBufferRef matched = [matcher copySample:sample forLayer:layer];
                    assert(matched && ![matcher error]);
                    CVPixelBufferRef output = CMSampleBufferGetImageBuffer(matched);
                    assert(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32ARGB);
                    assert(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(matched), timing.presentationTimeStamp) == 0);

                    // The reference: the BT.709 decode of the same samples, matched by CoreGraphics.
                    double l = fullRange ? yValue / 255. : (yValue - 16) / 219.;
                    double u = fullRange ? (cbValue - 128) / 255. : (cbValue - 128) / 224.;
                    double v = fullRange ? (crValue - 128) / 255. : (crValue - 128) / 224.;
                    double rgb[3] = { l + 1.5748 * v, l - 0.1873 * u - 0.4681 * v, l + 1.8556 * u };
                    uint8_t decoded[4] = { 255 };
                    for (int c = 0; c < 3; ++c)
                        decoded[c + 1] = (uint8_t)lround(fmin(fmax(rgb[c], 0), 1) * 255);
                    CGColorSpaceRef described = CVImageBufferCreateColorSpaceFromAttachments(CVBufferGetAttachments(input, kCVAttachmentMode_ShouldPropagate));
                    assert(described);
                    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, decoded, 4, NULL);
                    CGImageRef reference = CGImageCreate(1, 1, 8, 32, 4, described, kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst, provider, NULL, false, kCGRenderingIntentDefault);
                    uint8_t expected[4] = { 0 };
                    CGContextRef context = CGBitmapContextCreate(expected, 1, 1, 8, 4, spaces[0], kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst);
                    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), reference);
                    assert(!CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly));
                    const uint8_t *actual = CVPixelBufferGetBaseAddress(output);
                    for (size_t y = 0; y < height; ++y)
                        for (size_t x = 0; x < width; ++x)
                            for (int c = 0; c < 4; ++c) {
                                int delta = abs(actual[y * CVPixelBufferGetBytesPerRow(output) + x * 4 + c] - expected[c]);
                                if (delta > (c ? 2 : 0)) {
                                    fprintf(stderr, "ycbcr format=%u primaries=%u x=%zu y=%zu channel=%d delta=%d\n", format, primaries, x, y, c, delta);
                                    return 1;
                                }
                            }
                    memcpy(shown[primaries], actual, 4);
                    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
                    CGContextRelease(context);
                    CGImageRelease(reference);
                    CGDataProviderRelease(provider);
                    CGColorSpaceRelease(described);
                    CFRelease(matched);
                    CFRelease(sample);
                    CFRelease(description);
                    CVPixelBufferRelease(input);
                    ++ycbcrCases;
                }
            }
            assert(memcmp(shown[0], shown[1], 4));
        }
        printf("PASS %u Y'CbCr frames: matrix, range, packing and primaries\n", ycbcrCases);

        [matcher flushForLayer:layer];
        assert(![matcher error]);
        [matcher release];
        for (unsigned i = 0; i < 2; ++i)
            CGColorSpaceRelease(spaces[i]);
        printf("PASS %u patterned frames: colors, alpha, strides, timing, attachments and source preservation\n", cases);
    }
    return 0;
}
