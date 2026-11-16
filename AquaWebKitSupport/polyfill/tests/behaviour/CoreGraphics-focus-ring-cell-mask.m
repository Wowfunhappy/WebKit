// A cell's focus ring mask, drawn through -[NSCell drawFocusRingMaskWithFrame:inView:] (polyfills/methods/AppKit.m)
// inside a transparency layer under a focus ring style, in Core Animation's IOSurface contexts, against a CG bitmap's.
// Under QuartzCore's software renderer, which drops the ring, the masks draw into the layer read-back's own bitmap
// (polyfills/c/CoreGraphics.c), which rings them with everything else the layer drew.
//
// Gate K1: a button cell's mask straddling the edge between two adjacent surfaces drawn as tiles matches the bitmap
// on both sides, rings both, and draws no ring along the edge.
// Gate K2: a fill and a cell's mask in one layer match the bitmap: the fill is ringed and no mask shows.
// Gate K3: two cells' masks in one layer match the bitmap.
// Gate K4: under a ring drawn below its content, a straddling cell's mask with a fill drawn over it, inside the mask, in
// the same layer matches the bitmap, which keeps the order they were drawn in.
// Gate K5: a straddling cell's mask under a clip set inside the layer that cuts it matches the bitmap.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>

typedef const struct CGStyle *CGStyleRef;
typedef struct { unsigned version; int tint; int ordering; CGFloat alpha, radius, threshold; CGRect bounds; int accumulate; } RingStyle;
extern BOOL NSInitializeCGFocusRingStyleForTime(NSFocusRingPlacement, RingStyle *, NSTimeInterval);
extern CGStyleRef CGStyleCreateFocusRingWithColor(const RingStyle *, CGColorRef);
extern void CGContextSetStyle(CGContextRef, CGStyleRef);
extern void CGContextBeginTransparencyLayerWithRect(CGContextRef, CGRect, CFDictionaryRef);
extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern size_t wk_coreAnimationTextureLimit(void);

enum { kTile = 200 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static CGColorSpaceRef gSRGB;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-96s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static NSFocusRingPlacement gPlacement = NSFocusRingOnly;

static void setRing(CGContextRef c)
{
    RingStyle style;
    NSInitializeCGFocusRingStyleForTime(gPlacement, &style, DBL_MAX);
    style.accumulate = -1;
    CGColorRef color = CGColorCreateGenericRGB(0.2, 0.4, 0.9, 1);
    CGStyleRef ring = CGStyleCreateFocusRingWithColor(&style, color);
    CGContextSetStyle(c, ring);
    CFRelease(ring);
    CGColorRelease(color);
}

static void cellMask(CGContextRef c, CGRect rect)
{
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:c flipped:NO]];
    NSButtonCell *cell = [[NSButtonCell alloc] initTextCell:@"Button"];
    [cell setButtonType:NSMomentaryPushInButton];
    [cell setBezelStyle:NSRoundedBezelStyle];
    [cell drawFocusRingMaskWithFrame:rect inView:nil];
    [cell release];
    [NSGraphicsContext restoreGraphicsState];
}

typedef void (^Draw)(CGContextRef);

// The page, then `draw` inside a transparency layer over `layerRect` under the ring style, as WebKit draws a cell's ring.
static void ringed(CGContextRef c, CGRect layerRect, Draw draw)
{
    CGContextSetRGBFillColor(c, 0.93, 0.95, 0.9, 1);
    CGContextFillRect(c, CGRectMake(-1000, -1000, 3000, 3000));
    CGContextSaveGState(c);
    setRing(c);
    CGContextBeginTransparencyLayerWithRect(c, layerRect, NULL);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    draw(c);
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
}

static IOSurfaceRef createSurface(void)
{
    NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(kTile), (id)kIOSurfaceHeight: @(kTile), (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @((int)'BGRA') };
    return IOSurfaceCreate((CFDictionaryRef)properties);
}

