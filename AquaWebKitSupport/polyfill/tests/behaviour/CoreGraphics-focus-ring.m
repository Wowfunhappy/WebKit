// A focus ring in Core Animation's IOSurface contexts (polyfills/c/CoreGraphics.c), against a CG bitmap's: a path ring, a
// ring from a transparency layer, a cell's, in a direct surface and an asynchronously drawing layer at scales 1 and 2,
// inside an offscreen layer, and from a shape just past the surface, whose ring reaches into it. The draw leaves the
// context's state as a bitmap's does. A ring from a transparency layer past the surface or in an offscreen is reported.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>

typedef const struct CGStyle *CGStyleRef;
typedef struct { unsigned version; int tint; int ordering; CGFloat alpha, radius, threshold; CGRect bounds; int accumulate; } RingStyle;
extern BOOL NSInitializeCGFocusRingStyleForTime(NSFocusRingPlacement, RingStyle *, NSTimeInterval);
extern CGStyleRef CGStyleCreateFocusRingWithColor(const RingStyle *, CGColorRef);
extern void CGContextSetStyle(CGContextRef, CGStyleRef);
extern CGStyleRef CGContextGetStyle(CGContextRef);
extern void CGContextSetBaseCTM(CGContextRef, CGAffineTransform);
extern void CGContextBeginTransparencyLayerWithRect(CGContextRef, CGRect, CFDictionaryRef);
extern CGBlendMode CGContextGetBlendMode(CGContextRef);
extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern size_t wk_coreAnimationTextureLimit(void);

enum { kSide = 200 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static CGColorSpaceRef gSRGB;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-90s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static CGFloat gRingStyleAlpha = 1;

static void setRing(CGContextRef c)
{
    RingStyle style;
    NSInitializeCGFocusRingStyleForTime(NSFocusRingOnly, &style, DBL_MAX);
    style.accumulate = -1;
    style.alpha *= gRingStyleAlpha;
    CGColorRef color = CGColorCreateGenericRGB(0.2, 0.4, 0.9, 1);
    CGStyleRef ring = CGStyleCreateFocusRingWithColor(&style, color);
    CGContextSetStyle(c, ring);
    CFRelease(ring);
    CGColorRelease(color);
}

typedef void (^Draw)(CGContextRef);

static void pathRing(CGContextRef c, CGRect rect)
{
    CGContextSaveGState(c);
    setRing(c);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, 8, 8, NULL);
    CGContextBeginPath(c);
    CGContextAddPath(c, path);
    CGContextFillPath(c);
    CGPathRelease(path);
    CGContextRestoreGState(c);
}

static void layerRing(CGContextRef c, CGRect rect)
{
    CGContextSaveGState(c);
    setRing(c);
    CGContextBeginTransparencyLayerWithRect(c, rect, NULL);
    CGContextFillRect(c, rect);
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
}

static void cellRing(CGContextRef c, CGRect rect)
{
    CGContextSaveGState(c);
    setRing(c);
    CGContextBeginTransparencyLayerWithRect(c, rect, NULL);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:c flipped:NO]];
    NSButtonCell *cell = [[NSButtonCell alloc] initTextCell:@"Button"];
    [cell setButtonType:NSMomentaryPushInButton];
    [cell setBezelStyle:NSRoundedBezelStyle];
    [cell drawFocusRingMaskWithFrame:rect inView:nil];
    [NSGraphicsContext restoreGraphicsState];
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
}

static void page(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.93, 0.95, 0.9, 1);
    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
}

static bool gDrawingBitmap;

static int largestDirect(Draw draw, int *changed)
{
    NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(kSide), (id)kIOSurfaceHeight: @(kSide), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((int)'BGRA') };
    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
    CGContextRef s = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, gSRGB, kBGRA);
    CGContextRef b = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    page(s);
    page(b);
    gDrawingBitmap = false;
    draw(s);
    gDrawingBitmap = true;
    draw(b);
    CGContextFlush(s);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *a = IOSurfaceGetBaseAddress(surface), *p = CGBitmapContextGetData(b);
    size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
    int largest = 0, count = 0;
    for (size_t y = 0; y < kSide; y++) {
        for (size_t x = 0; x < kSide; x++) {
            for (int k = 0; k < 4; k++)
                largest = MAX(largest, abs(a[y * rowBytes + x * 4 + k] - p[(y * kSide + x) * 4 + k]));
            count += p[(y * kSide + x) * 4] != 230 || p[(y * kSide + x) * 4 + 1] != 242;
        }
    }
    *changed = count;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CGContextRelease(s);
    CGContextRelease(b);
    CFRelease(surface);
    return largest;
}

@interface BlockDelegate : NSObject <CALayerDelegate> {
@public
    Draw draw;
}
@end
@implementation BlockDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    draw(context);
}
@end

