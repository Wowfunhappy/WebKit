// CoreGraphics: entry points and constants modern WebKit references that 10.9's CoreGraphics does not
// export, or exports with behaviour that has to be replaced.
#include "wk_polyfill.h"
#include "wk_helpers.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <objc/objc.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceGenericXYZ, CFSTR("kCGColorSpaceGenericXYZ"));
// kCGColorSpaceExtendedRange (SDK-declared, macOS 10.12+; ABSENT on the 10.9 runtime CoreGraphics).
// WebKit2's CoreIPCCGColorSpace::toCF() references it (upstream, in the extended-range-ICC deserialize
// branch). It is a DATA constant, which does NOT auto-weak-link, so a bare reference makes WebKit2
// fail to load on 10.9 (dyld: Symbol not found: _kCGColorSpaceExtendedRange). Define it here so the
// reference binds to the polyfill. The value is immaterial: that branch is DEAD on 10.9 (the serialize
// side never emits an extended-range derivative — CopyPropertyList returns CFData/NULL, never a dict).
// The sibling keys (kCGColorSpaceICCData/kCGIndexed* etc.) are NOT here — upstream defines those
// `static` in CoreIPCCGColorSpace.h, so they carry no dyld reference.
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRange, CFSTR("kCGColorSpaceExtendedRange"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGGradientInterpolatesPremultiplied, CFSTR("kCGGradientInterpolatesPremultiplied"));

