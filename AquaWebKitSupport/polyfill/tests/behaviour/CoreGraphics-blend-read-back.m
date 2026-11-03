// The read-back route (polyfills/c/CoreGraphics.c) for blend modes QuartzCore does not implement, against a CG bitmap's
// draw, in a surface and an asynchronously drawing layer at scales 1 and 2, under a rotated clip, on opaque and half-
// transparent destinations. A source as the surface holds it comes within two levels premultiplied of the bitmap's group
// of the same drawing. Hue, saturation, color and luminosity fills, strokes, text and transparency layers of opaque
// sources then come within two levels away from edges, where QuartzCore's coverage differs under normal blending too;
// images and gradients within four. A translucent source's result is within two of CG's own composite of that source as
// a normal draw leaves it in the surface; a linear gradient's source is a bitmap's gradient drawn as an image, as the
// route draws it, where a normal draw takes QuartzCore's. Under the software renderer the result is also within what is
// pinned per mode and primitive, those being the source's rounding as the modes amplify it. A GPU rounds differently, and
// CG's HSL composites turn one level of source into as many as 32. Text the cleared surface draws without font smoothing is compared with
// smoothing off at its partly covered pixels. A PDF page reads back. A marked layer holds blended draws, nests, and takes
// the group's alpha. A fill under a shadow composites shadow then source. A current path survives and the blend mode is
// restored. QuartzCore's own hue draw equals its normal draw, which is the premise.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <Block.h>
#include <math.h>
#include <mach-o/dyld.h>
#include <stdio.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern CGBlendMode CGContextGetBlendMode(CGContextRef);
extern size_t wk_coreAnimationTextureLimit(void);
extern void CGContextSetBaseCTM(CGContextRef, CGAffineTransform);
extern void CGContextSetAllowsFontAntialiasing(CGContextRef, bool);
extern void CGContextSetAllowsDithering(CGContextRef, bool);
typedef void (*FillRectFn)(CGContextRef, CGRect);
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static const CGGradientDrawingOptions kBoth = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;
enum { kSide = 256 };

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-92s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static CGColorSpaceRef gSRGB;
static CGImageRef gImage, gOpaqueImage;
static CGGradientRef gGradient, gOpaqueGradient;
static CGFloat gSourceAlpha, gLayerAlpha;
static bool gOpaque;
typedef struct { IOSurfaceRef surface; CGContextRef context; } Target;

static Target createTarget(bool surface)
{
    Target target = { NULL, NULL };
    if (surface) {
        NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(kSide), (id)kIOSurfaceHeight: @(kSide), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((unsigned)'BGRA') };
        target.surface = IOSurfaceCreate((CFDictionaryRef)properties);
        target.context = CGIOSurfaceContextCreate(target.surface, kSide, kSide, 8, 32, gSRGB, kBGRA);
    } else
        target.context = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGContextClearRect(target.context, CGRectMake(0, 0, kSide, kSide));
    CGContextFlush(target.context);
    return target;
}

static void readTarget(Target *target, unsigned char *pixels)
{
    if (target->surface) {
        CGContextFlush(target->context);
        IOSurfaceLock(target->surface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *base = IOSurfaceGetBaseAddress(target->surface);
        size_t rowBytes = IOSurfaceGetBytesPerRow(target->surface);
        for (size_t y = 0; y < kSide; y++)
            memcpy(pixels + y * kSide * 4, base + y * rowBytes, kSide * 4);
        IOSurfaceUnlock(target->surface, kIOSurfaceLockReadOnly, NULL);
    } else
        memcpy(pixels, CGBitmapContextGetData(target->context), kSide * kSide * 4);
}

static const CGRect kBox = { { 48, 48 }, { 160, 160 } };
typedef void (^Primitive)(CGContextRef);
static bool gSmoothFonts = true;

static Primitive primitive(int index)
{
    switch (index) {
    case 0: return Block_copy(^(CGContextRef c) { CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, gSourceAlpha); CGContextFillRect(c, kBox); });
    case 1: return Block_copy(^(CGContextRef c) { CGContextSetRGBStrokeColor(c, 0.8, 0.3, 0.2, gSourceAlpha); CGContextSetLineWidth(c, 24); CGContextStrokeRect(c, kBox); });
    case 2: return Block_copy(^(CGContextRef c) { CGContextSetInterpolationQuality(c, kCGInterpolationNone); CGContextDrawImage(c, kBox, gOpaque ? gOpaqueImage : gImage); });
    case 3: return Block_copy(^(CGContextRef c) { CGContextDrawLinearGradient(c, gOpaque ? gOpaqueGradient : gGradient, CGPointMake(128, 0), CGPointMake(200, 0), kBoth); });
    case 4: return Block_copy(^(CGContextRef c) { CGContextDrawRadialGradient(c, gOpaque ? gOpaqueGradient : gGradient, CGPointMake(128, 128), 10, CGPointMake(128, 128), 90, kBoth); });
    case 5: return Block_copy(^(CGContextRef c) { CGContextSetShouldSmoothFonts(c, gSmoothFonts); CGContextSelectFont(c, "Helvetica-Bold", 90, kCGEncodingMacRoman); CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, gSourceAlpha); CGContextSetTextPosition(c, 40, 90); CGContextShowText(c, "Text", 4); });
    default: return Block_copy(^(CGContextRef c) { CGContextBeginTransparencyLayer(c, NULL); CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, gSourceAlpha); CGContextFillRect(c, kBox); CGContextSetRGBFillColor(c, 0.1, 0.8, 0.5, gLayerAlpha); CGContextFillEllipseInRect(c, kBox); CGContextEndTransparencyLayer(c); });
    }
}
static const char *kNames[] = { "fill", "stroke", "image", "linear", "radial", "text", "layer" };
enum { kPrimitiveCount = 7 };
#define PINS_HUE { 1, 1, 4, 3, 15, 1, 4 }
#define PINS_SATURATION { 1, 1, 3, 5, 3, 1, 1 }
#define PINS_COLOR { 1, 1, 4, 3, 3, 1, 2 }
#define PINS_LUMINOSITY { 1, 1, 3, 4, 4, 1, 1 }

