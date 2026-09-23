#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <ImageIO/ImageIO.h>
#include <IOSurface/IOSurface.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
extern bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef, CGColorSpaceRef);
extern const CFStringRef kCGImageAuxiliaryDataInfoMetadata;
extern const CFStringRef kCGTargetColorSpace;
extern const CFStringRef kCGTargetHeadroom;
extern const CFStringRef kIOSurfaceContentHeadroom;
extern const CFStringRef kCGTargetPixelFormat;
extern CGFloat CGImageGetHDRGainMapHeadroom(CGImageMetadataRef, CFDictionaryRef);
extern OSStatus CGImageApplyHDRGainMap(CVPixelBufferRef, CVPixelBufferRef, CVPixelBufferRef, CFDictionaryRef);
extern OSStatus CGImageCreatePixelBufferAttributesForHDRTarget(uint32_t, CFDictionaryRef, CFDictionaryRef, CFDictionaryRef*);
extern CGImageRef CGImageCreateFromIOSurface(IOSurfaceRef, CFDictionaryRef);

static CGImageMetadataRef metadataWithElements(NSString *properties, NSString *elements)
{
    NSString *xmp = [NSString stringWithFormat:@"<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:HDRGainMap='http://ns.apple.com/HDRGainMap/1.0/' xmlns:hdrgm='http://ns.adobe.com/hdr-gain-map/1.0/' %@>%@</rdf:Description></rdf:RDF></x:xmpmeta>", properties, elements];
    CGImageMetadataRef result = CGImageMetadataCreateFromXMPData((CFDataRef)[xmp dataUsingEncoding:NSUTF8StringEncoding]);
    assert(result);
    return result;
}

static CGImageMetadataRef metadata(NSString *properties)
{
    return metadataWithElements(properties, @"");
}

static CVPixelBufferRef buffer(OSType format, CGColorSpaceRef space)
{
    CVPixelBufferRef result = NULL;
    assert(CVPixelBufferCreate(NULL, 2, 1, format, (CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &result) == 0);
    if (space)
        CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
    return result;
}

static void checkUniform(const char *label, CGImageMetadataRef info, CGColorSpaceRef sourceSpace, CGColorSpaceRef targetSpace,
    float value, float expected, size_t width, size_t height, double targetHeadroom, bool surface)
{
    CVPixelBufferRef input = NULL, gain = NULL, output = NULL;
    CFDictionaryRef attributes = surface ? (CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}} : NULL;
    assert(CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_128RGBAFloat, attributes, &input) == 0);
    assert(CVPixelBufferCreate(NULL, 1, 1, kCVPixelFormatType_OneComponent8, attributes, &gain) == 0);
    assert(CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_128RGBAFloat, attributes, &output) == 0);
    CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, sourceSpace, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, targetSpace, kCVAttachmentMode_ShouldPropagate);
    if (targetHeadroom)
        CVBufferSetAttachment(output, kIOSurfaceContentHeadroom, (CFNumberRef)@(targetHeadroom), kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(input, 0);
    for (size_t y = 0; y < height; ++y) {
        float *row = (float*)((char*)CVPixelBufferGetBaseAddress(input) + y * CVPixelBufferGetBytesPerRow(input));
        for (size_t x = 0; x < width; ++x) {
            row[4*x] = row[4*x+1] = row[4*x+2] = value;
            row[4*x+3] = 1;
        }
    }
    CVPixelBufferUnlockBaseAddress(input, 0);
    CVPixelBufferLockBaseAddress(gain, 0);
    *(unsigned char*)CVPixelBufferGetBaseAddress(gain) = 255;
    CVPixelBufferUnlockBaseAddress(gain, 0);
    assert(CGImageApplyHDRGainMap(input, gain, output, (CFDictionaryRef)@{(id)kCGImageAuxiliaryDataInfoMetadata:(id)info}) == 0);
    CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    for (size_t y = 0; y < height; ++y) {
        const float *row = (const float*)((const char*)CVPixelBufferGetBaseAddress(output) + y * CVPixelBufferGetBytesPerRow(output));
        for (size_t x = 0; x < width; ++x) {
            for (unsigned channel = 0; channel < 3; ++channel) {
                if (fabs(row[4*x+channel] - expected) > .005)
                    printf("%s pixel %zu,%zu channel%u: %g expected %g\n", label, x, y, channel, row[4*x+channel], expected);
                assert(fabs(row[4*x+channel] - expected) < .005);
            }
            assert(fabs(row[4*x+3] - 1) < .001);
        }
    }
    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    CFRelease(output); CFRelease(gain); CFRelease(input);
    printf("PASS %s\n", label);
}

