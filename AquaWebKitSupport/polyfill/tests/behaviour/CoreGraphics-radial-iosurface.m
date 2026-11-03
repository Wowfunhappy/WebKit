// The CGContextDrawRadialGradient replacement (polyfills/c/CoreGraphics.c) for IOSurface contexts and the
// context Core Animation hands an asynchronously drawing layer's delegate. No draw here reaches QuartzCore's
// radial entry, delegate slots 22 and 9, where 10.9's own definition does, which is the premise: in this
// machine's software renderer the pixels of that entry and of the bitmap route agree, so only the slots tell
// them apart. A 400x704 mask of radial-gradient(1px at -10px -10px, transparent 0, white 1px) is opaque white
// throughout and byte-identical to 10.9's own draw into a bitmap. Concentric and offset circles, within an
// antialiased elliptical clip under a rotating, scaling CTM, come within two levels of the bitmap draw
// under global alpha and the multiply blend mode, a shadow, a linear-sRGB gradient, and a transparency layer;
// QuartzCore antialiases the clip's edge in its own way. Each blend mode that changes the destination beneath a
// transparent source leaves pixels the gradient does not cover untouched, in a surface and in an 8-bit bitmap of
// another colour space, and 64 draws leave them byte-exact; under a shadow as well a surface is byte-identical to 10.9's own draw into a surface, or for plus-darker within three levels of the bitmap's. A
// bitmap under a shadow is 10.9's own draw. A surface wider than one band holds, with a shadow and under the
// copy blend mode too. A gray gradient holds, a gray surface takes the route, a singular CTM paints nothing, and
// an asymmetric hard-stop gradient in an asynchronously drawing layer lands where it belongs at contents scales
// 1 and 2.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern void *CGContextGetDelegate(CGContextRef);
extern void CGContextDelegateSetCallback(void *, int, void (*)(void));
typedef void (*DrawRadialFn)(CGContextRef, CGGradientRef, CGPoint, CGFloat, CGPoint, CGFloat, CGGradientDrawingOptions);
typedef void (*DrawLinearFn)(CGContextRef, CGGradientRef, CGPoint, CGPoint, CGGradientDrawingOptions);

static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static const CGGradientDrawingOptions kBoth = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-96s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static DrawRadialFn gSystem;

static void *systemSymbol(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

// QuartzCore's radial entry: slot 22 of the context delegate takes concentric circles and offset ones, and slot 9
// offset ones as well. With these installed the context paints no radial gradient of its own.
static int gRadialHits;
// Also counts slot 21, the linear entry.
static int countRadialHit(void)
{
    gRadialHits++;
    return 0;
}

static void hookRadialEntry(CGContextRef context)
{
    CGContextDelegateSetCallback(CGContextGetDelegate(context), 22, (void (*)(void))countRadialHit);
    CGContextDelegateSetCallback(CGContextGetDelegate(context), 9, (void (*)(void))countRadialHit);
}

// A drawing target: an IOSurface context or a bitmap context, read back as BGRA rows from the top.
typedef struct {
    IOSurfaceRef surface;
    CGContextRef context;
    size_t width, height;
    unsigned char *pixels;
} Target;

static IOSurfaceRef createSurface(size_t width, size_t height, int bytesPerElement, unsigned format)
{
    NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height), (id)kIOSurfaceBytesPerElement: @(bytesPerElement),
        (id)kIOSurfacePixelFormat: @(format) };
    return IOSurfaceCreate((CFDictionaryRef)properties);
}

static Target createTarget(bool surface, size_t width, size_t height, CGColorSpaceRef space)
{
    Target target = { NULL, NULL, width, height, NULL };
    if (surface) {
        target.surface = createSurface(width, height, 4, 'BGRA');
        target.context = CGIOSurfaceContextCreate(target.surface, width, height, 8, 32, space, kBGRA);
    } else
        target.context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kBGRA);
    CGContextClearRect(target.context, CGRectMake(0, 0, width, height));
    return target;
}