#pragma mark - CGColorSpace name constants (10.11.2+)
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceDisplayP3, CFSTR("kCGColorSpaceDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedSRGB, CFSTR("kCGColorSpaceExtendedSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceLinearSRGB, CFSTR("kCGColorSpaceLinearSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedLinearSRGB, CFSTR("kCGColorSpaceExtendedLinearSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedDisplayP3, CFSTR("kCGColorSpaceExtendedDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceLinearDisplayP3, CFSTR("kCGColorSpaceLinearDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedLinearDisplayP3, CFSTR("kCGColorSpaceExtendedLinearDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceITUR_2020, CFSTR("kCGColorSpaceITUR_2020"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedITUR_2020, CFSTR("kCGColorSpaceExtendedITUR_2020"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceROMMRGB, CFSTR("kCGColorSpaceROMMRGB"));

// ---------------------------------------------------------------------------------------------
// Wide-gamut / extended-range colour space names (10.11-10.12+), all ABSENT on 10.9 (probed: only
// kCGColorSpaceSRGB exists; even kCGColorSpaceLinearSRGB is missing, and
// CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceExtendedSRGB")) returns NULL).
//
// Supplying the NAMES alone would be worse than useless: DestinationColorSpace would hold a NULL
// CGColorSpaceRef and trip its own ASSERT. So the names come with a CGColorSpaceCreateWithName that
// knows what to do with them.
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRec2020, CFSTR("kCGColorSpaceExtendedRec2020"));

// CGColorSpaceGetName (10.12+): CGColorSpaceCopyName IS present on 10.9 and recovers the same name
// (verified on-host: sRGB -> "kCGColorSpaceSRGB"). Forward to it and autorelease to match
// CGColorSpaceGetName's +0 "get" ownership.
WK_SYSTEM_FN("CoreGraphics", CFStringRef, CGColorSpaceCopyName, (CGColorSpaceRef));
WK_POLYFILL_ABSENT("CoreGraphics", CFStringRef, CGColorSpaceGetName, (CGColorSpaceRef space))
{
    if (!WK_SYSTEM(CGColorSpaceCopyName))
        return NULL;
    CFStringRef name = WK_SYSTEM(CGColorSpaceCopyName)(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

// CGColorSpaceCreateExtended (10.12+): widens a color space to extended range, letting component
// values fall outside [0,1]. 10.9 CoreGraphics has no extended-range concept at all, so the honest
// answer is the space itself — clamped rather than extended, which is what every pre-10.12 Mac did
// with these colors. Returns +1 to match the Create rule its callers adopt from.
WK_POLYFILL_ABSENT("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateExtended, (CGColorSpaceRef space))
{
    return space ? CGColorSpaceRetain(space) : NULL;
}

// CGIOSurfaceContextCreateImageReference (newer name) == CGIOSurfaceContextCreateImage.
extern CGImageRef CGIOSurfaceContextCreateImage(CGContextRef);
WK_POLYFILL_ABSENT("CoreGraphics", CGImageRef, CGIOSurfaceContextCreateImageReference, (CGContextRef context))
{
    return CGIOSurfaceContextCreateImage(context);
}

// CGPathAddUnevenCornersRoundedRect is macOS 10.13+. It appends a closed rounded-rect subpath whose four
// corners may each have their own radii, in the order [0] bottom-left, [1] bottom-right, [2] top-right,
// [3] top-left, where "top" is the rect's minY edge in the caller's y-down space: PathCG.cpp fills the
// array in exactly that order, and upstream's software equivalent (PathImpl::beziersForRoundedRect)
// applies topLeftRadius at (x, y) and bottomLeftRadius at (x, maxY). Built from four elliptical quadrants
// joined by straight edges, following CGPathAddRoundedRect's own seam: start at the midpoint of the right
// edge and close from the last quadrant's end back to the start, so a path built with it strokes (dash
// phase included) and fills identically. The transform is applied by CoreGraphics to every element, as it
// is for CGPathAddRoundedRect.
#define WK_KAPPA 0.5522847498307933

WK_POLYFILL_ABSENT("CoreGraphics", void, CGPathAddUnevenCornersRoundedRect,
                   (CGMutablePathRef path, const CGAffineTransform *transform, CGRect rect, const CGSize corners[4]))
{
    if (!path || CGRectIsNull(rect) || CGRectIsInfinite(rect))
        return;
    CGFloat minX = CGRectGetMinX(rect), maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect), maxY = CGRectGetMaxY(rect);
    CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);

    CGFloat blw = fmax(corners[0].width, 0), blh = fmax(corners[0].height, 0);
    CGFloat brw = fmax(corners[1].width, 0), brh = fmax(corners[1].height, 0);
    CGFloat trw = fmax(corners[2].width, 0), trh = fmax(corners[2].height, 0);
    CGFloat tlw = fmax(corners[3].width, 0), tlh = fmax(corners[3].height, 0);

    // Two radii sharing an edge cannot together exceed it; scaling all eight by the tightest offending
    // ratio keeps every edge running forwards. CoreGraphics' own rule for the uniform-radius API is
    // stricter -- CGPath.cc asserts 2 * corner <= extent per radius -- so a pair like 0.6w and 0.3w is
    // accepted here and rejected there. Being the more permissive of the two never yields a wrong path.
    CGFloat scale = 1;
    if (blw + brw > w)
        scale = fmin(scale, w / (blw + brw));
    if (tlw + trw > w)
        scale = fmin(scale, w / (tlw + trw));
    if (blh + tlh > h)
        scale = fmin(scale, h / (blh + tlh));
    if (brh + trh > h)
        scale = fmin(scale, h / (brh + trh));
    blw *= scale; blh *= scale;
    brw *= scale; brh *= scale;
    trw *= scale; trh *= scale;
    tlw *= scale; tlh *= scale;

    // With every radius zero CGPathAddRoundedRect degenerates to CGPathAddRect, which starts at the
    // rect's origin rather than the right edge; match that seam too.
    if (!blw && !blh && !brw && !brh && !trw && !trh && !tlw && !tlh) {
        CGPathAddRect(path, transform, rect);
        return;
    }

    CGPathMoveToPoint(path, transform, maxX, minY + h / 2);
    CGPathAddLineToPoint(path, transform, maxX, maxY - brh);
    CGPathAddCurveToPoint(path, transform, maxX, maxY - brh + brh * WK_KAPPA,
        maxX - brw + brw * WK_KAPPA, maxY, maxX - brw, maxY);
    CGPathAddLineToPoint(path, transform, minX + blw, maxY);
    CGPathAddCurveToPoint(path, transform, minX + blw - blw * WK_KAPPA, maxY,
        minX, maxY - blh + blh * WK_KAPPA, minX, maxY - blh);
    CGPathAddLineToPoint(path, transform, minX, minY + tlh);
    CGPathAddCurveToPoint(path, transform, minX, minY + tlh - tlh * WK_KAPPA,
        minX + tlw - tlw * WK_KAPPA, minY, minX + tlw, minY);
    CGPathAddLineToPoint(path, transform, maxX - trw, minY);
    CGPathAddCurveToPoint(path, transform, maxX - trw + trw * WK_KAPPA, minY,
        maxX, minY + trh - trh * WK_KAPPA, maxX, minY + trh);
    CGPathCloseSubpath(path);
}

// CGContextDrawConicGradient is macOS 10.12+; 10.9 CoreGraphics has no conic gradient of any kind. Both are rendered as a fan of angular wedges around the centre, coloured from the
// gradient's own ramp: the ramp is sampled by asking 10.9's own CGContextDrawLinearGradient to paint it
// into a 1xN strip, so colours, interpolation and alpha match every other gradient path exactly.
// Antialiasing is off for the wedge fill so adjacent wedges share edges without seams; the caller's clip
// still antialiases the outer boundary.
#define WK_CONIC_RAMP_SAMPLES 360
#define WK_CONIC_WEDGES 720

static void wk_drawConicFan(CGContextRef context, const uint8_t *ramp, CGPoint center, CGFloat angle)
{
    CGRect clip = CGContextGetClipBoundingBox(context);
    if (CGRectIsNull(clip) || CGRectIsInfinite(clip) || CGRectIsEmpty(clip))
        return;
    CGFloat dx = fmax(fabs(CGRectGetMinX(clip) - center.x), fabs(CGRectGetMaxX(clip) - center.x));
    CGFloat dy = fmax(fabs(CGRectGetMinY(clip) - center.y), fabs(CGRectGetMaxY(clip) - center.y));
    CGFloat radius = hypot(dx, dy) + 2;
    const CGFloat twoPi = 6.283185307179586;

    CGContextSaveGState(context);
    CGContextSetShouldAntialias(context, false);
    for (int i = 0; i < WK_CONIC_WEDGES; ++i) {
        CGFloat t = (i + 0.5) / WK_CONIC_WEDGES;
        int idx = (int)(t * WK_CONIC_RAMP_SAMPLES);
        if (idx < 0)
            idx = 0;
        else if (idx >= WK_CONIC_RAMP_SAMPLES)
            idx = WK_CONIC_RAMP_SAMPLES - 1;
        CGFloat a = ramp[idx * 4 + 3] / 255.0;
        CGFloat r = a > 0 ? fmin(1.0, (ramp[idx * 4 + 0] / 255.0) / a) : 0;
        CGFloat g = a > 0 ? fmin(1.0, (ramp[idx * 4 + 1] / 255.0) / a) : 0;
        CGFloat b = a > 0 ? fmin(1.0, (ramp[idx * 4 + 2] / 255.0) / a) : 0;
        CGContextSetRGBFillColor(context, r, g, b, a);
        CGFloat a0 = angle + twoPi * i / WK_CONIC_WEDGES;
        CGFloat a1 = angle + twoPi * (i + 1) / WK_CONIC_WEDGES;
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, center.x, center.y);
        CGContextAddLineToPoint(context, center.x + radius * cos(a0), center.y + radius * sin(a0));
        CGContextAddLineToPoint(context, center.x + radius * cos(a1), center.y + radius * sin(a1));
        CGContextClosePath(context);
        CGContextFillPath(context);
    }
    CGContextRestoreGState(context);
}

WK_POLYFILL_ABSENT("CoreGraphics", void, CGContextDrawConicGradient,
                   (CGContextRef context, CGGradientRef gradient, CGPoint center, CGFloat angle))
{
    if (!context || !gradient)
        return;
    uint8_t ramp[WK_CONIC_RAMP_SAMPLES * 4];
    memset(ramp, 0, sizeof(ramp));
    CGColorSpaceRef deviceRGB = CGColorSpaceCreateDeviceRGB();
    CGContextRef strip = CGBitmapContextCreate(ramp, WK_CONIC_RAMP_SAMPLES, 1, 8, WK_CONIC_RAMP_SAMPLES * 4,
        deviceRGB, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(deviceRGB);
    // A fixed-format 360x1 premultiplied-RGB buffer either allocates or the process is past saving; abort
    // rather than paint nothing, which would be indistinguishable from an empty gradient.
    if (!strip)
        abort();
    CGContextDrawLinearGradient(strip, gradient, CGPointMake(0, 0), CGPointMake(WK_CONIC_RAMP_SAMPLES, 0),
        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRelease(strip);
    wk_drawConicFan(context, ramp, center, angle);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// CGContextDrawPathDirect (10.13+): add the path and draw it (upstream passes a null bounding box).
WK_POLYFILL_ABSENT("CoreGraphics", void, CGContextDrawPathDirect,
    (CGContextRef context, CGPathDrawingMode mode, CGPathRef path, const CGRect *boundingBox))
{
    (void)boundingBox;
    CGContextAddPath(context, path);
    CGContextDrawPath(context, mode);
}

// CGGradientCreateWithColorComponentsAndOptions (10.12+). The only option is
// kCGGradientInterpolatesPremultiplied, and it is not a nicety: CSS requires gradient stops to be
// interpolated with premultiplied alpha, which is what makes `linear-gradient(transparent, #fff)`
// fade cleanly instead of through the transparent black the `transparent` keyword literally means.
// 10.9's CGGradientCreateWithColorComponents interpolates the components as given, so honouring the
// option means reshaping the stop list.
//
// Between two stops, premultiplied interpolation moves the PREMULTIPLIED colour linearly:
//
//     a(t) = lerp(a0, a1, t)                       (alpha is linear either way)
//     c(t) = lerp(c0*a0, c1*a1, t) / a(t)          (unpremultiplied colour, a rational curve)
//
// Unpremultiplied interpolation instead moves c linearly, which for `transparent -> white` walks the
// colour from black to white and shows as a grey smear. Two cases need no work, and they are the
// common ones: if a0 == a1 the two interpolations are identical (a constant factor), and if the
// colours are equal c(t) is constant, which linear interpolation reproduces exactly. Only a segment
// that changes BOTH colour and alpha is resampled: intermediate stops are emitted along it holding
// the exact c(t) above, so 10.9's linear walk between them tracks the true curve. c(t) is a smooth
// monotone Möbius curve, so the residual error falls off as the square of the sample spacing; at the
// spacing below it is far under one 8-bit level. (`transparent -> #fff` is exact even at one sample:
// c(t) collapses to constant white, being (t,t,t)/t.)
static size_t wkGradientPremultipliedSamples(size_t stopCount)
{
    // Keep the rebuilt list bounded for pathological stop counts (CSS permits hundreds of stops);
    // long lists are made of short segments, where fewer samples already track the curve closely.
    if (stopCount <= 64)
        return 32;
    if (stopCount <= 256)
        return 8;
    return 4;
}

WK_POLYFILL_ABSENT("CoreGraphics", CGGradientRef, CGGradientCreateWithColorComponentsAndOptions,
    (CGColorSpaceRef space, const CGFloat *components, const CGFloat *locations, size_t count, CFDictionaryRef options))
{
    bool interpolatesPremultiplied = false;
    if (options) {
        CFTypeRef value = CFDictionaryGetValue(options, kCGGradientInterpolatesPremultiplied);
        interpolatesPremultiplied = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    }

    // Number of colour components per stop, plus the trailing alpha, exactly as
    // CGGradientCreateWithColorComponents reads them.
    size_t colorComponents = space ? CGColorSpaceGetNumberOfComponents(space) : 0;
    size_t stride = colorComponents + 1;

    if (!interpolatesPremultiplied || !components || count < 2 || !colorComponents)
        return CGGradientCreateWithColorComponents(space, components, locations, count);

    // A NULL locations array means evenly spaced stops (CGGradient accepts that, and any caller may
    // rely on it), so synthesize the spacing rather than dropping the premultiplied contract.
    CGFloat *evenLocations = NULL;
    if (!locations) {
        evenLocations = (CGFloat *)malloc(count * sizeof(CGFloat));
        if (!evenLocations)
            return CGGradientCreateWithColorComponents(space, components, NULL, count);
        for (size_t stop = 0; stop < count; stop++)
            evenLocations[stop] = (CGFloat)stop / (CGFloat)(count - 1);
        locations = evenLocations;
    }

    size_t samples = wkGradientPremultipliedSamples(count);
    // Worst case per segment: its start stop, (samples - 1) intermediates, and a second copy of its
    // end stop; plus the trailing stop appended after the loop.
    size_t maxStops = (count - 1) * (samples + 1) + 1;
    CGFloat *newComponents = (CGFloat *)malloc(maxStops * stride * sizeof(CGFloat));
    CGFloat *newLocations = (CGFloat *)malloc(maxStops * sizeof(CGFloat));
    if (!newComponents || !newLocations) {
        free(newComponents);
        free(newLocations);
        CGGradientRef fallback = CGGradientCreateWithColorComponents(space, components, locations, count);
        free(evenLocations);
        return fallback;
    }

    // Emitted per SEGMENT: each segment contributes its start stop (carrying the colour that segment
    // needs) and any intermediates, and the final stop is appended at the end. A stop with alpha 0
    // can end up emitted twice at the same location, once per neighbouring segment, when the two want
    // different colours for it — a zero-width step between two fully transparent colours, i.e.
    // invisible, and the only way to give each side its own exact curve.
    size_t newCount = 0;
    for (size_t segment = 0; segment + 1 < count; segment++) {
        const CGFloat *from = &components[segment * stride];
        const CGFloat *to = &components[(segment + 1) * stride];
        CGFloat alphaFrom = from[colorComponents];
        CGFloat alphaTo = to[colorComponents];

        bool colorChanges = false;
        for (size_t component = 0; component < colorComponents; component++) {
            if (from[component] != to[component]) {
                colorChanges = true;
                break;
            }
        }
        // Nothing to do when the two interpolations agree: equal alpha (a constant factor), an
        // unchanging colour (c(t) constant), or a hard stop where no interpolation happens.
        bool needsResampling = colorChanges && alphaFrom != alphaTo && locations[segment + 1] > locations[segment];

        // A transparent endpoint has no recoverable colour of its own: as t leaves it, c(t) is
        // exactly the opposite endpoint's colour. Writing that colour in makes the whole segment
        // constant-coloured, so it needs no intermediates at all -- the `transparent -> #fff` case.
        const CGFloat *startColor = (needsResampling && alphaFrom == 0) ? to : from;
        const CGFloat *endColor = (needsResampling && alphaTo == 0) ? from : to;
        bool constantColor = needsResampling && (alphaFrom == 0 || alphaTo == 0);

        CGFloat *out = &newComponents[newCount * stride];
        memcpy(out, startColor, colorComponents * sizeof(CGFloat));
        out[colorComponents] = alphaFrom;
        newLocations[newCount] = locations[segment];
        newCount++;

        if (needsResampling && !constantColor) {
            for (size_t sample = 1; sample < samples; sample++) {
                CGFloat t = (CGFloat)sample / (CGFloat)samples;
                CGFloat alpha = alphaFrom + t * (alphaTo - alphaFrom);
                out = &newComponents[newCount * stride];
                for (size_t component = 0; component < colorComponents; component++) {
                    CGFloat premultiplied = from[component] * alphaFrom + t * (to[component] * alphaTo - from[component] * alphaFrom);
                    out[component] = premultiplied / alpha;
                }
                out[colorComponents] = alpha;
                newLocations[newCount] = locations[segment] + t * (locations[segment + 1] - locations[segment]);
                newCount++;
            }
        }

        // Give this segment its own end stop when the next segment would disagree about the colour of
        // the shared stop (only possible around a transparent stop, per above).
        if (endColor != to) {
            out = &newComponents[newCount * stride];
            memcpy(out, endColor, colorComponents * sizeof(CGFloat));
            out[colorComponents] = alphaTo;
            newLocations[newCount] = locations[segment + 1];
            newCount++;
        }
    }
    // The last stop, which no segment emitted as a start stop.
    {
        const CGFloat *last = &components[(count - 1) * stride];
        const CGFloat *previous = &components[(count - 2) * stride];
        CGFloat *out = &newComponents[newCount * stride];
        memcpy(out, last[colorComponents] == 0 ? previous : last, colorComponents * sizeof(CGFloat));
        out[colorComponents] = last[colorComponents];
        newLocations[newCount] = locations[count - 1];
        newCount++;
    }

    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, newComponents, newLocations, newCount);
    free(newComponents);
    free(newLocations);
    free(evenLocations);
    return gradient;
}

#pragma clang diagnostic pop

// Absent on 10.9 (modern WebCore calls it constantly from GraphicsContextCG during -drawRect:).
// The obvious forward — CGBitmapContextGetColorSpace() — is WRONG: on any non-bitmap context (the
// IOSurface-backed layer/drawRect contexts of compositing views, window contexts, …) it doesn't just
// return null, it first emits "CGBitmapContextGetColorSpace: invalid context 0x… This is a serious
// error…" to the console. WebKit drawing hits that on every paint, producing thousands of log lines
// (visible in Safari's WebContent and DashboardClient). CGContextCopyDeviceColorSpace() returns the
// context's colorspace for EVERY context kind silently (for a genuine bitmap context it returns that
// bitmap's colorspace, matching CGBitmapContextGetColorSpace). It returns +1 (a Copy), so autorelease
// to match CGContextGetColorSpace()'s +0 "get" ownership — the caller stores the result in a RetainPtr.
// CGContextCopyDeviceColorSpace exists in 10.9's CoreGraphics but the modern SDK we build against
// dropped its header declaration, so forward-declare it.
extern CGColorSpaceRef CGContextCopyDeviceColorSpace(CGContextRef);
WK_POLYFILL_ABSENT("CoreGraphics", CGColorSpaceRef, CGContextGetColorSpace, (CGContextRef context))
{
    CGColorSpaceRef colorSpace = CGContextCopyDeviceColorSpace(context);
    return colorSpace ? (CGColorSpaceRef)CFAutorelease(colorSpace) : NULL;
}

// Lockdown Mode for PDF (macOS 13+). No Lockdown Mode on 10.9.
WK_POLYFILL_ABSENT("CoreGraphics", void, CGEnterLockdownModeForPDF, (void))
{
}

// Wide-gamut / extended-range / HDR transfer-function color-space predicates (10.12+/10.14+). 10.9 is
// sRGB-only with no extended range or ITU-R BT.2100 transfer function: report false for all.
WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceIsWideGamutRGB, (CGColorSpaceRef space))
{
    (void)space;
    return false;
}

WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceUsesExtendedRange, (CGColorSpaceRef space))
{
    (void)space;
    return false;
}

WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceUsesITUR_2100TF, (CGColorSpaceRef space))
{
    (void)space;
    return false;
}

// CGColorCreateSRGB (10.15+) — build the color through the named sRGB color space (available since 10.5).
WK_POLYFILL_ABSENT("CoreGraphics", CGColorRef, CGColorCreateSRGB, (CGFloat r, CGFloat g, CGFloat b, CGFloat a)) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef color = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return color;
}

// CGContextDelegateSetCallback — a DELIBERATE REPLACEMENT of a present 10.9 function. Its delegate
// carries callback slots 0 through 23; its get_callback_address CGPostError()s and abort()s on any
// higher name. Names above that ceiling are ones this CoreGraphics has no slot for, so the delegate
// keeps its own behaviour for them (DrawGlyphsRecorder's deGetColorSpace = 30 leaves CG using the
// context's own colour space). Every name 10.9 does carry reaches its implementation unchanged.
WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDelegateSetCallback,
                     (void *delegate, int name, void (*callback)(void)))
{
    if (name > 23)
        return;
    if (WK_ORIGINAL(CGContextDelegateSetCallback))
        WK_ORIGINAL(CGContextDelegateSetCallback)(delegate, name, callback);
}