// The largest difference between the surface and columns [x0, x0 + kTile) of the bitmap, and how many of those bitmap
// pixels the ring changed from the page.
static int compare(IOSurfaceRef surface, CGContextRef bitmap, size_t x0, int *ringedPixels)
{
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *a = IOSurfaceGetBaseAddress(surface), *p = CGBitmapContextGetData(bitmap);
    size_t rowBytes = IOSurfaceGetBytesPerRow(surface), bitmapRowBytes = CGBitmapContextGetBytesPerRow(bitmap);
    int largest = 0, count = 0;
    for (size_t y = 0; y < kTile; y++) {
        for (size_t x = 0; x < kTile; x++) {
            const unsigned char *s = a + y * rowBytes + x * 4, *b = p + y * bitmapRowBytes + (x0 + x) * 4;
            for (int k = 0; k < 4; k++)
                largest = MAX(largest, abs(s[k] - b[k]));
            count += b[0] != 230 || b[1] != 242;
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    *ringedPixels = count;
    return largest;
}

// Draws into two adjacent surfaces, the second showing columns [kTile, 2 * kTile), and into one bitmap holding both.
static void tiles(CGRect layerRect, Draw draw, int *largest, int ringed_[2])
{
    CGContextRef bitmap = CGBitmapContextCreate(NULL, 2 * kTile, kTile, 8, 2 * kTile * 4, gSRGB, kBGRA);
    ringed(bitmap, layerRect, draw);
    *largest = 0;
    for (int tile = 0; tile < 2; tile++) {
        IOSurfaceRef surface = createSurface();
        CGContextRef s = CGIOSurfaceContextCreate(surface, kTile, kTile, 8, 32, gSRGB, kBGRA);
        CGContextTranslateCTM(s, -tile * kTile, 0);
        ringed(s, layerRect, draw);
        CGContextFlush(s);
        *largest = MAX(*largest, compare(surface, bitmap, tile * kTile, &ringed_[tile]));
        CGContextRelease(s);
        CFRelease(surface);
    }
    CGContextRelease(bitmap);
}

int main(void)
{
    @autoreleasepool {
        gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        [NSApplication sharedApplication];
        // A software renderer's ring is the bitmap's, composited; a GPU's own is up to three levels from the bitmap's.
        int tolerance = wk_coreAnimationTextureLimit() ? 1 : 3;
        char what[200];
        int largest, ringedPixels[2];

        const CGRect straddling = CGRectMake(150, 70, 100, 40);
        tiles(straddling, ^(CGContextRef c) { cellMask(c, straddling); }, &largest, ringedPixels);
        snprintf(what, sizeof(what), "K1: a cell straddling two surfaces: within %d of the bitmap (largest %d; ringed %d | %d)",
            tolerance, largest, ringedPixels[0], ringedPixels[1]);
        check(largest <= tolerance && ringedPixels[0] > 50 && ringedPixels[1] > 50, what);

        const CGRect both = CGRectMake(20, 40, 160, 120);
        tiles(both, ^(CGContextRef c) {
            CGContextFillRect(c, CGRectMake(30, 50, 40, 30));
            cellMask(c, CGRectMake(90, 110, 80, 30));
        }, &largest, ringedPixels);
        snprintf(what, sizeof(what), "K2: a fill and a cell in one layer: within %d of the bitmap (largest %d, %d pixels ringed)",
            tolerance, largest, ringedPixels[0]);
        check(largest <= tolerance && ringedPixels[0] > 100, what);

        tiles(both, ^(CGContextRef c) {
            cellMask(c, CGRectMake(30, 50, 80, 30));
            cellMask(c, CGRectMake(90, 110, 80, 30));
        }, &largest, ringedPixels);
        snprintf(what, sizeof(what), "K3: two cells in one layer: within %d of the bitmap (largest %d, %d pixels ringed)",
            tolerance, largest, ringedPixels[0]);
        check(largest <= tolerance && ringedPixels[0] > 100, what);

        gPlacement = NSFocusRingBelow;
        tiles(straddling, ^(CGContextRef c) {
            cellMask(c, straddling);
            CGContextSetRGBFillColor(c, 0.8, 0.1, 0.1, 1);
            CGContextFillRect(c, CGRectMake(185, 82, 30, 16));
        }, &largest, ringedPixels);
        gPlacement = NSFocusRingOnly;
        snprintf(what, sizeof(what), "K4: a ring below its content, a fill over a straddling cell: within %d of the bitmap (largest %d)",
            tolerance, largest);
        check(largest <= tolerance && ringedPixels[0] > 50 && ringedPixels[1] > 50, what);

        tiles(straddling, ^(CGContextRef c) {
            CGContextClipToRect(c, CGRectMake(0, 0, 215, kTile));
            cellMask(c, straddling);
        }, &largest, ringedPixels);
        snprintf(what, sizeof(what), "K5: a clip inside the layer cutting a straddling cell: within %d of the bitmap (largest %d; ringed %d | %d)",
            tolerance, largest, ringedPixels[0], ringedPixels[1]);
        check(largest <= tolerance && ringedPixels[0] > 50 && ringedPixels[1] > 10, what);
    }
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
