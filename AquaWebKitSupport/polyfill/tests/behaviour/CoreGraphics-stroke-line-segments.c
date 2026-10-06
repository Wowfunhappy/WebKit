// The CGContextStrokeLineSegments replacement (polyfills/c/CoreGraphics.c), measured against 10.9's own
// definition: in a bitmap context the two cover the same pixels under every CTM; in an IOSurface-backed
// context they agree unrotated, and under a rotated CTM 10.9's covers a different set (nothing, or a
// displaced fragment) while the archive's still covers the same pixels as the move-to/line-to/stroke
// route. The archive's definition is the one this program's link-time reference binds.
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);

typedef void (*StrokeLineSegmentsFn)(CGContextRef, const CGPoint *, size_t);

enum { kSide = 64 };

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// 10.9's definition, reached through dyld's image lookup: dlsym on this binary answers registered
// names with the archive's own definition.
static StrokeLineSegmentsFn systemStrokeLineSegments(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextStrokeLineSegments", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (StrokeLineSegmentsFn)NSAddressOfSymbol(found) : 0;
}

typedef struct { int count, minX, maxX, minY, maxY; } Coverage;

static Coverage coverage(const unsigned char *pixels, size_t bytesPerRow)
{
    Coverage c = { 0, kSide, -1, kSide, -1 };
    for (int y = 0; y < kSide; y++) {
        for (int x = 0; x < kSide; x++) {
            if (!pixels[y * bytesPerRow + x * 4 + 3])
                continue;
            c.count++;
            if (x < c.minX) c.minX = x;
            if (x > c.maxX) c.maxX = x;
            if (y < c.minY) c.minY = y;
            if (y > c.maxY) c.maxY = y;
        }
    }
    return c;
}

static int sameCoverage(Coverage a, Coverage b)
{
    return a.count == b.count && a.minX == b.minX && a.maxX == b.maxX && a.minY == b.minY && a.maxY == b.maxY;
}

static IOSurfaceRef createSurface(void)
{
    int side = kSide, bytesPerRow = kSide * 4, bytesPerElement = 4;
    unsigned format = 'BGRA';
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef numbers[] = {
        CFNumberCreate(NULL, kCFNumberIntType, &side), CFNumberCreate(NULL, kCFNumberIntType, &side),
        CFNumberCreate(NULL, kCFNumberIntType, &bytesPerRow), CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement),
        CFNumberCreate(NULL, kCFNumberIntType, &format),
    };
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerRow, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        CFDictionarySetValue(properties, keys[i], numbers[i]);
        CFRelease(numbers[i]);
    }
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}

// Segment pairs in a 16-unit space; the CTM below scales by 4 and rotates about the centre.
static const CGPoint kOneSegment[2] = { { 3, 8 }, { 12, 8 } };
static const CGPoint kTwoSegments[4] = { { 3, 8 }, { 12, 8 }, { 3, 4 }, { 12, 4 } };

static void prepare(CGContextRef context, double degrees)
{
    CGContextSetRGBStrokeColor(context, 0, 0, 0, 1);
    CGContextSetLineWidth(context, 2);
    CGContextScaleCTM(context, 4, 4);
    CGContextTranslateCTM(context, 8, 8);
    CGContextRotateCTM(context, degrees * M_PI / 180);
    CGContextTranslateCTM(context, -8, -8);
}

static void strokeViaPath(CGContextRef context, const CGPoint *points, size_t count)
{
    CGContextBeginPath(context);
    for (size_t i = 0; i + 1 < count; i += 2) {
        CGContextMoveToPoint(context, points[i].x, points[i].y);
        CGContextAddLineToPoint(context, points[i + 1].x, points[i + 1].y);
    }
    CGContextStrokePath(context);
}

typedef struct { const char *name; double degrees; const CGPoint *points; size_t count; } Geometry;