// CGContextSetOwnerIdentity (12+): tags a context's backing store to another process's memory
// ledger, using a task identity token. 10.9 has neither -- see task_create_identity_token in
// libSystem.m -- so there is no ledger to move the pages to and no token that could name one. The
// faithful answer on this OS is that the pages stay attributed to the process that allocated them,
// which is what doing nothing means here. Unreachable in practice for the same reason the token is:
// every caller gates on a valid ProcessIdentity, which 10.9 never produces. WebCore soft-links this
// one (PAL/pal/cg/CoreGraphicsSoftLink.cpp) with the required form, so without an entry here the
// lookup would RELEASE_ASSERT rather than reach any of that.
WK_POLYFILL_ABSENT("CoreGraphics", void, CGContextSetOwnerIdentity, (CGContextRef context, unsigned int owner))
{
    (void)context;
    (void)owner;
}

// VTIsHardwareDecodeSupported lives in polyfills/shared/videotoolbox.c: GStreamer's applemedia
// plugin calls it too, so the deps builds compile the same source into their gap archive.

// CGColorSpaceCreateWithName IS present on 10.9 and works for the names 10.9 knows; it returns NULL for
// the ones above. REPLACES rather than ABSENT for exactly that reason: the real function is asked first
// and its answer is returned untouched, so every colour space 10.9 understands behaves identically. Only a
// NULL answer for one of the names 10.9 lacks is substituted.
//
// The substitute depends on the name's TRANSFER FUNCTION, which is the part of these spaces 10.9 can
// still represent exactly even though it has no wide-gamut or extended-range display path.
//
// GAMUT is genuinely unavailable: there is no display path here that could show a colour outside sRGB,
// so Display P3, Rec. 2020, ProPhoto RGB and the extended-range variants all resolve to sRGB. Colours
// outside the sRGB gamut clamp, which is what this hardware does regardless of how they were tagged.
//
// The LINEAR names are different, and getting them wrong is not a gamut approximation but a wrong
// answer. A space named "linear sRGB" whose transfer function is sRGB's ~2.2 gamma misreports every
// value in it: WebCore composites SVG filters in linearRGB by default, so returning a gamma space
// there silently moves filter maths into the wrong domain. 10.9 can express the right thing —
// CGColorSpaceCreateCalibratedRGB takes an explicit gamma, and sRGB's own primaries and D65 white
// point are just numbers. Measured on this host by converting 0.5 into an sRGB bitmap: this space
// yields 187 and WebCore's own Resources/linearSRGB.icc yields 188 (one 1/255 rounding step apart),
// while plain sRGB yields 128, so WebCore's linearRGB filter maths lands in the space it asks for.
//
// EVERY colour-space name this file publishes is answered. Probed on this host, stock CGColorSpaceCreateWithName
// returns NULL for all eleven of them, and a NULL colour space is not a lesser answer but a broken one:
// it fails the caller's ASSERT, leaves CGBitmapContext creation without a colour space, and makes
// distinct absent spaces compare equal to each other.
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef));

