// Two replacements in polyfills/c/CoreGraphics.c, measured in the topology WebKit runs them in: several
// images in one process, each carrying its own copy of the archive.
//
// CGContextDrawImage into an IOSurface context. 10.9's QuartzCore keeps one colour-matched copy of a
// CGImage, keyed by the image alone, and hands it to every later IOSurface draw of that image whatever
// the destination's colour space. Gate A fills that cache through 10.9's own definition with a Display
// P3 destination and then draws through the archive into an sRGB destination. Gate B draws one image
// through two sibling images' copies of the replacement into destinations of different colour spaces,
// alternating, and checks every draw.
//
// CGContextGetColorSpace on a context built on a CGContextDelegate. The deGetColorSpace callback is
// installed through one image's CGContextDelegateSetCallback and read through a sibling image's
// CGContextGetColorSpace, which must hand it a gstate.
//
// Built three ways by build-polyfill.sh: -DWK_PROBE_SIDE_A and -DWK_PROBE_SIDE_B each make a dylib
// wrapping the archive's definitions, and the plain build is the program that loads both.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct CGContextDelegate *CGContextDelegateRef;
typedef void *CGGStateRef;
CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
CGContextDelegateRef CGContextDelegateCreate(void *info);
CGContextRef CGContextCreateWithDelegate(CGContextDelegateRef, int type, void *, void *);
void CGContextDelegateSetCallback(CGContextDelegateRef, int name, void (*callback)(void));
CGColorSpaceRef CGContextGetColorSpace(CGContextRef);
bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef, CGColorSpaceRef);