static void checkResampling(CGImageMetadataRef info, CGColorSpaceRef linear)
{
    CVPixelBufferRef input = NULL, gain = buffer(kCVPixelFormatType_OneComponent8, NULL), output = NULL;
    assert(CVPixelBufferCreate(NULL, 4, 1, kCVPixelFormatType_128RGBAFloat, NULL, &input) == 0);
    assert(CVPixelBufferCreate(NULL, 4, 1, kCVPixelFormatType_128RGBAFloat, NULL, &output) == 0);
    CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, linear, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, linear, kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(input, 0);
    float *pixels = CVPixelBufferGetBaseAddress(input);
    for (unsigned i = 0; i < 4; ++i) {
        pixels[4*i] = pixels[4*i+1] = pixels[4*i+2] = .25;
        pixels[4*i+3] = 1;
    }
    CVPixelBufferUnlockBaseAddress(input, 0);
    CVPixelBufferLockBaseAddress(gain, 0);
    unsigned char *gains = CVPixelBufferGetBaseAddress(gain);
    gains[0] = 0; gains[1] = 255;
    CVPixelBufferUnlockBaseAddress(gain, 0);
    assert(CGImageApplyHDRGainMap(input, gain, output, (CFDictionaryRef)@{(id)kCGImageAuxiliaryDataInfoMetadata:(id)info}) == 0);
    CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    pixels = CVPixelBufferGetBaseAddress(output);
    double interpolated[] = { 0, .25, .75, 1 };
    for (unsigned i = 0; i < 4; ++i) {
        double value = interpolated[i];
        double gainLinear = value < .081 ? value / 4.5 : pow((value + .099) / 1.099, 1 / .45);
        double expected = .25 * (1 + 3 * gainLinear);
        printf("resampled pixel%u: %g expected %g\n", i, pixels[4*i], expected);
        assert(fabs(pixels[4*i] - expected) < .005);
    }
    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    CFRelease(output); CFRelease(gain); CFRelease(input);
    puts("PASS gain-map edge clamping and nonuniform interpolation");
}

static unsigned read32(const unsigned char *bytes)
{
    return ((unsigned)bytes[0] << 24) | ((unsigned)bytes[1] << 16) | ((unsigned)bytes[2] << 8) | bytes[3];
}