// sRGB's primaries and D65 white point with a gamma of 1.0 — i.e. linear sRGB. Built once; the
// returned space is retained per call to match CGColorSpaceCreateWithName's Create semantics.
static CGColorSpaceRef wk_linear_sRGB_storage;
static void wk_build_linear_sRGB(void)
{
    const CGFloat whitePointD65[3] = { 0.9505, 1.0, 1.0890 };
    const CGFloat blackPoint[3] = { 0.0, 0.0, 0.0 };
    const CGFloat gammaLinear[3] = { 1.0, 1.0, 1.0 };
    // Columns are the XYZ coordinates of the sRGB red, green and blue primaries.
    const CGFloat sRGBPrimariesToXYZ[9] = {
        0.4124564, 0.2126729, 0.0193339,
        0.3575761, 0.7151522, 0.1191920,
        0.1804375, 0.0721750, 0.9503041,
    };
    wk_linear_sRGB_storage = CGColorSpaceCreateCalibratedRGB(whitePointD65, blackPoint, gammaLinear, sRGBPrimariesToXYZ);
}

static CGColorSpaceRef wk_linear_sRGB_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_linear_sRGB);
    return wk_linear_sRGB_storage;
}

// XYZ-D50. 10.9 has no XYZ colour space, but an RGB space whose primary matrix is the identity IS
// XYZ: the components pass through unchanged. This is the construction upstream's own FIXME in
// ColorSpaceCG.cpp proposes for the missing XYZ space.
static CGColorSpaceRef wk_xyz_D50_storage;
static void wk_build_xyz_D50(void)
{
    const CGFloat whitePointD50[3] = { 0.9642, 1.0, 0.8249 };
    const CGFloat blackPoint[3] = { 0.0, 0.0, 0.0 };
    const CGFloat gammaLinear[3] = { 1.0, 1.0, 1.0 };
    const CGFloat identity[9] = { 1.0, 0.0, 0.0,  0.0, 1.0, 0.0,  0.0, 0.0, 1.0 };
    wk_xyz_D50_storage = CGColorSpaceCreateCalibratedRGB(whitePointD50, blackPoint, gammaLinear, identity);
}

