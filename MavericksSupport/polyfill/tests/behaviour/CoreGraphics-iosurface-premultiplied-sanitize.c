// CGContextDrawTiledImage and CGPatternCreateWithImage2 (polyfills/c/CoreGraphics.c) against 10.9's own
// definitions, reached by image lookup. 10.9's software colour match reads a colour cube out of bounds
// for a premultiplied pixel whose alpha samples to 0 (8-bit alpha 0, or a 16-bit alpha below 0x0100)
// with a nonzero colour; the replacements zero those pixels' colours and leave every other byte alone.
// A pixel that only violates premultiply with a nonzero alpha never crashes and stays untouched.
//
// The crash cases run in a child: this binary re-executed with --crash-case N. A forked child cannot
// make an IOSurface context on this OS, so the child is a fresh process. A child that dies on a signal,
// or cannot make its context, is a FAIL. Against 10.9's own definitions those children crash, so this
// gate fails on stock. The byte-identity cases run in-process, comparing the replacement with 10.9.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
CGPatternRef CGPatternCreateWithImage2(CGImageRef, CGAffineTransform, CGPatternTiling);

enum { kSide = 64 };
static const CGBitmapInfo kRGBA8 = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
static const CGBitmapInfo kRGBA16 = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Big;
static int failures;
static void check(int ok, const char *what) { printf("  %-78s %s\n", what, ok ? "ok" : "FAIL"); fflush(stdout); if (!ok) failures++; }

typedef void (*DrawTiledFn)(CGContextRef, CGRect, CGImageRef);
static void *systemSymbol(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}
typedef CGPatternRef (*PatternFn)(CGImageRef, CGAffineTransform, CGPatternTiling);
static DrawTiledFn gSystemTiled;
static PatternFn gSystemPattern;
static CGColorSpaceRef gSRGB, gAdobe;

