// vImage's AVX2 dispatch, cleared by methods/Accelerate.m's constructor in every process that loads WebCore.
// Built twice: linked with that constructor, as WebCore links it, every conversion lands byte for byte on
// 10.9's own conversion of each pixel alone -- widths 16 to 80, source and destination buffers starting 0 to
// 63 bytes into their allocations, rows padded by bytes that are not a whole pixel, three rows, and a
// 1920x1080 frame (which 10.9 splits into row tiles across threads), in place for a converter whose pixels
// keep their size -- for converters of premultiplied BGRA between RGB spaces, RGBA into 24-bit RGB without
// alpha, CMYK into RGB, 16-bit RGBA into 8-bit, 4-bit grey into BGRA and one made from a ColorSync code
// fragment, and for vImageConvert_Planar16Q12toARGB8888 itself. Built without it (the argument
// "--without-initializer"), on a CPU with AVX2, the same full-width calls give some pixels other values,
// which is the premise.
#define __ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES 0
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

typedef unsigned long vImage_Flags;
typedef long vImage_Error;
typedef struct vImageConverter *vImageConverterRef;
typedef struct {
    void *data;
    unsigned long height;
    unsigned long width;
    size_t rowBytes;
} vImage_Buffer;
typedef struct {
    uint32_t bitsPerComponent;
    uint32_t bitsPerPixel;
    CGColorSpaceRef colorSpace;
    CGBitmapInfo bitmapInfo;
    uint32_t version;
    const CGFloat *decode;
    CGColorRenderingIntent renderingIntent;
} vImage_CGImageFormat;
vImageConverterRef vImageConverter_CreateWithCGImageFormat(const vImage_CGImageFormat *, const vImage_CGImageFormat *, const CGFloat *, vImage_Flags, vImage_Error *);
vImageConverterRef vImageConverter_CreateWithColorSyncCodeFragment(const void *, const vImage_CGImageFormat *, const vImage_CGImageFormat *, const CGFloat *, vImage_Flags, vImage_Error *);
vImage_Error vImageConverter_MustOperateOutOfPlace(const vImageConverterRef, const vImage_Buffer *, const vImage_Buffer *, vImage_Flags);
vImage_Error vImageConvert_AnyToAny(const vImageConverterRef, const vImage_Buffer *, const vImage_Buffer *, void *, vImage_Flags);
vImage_Error vImageConvert_Planar16Q12toARGB8888(const vImage_Buffer *, const vImage_Buffer *, const vImage_Buffer *, const vImage_Buffer *, const vImage_Buffer *, vImage_Flags);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static unsigned noise(unsigned i)
{
    i ^= i >> 13;
    i *= 0x5bd1e995u;
    return i ^ (i >> 15);
}

typedef struct {
    vImageConverterRef converter;
    unsigned sourceBits, destinationBits;
    bool opaqueFourth;   // the source's fourth byte is alpha, kept opaque
} Shape;

// The pixel at `x` of a source row, copied into a fresh buffer starting on a byte.
static void sourcePixel(const Shape *shape, const unsigned char *row, unsigned long x, unsigned char *pixel)
{
    if (shape->sourceBits >= 8) {
        memcpy(pixel, row + x * shape->sourceBits / 8, shape->sourceBits / 8);
        return;
    }
    unsigned bit = (unsigned)(x * shape->sourceBits);
    unsigned value = (row[bit / 8] >> (8 - shape->sourceBits - bit % 8)) & ((1u << shape->sourceBits) - 1);
    pixel[0] = (unsigned char)(value << (8 - shape->sourceBits));
}