static CGColorSpaceRef wk_xyz_D50_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_xyz_D50);
    return wk_xyz_D50_storage;
}

WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef name))
{
    if (!WK_SYSTEM(CGColorSpaceCreateWithName))
        return NULL;

    CGColorSpaceRef space = WK_SYSTEM(CGColorSpaceCreateWithName)(name);
    if (space || !name)
        return space;   // 10.9 knew this name (or there is no name): its answer stands

    // Linear transfer function, sRGB primaries. The extended variants differ from their plain
    // counterparts only in admitting out-of-[0,1] components, which this OS cannot represent.
    static const CFStringRef linear[] = {
        CFSTR("kCGColorSpaceLinearSRGB"), CFSTR("kCGColorSpaceExtendedLinearSRGB"),
        CFSTR("kCGColorSpaceLinearDisplayP3"), CFSTR("kCGColorSpaceExtendedLinearDisplayP3"),
    };
    for (size_t i = 0; i < sizeof(linear) / sizeof(linear[0]); i++) {
        if (CFStringCompare(name, linear[i], 0) == kCFCompareEqualTo) {
            CGColorSpaceRef linearSRGB = wk_linear_sRGB_space();
            return linearSRGB ? CGColorSpaceRetain(linearSRGB) : NULL;
        }
    }

    if (CFStringCompare(name, CFSTR("kCGColorSpaceGenericXYZ"), 0) == kCFCompareEqualTo) {
        CGColorSpaceRef xyz = wk_xyz_D50_space();
        return xyz ? CGColorSpaceRetain(xyz) : NULL;
    }

    // Wider gamut than sRGB, sRGB-like transfer function: representable only as sRGB here.
    static const CFStringRef gamutSubstituted[] = {
        CFSTR("kCGColorSpaceExtendedSRGB"), CFSTR("kCGColorSpaceDisplayP3"),
        CFSTR("kCGColorSpaceExtendedDisplayP3"), CFSTR("kCGColorSpaceITUR_2020"),
        CFSTR("kCGColorSpaceExtendedITUR_2020"), CFSTR("kCGColorSpaceExtendedRec2020"),
        CFSTR("kCGColorSpaceROMMRGB"), CFSTR("kCGColorSpaceExtendedAdobeRGB1998"),
    };
    for (size_t i = 0; i < sizeof(gamutSubstituted) / sizeof(gamutSubstituted[0]); i++) {
        if (CFStringCompare(name, gamutSubstituted[i], 0) == kCFCompareEqualTo)
            return WK_SYSTEM(CGColorSpaceCreateWithName)(kCGColorSpaceSRGB);
    }
    return NULL;   // some other unknown name: 10.9's own answer, unchanged
}