// Coverage of one geometry drawn by `stroke` (or, with a null `stroke`, by the path route).
static Coverage drawOnSurface(IOSurfaceRef surface, CGColorSpaceRef colorSpace, const Geometry *g, StrokeLineSegmentsFn stroke)
{
    IOSurfaceLock(surface, 0, NULL);
    memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetBytesPerRow(surface) * kSide);
    IOSurfaceUnlock(surface, 0, NULL);
    CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    prepare(context, g->degrees);
    if (stroke)
        stroke(context, g->points, g->count);
    else
        strokeViaPath(context, g->points, g->count);
    CGContextRelease(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    Coverage c = coverage(IOSurfaceGetBaseAddress(surface), IOSurfaceGetBytesPerRow(surface));
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return c;
}

static Coverage drawOnBitmap(CGColorSpaceRef colorSpace, const Geometry *g, StrokeLineSegmentsFn stroke)
{
    static unsigned char pixels[kSide * kSide * 4];
    memset(pixels, 0, sizeof pixels);
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    prepare(context, g->degrees);
    if (stroke)
        stroke(context, g->points, g->count);
    else
        strokeViaPath(context, g->points, g->count);
    CGContextRelease(context);
    return coverage(pixels, kSide * 4);
}

int main(void)
{
    // dladdr names the image holding the linked definition; the archive's is in this executable.
    Dl_info linked = { 0 };
    check(dladdr((void *)CGContextStrokeLineSegments, &linked) && linked.dli_fname && !strstr(linked.dli_fname, "CoreGraphics"),
        "the linked CGContextStrokeLineSegments is the archive's, not 10.9's");
    StrokeLineSegmentsFn system = systemStrokeLineSegments();
    check(system != NULL, "10.9's CGContextStrokeLineSegments is reachable for comparison");
    check(system != CGContextStrokeLineSegments, "10.9's definition is a different function from the archive's");

    IOSurfaceRef surface = createSurface();
    check(surface != NULL, "an IOSurface allocates");
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    const Geometry geometries[] = {
        { "one segment, rotated 90", 90, kOneSegment, 2 },
        { "one segment, rotated 45", 45, kOneSegment, 2 },
        { "two segments, rotated 90", 90, kTwoSegments, 4 },
        { "one segment, unrotated", 0, kOneSegment, 2 },
    };
    for (size_t i = 0; i < sizeof geometries / sizeof *geometries; i++) {
        const Geometry *g = &geometries[i];
        char what[112];

        Coverage path = drawOnBitmap(colorSpace, g, NULL);
        Coverage ours = drawOnBitmap(colorSpace, g, CGContextStrokeLineSegments);
        snprintf(what, sizeof what, "bitmap: %s, archive's covers the path route's pixels", g->name);
        check(path.count > 0 && sameCoverage(ours, path), what);
        if (system) {
            snprintf(what, sizeof what, "bitmap: %s, 10.9's covers the same pixels", g->name);
            check(sameCoverage(drawOnBitmap(colorSpace, g, system), path), what);
        }

        if (!surface)
            continue;
        path = drawOnSurface(surface, colorSpace, g, NULL);
        ours = drawOnSurface(surface, colorSpace, g, CGContextStrokeLineSegments);
        snprintf(what, sizeof what, "IOSurface: %s, archive's covers the path route's pixels", g->name);
        check(path.count > 0 && sameCoverage(ours, path), what);
        if (system) {
            Coverage theirs = drawOnSurface(surface, colorSpace, g, system);
            if (g->degrees == 0) {
                snprintf(what, sizeof what, "IOSurface: %s, 10.9's covers the same pixels", g->name);
                check(sameCoverage(theirs, path), what);
            } else {
                snprintf(what, sizeof what, "IOSurface: %s, 10.9's covers a different set", g->name);
                check(!sameCoverage(theirs, path), what);
            }
        }
    }

    if (failures)
        printf("CGContextStrokeLineSegments probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