static CGContextRef shownPixels(NSWindow *window)
{
    CGImageRef shot = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber], kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    CGContextRef shown = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGContextDrawImage(shown, CGRectMake(0, 0, kSide, kSide), shot);
    CGImageRelease(shot);
    return shown;
}

static int largestThroughLayer(int scale, Draw draw)
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kSide, kSide) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setColorSpace:[NSColorSpace sRGBColorSpace]];
    NSView *view = [window contentView];
    [view setWantsLayer:YES];
    BlockDelegate *delegate = [[BlockDelegate alloc] init];
    delegate->draw = draw;
    CALayer *layer = [CALayer layer];
    layer.drawsAsynchronously = YES;
    layer.contentsScale = scale;
    layer.frame = CGRectMake(0, 0, kSide, kSide);
    layer.delegate = delegate;
    [view.layer addSublayer:layer];
    [layer setNeedsDisplay];
    [window orderFront:nil];
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    CGContextRef shown = shownPixels(window);
    size_t side = kSide * scale;
    CGContextRef bitmap = CGBitmapContextCreate(NULL, side, side, 8, side * 4, gSRGB, kBGRA);
    CGContextScaleCTM(bitmap, scale, scale);
    CGContextSetBaseCTM(bitmap, CGAffineTransformMakeScale(scale, scale));
    draw(bitmap);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.delegate = nil;
    layer.drawsAsynchronously = NO;
    layer.contents = (__bridge id)image;
    [CATransaction commit];
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    CGContextRef reference = shownPixels(window);
    const unsigned char *a = CGBitmapContextGetData(shown), *b = CGBitmapContextGetData(reference);
    int largest = 0;
    for (size_t i = 0; i < kSide * kSide * 4; i++)
        largest = MAX(largest, abs(a[i] - b[i]));
    [window orderOut:nil];
    CGImageRelease(image);
    CGContextRelease(bitmap);
    CGContextRelease(shown);
    CGContextRelease(reference);
    return largest;
}

