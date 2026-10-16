// The CGContextDrawImage replacement (polyfills/c/CoreGraphics.c) for an image whose colour space is not
// the IOSurface context's. A linear-sRGB image of every 8-bit level is drawn into an sRGB IOSurface at
// sizes both sides of the point where 10.9's QuartzCore stops matching exactly, and every level must land
// within one level of its exact sRGB encoding. The same draws through 10.9's own definition show the
// colour cube at the larger sizes, which is the premise. Image alpha (opaque, premultiplied) and 16-bit
// components each take the route. A translucent image's levels must land within one level of their exact
// match too, in an IOSurface and in an 8-bit bitmap, which 10.9's own 8-bit bitmap route misses by more; a
// straight-alpha one as that route matches it, within two levels. Translucent images of other matrix-shaper pairs land within one level of
// CoreGraphics' own match of them widened to 16 bits, and so do one in a space ColorSync describes by tables,
// drawn into an 8-bit bitmap.
// An image wider than the renderer's texture limit is matched across the parts it is drawn in. A partially
// decoded CMYK JPEG, built as JPEGImageDecoder::createNativeImage builds it (an opaque CMYK
// image under CGImageCreateWithMask), paints only its decoded rows.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

static CGColorSpaceRef createLinearSRGB(void)
{
    const CGFloat white[3] = { 0.9505, 1.0, 1.0890 }, black[3] = { 0, 0, 0 }, gamma[3] = { 1, 1, 1 };
    const CGFloat primaries[9] = { 0.4124564, 0.2126729, 0.0193339, 0.3575761, 0.7151522, 0.1191920, 0.1804375, 0.0721750, 0.9503041 };
    return CGColorSpaceCreateCalibratedRGB(white, black, gamma, primaries);
}