static void prepare(CGContextRef c, CGFloat alpha)
{
    CGContextSetRGBFillColor(c, 0.2, 0.6, 0.9, alpha);
    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
}

// The largest component difference, away from pixels within three of one where the two differ under normal blending.
static int largestAwayFromEdges(const unsigned char *a, const unsigned char *b, const unsigned char *normalA, const unsigned char *normalB, const unsigned char *excluded)
{
    static unsigned char edge[kSide * kSide];
    memset(edge, 0, sizeof(edge));
    if (excluded)
        memcpy(edge, excluded, sizeof(edge));
    for (int y = 0; y < kSide; y++) {
        for (int x = 0; x < kSide; x++) {
            bool differs = false;
            for (int k = 0; k < 4; k++)
                differs |= abs(normalA[(y * kSide + x) * 4 + k] - normalB[(y * kSide + x) * 4 + k]) > 2;
            if (!differs)
                continue;
            for (int dy = -3; dy <= 3; dy++) {
                for (int dx = -3; dx <= 3; dx++) {
                    if (x + dx >= 0 && x + dx < kSide && y + dy >= 0 && y + dy < kSide)
                        edge[(y + dy) * kSide + x + dx] = 1;
                }
            }
        }
    }
    int largest = 0;
    for (size_t i = 0; i < kSide * kSide; i++) {
        if (edge[i])
            continue;
        for (int k = 0; k < 4; k++)
            largest = MAX(largest, abs(a[i * 4 + k] - b[i * 4 + k]));
    }
    return largest;
}

static int partlyCoveredBeyondNormal(const unsigned char *surfacePixels, const unsigned char *bitmapPixels, const unsigned char *normalSurface, const unsigned char *normalBitmap, const unsigned char *partlyCovered)
{
    int beyondNormal = 0;
    for (size_t i = 0; i < kSide * kSide; i++) {
        if (!partlyCovered[i])
            continue;
        for (int k = 0; k < 4; k++) {
            int difference = abs(surfacePixels[i * 4 + k] - bitmapPixels[i * 4 + k]), normal = abs(normalSurface[i * 4 + k] - normalBitmap[i * 4 + k]);
            beyondNormal = MAX(beyondNormal, difference - normal);
        }
    }
    return beyondNormal;
}

// Pixels the text only partly covers: the opaque destination lets a direct draw smooth them, and the cleared surface
// the read-back draws on does not.
static void markPartlyCoveredText(unsigned char *excluded, bool transformed)
{
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetGrayFillColor(c, 1, 1);
    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
    if (transformed) {
        CGContextTranslateCTM(c, 128, 128);
        CGContextRotateCTM(c, 0.3);
        CGContextTranslateCTM(c, -128, -128);
    }
    CGContextSelectFont(c, "Helvetica-Bold", 90, kCGEncodingMacRoman);
    CGContextSetGrayFillColor(c, 0, 1);
    CGContextSetTextPosition(c, 40, 90);
    CGContextShowText(c, "Text", 4);
    const unsigned char *coverage = CGBitmapContextGetData(c);
    memset(excluded, 0, kSide * kSide);
    for (int y = 0; y < kSide; y++) {
        for (int x = 0; x < kSide; x++) {
            unsigned char value = coverage[y * kSide + x];
            if (value == 0 || value == 255)
                continue;
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    if (x + dx >= 0 && x + dx < kSide && y + dy >= 0 && y + dy < kSide)
                        excluded[(y + dy) * kSide + x + dx] = 1;
                }
            }
        }
    }
    CGContextRelease(c);
    CGColorSpaceRelease(gray);
}

static void markPrimitiveEdges(unsigned char *excluded)
{
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef c = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetGrayFillColor(c, 1, 1);
    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
    CGContextSetGrayStrokeColor(c, 0, 1);
    CGContextSetLineWidth(c, 6);
    CGContextStrokeEllipseInRect(c, kBox);
    CGContextStrokeRect(c, kBox);
    const unsigned char *pixels = CGBitmapContextGetData(c);
    for (size_t i = 0; i < kSide * kSide; i++)
        excluded[i] = pixels[i] != 255;
    CGContextRelease(c);
    CGColorSpaceRelease(gray);
}

static void drawScene(CGContextRef c, CGBlendMode mode, CGFloat alpha, Primitive draw)
{
    CGContextSaveGState(c);
    prepare(c, alpha);
    CGContextTranslateCTM(c, 128, 128);
    CGContextRotateCTM(c, 0.3);
    CGContextTranslateCTM(c, -128, -128);
    CGContextClipToRect(c, CGRectMake(16, 16, 224, 224));
    if (!gOpaque)
        CGContextSetAlpha(c, 0.8);
    CGContextSetBlendMode(c, mode);
    draw(c);
    CGContextRestoreGState(c);
}

