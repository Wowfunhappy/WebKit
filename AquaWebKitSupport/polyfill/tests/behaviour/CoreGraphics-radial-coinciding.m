// The CGContextDrawRadialGradient replacement (polyfills/c/CoreGraphics.c) for concentric start and end
// circles of equal radius, drawn red to blue over magenta, against modern CoreGraphics' rule: the end radius
// moves out by 1e-6 and the shading is evaluated exactly, so kCGGradientDrawsBeforeStartLocation paints the
// disc red and kCGGradientDrawsAfterEndLocation paints the plane outside it blue, at every radius. Where 10.9's
// float canonical radii stay distinct (r = 0.5, 1, 5, 16, 33), the result is byte-identical to 10.9's own
// shading of the moved radius, also under a global alpha with a half-transparent last stop and under a shadow
// with opaque stops; under a shadow a half-transparent last stop comes within two levels, as 10.9's own
// shading does of itself drawn in a transparency layer. The rule holds under the bounding-box CTM of an SVG radialGradient with
// r = fr = 100, in a linear-sRGB bitmap, an IOSurface, and the context Core Animation hands an asynchronously
// drawing layer's delegate. 10.9's own definition paints nothing for equal radii, which is the premise, and
// radii a thousandth apart draw as 10.9 draws them.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
typedef void (*DrawRadialFn)(CGContextRef, CGGradientRef, CGPoint, CGFloat, CGPoint, CGFloat, CGGradientDrawingOptions);

enum { kSide = 100 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static const CGGradientDrawingOptions kBoth = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;
static const CGPoint kCenter = { 50.5, 50.5 };

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-84s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static DrawRadialFn systemDrawRadial(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawRadialGradient", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawRadialFn)NSAddressOfSymbol(found) : 0;
}

static CGGradientRef gGradient;
static CGFloat gAsyncRadius;

// Pixels of a bitmap (BGRA rows of kSide, row 0 at the top) that break the rule for `options`, given the colours
// expected inside, outside and untouched. Pixels within half a pixel of the circle are not judged. A tolerance
// of `slack` per channel admits a renderer that rounds differently.
static int pixelsBreakingRule(const unsigned char *pixels, size_t rowBytes, bool flipped, CGFloat radius, bool paints,
    CGGradientDrawingOptions options, const unsigned char inside[4], const unsigned char outside[4], const unsigned char untouched[4], int slack)
{
    int broken = 0;
    for (size_t row = 0; row < kSide; row++) {
        for (size_t x = 0; x < kSide; x++) {
            CGFloat y = flipped ? row + 0.5 : kSide - row - 0.5;
            CGFloat d = hypot(x + 0.5 - kCenter.x, y - kCenter.y);
            const unsigned char *expected;
            if (d < radius - 0.5)
                expected = paints && (options & kCGGradientDrawsBeforeStartLocation) ? inside : untouched;
            else if (d > radius + 0.5)
                expected = paints && (options & kCGGradientDrawsAfterEndLocation) ? outside : untouched;
            else
                continue;
            const unsigned char *pixel = pixels + row * rowBytes + x * 4;
            for (int c = 0; c < 4; c++) {
                if (abs(pixel[c] - expected[c]) > slack) {
                    broken++;
                    break;
                }
            }
        }
    }
    return broken;
}

// A bitmap of `space` filled magenta, with the concentric gradient of equal radii drawn into it by `draw`.
static CGContextRef createDrawn(CGColorSpaceRef space, DrawRadialFn draw, CGGradientDrawingOptions options, CGFloat startRadius, CGFloat endRadius)
{
    CGContextRef context = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, space, kBGRA);
    CGContextSetRGBFillColor(context, 1, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
    draw(context, gGradient, kCenter, startRadius, kCenter, endRadius, options);
    return context;
}

// The BGRA pixel a flat fill of sRGB `rgb` leaves in a bitmap of `space`.
static void flatPixel(CGColorSpaceRef space, CGColorSpaceRef sRGB, CGFloat r, CGFloat g, CGFloat b, unsigned char out[4])
{
    CGContextRef flat = CGBitmapContextCreate(NULL, 1, 1, 8, 4, space, kBGRA);
    CGContextSetFillColorSpace(flat, sRGB);
    const CGFloat components[] = { r, g, b, 1 };
    CGContextSetFillColor(flat, components);
    CGContextFillRect(flat, CGRectMake(0, 0, 1, 1));
    memcpy(out, CGBitmapContextGetData(flat), 4);
    CGContextRelease(flat);
}

// 60x60, the clip 40x40 at (10, 10), red to blue at `lastAlpha`, under a shadow (`shadow`) or global alpha 0.6,
// with concentric circles at (30, 30) drawn by `draw` with radii `startRadius` and `endRadius`.
enum { kState = 60 };
static CGContextRef createStyled(CGColorSpaceRef space, DrawRadialFn draw, bool shadow, CGFloat lastAlpha, CGFloat startRadius, CGFloat endRadius)
{
    const CGFloat components[] = { 1, 0, 0, 1, 0, 0, 1, lastAlpha };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
    CGContextRef context = CGBitmapContextCreate(NULL, kState, kState, 8, kState * 4, space, kBGRA);
    CGContextSetRGBFillColor(context, 1, 1, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, kState, kState));
    CGContextClipToRect(context, CGRectMake(10, 10, 40, 40));
    const CGFloat black[] = { 0, 0, 0, 1 };
    CGColorRef shadowColor = CGColorCreate(space, black);
    if (shadow)
        CGContextSetShadowWithColor(context, CGSizeMake(6, -6), 3, shadowColor);
    else
        CGContextSetAlpha(context, 0.6);
    draw(context, gradient, CGPointMake(30, 30), startRadius, CGPointMake(30, 30), endRadius, kBoth);
    CGColorRelease(shadowColor);
    CGGradientRelease(gradient);
    return context;
}