// Level x % 256 in every colour component of column x, in the requested layout.
static CGImageRef createLevelsImage(CGColorSpaceRef space, size_t width, size_t height, bool sixteenBit, bool opaque)
{
    size_t bitsPerComponent = sixteenBit ? 16 : 8, pixelBytes = sixteenBit ? 8 : 4, rowBytes = width * pixelBytes;
    CGBitmapInfo info = sixteenBit
        ? kCGBitmapByteOrder16Host | (CGBitmapInfo)(opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast)
        : kCGBitmapByteOrder32Little | (CGBitmapInfo)(opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
    unsigned char *pixels = calloc(height, rowBytes);
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            unsigned level = x % 256;
            if (sixteenBit) {
                uint16_t *p = (uint16_t *)(pixels + y * rowBytes + x * 8);
                p[0] = p[1] = p[2] = (uint16_t)(level * 257);
                p[3] = 0xffff;
            } else {
                unsigned char *p = pixels + y * rowBytes + x * 4;
                p[0] = p[1] = p[2] = (unsigned char)level;
                p[3] = 0xff;
            }
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, height * rowBytes, NULL);
    CGImageRef image = CGImageCreate(width, height, bitsPerComponent, pixelBytes * 8, rowBytes, space, info, provider, NULL, false,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

static IOSurfaceRef createSurface(size_t width, size_t height)
{
    int w = (int)width, h = (int)height, bytesPerElement = 4;
    unsigned format = 'BGRA';
    CFNumberRef widthNumber = CFNumberCreate(NULL, kCFNumberIntType, &w);
    CFNumberRef heightNumber = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    CFNumberRef pixelFormat = CFNumberCreate(NULL, kCFNumberIntType, &format);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    const void *values[] = { widthNumber, heightNumber, element, pixelFormat };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(widthNumber);
    CFRelease(heightNumber);
    CFRelease(element);
    CFRelease(pixelFormat);
    return surface;
}

// The green byte of each of the first 256 columns of row 0.
static void drawIntoSurface(DrawImageFn draw, CGColorSpaceRef space, CGImageRef image, unsigned char out[256])
{
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    IOSurfaceRef surface = createSurface(width, height);
    CGContextRef context = CGIOSurfaceContextCreate(surface, width, height, 8, 32, space, kBGRA);
    draw(context, CGRectMake(0, 0, width, height), image);
    CGContextFlush(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *base = IOSurfaceGetBaseAddress(surface);
    size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
    for (size_t x = 0; x < 256 && x < width; x++)
        out[x] = base[(height - 1) * rowBytes + x * 4 + 1];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CGContextRelease(context);
    CFRelease(surface);
}

// The sRGB encoding of a linear value, as an 8-bit level.
static int exactEncoding(double linearValue)
{
    double encoded = linearValue <= 0.0031308 ? linearValue * 12.92 : 1.055 * pow(linearValue, 1 / 2.4) - 0.055;
    return (int)lround(encoded * 255);
}

static void archiveDraw(CGContextRef context, CGRect rect, CGImageRef image)
{
    CGContextDrawImage(context, rect, image);
}

int main(int argc, char **argv)
{
    DrawImageFn system = systemDrawImage();
    CGColorSpaceRef linear = createLinearSRGB();
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!system || !linear || !sRGB)
        return 1;

    static const struct { size_t width, height; bool sixteenBit, opaque; const char *name; } cases[] = {
        { 64, 64, false, false, "64x64 premultiplied 8-bit" },
        { 256, 256, false, false, "256x256 premultiplied 8-bit" },
        { 256, 256, false, true, "256x256 opaque 8-bit" },
        { 256, 256, true, false, "256x256 premultiplied 16-bit" },
        { 1024, 1, false, false, "1024x1 premultiplied 8-bit" },
    };
    bool systemDiverges = false;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        CGImageRef image = createLevelsImage(linear, cases[i].width, cases[i].height, cases[i].sixteenBit, cases[i].opaque);
        unsigned char actual[256] = { 0 }, stock[256] = { 0 };
        drawIntoSurface(archiveDraw, sRGB, image, actual);
        drawIntoSurface(system, sRGB, image, stock);
        size_t columns = cases[i].width < 256 ? cases[i].width : 256;
        int worst = 0;
        for (size_t level = 0; level < columns; level++) {
            int exact = exactEncoding(level / 255.0);
            int error = abs((int)actual[level] - exact);
            if (error > worst)
                worst = error;
            if (abs((int)stock[level] - exact) > 1)
                systemDiverges = true;
        }
        char what[128];
        snprintf(what, sizeof(what), "%s: every level within one of its exact encoding", cases[i].name);
        check(worst <= 1, what);
        if (worst > 1)
            printf("    level 1: actual %u exact %d\n", actual[1], exactEncoding(1 / 255.0));
        CGImageRelease(image);
    }
    check(systemDiverges, "10.9's own definition colour-matches some of these through its cube");

    // Every premultiplied green level g <= a at every alpha a, one per pixel of a 256x256 image.
    {
        enum { kSide = 256 };
        unsigned char *pixels = calloc(kSide * kSide, 4);
        for (size_t a = 1; a < kSide; a++) {
            for (size_t g = 0; g < kSide; g++) {
                unsigned char *p = pixels + (kSide - 1 - a) * kSide * 4 + g * 4;
                p[1] = (unsigned char)(g <= a ? g : a);
                p[3] = (unsigned char)a;
            }
        }
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
        CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, linear, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        // Route 0 is an IOSurface, route 1 an 8-bit bitmap, both through the archive; route 2 the bitmap
        // through 10.9's own definition.
        int worst[3] = { 0, 0, 0 };
        for (int route = 0; route < 3; route++) {
            unsigned char *out = calloc(kSide * kSide, 4);
            if (route) {
                CGContextRef context = CGBitmapContextCreate(out, kSide, kSide, 8, kSide * 4, sRGB, kBGRA);
                CGContextSetBlendMode(context, kCGBlendModeCopy);
                (route == 1 ? archiveDraw : system)(context, CGRectMake(0, 0, kSide, kSide), image);
                CGContextRelease(context);
            } else {
                IOSurfaceRef surface = createSurface(kSide, kSide);
                CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, sRGB, kBGRA);
                CGContextSetBlendMode(context, kCGBlendModeCopy);
                CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
                CGContextFlush(context);
                IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
                for (size_t y = 0; y < kSide; y++)
                    memcpy(out + y * kSide * 4, (const unsigned char *)IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface), kSide * 4);
                IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
                CGContextRelease(context);
                CFRelease(surface);
            }
            for (size_t a = 1; a < kSide; a++) {
                for (size_t g = 0; g <= a; g++) {
                    double linearValue = (double)g / (double)a;
                    double encoded = linearValue <= 0.0031308 ? linearValue * 12.92 : 1.055 * pow(linearValue, 1 / 2.4) - 0.055;
                    int exact = (int)lround(encoded * (double)a);
                    int error = abs((int)out[(kSide - 1 - a) * kSide * 4 + g * 4 + 1] - exact);
                    if (error > worst[route])
                        worst[route] = error;
                }
            }
            free(out);
        }
        printf("    worst level error: IOSurface %d, bitmap %d, 10.9's bitmap route %d\n", worst[0], worst[1], worst[2]);
        check(worst[0] <= 1, "a translucent linear-sRGB image matches within one level of exact");
        check(worst[1] <= 1, "and does into an 8-bit bitmap");
        check(worst[2] > 1, "10.9's own 8-bit bitmap route misses some of it by more");
        CGImageRelease(image);
        free(pixels);
    }

    // Pairs of other matrix-shaper spaces: translucent pixels of every alpha drawn into an IOSurface land
    // within one level of CoreGraphics' own match of the image widened to 16 bits, Display P3 colours
    // outside sRGB's gamut included.
    {
        enum { kSide = 256 };
        CFDataRef adobeProfile = NULL;
        FILE *file = fopen("/System/Library/ColorSync/Profiles/AdobeRGB1998.icc", "rb");
        if (file) {
            unsigned char bytes[8192];
            size_t length = fread(bytes, 1, sizeof(bytes), file);
            fclose(file);
            adobeProfile = CFDataCreate(NULL, bytes, (CFIndex)length);
        }
        CGColorSpaceRef adobe = adobeProfile ? CGColorSpaceCreateWithICCProfile(adobeProfile) : NULL;
        CGColorSpaceRef generic = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
        CGColorSpaceRef displayP3 = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3"));
        struct { CGColorSpaceRef from, to; const char *what; } pairs[] = {
            { adobe, generic, "a translucent Adobe RGB image matches Generic RGB as a 16-bit match does" },
            { displayP3, sRGB, "a translucent Display P3 image matches sRGB as a 16-bit match does" },
            { sRGB, linear, "a translucent sRGB image matches linear sRGB as a 16-bit match does" },
        };
        unsigned char *pixels = calloc(kSide * kSide, 4);
        unsigned seed = 1;
        for (size_t y = 0; y < kSide; y++) {
            for (size_t x = 0; x < kSide; x++) {
                unsigned char *p = pixels + (y * kSide + x) * 4;
                unsigned alpha = (unsigned)x;
                for (int c = 0; c < 3; c++) {
                    seed = seed * 1103515245 + 12345;
                    p[c] = (unsigned char)(alpha ? (seed >> 16) % (alpha + 1) : 0);
                }
                p[3] = (unsigned char)alpha;
            }
        }
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            if (!pairs[i].from || !pairs[i].to) {
                check(0, pairs[i].what);
                continue;
            }
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
            CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, pairs[i].from, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);

            const CGBitmapInfo wide = kCGBitmapByteOrder16Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
            CGContextRef widened = CGBitmapContextCreate(NULL, kSide, kSide, 16, 0, pairs[i].from, wide);
            CGContextSetBlendMode(widened, kCGBlendModeCopy);
            CGContextDrawImage(widened, CGRectMake(0, 0, kSide, kSide), image);
            CGImageRef widenedImage = CGBitmapContextCreateImage(widened);
            CGContextRef reference = CGBitmapContextCreate(NULL, kSide, kSide, 16, 0, pairs[i].to, wide);
            CGContextSetBlendMode(reference, kCGBlendModeCopy);
            CGContextDrawImage(reference, CGRectMake(0, 0, kSide, kSide), widenedImage);

            IOSurfaceRef surface = createSurface(kSide, kSide);
            CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, pairs[i].to, kBGRA);
            CGContextSetBlendMode(context, kCGBlendModeCopy);
            CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
            CGContextFlush(context);
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            const unsigned char *base = IOSurfaceGetBaseAddress(surface);
            size_t surfaceRowBytes = IOSurfaceGetBytesPerRow(surface);
            const uint16_t *expected = CGBitmapContextGetData(reference);
            size_t expectedRow = CGBitmapContextGetBytesPerRow(reference) / 2;
            int worst = 0;
            for (size_t y = 0; y < kSide; y++) {
                for (size_t x = 0; x < kSide; x++) {
                    for (int c = 0; c < 4; c++) {
                        static const int bgra[4] = { 2, 1, 0, 3 };
                        int want = (int)lround(expected[y * expectedRow + x * 4 + c] / 257.0);
                        int error = abs((int)base[y * surfaceRowBytes + x * 4 + bgra[c]] - want);
                        if (error > worst)
                            worst = error;
                    }
                }
            }
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            printf("    worst level difference: %d\n", worst);
            check(worst <= 1, pairs[i].what);
            CGContextRelease(context);
            CFRelease(surface);
            CGContextRelease(reference);
            CGImageRelease(widenedImage);
            CGContextRelease(widened);
            CGImageRelease(image);
        }
        free(pixels);
        if (adobe)
            CGColorSpaceRelease(adobe);
        if (adobeProfile)
            CFRelease(adobeProfile);
        CGColorSpaceRelease(generic);
        if (displayP3)
            CGColorSpaceRelease(displayP3);
    }

    // A space ColorSync describes by tables (an sRGB profile with a Lab connection space and LUT tags, the
    // first argument): a translucent image in it drawn into an 8-bit Generic RGB bitmap lands within one level
    // of CoreGraphics' own match of it widened to 16 bits, which 10.9's own bitmap route misses by more.
    if (argc > 1) {
        enum { kSide = 256 };
        CFDataRef tableProfile = NULL;
        FILE *file = fopen(argv[1], "rb");
        if (file) {
            static unsigned char bytes[1 << 17];
            size_t length = fread(bytes, 1, sizeof(bytes), file);
            fclose(file);
            tableProfile = CFDataCreate(NULL, bytes, (CFIndex)length);
        }
        CGColorSpaceRef table = tableProfile ? CGColorSpaceCreateWithICCProfile(tableProfile) : NULL;
        CGColorSpaceRef generic = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
        if (!table) {
            check(0, "the table-described profile loads");
        } else {
            unsigned char *pixels = calloc(kSide * kSide, 4);
            unsigned seed = 7;
            for (size_t y = 0; y < kSide; y++) {
                for (size_t x = 0; x < kSide; x++) {
                    unsigned char *p = pixels + (y * kSide + x) * 4;
                    for (int c = 0; c < 3; c++) {
                        seed = seed * 1103515245 + 12345;
                        p[c] = (unsigned char)(x ? (seed >> 16) % (x + 1) : 0);
                    }
                    p[3] = (unsigned char)x;
                }
            }
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
            CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, table, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
            CGDataProviderRelease(provider);
            const CGBitmapInfo wide = kCGBitmapByteOrder16Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
            CGContextRef widened = CGBitmapContextCreate(NULL, kSide, kSide, 16, 0, table, wide);
            CGContextSetBlendMode(widened, kCGBlendModeCopy);
            CGContextDrawImage(widened, CGRectMake(0, 0, kSide, kSide), image);
            CGImageRef widenedImage = CGBitmapContextCreateImage(widened);
            CGContextRef reference = CGBitmapContextCreate(NULL, kSide, kSide, 16, 0, generic, wide);
            CGContextSetBlendMode(reference, kCGBlendModeCopy);
            CGContextDrawImage(reference, CGRectMake(0, 0, kSide, kSide), widenedImage);
            const uint16_t *expected = CGBitmapContextGetData(reference);
            size_t expectedRow = CGBitmapContextGetBytesPerRow(reference) / 2;
            int worst[2] = { 0, 0 };
            for (int route = 0; route < 2; route++) {
                unsigned char *out = calloc(kSide * kSide, 4);
                CGContextRef context = CGBitmapContextCreate(out, kSide, kSide, 8, kSide * 4, generic, kBGRA);
                CGContextSetBlendMode(context, kCGBlendModeCopy);
                (route ? system : archiveDraw)(context, CGRectMake(0, 0, kSide, kSide), image);
                CGContextRelease(context);
                for (size_t y = 0; y < kSide; y++) {
                    for (size_t x = 0; x < kSide; x++) {
                        for (int c = 0; c < 4; c++) {
                            static const int bgra[4] = { 2, 1, 0, 3 };
                            int want = (int)lround(expected[y * expectedRow + x * 4 + c] / 257.0);
                            int error = abs((int)out[(y * kSide + x) * 4 + bgra[c]] - want);
                            if (error > worst[route])
                                worst[route] = error;
                        }
                    }
                }
                free(out);
            }
            printf("    table-described space into an 8-bit bitmap: worst level difference %d, 10.9's own route %d\n", worst[0], worst[1]);
            check(worst[0] <= 1, "a translucent image in a table-described space matches as a 16-bit match does");
            check(worst[1] > 1, "10.9's own 8-bit bitmap route misses some of it by more");
            CGContextRelease(reference);
            CGImageRelease(widenedImage);
            CGContextRelease(widened);
            CGImageRelease(image);
            free(pixels);
            CGColorSpaceRelease(table);
        }
        CGColorSpaceRelease(generic);
        if (tableProfile)
            CFRelease(tableProfile);
    }

    // An image wider than QuartzCore's texture limit is drawn from parts of its per-space image: the visible
    // columns 13000 to 16999 of a 17000x2 linear-sRGB ramp, drawn twice into a 4000-wide surface, land within
    // one level of their exact encoding both times.
    {
        enum { kWide = 17000, kTall = 2, kSurface = 4000, kFirst = 13000 };
        CGImageRef image = createLevelsImage(linear, kWide, kTall, false, true);
        IOSurfaceRef surface = createSurface(kSurface, kTall);
        CGContextRef context = CGIOSurfaceContextCreate(surface, kSurface, kTall, 8, 32, sRGB, kBGRA);
        int worst = 0;
        for (int draw = 0; draw < 2; draw++) {
            CGContextClearRect(context, CGRectMake(0, 0, kSurface, kTall));
            CGContextDrawImage(context, CGRectMake(-kFirst, 0, kWide, kTall), image);
            CGContextFlush(context);
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            const unsigned char *base = IOSurfaceGetBaseAddress(surface);
            for (size_t x = 0; x < kSurface; x++) {
                int error = abs((int)base[x * 4 + 1] - exactEncoding(((x + kFirst) % 256) / 255.0));
                if (error > worst)
                    worst = error;
            }
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        }
        printf("    oversized image worst level error: %d\n", worst);
        check(worst <= 1, "an image over the texture limit is matched in the parts drawn of it");
        CGContextRelease(context);
        CFRelease(surface);
        CGImageRelease(image);
    }

    // Straight alpha: every colour level c at every alpha a, matched within one level of exact.
    {
        enum { kSide = 256 };
        unsigned char *pixels = calloc(kSide * kSide, 4);
        for (size_t a = 1; a < kSide; a++) {
            for (size_t c = 0; c < kSide; c++) {
                unsigned char *p = pixels + (kSide - 1 - a) * kSide * 4 + c * 4;
                p[0] = p[1] = p[2] = (unsigned char)c;
                p[3] = (unsigned char)a;
            }
        }
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
        CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, linear, (CGBitmapInfo)kCGImageAlphaLast, provider, NULL, false,
            kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        IOSurfaceRef surface = createSurface(kSide, kSide);
        CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, sRGB, kBGRA);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
        CGContextFlush(context);
        CGContextRef bitmap = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, sRGB, kBGRA);
        CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
        CGContextDrawImage(bitmap, CGRectMake(0, 0, kSide, kSide), image);
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *base = IOSurfaceGetBaseAddress(surface);
        size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
        bool sameAsBitmap = true;
        for (size_t y = 0; y < kSide; y++)
            sameAsBitmap &= !memcmp(base + y * rowBytes, (const unsigned char *)CGBitmapContextGetData(bitmap) + y * kSide * 4, kSide * 4);
        CGContextRelease(bitmap);
        int worst = 0;
        for (size_t a = 1; a < kSide; a++) {
            for (size_t c = 0; c < kSide; c++) {
                double linearValue = c / 255.0;
                double encoded = linearValue <= 0.0031308 ? linearValue * 12.92 : 1.055 * pow(linearValue, 1 / 2.4) - 0.055;
                int exact = (int)lround(encoded * (double)a);
                int error = abs((int)base[(kSide - 1 - a) * rowBytes + c * 4 + 1] - exact);
                if (error > worst)
                    worst = error;
            }
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        printf("    worst level error, straight alpha: %d\n", worst);
        check(sameAsBitmap, "a straight-alpha linear-sRGB image matches as CoreGraphics' bitmap route does");
        check(worst <= 2, "which is within two levels of exact");
        CGContextRelease(context);
        CFRelease(surface);
        CGImageRelease(image);
        free(pixels);
    }

    // A partially decoded CMYK JPEG: an opaque CMYK image whose first `decoded` rows are covered by a
    // 1-pixel-wide mask (0 paints, 255 leaves the destination), drawn over opaque white.
    {
        enum { kSide = 128, kDecoded = 40 };
        CGColorSpaceRef cmyk = CGColorSpaceCreateWithName(kCGColorSpaceGenericCMYK);
        unsigned char *pixels = calloc(kSide * kSide, 4);
        for (size_t i = 0; i < kSide * kSide; i++)
            pixels[i * 4 + 0] = 255;   // full cyan
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
        CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, cmyk, (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, false,
            kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        unsigned char coverage[kSide];
        memset(coverage, 255, sizeof(coverage));
        memset(coverage, 0, kDecoded);
        CFDataRef coverageData = CFDataCreate(NULL, coverage, sizeof(coverage));
        CGDataProviderRef maskProvider = CGDataProviderCreateWithCFData(coverageData);
        CGImageRef mask = CGImageMaskCreate(1, kSide, 8, 8, 1, maskProvider, NULL, false);
        CGImageRef masked = CGImageCreateWithMask(image, mask);
        IOSurfaceRef surface = createSurface(kSide, kSide);
        CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, sRGB, kBGRA);
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), masked);
        CGContextFlush(context);
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *base = IOSurfaceGetBaseAddress(surface);
        size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
        const unsigned char *decodedPixel = base + 10 * rowBytes + 64 * 4;
        const unsigned char *pendingPixel = base + 100 * rowBytes + 64 * 4;
        printf("    masked CMYK JPEG: decoded row BGRA %u,%u,%u,%u; pending row BGRA %u,%u,%u,%u\n", decodedPixel[0], decodedPixel[1],
            decodedPixel[2], decodedPixel[3], pendingPixel[0], pendingPixel[1], pendingPixel[2], pendingPixel[3]);
        check(decodedPixel[2] < 128 && decodedPixel[0] > 128, "a masked CMYK image paints its decoded rows");
        check(pendingPixel[0] == 255 && pendingPixel[1] == 255 && pendingPixel[2] == 255, "and leaves the rows its mask excludes");
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        CGContextRelease(context);
        CFRelease(surface);
        CGImageRelease(masked);
        CGImageRelease(mask);
        CGDataProviderRelease(maskProvider);
        CFRelease(coverageData);
        CGImageRelease(image);
        free(pixels);
        CGColorSpaceRelease(cmyk);
    }

    CGColorSpaceRelease(linear);
    CGColorSpaceRelease(sRGB);
    return failures ? 1 : 0;
}