static void readTarget(Target *target)
{
    target->pixels = malloc(target->width * target->height * 4);
    if (target->surface) {
        CGContextFlush(target->context);
        IOSurfaceLock(target->surface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *base = IOSurfaceGetBaseAddress(target->surface);
        size_t rowBytes = IOSurfaceGetBytesPerRow(target->surface);
        for (size_t y = 0; y < target->height; y++)
            memcpy(target->pixels + y * target->width * 4, base + y * rowBytes, target->width * 4);
        IOSurfaceUnlock(target->surface, kIOSurfaceLockReadOnly, NULL);
    } else
        memcpy(target->pixels, CGBitmapContextGetData(target->context), target->width * target->height * 4);
}

static void releaseTarget(Target *target)
{
    CGContextRelease(target->context);
    if (target->surface)
        CFRelease(target->surface);
    free(target->pixels);
}

// The largest component difference between two targets, within the fraction `inset` of the elliptical clip's
// radii when `inset` is positive.
static int largestDifference(const Target *a, const Target *b, CGAffineTransform clipTransform, double inset)
{
    CGAffineTransform toClip = CGAffineTransformInvert(clipTransform);
    int largest = 0;
    for (size_t row = 0; row < a->height; row++) {
        for (size_t x = 0; x < a->width; x++) {
            if (inset > 0) {
                CGPoint point = CGPointApplyAffineTransform(CGPointMake(x + 0.5, a->height - row - 0.5), toClip);
                if (hypot((point.x - 50) / 45, (point.y - 50) / 40) > inset)
                    continue;
            }
            const unsigned char *p = a->pixels + (row * a->width + x) * 4, *q = b->pixels + (row * a->width + x) * 4;
            for (int c = 0; c < 4; c++)
                largest = MAX(largest, abs(p[c] - q[c]));
        }
    }
    return largest;
}

enum { kSide = 120 };
static CGColorSpaceRef gSRGB, gLinear;

static CGAffineTransform sceneTransform(void)
{
    CGAffineTransform transform = CGAffineTransformMakeTranslation(60, 60);
    transform = CGAffineTransformRotate(transform, 0.3);
    transform = CGAffineTransformScale(transform, 1.3, 0.9);
    return CGAffineTransformTranslate(transform, -50, -50);
}

// A red-to-half-transparent-blue gradient over magenta within the elliptical clip.
typedef struct {
    bool concentric, partial, shadow, inLayer;
    CGBlendMode blendMode;
    CGFloat alpha;
    CGColorSpaceRef gradientSpace;
} Scene;

static void drawScene(CGContextRef context, Scene scene, DrawRadialFn draw)
{
    CGContextSetRGBFillColor(context, 1, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
    const CGFloat components[] = { 1, 0, 0, 1, 0, 0, 1, 0.5 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(scene.gradientSpace ? scene.gradientSpace : gSRGB, components, NULL, 2);
    CGContextConcatCTM(context, sceneTransform());
    CGContextAddEllipseInRect(context, CGRectMake(5, 10, 90, 80));
    CGContextClip(context);
    if (scene.alpha)
        CGContextSetAlpha(context, scene.alpha);
    CGContextSetBlendMode(context, scene.blendMode);
    if (scene.shadow) {
        CGColorRef shadowColor = CGColorCreateGenericRGB(0, 0, 0, 0.8);
        CGContextSetShadowWithColor(context, CGSizeMake(6, -6), 3, shadowColor);
        CGColorRelease(shadowColor);
    }
    if (scene.inLayer)
        CGContextBeginTransparencyLayer(context, NULL);
    CGPoint start = CGPointMake(30, 40), end = CGPointMake(60, 50);
    CGFloat startRadius = 5, endRadius = 40;
    if (scene.concentric)
        start = end = CGPointMake(45, 45);
    if (scene.partial) {
        start = end = CGPointMake(50, 50);
        startRadius = 10;
        endRadius = 30;
    }
    draw(context, gradient, start, startRadius, end, endRadius, scene.partial ? 0 : kBoth);
    if (scene.inLayer)
        CGContextEndTransparencyLayer(context);
    CGGradientRelease(gradient);
}

// Draws the scene with `gSystem` and then the archive's definition into a surface whose radial entry is hooked.
static void checkRoute(Scene scene, const char *name)
{
    int hits[2];
    for (int pass = 0; pass < 2; pass++) {
        Target surface = createTarget(true, kSide, kSide, gSRGB);
        hookRadialEntry(surface.context);
        gRadialHits = 0;
        drawScene(surface.context, scene, pass ? CGContextDrawRadialGradient : gSystem);
        hits[pass] = gRadialHits;
        CGContextFlush(surface.context);
        releaseTarget(&surface);
    }
    char what[200];
    snprintf(what, sizeof(what), "%s: QuartzCore's radial entry taken %d times by 10.9's draw, %d by the archive's", name, hits[0], hits[1]);
    check(hits[0] > 0 && !hits[1], what);
}

// The archive's draw into a surface against `baseline` (gSystem into a surface when `baselineIsSurface`, or into a
// bitmap), within `inset` of the clip.
static void checkScene(Scene scene, const char *name, bool baselineIsSurface, double inset, int tolerance)
{
    Target surface = createTarget(true, kSide, kSide, gSRGB), baseline = createTarget(baselineIsSurface, kSide, kSide, gSRGB);
    drawScene(surface.context, scene, CGContextDrawRadialGradient);
    drawScene(baseline.context, scene, gSystem);
    readTarget(&surface);
    readTarget(&baseline);
    int largest = largestDifference(&surface, &baseline, sceneTransform(), inset);
    char what[200];
    snprintf(what, sizeof(what), "%s: within %d of 10.9's %s draw (largest %d)", name, tolerance, baselineIsSurface ? "surface" : "bitmap", largest);
    check(largest <= tolerance, what);
    releaseTarget(&surface);
    releaseTarget(&baseline);
}

static const struct { CGBlendMode mode; const char *name; } kDestructiveModes[] = {
    { kCGBlendModeClear, "clear" }, { kCGBlendModeCopy, "copy" }, { kCGBlendModeSourceIn, "source-in" }, { kCGBlendModeSourceOut, "source-out" },
    { kCGBlendModeDestinationIn, "destination-in" }, { kCGBlendModeDestinationAtop, "destination-atop" }, { kCGBlendModePlusDarker, "plus-darker" },
};
enum { kDestructiveModeCount = sizeof(kDestructiveModes) / sizeof(kDestructiveModes[0]), kStyledTolerance = 0 };

static bool gAsyncDrawn;
static int gAsyncHits[2];
static CGGradientRef gHardStop, gMask;
static const CGPoint kHardCenter = { 60, 40 };
enum { kLayerWidth = 200, kLayerHeight = 150, kHardRadius = 50 };

@interface ProbeDelegate : NSObject <CALayerDelegate>
@end
@implementation ProbeDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    hookRadialEntry(context);
    gRadialHits = 0;
    gSystem(context, gHardStop, kHardCenter, 0, kHardCenter, 2 * kHardRadius, kBoth);
    gAsyncHits[0] = gRadialHits;
    gRadialHits = 0;
    CGContextDrawRadialGradient(context, gHardStop, kHardCenter, 0, kHardCenter, 2 * kHardRadius, kBoth);
    gAsyncHits[1] = gRadialHits;
    gAsyncDrawn = true;
}
@end

int main(void)
{
    @autoreleasepool {
        gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        gLinear = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceLinearSRGB"));
        gSystem = (DrawRadialFn)systemSymbol("_CGContextDrawRadialGradient");
        if (!gSystem || !gSRGB || !gLinear)
            return 1;
        const CGFloat maskComponents[] = { 0, 0, 0, 0, 1, 1, 1, 1 };
        gMask = CGGradientCreateWithColorComponents(gSRGB, maskComponents, NULL, 2);
        const CGFloat rampComponents[] = { 1, 0, 0, 1, 0, 0, 1, 0.5 };
        CGGradientRef gRamp2 = CGGradientCreateWithColorComponents(gSRGB, rampComponents, NULL, 2);
        DrawLinearFn systemLinear = (DrawLinearFn)systemSymbol("_CGContextDrawLinearGradient");

        {
            enum { kWidth = 400, kHeight = 704 };
            Target surface = createTarget(true, kWidth, kHeight, gSRGB), bitmap = createTarget(false, kWidth, kHeight, gSRGB);
            for (int pass = 0; pass < 2; pass++) {
                CGContextRef context = pass ? bitmap.context : surface.context;
                CGContextTranslateCTM(context, 0, kHeight);
                CGContextScaleCTM(context, 1, -1);
                CGContextClipToRect(context, CGRectMake(0, 0, kWidth, kHeight));
                (pass ? gSystem : CGContextDrawRadialGradient)(context, gMask, CGPointMake(-10, -10), 0, CGPointMake(-10, -10), 1, kBoth);
            }
            readTarget(&surface);
            readTarget(&bitmap);
            int notWhite = 0;
            for (size_t i = 0; i < kWidth * kHeight; i++)
                notWhite += *(const uint32_t *)(const void *)(surface.pixels + i * 4) != 0xffffffff;
            printf("    mask: %d of %d surface pixels not opaque white\n", notWhite, kWidth * kHeight);
            check(!notWhite, "400x704 IOSurface mask, 1px circle at (-10, -10): opaque white throughout");
            check(!memcmp(surface.pixels, bitmap.pixels, kWidth * kHeight * 4), "the mask is byte-identical to 10.9's draw into a bitmap");
            releaseTarget(&surface);
            releaseTarget(&bitmap);

            Target hooked = createTarget(true, kWidth, kHeight, gSRGB);
            hookRadialEntry(hooked.context);
            gRadialHits = 0;
            gSystem(hooked.context, gMask, CGPointMake(-10, -10), 0, CGPointMake(-10, -10), 1, kBoth);
            int stockHits = gRadialHits;
            gRadialHits = 0;
            CGContextDrawRadialGradient(hooked.context, gMask, CGPointMake(-10, -10), 0, CGPointMake(-10, -10), 1, kBoth);
            check(stockHits > 0 && !gRadialHits, "the mask does not reach QuartzCore's radial entry; 10.9's draw does");
            CGContextFlush(hooked.context);
            releaseTarget(&hooked);
        }

        {
            // Native linear gradients take delegate slot 21. One extended both ways stays there, where a GPU draws it
            // correctly; another extension takes the bands.
            static const struct { CGGradientDrawingOptions options; const char *name; int nativeHits; } linears[] = {
                { kBoth, "both extensions", 1 }, { 0, "no extension", 0 },
                { kCGGradientDrawsBeforeStartLocation, "before start", 0 }, { kCGGradientDrawsAfterEndLocation, "after end", 0 },
            };
            for (size_t i = 0; i < sizeof(linears) / sizeof(linears[0]); i++) {
                Target hooked = createTarget(true, kSide, kSide, gSRGB);
                CGContextDelegateSetCallback(CGContextGetDelegate(hooked.context), 21, (void (*)(void))countRadialHit);
                gRadialHits = 0;
                CGContextDrawLinearGradient(hooked.context, gMask, CGPointMake(30, 0), CGPointMake(90, 0), linears[i].options);
                char what[120];
                snprintf(what, sizeof(what), "linear, %s: QuartzCore's linear entry taken %d times", linears[i].name, gRadialHits);
                check(gRadialHits == linears[i].nativeHits, what);
                CGContextFlush(hooked.context);
                releaseTarget(&hooked);

                Target surface = createTarget(true, kSide, kSide, gSRGB), bitmap = createTarget(false, kSide, kSide, gSRGB);
                for (int pass = 0; pass < 2; pass++) {
                    CGContextRef c = pass ? bitmap.context : surface.context;
                    CGContextSetRGBFillColor(c, 1, 0, 1, 1);
                    CGContextFillRect(c, CGRectMake(0, 0, kSide, kSide));
                    CGContextSetBlendMode(c, kCGBlendModeMultiply);
                    (pass ? systemLinear : CGContextDrawLinearGradient)(c, gRamp2, CGPointMake(30, 0), CGPointMake(90, 0), linears[i].options);
                }
                readTarget(&surface);
                readTarget(&bitmap);
                int largest = largestDifference(&surface, &bitmap, CGAffineTransformIdentity, 0);
                snprintf(what, sizeof(what), "linear, %s, multiply: within 5 of 10.9's bitmap draw (largest %d)", linears[i].name, largest);
                check(largest <= 5, what);
                releaseTarget(&surface);
                releaseTarget(&bitmap);
            }
        }

        static const struct { const char *name; Scene scene; } scenes[] = {
            { "rotated, scaled, elliptical clip", { false, false, false, false, kCGBlendModeNormal, 0, NULL } },
            { "multiply under global alpha 0.6", { false, false, false, false, kCGBlendModeMultiply, 0.6, NULL } },
            { "shadow", { false, false, true, false, kCGBlendModeNormal, 0, NULL } },
            { "transparency layer under global alpha 0.6", { false, false, false, true, kCGBlendModeNormal, 0.6, NULL } },
        };
        for (size_t i = 0; i < sizeof(scenes) / sizeof(scenes[0]); i++) {
            for (int concentric = 0; concentric < 2; concentric++) {
                Scene scene = scenes[i].scene;
                scene.concentric = concentric;
                char name[120];
                snprintf(name, sizeof(name), "%s, %s", scenes[i].name, concentric ? "concentric" : "offset");
                checkRoute(scene, name);
                checkScene(scene, name, false, 0.9, 2);
            }
        }
        for (int concentric = 0; concentric < 2; concentric++) {
            Scene scene = { concentric, false, false, false, kCGBlendModeNormal, 0, gLinear };
            char name[120];
            snprintf(name, sizeof(name), "linear-sRGB gradient, %s", concentric ? "concentric" : "offset");
            checkRoute(scene, name);
            checkScene(scene, name, false, 0.9, 2);
        }

        for (size_t i = 0; i < kDestructiveModeCount; i++) {
            char name[120];
            snprintf(name, sizeof(name), "%s, partial coverage, surface", kDestructiveModes[i].name);
            Scene partial = { true, true, false, false, kDestructiveModes[i].mode, 0, NULL };
            checkRoute(partial, name);
            checkScene(partial, name, false, 0, 2);

            // An 8-bit bitmap of another colour space takes the same route.
            Target ours = createTarget(false, kSide, kSide, gSRGB), stock = createTarget(false, kSide, kSide, gSRGB);
            Scene other = partial;
            other.gradientSpace = gLinear;
            drawScene(ours.context, other, CGContextDrawRadialGradient);
            drawScene(stock.context, other, gSystem);
            readTarget(&ours);
            readTarget(&stock);
            int largest = largestDifference(&ours, &stock, sceneTransform(), 0);
            snprintf(name, sizeof(name), "%s, partial coverage, bitmap of another space: within 2 of 10.9 (largest %d)", kDestructiveModes[i].name, largest);
            check(largest <= 2, name);
            releaseTarget(&ours);
            releaseTarget(&stock);

            snprintf(name, sizeof(name), "%s under a shadow, partial coverage", kDestructiveModes[i].name);
            Scene styled = partial;
            styled.shadow = true;
            checkRoute(styled, name);
            if (kDestructiveModes[i].mode == kCGBlendModePlusDarker)
                checkScene(styled, name, false, 0.9, 3);
            else
                checkScene(styled, name, true, 0, kStyledTolerance);
        }

        {
            // Repeated draws leave pixels the gradient does not cover exact: under the software renderer a mask clip
            // would lower them a level per draw.
            enum { kDraws = 64 };
            const CGFloat components[] = { 1, 0, 0, 1, 0, 0, 1, 0.5 };
            CGGradientRef gradient = CGGradientCreateWithColorComponents(gSRGB, components, NULL, 2);
            const CGPoint center = { 60, 60 };
            for (size_t i = 0; i < kDestructiveModeCount; i++) {
                for (int equalRadii = 0; equalRadii < 2; equalRadii++) {
                    Target drawn = createTarget(true, kSide, kSide, gSRGB), untouched = createTarget(true, kSide, kSide, gSRGB);
                    for (int pass = 0; pass < 2; pass++) {
                        CGContextRef context = pass ? untouched.context : drawn.context;
                        CGContextSetRGBFillColor(context, 1, 0, 1, 1);
                        CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
                    }
                    CGContextSetBlendMode(drawn.context, kDestructiveModes[i].mode);
                    for (int draw = 0; draw < kDraws; draw++) {
                        if (equalRadii)
                            CGContextDrawRadialGradient(drawn.context, gradient, center, 30, center, 30, kCGGradientDrawsBeforeStartLocation);
                        else
                            CGContextDrawRadialGradient(drawn.context, gradient, center, 10, center, 30, 0);
                    }
                    readTarget(&drawn);
                    readTarget(&untouched);
                    int changed = 0;
                    for (size_t row = 0; row < kSide; row++) {
                        for (size_t x = 0; x < kSide; x++) {
                            double distance = hypot(x + 0.5 - center.x, kSide - row - 0.5 - center.y);
                            if (distance < 32)
                                continue;
                            changed += memcmp(drawn.pixels + (row * kSide + x) * 4, untouched.pixels + (row * kSide + x) * 4, 4) != 0;
                        }
                    }
                    char what[160];
                    snprintf(what, sizeof(what), "%s, %s, %d draws: %d pixels outside the coverage changed", kDestructiveModes[i].name,
                        equalRadii ? "equal radii" : "partial coverage", kDraws, changed);
                    check(!changed, what);
                    releaseTarget(&drawn);
                    releaseTarget(&untouched);
                }
            }
            CGGradientRelease(gradient);
        }

        {
            // A shadow on a bitmap is 10.9's own draw, in another colour space too.
            static const CGBlendMode modes[] = { kCGBlendModeNormal, kCGBlendModeSaturation, kCGBlendModeColorDodge, kCGBlendModeCopy };
            bool same = true;
            for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
                Target ours = createTarget(false, kSide, kSide, gSRGB), stock = createTarget(false, kSide, kSide, gSRGB);
                Scene scene = { true, false, true, false, modes[i], 0, gLinear };
                drawScene(ours.context, scene, CGContextDrawRadialGradient);
                drawScene(stock.context, scene, gSystem);
                readTarget(&ours);
                readTarget(&stock);
                same &= !memcmp(ours.pixels, stock.pixels, kSide * kSide * 4);
                releaseTarget(&ours);
                releaseTarget(&stock);
            }
            check(same, "a bitmap of another colour space under a shadow: byte-identical to 10.9's draw");
        }

        {
            // More than 1 << 20 pixels: more than one band.
            enum { kWidth = 1400, kHeight = 1000 };
            const CGFloat components[] = { 1, 0, 0, 1, 0, 0, 1, 0.5 };
            CGGradientRef gradient = CGGradientCreateWithColorComponents(gSRGB, components, NULL, 2);
            CGColorRef shadowColor = CGColorCreateGenericRGB(0, 0, 0, 0.8);
            static const struct { const char *what; bool shadow; bool copy; } cases[] = {
                { "several bands", false, false }, { "several bands under a shadow", true, false },
                { "several bands, copy blend, partial coverage", false, true },
            };
            for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
                Target surface = createTarget(true, kWidth, kHeight, gSRGB), bitmap = createTarget(false, kWidth, kHeight, gSRGB);
                for (int pass = 0; pass < 2; pass++) {
                    CGContextRef context = pass ? bitmap.context : surface.context;
                    CGContextSetRGBFillColor(context, 1, 0, 1, 1);
                    CGContextFillRect(context, CGRectMake(0, 0, kWidth, kHeight));
                    if (cases[i].shadow)
                        CGContextSetShadowWithColor(context, CGSizeMake(6, -6), 3, shadowColor);
                    if (cases[i].copy)
                        CGContextSetBlendMode(context, kCGBlendModeCopy);
                    (pass ? gSystem : CGContextDrawRadialGradient)(context, gradient, CGPointMake(300, 200), cases[i].copy ? 100 : 0, CGPointMake(300, 200),
                        900, cases[i].copy ? 0 : kBoth);
                }
                readTarget(&surface);
                readTarget(&bitmap);
                int largest = largestDifference(&surface, &bitmap, CGAffineTransformIdentity, 0);
                char what[160];
                snprintf(what, sizeof(what), "%s: within 2 of 10.9's bitmap draw (largest %d)", cases[i].what, largest);
                check(largest <= 2, what);
                releaseTarget(&surface);
                releaseTarget(&bitmap);
            }
            CGColorRelease(shadowColor);
            CGGradientRelease(gradient);
        }

        {
            // 10.9 paints neither a gradient nor an image of any layout into a gray surface: the route is what holds.
            enum { kWidth = 64, kHeight = 64 };
            CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
            const CGFloat ramp[] = { 0, 0, 0, 1, 1, 1, 1, 1 };
            CGGradientRef gradient = CGGradientCreateWithColorComponents(gSRGB, ramp, NULL, 2);
            int hits[2];
            for (int pass = 0; pass < 2; pass++) {
                IOSurfaceRef surface = createSurface(kWidth, kHeight, 1, 'L008');
                CGContextRef context = CGIOSurfaceContextCreate(surface, kWidth, kHeight, 8, 8, gray, (CGBitmapInfo)kCGImageAlphaNone);
                hookRadialEntry(context);
                gRadialHits = 0;
                (pass ? CGContextDrawRadialGradient : gSystem)(context, gradient, CGPointMake(20, 30), 0, CGPointMake(20, 30), 40, kBoth);
                hits[pass] = gRadialHits;
                CGContextFlush(context);
                CGContextRelease(context);
                CFRelease(surface);
            }
            char what[160];
            snprintf(what, sizeof(what), "gray L008 surface: entry taken %d by 10.9's draw, %d by the archive's", hits[0], hits[1]);
            check(hits[0] > 0 && !hits[1], what);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(gray);
        }

        {
            // A gray gradient into a BGRA surface.
            CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
            const CGFloat ramp[] = { 0, 1, 1, 0.5 };
            CGGradientRef gradient = CGGradientCreateWithColorComponents(gray, ramp, NULL, 2);
            Target surface = createTarget(true, kSide, kSide, gSRGB), bitmap = createTarget(false, kSide, kSide, gSRGB);
            CGContextDrawRadialGradient(surface.context, gradient, CGPointMake(40, 50), 0, CGPointMake(40, 50), 50, kBoth);
            gSystem(bitmap.context, gradient, CGPointMake(40, 50), 0, CGPointMake(40, 50), 50, kBoth);
            readTarget(&surface);
            readTarget(&bitmap);
            int largest = largestDifference(&surface, &bitmap, CGAffineTransformIdentity, 0);
            char what[160];
            snprintf(what, sizeof(what), "gray gradient in a BGRA surface: within 2 of 10.9's bitmap draw (largest %d)", largest);
            check(largest <= 2, what);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(gray);
            releaseTarget(&surface);
            releaseTarget(&bitmap);
        }

        {
            Target surface = createTarget(true, kSide, kSide, gSRGB);
            CGContextSaveGState(surface.context);
            hookRadialEntry(surface.context);
            gRadialHits = 0;
            CGContextScaleCTM(surface.context, 0, 1);
            CGContextDrawRadialGradient(surface.context, gMask, CGPointMake(10, 10), 0, CGPointMake(10, 10), 5, kBoth);
            CGContextRestoreGState(surface.context);
            int hits = gRadialHits;
            readTarget(&surface);
            int painted = 0;
            for (size_t i = 0; i < kSide * kSide * 4; i++)
                painted += surface.pixels[i] != 0;
            check(!hits && !painted, "a singular CTM paints nothing and takes no radial entry");
            releaseTarget(&surface);
        }

        // Red within kHardRadius of the off-centre point, blue beyond it.
        const CGFloat hardComponents[] = { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1 };
        const CGFloat hardLocations[] = { 0, 0.5, 0.5, 1 };
        gHardStop = CGGradientCreateWithColorComponents(gSRGB, hardComponents, hardLocations, 4);
        [NSApplication sharedApplication];
        static const CGFloat contentsScales[] = { 1, 2 };
        for (size_t i = 0; i < sizeof(contentsScales) / sizeof(contentsScales[0]); i++) {
            gAsyncDrawn = false;
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kLayerWidth, kLayerHeight)
                styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
            [window setColorSpace:[NSColorSpace sRGBColorSpace]];
            NSView *view = [window contentView];
            [view setWantsLayer:YES];
            ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
            CALayer *layer = [CALayer layer];
            layer.drawsAsynchronously = YES;
            layer.contentsScale = contentsScales[i];
            layer.frame = CGRectMake(0, 0, kLayerWidth, kLayerHeight);
            layer.delegate = delegate;
            [view.layer addSublayer:layer];
            [layer setNeedsDisplay];
            [window orderFront:nil];
            [CATransaction flush];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            CGImageRef shot = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber],
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
            int wrong = -1;
            if (shot && CGImageGetWidth(shot) == kLayerWidth && CGImageGetHeight(shot) == kLayerHeight) {
                CGContextRef bitmap = CGBitmapContextCreate(NULL, kLayerWidth, kLayerHeight, 8, kLayerWidth * 4, gSRGB, kBGRA);
                CGContextDrawImage(bitmap, CGRectMake(0, 0, kLayerWidth, kLayerHeight), shot);
                const unsigned char *pixels = CGBitmapContextGetData(bitmap);
                wrong = 0;
                for (size_t row = 0; row < kLayerHeight; row++) {
                    for (size_t x = 0; x < kLayerWidth; x++) {
                        double distance = hypot(x + 0.5 - kHardCenter.x, kLayerHeight - row - 0.5 - kHardCenter.y);
                        if (fabs(distance - kHardRadius) < 2)
                            continue;
                        const unsigned char *pixel = pixels + (row * kLayerWidth + x) * 4;
                        wrong += (distance < kHardRadius ? pixel[2] < 245 || pixel[0] > 10 : pixel[0] < 245 || pixel[2] > 10) || pixel[1] > 10;
                    }
                }
                CGContextRelease(bitmap);
            }
            if (shot)
                CGImageRelease(shot);
            char what[200];
            snprintf(what, sizeof(what), "asynchronously drawn layer at contents scale %g: %d pixels out of place, entry taken %d by 10.9's draw, %d by the archive's",
                contentsScales[i], wrong, gAsyncHits[0], gAsyncHits[1]);
            check(gAsyncDrawn && !wrong && gAsyncHits[0] > 0 && !gAsyncHits[1], what);
            [window orderOut:nil];
        }
        CGGradientRelease(gHardStop);

        CGGradientRelease(gMask);
        CGColorSpaceRelease(gLinear);
        CGColorSpaceRelease(gSRGB);
    }
    return failures ? 1 : 0;
}
