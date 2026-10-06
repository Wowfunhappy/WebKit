// Repeated paints of a retained image preserve pixels across native pattern transforms.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern CGPatternRef CGPatternCreateWithImage2(CGImageRef, CGAffineTransform, CGPatternTiling);

typedef void (*DrawTiled)(CGContextRef, CGRect, CGImageRef);
typedef CGPatternRef (*CreatePattern)(CGImageRef, CGAffineTransform, CGPatternTiling);
enum { side = 16, byteCount = side * side * 4 };

static const struct {
    const char *name;
    CGBitmapInfo info;
    unsigned red, green, blue, alpha;
} formats[] = {
    { "RGBA", kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, 0, 1, 2, 3 },
    { "BGRA", kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, 2, 1, 0, 3 },
    { "ARGB", kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big, 1, 2, 3, 0 },
    { "ABGR", kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little, 3, 2, 1, 0 },
};

static void *systemSymbol(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol symbol = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : NULL;
    return symbol ? NSAddressOfSymbol(symbol) : NULL;
}

static CGImageRef imageWithPixels(unsigned char *pixels, CGColorSpaceRef space, CGBitmapInfo info)
{
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, byteCount, NULL);
    CGImageRef image = CGImageCreate(side, side, 8, 32, side * 4, space, info,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

static int draw(CGColorSpaceRef space, CGImageRef image, CGPatternRef pattern, DrawTiled tiled, unsigned char *result)
{
    int width = side, bytesPerElement = 4;
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &width);
    CFNumberRef b = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement };
    const void *values[] = { w, w, b };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(w);
    CFRelease(b);
    CGContextRef context = surface ? CGIOSurfaceContextCreate(surface, side, side, 8, 32, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
    if (!context) {
        if (surface)
            CFRelease(surface);
        return 0;
    }
    if (pattern) {
        CGColorSpaceRef patternSpace = CGColorSpaceCreatePattern(NULL);
        CGContextSetFillColorSpace(context, patternSpace);
        CGColorSpaceRelease(patternSpace);
        CGFloat alpha = 1;
        CGContextSetFillPattern(context, pattern, &alpha);
        CGContextFillRect(context, CGRectMake(0, 0, side, side));
    } else
        tiled(context, CGRectMake(0, 0, side, side), image);
    CGContextFlush(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    for (size_t row = 0; row < side; ++row)
        memcpy(result + row * side * 4, (const unsigned char *)IOSurfaceGetBaseAddress(surface) + row * IOSurfaceGetBytesPerRow(surface), side * 4);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CGContextRelease(context);
    CFRelease(surface);
    return 1;
}

int main(void)
{
    DrawTiled stockDraw = (DrawTiled)systemSymbol("_CGContextDrawTiledImage");
    CreatePattern stockPattern = (CreatePattern)systemSymbol("_CGPatternCreateWithImage2");
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!stockDraw || !stockPattern || !space)
        return 1;
    int failures = 0;
    for (unsigned scenario = 0; scenario < 2 * sizeof(formats) / sizeof(formats[0]); ++scenario) {
        unsigned format = scenario / 2, usePattern = scenario % 2;
        unsigned char pixels[byteCount], actual[byteCount], expected[byteCount];
        for (unsigned pixel = 0; pixel < side * side; ++pixel) {
            unsigned alpha = pixel % 3 == 0 ? 0 : pixel % 3 == 1 ? 128 : 255;
            pixels[pixel * 4 + formats[format].red] = ((72 + pixel % side) * alpha) / 255;
            pixels[pixel * 4 + formats[format].green] = ((84 + pixel / side) * alpha) / 255;
            pixels[pixel * 4 + formats[format].blue] = (96 * alpha) / 255;
            pixels[pixel * 4 + formats[format].alpha] = alpha;
        }
        CGImageRef image = imageWithPixels(pixels, space, formats[format].info);
        if (!image)
            return 1;
        for (unsigned iteration = 0; iteration < 3; ++iteration) {
            // Compare the retained image with a fresh image over the same immutable pixels.
            CGImageRef referenceImage = imageWithPixels(pixels, space, formats[format].info);
            if (!referenceImage)
                return 1;
            CGAffineTransform transform = CGAffineTransformMakeRotation(iteration * 0.17);
            transform = CGAffineTransformScale(transform, 1 + iteration * 0.25, 1 - iteration * 0.2);
            CGPatternRef pattern = usePattern ? CGPatternCreateWithImage2(image, transform, kCGPatternTilingConstantSpacing) : NULL;
            CGPatternRef reference = usePattern ? stockPattern(referenceImage, transform, kCGPatternTilingConstantSpacing) : NULL;
            if (usePattern && (!pattern || !reference))
                return 1;
            int ok = draw(space, image, pattern, CGContextDrawTiledImage, actual)
                && draw(space, referenceImage, reference, stockDraw, expected)
                && !memcmp(actual, expected, sizeof(actual));
            printf("%s %s draw %u preserves pixels: %s\n", formats[format].name, usePattern ? "pattern" : "tiled", iteration, ok ? "PASS" : "FAIL");
            failures += !ok;
            if (!ok)
                printf("  actual=%u,%u,%u,%u expected=%u,%u,%u,%u\n", actual[0], actual[1], actual[2], actual[3], expected[0], expected[1], expected[2], expected[3]);
            if (pattern)
                CGPatternRelease(pattern);
            if (reference)
                CGPatternRelease(reference);
            CGImageRelease(referenceImage);
        }
        CGImageRelease(image);
    }
    CGColorSpaceRelease(space);
    return failures ? 1 : 0;
}