// The final difference a translucent source leaves, per mode and primitive: the source's own rounding, amplified.
static int pinnedDifference(size_t mode, int primitiveIndex)
{
    static const int pins[4][kPrimitiveCount] = {
        PINS_HUE,
        PINS_SATURATION,
        PINS_COLOR,
        PINS_LUMINOSITY,
    };
    return pins[mode][primitiveIndex];
}

static const struct { CGBlendMode mode; const char *name; } kModes[] = {
    { kCGBlendModeHue, "hue" }, { kCGBlendModeSaturation, "saturation" }, { kCGBlendModeColor, "color" }, { kCGBlendModeLuminosity, "luminosity" },
};

// A CG bitmap's translucent linear gradient, under the context's CTM, drawn into the context as an image.
static void drawLinearAsImage(CGContextRef c)
{
    CGAffineTransform ctm = CGContextGetCTM(c);
    CGContextRef band = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGContextConcatCTM(band, ctm);
    CGContextDrawLinearGradient(band, gGradient, CGPointMake(128, 0), CGPointMake(200, 0), kBoth);
    CGImageRef bandImage = CGBitmapContextCreateImage(band);
    CGContextSaveGState(c);
    CGContextConcatCTM(c, CGAffineTransformInvert(ctm));
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, kSide, kSide), bandImage);
    CGContextRestoreGState(c);
    CGImageRelease(bandImage);
    CGContextRelease(band);
}

// The largest difference, away from edges, of `result` from CG's composite of the source a normal draw leaves in a
// surface over the destination the surface holds.
static int largestFromSurfaceSourceComposite(const unsigned char *result, const unsigned char *normalS, const unsigned char *normalB, const unsigned char *excluded, CGBlendMode mode, CGFloat alpha, int primitiveIndex)
{
    static unsigned char sourcePixels[kSide * kSide * 4];
    Target source = createTarget(true);
    CGContextRef c = source.context;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 128, 128);
    CGContextRotateCTM(c, 0.3);
    CGContextTranslateCTM(c, -128, -128);
    CGContextClipToRect(c, CGRectMake(16, 16, 224, 224));
    if (!gOpaque)
        CGContextSetAlpha(c, 0.8);
    if (primitiveIndex == 3)
        drawLinearAsImage(c);
    else
        primitive(primitiveIndex)(c);
    CGContextRestoreGState(c);
    readTarget(&source, sourcePixels);
    CGContextRef sourceBitmap = CGBitmapContextCreate(sourcePixels, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGImageRef sourceImage = CGBitmapContextCreateImage(sourceBitmap);
    static unsigned char destinationPixels[kSide * kSide * 4];
    Target destination = createTarget(true);
    prepare(destination.context, alpha);
    readTarget(&destination, destinationPixels);
    CGContextRef destinationBitmap = CGBitmapContextCreate(destinationPixels, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGImageRef destinationImage = CGBitmapContextCreateImage(destinationBitmap);
    Target composite = createTarget(false);
    CGContextSetInterpolationQuality(composite.context, kCGInterpolationNone);
    CGContextDrawImage(composite.context, CGRectMake(0, 0, kSide, kSide), destinationImage);
    CGContextSetBlendMode(composite.context, mode);
    CGContextDrawImage(composite.context, CGRectMake(0, 0, kSide, kSide), sourceImage);
    static unsigned char compositePixels[kSide * kSide * 4];
    readTarget(&composite, compositePixels);
    int largest = largestAwayFromEdges(result, compositePixels, normalS, normalB, excluded);
    CGImageRelease(destinationImage);
    CGContextRelease(destinationBitmap);
    CGContextRelease(destination.context);
    CFRelease(destination.surface);
    CGImageRelease(sourceImage);
    CGContextRelease(sourceBitmap);
    CGContextRelease(composite.context);
    CGContextRelease(source.context);
    CFRelease(source.surface);
    return largest;
}

static CGContextRef shownPixels(NSWindow *window)
{
    CGImageRef shot = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber], kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    CGContextRef shown = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide * 4, gSRGB, kBGRA);
    CGContextDrawImage(shown, CGRectMake(0, 0, kSide, kSide), shot);
    CGImageRelease(shot);
    return shown;
}

@interface BlockDelegate : NSObject <CALayerDelegate> {
@public
    void (^draw)(CGContextRef);
}
@end
@implementation BlockDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    draw(context);
}
@end

// The largest difference of `draw` in an asynchronous layer at `scale` from `draw` in a bitmap of that scale, whose base
// CTM carries it, each shown through the same layer.
static int largestFromBitmapThroughLayer(int scale, void (^draw)(CGContextRef))
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
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
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
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
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

static bool gAsyncDrawn;
static int gAsyncMode, gAsyncPrimitive;
@interface ProbeDelegate : NSObject <CALayerDelegate>
@end
@implementation ProbeDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    prepare(context, 1);
    CGContextSetBlendMode(context, kModes[gAsyncMode].mode);
    primitive(gAsyncPrimitive)(context);
    gAsyncDrawn = true;
}
@end