// Transparency-layer bookkeeping shared with CTFontDrawGlyphs in CoreText.c, which converts a glyph
// run painted into a CGPDFContext while a layer is open into outlines. 10.9 offers no way to ask a
// context whether a layer is open (CGContextGetTransparencyLayerDepth and
// CGContextIsInTransparencyLayer are both absent from CoreGraphics here), so the layer entry points
// below carry the count.

struct wk_transparency_layer_entry {
    CGContextRef context;
    unsigned depth;
    struct wk_transparency_layer_entry *next;
};

static pthread_mutex_t wk_transparencyLayerLock = PTHREAD_MUTEX_INITIALIZER;
static struct wk_transparency_layer_entry *wk_transparencyLayerHead;

// The context is retained for as long as an entry exists. Core Graphics requires
// begin and end to balance, but nothing can enforce that a caller does not release a
// context with a layer still open; retaining means the address can never be recycled
// underneath a live entry, so a later context can never inherit a stale "inside a
// layer" answer and have its text silently converted to outlines.
void wk_transparencyLayerBegan(CGContextRef context)
{
    if (!context)
        return;
    pthread_mutex_lock(&wk_transparencyLayerLock);
    struct wk_transparency_layer_entry *entry = wk_transparencyLayerHead;
    while (entry && entry->context != context)
        entry = entry->next;
    if (entry)
        entry->depth++;
    else if ((entry = (struct wk_transparency_layer_entry *)malloc(sizeof(*entry)))) {
        entry->context = CGContextRetain(context);
        entry->depth = 1;
        entry->next = wk_transparencyLayerHead;
        wk_transparencyLayerHead = entry;
    }
    pthread_mutex_unlock(&wk_transparencyLayerLock);
}