// The largest difference between two kState bitmaps.
static int largestDifference(CGContextRef a, CGContextRef b)
{
    const unsigned char *p = CGBitmapContextGetData(a), *q = CGBitmapContextGetData(b);
    int largest = 0;
    for (size_t i = 0; i < kState * kState * 4; i++)
        largest = MAX(largest, abs(p[i] - q[i]));
    return largest;
}

static const char *optionsName(CGGradientDrawingOptions options)
{
    return options == kBoth ? "both extensions" : options == kCGGradientDrawsBeforeStartLocation ? "before start"
        : options == kCGGradientDrawsAfterEndLocation ? "after end" : "no extension";
}

static bool gAsyncDrawn;
@interface ProbeDelegate : NSObject <CALayerDelegate>
@end
@implementation ProbeDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    CGContextSetRGBFillColor(context, 1, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
    CGContextDrawRadialGradient(context, gGradient, kCenter, gAsyncRadius, kCenter, gAsyncRadius, kBoth);
    gAsyncDrawn = true;
}
@end

int main(void)
{
    @autoreleasepool {
        CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef linear = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceLinearSRGB"));
        const CGFloat components[] = { 1, 0, 0, 1, 0, 0, 1, 1 };
        gGradient = CGGradientCreateWithColorComponents(sRGB, components, NULL, 2);
        DrawRadialFn system = systemDrawRadial();
        const unsigned char red[4] = { 0, 0, 255, 255 }, blue[4] = { 255, 0, 0, 255 }, magenta[4] = { 255, 0, 255, 255 };

        static const CGGradientDrawingOptions optionSets[] = { kBoth, kCGGradientDrawsBeforeStartLocation, kCGGradientDrawsAfterEndLocation, 0 };
        static const struct { CGFloat radius; bool paints; } radii[] = {
            { 0.5, true }, { 1, true }, { 5, true }, { 16, true }, { 33, true }, { 17, true }, { 50, true }, { 100, true }, { 500, true },
        };
        for (size_t i = 0; i < sizeof(radii) / sizeof(radii[0]); i++) {
            for (size_t j = 0; j < sizeof(optionSets) / sizeof(optionSets[0]); j++) {
                CGContextRef context = createDrawn(sRGB, CGContextDrawRadialGradient, optionSets[j], radii[i].radius, radii[i].radius);
                int broken = pixelsBreakingRule(CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context), false,
                    radii[i].radius, radii[i].paints, optionSets[j], red, blue, magenta, 0);
                char what[160];
                snprintf(what, sizeof(what), "r = %g, %s: %s (%d pixels differ)", radii[i].radius, optionsName(optionSets[j]),
                    !radii[i].paints || !optionSets[j] ? "nothing drawn" : optionSets[j] == kBoth ? "red disc, blue beyond"
                        : optionSets[j] == kCGGradientDrawsBeforeStartLocation ? "red disc" : "blue beyond the disc", broken);
                check(!broken, what);
                if (system && radii[i].radius != 17 && radii[i].radius < 50) {
                    CGContextRef stock = createDrawn(sRGB, system, optionSets[j], radii[i].radius, radii[i].radius + 1e-6);
                    snprintf(what, sizeof(what), "r = %g, %s: byte-identical to 10.9 shading r and r + 1e-6", radii[i].radius,
                        optionsName(optionSets[j]));
                    check(!memcmp(CGBitmapContextGetData(context), CGBitmapContextGetData(stock), kSide * kSide * 4), what);
                    CGContextRelease(stock);
                }
                CGContextRelease(context);
            }
        }

        static const struct { bool shadow; CGFloat lastAlpha; int tolerance; const char *what; } styled[] = {
            { false, 0.5, 0, "r = 5 under global alpha, half-transparent last stop: byte-identical to 10.9 shading r and r + 1e-6" },
            { true, 1, 0, "r = 5 under a shadow, opaque stops: byte-identical to 10.9 shading r and r + 1e-6" },
            { true, 0.5, 2, "r = 5 under a shadow, half-transparent last stop: within 2 levels of 10.9 shading r and r + 1e-6" },
        };
        for (size_t i = 0; system && i < sizeof(styled) / sizeof(styled[0]); i++) {
            CGContextRef ours = createStyled(sRGB, CGContextDrawRadialGradient, styled[i].shadow, styled[i].lastAlpha, 5, 5);
            CGContextRef stock = createStyled(sRGB, system, styled[i].shadow, styled[i].lastAlpha, 5, 5 + 1e-6);
            int largest = largestDifference(ours, stock);
            printf("    largest difference %d\n", largest);
            check(largest <= styled[i].tolerance, styled[i].what);
            CGContextRelease(ours);
            CGContextRelease(stock);
        }

        {
            CGContextRef context = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, sRGB, kBGRA);
            CGContextSetRGBFillColor(context, 1, 0, 1, 1);
            CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
            CGContextScaleCTM(context, kSide, kSide);
            CGContextClipToRect(context, CGRectMake(0, 0, 1, 1));
            CGContextDrawRadialGradient(context, gGradient, CGPointMake(0.5, 0.5), 100, CGPointMake(0.5, 0.5), 100, kBoth);
            int broken = pixelsBreakingRule(CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context), false, 1000, true,
                kBoth, red, blue, magenta, 0);
            check(!broken, "r = fr = 100 under a 100x bounding-box CTM: the disc covers the clip red");
            CGContextRelease(context);
        }

        {
            unsigned char linearRed[4], linearBlue[4];
            flatPixel(linear, sRGB, 1, 0, 0, linearRed);
            flatPixel(linear, sRGB, 0, 0, 1, linearBlue);
            CGContextRef context = createDrawn(linear, CGContextDrawRadialGradient, kBoth, 5, 5);
            int broken = pixelsBreakingRule(CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context), false, 5, true, kBoth,
                linearRed, linearBlue, magenta, 0);
            printf("    linear-sRGB bitmap: %d pixels differ from flat fills of the stops\n", broken);
            check(!broken, "r = 5 in a linear-sRGB bitmap: flat fills of the first stop inside and the last stop beyond");
            CGContextRelease(context);
        }

        {
            NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(kSide), (id)kIOSurfaceHeight: @(kSide), (id)kIOSurfaceBytesPerElement: @4,
                (id)kIOSurfacePixelFormat: @((unsigned)'BGRA') };
            IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
            CGContextRef context = CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, sRGB, kBGRA);
            CGContextSetRGBFillColor(context, 1, 0, 1, 1);
            CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
            CGContextDrawRadialGradient(context, gGradient, kCenter, 5, kCenter, 5, kBoth);
            CGContextFlush(context);
            IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
            int broken = pixelsBreakingRule(IOSurfaceGetBaseAddress(surface), IOSurfaceGetBytesPerRow(surface), false, 5, true, kBoth,
                red, blue, magenta, 0);
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            printf("    IOSurface: %d pixels differ\n", broken);
            check(!broken, "r = 5 in an IOSurface: red disc, blue beyond");
            CGContextRelease(context);
            CFRelease(surface);
        }

        [NSApplication sharedApplication];
        static const struct { CGFloat radius; bool paints; } asyncRadii[] = { { 5, true }, { 50, true } };
        for (size_t i = 0; i < sizeof(asyncRadii) / sizeof(asyncRadii[0]); i++) {
            gAsyncRadius = asyncRadii[i].radius;
            gAsyncDrawn = false;
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kSide, kSide) styleMask:NSBorderlessWindowMask
                backing:NSBackingStoreBuffered defer:NO];
            [window setColorSpace:[NSColorSpace sRGBColorSpace]];
            NSView *view = [window contentView];
            [view setWantsLayer:YES];
            ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
            CALayer *layer = [CALayer layer];
            layer.drawsAsynchronously = YES;
            layer.frame = CGRectMake(0, 0, kSide, kSide);
            layer.delegate = delegate;
            [view.layer addSublayer:layer];
            [layer setNeedsDisplay];
            [window orderFront:nil];
            [CATransaction flush];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            CGImageRef shot = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber],
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
            int broken = -1;
            if (shot && CGImageGetWidth(shot) == kSide) {
                CGContextRef bitmap = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, sRGB, kBGRA);
                CGContextDrawImage(bitmap, CGRectMake(0, 0, kSide, kSide), shot);
                broken = pixelsBreakingRule(CGBitmapContextGetData(bitmap), CGBitmapContextGetBytesPerRow(bitmap), false,
                    asyncRadii[i].radius, asyncRadii[i].paints, kBoth, red, blue, magenta, 5);
                CGContextRelease(bitmap);
            }
            if (shot)
                CGImageRelease(shot);
            char what[160];
            snprintf(what, sizeof(what), "r = %g in an asynchronously drawn layer: %s (%d pixels on screen differ)", asyncRadii[i].radius,
                asyncRadii[i].paints ? "red disc, blue beyond" : "nothing drawn", broken);
            check(gAsyncDrawn && !broken, what);
            [window orderOut:nil];
        }

        if (system) {
            CGContextRef context = createDrawn(sRGB, system, kBoth, 5, 5);
            int broken = pixelsBreakingRule(CGBitmapContextGetData(context), CGBitmapContextGetBytesPerRow(context), false, 5, false, kBoth,
                red, blue, magenta, 0);
            check(!broken, "10.9's own definition paints nothing for equal radii");
            CGContextRelease(context);
            CGContextRef archive = createDrawn(sRGB, CGContextDrawRadialGradient, kBoth, 4.999, 5);
            CGContextRef stock = createDrawn(sRGB, system, kBoth, 4.999, 5);
            check(!memcmp(CGBitmapContextGetData(archive), CGBitmapContextGetData(stock), kSide * kSide * 4),
                "radii a thousandth apart draw as 10.9's own definition draws them");
            CGContextRelease(archive);
            CGContextRelease(stock);
        }
        CGGradientRelease(gGradient);
        CGColorSpaceRelease(linear);
        CGColorSpaceRelease(sRGB);
    }
    return failures ? 1 : 0;
}