int main(void)
{
    @autoreleasepool {
        gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef checker = CGBitmapContextCreate(NULL, 64, 64, 8, 256, gSRGB, kBGRA);
        CGContextSetRGBFillColor(checker, 0.5, 0.25, 0.75, 0.6);
        CGContextFillRect(checker, CGRectMake(0, 0, 64, 64));
        CGContextSetRGBFillColor(checker, 0.1, 0.9, 0.2, 0.6);
        CGContextFillRect(checker, CGRectMake(16, 16, 32, 32));
        gImage = CGBitmapContextCreateImage(checker);
        const CGFloat stops[] = { 1, 0, 0, 1, 0, 0, 1, 0.5 };
        gGradient = CGGradientCreateWithColorComponents(gSRGB, stops, NULL, 2);

        const CGFloat opaqueStops[] = { 1, 0, 0, 1, 0, 0, 1, 1 };
        gOpaqueGradient = CGGradientCreateWithColorComponents(gSRGB, opaqueStops, NULL, 2);
        CGContextRef solid = CGBitmapContextCreate(NULL, 64, 64, 8, 256, gSRGB, kBGRA);
        CGContextSetRGBFillColor(solid, 0.5, 0.25, 0.75, 1);
        CGContextFillRect(solid, CGRectMake(0, 0, 64, 64));
        CGContextSetRGBFillColor(solid, 0.1, 0.9, 0.2, 1);
        CGContextFillRect(solid, CGRectMake(16, 16, 32, 32));
        gOpaqueImage = CGBitmapContextCreateImage(solid);

        static unsigned char surfacePixels[kSide * kSide * 4], bitmapPixels[kSide * kSide * 4], normalSurface[kSide * kSide * 4], normalBitmap[kSide * kSide * 4];
        static unsigned char excluded[kSide * kSide];
        markPartlyCoveredText(excluded, true);

        // A source as the surface holds it, against the bitmap's group of the same drawing.
        for (int opaque = 0; opaque < 2; opaque++)
        for (int p = 0; p < kPrimitiveCount; p++) {
            gOpaque = opaque;
            gSourceAlpha = opaque ? 1 : 0.7;
            gLayerAlpha = opaque ? 1 : 0.5;
            Target surface = createTarget(true), bitmap = createTarget(false);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                CGContextTranslateCTM(c, 128, 128);
                CGContextRotateCTM(c, 0.3);
                CGContextTranslateCTM(c, -128, -128);
                CGContextClipToRect(c, CGRectMake(16, 16, 224, 224));
                if (!opaque)
                    CGContextSetAlpha(c, 0.8);
                primitive(p)(c);
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            int largest = largestAwayFromEdges(surfacePixels, bitmapPixels, surfacePixels, bitmapPixels, p == 5 ? excluded : NULL);
            char what[140];
            snprintf(what, sizeof(what), "%s %s as the surface holds it: within 2 of the bitmap's group (largest %d)", opaque ? "opaque" : "translucent", kNames[p], largest);
            check(largest <= 2, what);
            if (p == 3 && !opaque) {
                Target imageSurface = createTarget(true);
                CGContextRef c = imageSurface.context;
                CGContextTranslateCTM(c, 128, 128);
                CGContextRotateCTM(c, 0.3);
                CGContextTranslateCTM(c, -128, -128);
                CGContextClipToRect(c, CGRectMake(16, 16, 224, 224));
                CGContextSetAlpha(c, 0.8);
                drawLinearAsImage(c);
                readTarget(&imageSurface, surfacePixels);
                int imageLargest = largestAwayFromEdges(surfacePixels, bitmapPixels, surfacePixels, bitmapPixels, NULL);
                snprintf(what, sizeof(what), "translucent linear reference image as the surface holds it: within 2 of the bitmap's group (largest %d)", imageLargest);
                check(imageLargest <= 2, what);
                CGContextRelease(imageSurface.context);
                CFRelease(imageSurface.surface);
            }
            CGContextRelease(surface.context);
            CGContextRelease(bitmap.context);
            CFRelease(surface.surface);
        }

        for (int opaque = 1; opaque >= 0; opaque--) {
            gOpaque = opaque;
            gSourceAlpha = opaque ? 1 : 0.7;
            gLayerAlpha = opaque ? 1 : 0.5;
            for (size_t m = 0; m < 4; m++) {
                for (int p = 0; p < kPrimitiveCount; p++) {
                    for (int translucent = 0; translucent < 2; translucent++) {
                        CGFloat alpha = translucent ? 0.5 : 1;
                        Target surface = createTarget(true), bitmap = createTarget(false), normalS = createTarget(true), normalB = createTarget(false);
                        drawScene(surface.context, kModes[m].mode, alpha, primitive(p));
                        drawScene(bitmap.context, kModes[m].mode, alpha, primitive(p));
                        drawScene(normalS.context, kCGBlendModeNormal, alpha, primitive(p));
                        drawScene(normalB.context, kCGBlendModeNormal, alpha, primitive(p));
                        readTarget(&surface, surfacePixels);
                        readTarget(&bitmap, bitmapPixels);
                        readTarget(&normalS, normalSurface);
                        readTarget(&normalB, normalBitmap);
                        int largest = largestAwayFromEdges(surfacePixels, bitmapPixels, normalSurface, normalBitmap, p == 5 ? excluded : NULL);
                        // Images and gradients stay within two levels as sources, checked above; these modes amplify that.
                        bool sampled = p == 2 || p == 3 || p == 4;
                        int allowed = opaque ? (sampled ? 4 : 2) : pinnedDifference(m, p);
                        if (!opaque) {
                            int fromComposite = largestFromSurfaceSourceComposite(surfacePixels, normalSurface, normalBitmap, p == 5 ? excluded : NULL, kModes[m].mode, alpha, p);
                            char compositeWhat[160];
                            snprintf(compositeWhat, sizeof(compositeWhat), "translucent %s %s, destination alpha %.1f: within 2 of CG's composite of the surface's source (largest %d)", kModes[m].name, kNames[p], alpha, fromComposite);
                            check(fromComposite <= 2, compositeWhat);
                        }
                        char what[140];
                        snprintf(what, sizeof(what), "%s %s %s, destination alpha %.1f: within %d of the bitmap (largest %d)", opaque ? "opaque" : "translucent", kModes[m].name, kNames[p], alpha, allowed, largest);
                        if (opaque || wk_coreAnimationTextureLimit())
                            check(largest <= allowed, what);
                        else
                            printf("    translucent %s %s, destination alpha %.1f: largest %d from the bitmap\n", kModes[m].name, kNames[p], alpha, largest);
                        if (p == 5) {
                            printf("    %s %s text, destination alpha %.1f: partly covered pixels, smoothing on: %d beyond the normal-mode difference\n", opaque ? "opaque" : "translucent", kModes[m].name, alpha, partlyCoveredBeyondNormal(surfacePixels, bitmapPixels, normalSurface, normalBitmap, excluded));
                            Target controls[4] = { createTarget(true), createTarget(false), createTarget(true), createTarget(false) };
                            gSmoothFonts = false;
                            drawScene(controls[0].context, kModes[m].mode, alpha, primitive(p));
                            drawScene(controls[1].context, kModes[m].mode, alpha, primitive(p));
                            drawScene(controls[2].context, kCGBlendModeNormal, alpha, primitive(p));
                            drawScene(controls[3].context, kCGBlendModeNormal, alpha, primitive(p));
                            gSmoothFonts = true;
                            readTarget(&controls[0], surfacePixels);
                            readTarget(&controls[1], bitmapPixels);
                            readTarget(&controls[2], normalSurface);
                            readTarget(&controls[3], normalBitmap);
                            int beyond = partlyCoveredBeyondNormal(surfacePixels, bitmapPixels, normalSurface, normalBitmap, excluded);
                            snprintf(what, sizeof(what), "%s %s text, destination alpha %.1f, smoothing off: partly covered pixels within 8 beyond normal (largest %d)", opaque ? "opaque" : "translucent", kModes[m].name, alpha, beyond);
                            check(beyond <= 8, what);
                            for (int i = 0; i < 4; i++) {
                                CGContextRelease(controls[i].context);
                                if (controls[i].surface)
                                    CFRelease(controls[i].surface);
                            }
                        }
                        CGContextRelease(surface.context);
                        CGContextRelease(bitmap.context);
                        CGContextRelease(normalS.context);
                        CGContextRelease(normalB.context);
                        CFRelease(surface.surface);
                        CFRelease(normalS.surface);
                    }
                }
            }
        }
        gOpaque = true;
        gSourceAlpha = 1;
        gLayerAlpha = 1;

        // A marked layer: a blended draw inside it blends with the layer's contents, nested too, under the group's alpha.
        {
            const void *keys[] = { CFSTR("AquaWebKitBlendingGroupLayer") };
            const void *values[] = { kCFBooleanTrue };
            CFDictionaryRef marked = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            for (int nested = 0; nested < 2; nested++) {
                for (int groupAlpha = 0; groupAlpha < 2; groupAlpha++) {
                    Target surface = createTarget(true), bitmap = createTarget(false);
                    for (int pass = 0; pass < 2; pass++) {
                        CGContextRef c = pass ? bitmap.context : surface.context;
                        prepare(c, 1);
                        CGContextSetAlpha(c, groupAlpha ? 0.6 : 1);
                        CGContextBeginTransparencyLayer(c, marked);
                        CGContextSetRGBFillColor(c, 0.9, 0.8, 0.1, 1);
                        CGContextFillRect(c, CGRectMake(32, 32, 192, 192));
                        if (nested) {
                            CGContextBeginTransparencyLayer(c, marked);
                            CGContextSetRGBFillColor(c, 0.1, 0.2, 0.9, 1);
                            CGContextFillRect(c, CGRectMake(48, 48, 160, 160));
                        }
                        CGContextSetBlendMode(c, kCGBlendModeLuminosity);
                        CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                        CGContextFillRect(c, kBox);
                        CGContextSetBlendMode(c, kCGBlendModeNormal);
                        if (nested)
                            CGContextEndTransparencyLayer(c);
                        CGContextEndTransparencyLayer(c);
                    }
                    readTarget(&surface, surfacePixels);
                    readTarget(&bitmap, bitmapPixels);
                    int largest = 0;
                    for (size_t i = 0; i < kSide * kSide * 4; i++)
                        largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
                    char what[140];
                    snprintf(what, sizeof(what), "luminosity in a marked layer%s%s: within 2 of the bitmap everywhere (largest %d)", nested ? ", nested" : "", groupAlpha ? ", group alpha 0.6" : "", largest);
                    check(largest <= 2, what);
                    CGContextRelease(surface.context);
                    CGContextRelease(bitmap.context);
                    CFRelease(surface.surface);
                }
            }
            CFRelease(marked);
        }

        // A shadow under each mode.
        for (size_t m = 0; m < 4; m++) {
            Target surface = createTarget(true), bitmap = createTarget(false);
            CGColorRef shadow = CGColorCreateGenericRGB(0, 0, 0, 0.8);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                prepare(c, 1);
                CGContextSetBlendMode(c, kModes[m].mode);
                CGContextSetShadowWithColor(c, CGSizeMake(16, -16), 4, shadow);
                CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                CGContextFillRect(c, CGRectMake(48, 72, 120, 120));
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            int largest = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
            char what[120];
            snprintf(what, sizeof(what), "%s fill under a shadow: within 3 of the bitmap everywhere (largest %d)", kModes[m].name, largest);
            check(largest <= 3, what);
            CGColorRelease(shadow);
            CGContextRelease(surface.context);
            CGContextRelease(bitmap.context);
            CFRelease(surface.surface);
        }

        // QuartzCore's own hue is its normal: the system draw through a bitmap comparison would not show it, so the
        // surface under the route must differ from the normal draw.
        {
            Target surface = createTarget(true), normalS = createTarget(true);
            prepare(surface.context, 1);
            prepare(normalS.context, 1);
            CGContextSetBlendMode(surface.context, kCGBlendModeHue);
            primitive(0)(surface.context);
            primitive(0)(normalS.context);
            readTarget(&surface, surfacePixels);
            readTarget(&normalS, normalSurface);
            check(memcmp(surfacePixels + (128 * kSide + 128) * 4, normalSurface + (128 * kSide + 128) * 4, 4) != 0, "a hue fill differs from a normal fill");
            check(CGContextGetBlendMode(surface.context) == kCGBlendModeHue, "the blend mode is the draw's own afterward");
            CGContextRelease(surface.context);
            CGContextRelease(normalS.context);
        }

        // Outside the clip, and a current path.
        {
            Target surface = createTarget(true), bitmap = createTarget(false);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                prepare(c, 1);
                CGContextClipToRect(c, CGRectMake(64, 64, 64, 64));
                CGContextSetBlendMode(c, kCGBlendModeHue);
                CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                CGContextAddEllipseInRect(c, CGRectMake(0, 0, kSide, kSide));
                CGContextFillPath(c);
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            int largest = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
            char what[120];
            snprintf(what, sizeof(what), "a path filled under hue and a rect clip: within 2 of the bitmap everywhere (largest %d)", largest);
            check(largest <= 2, what);
            CGContextRelease(surface.context);
            CGContextRelease(bitmap.context);
        }

        // A PDF page.
        {
            CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
            CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(data);
            CGRect media = CGRectMake(0, 0, kSide, kSide);
            CGContextRef pdf = CGPDFContextCreate(consumer, &media, NULL);
            CGPDFContextBeginPage(pdf, NULL);
            CGContextSetRGBFillColor(pdf, 0.8, 0.3, 0.2, 1);
            CGContextFillRect(pdf, kBox);
            CGPDFContextEndPage(pdf);
            CGPDFContextClose(pdf);
            CGContextRelease(pdf);
            CGDataConsumerRelease(consumer);
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
            CGPDFDocumentRef document = CGPDFDocumentCreateWithProvider(provider);
            CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
            Target surface = createTarget(true), bitmap = createTarget(false);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                prepare(c, 1);
                CGContextSetBlendMode(c, kCGBlendModeLuminosity);
                CGContextDrawPDFPage(c, page);
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            int largest = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
            char what[120];
            snprintf(what, sizeof(what), "a PDF page under luminosity: within 2 of the bitmap everywhere (largest %d)", largest);
            check(largest <= 2, what);
            CGContextRelease(surface.context);
            CGContextRelease(bitmap.context);
            CFRelease(surface.surface);
            CGPDFDocumentRelease(document);
            CGDataProviderRelease(provider);
            CFRelease(data);
        }

        // CoreGraphics measures a shadow in base space, so at contents scale 2 it reaches twice as many device pixels.
        [NSApplication sharedApplication];
        CFStringRef markedKeys[] = { CFSTR("AquaWebKitBlendingGroupLayer") };
        CFDictionaryRef marked = CFDictionaryCreate(NULL, (const void **)markedKeys, (const void **)&kCFBooleanTrue, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CGColorRef scaleShadow = CGColorCreateGenericRGB(0, 0, 0, 0.8);
        for (int scale = 1; scale <= 2; scale++) {
            for (size_t m = 0; m < 4; m++) {
                for (int inLayer = 0; inLayer < 2; inLayer++) {
                    CGBlendMode mode = kModes[m].mode;
                    int largest = largestFromBitmapThroughLayer(scale, ^(CGContextRef c) {
                        CGContextSetRGBFillColor(c, 0.2, 0.6, 0.9, 1);
                        CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
                        CGContextSetBlendMode(c, mode);
                        CGContextSetShadowWithColor(c, CGSizeMake(6, -6), 5, scaleShadow);
                        CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                        if (inLayer)
                            CGContextBeginTransparencyLayer(c, marked);
                        CGContextFillRect(c, CGRectMake(64, 64, 96, 96));
                        if (inLayer)
                            CGContextEndTransparencyLayer(c);
                    });
                    char what[140];
                    snprintf(what, sizeof(what), "%s %s under a shadow, async layer at scale %d: within 3 of the bitmap (largest %d)", kModes[m].name, inLayer ? "marked layer" : "fill", scale, largest);
                    check(largest <= 3, what);
                }
            }
        }
        CGColorRelease(scaleShadow);
        CFRelease(marked);

        // Text under a shadow: the context's text matrix and position hold, and the position advances as a bitmap's does.
        {
            CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 28, NULL);
            CGFontRef graphicsFont = CTFontCopyGraphicsFont(font, NULL);
            UniChar characters[] = { 'H', 'u', 'e', 'd' };
            CGGlyph glyphs[4];
            CTFontGetGlyphsForCharacters(font, characters, glyphs, 4);
            const CGSize advances[] = { { 22, 0 }, { 18, 0 }, { 18, 0 }, { 18, 0 } };
            const CGPoint positions[] = { { 0, 0 }, { 22, 0 }, { 40, 0 }, { 58, 0 } };
            CGColorRef shadow = CGColorCreateGenericRGB(0, 0, 0, 0.8);
            static const char *kTextDraws[] = { "CGContextShowText", "CGContextShowGlyphsWithAdvances", "CGContextShowGlyphsAtPositions", "CTFontDrawGlyphs" };
            static const struct { const char *name; void (*set)(CGContextRef, bool); } kAllows[] = {
                { "antialiasing", CGContextSetAllowsAntialiasing }, { "dithering", CGContextSetAllowsDithering }, { "font antialiasing", CGContextSetAllowsFontAntialiasing },
                { "font smoothing", CGContextSetAllowsFontSmoothing }, { "font subpixel positioning", CGContextSetAllowsFontSubpixelPositioning }, { "font subpixel quantization", CGContextSetAllowsFontSubpixelQuantization },
            };
            const size_t allowsCount = sizeof(kAllows) / sizeof(kAllows[0]);
            for (size_t draw = 0; draw < 4; draw++) {
                for (size_t off = 0; off <= allowsCount; off++) {
                    Target surface = createTarget(true), bitmap = createTarget(false);
                    for (int pass = 0; pass < 2; pass++) {
                        CGContextRef c = pass ? bitmap.context : surface.context;
                        prepare(c, 1);
                        for (size_t a = 0; a < allowsCount; a++)
                            kAllows[a].set(c, a != off);
                        CGContextSetBlendMode(c, kCGBlendModeLuminosity);
                        CGContextSetShadowWithColor(c, CGSizeMake(4, -4), 2, shadow);
                        CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                        CGContextSelectFont(c, "Helvetica", 28, kCGEncodingMacRoman);
                        CGContextSetFont(c, graphicsFont);
                        CGContextSetFontSize(c, 28);
                        CGContextSetTextMatrix(c, CGAffineTransformMakeScale(1.5, 1));
                        CGContextSetTextPosition(c, 20, 90);
                        switch (draw) {
                        case 0:
                            CGContextSelectFont(c, "Helvetica", 28, kCGEncodingMacRoman);
                            CGContextShowText(c, "Hued", 4);
                            break;
                        case 1:
                            CGContextShowGlyphsWithAdvances(c, glyphs, advances, 4);
                            break;
                        case 2:
                            CGContextShowGlyphsAtPositions(c, glyphs, positions, 4);
                            break;
                        default:
                            CTFontDrawGlyphs(font, glyphs, positions, 4, c);
                            break;
                        }
                    }
                    readTarget(&surface, surfacePixels);
                    readTarget(&bitmap, bitmapPixels);
                    int largest = 0;
                    for (size_t i = 0; i < kSide * kSide * 4; i++)
                        largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
                    char what[160];
                    if (off == allowsCount) {
                        CGPoint surfaceAfter = CGContextGetTextPosition(surface.context), bitmapAfter = CGContextGetTextPosition(bitmap.context);
                        snprintf(what, sizeof(what), "%s under luminosity and a shadow, text matrix 1.5: within 3 of the bitmap (largest %d)", kTextDraws[draw], largest);
                        check(largest <= 3, what);
                        snprintf(what, sizeof(what), "%s leaves the text position a bitmap's does", kTextDraws[draw]);
                        check(fabs(surfaceAfter.x - bitmapAfter.x) < 0.01 && fabs(surfaceAfter.y - bitmapAfter.y) < 0.01, what);
                    } else {
                        snprintf(what, sizeof(what), "%s under luminosity and a shadow, %s not allowed: within 3 of the bitmap (largest %d)", kTextDraws[draw], kAllows[off].name, largest);
                        check(largest <= 3, what);
                    }
                    CGContextRelease(surface.context);
                    CGContextRelease(bitmap.context);
                    CFRelease(surface.surface);
                }
            }

            // A clipping text mode reaches the context; the same scene under normal blending bounds the renderers' difference.
            int largestOf[2];
            for (int hue = 0; hue < 2; hue++) {
                Target surface = createTarget(true), bitmap = createTarget(false);
                for (int pass = 0; pass < 2; pass++) {
                    CGContextRef c = pass ? bitmap.context : surface.context;
                    prepare(c, 1);
                    CGContextSaveGState(c);
                    CGContextSetBlendMode(c, hue ? kCGBlendModeHue : kCGBlendModeNormal);
                    CGContextSetShadowWithColor(c, CGSizeMake(4, -4), 2, shadow);
                    CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                    CGContextSelectFont(c, "Helvetica", 48, kCGEncodingMacRoman);
                    CGContextSetTextDrawingMode(c, kCGTextFillClip);
                    CGContextSetTextPosition(c, 20, 90);
                    CGContextShowText(c, "Hued", 4);
                    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
                    CGContextSetBlendMode(c, kCGBlendModeNormal);
                    CGContextSetRGBFillColor(c, 0.1, 0.8, 0.3, 1);
                    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
                    CGContextRestoreGState(c);
                }
                readTarget(&surface, surfacePixels);
                readTarget(&bitmap, bitmapPixels);
                largestOf[hue] = 0;
                for (size_t i = 0; i < kSide * kSide * 4; i++)
                    largestOf[hue] = MAX(largestOf[hue], abs(surfacePixels[i] - bitmapPixels[i]));
                CGContextRelease(surface.context);
                CGContextRelease(bitmap.context);
                CFRelease(surface.surface);
            }
            char what[160];
            snprintf(what, sizeof(what), "a clipping text mode under hue and a shadow: within normal blending's %d of the bitmap (largest %d)", largestOf[0], largestOf[1]);
            check(largestOf[1] <= largestOf[0], what);
            CGColorRelease(shadow);
            CFRelease(graphicsFont);
            CFRelease(font);
        }

        // A shadow cast into the surface by a shape outside it.
        {
            Target surface = createTarget(true), bitmap = createTarget(false);
            CGColorRef shadow = CGColorCreateGenericRGB(0, 0, 0, 0.8);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                prepare(c, 1);
                CGContextSetBlendMode(c, kCGBlendModeLuminosity);
                CGContextSetShadowWithColor(c, CGSizeMake(0, 120), 4, shadow);
                CGContextSetRGBFillColor(c, 0.8, 0.3, 0.2, 1);
                CGContextFillRect(c, CGRectMake(48, -100, 120, 60));
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            int largest = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
            char what[120];
            snprintf(what, sizeof(what), "a shadow cast from outside the surface: within 3 of the bitmap (largest %d)", largest);
            check(largest <= 3, what);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef c = pass ? bitmap.context : surface.context;
                prepare(c, 1);
                CGContextBeginTransparencyLayer(c, NULL);
                CGContextFillRect(c, CGRectMake(48, -100, 120, 60));
                CGContextEndTransparencyLayer(c);
            }
            readTarget(&surface, surfacePixels);
            readTarget(&bitmap, bitmapPixels);
            largest = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                largest = MAX(largest, abs(surfacePixels[i] - bitmapPixels[i]));
            printf("    a shadow cast from a transparency layer outside the surface: largest %d from the bitmap\n", largest);
            CGColorRelease(shadow);
            CGContextRelease(surface.context);
            CGContextRelease(bitmap.context);
            CFRelease(surface.surface);
        }

        // Asynchronously drawn layers, read back from the window.
        [NSApplication sharedApplication];
        static unsigned char asyncEdges[kSide * kSide];
        markPrimitiveEdges(asyncEdges);
        for (int opaque = 1; opaque >= 0; opaque--) {
            gOpaque = opaque;
            gSourceAlpha = opaque ? 1 : 0.7;
            gLayerAlpha = opaque ? 1 : 0.5;
            for (gAsyncMode = 0; gAsyncMode < 4; gAsyncMode++) {
                for (gAsyncPrimitive = 0; gAsyncPrimitive < kPrimitiveCount; gAsyncPrimitive += 2) {
                    for (int scale = 1; scale <= 2; scale++) {
                        gAsyncDrawn = false;
                        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(60, 60, kSide, kSide) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
                        [window setColorSpace:[NSColorSpace sRGBColorSpace]];
                        NSView *view = [window contentView];
                        [view setWantsLayer:YES];
                        ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
                        CALayer *layer = [CALayer layer];
                        layer.drawsAsynchronously = YES;
                        layer.contentsScale = scale;
                        layer.frame = CGRectMake(0, 0, kSide, kSide);
                        layer.delegate = delegate;
                        [view.layer addSublayer:layer];
                        [layer setNeedsDisplay];
                        [window orderFront:nil];
                        [CATransaction flush];
                        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                        CGContextRef shown = shownPixels(window);
                        size_t referenceSide = kSide * scale;
                        CGContextRef referenceBitmap = CGBitmapContextCreate(NULL, referenceSide, referenceSide, 8, referenceSide * 4, gSRGB, kBGRA);
                        CGContextScaleCTM(referenceBitmap, scale, scale);
                        prepare(referenceBitmap, 1);
                        CGContextSetBlendMode(referenceBitmap, kModes[gAsyncMode].mode);
                        primitive(gAsyncPrimitive)(referenceBitmap);
                        CGImageRef referenceImage = CGBitmapContextCreateImage(referenceBitmap);
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        layer.delegate = nil;
                        layer.drawsAsynchronously = NO;
                        layer.contents = (__bridge id)referenceImage;
                        [CATransaction commit];
                        [CATransaction flush];
                        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                        CGContextRef reference = shownPixels(window);
                        int largest = largestAwayFromEdges(CGBitmapContextGetData(shown), CGBitmapContextGetData(reference), CGBitmapContextGetData(reference), CGBitmapContextGetData(reference), asyncEdges);
                        int allowed = opaque ? 2 : 3;
                        char what[140];
                        snprintf(what, sizeof(what), "%s %s %s, async layer at scale %d: within %d of the bitmap through the same layer (largest %d)", opaque ? "opaque" : "translucent", kModes[gAsyncMode].name, kNames[gAsyncPrimitive], scale, allowed, largest);
                        check(gAsyncDrawn && largest <= allowed, what);
                        CGImageRelease(referenceImage);
                        CGContextRelease(referenceBitmap);
                        CGContextRelease(shown);
                        CGContextRelease(reference);
                        [window orderOut:nil];
                    }
                }
            }
        }
    }
    return failures ? 1 : 0;
}