// Whether `convert` of a width x height source at the given offsets and row padding matches each pixel
// converted alone, byte for byte (`inPlace` converts the source buffer into itself).
static bool matchesPerPixel(const Shape *shape, unsigned long width, unsigned long height, size_t sourceOffset,
    size_t destinationOffset, size_t padding, bool inPlace)
{
    size_t sourceRow = (width * shape->sourceBits + 7) / 8 + padding, destinationRow = width * shape->destinationBits / 8 + padding;
    unsigned char *sourceAllocation = malloc(sourceRow * height + 64), *destinationAllocation = malloc(destinationRow * height + 64);
    unsigned char *source = sourceAllocation + sourceOffset;
    unsigned char *destination = inPlace ? source : destinationAllocation + destinationOffset;
    for (size_t i = 0; i < sourceRow * height; i++)
        source[i] = (unsigned char)noise((unsigned)(i + width * 131 + sourceOffset));
    if (shape->opaqueFourth) {
        for (unsigned long y = 0; y < height; y++) {
            for (unsigned long x = 0; x < width; x++)
                source[y * sourceRow + x * 4 + 3] = 255;
        }
    }
    unsigned char *expected = malloc(destinationRow * height);
    for (unsigned long y = 0; y < height; y++) {
        for (unsigned long x = 0; x < width; x++) {
            unsigned char pixel[16], out[16];
            sourcePixel(shape, source + y * sourceRow, x, pixel);
            vImage_Buffer one = { pixel, 1, 1, 16 }, oneOut = { out, 1, 1, 16 };
            vImageConvert_AnyToAny(shape->converter, &one, &oneOut, NULL, 0);
            memcpy(expected + y * destinationRow + x * shape->destinationBits / 8, out, shape->destinationBits / 8);
        }
    }
    vImage_Buffer from = { source, height, width, sourceRow }, to = { destination, height, width, inPlace ? sourceRow : destinationRow };
    bool same = vImageConvert_AnyToAny(shape->converter, &from, &to, NULL, 0) == 0;
    for (unsigned long y = 0; same && y < height; y++)
        same = !memcmp(destination + y * to.rowBytes, expected + y * destinationRow, width * shape->destinationBits / 8);
    free(expected);
    free(sourceAllocation);
    free(destinationAllocation);
    return same;
}

// Every width from 16 to 80 at a spread of buffer offsets and row paddings, three rows each.
static int sweepMismatches(const Shape *shape)
{
    static const size_t offsets[] = { 0, 1, 2, 3, 4, 5, 7, 8, 13, 31, 32, 63 };
    enum { offsetCount = sizeof(offsets) / sizeof(offsets[0]) };
    int mismatches = 0;
    for (unsigned long width = 16; width <= 80; width++) {
        for (size_t i = 0; i < offsetCount; i++) {
            size_t sourceOffset = offsets[i], destinationOffset = offsets[(i * 5 + width) % offsetCount], padding = (width + i) % 7;
            mismatches += !matchesPerPixel(shape, width, 3, sourceOffset, destinationOffset, padding, false);
        }
    }
    return mismatches;
}