int main(void)
{
    @autoreleasepool {
        gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        [NSApplication sharedApplication];
        // A software renderer's ring is the bitmap's, composited; a GPU's own is up to three levels from the bitmap's.
        int tolerance = wk_coreAnimationTextureLimit() ? 1 : 3;
        const CGRect box = CGRectMake(50, 60, 100, 60);
        static const struct { const char *name; void (*ring)(CGContextRef, CGRect); } kRings[] = { { "path", pathRing }, { "layer", layerRing }, { "cell", cellRing } };
        char what[160];
        for (int r = 0; r < 3; r++) {
            void (*ring)(CGContextRef, CGRect) = kRings[r].ring;
            int changed;
            int largest = largestDirect(^(CGContextRef c) { ring(c, box); }, &changed);
            snprintf(what, sizeof(what), "%s ring, direct surface: within %d of the bitmap (largest %d, %d pixels ringed)", kRings[r].name, tolerance, largest, changed);
            check(largest <= tolerance && changed > 100, what);
            for (int scale = 1; scale <= 2; scale++) {
                largest = largestThroughLayer(scale, ^(CGContextRef c) { page(c); ring(c, box); });
                // A GPU's own ring at scale 2 is up to five levels from the bitmap's once the window shows it at scale 1.
                int allowed = scale == 2 && !wk_coreAnimationTextureLimit() ? 5 : tolerance;
                snprintf(what, sizeof(what), "%s ring, async layer at scale %d: within %d of the bitmap (largest %d)", kRings[r].name, scale, allowed, largest);
                check(largest <= allowed, what);
            }
        }

        // A shape ending one pixel off the surface still rings into it.
        {
            int changed;
            CGRect past = CGRectMake(-80, 60, 79, 60);
            int largest = largestDirect(^(CGContextRef c) { pathRing(c, past); }, &changed);
            snprintf(what, sizeof(what), "path ring from one pixel past the surface: within %d of the bitmap (largest %d, %d pixels ringed)", tolerance, largest, changed);
            check(largest <= tolerance && changed > 10, what);
            largest = largestDirect(^(CGContextRef c) { layerRing(c, past); }, &changed);
            printf("    layer ring from one pixel past the surface: largest %d from the bitmap, %d pixels ringed in the bitmap\n", largest, changed);
            largest = largestDirect(^(CGContextRef c) { cellRing(c, past); }, &changed);
            printf("    cell ring from one pixel past the surface: largest %d from the bitmap, %d pixels ringed in the bitmap\n", largest, changed);
        }

        // Inside an offscreen layer, nothing of the surface can be read.
        {
            int changed;
            int largest = largestDirect(^(CGContextRef c) {
                CGContextBeginTransparencyLayer(c, NULL);
                pathRing(c, box);
                CGContextEndTransparencyLayer(c);
            }, &changed);
            snprintf(what, sizeof(what), "path ring inside an offscreen layer: within %d of the bitmap (largest %d)", tolerance, largest);
            check(largest <= tolerance, what);
            largest = largestDirect(^(CGContextRef c) {
                CGContextBeginTransparencyLayer(c, NULL);
                layerRing(c, box);
                CGContextEndTransparencyLayer(c);
            }, &changed);
            printf("    layer ring inside an offscreen layer: largest %d from the bitmap\n", largest);
            largest = largestDirect(^(CGContextRef c) {
                CGContextBeginTransparencyLayer(c, NULL);
                cellRing(c, box);
                CGContextEndTransparencyLayer(c);
            }, &changed);
            printf("    cell ring inside an offscreen layer: largest %d from the bitmap\n", largest);
        }

        // A surface multiplies a ring's own alpha by global alpha under every blend mode; CG's bitmap ignores global alpha
        // on a ring, so the reference scales the style's alpha.
        {
            static const struct { CGBlendMode mode; const char *name; } kAlphaModes[] = {
                { kCGBlendModeNormal, "normal" }, { kCGBlendModeMultiply, "multiply" }, { kCGBlendModePlusDarker, "plus-darker" },
                { kCGBlendModeDestinationOut, "destination-out" }, { kCGBlendModeHue, "hue" }, { kCGBlendModeCopy, "copy" },
            };
            int alphaTolerance = MAX(tolerance, 2);
            for (int r = 0; r < 2; r++) {
                void (*ring)(CGContextRef, CGRect) = kRings[r].ring;
                for (size_t m = 0; m < sizeof(kAlphaModes) / sizeof(kAlphaModes[0]); m++) {
                    for (int clipped = 0; clipped < 2; clipped++) {
                        int changed;
                        CGBlendMode mode = kAlphaModes[m].mode;
                        int largest = largestDirect(^(CGContextRef c) {
                            if (clipped)
                                CGContextClipToRect(c, CGRectMake(40, 40, 70, 120));
                            CGContextSetBlendMode(c, mode);
                            CGContextSetAlpha(c, 0.5);
                            gRingStyleAlpha = gDrawingBitmap ? 0.5 : 1;
                            ring(c, box);
                            gRingStyleAlpha = 1;
                        }, &changed);
                        snprintf(what, sizeof(what), "%s ring under %s, global alpha 0.5%s: within %d of a bitmap's ring at that style alpha (largest %d)", kRings[r].name, kAlphaModes[m].name, clipped ? ", clipped" : "", alphaTolerance, largest);
                        check(largest <= alphaTolerance, what);
                    }
                }
            }
        }

        // A blend mode composites the ring over the destination.
        {
            static const struct { CGBlendMode mode; const char *name; } kModes[] = {
                { kCGBlendModeMultiply, "multiply" }, { kCGBlendModeDestinationOut, "destination-out" }, { kCGBlendModeCopy, "copy" },
                { kCGBlendModeSourceIn, "source-in" }, { kCGBlendModeClear, "clear" }, { kCGBlendModeHue, "hue" }, { kCGBlendModePlusDarker, "plus-darker" },
            };
            for (size_t m = 0; m < sizeof(kModes) / sizeof(kModes[0]); m++) {
                int changed;
                CGBlendMode mode = kModes[m].mode;
                int largest = largestDirect(^(CGContextRef c) {
                    CGContextSetBlendMode(c, mode);
                    pathRing(c, box);
                }, &changed);
                snprintf(what, sizeof(what), "path ring under %s: within %d of the bitmap (largest %d)", kModes[m].name, tolerance, largest);
                check(largest <= tolerance, what);
            }
        }

        // The draw leaves the context's state.
        {
            NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(kSide), (id)kIOSurfaceHeight: @(kSide), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((int)'BGRA') };
            IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
            CGContextRef c = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, gSRGB, kBGRA);
            CGContextRef b = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
            bool same = true;
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef t = pass ? b : c;
                setRing(t);
                CGContextSetBlendMode(t, kCGBlendModeMultiply);
            }
            CGStyleRef before = CGContextGetStyle(c);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef t = pass ? b : c;
                CGContextAddRect(t, box);
                CGContextFillRect(t, CGRectMake(10, 10, 20, 20));
            }
            same &= CGContextIsPathEmpty(c) == CGContextIsPathEmpty(b);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef t = pass ? b : c;
                CGContextBeginPath(t);
                CGContextAddRect(t, box);
                CGContextFillPath(t);
            }
            same &= CGContextIsPathEmpty(c) == CGContextIsPathEmpty(b);
            check(same, "a rect fill and a path fill under a ring leave the current path as a bitmap's do");
            check(CGContextGetStyle(c) == before && CGContextGetBlendMode(c) == kCGBlendModeMultiply, "the style and blend mode are the draw's own afterward");
            CGContextRelease(c);
            CGContextRelease(b);
            CFRelease(surface);
        }
    }
    return failures ? 1 : 0;
}
