// CGContextDrawImage into an IOSurface context, for an image CGIOSurfaceContextCreateImage made, through
// the replacements in polyfills/c/CoreGraphics.c.
//
// Gate A: a canvas-sized draw of such an image into a destination of its own colour space, clipped to a
// small rect, costs a fraction of a draw that reads the whole surface (a CGImageCreateCopy of the same
// image through 10.9's own definition).
// Gate B: the image's surface written while the image lives, so 10.9 detaches it onto a copy of its
// bytes and caches it like any other image; the image then drawn into a destination of another colour
// space and after that into one of its own, which reads the colour the image was made with. 10.9's own
// definition, handed the image for both draws, keeps the first destination's matching for the second.
// Gate C, with an accelerated QuartzCore renderer: a draw into a destination of another colour space is
// drawn from the surface too. Gate D, without one: an image holding pixels of alpha 0 and full colour,
// which the software renderer's colour match reads out of bounds for, draws into another colour space.
// Gate E, without one: a clipped draw into another colour space of a fresh image of a surface being drawn
// into and flushed costs a fraction of matching the whole image, and paints what the whole image's match
// paints. Gate F, without one: an image whose context goes on drawing past a queue's worth after it is
// made, drawn at once into another colour space, paints the image's own pixels.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <OpenGL/OpenGL.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
CGImageRef CGIOSurfaceContextCreateImage(CGContextRef);
IOSurfaceRef CGIOSurfaceContextGetSurface(CGContextRef);

static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

// 10.9's definition, reached through dyld's image lookup: dlsym answers registered names with the
// archive's definition.
static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

static CGContextRef createContext(int width, int height, CGColorSpaceRef space)
{
    int bytesPerElement = 4, bytesPerRow = width * 4;
    unsigned format = 'BGRA';
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &width);
    CFNumberRef h = CFNumberCreate(NULL, kCFNumberIntType, &height);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    CFNumberRef row = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerRow);
    CFNumberRef pixelFormat = CFNumberCreate(NULL, kCFNumberIntType, &format);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow, kIOSurfacePixelFormat };
    const void *values[] = { w, h, element, row, pixelFormat };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CGContextRef context = surface ? CGIOSurfaceContextCreate(surface, width, height, 8, 32, space, kBGRA) : NULL;
    CFRelease(properties);
    CFRelease(w);
    CFRelease(h);
    CFRelease(element);
    CFRelease(row);
    CFRelease(pixelFormat);
    if (surface)
        CFRelease(surface);
    return context;
}

