// A half-plane clip through the CGContextClipToRect replacement (polyfills/c/CoreGraphics.c) in an IOSurface context,
// against a CG bitmap's, under transforms that scale one axis far more than the other or rotate it. The replacement
// bounds the rect to a reach past the clip that QuartzCore still rasterizes; the clip must stay where it is.
//
// Gate L1: under scale(1, 0.01) the half-plane clips exactly as the bitmap's.
// Gate L2: under scale(0.01, 1) the same.
// Gate L3: under a 45-degree rotation the same.
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);

enum { kSide = 128 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-92s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

// Clears the context, then fills a square 1e7 across under a clip to the half-plane x >= edge of the transformed user
// space, `extent` long in every other direction. QuartzCore's software renderer draws no FLT_MAX fill under these
// transforms on its own, so the fill stays finite and the clip alone decides what shows.
static void halfPlane(CGContextRef c, CGAffineTransform transform, CGFloat edge, CGFloat extent)
{
    CGContextClearRect(c, CGRectMake(0, 0, kSide, kSide));
    CGContextSaveGState(c);
    CGContextConcatCTM(c, transform);
    CGContextClipToRect(c, CGRectMake(edge, -extent / 2, extent, extent));
    CGContextSetRGBFillColor(c, 0.1, 0.5, 0.9, 1);
    CGContextFillRect(c, CGRectMake(-5e6, -5e6, 1e7, 1e7));
    CGContextRestoreGState(c);
}

static void compare(const char *what, CGAffineTransform transform, CGFloat edge, CGFloat extent)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    int side = kSide, bytesPerElement = 4;
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &side);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement };
    const void *values[] = { w, w, element };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(w);
    CFRelease(element);
    CGContextRef s = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, space, kBGRA);
    CGContextRef b = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, space, kBGRA);
    halfPlane(s, transform, edge, extent);
    halfPlane(b, transform, edge, extent);
    CGContextFlush(s);

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *a = IOSurfaceGetBaseAddress(surface), *p = CGBitmapContextGetData(b);
    size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
    int largest = 0, painted = 0, clear = 0;
    for (size_t y = 0; y < kSide; y++) {
        for (size_t x = 0; x < kSide; x++) {
            for (int k = 0; k < 4; k++) {
                int d = abs(a[y * rowBytes + x * 4 + k] - p[(y * kSide + x) * 4 + k]);
                if (d > largest)
                    largest = d;
            }
            unsigned char alpha = p[(y * kSide + x) * 4 + 3];
            painted += alpha == 255;
            clear += alpha == 0;
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    char line[200];
    snprintf(line, sizeof(line), "%s: within 1 of the bitmap (largest %d; bitmap %d painted, %d clear)", what, largest, painted, clear);
    check(largest <= 1 && painted > 1000 && clear > 1000, line);
    CGContextRelease(s);
    CGContextRelease(b);
    CFRelease(surface);
    CGColorSpaceRelease(space);
}

int main(void)
{
    printf("A half-plane clip in an IOSurface context against a bitmap's:\n");
    compare("L1: under scale(1, 0.01)", CGAffineTransformMakeScale(1, 0.01), 40, FLT_MAX);
    compare("L2: under scale(0.01, 1)", CGAffineTransformMakeScale(0.01, 1), 4000, FLT_MAX);
    CGAffineTransform rotated = CGAffineTransformRotate(CGAffineTransformMakeTranslation(kSide / 2, kSide / 2), M_PI / 4);
    // A CG bitmap rasterizes no rotated FLT_MAX rect, so the rotated half-plane is 1e7 long.
    compare("L3: under a 45-degree rotation", rotated, -10, 1e7);
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