enum { kSide = 4, kDeGetColorSpace = 30 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

#if defined(WK_PROBE_SIDE_A) || defined(WK_PROBE_SIDE_B)

__attribute__((visibility("default"))) void wk_probe_draw(CGContextRef context, CGImageRef image)
{
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
}

__attribute__((visibility("default"))) void wk_probe_set_callback(CGContextDelegateRef delegate, void (*callback)(void))
{
    CGContextDelegateSetCallback(delegate, kDeGetColorSpace, callback);
}

__attribute__((visibility("default"))) CGColorSpaceRef wk_probe_color_space(CGContextRef context)
{
    return CGContextGetColorSpace(context);
}

#else

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

// 10.9's definition, reached through dyld's image lookup: dlsym answers registered names with an
// archive's definition.
static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

static IOSurfaceRef createSurface(void)
{
    int side = kSide, bytesPerElement = 4;
    unsigned format = 'BGRA';
    CFNumberRef width = CFNumberCreate(NULL, kCFNumberIntType, &side);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    CFNumberRef pixelFormat = CFNumberCreate(NULL, kCFNumberIntType, &format);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    const void *values[] = { width, width, element, pixelFormat };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(width);
    CFRelease(element);
    CFRelease(pixelFormat);
    return surface;
}

// An opaque sRGB red image over its own bytes.
static CGImageRef createRedImage(CGColorSpaceRef sRGB)
{
    unsigned char *pixels = malloc(kSide * kSide * 4);
    for (int i = 0; i < kSide * kSide; i++)
        memcpy(pixels + i * 4, "\x00\x00\xff\xff", 4);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kSide * kSide * 4, NULL);
    CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide * 4, sRGB, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

// Draws `image` through `draw` into a fresh IOSurface context of `space` and reads one pixel as R,G,B.
static void drawAndRead(void (*draw)(CGContextRef, CGImageRef), DrawImageFn system, CGColorSpaceRef space, CGImageRef image, unsigned rgb[3])
{
    IOSurfaceRef surface = createSurface();
    CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, space, kBGRA);
    if (draw)
        draw(context, image);
    else
        system(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextFlush(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *p = IOSurfaceGetBaseAddress(surface);
    rgb[0] = p[2];
    rgb[1] = p[1];
    rgb[2] = p[0];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CGContextRelease(context);
    CFRelease(surface);
}

static bool near(const unsigned rgb[3], unsigned r, unsigned g, unsigned b)
{
    return abs((int)rgb[0] - (int)r) <= 1 && abs((int)rgb[1] - (int)g) <= 1 && abs((int)rgb[2] - (int)b) <= 1;
}

static CGColorSpaceRef gCallbackAnswer;
static int gCallbackCalls;
static bool gCallbackSawGState;
static CGColorSpaceRef recordingColorSpace(CGContextDelegateRef delegate, void *renderingState, CGGStateRef gstate)
{
    (void)delegate;
    (void)renderingState;
    gCallbackCalls++;
    gCallbackSawGState = gstate != NULL;
    return gCallbackAnswer;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <side-a.dylib> <side-b.dylib>\n", argv[0]);
        return 2;
    }
    void *sideA = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void *sideB = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    check(sideA && sideB, "both images load");
    void (*drawA)(CGContextRef, CGImageRef) = sideA ? dlsym(sideA, "wk_probe_draw") : NULL;
    void (*drawB)(CGContextRef, CGImageRef) = sideB ? dlsym(sideB, "wk_probe_draw") : NULL;
    void (*setCallbackA)(CGContextDelegateRef, void (*)(void)) = sideA ? dlsym(sideA, "wk_probe_set_callback") : NULL;
    CGColorSpaceRef (*colorSpaceB)(CGContextRef) = sideB ? dlsym(sideB, "wk_probe_color_space") : NULL;
    DrawImageFn system = systemDrawImage();
    check(drawA && drawB && setCallbackA && colorSpaceB, "each image exports its wrappers");
    check(system != NULL, "10.9's CGContextDrawImage resolves by image lookup");
    if (!drawA || !drawB || !setCallbackA || !colorSpaceB || !system)
        return 1;

    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3"));
    check(sRGB && adobe && p3, "sRGB, Adobe RGB and Display P3 spaces exist");
    unsigned rgb[3];

    // The cache premise, through 10.9's definition alone: this is what the replacement exists for.
    CGImageRef premise = createRedImage(sRGB);
    drawAndRead(NULL, system, p3, premise, rgb);
    check(near(rgb, 234, 51, 35), "10.9: sRGB red into a Display P3 surface reads 234,51,35");
    drawAndRead(NULL, system, sRGB, premise, rgb);
    check(near(rgb, 234, 51, 35), "10.9: the same image into an sRGB surface reuses that matching");
    CGImageRelease(premise);

    // Gate A: QuartzCore's cache for the image is filled by a caller outside the archive first.
    CGImageRef imageA = createRedImage(sRGB);
    drawAndRead(NULL, system, p3, imageA, rgb);
    drawAndRead(drawA, NULL, sRGB, imageA, rgb);
    check(near(rgb, 255, 0, 0), "gate A: archive draw into sRGB after a system draw into P3 reads 255,0,0");
    drawAndRead(drawA, NULL, p3, imageA, rgb);
    check(near(rgb, 234, 51, 35), "gate A: archive draw into P3 reads 234,51,35");
    CGImageRelease(imageA);

    // Gate B: sibling images alternate destinations for one image.
    CGImageRef imageB = createRedImage(sRGB);
    bool allRight = true;
    for (int round = 0; round < 60; round++) {
        void (*draw)(CGContextRef, CGImageRef) = round % 2 ? drawB : drawA;
        switch (round % 3) {
        case 0: drawAndRead(draw, NULL, p3, imageB, rgb); allRight &= near(rgb, 234, 51, 35); break;
        case 1: drawAndRead(draw, NULL, sRGB, imageB, rgb); allRight &= near(rgb, 255, 0, 0); break;
        case 2: drawAndRead(draw, NULL, adobe, imageB, rgb); allRight &= near(rgb, 219, 0, 0); break;
        }
    }
    check(allRight, "gate B: 60 draws across two images and three spaces all match their space");
    CGImageRelease(imageB);

    // The delegate's deGetColorSpace, installed in one image and read in another.
    CGContextDelegateRef delegate = CGContextDelegateCreate(NULL);
    CGContextRef recording = CGContextCreateWithDelegate(delegate, 0, NULL, NULL);
    check(colorSpaceB(recording) == NULL, "a delegate context with no callback has no colour space");
    gCallbackAnswer = p3;
    setCallbackA(delegate, (void (*)(void))recordingColorSpace);
    CGColorSpaceRef answered = colorSpaceB(recording);
    check(gCallbackCalls == 1, "the sibling image's CGContextGetColorSpace calls the callback");
    check(gCallbackSawGState, "the callback receives the context's gstate");
    check(answered && CGColorSpaceEqualToColorSpace(answered, p3), "the callback's colour space is the answer");
    CGContextRelease(recording);
    CFRelease(delegate);

    return failures ? 1 : 0;
}
#endif