static void fill(CGContextRef context, int side, CGFloat r, CGFloat g, CGFloat b)
{
    CGContextSetRGBFillColor(context, r, g, b, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGContextFlush(context);
}

static void readPixel(CGContextRef context, int rgb[3])
{
    CGContextFlush(context);
    IOSurfaceRef surface = CGIOSurfaceContextGetSurface(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *p = IOSurfaceGetBaseAddress(surface);
    rgb[0] = p[2];
    rgb[1] = p[1];
    rgb[2] = p[0];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}

static double milliseconds(void)
{
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom)
        mach_timebase_info(&timebase);
    return mach_absolute_time() * (double)timebase.numer / timebase.denom / 1e6;
}

// Milliseconds per clipped draw of a fresh image of `source` into `destination`, through `system` when
// given and the replacement otherwise, with `copy` drawing a CGImageCreateCopy of the image: the best of
// three runs after an untimed draw.
static double clippedDrawCost(CGContextRef source, CGContextRef destination, int width, int height, DrawImageFn system, int copy)
{
    enum { kDraws = 20 };
    double best = INFINITY;
    for (int run = 0; run < 4; run++) {
        double start = milliseconds();
        for (int i = 0; i < (run ? kDraws : 1); i++) {
            CGContextSetRGBFillColor(source, 0, 0, 0, 1);
            CGContextFillRect(source, CGRectMake(100 + i, 100, 8, 8));
            CGImageRef image = CGIOSurfaceContextCreateImage(source);
            CGImageRef drawn = copy ? CGImageCreateCopy(image) : CGImageRetain(image);
            CGContextSaveGState(destination);
            CGContextClipToRect(destination, CGRectMake(96 + i, 96, 16, 16));
            if (system)
                system(destination, CGRectMake(0, 0, width, height), drawn);
            else
                CGContextDrawImage(destination, CGRectMake(0, 0, width, height), drawn);
            CGContextRestoreGState(destination);
            CGContextFlush(destination);
            CGImageRelease(drawn);
            CGImageRelease(image);
        }
        if (run)
            best = fmin(best, (milliseconds() - start) / kDraws);
    }
    return best;
}

// Makes an image of a 234,51,35 surface, writes the surface (the detach), and draws the image into a
// destination of `other` and then into one of its own space, through `system` when given; reads the second.
static void detachedDraws(int side, CGColorSpaceRef own, CGColorSpaceRef other, DrawImageFn system, int rgb[3])
{
    CGContextRef source = createContext(side, side, own);
    fill(source, side, 234 / 255.0, 51 / 255.0, 35 / 255.0);
    CGImageRef image = CGIOSurfaceContextCreateImage(source);
    fill(source, side, 0, 0, 1);
    CGContextRef first = createContext(side, side, other);
    CGContextRef second = createContext(side, side, own);
    CGRect rect = CGRectMake(0, 0, side, side);
    if (system) {
        system(first, rect, image);
        CGContextFlush(first);
        system(second, rect, image);
    } else {
        CGContextDrawImage(first, rect, image);
        CGContextFlush(first);
        CGContextDrawImage(second, rect, image);
    }
    readPixel(second, rgb);
    CGImageRelease(image);
    CGContextRelease(first);
    CGContextRelease(second);
    CGContextRelease(source);
}

// CA::CG::IOSurfaceRenderer::acquire's pixel format, as the replacement probes it.
static int hasAcceleratedRenderer(void)
{
    const CGLPixelFormatAttribute attributes[] = { kCGLPFAColorSize, 32, kCGLPFAAccelerated, kCGLPFANoRecovery,
        kCGLPFAAllowOfflineRenderers, (CGLPixelFormatAttribute)1262, 0 };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    int accelerated = 0;
    if (!CGLChoosePixelFormat(attributes, &format, &count) && format) {
        CGLContextObj context = NULL;
        if (count > 0 && !CGLCreateContext(format, NULL, &context) && context) {
            accelerated = 1;
            CGLDestroyContext(context);
        }
        CGLDestroyPixelFormat(format);
    }
    return accelerated;
}

int main(void)
{
    DrawImageFn system = systemDrawImage();
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    if (!system || !sRGB || !adobe)
        return 1;

    printf("CGIOSurfaceContextCreateImage image, same colour space:\n");
    {
        const int width = 1024, height = 4096;
        CGContextRef source = createContext(width, height, sRGB);
        CGContextRef destination = createContext(width, height, sRGB);
        if (!source || !destination)
            return 1;
        fill(source, height, 1, 1, 1);
        double replacement = clippedDrawCost(source, destination, width, height, NULL, 0);
        double surfaceCopy = clippedDrawCost(source, destination, width, height, system, 1);
        printf("    ms per draw: replacement %.2f, copy through 10.9 %.2f\n", replacement, surfaceCopy);
        check(replacement * 5 < surfaceCopy, "A: drawn from its surface, not through a copy of it");
        CGContextRelease(source);
        CGContextRelease(destination);
    }

    int accelerated = hasAcceleratedRenderer();
    printf("CGIOSurfaceContextCreateImage image, another colour space:\n");
    if (accelerated) {
        const int width = 1024, height = 4096;
        CGContextRef source = createContext(width, height, sRGB);
        CGContextRef destination = createContext(width, height, adobe);
        if (!source || !destination)
            return 1;
        fill(source, height, 1, 1, 1);
        double replacement = clippedDrawCost(source, destination, width, height, NULL, 0);
        double surfaceCopy = clippedDrawCost(source, destination, width, height, system, 1);
        printf("    ms per draw: replacement %.2f, copy through 10.9 %.2f\n", replacement, surfaceCopy);
        check(replacement * 5 < surfaceCopy, "C: drawn from its surface, not through a copy of it");
        CGContextRelease(source);
        CGContextRelease(destination);
    } else {
        const int side = 256;
        CGContextRef source = createContext(side, side, sRGB);
        IOSurfaceRef surface = CGIOSurfaceContextGetSurface(source);
        IOSurfaceLock(surface, 0, NULL);
        unsigned char *base = IOSurfaceGetBaseAddress(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                unsigned char *pixel = base + y * stride + x * 4;
                pixel[0] = pixel[1] = pixel[2] = 255;
                pixel[3] = (x + y) & 1 ? 0 : 128;
            }
        }
        IOSurfaceUnlock(surface, 0, NULL);
        CGImageRef image = CGIOSurfaceContextCreateImage(source);
        for (int i = 0; i < 20; i++) {
            CGContextRef destination = createContext(side, side, adobe);
            CGContextDrawImage(destination, CGRectMake(0.5, 0.25, side * 0.9, side * 0.9), image);
            CGContextFlush(destination);
            CGContextRelease(destination);
        }
        CGImageRelease(image);
        CGContextRelease(source);
        check(1, "D: alpha-0 colour pixels draw into another colour space");

        const int width = 1024, height = 4096;
        CGContextRef gradientSource = createContext(width, height, sRGB);
        CGFloat components[] = { 0.1, 0.7, 0.3, 1, 0.9, 0.2, 0.6, 0.5 };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(sRGB, components, NULL, 2);
        CGContextDrawLinearGradient(gradientSource, gradient, CGPointMake(0, 0), CGPointMake(width, height), 0);
        CGGradientRelease(gradient);
        CGContextRef marked = createContext(width, height, adobe), whole = createContext(width, height, adobe);
        double start = milliseconds();
        for (int i = 0; i < 20; i++) {
            CGContextFillRect(gradientSource, CGRectMake(width - 1 - i, 0, 1, 1));
            CGContextFlush(gradientSource);
            CGImageRef image = CGIOSurfaceContextCreateImage(gradientSource);
            CGContextSaveGState(marked);
            CGContextClipToRect(marked, CGRectMake(96 + i, 96, 16, 16));
            CGContextDrawImage(marked, CGRectMake(0, 0, width, height), image);
            CGContextRestoreGState(marked);
            CGContextFlush(marked);
            CGImageRelease(image);
        }
        double rows = (milliseconds() - start) / 20;
        start = milliseconds();
        for (int i = 0; i < 20; i++) {
            CGContextFillRect(gradientSource, CGRectMake(width - 1 - i, 0, 1, 1));
            CGContextFlush(gradientSource);
            CGImageRef image = CGIOSurfaceContextCreateImage(gradientSource);
            CGImageRef copy = CGImageCreateCopy(image);
            CGContextSaveGState(whole);
            CGContextClipToRect(whole, CGRectMake(96 + i, 96, 16, 16));
            CGContextDrawImage(whole, CGRectMake(0, 0, width, height), copy);
            CGContextRestoreGState(whole);
            CGContextFlush(whole);
            CGImageRelease(copy);
            CGImageRelease(image);
        }
        double wholeImage = (milliseconds() - start) / 20;
        printf("    ms per draw: visible rows %.2f, whole image %.2f\n", rows, wholeImage);
        check(rows * 5 < wholeImage, "E: matches the rows the clip shows, not the whole image");

        IOSurfaceRef markedSurface = CGIOSurfaceContextGetSurface(marked), wholeSurface = CGIOSurfaceContextGetSurface(whole);
        IOSurfaceLock(markedSurface, kIOSurfaceLockReadOnly, NULL);
        IOSurfaceLock(wholeSurface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *a = IOSurfaceGetBaseAddress(markedSurface), *b = IOSurfaceGetBaseAddress(wholeSurface);
        size_t markedStride = IOSurfaceGetBytesPerRow(markedSurface), wholeStride = IOSurfaceGetBytesPerRow(wholeSurface);
        int worst = 0;
        for (int y = height - 140; y < height - 80; y++) {
            for (int x = 80; x < 140; x++) {
                for (int k = 0; k < 4; k++) {
                    int d = abs((int)a[y * markedStride + x * 4 + k] - (int)b[y * wholeStride + x * 4 + k]);
                    if (d > worst)
                        worst = d;
                }
            }
        }
        IOSurfaceUnlock(markedSurface, kIOSurfaceLockReadOnly, NULL);
        IOSurfaceUnlock(wholeSurface, kIOSurfaceLockReadOnly, NULL);
        printf("    worst level difference from the whole image's match: %d\n", worst);
        check(!worst, "E: paints what the whole image's match paints");

        const int raceSide = 512;
        CGContextRef raceSource = createContext(raceSide, raceSide, sRGB);
        CGContextRef expectedDestination = createContext(raceSide, raceSide, adobe);
        fill(raceSource, raceSide, 234 / 255.0, 51 / 255.0, 35 / 255.0);
        CGImageRef first = CGIOSurfaceContextCreateImage(raceSource);
        CGImageRef firstCopy = CGImageCreateCopy(first);
        CGContextDrawImage(expectedDestination, CGRectMake(0, 0, raceSide, raceSide), firstCopy);
        CGImageRelease(firstCopy);
        CGImageRelease(first);
        int expected[3];
        readPixel(expectedDestination, expected);
        int mismatches = 0;
        for (int iteration = 0; iteration < 50; iteration++) {
            fill(raceSource, raceSide, 234 / 255.0, 51 / 255.0, 35 / 255.0);
            CGImageRef image = CGIOSurfaceContextCreateImage(raceSource);
            CGContextSetRGBFillColor(raceSource, 0, 0, 1, 1);
            for (int i = 0; i < 4000; i++)
                CGContextFillRect(raceSource, CGRectMake(i % raceSide, (i * 7) % raceSide, 64, 64));
            CGContextRef destination = createContext(raceSide, raceSide, adobe);
            CGContextDrawImage(destination, CGRectMake(0, 0, raceSide, raceSide), image);
            CGContextFlush(destination);
            IOSurfaceRef surface = CGIOSurfaceContextGetSurface(destination);
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            const unsigned char *base = IOSurfaceGetBaseAddress(surface);
            size_t stride = IOSurfaceGetBytesPerRow(surface);
            for (int y = 0; y < raceSide; y += 7) {
                for (int x = 0; x < raceSide; x += 7) {
                    const unsigned char *pixel = base + y * stride + x * 4;
                    if (pixel[2] != expected[0] || pixel[1] != expected[1] || pixel[0] != expected[2])
                        mismatches++;
                }
            }
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            CGContextRelease(destination);
            CGImageRelease(image);
            CGContextFlush(raceSource);
        }
        printf("    expected %d,%d,%d; mismatched samples over 50 draws: %d\n", expected[0], expected[1], expected[2], mismatches);
        check(!mismatches, "F: paints the image's own pixels while its context goes on drawing");
        CGContextRelease(expectedDestination);
        CGContextRelease(raceSource);
        CGContextRelease(marked);
        CGContextRelease(whole);
        CGContextRelease(gradientSource);
    }

    printf("CGIOSurfaceContextCreateImage image after a detach:\n");
    {
        const int sides[] = { 4, 64 };
        for (unsigned i = 0; i < sizeof(sides) / sizeof(sides[0]); i++) {
            int replacement[3], system10_9[3];
            detachedDraws(sides[i], sRGB, adobe, NULL, replacement);
            detachedDraws(sides[i], sRGB, adobe, system, system10_9);
            printf("    %dx%d: replacement %d,%d,%d; 10.9's definition %d,%d,%d\n", sides[i], sides[i],
                replacement[0], replacement[1], replacement[2], system10_9[0], system10_9[1], system10_9[2]);
            char what[96];
            snprintf(what, sizeof(what), "B: %dx%d reads 234,51,35 after another space", sides[i], sides[i]);
            check(replacement[0] == 234 && replacement[1] == 51 && replacement[2] == 35, what);
            if (!accelerated) {
                snprintf(what, sizeof(what), "B: %dx%d 10.9's definition keeps the other space's matching", sides[i], sides[i]);
                check(system10_9[0] != 234 || system10_9[1] != 51 || system10_9[2] != 35, what);
            }
        }
    }

    CGColorSpaceRelease(sRGB);
    CGColorSpaceRelease(adobe);
    return failures != 0;
}