void wk_transparencyLayerEnded(CGContextRef context)
{
    if (!context)
        return;
    CGContextRef release = NULL;
    pthread_mutex_lock(&wk_transparencyLayerLock);
    struct wk_transparency_layer_entry **link = &wk_transparencyLayerHead;
    while (*link && (*link)->context != context)
        link = &(*link)->next;
    if (*link && --(*link)->depth == 0) {
        struct wk_transparency_layer_entry *closed = *link;
        *link = closed->next;
        release = closed->context;
        free(closed);
    }
    pthread_mutex_unlock(&wk_transparencyLayerLock);
    if (release)
        CGContextRelease(release);
}

bool wk_isInsideTransparencyLayer(CGContextRef context)
{
    bool inside = false;
    pthread_mutex_lock(&wk_transparencyLayerLock);
    for (struct wk_transparency_layer_entry *entry = wk_transparencyLayerHead; entry; entry = entry->next) {
        if (entry->context == context) {
            inside = true;
            break;
        }
    }
    pthread_mutex_unlock(&wk_transparencyLayerLock);
    return inside;
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextBeginTransparencyLayer, (CGContextRef context, CFDictionaryRef auxiliaryInfo))
{
    wk_transparencyLayerBegan(context);
    if (WK_ORIGINAL(CGContextBeginTransparencyLayer))
        WK_ORIGINAL(CGContextBeginTransparencyLayer)(context, auxiliaryInfo);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextBeginTransparencyLayerWithRect, (CGContextRef context, CGRect rect, CFDictionaryRef auxiliaryInfo))
{
    wk_transparencyLayerBegan(context);
    if (WK_ORIGINAL(CGContextBeginTransparencyLayerWithRect))
        WK_ORIGINAL(CGContextBeginTransparencyLayerWithRect)(context, rect, auxiliaryInfo);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextEndTransparencyLayer, (CGContextRef context))
{
    if (WK_ORIGINAL(CGContextEndTransparencyLayer))
        WK_ORIGINAL(CGContextEndTransparencyLayer)(context);
    wk_transparencyLayerEnded(context);
}

// The display's Metal device, absent from 10.9 CoreGraphics along with Metal itself (see Metal.c). nil
// is the same "this display has no Metal device" answer MTLCreateSystemDefaultDevice gives, and ANGLE's
// GetGPUInformation falls through to its CGL/IOKit path on it.
WK_POLYFILL_ABSENT("CoreGraphics", id, CGDirectDisplayCopyCurrentMetalDevice, (CGDirectDisplayID displayID))
{ (void)displayID; return nil; }