int main(int argc, char **argv)
{
    bool withoutInitializer = argc > 1 && !strcmp(argv[1], "--without-initializer");
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    CGColorSpaceRef cmyk = CGColorSpaceCreateWithName(kCGColorSpaceGenericCMYK);
    CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    int avx2 = 0;
    size_t size = sizeof(avx2);
    sysctlbyname("hw.optional.avx2_0", &avx2, &size, NULL, 0);
    if (withoutInitializer && !avx2) {
        printf("    no AVX2 on this CPU: the premise does not arise\n");
        return 0;
    }

    const CGBitmapInfo bgra = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    const CGBitmapInfo rgba = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    vImage_CGImageFormat adobeBGRA = { 8, 32, adobe, bgra, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat sRGBBGRA = { 8, 32, sRGB, bgra, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat adobeRGBA = { 8, 32, adobe, rgba, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat sRGB24 = { 8, 24, sRGB, (CGBitmapInfo)kCGImageAlphaNone, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat cmyk32 = { 8, 32, cmyk, (CGBitmapInfo)kCGImageAlphaNone, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat sRGB64 = { 16, 64, sRGB, (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat gray4 = { 4, 4, gray, (CGBitmapInfo)kCGImageAlphaNone, 0, NULL, kCGRenderingIntentDefault };
    const CGFloat background[4] = { 0, 0, 0, 1 };
    vImage_Error error = 0;

    // A code fragment for Adobe RGB to sRGB.
    CFArrayRef fragment = NULL;
    {
        CFDataRef adobeProfile = CGColorSpaceCopyICCProfile(adobe), sRGBProfile = CGColorSpaceCopyICCProfile(sRGB);
        ColorSyncProfileRef from = ColorSyncProfileCreate(adobeProfile, NULL), to = ColorSyncProfileCreate(sRGBProfile, NULL);
        const void *keys[] = { kColorSyncProfile, kColorSyncRenderingIntent, kColorSyncTransformTag };
        const void *fromValues[] = { from, kColorSyncRenderingIntentPerceptual, kColorSyncTransformDeviceToPCS };
        const void *toValues[] = { to, kColorSyncRenderingIntentPerceptual, kColorSyncTransformPCSToDevice };
        CFDictionaryRef steps[2] = {
            CFDictionaryCreate(NULL, keys, fromValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks),
            CFDictionaryCreate(NULL, keys, toValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks),
        };
        CFArrayRef sequence = CFArrayCreate(NULL, (const void **)steps, 2, &kCFTypeArrayCallBacks);
        ColorSyncTransformRef transform = ColorSyncTransformCreate(sequence, NULL);
        fragment = transform ? (CFArrayRef)ColorSyncTransformCopyProperty(transform, kColorSyncTransformFullConversionData, NULL) : NULL;
    }

    struct {
        const char *what;
        Shape shape;
    } shapes[] = {
        { "premultiplied BGRA, Adobe RGB into sRGB", { vImageConverter_CreateWithCGImageFormat(&adobeBGRA, &sRGBBGRA, NULL, 0, &error), 32, 32, true } },
        { "RGBA into 24-bit RGB without alpha", { vImageConverter_CreateWithCGImageFormat(&adobeRGBA, &sRGB24, background, 0, &error), 32, 24, true } },
        { "CMYK into RGB", { vImageConverter_CreateWithCGImageFormat(&cmyk32, &sRGBBGRA, NULL, 0, &error), 32, 32, false } },
        { "16-bit RGBA into 8-bit", { vImageConverter_CreateWithCGImageFormat(&sRGB64, &adobeBGRA, NULL, 0, &error), 64, 32, false } },
        { "4-bit grey into BGRA", { vImageConverter_CreateWithCGImageFormat(&gray4, &sRGBBGRA, NULL, 0, &error), 4, 32, false } },
        { "a ColorSync code fragment's converter", { fragment ? vImageConverter_CreateWithColorSyncCodeFragment(fragment, &adobeBGRA, &sRGBBGRA, NULL, 0, &error) : NULL, 32, 32, true } },
    };
    int diverging = 0;
    for (size_t i = 0; i < sizeof(shapes) / sizeof(shapes[0]); i++) {
        char what[200];
        snprintf(what, sizeof(what), "%s: every width, offset and padding is each pixel's own", shapes[i].what);
        if (!shapes[i].shape.converter) {
            check(0, what);
            continue;
        }
        int mismatches = sweepMismatches(&shapes[i].shape);
        printf("    %s: %d of 780 cases differ from each pixel's own conversion\n", shapes[i].what, mismatches);
        diverging += mismatches > 0;
        if (!withoutInitializer)
            check(!mismatches, what);
    }
    if (withoutInitializer)
        check(diverging > 0, "without the initializer, full-width conversions differ from each pixel's own");

    // A 1920x1080 frame, and the same converter in place.
    if (!withoutInitializer) {
        Shape *shape = &shapes[0].shape;
        check(matchesPerPixel(shape, 1920, 1080, 0, 0, 0, false), "a 1920x1080 frame is each pixel's own");
        vImage_Buffer probe = { NULL, 1, 1, 4 };
        check(!vImageConverter_MustOperateOutOfPlace(shape->converter, &probe, &probe, 0), "the BGRA converter may work in place");
        bool inPlace = true;
        for (unsigned long width = 16; width <= 80; width += 7)
            inPlace = inPlace && matchesPerPixel(shape, width, 3, width % 13, 0, width % 5, true);
        inPlace = inPlace && matchesPerPixel(shape, 1920, 1080, 3, 0, 4, true);
        check(inPlace, "in place, every width and a 1920x1080 frame are each pixel's own");
    }

    // vImageConvert_Planar16Q12toARGB8888 over four planes, at the same widths and offsets.
    {
        static const size_t offsets[] = { 0, 2, 4, 6, 8, 14, 32, 62 };
        int mismatches = 0;
        for (unsigned long width = 16; width <= 80; width++) {
            for (size_t o = 0; o < sizeof(offsets) / sizeof(offsets[0]); o++) {
                enum { kRows = 3 };
                size_t planeRow = width * 2 + (o % 3) * 2, outRow = width * 4 + o % 5;
                int16_t *planes[4];
                unsigned char *planeAllocations[4];
                for (int p = 0; p < 4; p++) {
                    planeAllocations[p] = malloc(planeRow * kRows + 64);
                    planes[p] = (int16_t *)(void *)(planeAllocations[p] + offsets[o]);
                    for (size_t i = 0; i < planeRow * kRows / 2; i++)
                        planes[p][i] = (int16_t)(p == 0 ? 4096 : noise((unsigned)(i * 4 + p + width)) % 4097);
                }
                unsigned char *outAllocation = malloc(outRow * kRows + 64);
                unsigned char *out = outAllocation + offsets[(o + 3) % 8];
                vImage_Buffer bufs[4];
                for (int p = 0; p < 4; p++)
                    bufs[p] = (vImage_Buffer) { planes[p], kRows, width, planeRow };
                vImage_Buffer outBuffer = { out, kRows, width, outRow };
                vImageConvert_Planar16Q12toARGB8888(&bufs[0], &bufs[1], &bufs[2], &bufs[3], &outBuffer, 0);
                bool same = true;
                for (unsigned long y = 0; y < kRows; y++) {
                    for (unsigned long x = 0; x < width; x++) {
                        unsigned char alone[4];
                        vImage_Buffer one[4];
                        for (int p = 0; p < 4; p++)
                            one[p] = (vImage_Buffer) { (unsigned char *)planes[p] + y * planeRow + x * 2, 1, 1, 2 };
                        vImage_Buffer oneOut = { alone, 1, 1, 4 };
                        vImageConvert_Planar16Q12toARGB8888(&one[0], &one[1], &one[2], &one[3], &oneOut, 0);
                        same = same && !memcmp(alone, out + y * outRow + x * 4, 4);
                    }
                }
                mismatches += !same;
                for (int p = 0; p < 4; p++)
                    free(planeAllocations[p]);
                free(outAllocation);
            }
        }
        printf("    Planar16Q12 to ARGB8888: %d of 520 cases differ from each pixel's own\n", mismatches);
        if (withoutInitializer)
            check(mismatches > 0, "without the initializer, Planar16Q12 to ARGB8888 differs from each pixel's own");
        else
            check(!mismatches, "Planar16Q12 to ARGB8888: every width and offset is each pixel's own");
    }

    for (size_t i = 0; i < sizeof(shapes) / sizeof(shapes[0]); i++) {
        if (shapes[i].shape.converter)
            CFRelease(shapes[i].shape.converter);
    }
    CGColorSpaceRelease(gray);
    CGColorSpaceRelease(cmyk);
    CGColorSpaceRelease(adobe);
    CGColorSpaceRelease(sRGB);
    return failures ? 1 : 0;
}