static CGColorSpaceRef scaledPCSProfile(CGColorSpaceRef pq)
{
    CFDataRef original = CGColorSpaceCopyICCProfile(pq);
    CFMutableDataRef data = CFDataCreateMutableCopy(NULL, 0, original);
    CFRelease(original);
    unsigned char *bytes = CFDataGetMutableBytePtr(data);
    memset(bytes + 84, 0, 16);
    for (unsigned i = 0; i < read32(bytes + 128); ++i) {
        unsigned char *entry = bytes + 132 + 12 * i;
        bool forward = !memcmp(entry, "A2B0", 4), reverse = !memcmp(entry, "B2A0", 4);
        if (!forward && !reverse)
            continue;
        unsigned char *tag = bytes + read32(entry + 4);
        unsigned char *matrix = tag + read32(tag + 16);
        for (unsigned component = 0; component < 9; ++component) {
            unsigned char *coefficient = matrix + component * 4;
            int32_t value = (int32_t)read32(coefficient);
            value = forward ? value / 2 : value * 2;
            coefficient[0] = value >> 24; coefficient[1] = value >> 16;
            coefficient[2] = value >> 8; coefficient[3] = value;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithICCProfile(data);
    CFRelease(data);
    assert(space);
    return space;
}

static CGColorSpaceRef hlgProfile(CGColorSpaceRef pq)
{
    CFDataRef original = CGColorSpaceCopyICCProfile(pq);
    CFMutableDataRef data = CFDataCreateMutableCopy(NULL, 0, original);
    CFRelease(original);
    unsigned char *bytes = CFDataGetMutableBytePtr(data);
    memset(bytes + 84, 0, 16);
    for (unsigned i = 0; i < read32(bytes + 128); ++i) {
        unsigned char *entry = bytes + 132 + 12 * i;
        unsigned char *tag = bytes + read32(entry + 4);
        if (!memcmp(entry, "cicp", 4))
            tag[9] = 18;
        bool forward = !memcmp(entry, "A2B0", 4), reverse = !memcmp(entry, "B2A0", 4);
        if (!forward && !reverse)
            continue;
        unsigned char *curves = tag + read32(tag + 28);
        unsigned count = read32(curves + 8), stride = 12 + 2 * count;
        const double a = .17883277, b = 1 - 4 * a, c = .5 - a * log(4 * a);
        for (unsigned channel = 0; channel < 3; ++channel) {
            for (unsigned sample = 0; sample < count; ++sample) {
                double x = (double)sample / (count - 1);
                double value;
                if (forward) {
                    double scene = x <= .5 ? x * x / 3 : (exp((x - c) / a) + b) / 12;
                    value = pow(scene, 1.2 / 8);
                } else {
                    double scene = pow(x, 8 / 1.2);
                    value = scene <= 1.0 / 12 ? sqrt(3 * scene) : a * log(12 * scene - b) + c;
                }
                unsigned quantized = lround(fmin(1, fmax(0, value)) * 65535);
                unsigned char *item = curves + channel * stride + 12 + 2 * sample;
                item[0] = quantized >> 8; item[1] = quantized;
            }
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithICCProfile(data);
    CFRelease(data);
    assert(space);
    return space;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        CGColorSpaceRef linear = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceExtendedLinearSRGB"));
        assert(linear);
        CVPixelBufferRef input = buffer(kCVPixelFormatType_128RGBAFloat, linear);
        CVPixelBufferRef gain = buffer(kCVPixelFormatType_OneComponent8, NULL);
        CVPixelBufferRef output = buffer(kCVPixelFormatType_128RGBAFloat, linear);
        CVPixelBufferLockBaseAddress(input, 0);
        float samples[] = { .25f, .125f, .0625f, .5f, .4f, .2f, .1f, 1 };
        memcpy(CVPixelBufferGetBaseAddress(input), samples, sizeof(samples));
        CVPixelBufferUnlockBaseAddress(input, 0);
        CVPixelBufferLockBaseAddress(gain, 0);
        unsigned char *mask = CVPixelBufferGetBaseAddress(gain);
        mask[0] = 255; mask[1] = 0;
        CVPixelBufferUnlockBaseAddress(gain, 0);
        const NSString *fixtures[] = {
            @"HDRGainMap:HDRGainMapVersion='131072' HDRGainMap:HDRGainMapHeadroom='4'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2' hdrgm:OffsetSDR='0' hdrgm:OffsetHDR='0'"
        };
        for (unsigned fixture = 0; fixture < 2; ++fixture) {
            CGImageMetadataRef info = metadata((NSString*)fixtures[fixture]);
            assert(fabs(CGImageGetHDRGainMapHeadroom(info, NULL) - 4) < 1e-6);
            NSDictionary *options = @{ (id)kCGImageAuxiliaryDataInfoMetadata:(id)info };
            assert(CGImageApplyHDRGainMap(input, gain, output, (CFDictionaryRef)options) == 0);
            CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
            const float *actual = CVPixelBufferGetBaseAddress(output);
            for (unsigned i = 0; i < 8; ++i) {
                float expected = samples[i] * (i < 3 ? 4 : 1);
                printf("fixture=%u component=%u actual=%g expected=%g\n", fixture, i, actual[i], expected);
                assert(fabs(actual[i] - expected) < .005);
            }
            CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
            CGImageRef image = CGImageCreateFromIOSurface(CVPixelBufferGetIOSurface(output), NULL);
            assert(image && CGImageGetBitsPerComponent(image) == 32);
            assert(CGColorSpaceEqualToColorSpace(CGImageGetColorSpace(image), linear));
            CGImageRelease(image);
            CFRelease(info);
        }
        CGImageMetadataRef apple = metadata((NSString*)fixtures[0]);
        checkUniform("white gain map 1x1 to 4x4", apple, linear, linear, .25, 1, 4, 4, 0, true);
        checkUniform("plain floating-point pixel buffers", apple, linear, linear, .25, 1, 4, 4, 0, false);
        checkUniform("target headroom attachment 2x", apple, linear, linear, .25, .5, 2, 2, 2, true);
        checkUniform("target headroom attachment SDR", apple, linear, linear, .25, .25, 2, 2, 1, true);
        checkResampling(apple, linear);
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        checkUniform("sRGB input linearization", apple, srgb, linear, .5, .8561646, 2, 2, 0, true);
        CGColorSpaceRef pq = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3_PQ"));
        CGColorSpaceRef p3 = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceExtendedLinearDisplayP3"));
        checkUniform("LUT color-space linearization", apple, pq, p3, .58068888, 4, 2, 2, 0, true);
        checkUniform("PQ output diffuse white", apple, linear, pq, .25, .58068888, 2, 2, 0, true);
        CGColorSpaceRef scaledPQ = scaledPCSProfile(pq);
        checkUniform("PQ input with different ICC PCS scale", apple, scaledPQ, p3, .58068888, 4, 2, 2, 0, true);
        checkUniform("PQ output with different ICC PCS scale", apple, linear, scaledPQ, .25, .58068888, 2, 2, 0, true);
        CGColorSpaceRelease(scaledPQ);
        CGColorSpaceRef hlg = hlgProfile(pq);
        checkUniform("HLG input reference white", apple, hlg, p3, .75, 4, 2, 2, 0, true);
        checkUniform("HLG output reference white", apple, linear, hlg, .25, .75, 2, 2, 0, true);
        CGColorSpaceRelease(hlg);
        CGImageMetadataRef single = metadataWithElements(@"hdrgm:Version='1.0' hdrgm:HDRCapacityMax='3' hdrgm:OffsetSDR='0' hdrgm:OffsetHDR='0'",
            @"<hdrgm:GainMapMax><rdf:Seq><rdf:li>3</rdf:li></rdf:Seq></hdrgm:GainMapMax>");
        checkUniform("single-element gain array", single, linear, linear, .25, 2, 2, 2, 0, true);
        CGImageMetadataRef triple = metadataWithElements(@"hdrgm:Version='1.0' hdrgm:HDRCapacityMax='3' hdrgm:OffsetSDR='0' hdrgm:OffsetHDR='0'",
            @"<hdrgm:GainMapMax><rdf:Seq><rdf:li>3</rdf:li><rdf:li>3</rdf:li><rdf:li>3</rdf:li></rdf:Seq></hdrgm:GainMapMax>");
        checkUniform("three-element gain array", triple, linear, linear, .25, 2, 2, 2, 0, true);
        CGImageMetadataRef offsets = metadata(@"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2'");
        checkUniform("Adobe default offsets", offsets, linear, linear, .25, 1.046875, 2, 2, 0, true);
        checkUniform("Adobe SDR identity with offsets", offsets, linear, linear, .25, .25, 2, 2, 1, true);
        CGImageMetadataRef hdrBase = metadata(@"hdrgm:Version='1.0' hdrgm:GainMapMax='3' hdrgm:HDRCapacityMax='3' hdrgm:OffsetSDR='0' hdrgm:OffsetHDR='0' hdrgm:BaseRenditionIsHDR='True'");
        checkUniform("HDR base reconstructed as SDR", hdrBase, linear, linear, 2, .25, 2, 2, 1, true);
        checkUniform("HDR base identity at full headroom", hdrBase, linear, linear, 2, 2, 2, 2, 0, true);
        NSString *invalid[] = {
            @"hdrgm:Version='1.0' hdrgm:HDRCapacityMax='2'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='nan' hdrgm:HDRCapacityMax='2'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='nan'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2' hdrgm:Gamma='0'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2' hdrgm:Gamma='nan'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2' hdrgm:OffsetHDR='-1'",
            @"hdrgm:Version='1.0' hdrgm:GainMapMax='2' hdrgm:GainMapMin='3' hdrgm:HDRCapacityMax='2'",
            @"hdrgm:Version='2.0' hdrgm:GainMapMax='2' hdrgm:HDRCapacityMax='2'",
        };
        for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
            CGImageMetadataRef info = metadata(invalid[i]);
            assert(CGImageGetHDRGainMapHeadroom(info, NULL) == 1);
            assert(CGImageApplyHDRGainMap(input, gain, output, (CFDictionaryRef)@{(id)kCGImageAuxiliaryDataInfoMetadata:(id)info}) != 0);
            CFRelease(info);
        }
        CGImageMetadataRef invalidArray = metadataWithElements(@"hdrgm:Version='1.0' hdrgm:GainMapMax='2'",
            @"<hdrgm:HDRCapacityMax><rdf:Seq><rdf:li>2</rdf:li></rdf:Seq></hdrgm:HDRCapacityMax>");
        assert(CGImageApplyHDRGainMap(input, gain, output, (CFDictionaryRef)@{(id)kCGImageAuxiliaryDataInfoMetadata:(id)invalidArray}) != 0);
        CFRelease(invalidArray);
        puts("PASS malformed, missing, non-finite, out-of-range and non-scalar metadata rejection");
        assert(argc == 2);
        NSData *jpeg = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        assert(jpeg);
        NSData *startMarker = [@"<x:xmpmeta" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *endMarker = [@"</x:xmpmeta>" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange search = NSMakeRange(0, [jpeg length]);
        bool found = false;
        while (search.length) {
            NSRange start = [jpeg rangeOfData:startMarker options:0 range:search];
            if (start.location == NSNotFound)
                break;
            NSRange end = [jpeg rangeOfData:endMarker options:0 range:NSMakeRange(start.location, [jpeg length] - start.location)];
            assert(end.location != NSNotFound);
            NSRange packet = NSMakeRange(start.location, NSMaxRange(end) - start.location);
            CGImageMetadataRef info = CGImageMetadataCreateFromXMPData((CFDataRef)[jpeg subdataWithRange:packet]);
            if (info) {
                if (fabs(CGImageGetHDRGainMapHeadroom(info, NULL) - 5.655168456726131) < 1e-6)
                    found = true;
                CFRelease(info);
            }
            search = NSMakeRange(NSMaxRange(packet), [jpeg length] - NSMaxRange(packet));
        }
        assert(found);
        puts("PASS upstream JPEG auxiliary XMP headroom");
        CFRelease(hdrBase); CFRelease(offsets); CFRelease(triple); CFRelease(single); CFRelease(apple);
        CGColorSpaceRelease(p3); CGColorSpaceRelease(pq); CGColorSpaceRelease(srgb);
        CFDictionaryRef attributes = NULL;
        assert(CGImageCreatePixelBufferAttributesForHDRTarget(2, (CFDictionaryRef)@{(id)kCVPixelBufferWidthKey:@2, (id)kCVPixelBufferHeightKey:@1},
            (CFDictionaryRef)@{(id)kCGTargetPixelFormat:@(kCVPixelFormatType_128RGBAFloat), (id)kCGTargetColorSpace:(id)linear}, &attributes) == 0);
        assert([(id)CFDictionaryGetValue(attributes, kCVPixelBufferPixelFormatTypeKey) unsignedIntValue] == kCVPixelFormatType_128RGBAFloat);
        assert(CGColorSpaceEqualToColorSpace((CGColorSpaceRef)CFDictionaryGetValue(attributes, kCVImageBufferCGColorSpaceKey), linear));
        CFRelease(attributes);
        CFRelease(input); CFRelease(gain); CFRelease(output); CGColorSpaceRelease(linear);
        puts("PASS HDR gain-map reconstruction, alpha, IOSurface color space, target attributes");
    }
}