static IOSurfaceRef makeSurface(void)
{
    int side = kSide, bpe = 4; unsigned fmt = 'BGRA';
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &side), e = CFNumberCreate(NULL, kCFNumberIntType, &bpe), f = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
    const void *k[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    const void *v[] = { w, w, e, f };
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d); CFRelease(d); CFRelease(w); CFRelease(e); CFRelease(f); return s;
}
// Tile `image` into a fresh IOSurface of `space` and copy the surface bytes.
static unsigned char *tileToSurface(void (*draw)(CGContextRef, CGRect, CGImageRef), CGColorSpaceRef space, CGImageRef image)
{
    IOSurfaceRef s = makeSurface();
    CGContextRef c = CGIOSurfaceContextCreate(s, kSide, kSide, 8, 32, space, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    draw(c, CGRectMake(0, 0, kSide, kSide), image);
    CGContextFlush(c);
    unsigned char *out = malloc(kSide * kSide * 4);
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    memcpy(out, IOSurfaceGetBaseAddress(s), kSide * kSide * 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CGContextRelease(c); CFRelease(s); return out;
}

// 8-bit RGBA (big-endian: R,G,B,A). pixel0 gets (r,g,b,a); the rest opaque grey.
static CGImageRef make8RGBA(uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
    unsigned char *p = malloc(kSide * kSide * 4);
    for (size_t i = 0; i < (size_t)kSide * kSide; i++) { p[i*4]=0x80; p[i*4+1]=0x80; p[i*4+2]=0x80; p[i*4+3]=0xFF; }
    p[0]=r; p[1]=g; p[2]=b; p[3]=a;
    CGDataProviderRef d = CGDataProviderCreateWithData(NULL, p, kSide*kSide*4, NULL);
    CGImageRef im = CGImageCreate(kSide, kSide, 8, 32, kSide*4, gSRGB, kRGBA8, d, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(d); return im;
}
// 16-bit RGBA (big-endian). pixel0 gets the given 16-bit components.
static CGImageRef make16RGBA(uint16_t r, uint16_t g, uint16_t b, uint16_t a)
{
    uint8_t *p = malloc(kSide * kSide * 8);
    for (size_t i = 0; i < (size_t)kSide * kSide; i++) { uint16_t v[4]={0x8000,0x8000,0x8000,0xFFFF}; for(int c=0;c<4;c++){p[i*8+c*2]=v[c]>>8;p[i*8+c*2+1]=(uint8_t)v[c];} }
    uint16_t v0[4]={r,g,b,a}; for(int c=0;c<4;c++){p[c*2]=v0[c]>>8;p[c*2+1]=(uint8_t)v0[c];}
    CGDataProviderRef d = CGDataProviderCreateWithData(NULL, p, kSide*kSide*8, NULL);
    CGImageRef im = CGImageCreate(kSide, kSide, 16, 64, kSide*8, gSRGB, kRGBA16, d, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(d); return im;
}
// 8-bit grey+alpha (2 bytes/pixel, grey then alpha). pixel0 grey g, alpha a.
static CGImageRef make8GrayAlpha(uint8_t g, uint8_t a)
{
    unsigned char *p = malloc(kSide * kSide * 2);
    for (size_t i = 0; i < (size_t)kSide * kSide; i++) { p[i*2]=0x80; p[i*2+1]=0xFF; }
    p[0]=g; p[1]=a;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef d = CGDataProviderCreateWithData(NULL, p, kSide*kSide*2, NULL);
    CGImageRef im = CGImageCreate(kSide, kSide, 8, 16, kSide*2, gray, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, d, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(gray); CGDataProviderRelease(d); return im;
}

// Crash-case worker, run in the child. It calls CGContextDrawTiledImage directly, so in the archive build
// the draw is the replacement. Exit 3 means the context could not be made and nothing was tested.
static int crashWorker(int kind)
{
    gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = kind == 0 ? make16RGBA(0x8000, 0x8000, 0x8000, 0x00ff) : make8GrayAlpha(0x40, 0x00);
    CGColorSpaceRef wide = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    IOSurfaceRef s = makeSurface();
    CGContextRef c = s && wide ? CGIOSurfaceContextCreate(s, kSide, kSide, 8, 32, wide, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
    if (!image || !c)
        return 3;
    CGContextDrawTiledImage(c, CGRectMake(0, 0, kSide, kSide), image);
    CGContextFlush(c);
    return 0;
}
// Runs crash case `kind` in a re-executed child; true only if it made its context, drew, and exited 0.
static bool childSurvives(const char *self, int kind)
{
    char kindArg[2] = { (char)('0' + kind), 0 };
    char *argv[] = { (char *)self, "--crash-case", kindArg, NULL };
    pid_t pid;
    if (posix_spawn(&pid, self, NULL, NULL, argv, environ))
        return false;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid)
        return false;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--crash-case"))
        return crashWorker(argv[2][0] - '0');
    gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    gAdobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    gSystemTiled = (DrawTiledFn)systemSymbol("_CGContextDrawTiledImage");
    gSystemPattern = (PatternFn)systemSymbol("_CGPatternCreateWithImage2");
    check(gSRGB && gAdobe && gSystemTiled, "sRGB, Adobe RGB, and 10.9's CGContextDrawTiledImage resolve");
    if (!gSystemTiled) return 1;

    // Crash cases: through the replacement, in a child. A child crash means the replacement failed.
    check(childSurvives(argv[0], 0), "16-bit RGBA, alpha 0x00ff, tiled: replacement prevents the crash");
    check(childSurvives(argv[0], 1), "8-bit grey+alpha, alpha 0, tiled: replacement prevents the crash");

    // Correctness: the replacement's draw of a poisoned image equals 10.9's draw of the zeroed image.
    {
        CGImageRef poison = make16RGBA(0x8000, 0x8000, 0x8000, 0x00ff);
        CGImageRef zeroed = make16RGBA(0, 0, 0, 0x00ff);
        unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gAdobe, poison);
        unsigned char *viaZeroed = tileToSurface(gSystemTiled, gAdobe, zeroed);
        check(!memcmp(viaArchive, viaZeroed, kSide * kSide * 4), "16-bit RGBA alpha 0x00ff: archive draw equals 10.9's draw of the zeroed image");
        free(viaArchive); free(viaZeroed); CGImageRelease(poison); CGImageRelease(zeroed);
    }

    // A colour above its (nonzero) alpha never crashes and must be left untouched: a40 c=C0.
    {
        CGImageRef image = make8RGBA(0xC0, 0xC0, 0xC0, 0x40);
        unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gSRGB, image);
        unsigned char *viaSystem = tileToSurface(gSystemTiled, gSRGB, image);
        check(!memcmp(viaArchive, viaSystem, kSide * kSide * 4), "alpha 0x40 colour 0xC0 tiled into an sRGB IOSurface: byte-identical to 10.9");
        free(viaArchive); free(viaSystem); CGImageRelease(image);
    }
    // The same as a pattern into an sRGB BITMAP context (no colour match at all).
    {
        CGImageRef image = make8RGBA(0xC0, 0xC0, 0xC0, 0x40);
        unsigned char *out[2];
        for (int k = 0; k < 2; k++) {
            CGContextRef c = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGPatternRef pat = k ? gSystemPattern(image, CGAffineTransformIdentity, kCGPatternTilingConstantSpacing)
                                 : CGPatternCreateWithImage2(image, CGAffineTransformIdentity, kCGPatternTilingConstantSpacing);
            CGColorSpaceRef ps = CGColorSpaceCreatePattern(NULL); CGContextSetFillColorSpace(c, ps); CGColorSpaceRelease(ps);
            CGFloat a = 1; CGContextSetFillPattern(c, pat, &a); CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
            out[k] = malloc(kSide * kSide * 4); memcpy(out[k], CGBitmapContextGetData(c), kSide * kSide * 4);
            CGPatternRelease(pat); CGContextRelease(c);
        }
        check(!memcmp(out[0], out[1], kSide * kSide * 4), "alpha 0x40 colour 0xC0 pattern into an sRGB bitmap context: byte-identical to 10.9");
        free(out[0]); free(out[1]); CGImageRelease(image);
    }

    // 16-bit alpha 0x1000 (samples to 0x10, not 0) with colour 0x8000: invalid but no crash, untouched.
    {
        CGImageRef image = make16RGBA(0x8000, 0x8000, 0x8000, 0x1000);
        unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gAdobe, image);
        unsigned char *viaSystem = tileToSurface(gSystemTiled, gAdobe, image);
        check(!memcmp(viaArchive, viaSystem, kSide * kSide * 4), "16-bit colour 0x8000 over alpha 0x1000: byte-identical to 10.9");
        free(viaArchive); free(viaSystem); CGImageRelease(image);
    }
    // 16-bit alpha 0x00ff colour 0x1000: no crash on stock, and equals the zeroed draw.
    {
        CGImageRef poison = make16RGBA(0x1000, 0x1000, 0x1000, 0x00ff);
        CGImageRef zeroed = make16RGBA(0, 0, 0, 0x00ff);
        unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gAdobe, poison);
        unsigned char *viaZeroed = tileToSurface(gSystemTiled, gAdobe, zeroed);
        check(!memcmp(viaArchive, viaZeroed, kSide * kSide * 4), "16-bit alpha 0x00ff colour 0x1000: archive draw equals 10.9's zeroed draw");
        free(viaArchive); free(viaZeroed); CGImageRelease(poison); CGImageRelease(zeroed);
    }

    // A decode array remaps samples, so the stored bytes are not what the cube indexes: the archive must
    // leave such an image alone. An opaque image with a non-identity decode does not crash, so its
    // passthrough can be compared byte-for-byte with 10.9's draw.
    {
        unsigned char *p = malloc(kSide * kSide * 4);
        for (size_t i = 0; i < (size_t)kSide * kSide; i++) { p[i*4]=0x20; p[i*4+1]=0x40; p[i*4+2]=0x60; p[i*4+3]=0xFF; }
        CGDataProviderRef d = CGDataProviderCreateWithData(NULL, p, kSide*kSide*4, NULL);
        CGFloat decode[8] = { 1, 0, 1, 0, 1, 0, 0, 1 };   // inverts the three colour channels
        CGImageRef image = CGImageCreate(kSide, kSide, 8, 32, kSide*4, gSRGB, kRGBA8, d, decode, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(d);
        if (image) {
            unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gAdobe, image);
            unsigned char *viaSystem = tileToSurface(gSystemTiled, gAdobe, image);
            check(!memcmp(viaArchive, viaSystem, kSide * kSide * 4), "decode-array image: byte-identical to 10.9 (passed through)");
            free(viaArchive); free(viaSystem); CGImageRelease(image);
        } else check(0, "decode-array image could be created");
    }

    // A CGImageCreateWithImageInRect subimage of a valid image, tiled.
    {
        CGImageRef full = make8RGBA(0x80, 0x40, 0x20, 0xFF);
        CGImageRef sub = CGImageCreateWithImageInRect(full, CGRectMake(0, 0, kSide / 2, kSide / 2));
        if (sub) {
            unsigned char *viaArchive = tileToSurface(CGContextDrawTiledImage, gAdobe, sub);
            unsigned char *viaSystem = tileToSurface(gSystemTiled, gAdobe, sub);
            check(!memcmp(viaArchive, viaSystem, kSide * kSide * 4), "subimage (CGImageCreateWithImageInRect) tiled: byte-identical to 10.9");
            free(viaArchive); free(viaSystem); CGImageRelease(sub);
        } else check(0, "subimage could be created");
        CGImageRelease(full);
    }

    return failures ? 1 : 0;
}
