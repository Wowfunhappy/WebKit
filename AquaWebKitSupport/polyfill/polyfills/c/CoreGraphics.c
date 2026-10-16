// CoreGraphics: entry points and constants modern WebKit references that 10.9's CoreGraphics does not
// export, or exports with behaviour that has to be replaced.
#include "wk_polyfill.h"
#include "wk_icc.h"
#include "wk_helpers.h"
#include "wk_coregraphics.h"

#include <stdatomic.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <objc/objc.h>
#include <objc/objc-sync.h>
#include <objc/runtime.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceGenericXYZ, CFSTR("kCGColorSpaceGenericXYZ"));
// Display P3 primaries with the SMPTE ST 2084 transfer function.
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceDisplayP3_PQ, CFSTR("kCGColorSpaceDisplayP3_PQ"));
// Extended ICC property lists carry the range independently of the profile's primaries and transfer.
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

// A space CGColorSpaceCreateWithName synthesizes below is built from ICC data, which 10.9 leaves unnamed;
// it carries the name it was created under. 10.9's CGColorSpaceCopyName names the spaces 10.9 knows.
static const void *wk_colorSpaceNameKey(void)
{
    return (const void *)sel_registerName("wk_colorSpaceName");
}

static CFStringRef wk_colorSpaceName(CGColorSpaceRef space)
{
    return space ? (CFStringRef)objc_getAssociatedObject((id)space, wk_colorSpaceNameKey()) : NULL;
}

static CGColorSpaceRef wk_nameColorSpace(CGColorSpaceRef space, CFStringRef name)
{
    if (space)
        objc_setAssociatedObject((id)space, wk_colorSpaceNameKey(), (id)name, OBJC_ASSOCIATION_COPY);
    return space;
}

WK_POLYFILL_REPLACES("CoreGraphics", CFStringRef, CGColorSpaceCopyName, (CGColorSpaceRef space))
{
    CFStringRef name = wk_colorSpaceName(space);
    return name ? CFRetain(name) : WK_ORIGINAL(CGColorSpaceCopyName)(space);
}

// CGColorSpaceGetName (10.12+) is CGColorSpaceCopyName with +0 "get" ownership.
WK_POLYFILL_ABSENT("CoreGraphics", CFStringRef, CGColorSpaceGetName, (CGColorSpaceRef space))
{
    CFStringRef name = CGColorSpaceCopyName(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

static const void *wk_extendedColorSpaceKey(void)
{
    return (const void *)sel_registerName("wk_extendedColorSpace");
}

static bool wk_colorSpaceUsesExtendedRange(CGColorSpaceRef space)
{
    return space && objc_getAssociatedObject((id)space, wk_extendedColorSpaceKey()) != nil;
}

// Quartz preserves out-of-range components in float bitmaps. An independent ICC wrapper carries
// the storage-range contract while retaining the native profile's color matching.
static CGColorSpaceRef wk_createExtendedColorSpace(CGColorSpaceRef space)
{
    if (!space || wk_colorSpaceUsesExtendedRange(space))
        return space ? CGColorSpaceRetain(space) : NULL;
    CFDataRef profile = CGColorSpaceCopyICCProfile(space);
    if (!profile)
        return NULL;
    CGColorSpaceRef result = CGColorSpaceCreateWithICCProfile(profile);
    CFRelease(profile);
    if (result)
        objc_setAssociatedObject((id)result, wk_extendedColorSpaceKey(), (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

WK_POLYFILL_ABSENT("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateExtended, (CGColorSpaceRef space))
{
    return wk_createExtendedColorSpace(space);
}

WK_POLYFILL_REPLACES("CoreGraphics", bool, CGColorSpaceEqualToColorSpace, (CGColorSpaceRef first, CGColorSpaceRef second))
{
    return wk_colorSpaceUsesExtendedRange(first) == wk_colorSpaceUsesExtendedRange(second)
        && WK_ORIGINAL(CGColorSpaceEqualToColorSpace)(first, second);
}

// An ICC-based space's property list is its profile data.
WK_POLYFILL_REPLACES("CoreGraphics", CFPropertyListRef, CGColorSpaceCopyPropertyList, (CGColorSpaceRef space))
{
    // A named space's property list is its name.
    CFStringRef name = wk_colorSpaceName(space);
    if (name)
        return CFRetain(name);
    if (!wk_colorSpaceUsesExtendedRange(space)) {
        CFDataRef original = wk_iccOriginalProfile(space);
        return original ? CFRetain(original) : WK_ORIGINAL(CGColorSpaceCopyPropertyList)(space);
    }
    CFDataRef profile = CGColorSpaceCopyICCProfile(space);
    if (!profile)
        return NULL;
    const void *keys[] = { CFSTR("kCGColorSpaceICCData"), CFSTR("kCGColorSpaceExtendedRange") };
    const void *values[] = { profile, kCFBooleanTrue };
    CFDictionaryRef result = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(profile);
    return result;
}

WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithPropertyList, (CFPropertyListRef propertyList))
{
    if (propertyList && CFGetTypeID(propertyList) == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;
        CFTypeRef extended = CFDictionaryGetValue(dictionary, CFSTR("kCGColorSpaceExtendedRange"));
        CFTypeRef profile = CFDictionaryGetValue(dictionary, CFSTR("kCGColorSpaceICCData"));
        if (extended == kCFBooleanTrue && profile && CFGetTypeID(profile) == CFDataGetTypeID()) {
            CGColorSpaceRef result = CGColorSpaceCreateWithICCProfile((CFDataRef)profile);
            if (result)
                objc_setAssociatedObject((id)result, wk_extendedColorSpaceKey(), (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return result;
        }
    }
    if (propertyList && CFGetTypeID(propertyList) == CFDataGetTypeID())
        return CGColorSpaceCreateWithICCProfile((CFDataRef)propertyList);
    if (propertyList && CFGetTypeID(propertyList) == CFStringGetTypeID())
        return CGColorSpaceCreateWithName((CFStringRef)propertyList);
    return WK_ORIGINAL(CGColorSpaceCreateWithPropertyList)(propertyList);
}

WK_SYSTEM_FN("IOSurface", kern_return_t, IOSurfaceLock, (IOSurfaceRef, uint32_t, uint32_t *));
WK_SYSTEM_FN("IOSurface", kern_return_t, IOSurfaceUnlock, (IOSurfaceRef, uint32_t, uint32_t *));
WK_SYSTEM_FN("IOSurface", void *, IOSurfaceGetBaseAddress, (IOSurfaceRef));
WK_SYSTEM_FN("IOSurface", size_t, IOSurfaceGetAllocSize, (IOSurfaceRef));
WK_SYSTEM_FN("IOSurface", size_t, IOSurfaceGetBytesPerRow, (IOSurfaceRef));

extern IOSurfaceRef CGIOSurfaceContextGetSurface(CGContextRef);
extern CGColorSpaceRef CGIOSurfaceContextGetColorSpace(CGContextRef);
extern size_t CGIOSurfaceContextGetWidth(CGContextRef);
extern size_t CGIOSurfaceContextGetHeight(CGContextRef);
extern size_t CGIOSurfaceContextGetBitsPerComponent(CGContextRef);
extern size_t CGIOSurfaceContextGetBitsPerPixel(CGContextRef);
extern size_t CGIOSurfaceContextGetBitmapInfo(CGContextRef);

static const void *wk_surfaceGetBytePointer(void *info)
{
    IOSurfaceRef surface = info;
    if (WK_SYSTEM(IOSurfaceLock)(surface, kIOSurfaceLockReadOnly, NULL))
        return NULL;
    return WK_SYSTEM(IOSurfaceGetBaseAddress)(surface);
}

static void wk_surfaceReleaseBytePointer(void *info, const void *pointer)
{
    (void)pointer;
    WK_SYSTEM(IOSurfaceUnlock)(info, kIOSurfaceLockReadOnly, NULL);
}

static size_t wk_surfaceGetBytesAtPosition(void *info, void *buffer, off_t position, size_t count)
{
    IOSurfaceRef surface = info;
    size_t length = WK_SYSTEM(IOSurfaceGetAllocSize)(surface);
    if (position < 0 || (size_t)position >= length)
        return 0;
    if (count > length - (size_t)position)
        count = length - (size_t)position;
    if (WK_SYSTEM(IOSurfaceLock)(surface, kIOSurfaceLockReadOnly, NULL))
        return 0;
    memcpy(buffer, (const uint8_t *)WK_SYSTEM(IOSurfaceGetBaseAddress)(surface) + position, count);
    WK_SYSTEM(IOSurfaceUnlock)(surface, kIOSurfaceLockReadOnly, NULL);
    return count;
}

static void wk_surfaceReleaseProvider(void *info)
{
    CFRelease(info);
}

// A direct provider retains the surface and locks it while CoreGraphics reads its pixels.
WK_POLYFILL_ABSENT("CoreGraphics", CGImageRef, CGIOSurfaceContextCreateImageReference, (CGContextRef context))
{
    if (!context)
        return NULL;
    CGContextFlush(context);
    IOSurfaceRef surface = CGIOSurfaceContextGetSurface(context);
    if (!surface)
        return NULL;
    size_t width = CGIOSurfaceContextGetWidth(context);
    size_t height = CGIOSurfaceContextGetHeight(context);
    size_t stride = WK_SYSTEM(IOSurfaceGetBytesPerRow)(surface);
    if (!height || !stride || height > INT64_MAX / stride)
        return NULL;
    const CGDataProviderDirectCallbacks callbacks = {
        0, wk_surfaceGetBytePointer, wk_surfaceReleaseBytePointer,
        wk_surfaceGetBytesAtPosition, wk_surfaceReleaseProvider
    };
    CGDataProviderRef provider = CGDataProviderCreateDirect((void *)CFRetain(surface), (off_t)(height * stride), &callbacks);
    if (!provider) {
        CFRelease(surface);
        return NULL;
    }
    CGImageRef image = CGImageCreate(width, height, CGIOSurfaceContextGetBitsPerComponent(context),
        CGIOSurfaceContextGetBitsPerPixel(context), stride, CGIOSurfaceContextGetColorSpace(context),
        (CGBitmapInfo)CGIOSurfaceContextGetBitmapInfo(context), provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
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

// CGContextDrawConicGradient is macOS 10.12+; 10.9 CoreGraphics has no conic gradient of any kind.
// The gradient is evaluated once per destination pixel, which is what the real API does: the ramp is
// sampled by asking 10.9's own CGContextDrawLinearGradient to paint it into a floating-point 1xN strip of
// the gradient's own colour space (so a space coarser than the destination's loses none of the levels the
// destination keeps, each lands rounded, and an extended-range space's out-of-range components survive), so
// colours, interpolation and alpha match every other gradient path exactly, and each pixel takes the ramp
// entry its angle around the centre falls in. The pixels are an image in that space, which the context
// matches like any other draw. The drawing CTM is set to the identity so the pixel grid is the
// context's own whatever transform the caller had -- a scaled, flipped or rotated context needs no
// special case -- and each sample is mapped back through the caller's transform to the space the centre
// and the angle are stated in. Measured on this host against the geometry of
// fast/canvas/canvas-conic-gradient-angle.html (hard stops on the quadrant boundaries): pixel-identical
// to the same figure drawn as four rectangles, at 1x and at 2x, with the clip at the origin and offset,
// and invariant under a rotated CTM.

// The ramp carries four samples per pixel of arc at the farthest point the clip reaches. One sample per
// pixel makes the colour at a given angle right but leaves a sample boundary up to half a pixel from the
// stop it represents, which a hard stop shows as a stepped edge; four keeps that boundary within an
// eighth of a pixel. Measured against fast/canvas/canvas-conic-gradient-angle's own geometry: one sample
// per pixel is exact at 1x and misplaces 6 pixels at 2x, two per pixel and up are exact at both.
static size_t wk_conicRampSamples(CGContextRef context, CGPoint center)
{
    const double samplesPerRimPixel = 4;
    CGRect clip = CGContextConvertRectToDeviceSpace(context, CGContextGetClipBoundingBox(context));
    CGPoint deviceCenter = CGContextConvertPointToDeviceSpace(context, center);
    CGFloat dx = fmax(fabs(CGRectGetMinX(clip) - deviceCenter.x), fabs(CGRectGetMaxX(clip) - deviceCenter.x));
    CGFloat dy = fmax(fabs(CGRectGetMinY(clip) - deviceCenter.y), fabs(CGRectGetMaxY(clip) - deviceCenter.y));
    double samples = ceil(samplesPerRimPixel * 2 * M_PI * hypot(dx, dy));
    if (!(samples > 4))
        return 4;
    return (size_t)samples;
}

extern CGColorSpaceRef CGGradientGetColorSpace(CGGradientRef);

// The layout a conic gradient's ramp and pixels take in its colour space.
typedef struct {
    CGColorSpaceRef space;
    size_t bitsPerComponent;
    size_t pixelBytes;
    CGBitmapInfo bitmapInfo;
} wk_conic_layout;

static void wk_paintConicGradient(CGContextRef context, const uint8_t *ramp, size_t rampSamples, const wk_conic_layout *layout,
    CGPoint center, CGFloat angle)
{
    const double twoPi = 6.283185307179586;
    CGAffineTransform userFromBase = CGAffineTransformInvert(CGContextGetCTM(context));

    CGContextSaveGState(context);
    CGContextConcatCTM(context, CGAffineTransformInvert(CGContextGetCTM(context)));

    CGRect clip = CGRectIntegral(CGContextGetClipBoundingBox(context));
    size_t columns = (size_t)CGRectGetWidth(clip);
    size_t rows = (size_t)CGRectGetHeight(clip);
    size_t pixelBytes = layout->pixelBytes;
    uint8_t *pixels = (columns && rows) ? (uint8_t *)malloc(columns * rows * pixelBytes) : NULL;
    if (!pixels) {
        CGContextRestoreGState(context);
        return;
    }

    double start = fmod((double)angle, twoPi);
    if (start < 0)
        start += twoPi;
    double scale = rampSamples / twoPi;

    for (size_t row = 0; row < rows; ++row) {
        // CGContextDrawImage lays a bitmap's first row along the destination rect's maxY edge.
        CGPoint first = CGPointApplyAffineTransform(
            CGPointMake(CGRectGetMinX(clip) + 0.5, CGRectGetMaxY(clip) - row - 0.5), userFromBase);
        double x = first.x - center.x;
        double y = first.y - center.y;
        uint8_t *out = pixels + row * columns * pixelBytes;
        for (size_t column = 0; column < columns; ++column, x += userFromBase.a, y += userFromBase.b) {
            double turn = atan2(y, x) - start;
            if (turn < 0)
                turn += twoPi;
            if (turn < 0)
                turn += twoPi;
            size_t index = (size_t)(turn * scale);
            if (index >= rampSamples)
                index = rampSamples - 1;
            memcpy(out + column * pixelBytes, ramp + index * pixelBytes, pixelBytes);
        }
    }

    CGContextRef bitmap = CGBitmapContextCreate(pixels, columns, rows, layout->bitsPerComponent, columns * pixelBytes, layout->space,
        layout->bitmapInfo);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
    if (bitmap)
        CGContextRelease(bitmap);
    if (image) {
        CGContextSetInterpolationQuality(context, kCGInterpolationNone);
        CGContextDrawImage(context, clip, image);
        CGImageRelease(image);
    }
    CGContextRestoreGState(context);
    free(pixels);
}

WK_POLYFILL_ABSENT("CoreGraphics", void, CGContextDrawConicGradient,
                   (CGContextRef context, CGGradientRef gradient, CGPoint center, CGFloat angle))
{
    if (!context || !gradient)
        return;
    CGRect clip = CGContextGetClipBoundingBox(context);
    if (CGRectIsNull(clip) || CGRectIsInfinite(clip) || CGRectIsEmpty(clip))
        return;

    // WebKit's gradients are RGB; a gradient in another model is sampled in extended sRGB, which holds its colours.
    CGColorSpaceRef gradientSpace = CGGradientGetColorSpace(gradient);
    CGColorSpaceRef space = gradientSpace && CGColorSpaceGetModel(gradientSpace) == kCGColorSpaceModelRGB
        ? CGColorSpaceRetain(gradientSpace) : CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    if (!space)
        return;
    wk_conic_layout layout = {
        space,
        32,
        16,
        kCGBitmapFloatComponents | kCGBitmapByteOrder32Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast,
    };

    size_t samples = wk_conicRampSamples(context, center);
    uint8_t *ramp = (uint8_t *)calloc(samples, layout.pixelBytes);
    CGContextRef strip = ramp ? CGBitmapContextCreate(ramp, samples, 1, layout.bitsPerComponent, samples * layout.pixelBytes, space,
        layout.bitmapInfo) : NULL;
    if (strip) {
        CGContextDrawLinearGradient(strip, gradient, CGPointMake(0, 0), CGPointMake(samples, 0),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        CGContextRelease(strip);
        wk_paintConicGradient(context, ramp, samples, &layout, center, angle);
    }
    free(ramp);
    CGColorSpaceRelease(space);
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

// CGContextStrokeLineSegments: drawing into an IOSurface-backed context under a CTM with a rotation or
// skew component, 10.9's implementation strokes the segments at the wrong place or not at all. This is
// the function's documented equivalent, which rasterizes through the general path route on every
// context type.
WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextStrokeLineSegments,
    (CGContextRef context, const CGPoint *points, size_t count))
{
    CGContextBeginPath(context);
    for (size_t i = 0; i + 1 < count; i += 2) {
        CGContextMoveToPoint(context, points[i].x, points[i].y);
        CGContextAddLineToPoint(context, points[i + 1].x, points[i + 1].y);
    }
    CGContextStrokePath(context);
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

// CGContextGetColorSpace (10.11+). IOSurface contexts expose their space through their own accessor;
// CGContextCopyDeviceColorSpace supplies the native bitmap and device-context spaces.
//
// A context built on a CGContextDelegate has no colour space of its own: its colour space is the
// delegate's deGetColorSpace callback's answer, which CGContextDelegateSetCallback below keeps on the
// delegate. The callback is called as CoreGraphics calls a delegate callback, with the delegate, the
// context's rendering state and its top gstate. The key is a selector, so every image's copy of this
// archive reads and writes the same association.
//
// A Core Animation layer that draws asynchronously hands its delegate such a context, built on
// QuartzCore's delegate, whose info is the CA::CG::ContextDelegate that renders the drawing. The colour
// space it renders into, and matches every image to, is the one CA::CG::ContextDelegate::set_colorspace
// keeps at offset 0x20 of that object in 10.9's QuartzCore.
extern CGColorSpaceRef CGContextCopyDeviceColorSpace(CGContextRef);
extern CGColorSpaceRef CGIOSurfaceContextGetColorSpace(CGContextRef);

// CGIOSurfaceContextFlushQueue (10.10+) completes an IOSurface context's queued drawing, which is what
// CGContextFlush does to one on this OS.
WK_POLYFILL_ABSENT("CoreGraphics", void, CGIOSurfaceContextFlushQueue, (CGContextRef context))
{
    if (context)
        CGContextFlush(context);
}
WK_SYSTEM_FN("CoreGraphics", int, CGContextGetType, (CGContextRef));
extern void *CGContextGetDelegate(CGContextRef);
extern void *CGContextDelegateGetInfo(void *);
extern void *CGContextGetRenderingState(CGContextRef);
extern void *CGContextCopyTopGState(CGContextRef);
extern void CGGStateRelease(void *);

typedef CGColorSpaceRef (*wk_delegate_color_space_callback)(void *delegate, void *renderingState, void *gstate);

static CGColorSpaceRef wk_copyContextColorSpace(CGContextRef context)
{
    if (context && WK_SYSTEM(CGContextGetType)(context) == WK_CG_CONTEXT_TYPE_IOSURFACE) {
        CGColorSpaceRef space = CGIOSurfaceContextGetColorSpace(context);
        return space ? CGColorSpaceRetain(space) : NULL;
    }
    return CGContextCopyDeviceColorSpace(context);
}

static const void *wk_delegateColorSpaceCallbackKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_delegateColorSpaceCallback");
    return key;
}

WK_POLYFILL_ABSENT("CoreGraphics", CGColorSpaceRef, CGContextGetColorSpace, (CGContextRef context))
{
    CGColorSpaceRef colorSpace = wk_copyContextColorSpace(context);
    if (colorSpace)
        return (CGColorSpaceRef)CFAutorelease(colorSpace);

    void *delegate = context ? CGContextGetDelegate(context) : NULL;
    if (!delegate)
        return NULL;
    if (wk_drawsThroughCoreAnimationIOSurface(context))
        return *(CGColorSpaceRef *)((char *)CGContextDelegateGetInfo(delegate) + 0x20);
    wk_delegate_color_space_callback callback = (wk_delegate_color_space_callback)(void *)objc_getAssociatedObject((id)delegate, wk_delegateColorSpaceCallbackKey());
    if (!callback)
        return NULL;
    void *gstate = CGContextCopyTopGState(context);
    colorSpace = callback(delegate, CGContextGetRenderingState(context), gstate);
    if (gstate)
        CGGStateRelease(gstate);
    return colorSpace;
}

extern CGImageRef CGImageGetMask(CGImageRef);
extern const void *CGImageGetMaskingColors(CGImageRef);

// A conversion through intermediate bitmaps works in bands of rows of at most this many pixels, which
// bounds the intermediates whatever the size of the whole.
static const size_t wk_conversionBandPixels = (size_t)1 << 20;

static size_t wk_conversionBandRows(size_t width)
{
    size_t rows = width ? wk_conversionBandPixels / width : 1;
    return rows ? rows : 1;
}

// Rows of 16-bit premultiplied RGBA (host order) rounded into rows of 8-bit premultiplied BGRA
// (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little). CoreGraphics' own 16-to-8-bit draw drops
// the low byte.
static void wk_roundRowsTo8Bit(const uint8_t *from, size_t fromRowBytes, uint8_t *to, size_t toRowBytes, size_t width, size_t rows)
{
    static const size_t order[4] = { 2, 1, 0, 3 };
    for (size_t y = 0; y < rows; y++) {
        const uint16_t *source = (const uint16_t *)(const void *)(from + y * fromRowBytes);
        uint8_t *out = to + y * toRowBytes;
        for (size_t x = 0; x < width; x++) {
            for (size_t component = 0; component < 4; component++)
                out[x * 4 + component] = (uint8_t)(((uint32_t)source[x * 4 + order[component]] * 255 + 32767) / 65535);
        }
    }
}

// An image over `context`'s pixels that does not copy them; it is used and released while the context lives.
static CGImageRef wk_createImageOverBitmap(CGContextRef context)
{
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, CGBitmapContextGetData(context),
        CGBitmapContextGetBytesPerRow(context) * CGBitmapContextGetHeight(context), NULL);
    if (!provider)
        return NULL;
    CGImageRef image = CGImageCreate(CGBitmapContextGetWidth(context), CGBitmapContextGetHeight(context),
        CGBitmapContextGetBitsPerComponent(context), CGBitmapContextGetBitsPerPixel(context), CGBitmapContextGetBytesPerRow(context),
        CGBitmapContextGetColorSpace(context), CGBitmapContextGetBitmapInfo(context), provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

static CGContextRef wk_createBitmapWithImage(CGImageRef image, CGColorSpaceRef colorSpace, size_t bitsPerComponent, CGBitmapInfo bitmapInfo)
{
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, bitsPerComponent, 0, colorSpace, bitmapInfo);
    if (!bitmap)
        return NULL;
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationNone);
    CGContextSetRenderingIntent(bitmap, CGImageGetRenderingIntent(image));
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), image);
    return bitmap;
}

// A match between two RGB colour spaces evaluated from ColorSync's parametric description of it
// (kColorSyncTransformParametricConversionData): per-channel parametric curves and 3x4 matrices, in the
// order they apply, on colour unpremultiplied in floating point. Each curve is tabulated at
// wk_curveIntervals + 1 points over [0, 1] and interpolated, and its first interval, where a gamma curve is
// steepest, at wk_curveIntervals + 1 points of its own. A pair ColorSync describes with anything else -- a
// table, a black point compensation -- has no parametric match, and is matched by CoreGraphics' bitmap
// route.
#define WK_COLORSYNC "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ColorSync.framework/ColorSync"
WK_SYSTEM_FN(WK_COLORSYNC, CFTypeRef, ColorSyncProfileCreate, (CFDataRef, CFErrorRef *));
WK_SYSTEM_FN(WK_COLORSYNC, CFTypeRef, ColorSyncTransformCreate, (CFArrayRef, CFDictionaryRef));
WK_SYSTEM_FN(WK_COLORSYNC, CFTypeRef, ColorSyncTransformCopyProperty, (CFTypeRef, CFTypeRef, CFDictionaryRef));
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncProfile);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncRenderingIntent);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncRenderingIntentPerceptual);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncRenderingIntentRelative);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncRenderingIntentSaturation);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncRenderingIntentAbsolute);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncTransformTag);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncTransformDeviceToPCS);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncTransformPCSToDevice);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncTransformParametricConversionData);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionMatrix);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionParamCurve0);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionParamCurve1);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionParamCurve2);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionParamCurve3);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionParamCurve4);
WK_SYSTEM_CONST(WK_COLORSYNC, CFStringRef, kColorSyncConversionChannelID);

enum { wk_curveIntervals = 1024, wk_matchMaxSteps = 8, wk_matchCacheSize = 16 };

typedef struct {
    int type;          // the ICC parametric curve type, 0 to 4
    double g, a, b, c, d, e, f;
} wk_param_curve;

typedef struct {
    bool isMatrix;
    float matrix[3][4];
    wk_param_curve curves[3];
    bool hasCurve[3];
    float *tables[3];
} wk_match_step;

typedef struct {
    CGColorSpaceRef from, to;
    CGColorRenderingIntent intent;
    unsigned references; // the cache's and each caller's, under wk_matchCacheLock
    int stepCount;     // 0: no parametric match
    wk_match_step steps[wk_matchMaxSteps];
} wk_rgb_match;

static double wk_evaluateParamCurve(const wk_param_curve *curve, double x)
{
    switch (curve->type) {
    case 0:
        return pow(x, curve->g);
    case 1:
        return x >= -curve->b / curve->a ? pow(curve->a * x + curve->b, curve->g) : 0;
    case 2:
        return x >= -curve->b / curve->a ? pow(curve->a * x + curve->b, curve->g) + curve->c : curve->c;
    case 3:
        return x >= curve->d ? pow(curve->a * x + curve->b, curve->g) : curve->c * x;
    default:
        return x >= curve->d ? pow(curve->a * x + curve->b, curve->g) + curve->e : curve->c * x + curve->f;
    }
}

static bool wk_readNumbers(CFArrayRef array, double *out, CFIndex count)
{
    if (!array || CFGetTypeID(array) != CFArrayGetTypeID() || CFArrayGetCount(array) < count)
        return false;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef value = CFArrayGetValueAtIndex(array, i);
        if (CFGetTypeID(value) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &out[i]);
        else if (CFGetTypeID(value) == CFStringGetTypeID())
            out[i] = CFStringGetDoubleValue((CFStringRef)value);
        else
            return false;
    }
    return true;
}

// Reads one component of the description into `match`, opening a new curve step when the last step is a
// matrix or already has a curve for this channel.
static bool wk_readMatchComponent(CFDictionaryRef component, wk_rgb_match *match)
{
    if (CFGetTypeID(component) != CFDictionaryGetTypeID())
        return false;
    CFArrayRef matrix = (CFArrayRef)CFDictionaryGetValue(component, WK_SYSTEM(kColorSyncConversionMatrix));
    if (matrix) {
        if (CFDictionaryGetCount(component) != 1 || CFGetTypeID(matrix) != CFArrayGetTypeID() || CFArrayGetCount(matrix) != 3
            || match->stepCount == wk_matchMaxSteps)
            return false;
        wk_match_step *step = &match->steps[match->stepCount++];
        step->isMatrix = true;
        for (CFIndex row = 0; row < 3; row++) {
            double values[4];
            if (!wk_readNumbers((CFArrayRef)CFArrayGetValueAtIndex(matrix, row), values, 4))
                return false;
            for (int column = 0; column < 4; column++)
                step->matrix[row][column] = (float)values[column];
        }
        return true;
    }

    CFStringRef keys[] = {
        WK_SYSTEM(kColorSyncConversionParamCurve0), WK_SYSTEM(kColorSyncConversionParamCurve1), WK_SYSTEM(kColorSyncConversionParamCurve2),
        WK_SYSTEM(kColorSyncConversionParamCurve3), WK_SYSTEM(kColorSyncConversionParamCurve4),
    };
    CFNumberRef channelNumber = (CFNumberRef)CFDictionaryGetValue(component, WK_SYSTEM(kColorSyncConversionChannelID));
    int channel = -1;
    if (!channelNumber || CFGetTypeID(channelNumber) != CFNumberGetTypeID() || !CFNumberGetValue(channelNumber, kCFNumberIntType, &channel)
        || channel < 0 || channel > 2 || CFDictionaryGetCount(component) != 2)
        return false;
    for (int type = 0; type < 5; type++) {
        CFArrayRef parameters = (CFArrayRef)CFDictionaryGetValue(component, keys[type]);
        if (!parameters)
            continue;
        double values[7];
        if (!wk_readNumbers(parameters, values, 7))
            return false;
        wk_match_step *step = match->stepCount ? &match->steps[match->stepCount - 1] : NULL;
        if (!step || step->isMatrix || step->hasCurve[channel]) {
            if (match->stepCount == wk_matchMaxSteps)
                return false;
            step = &match->steps[match->stepCount++];
        }
        wk_param_curve curve = { type, values[0], values[1], values[2], values[3], values[4], values[5], values[6] };
        if ((type == 1 || type == 2) && curve.a == 0)
            return false;
        step->curves[channel] = curve;
        step->hasCurve[channel] = true;
        return true;
    }
    return false;
}

static CFTypeRef wk_copyColorSyncProfile(CGColorSpaceRef space)
{
    CFDataRef data = CGColorSpaceCopyICCProfile(space);
    if (!data)
        return NULL;
    CFDataRef repaired = wk_iccProfileForColorSync(data);
    CFRelease(data);
    CFTypeRef profile = repaired ? WK_SYSTEM(ColorSyncProfileCreate)(repaired, NULL) : NULL;
    if (repaired)
        CFRelease(repaired);
    return profile;
}

static CFStringRef wk_colorSyncIntent(CGColorRenderingIntent intent)
{
    switch (intent) {
    case kCGRenderingIntentAbsoluteColorimetric:
        return WK_SYSTEM(kColorSyncRenderingIntentAbsolute);
    case kCGRenderingIntentRelativeColorimetric:
        return WK_SYSTEM(kColorSyncRenderingIntentRelative);
    case kCGRenderingIntentSaturation:
        return WK_SYSTEM(kColorSyncRenderingIntentSaturation);
    default:
        return WK_SYSTEM(kColorSyncRenderingIntentPerceptual);
    }
}

static void wk_buildRGBMatch(wk_rgb_match *match)
{
    CFTypeRef fromProfile = wk_copyColorSyncProfile(match->from), toProfile = wk_copyColorSyncProfile(match->to);
    CFArrayRef description = NULL;
    if (fromProfile && toProfile) {
        const void *keys[] = { WK_SYSTEM(kColorSyncProfile), WK_SYSTEM(kColorSyncRenderingIntent), WK_SYSTEM(kColorSyncTransformTag) };
        const void *fromValues[] = { fromProfile, wk_colorSyncIntent(match->intent), WK_SYSTEM(kColorSyncTransformDeviceToPCS) };
        const void *toValues[] = { toProfile, wk_colorSyncIntent(match->intent), WK_SYSTEM(kColorSyncTransformPCSToDevice) };
        CFDictionaryRef from = CFDictionaryCreate(kCFAllocatorDefault, keys, fromValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryRef to = CFDictionaryCreate(kCFAllocatorDefault, keys, toValues, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *sequence[] = { from, to };
        CFArrayRef profiles = from && to ? CFArrayCreate(kCFAllocatorDefault, sequence, 2, &kCFTypeArrayCallBacks) : NULL;
        CFTypeRef transform = profiles ? WK_SYSTEM(ColorSyncTransformCreate)(profiles, NULL) : NULL;
        if (transform) {
            description = (CFArrayRef)WK_SYSTEM(ColorSyncTransformCopyProperty)(transform, WK_SYSTEM(kColorSyncTransformParametricConversionData), NULL);
            CFRelease(transform);
        }
        if (profiles)
            CFRelease(profiles);
        if (from)
            CFRelease(from);
        if (to)
            CFRelease(to);
    }
    if (fromProfile)
        CFRelease(fromProfile);
    if (toProfile)
        CFRelease(toProfile);

    bool usable = description && CFGetTypeID(description) == CFArrayGetTypeID() && CFArrayGetCount(description) > 0;
    for (CFIndex i = 0; usable && i < CFArrayGetCount(description); i++)
        usable = wk_readMatchComponent((CFDictionaryRef)CFArrayGetValueAtIndex(description, i), match);
    if (description)
        CFRelease(description);
    for (int s = 0; usable && s < match->stepCount; s++) {
        wk_match_step *step = &match->steps[s];
        for (int channel = 0; !step->isMatrix && usable && channel < 3; channel++) {
            // The coarse table, then the fine one over its first interval; a channel the step has no curve for
            // takes the identity, which interpolates exactly.
            float *table = (float *)malloc(2 * (wk_curveIntervals + 1) * sizeof(float));
            step->tables[channel] = table;
            usable = table != NULL;
            const wk_param_curve identity = { 0, 1, 0, 0, 0, 0, 0, 0 };
            const wk_param_curve *curve = step->hasCurve[channel] ? &step->curves[channel] : &identity;
            for (int i = 0; usable && i <= wk_curveIntervals; i++) {
                table[i] = (float)wk_evaluateParamCurve(curve, (double)i / wk_curveIntervals);
                table[wk_curveIntervals + 1 + i] = (float)wk_evaluateParamCurve(curve, (double)i / wk_curveIntervals / wk_curveIntervals);
            }
        }
    }
    if (!usable) {
        for (int s = 0; s < match->stepCount; s++) {
            for (int channel = 0; channel < 3; channel++)
                free(match->steps[s].tables[channel]);
        }
        memset(match->steps, 0, sizeof(match->steps));
        match->stepCount = 0;
    }
}

static pthread_mutex_t wk_matchCacheLock = PTHREAD_MUTEX_INITIALIZER;

static void wk_freeRGBMatch(wk_rgb_match *match)
{
    for (int s = 0; s < wk_matchMaxSteps; s++) {
        for (int channel = 0; channel < 3; channel++)
            free(match->steps[s].tables[channel]);
    }
    CGColorSpaceRelease(match->from);
    CGColorSpaceRelease(match->to);
    free(match);
}

// Releases a match wk_rgbMatch answered.
static void wk_releaseRGBMatch(const wk_rgb_match *match)
{
    if (!match)
        return;
    pthread_mutex_lock(&wk_matchCacheLock);
    bool last = !--((wk_rgb_match *)match)->references;
    pthread_mutex_unlock(&wk_matchCacheLock);
    if (last)
        wk_freeRGBMatch((wk_rgb_match *)match);
}

// The parametric match from `from` to `to` under `intent`, or NULL when ColorSync describes it otherwise;
// the caller releases it. The most recent wk_matchCacheSize pairs are kept.
static const wk_rgb_match *wk_rgbMatch(CGColorSpaceRef from, CGColorSpaceRef to, CGColorRenderingIntent intent)
{
    static wk_rgb_match *cache[wk_matchCacheSize];
    static unsigned next;
    pthread_mutex_lock(&wk_matchCacheLock);
    wk_rgb_match *found = NULL, *evicted = NULL;
    for (unsigned i = 0; !found && i < wk_matchCacheSize; i++) {
        wk_rgb_match *entry = cache[i];
        if (entry && entry->intent == intent && WK_ORIGINAL(CGColorSpaceEqualToColorSpace)(entry->from, from)
            && WK_ORIGINAL(CGColorSpaceEqualToColorSpace)(entry->to, to))
            found = entry;
    }
    if (!found) {
        found = (wk_rgb_match *)calloc(1, sizeof(wk_rgb_match));
        if (found) {
            found->from = CGColorSpaceRetain(from);
            found->to = CGColorSpaceRetain(to);
            found->intent = intent;
            found->references = 1;
            wk_buildRGBMatch(found);
            unsigned slot = next++ % wk_matchCacheSize;
            evicted = cache[slot] && !--cache[slot]->references ? cache[slot] : NULL;
            cache[slot] = found;
        }
    }
    if (found && !found->stepCount)
        found = NULL;
    if (found)
        found->references++;
    pthread_mutex_unlock(&wk_matchCacheLock);
    if (evicted)
        wk_freeRGBMatch(evicted);
    return found;
}

typedef float wk_float4 __attribute__((ext_vector_type(4)));
typedef int wk_int4 __attribute__((ext_vector_type(4)));

static inline __attribute__((always_inline)) wk_float4 wk_clampUnit(wk_float4 value)
{
    return __builtin_elementwise_min(__builtin_elementwise_max(value, (wk_float4)0), (wk_float4)1);
}

// The three channels of `rgb` through their tables of a curve step.
static inline __attribute__((always_inline)) wk_float4 wk_evaluateTables(float *const tables[3], wk_float4 rgb)
{
    wk_float4 position = wk_clampUnit(rgb) * (float)wk_curveIntervals;
    wk_int4 fine = position < 1;
    position *= 1 + __builtin_convertvector(-fine, wk_float4) * (float)(wk_curveIntervals - 1);
    wk_int4 index = __builtin_elementwise_min(__builtin_convertvector(position, wk_int4), (wk_int4)(wk_curveIntervals - 1));
    wk_float4 fraction = position - __builtin_convertvector(index, wk_float4);
    index += fine & (wk_curveIntervals + 1);
    wk_float4 low = { tables[0][index.x], tables[1][index.y], tables[2][index.z], 0 };
    wk_float4 high = { tables[0][index.x + 1], tables[1][index.y + 1], tables[2][index.z + 1], 0 };
    return low + fraction * (high - low);
}

static inline __attribute__((always_inline)) wk_float4 wk_applyRGBMatch(const wk_rgb_match *match, wk_float4 rgb)
{
    for (int s = 0; s < match->stepCount; s++) {
        const wk_match_step *step = &match->steps[s];
        if (step->isMatrix) {
            const float (*m)[4] = step->matrix;
            rgb = (wk_float4) { m[0][0], m[1][0], m[2][0], 0 } * rgb.x + (wk_float4) { m[0][1], m[1][1], m[2][1], 0 } * rgb.y
                + (wk_float4) { m[0][2], m[1][2], m[2][2], 0 } * rgb.z + (wk_float4) { m[0][3], m[1][3], m[2][3], 0 };
        } else
            rgb = wk_evaluateTables(step->tables, rgb);
    }
    return rgb;
}

// One premultiplied pixel matched and written as 8-bit premultiplied BGRA: `straight` takes its colour
// components to unpremultiplied ones, and `scale` takes matched unpremultiplied ones to 8-bit premultiplied
// levels, which stay within the pixel's 8-bit alpha `alpha8`.
static inline __attribute__((always_inline)) void wk_matchPremultipliedPixel(const wk_rgb_match *match, float red, float green, float blue, float straight, float scale,
    int alpha8, uint8_t *out)
{
    if (!alpha8) {
        out[0] = out[1] = out[2] = out[3] = 0;
        return;
    }
    wk_float4 rgb = wk_applyRGBMatch(match, (wk_float4) { red, green, blue, 0 } * straight);
    wk_int4 levels = __builtin_elementwise_min(__builtin_convertvector(wk_clampUnit(rgb) * scale + 0.5f, wk_int4), (wk_int4)alpha8);
    out[0] = (uint8_t)levels.z;
    out[1] = (uint8_t)levels.y;
    out[2] = (uint8_t)levels.x;
    out[3] = (uint8_t)alpha8;
}

// Rows of 16-bit premultiplied RGBA (host order) matched into rows of 8-bit premultiplied BGRA.
static void wk_matchWideRows(const wk_rgb_match *shared, const uint8_t *from, size_t fromRowBytes, uint8_t *to, size_t toRowBytes, size_t width, size_t rows)
{
    // A copy the pixel stores cannot alias, so its steps stay in registers across the rows.
    const wk_rgb_match local = *shared, *match = &local;
    for (size_t y = 0; y < rows; y++) {
        const uint16_t *source = (const uint16_t *)(const void *)(from + y * fromRowBytes);
        uint8_t *out = to + y * toRowBytes;
        for (size_t x = 0; x < width; x++, source += 4, out += 4) {
            unsigned alpha = source[3];
            float straight = alpha ? 1.0f / (float)alpha : 0;
            wk_matchPremultipliedPixel(match, source[0], source[1], source[2], straight, (float)alpha * (255.0f / 65535.0f),
                (int)((alpha * 255 + 32767) / 65535), out);
        }
    }
}

// Rows of 8-bit premultiplied pixels whose red, green, blue and alpha lie at byte offsets `offsets`,
// matched into rows of 8-bit premultiplied BGRA.
static float wk_alphaReciprocals[256];
static void wk_build_alphaReciprocals(void)
{
    for (int alpha = 1; alpha < 256; alpha++)
        wk_alphaReciprocals[alpha] = 1.0f / (float)alpha;
}

static void wk_matchNarrowRows(const wk_rgb_match *shared, const uint8_t *from, size_t fromRowBytes, const int offsets[4], uint8_t *to, size_t toRowBytes, size_t width, size_t rows)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_alphaReciprocals);
    float reciprocals[256];
    memcpy(reciprocals, wk_alphaReciprocals, sizeof(reciprocals));
    const wk_rgb_match local = *shared, *match = &local;
    int red = offsets[0], green = offsets[1], blue = offsets[2], alphaOffset = offsets[3];
    for (size_t y = 0; y < rows; y++) {
        const uint8_t *source = from + y * fromRowBytes;
        uint8_t *out = to + y * toRowBytes;
        for (size_t x = 0; x < width; x++, source += 4, out += 4) {
            int alpha = source[alphaOffset];
            wk_matchPremultipliedPixel(match, source[red], source[green], source[blue], reciprocals[alpha], (float)alpha, alpha, out);
        }
    }
}

// CGContextDrawLinearGradient and CGContextDrawRadialGradient — DELIBERATE REPLACEMENTS of present 10.9
// functions, for 8-bit bitmap contexts whose colour space is not the gradient's. 10.9's bitmap rasterizer
// matches the gradient's colours to the context and then dithers the matched values, so a stretch between
// two equal stops is dithered too: sRGB 0,128,0 matched into the 8-bit linear-sRGB buffer of an SVG filter
// is 55.03, which 4% of the stretch stores as 56 (sRGB 129), while 1.5% of its zero red stores as 1 (sRGB
// 13). Modern CoreGraphics leaves that stretch one colour and still dithers the ramps.
//
// So the gradient is drawn over the clip's device bounds twice: undithered into a 16-bit bitmap of its own
// colour space, and natively into an 8-bit bitmap of the context's, which 10.9 dithers in the context's own
// quantization. The 16-bit bitmap is matched into the context's space at 8 bits through the pair's
// parametric match, or when ColorSync gives none, into a 16-bit bitmap of that space and rounded to 8 bits.
// A pixel where the undithered gradient varies -- differs from a neighbour -- takes the native draw's
// dithered colour; one where it is flat keeps the matched colour. The result is drawn into the context, a
// band of rows at a time. An extended-range gradient space is drawn into a floating-point bitmap and not
// dithered, since an 8-bit bitmap cannot hold its out-of-range components. The bands are transparent outside
// the gradient's extent, so the route is taken under a blend mode that leaves the destination unchanged
// beneath a transparent source, and without a shadow, which the native draw casts from the gradient's
// coverage.
extern bool CGContextGetAllowsDithering(CGContextRef);
extern CGBlendMode CGContextGetBlendMode(CGContextRef);
extern CGColorRenderingIntent CGContextGetRenderingIntent(CGContextRef);
typedef struct CGStyle *CGStyleRef;
extern CGStyleRef CGContextGetStyle(CGContextRef);

static bool wk_transparentSourceKeepsDestination(CGBlendMode mode)
{
    switch (mode) {
    case kCGBlendModeClear:
    case kCGBlendModeCopy:
    case kCGBlendModeSourceIn:
    case kCGBlendModeSourceOut:
    case kCGBlendModeDestinationIn:
    case kCGBlendModeDestinationAtop:
    case kCGBlendModePlusDarker:
        return false;
    default:
        return true;
    }
}

typedef struct {
    CGGradientRef gradient;
    bool radial;
    CGPoint startPoint;
    CGFloat startRadius;
    CGPoint endPoint;
    CGFloat endRadius;
    CGGradientDrawingOptions options;
} wk_gradient_draw;

static void wk_drawGradientDirectly(CGContextRef context, const wk_gradient_draw *draw);

// A bitmap of `space` covering `band` of device space, with the gradient drawn into it under `ctm`.
static CGContextRef wk_createGradientBand(const wk_gradient_draw *draw, CGColorSpaceRef space, CGRect band, CGAffineTransform ctm,
    size_t bitsPerComponent, CGBitmapInfo bitmapInfo)
{
    CGContextRef bitmap = CGBitmapContextCreate(NULL, (size_t)band.size.width, (size_t)band.size.height, bitsPerComponent, 0, space, bitmapInfo);
    if (!bitmap)
        return NULL;
    CGContextTranslateCTM(bitmap, -band.origin.x, -band.origin.y);
    CGContextConcatCTM(bitmap, ctm);
    wk_drawGradientDirectly(bitmap, draw);
    return bitmap;
}

// Pixels of `matched` where the undithered gradient in `exact` (16-bit RGBA) differs from a neighbour take the
// pixel of `native` (laid out as `matched`); the rest keep their own.
static void wk_ditherGradientRamps(CGContextRef exact, CGContextRef native, CGContextRef matched)
{
    size_t width = CGBitmapContextGetWidth(exact), height = CGBitmapContextGetHeight(exact);
    size_t exactRowBytes = CGBitmapContextGetBytesPerRow(exact);
    const uint8_t *exactBase = (const uint8_t *)CGBitmapContextGetData(exact);
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = exactBase + y * exactRowBytes;
        const uint8_t *above = y ? row - exactRowBytes : NULL;
        const uint8_t *below = y + 1 < height ? row + exactRowBytes : NULL;
        const uint8_t *nativeRow = (const uint8_t *)CGBitmapContextGetData(native) + y * CGBitmapContextGetBytesPerRow(native);
        uint8_t *out = (uint8_t *)CGBitmapContextGetData(matched) + y * CGBitmapContextGetBytesPerRow(matched);
        for (size_t x = 0; x < width; x++) {
            const uint8_t *pixel = row + x * 8;
            bool varies = (x && memcmp(pixel - 8, pixel, 8)) || (x + 1 < width && memcmp(pixel + 8, pixel, 8))
                || (above && memcmp(above + x * 8, pixel, 8)) || (below && memcmp(below + x * 8, pixel, 8));
            if (varies)
                memcpy(out + x * 4, nativeRow + x * 4, 4);
        }
    }
}

static bool wk_drawGradientInItsColorSpace(CGContextRef context, const wk_gradient_draw *draw)
{
    if (WK_SYSTEM(CGContextGetType)(context) != WK_CG_CONTEXT_TYPE_BITMAP)
        return false;
    CGColorSpaceRef contextSpace = CGBitmapContextGetColorSpace(context);
    CGColorSpaceRef gradientSpace = draw->gradient ? CGGradientGetColorSpace(draw->gradient) : NULL;
    if (!contextSpace || !gradientSpace || CGBitmapContextGetBitsPerComponent(context) != 8
        || (CGBitmapContextGetBitmapInfo(context) & kCGBitmapFloatComponents) || !CGContextGetAllowsDithering(context)
        || !wk_transparentSourceKeepsDestination(CGContextGetBlendMode(context)) || CGContextGetStyle(context)
        || CGColorSpaceGetModel(gradientSpace) != kCGColorSpaceModelRGB
        || CGColorSpaceGetModel(contextSpace) != kCGColorSpaceModelRGB
        || WK_ORIGINAL(CGColorSpaceEqualToColorSpace)(gradientSpace, contextSpace))
        return false;

    CGAffineTransform ctm = CGContextGetCTM(context);
    CGRect bounds = CGRectMake(0, 0, CGBitmapContextGetWidth(context), CGBitmapContextGetHeight(context));
    CGRect device = CGRectIntersection(CGRectApplyAffineTransform(CGContextGetClipBoundingBox(context), ctm), bounds);
    if (CGRectIsNull(device) || CGRectIsEmpty(device))
        return true;
    device = CGRectIntegral(device);

    bool extended = wk_colorSpaceUsesExtendedRange(gradientSpace);
    const CGBitmapInfo wideInfo = kCGBitmapByteOrder16Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    const CGBitmapInfo floatInfo = kCGBitmapFloatComponents | kCGBitmapByteOrder32Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    const CGBitmapInfo outInfo = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    size_t width = (size_t)device.size.width, bandRows = wk_conversionBandRows(width);

    const wk_rgb_match *match = extended ? NULL : wk_rgbMatch(gradientSpace, contextSpace, CGContextGetRenderingIntent(context));
    CGContextSaveGState(context);
    CGContextConcatCTM(context, CGAffineTransformInvert(ctm));
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    for (CGFloat bandTop = CGRectGetMaxY(device); bandTop > CGRectGetMinY(device); bandTop -= (CGFloat)bandRows) {
        CGFloat rows = fmin((CGFloat)bandRows, bandTop - CGRectGetMinY(device));
        CGRect band = CGRectMake(device.origin.x, bandTop - rows, device.size.width, rows);
        CGContextRef exact = wk_createGradientBand(draw, gradientSpace, band, ctm, extended ? 32 : 16, extended ? floatInfo : wideInfo);
        CGImageRef exactImage = exact && !match ? wk_createImageOverBitmap(exact) : NULL;
        CGContextRef matched = exactImage ? wk_createBitmapWithImage(exactImage, contextSpace, 16, wideInfo) : NULL;
        CGContextRef out = (match && exact) || matched ? CGBitmapContextCreate(NULL, width, (size_t)rows, 8, width * 4, contextSpace, outInfo) : NULL;
        CGImageRef outImage = NULL;
        if (out) {
            if (match)
                wk_matchWideRows(match, CGBitmapContextGetData(exact), CGBitmapContextGetBytesPerRow(exact), CGBitmapContextGetData(out),
                    CGBitmapContextGetBytesPerRow(out), width, (size_t)rows);
            else
                wk_roundRowsTo8Bit(CGBitmapContextGetData(matched), CGBitmapContextGetBytesPerRow(matched), CGBitmapContextGetData(out),
                    CGBitmapContextGetBytesPerRow(out), width, (size_t)rows);
            CGContextRef native = extended ? NULL : wk_createGradientBand(draw, contextSpace, band, ctm, 8, outInfo);
            if (native) {
                wk_ditherGradientRamps(exact, native, out);
                CGContextRelease(native);
            }
            outImage = wk_createImageOverBitmap(out);
        }
        if (outImage) {
            CGContextDrawImage(context, band, outImage);
            CGImageRelease(outImage);
        } else {
            // A band whose bitmaps could not be made is the native draw within it.
            CGContextSaveGState(context);
            CGContextClipToRect(context, band);
            CGContextConcatCTM(context, ctm);
            wk_drawGradientDirectly(context, draw);
            CGContextRestoreGState(context);
        }
        if (out)
            CGContextRelease(out);
        if (matched)
            CGContextRelease(matched);
        if (exactImage)
            CGImageRelease(exactImage);
        if (exact)
            CGContextRelease(exact);
    }
    CGContextRestoreGState(context);
    wk_releaseRGBMatch(match);
    return true;
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDrawLinearGradient,
    (CGContextRef context, CGGradientRef gradient, CGPoint startPoint, CGPoint endPoint, CGGradientDrawingOptions options))
{
    wk_gradient_draw draw = { gradient, false, startPoint, 0, endPoint, 0, options };
    if (!context || !wk_drawGradientInItsColorSpace(context, &draw))
        wk_drawGradientDirectly(context, &draw);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDrawRadialGradient,
    (CGContextRef context, CGGradientRef gradient, CGPoint startCenter, CGFloat startRadius, CGPoint endCenter, CGFloat endRadius, CGGradientDrawingOptions options))
{
    wk_gradient_draw draw = { gradient, true, startCenter, startRadius, endCenter, endRadius, options };
    if (!context || !wk_drawGradientInItsColorSpace(context, &draw))
        wk_drawGradientDirectly(context, &draw);
}

static void wk_drawGradientDirectly(CGContextRef context, const wk_gradient_draw *draw)
{
    if (draw->radial)
        WK_ORIGINAL(CGContextDrawRadialGradient)(context, draw->gradient, draw->startPoint, draw->startRadius, draw->endPoint, draw->endRadius, draw->options);
    else
        WK_ORIGINAL(CGContextDrawLinearGradient)(context, draw->gradient, draw->startPoint, draw->endPoint, draw->options);
}

// Lockdown Mode for PDF (macOS 13+). No Lockdown Mode on 10.9.
WK_POLYFILL_ABSENT("CoreGraphics", void, CGEnterLockdownModeForPDF, (void))
{
}

// CGColorSpaceIsWideGamutRGB is further down, with the wide-gamut spaces it answers about.

// Extended-range metadata selects floating-point backing storage in WebCore.
WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceUsesExtendedRange, (CGColorSpaceRef space))
{
    return wk_colorSpaceUsesExtendedRange(space);
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
// higher name. Every name 10.9 carries reaches its implementation unchanged. deGetColorSpace (30) is
// kept on the delegate as an association, which CGContextGetColorSpace above answers from; the other
// names above the ceiling are ones this CoreGraphics never asks for.
WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDelegateSetCallback,
                     (void *delegate, int name, void (*callback)(void)))
{
    static const int deGetColorSpace = 30;
    if (name == deGetColorSpace) {
        if (delegate)
            objc_setAssociatedObject((id)delegate, wk_delegateColorSpaceCallbackKey(), (id)(void *)callback, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (name > 23)
        return;
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
// GAMUT is a matter of primaries and a white point, which CGColorSpaceCreateCalibratedRGB takes: the
// Display P3, Rec. 2020 and ROMM RGB names are answered with their own published primaries, so values
// tagged with them are interpreted as what they are and clamp where clamping belongs, at the
// conversion to the display.
//
// The LINEAR names are different, and getting them wrong is not a gamut approximation but a wrong
// answer. A space named "linear sRGB" whose transfer function is sRGB's ~2.2 gamma misreports every
// value in it: WebCore composites SVG filters in linearRGB by default, so returning a gamma space
// there silently moves filter maths into the wrong domain. The linear spaces are CoreGraphics' own
// sRGB profile with its colorants (Display P3's, for linear Display P3) and identity tone curves, so a
// match between a linear space and its gamma-encoded one is the tone curve alone, as modern macOS gives
// for kCGColorSpaceLinearSRGB: every 8-bit sRGB level lands on its exact linearization.
//
// EVERY colour-space name this file publishes is answered. Probed on this host, stock CGColorSpaceCreateWithName
// returns NULL for all eleven of them, and a NULL colour space is not a lesser answer but a broken one:
// it fails the caller's ASSERT, leaves CGBitmapContext creation without a colour space, and makes
// distinct absent spaces compare equal to each other.
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef));
WK_SYSTEM_FN("CoreGraphics", bool, CGColorSpaceEqualToColorSpace, (CGColorSpaceRef, CGColorSpaceRef));

static CGColorSpaceRef wk_createICCSpaceFromSRGB(const uint32_t colorants[3][3], bool linear, const char *description);

// Linear sRGB, built once; the returned space is retained per call to match CGColorSpaceCreateWithName's
// Create semantics.
static CGColorSpaceRef wk_linear_sRGB_storage;
static void wk_build_linear_sRGB(void)
{
    wk_linear_sRGB_storage = wk_createICCSpaceFromSRGB(NULL, true, "Linear sRGB");
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

// The wide-gamut spaces. CGColorSpaceCreateCalibratedRGB takes the XYZ coordinates of the red, green
// and blue primaries as its matrix (columns) and one gamma per channel, which is what a space whose
// transfer function IS a power curve needs. Display P3 and linear Display P3 are built from an ICC
// profile instead -- see below.
static const CGFloat wk_whitePointD65[3] = { 0.9505, 1.0, 1.0890 };
static const CGFloat wk_whitePointD50[3] = { 0.9642, 1.0, 0.8249 };
static const CGFloat wk_blackPoint[3] = { 0.0, 0.0, 0.0 };

static const CGFloat wk_rec2020PrimariesToXYZ[9] = {
    0.6369580, 0.2627002, 0.0000000,
    0.1446169, 0.6779981, 0.0280727,
    0.1688810, 0.0593017, 1.0609851,
};
static const CGFloat wk_rommPrimariesToXYZ[9] = {
    0.7976749, 0.2880402, 0.0000000,
    0.1351917, 0.7118741, 0.0000000,
    0.0313534, 0.0000857, 0.8252100,
};

static CGColorSpaceRef wk_makeCalibratedRGB(const CGFloat whitePoint[3], CGFloat transfer, const CGFloat primaries[9])
{
    const CGFloat gamma[3] = { transfer, transfer, transfer };
    return CGColorSpaceCreateCalibratedRGB(whitePoint, wk_blackPoint, gamma, primaries);
}

// Display P3: P3's primaries with sRGB's transfer function. That transfer function is piecewise -- a
// linear segment below 0.04045 and a 2.4 power above it -- and CGColorSpaceCreateCalibratedRGB takes
// one exponent per channel, so a calibrated space cannot carry it. The nearest exponent, 2.2, costs a
// 1/255 step: measured on this host by filling into an sRGB bitmap, the P3 green (0.26374, 0.59085,
// 0.16434) lands on 0,154,0 through a 2.2 exponent and on 0,153,0 (sRGB #009900) through the real curve.
//
// So the space is built from an ICC profile: this CoreGraphics' own sRGB profile with the three
// colorant tags replaced by the Display P3 primaries. Every curve in it is the one this CoreGraphics
// already uses for sRGB, so gamut is the only thing that differs from sRGB, which is exactly what
// Display P3 is.

// The D50-adapted XYZ of the Display P3 red, green and blue primaries, one row per primary, in the
// s15Fixed16 encoding an ICC XYZType tag holds. Bradford adaptation maps Display P3's D65
// primaries to the ICC PCS white point (0.9642, 1.0, 0.8249).
static const uint32_t wk_displayP3ColorantsD50[3][3] = {
    { 0x000083dfu, 0x00003dbfu, 0xffffffbbu },
    { 0x00004abfu, 0x0000b137u, 0x00000ab9u },
    { 0x00002838u, 0x0000110bu, 0x0000c8b9u },
};

static uint32_t wk_iccReadUInt32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void wk_iccWriteUInt32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

// An ICC textDescriptionType tag: a 4-byte type signature, 4 reserved bytes, the ASCII length
// including its terminator, the ASCII text, then a Unicode section (language code and length) and a
// ScriptCode one (code, length and a 67-byte field), which zeros leave empty. The whole tag is
// rewritten rather than edited because those two sections sit directly behind the text.
static bool wk_iccWriteDescription(uint8_t *tag, uint32_t tagSize, const char *text)
{
    const size_t bytesBesidesTheText = 12 + 4 + 4 + 2 + 1 + 67;
    size_t textSize = strlen(text) + 1;
    if (memcmp(tag, "desc", 4) || tagSize < bytesBesidesTheText + textSize)
        return false;
    memset(tag, 0, tagSize);
    memcpy(tag, "desc", 4);
    wk_iccWriteUInt32(tag + 8, (uint32_t)textSize);
    memcpy(tag + 12, text, textSize);
    return true;
}

// This CoreGraphics' sRGB profile with its colorant tags replaced by `colorants` (D50-adapted XYZ rows
// in s15Fixed16) unless they are NULL, its tone curves by the identity when `linear`, and its description
// by `description`; NULL when the profile cannot be rewritten.
static CGColorSpaceRef wk_createICCSpaceFromSRGB(const uint32_t colorants[3][3], bool linear, const char *description)
{
    CGColorSpaceRef sRGB = WK_SYSTEM(CGColorSpaceCreateWithName)(kCGColorSpaceSRGB);
    if (!sRGB)
        return NULL;
    CFDataRef sRGBProfile = CGColorSpaceCopyICCProfile(sRGB);
    CGColorSpaceRelease(sRGB);
    if (!sRGBProfile)
        return NULL;

    CFMutableDataRef profile = CFDataCreateMutableCopy(NULL, 0, sRGBProfile);
    CFRelease(sRGBProfile);
    if (!profile)
        return NULL;

    // The tag table follows the 128-byte header: a count, then one 12-byte entry per tag carrying its
    // signature, its offset from the start of the profile and its size.
    uint8_t *bytes = CFDataGetMutableBytePtr(profile);
    size_t length = (size_t)CFDataGetLength(profile);
    unsigned colorantsWritten = 0, curvesWritten = 0;
    bool described = false;
    if (length >= 132) {
        static const char *const colorantTags[3] = { "rXYZ", "gXYZ", "bXYZ" };
        static const char *const curveTags[3] = { "rTRC", "gTRC", "bTRC" };
        uint32_t tagCount = wk_iccReadUInt32(bytes + 128);
        for (uint32_t i = 0; i < tagCount && 132 + 12 * (size_t)(i + 1) <= length; i++) {
            const uint8_t *entry = bytes + 132 + 12 * (size_t)i;
            uint32_t offset = wk_iccReadUInt32(entry + 4);
            uint32_t size = wk_iccReadUInt32(entry + 8);
            if (offset > length || size > length - offset)
                continue;
            uint8_t *tag = bytes + offset;
            if (!memcmp(entry, "desc", 4)) {
                described = wk_iccWriteDescription(tag, size, description);
                continue;
            }
            // An XYZType tag is its signature, 4 reserved bytes and three s15Fixed16 numbers.
            for (unsigned c = 0; colorants && c < 3; c++) {
                if (memcmp(entry, colorantTags[c], 4) || size < 20 || memcmp(tag, "XYZ ", 4))
                    continue;
                for (unsigned component = 0; component < 3; component++)
                    wk_iccWriteUInt32(tag + 8 + 4 * component, colorants[c][component]);
                colorantsWritten++;
            }
            // A curveType tag with no entries is the identity: its signature, 4 reserved bytes and a zero
            // count. The three curves share one tag, so each entry's size is rewritten to that.
            for (unsigned c = 0; linear && c < 3; c++) {
                if (memcmp(entry, curveTags[c], 4) || size < 12 || memcmp(tag, "curv", 4))
                    continue;
                wk_iccWriteUInt32(tag + 8, 0);
                wk_iccWriteUInt32((uint8_t *)entry + 8, 12);
                curvesWritten++;
            }
        }
    }

    CGColorSpaceRef space = (!colorants || colorantsWritten == 3) && (!linear || curvesWritten == 3) && described
        ? CGColorSpaceCreateWithICCProfile(profile) : NULL;
    CFRelease(profile);
    return space;
}

static CGColorSpaceRef wk_displayP3_storage;
static void wk_build_displayP3(void)
{
    wk_displayP3_storage = wk_createICCSpaceFromSRGB(wk_displayP3ColorantsD50, false, "Display P3");
}
static CGColorSpaceRef wk_displayP3_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_displayP3);
    return wk_displayP3_storage;
}

static void wk_iccWriteUInt16(uint8_t *bytes, uint16_t value)
{
    bytes[0] = value >> 8;
    bytes[1] = value;
}

// SMPTE ST 2084, linear 1.0 at 10000 cd/m^2.
__attribute__((visibility("hidden"))) double wk_pqEOTF(double encoded)
{
    double p = pow(encoded, 32.0 / 2523.0);
    return pow(fmax(p - 3424.0 / 4096.0, 0.0) / (2413.0 / 128.0 - (2392.0 / 128.0) * p), 16384.0 / 2610.0);
}

__attribute__((visibility("hidden"))) double wk_pqOETF(double linear)
{
    double p = pow(linear, 2610.0 / 16384.0);
    return pow((3424.0 / 4096.0 + (2413.0 / 128.0) * p) / (1 + (2392.0 / 128.0) * p), 2523.0 / 32.0);
}

enum { wk_pqSamples = 16384, wk_pqCurveSize = 12 + 2 * wk_pqSamples };

static uint32_t wk_iccWriteMLUC(uint8_t *bytes, const char *text)
{
    size_t count = strlen(text);
    memcpy(bytes, "mluc", 4);
    wk_iccWriteUInt32(bytes + 8, 1);
    wk_iccWriteUInt32(bytes + 12, 12);
    memcpy(bytes + 16, "enUS", 4);
    wk_iccWriteUInt32(bytes + 20, 2 * count);
    wk_iccWriteUInt32(bytes + 24, 28);
    for (size_t i = 0; i < count; ++i)
        wk_iccWriteUInt16(bytes + 28 + 2 * i, text[i]);
    return 28 + 2 * count;
}

static CGColorSpaceRef wk_displayP3PQ_storage;

// A matrix/TRC profile: the Display P3 colorants scaled so 1.0 is 80 cd/m^2 against ST 2084's 10000, and
// the transfer function sampled as each channel's TRC. 10.9's ColorSync evaluates no curve of an lut tag
// below x/16, so a TRC is the closest it comes to ST 2084; WebKit's own HDR conversions evaluate ST 2084
// exactly (ImageIOHDR.m).
static void wk_build_displayP3PQ(void)
{
    CGColorSpaceRef base = wk_displayP3_space();
    CFDataRef source = base ? CGColorSpaceCopyICCProfile(base) : NULL;
    if (!source)
        return;
    enum { tagCount = 11, tableEnd = 132 + 12 * tagCount };
    size_t capacity = tableEnd + wk_pqCurveSize + 256;
    CFMutableDataRef profile = CFDataCreateMutable(NULL, 0);
    CFDataSetLength(profile, capacity);
    uint8_t *bytes = CFDataGetMutableBytePtr(profile);
    memset(bytes, 0, capacity);
    memcpy(bytes, CFDataGetBytePtr(source), 128);
    CFRelease(source);
    wk_iccWriteUInt32(bytes + 8, 0x04300000);
    memset(bytes + 84, 0, 16);
    wk_iccWriteUInt32(bytes + 128, tagCount);
    const char *signatures[] = { "desc", "cprt", "wtpt", "rXYZ", "gXYZ", "bXYZ", "lumi", "cicp", "rTRC", "gTRC", "bTRC" };
    uint32_t cursor = tableEnd;
    for (unsigned i = 0; i < tagCount; ++i) {
        uint8_t *tag = bytes + cursor;
        uint32_t size;
        if (i < 2)
            size = wk_iccWriteMLUC(tag, i ? "Aqua WebKit" : "Display P3 PQ");
        else if (i < 7) {
            size = 20;
            memcpy(tag, "XYZ ", 4);
            for (unsigned c = 0; c < 3; ++c) {
                uint32_t value;
                if (i == 2) {
                    static const uint32_t white[] = { 0xf6d6, 0x10000, 0xd32d };
                    value = white[c];
                } else if (i == 6)
                    value = c == 1 ? 10000u << 16 : 0;
                else
                    value = (int32_t)wk_displayP3ColorantsD50[i - 3][c] * 125;
                wk_iccWriteUInt32(tag + 8 + 4 * c, value);
            }
        } else if (i == 7) {
            size = 12;
            memcpy(tag, "cicp", 4);
            tag[8] = 12;
            tag[9] = 16;
            tag[11] = 1;
        } else if (i == 8) {
            size = wk_pqCurveSize;
            memcpy(tag, "curv", 4);
            wk_iccWriteUInt32(tag + 8, wk_pqSamples);
            for (unsigned sample = 0; sample < wk_pqSamples; ++sample)
                wk_iccWriteUInt16(tag + 12 + 2 * sample, (uint16_t)lround(wk_pqEOTF((double)sample / (wk_pqSamples - 1)) * 65535));
        } else {
            // The three channels share one curve.
            uint8_t *entry = bytes + 132 + 12 * i;
            memcpy(entry, signatures[i], 4);
            memcpy(entry + 4, entry - 12 + 4, 8);
            continue;
        }
        uint8_t *entry = bytes + 132 + 12 * i;
        memcpy(entry, signatures[i], 4);
        wk_iccWriteUInt32(entry + 4, cursor);
        wk_iccWriteUInt32(entry + 8, size);
        cursor += (size + 3) & ~3u;
    }
    wk_iccWriteUInt32(bytes, cursor);
    CFDataSetLength(profile, cursor);
    wk_displayP3PQ_storage = CGColorSpaceCreateWithICCProfile(profile);
    CFRelease(profile);
}

static CGColorSpaceRef wk_displayP3PQ_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_displayP3PQ);
    return wk_displayP3PQ_storage;
}

__attribute__((visibility("hidden"))) bool wk_isDisplayP3PQSpace(CGColorSpaceRef space)
{
    return space && space == wk_displayP3PQ_space();
}

__attribute__((visibility("hidden"))) unsigned wk_colorSpaceTransferFunction(CGColorSpaceRef space)
{
    if (!space)
        return false;
    CFDataRef profile = CGColorSpaceCopyICCProfile(space);
    if (!profile)
        return false;
    const uint8_t *bytes = CFDataGetBytePtr(profile);
    size_t length = (size_t)CFDataGetLength(profile);
    unsigned transfer = 0;
    if (length >= 132) {
        uint32_t count = wk_iccReadUInt32(bytes + 128);
        for (uint32_t i = 0; i < count && 132 + 12 * (size_t)(i + 1) <= length; ++i) {
            const uint8_t *entry = bytes + 132 + 12 * i;
            uint32_t offset = wk_iccReadUInt32(entry + 4), size = wk_iccReadUInt32(entry + 8);
            if (!memcmp(entry, "cicp", 4) && offset <= length && size >= 12 && size <= length - offset
                && !memcmp(bytes + offset, "cicp", 4)) {
                transfer = bytes[offset + 9];
                break;
            }
        }
    }
    CFRelease(profile);
    return transfer;
}

WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceUsesITUR_2100TF, (CGColorSpaceRef space))
{
    unsigned transfer = wk_colorSpaceTransferFunction(space);
    return transfer == 16 || transfer == 18;
}

// The same primaries with a linear transfer.
static CGColorSpaceRef wk_linearDisplayP3_storage;
static void wk_build_linearDisplayP3(void)
{
    wk_linearDisplayP3_storage = wk_createICCSpaceFromSRGB(wk_displayP3ColorantsD50, true, "Linear Display P3");
}
static CGColorSpaceRef wk_linearDisplayP3_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_linearDisplayP3);
    return wk_linearDisplayP3_storage;
}

// ITU-R BT.2020: 2020 primaries, D65, the BT.1886 display transfer.
static CGColorSpaceRef wk_rec2020_storage;
static void wk_build_rec2020(void)
{
    wk_rec2020_storage = wk_makeCalibratedRGB(wk_whitePointD65, 2.4, wk_rec2020PrimariesToXYZ);
}
static CGColorSpaceRef wk_rec2020_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_rec2020);
    return wk_rec2020_storage;
}

// ROMM RGB (ProPhoto): ROMM primaries, D50, gamma 1.8.
static CGColorSpaceRef wk_romm_storage;
static void wk_build_romm(void)
{
    wk_romm_storage = wk_makeCalibratedRGB(wk_whitePointD50, 1.8, wk_rommPrimariesToXYZ);
}
static CGColorSpaceRef wk_romm_space(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_romm);
    return wk_romm_storage;
}

WK_SYSTEM_FN(WK_COLORSYNC, bool, ColorSyncProfileIsWideGamut, (CFTypeRef));

// ColorSync classifies the profile's chromaticity triangle against the NTSC gamut threshold.
WK_POLYFILL_ABSENT("CoreGraphics", bool, CGColorSpaceIsWideGamutRGB, (CGColorSpaceRef space))
{
    if (!space || CGColorSpaceGetModel(space) != kCGColorSpaceModelRGB)
        return false;
    CFDataRef data = CGColorSpaceCopyICCProfile(space);
    if (!data)
        return false;
    CFDataRef repaired = wk_iccProfileForColorSync(data);
    CFRelease(data);
    CFTypeRef profile = WK_SYSTEM(ColorSyncProfileCreate)(repaired, NULL);
    CFRelease(repaired);
    if (!profile)
        return false;
    bool result = WK_SYSTEM(ColorSyncProfileIsWideGamut)(profile);
    CFRelease(profile);
    return result;
}

WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef name))
{
    CGColorSpaceRef space = WK_SYSTEM(CGColorSpaceCreateWithName)(name);
    if (space || !name)
        return space;   // 10.9 knew this name (or there is no name): its answer stands

    // Linear transfer function and sRGB primaries, with independent storage-range metadata.
    static const CFStringRef linear[] = {
        CFSTR("kCGColorSpaceLinearSRGB"), CFSTR("kCGColorSpaceExtendedLinearSRGB"),
    };
    for (size_t i = 0; i < sizeof(linear) / sizeof(linear[0]); i++) {
        if (CFStringCompare(name, linear[i], 0) == kCFCompareEqualTo) {
            CGColorSpaceRef linearSRGB = wk_linear_sRGB_space();
            return wk_nameColorSpace(CFStringHasPrefix(name, CFSTR("kCGColorSpaceExtended")) ? wk_createExtendedColorSpace(linearSRGB) : (linearSRGB ? CGColorSpaceRetain(linearSRGB) : NULL), name);
        }
    }

    if (CFStringCompare(name, CFSTR("kCGColorSpaceGenericXYZ"), 0) == kCFCompareEqualTo) {
        CGColorSpaceRef xyz = wk_xyz_D50_space();
        return wk_nameColorSpace(xyz ? CGColorSpaceRetain(xyz) : NULL, name);
    }

    // Wide-gamut spaces retain their primaries, white point and transfer in both storage ranges.
    static const struct { CFStringRef name; CGColorSpaceRef (*space)(void); } wideGamut[] = {
        { CFSTR("kCGColorSpaceDisplayP3"), wk_displayP3_space },
        { CFSTR("kCGColorSpaceDisplayP3_PQ"), wk_displayP3PQ_space },
        { CFSTR("kCGColorSpaceExtendedDisplayP3"), wk_displayP3_space },
        { CFSTR("kCGColorSpaceLinearDisplayP3"), wk_linearDisplayP3_space },
        { CFSTR("kCGColorSpaceExtendedLinearDisplayP3"), wk_linearDisplayP3_space },
        { CFSTR("kCGColorSpaceITUR_2020"), wk_rec2020_space },
        { CFSTR("kCGColorSpaceExtendedITUR_2020"), wk_rec2020_space },
        { CFSTR("kCGColorSpaceExtendedRec2020"), wk_rec2020_space },
        { CFSTR("kCGColorSpaceROMMRGB"), wk_romm_space },
    };
    for (size_t i = 0; i < sizeof(wideGamut) / sizeof(wideGamut[0]); i++) {
        if (CFStringCompare(name, wideGamut[i].name, 0) == kCFCompareEqualTo) {
            CGColorSpaceRef wide = wideGamut[i].space();
            return wk_nameColorSpace(CFStringHasPrefix(name, CFSTR("kCGColorSpaceExtended")) ? wk_createExtendedColorSpace(wide) : (wide ? CGColorSpaceRetain(wide) : NULL), name);
        }
    }

    if (CFStringCompare(name, CFSTR("kCGColorSpaceExtendedSRGB"), 0) == kCFCompareEqualTo) {
        CGColorSpaceRef srgb = WK_SYSTEM(CGColorSpaceCreateWithName)(kCGColorSpaceSRGB);
        CGColorSpaceRef extended = wk_createExtendedColorSpace(srgb);
        if (srgb)
            CGColorSpaceRelease(srgb);
        return wk_nameColorSpace(extended, name);
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
// Total layers open across every tracked context. wk_isInsideTransparencyLayer runs once per glyph
// run painted (CTFontDrawGlyphs), so the zero case — all of screen painting — must not take the lock.
static int wk_transparencyLayerOpenCount;


// CGContextDrawImage — a DELIBERATE REPLACEMENT of a present 10.9 function, for IOSurface contexts and for
// 8-bit bitmap contexts drawing a premultiplied image of another colour space (wk_matchesBitmapDraw).
// 10.9 implements those in QuartzCore (CAIOSurfaceContextVTable), whose CA::Render::copy_image
// colour-matches an image once and keeps the result in an image cache keyed by the CGImage alone, so
// every later draw of that image into an IOSurface context reuses the first destination's matching
// whatever its own colour space is: an sRGB image drawn into a Display P3 surface and then into an
// sRGB one reads 234,51,35 in both. It also matches all but small images through its renderer's colour
// cube, interpolating between nodes eight 8-bit levels apart, which puts level 1 of a linear-sRGB image
// at sRGB 6 where ColorSync answers 13. An IOSurface draw is therefore always made through an image
// kept for that destination colour space and released with the image. An image in another colour space
// is matched into that space by CoreGraphics' bitmap route, which QuartzCore then draws unmatched; an
// image already in it is a CGImageCreateCopy, which shares its pixels and has a cache entry of its own
// that no other caller can fill. 10.9 caches both a CGIOSurfaceContextCreateImage image and a
// direct-provider image on these routes; the per-space image is what gives each destination space its
// own matching. An image over the renderer's texture limit (below) is drawn in parts of its per-space image.
//
// Every image in the process carries its own copy of this archive, so the association key is a
// selector and the lock is one object the runtime's association table holds for the whole process.

static const void *wk_ioSurfaceImageDrawsKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_ioSurfaceImageDraws");
    return key;
}

static id wk_ioSurfaceImageLock(void)
{
    static id lock;
    if (lock)
        return lock;
    id anchor = (id)objc_getClass("NSObject");
    const void *key = (const void *)sel_registerName("wk_ioSurfaceImageLock");
    objc_sync_enter(anchor);
    id existing = objc_getAssociatedObject(anchor, key);
    if (!existing) {
        CFMutableDataRef token = CFDataCreateMutable(kCFAllocatorDefault, 0);
        if (token) {
            objc_setAssociatedObject(anchor, key, (id)(void *)token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(token);
            existing = objc_getAssociatedObject(anchor, key);
        }
    }
    objc_sync_exit(anchor);
    lock = existing;
    return lock;
}

// The bytes of an unmasked image whose pixels are 8-bit premultiplied RGB in 32 bits, as its provider holds
// them, or NULL for any other image, which is read through a bitmap.
static CFDataRef wk_copyPremultipliedPixels(CGImageRef image)
{
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    CGBitmapInfo order = CGImageGetBitmapInfo(image) & kCGBitmapByteOrderMask;
    if (CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32 || CGImageGetDecode(image) || CGImageGetMask(image)
        || (alpha != kCGImageAlphaPremultipliedFirst && alpha != kCGImageAlphaPremultipliedLast)
        || (order != kCGBitmapByteOrderDefault && order != kCGBitmapByteOrder32Big && order != kCGBitmapByteOrder32Little))
        return NULL;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (data && (size_t)CFDataGetLength(data) < CGImageGetBytesPerRow(image) * (CGImageGetHeight(image) - 1) + CGImageGetWidth(image) * 4) {
        CFRelease(data);
        return NULL;
    }
    return data;
}

// The byte offsets of red, green, blue and alpha in a pixel of an image wk_copyPremultipliedPixels reads.
static void wk_premultipliedOffsets(CGImageRef image, int offsets[4])
{
    bool alphaFirst = CGImageGetAlphaInfo(image) == kCGImageAlphaPremultipliedFirst;
    bool little = (CGImageGetBitmapInfo(image) & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
    // Components in memory order for a big-endian word: alpha first is A R G B, alpha last is R G B A.
    int alphaIndex = alphaFirst ? 0 : 3, redIndex = alphaFirst ? 1 : 0;
    for (int i = 0; i < 3; i++)
        offsets[i] = little ? 3 - (redIndex + i) : redIndex + i;
    offsets[3] = little ? 3 - alphaIndex : alphaIndex;
}

// `image` matched into a bitmap of `colorSpace` at the image's component depth. The bitmap carries alpha
// unless the image is opaque: no alpha channel, no mask and no masking colours. 10.9's CoreGraphics matches
// a premultiplied 8-bit image after unpremultiplying it at 8 bits, which moves dark translucent colours by
// up to 5 levels: a linear-sRGB 41 at alpha 191 lands on sRGB 95 where the colour is 95.63. Such an image is
// matched through the pair's parametric match, and when ColorSync gives none, widened to 16 bits in its own
// colour space, matched there and rounded back to 8 bits, a band of rows at a time.
static CGImageRef wk_createImageMatchedToColorSpace(CGImageRef image, CGColorSpaceRef colorSpace)
{
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    bool opaque = (alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast)
        && !CGImageGetMask(image) && !CGImageGetMaskingColors(image);
    bool premultiplied = alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaPremultipliedLast;
    size_t bitsPerComponent;
    CGBitmapInfo bitmapInfo;
    if (CGImageGetBitmapInfo(image) & kCGBitmapFloatComponents) {
        bitsPerComponent = 32;
        bitmapInfo = kCGBitmapFloatComponents | kCGBitmapByteOrder32Host
            | (CGBitmapInfo)(opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
    } else if (CGImageGetBitsPerComponent(image) > 8) {
        bitsPerComponent = 16;
        bitmapInfo = kCGBitmapByteOrder16Host | (CGBitmapInfo)(opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
    } else {
        bitsPerComponent = 8;
        bitmapInfo = kCGBitmapByteOrder32Little | (CGBitmapInfo)(opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
    }

    CGColorSpaceRef imageSpace = CGImageGetColorSpace(image);
    if (!premultiplied || bitsPerComponent != 8 || CGColorSpaceGetModel(imageSpace) != kCGColorSpaceModelRGB) {
        CGContextRef bitmap = wk_createBitmapWithImage(image, colorSpace, bitsPerComponent, bitmapInfo);
        if (!bitmap)
            return NULL;
        CGImageRef pixels = CGBitmapContextCreateImage(bitmap);
        CGContextRelease(bitmap);
        if (!pixels)
            return NULL;
        CGImageRef matched = CGImageCreate(width, height, bitsPerComponent, CGImageGetBitsPerPixel(pixels), CGImageGetBytesPerRow(pixels),
            colorSpace, bitmapInfo, CGImageGetDataProvider(pixels), NULL, CGImageGetShouldInterpolate(image), CGImageGetRenderingIntent(image));
        CGImageRelease(pixels);
        return matched;
    }

    CFMutableDataRef pixels = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!pixels)
        return NULL;
    CFDataSetLength(pixels, (CFIndex)(width * height * 4));
    uint8_t *out = CFDataGetMutableBytePtr(pixels);
    const wk_rgb_match *match = wk_rgbMatch(imageSpace, colorSpace, CGImageGetRenderingIntent(image));
    CFDataRef source = match ? wk_copyPremultipliedPixels(image) : NULL;
    bool complete = out != NULL;
    if (source && out) {
        int offsets[4];
        wk_premultipliedOffsets(image, offsets);
        wk_matchNarrowRows(match, CFDataGetBytePtr(source), CGImageGetBytesPerRow(image), offsets, out, width * 4, width, height);
    }
    const CGBitmapInfo wideInfo = kCGBitmapByteOrder16Host | (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
    const CGBitmapInfo narrowInfo = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    static const int narrowOffsets[4] = { 2, 1, 0, 3 };
    size_t bandRows = wk_conversionBandRows(width);
    for (size_t top = 0; !source && complete && top < height; top += bandRows) {
        size_t rows = height - top < bandRows ? height - top : bandRows;
        CGImageRef band = CGImageCreateWithImageInRect(image, CGRectMake(0, top, width, rows));
        CGContextRef wide = band ? wk_createBitmapWithImage(band, imageSpace, match ? 8 : 16, match ? narrowInfo : wideInfo) : NULL;
        CGImageRef wideImage = wide && !match ? wk_createImageOverBitmap(wide) : NULL;
        CGContextRef matched = wideImage ? wk_createBitmapWithImage(wideImage, colorSpace, 16, wideInfo) : NULL;
        if (match && wide)
            wk_matchNarrowRows(match, CGBitmapContextGetData(wide), CGBitmapContextGetBytesPerRow(wide), narrowOffsets, out + top * width * 4, width * 4, width, rows);
        else if (matched)
            wk_roundRowsTo8Bit(CGBitmapContextGetData(matched), CGBitmapContextGetBytesPerRow(matched), out + top * width * 4, width * 4, width, rows);
        complete = match ? wide != NULL : matched != NULL;
        if (matched)
            CGContextRelease(matched);
        if (wideImage)
            CGImageRelease(wideImage);
        if (wide)
            CGContextRelease(wide);
        if (band)
            CGImageRelease(band);
    }
    if (source)
        CFRelease(source);
    wk_releaseRGBMatch(match);
    CGDataProviderRef provider = complete ? CGDataProviderCreateWithCFData(pixels) : NULL;
    CFRelease(pixels);
    if (!provider)
        return NULL;
    CGImageRef matched = CGImageCreate(width, height, 8, 32, width * 4, colorSpace, bitmapInfo, provider, NULL,
        CGImageGetShouldInterpolate(image), CGImageGetRenderingIntent(image));
    CGDataProviderRelease(provider);
    return matched;
}

// The image kept for `colorSpace` in `draws`, a flat array of (colour space, image) pairs, or NULL.
static CGImageRef wk_findImageForColorSpace(CFArrayRef draws, CGColorSpaceRef colorSpace)
{
    CFIndex count = draws ? CFArrayGetCount(draws) : 0;
    for (CFIndex index = 0; index + 1 < count; index += 2) {
        if (WK_SYSTEM(CGColorSpaceEqualToColorSpace)((CGColorSpaceRef)CFArrayGetValueAtIndex(draws, index), colorSpace))
            return (CGImageRef)CFArrayGetValueAtIndex(draws, index + 1);
    }
    return NULL;
}

// The image a context of this colour space draws for `image`, kept on the image as an association. It is
// made outside the lock, and a thread that loses the race to keep one uses the winner's.
static CGImageRef wk_imageForDestinationColorSpace(CGImageRef image, CGColorSpaceRef colorSpace)
{
    id lock = wk_ioSurfaceImageLock();
    objc_sync_enter(lock);
    CGImageRef answer = wk_findImageForColorSpace((CFArrayRef)(void *)objc_getAssociatedObject((id)image, wk_ioSurfaceImageDrawsKey()), colorSpace);
    objc_sync_exit(lock);
    if (answer)
        return answer;

    CGColorSpaceRef imageSpace = CGImageGetColorSpace(image);
    bool matched = imageSpace && !CGImageIsMask(image) && CGColorSpaceGetModel(colorSpace) == kCGColorSpaceModelRGB
        && !WK_SYSTEM(CGColorSpaceEqualToColorSpace)(imageSpace, colorSpace);
    CGImageRef copy = matched ? wk_createImageMatchedToColorSpace(image, colorSpace) : NULL;
    if (!copy)
        copy = CGImageCreateCopy(image);
    if (!copy)
        return NULL;

    objc_sync_enter(lock);
    CFMutableArrayRef draws = (CFMutableArrayRef)(void *)objc_getAssociatedObject((id)image, wk_ioSurfaceImageDrawsKey());
    answer = wk_findImageForColorSpace(draws, colorSpace);
    if (!answer) {
        if (!draws) {
            draws = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
            if (draws) {
                objc_setAssociatedObject((id)image, wk_ioSurfaceImageDrawsKey(), (id)(void *)draws, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                CFRelease(draws);
            }
        }
        if (draws) {
            CFArrayAppendValue(draws, colorSpace);
            CFArrayAppendValue(draws, copy);
            answer = copy;
        }
    }
    objc_sync_exit(lock);
    CGImageRelease(copy);
    return answer;
}

// 10.9's IOSurface contexts are drawn by CoreAnimation, which draws nothing of an image wider or taller than
// its renderer's texture limit: the software renderer's is 16384 (CA::OGL::SWContext::get, checked in
// SWContext::bind_image_impl), a hardware renderer's is its GL_MAX_TEXTURE_SIZE
// (CA::OGL::CGLContext::update_limits). Modern CoreGraphics draws an image of any size, so an oversized
// image is drawn from the part the clip leaves visible, and when that part is itself over the limit, from
// tiles of it, each within the limit and clipped to its own share of the destination.
WK_SYSTEM_FN("OpenGL", int, CGLChoosePixelFormat, (const int *, void **, int *));
WK_SYSTEM_FN("OpenGL", int, CGLCreateContext, (void *, void *, void **));
WK_SYSTEM_FN("OpenGL", void *, CGLGetCurrentContext, (void));
WK_SYSTEM_FN("OpenGL", int, CGLSetCurrentContext, (void *));
WK_SYSTEM_FN("OpenGL", int, CGLDestroyContext, (void *));
WK_SYSTEM_FN("OpenGL", int, CGLDestroyPixelFormat, (void *));
WK_SYSTEM_FN("OpenGL", void, glGetIntegerv, (unsigned, int *));
extern bool CGContextGetShouldAntialias(CGContextRef);
extern CGRect CGStyleGetDrawBoundingBox(CGStyleRef, CGRect);

static int wk_rendererTextureLimit(const int *attributes)
{
    void *pixelFormat = NULL;
    int formats = 0;
    if (WK_SYSTEM(CGLChoosePixelFormat)(attributes, &pixelFormat, &formats) || !pixelFormat)
        return 0;
    int limit = 0;
    void *renderer = NULL;
    if (formats > 0 && !WK_SYSTEM(CGLCreateContext)(pixelFormat, NULL, &renderer) && renderer) {
        void *current = WK_SYSTEM(CGLGetCurrentContext)();
        if (!WK_SYSTEM(CGLSetCurrentContext)(renderer)) {
            const unsigned maxTextureSize = 0x0D33; // GL_MAX_TEXTURE_SIZE
            WK_SYSTEM(glGetIntegerv)(maxTextureSize, &limit);
            WK_SYSTEM(CGLSetCurrentContext)(current);
        }
        WK_SYSTEM(CGLDestroyContext)(renderer);
    }
    WK_SYSTEM(CGLDestroyPixelFormat)(pixelFormat);
    return limit;
}

static size_t wk_ioSurfaceTextureLimit_storage;
static void wk_build_ioSurfaceTextureLimit(void)
{
    // The pixel format CA::CG::IOSurfaceRenderer::acquire chooses with (its static attributes: colour size
    // 32, accelerated, no recovery, offline renderers allowed, 1262); without one it draws with its
    // software renderer.
    static const int acquireAttributes[] = { 8, 32, 73, 72, 96, 1262, 0 };
    static const int softwareAttributes[] = { 70, 0x00020400, 0 }; // kCGLPFARendererID, kCGLRendererGenericFloatID
    int limit = wk_rendererTextureLimit(acquireAttributes);
    if (limit <= 0)
        limit = wk_rendererTextureLimit(softwareAttributes);
    wk_ioSurfaceTextureLimit_storage = limit > 0 ? (size_t)limit : 0;
}

size_t wk_coreAnimationTextureLimit(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_build_ioSurfaceTextureLimit);
    return wk_ioSurfaceTextureLimit_storage;
}

static bool wk_drawOversizedImageInIOSurface(CGContextRef, CGRect, CGImageRef);

// Direct IOSurface contexts and asynchronous CA layer contexts share this renderer delegate.
extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
WK_SYSTEM_FN("IOSurface", IOSurfaceRef, IOSurfaceCreate, (CFDictionaryRef));
WK_SYSTEM_CONST("IOSurface", CFStringRef, kIOSurfaceWidth);
WK_SYSTEM_CONST("IOSurface", CFStringRef, kIOSurfaceHeight);
WK_SYSTEM_CONST("IOSurface", CFStringRef, kIOSurfaceBytesPerElement);
static const void *wk_coreAnimationIOSurfaceDelegateVTable;

static const void *wk_contextDelegateVTable(CGContextRef context)
{
    void *delegate = context ? CGContextGetDelegate(context) : NULL;
    void *info = delegate ? CGContextDelegateGetInfo(delegate) : NULL;
    return info ? *(const void **)info : NULL;
}

static void wk_learnIOSurfaceDelegate(void)
{
    int one = 1, pixelBytes = 4;
    CFNumberRef dimension = CFNumberCreate(NULL, kCFNumberIntType, &one);
    CFNumberRef bytes = CFNumberCreate(NULL, kCFNumberIntType, &pixelBytes);
    const void *keys[] = {
        WK_SYSTEM(kIOSurfaceWidth),
        WK_SYSTEM(kIOSurfaceHeight),
        WK_SYSTEM(kIOSurfaceBytesPerElement),
    };
    const void *values[] = { dimension, dimension, bytes };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = WK_SYSTEM(IOSurfaceCreate)(properties);
    CFRelease(properties);
    CFRelease(bytes);
    CFRelease(dimension);
    if (!surface)
        return;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGIOSurfaceContextCreate(surface, 1, 1, 8, 32, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    wk_coreAnimationIOSurfaceDelegateVTable = wk_contextDelegateVTable(context);
    if (context)
        CGContextRelease(context);
    CGColorSpaceRelease(space);
    CFRelease(surface);
}

bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef context)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_learnIOSurfaceDelegate);
    return wk_coreAnimationIOSurfaceDelegateVTable
        && wk_contextDelegateVTable(context) == wk_coreAnimationIOSurfaceDelegateVTable;
}

// An 8-bit bitmap context of another RGB colour space than a premultiplied 8-bit RGB image draws the image's
// per-space image, as an IOSurface context does. 10.9's bitmap route unpremultiplies at 8 bits and matches
// through an 8-bit table, which lands opaque levels up to 0.55 of a level from exact -- sRGB 7 becomes
// linear-sRGB 0 where it is 0.54 -- and translucent ones up to 5 levels away.
static bool wk_matchesBitmapDraw(CGContextRef context, CGImageRef image, CGColorSpaceRef *contextSpace)
{
    if (WK_SYSTEM(CGContextGetType)(context) != WK_CG_CONTEXT_TYPE_BITMAP || CGBitmapContextGetBitsPerComponent(context) != 8
        || (CGBitmapContextGetBitmapInfo(context) & kCGBitmapFloatComponents))
        return false;
    CGColorSpaceRef destination = CGBitmapContextGetColorSpace(context);
    CGColorSpaceRef source = CGImageGetColorSpace(image);
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    if (!destination || !source || CGImageIsMask(image) || CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32
        || (alpha != kCGImageAlphaPremultipliedFirst && alpha != kCGImageAlphaPremultipliedLast)
        || CGColorSpaceGetModel(destination) != kCGColorSpaceModelRGB || CGColorSpaceGetModel(source) != kCGColorSpaceModelRGB
        || WK_SYSTEM(CGColorSpaceEqualToColorSpace)(source, destination))
        return false;
    *contextSpace = destination;
    return true;
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDrawImage, (CGContextRef context, CGRect rect, CGImageRef image))
{
    CGColorSpaceRef bitmapSpace = NULL;
    if (context && image && wk_drawsThroughCoreAnimationIOSurface(context)) {
        CGColorSpaceRef colorSpace = CGContextGetColorSpace(context);
        CGImageRef copy = colorSpace ? wk_imageForDestinationColorSpace(image, colorSpace) : NULL;
        CGImageRef drawn = copy ? copy : image;
        if (!wk_drawOversizedImageInIOSurface(context, rect, drawn))
            WK_ORIGINAL(CGContextDrawImage)(context, rect, drawn);
    } else if (context && image && wk_matchesBitmapDraw(context, image, &bitmapSpace)) {
        CGImageRef copy = wk_imageForDestinationColorSpace(image, bitmapSpace);
        WK_ORIGINAL(CGContextDrawImage)(context, rect, copy ? copy : image);
    } else
        WK_ORIGINAL(CGContextDrawImage)(context, rect, image);
}

// CGContextClipToRect and CGContextClipToRects — DELIBERATE REPLACEMENTS of present 10.9 functions, for
// IOSurface contexts. 10.9 draws those through CoreAnimation, which drops a clip whose device-space extent
// is too large to rasterize: measured on this OS, a 40-unit-wide rect clips at a height of 2e9 and is
// ignored at 2e12 or at FloatRect::infiniteRect()'s FLT_MAX, while CGContextGetClipBoundingBox reports
// the clip applied. The clip is an intersection with the current one, so each rect is first intersected
// with the current clip's bounding box, which changes no clip and bounds every extent to the context.
static bool wk_boundsClipToContext(CGContextRef context)
{
    return context && wk_drawsThroughCoreAnimationIOSurface(context);
}

static CGRect wk_clipRectWithinClip(CGContextRef context, CGRect rect)
{
    CGRect bounded = CGRectIntersection(CGRectStandardize(rect), CGContextGetClipBoundingBox(context));
    return CGRectIsNull(bounded) ? CGRectZero : bounded;
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextClipToRect, (CGContextRef context, CGRect rect))
{
    if (wk_boundsClipToContext(context))
        rect = wk_clipRectWithinClip(context, rect);
    WK_ORIGINAL(CGContextClipToRect)(context, rect);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextClipToRects, (CGContextRef context, const CGRect *rects, size_t count))
{
    if (!wk_boundsClipToContext(context) || !rects || !count) {
        WK_ORIGINAL(CGContextClipToRects)(context, rects, count);
        return;
    }
    CGRect *bounded = (CGRect *)malloc(count * sizeof(CGRect));
    if (!bounded)
        abort();
    for (size_t i = 0; i < count; ++i)
        bounded[i] = wk_clipRectWithinClip(context, rects[i]);
    WK_ORIGINAL(CGContextClipToRects)(context, bounded, count);
    free(bounded);
}

// Image pixels run with the rect's x, and the image's first row lies along the rect's maxY edge.
static void wk_drawImagePart(CGContextRef context, CGRect rect, CGImageRef image, double left, double top, double right, double bottom)
{
    double pixelsPerUnitX = CGImageGetWidth(image) / rect.size.width;
    double pixelsPerUnitY = CGImageGetHeight(image) / rect.size.height;
    CGImageRef part = CGImageCreateWithImageInRect(image, CGRectMake(left, top, right - left, bottom - top));
    if (!part)
        return;
    CGRect partRect = CGRectMake(CGRectGetMinX(rect) + left / pixelsPerUnitX, CGRectGetMaxY(rect) - bottom / pixelsPerUnitY,
        (right - left) / pixelsPerUnitX, (bottom - top) / pixelsPerUnitY);
    WK_ORIGINAL(CGContextDrawImage)(context, partRect, part);
    CGImageRelease(part);
}

// Answers whether the draw was made here; false leaves it to 10.9, which draws an image within the limit.
static bool wk_drawOversizedImageInIOSurface(CGContextRef context, CGRect rect, CGImageRef image)
{
    size_t limit = wk_coreAnimationTextureLimit();
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!limit || (width <= limit && height <= limit))
        return false;
    if (CGImageIsMask(image) || !(rect.size.width > 0) || !(rect.size.height > 0))
        return false;

    // A style -- a shadow, a focus ring -- paints around what it is drawn with, so the part that matters is
    // the one whose styled output meets the clip. CGStyleGetDrawBoundingBox outsets a base-space rect by the
    // style's reach, the same distance on every side, which is also the farthest a source pixel outside the
    // clip can paint into it.
    CGAffineTransform ctm = CGContextGetCTM(context);
    CGRect clip = CGContextGetClipBoundingBox(context);
    CGStyleRef style = CGContextGetStyle(context);
    if (style) {
        CGRect reach = CGStyleGetDrawBoundingBox(style, CGRectApplyAffineTransform(clip, ctm));
        if (!CGRectIsNull(reach) && !CGRectIsInfinite(reach))
            clip = CGRectApplyAffineTransform(reach, CGAffineTransformInvert(ctm));
    }
    CGRect visible = CGRectIntersection(rect, clip);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible))
        return true;

    // The source pixels a filter reads beyond a part's edge: a couple, widened by how far the draw shrinks. A
    // tile's core still has to cover a destination pixel, which bounds the margin on either side of it.
    double pixelsPerUnitX = width / rect.size.width, pixelsPerUnitY = height / rect.size.height;
    double devicePerPixel = fmin(hypot(ctm.a, ctm.b) / pixelsPerUnitX, hypot(ctm.c, ctm.d) / pixelsPerUnitY);
    double pixelsPerDevicePixel = ceil(1 / fmin(devicePerPixel, 1));
    double margin = fmax(fmin(ceil(2 / fmin(devicePerPixel, 1)) + 2, floor((limit - pixelsPerDevicePixel) / 2)), 0);

    double left = fmax(floor((CGRectGetMinX(visible) - CGRectGetMinX(rect)) * pixelsPerUnitX) - margin, 0);
    double right = fmin(ceil((CGRectGetMaxX(visible) - CGRectGetMinX(rect)) * pixelsPerUnitX) + margin, width);
    double top = fmax(floor((CGRectGetMaxY(rect) - CGRectGetMaxY(visible)) * pixelsPerUnitY) - margin, 0);
    double bottom = fmin(ceil((CGRectGetMaxY(rect) - CGRectGetMinY(visible)) * pixelsPerUnitY) + margin, height);
    if (right <= left || bottom <= top)
        return true;
    if (right - left <= limit && bottom - top <= limit) {
        wk_drawImagePart(context, rect, image, left, top, right, bottom);
        return true;
    }

    // Tiles meet along image pixel boundaries. Each is clipped, without antialiasing, to its share of the
    // destination -- extended past the rect on the part's outer sides -- so every destination pixel is
    // painted by exactly one tile, and each tile carries the neighbours its filter reads. The tiles paint
    // into one transparency layer, so the context's alpha, blend mode and shadow apply to the image once.
    double core = limit - 2 * margin;
    bool antialias = CGContextGetShouldAntialias(context);
    CGContextBeginTransparencyLayerWithRect(context, visible, NULL);
    for (double rowStart = top; rowStart < bottom; rowStart += core) {
        double rowEnd = fmin(rowStart + core, bottom);
        double clipTop = rowStart == top ? CGRectGetMaxY(rect) + rect.size.height : CGRectGetMaxY(rect) - rowStart / pixelsPerUnitY;
        double clipBottom = rowEnd == bottom ? CGRectGetMinY(rect) - rect.size.height : CGRectGetMaxY(rect) - rowEnd / pixelsPerUnitY;
        for (double columnStart = left; columnStart < right; columnStart += core) {
            double columnEnd = fmin(columnStart + core, right);
            double clipLeft = columnStart == left ? CGRectGetMinX(rect) - rect.size.width : CGRectGetMinX(rect) + columnStart / pixelsPerUnitX;
            double clipRight = columnEnd == right ? CGRectGetMaxX(rect) + rect.size.width : CGRectGetMinX(rect) + columnEnd / pixelsPerUnitX;
            CGContextSaveGState(context);
            CGContextSetShouldAntialias(context, false);
            CGContextClipToRect(context, CGRectMake(clipLeft, clipBottom, clipRight - clipLeft, clipTop - clipBottom));
            CGContextSetShouldAntialias(context, antialias);
            wk_drawImagePart(context, rect, image, fmax(columnStart - margin, 0), fmax(rowStart - margin, 0),
                fmin(columnEnd + margin, width), fmin(rowEnd + margin, height));
            CGContextRestoreGState(context);
        }
    }
    CGContextEndTransparencyLayer(context);
    return true;
}

// CGContextDrawTiledImage and the pattern setters below draw a private copy of the pixels of a
// premultiplied image QuartzCore colour-matches. 10.9's software colour match
// (CA::OGL::SW::tex_color_match) unpremultiplies each sampled 8-bit pixel by its alpha to index a colour
// cube, and only when the alpha is not 255. At alpha 0 the reciprocal is +inf and the Newton step
// 0 * inf is NaN, which cvttss2si turns into INT_MIN, and the cube is read far out of bounds; any
// nonzero alpha stays in range through the cube's own upper clamp.
// So the dangerous pixel is one whose alpha samples to 0 (8-bit alpha 0, or a 16-bit alpha below
// 0x0100) with a colour that does not. The CGContextDrawImage replacement above escapes this: its
// per-colour-space image takes a route that never colour-matches. Tile and pattern draws use that image,
// which is unmatched by QuartzCore whenever it is in the destination's colour space.
//
// The image drawn has a direct provider that reads the source image's bytes when CoreGraphics asks for a
// range, through an access session, and cleans them in CoreGraphics' own buffer before answering, so each
// pixel CoreGraphics receives is cleaned from one read and every draw reads the backing as it is then.
// 10.9 asks for whole rows; a pixel a request holds only part of is read whole, and kept for the request
// that asks for the rest of it.
//
// Every premultiplied integer layout that reaches the colour match is copied: 8- and 16-bit-per-
// component colour-plus-alpha and grey-plus-alpha, alpha first or last, in every byte order, and an
// identity decode array (every pair {0, 1}), which 10.9 stores as none. Any other decode takes a route
// that does not index the cube with the stored alpha. A non-premultiplied image, a float image (32-bit
// float does not reach this index, and 10.9 cannot build a half-float CGImage), a mask, and a
// non-identity decode pass through untouched.

typedef struct {
    size_t pixelBytes;       // 2, 4 or 8
    size_t alphaByteOffset;  // first byte of the alpha component within a pixel
    size_t alphaByteCount;   // 1 or 2
    bool little;             // for a 16-bit alpha, the component's byte order
} wk_premultiplied_desc;

// Whether a decode array maps every component onto itself. 10.9 keeps two values per component of an
// image, alpha included.
static bool wk_identityDecode(const CGFloat *decode, size_t components)
{
    for (size_t i = 0; i < 2 * components; i += 2) {
        if (decode[i] != 0 || decode[i + 1] != 1)
            return false;
    }
    return true;
}

// Whether `image` is a premultiplied integer layout the colour cube can index out of bounds, and where
// its alpha sits in each stored pixel.
static bool wk_premultipliedDescribe(CGImageRef image, wk_premultiplied_desc *desc)
{
    if (CGImageIsMask(image))
        return false;
    CGBitmapInfo info = CGImageGetBitmapInfo(image);
    if (info & kCGBitmapFloatComponents)
        return false;
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    if (alpha != kCGImageAlphaPremultipliedFirst && alpha != kCGImageAlphaPremultipliedLast)
        return false;
    bool first = alpha == kCGImageAlphaPremultipliedFirst;
    size_t bpc = CGImageGetBitsPerComponent(image);
    size_t bpp = CGImageGetBitsPerPixel(image);
    if (bpc != 8 && bpc != 16)
        return false;
    if (bpp != bpc * 2 && bpp != bpc * 4)
        return false;   // grey+alpha (two components) or colour+alpha (four)
    size_t components = bpp / bpc;
    size_t componentBytes = bpc / 8;

    const CGFloat *decode = CGImageGetDecode(image);
    if (decode) {
        CGColorSpaceRef space = CGImageGetColorSpace(image);
        if (!space || CGColorSpaceGetNumberOfComponents(space) + 1 != components)
            return false;
        if (!wk_identityDecode(decode, components))
            return false;
    }

    size_t alphaComponent = first ? 0 : components - 1;
    CGBitmapInfo order = info & kCGBitmapByteOrderMask;
    desc->pixelBytes = bpp / 8;
    desc->alphaByteCount = componentBytes;
    if (componentBytes == 1) {
        // A four-byte pixel is one 32-bit word, reversed by 32Little. A two-byte pixel is reversed by
        // 16Little, and tagged 32Little it carries its alpha in the second byte, named first or last.
        if (desc->pixelBytes == 4)
            desc->alphaByteOffset = order == kCGBitmapByteOrder32Little ? 3 - alphaComponent : alphaComponent;
        else if (order == kCGBitmapByteOrder32Little)
            desc->alphaByteOffset = 1;
        else
            desc->alphaByteOffset = order == kCGBitmapByteOrder16Little ? 1 - alphaComponent : alphaComponent;
        desc->little = false;
    } else {
        // 16-bit components: 16Little stores each one little-endian in place; 32Little reverses each
        // 32-bit word, which swaps the two components in it and stores them little-endian; every other
        // order stores them big-endian in place.
        size_t stored = order == kCGBitmapByteOrder32Little ? alphaComponent ^ 1 : alphaComponent;
        desc->alphaByteOffset = stored * 2;
        desc->little = order == kCGBitmapByteOrder16Little || order == kCGBitmapByteOrder32Little;
    }
    return true;
}

static uint16_t wk_read16(const uint8_t *p, bool little)
{
    return little ? (uint16_t)(p[0] | (p[1] << 8)) : (uint16_t)((p[0] << 8) | p[1]);
}

static bool wk_pixelSamplesToAlphaZero(const uint8_t *pixel, const wk_premultiplied_desc *desc)
{
    if (desc->alphaByteCount == 1)
        return pixel[desc->alphaByteOffset] == 0;
    return wk_read16(pixel + desc->alphaByteOffset, desc->little) < 0x100;
}

// Zero the colour bytes of `pixel` when its alpha samples to 0.
static void wk_cleanPixel(uint8_t *pixel, const wk_premultiplied_desc *desc)
{
    if (!wk_pixelSamplesToAlphaZero(pixel, desc))
        return;
    for (size_t b = 0; b < desc->pixelBytes; b++) {
        if (b < desc->alphaByteOffset || b >= desc->alphaByteOffset + desc->alphaByteCount)
            pixel[b] = 0;
    }
}

// The access-session SPI is the reader CGDataProviderCopyData uses on 10.9.
WK_SYSTEM_FN("CoreGraphics", void *, CGAccessSessionCreate, (CGDataProviderRef));
WK_SYSTEM_FN("CoreGraphics", off_t, CGAccessSessionSkipForward, (void *, off_t));
WK_SYSTEM_FN("CoreGraphics", size_t, CGAccessSessionGetBytes, (void *, void *, size_t));
WK_SYSTEM_FN("CoreGraphics", void, CGAccessSessionRelease, (void *));

typedef struct {
    CGDataProviderRef source;
    size_t width;
    size_t height;
    size_t bytesPerRow;
    size_t length;           // height * bytesPerRow
    size_t required;         // through the last pixel of the last row
    wk_premultiplied_desc layout;
    pthread_mutex_t lock;
    bool haveKept;
    size_t keptStart;
    uint8_t kept[8];
} wk_premultiplied_provider;

// Reads up to `count` source bytes at `position`, answering how many it read.
static size_t wk_premultipliedReadSource(CGDataProviderRef source, uint8_t *out, size_t position, size_t count)
{
    void *session = WK_SYSTEM(CGAccessSessionCreate)(source);
    if (!session)
        return 0;
    size_t copied = 0;
    if ((size_t)WK_SYSTEM(CGAccessSessionSkipForward)(session, (off_t)position) == position) {
        while (copied < count) {
            size_t read = WK_SYSTEM(CGAccessSessionGetBytes)(session, out + copied, count - copied);
            if (!read)
                break;
            copied += read;
        }
    }
    WK_SYSTEM(CGAccessSessionRelease)(session);
    return copied;
}

static size_t wk_premultipliedGetBytesAtPosition(void *info, void *buffer, off_t offset, size_t count)
{
    wk_premultiplied_provider *provider = info;
    if (offset < 0 || (size_t)offset >= provider->length || !count)
        return 0;
    size_t start = (size_t)offset;
    if (count > provider->length - start)
        count = provider->length - start;
    size_t end = start + count;
    uint8_t *out = buffer;
    size_t read = wk_premultipliedReadSource(provider->source, out, start, count);
    if (read < count) {
        // Only the padding after the last row's pixels may be missing from the source.
        if (start + read < provider->required)
            return 0;
        memset(out + read, 0, count - read);
    }

    size_t pixelBytes = provider->layout.pixelBytes;
    pthread_mutex_lock(&provider->lock);
    for (size_t row = start / provider->bytesPerRow; row < provider->height; row++) {
        size_t rowStart = row * provider->bytesPerRow;
        if (rowStart >= end)
            break;
        size_t pixelsEnd = rowStart + provider->width * pixelBytes;
        size_t pixel = start > rowStart ? rowStart + (start - rowStart) / pixelBytes * pixelBytes : rowStart;
        for (; pixel < pixelsEnd && pixel < end; pixel += pixelBytes) {
            if (pixel >= start && pixel + pixelBytes <= end) {
                wk_cleanPixel(out + (pixel - start), &provider->layout);
                continue;
            }
            uint8_t whole[8];
            if (provider->haveKept && provider->keptStart == pixel)
                memcpy(whole, provider->kept, pixelBytes);
            else {
                if (wk_premultipliedReadSource(provider->source, whole, pixel, pixelBytes) < pixelBytes) {
                    pthread_mutex_unlock(&provider->lock);
                    return 0;
                }
                wk_cleanPixel(whole, &provider->layout);
                memcpy(provider->kept, whole, pixelBytes);
                provider->keptStart = pixel;
                provider->haveKept = true;
            }
            size_t from = pixel > start ? pixel : start;
            size_t to = pixel + pixelBytes < end ? pixel + pixelBytes : end;
            memcpy(out + (from - start), whole + (from - pixel), to - from);
        }
    }
    pthread_mutex_unlock(&provider->lock);
    return count;
}

static void wk_premultipliedReleaseProvider(void *info)
{
    wk_premultiplied_provider *provider = info;
    CGDataProviderRelease(provider->source);
    pthread_mutex_destroy(&provider->lock);
    free(provider);
}

static CGImageRef wk_premultipliedImage(CGImageRef image)
{
    wk_premultiplied_desc desc;
    if (!wk_premultipliedDescribe(image, &desc))
        return (CGImageRef)CGImageRetain(image);

    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image), stride = CGImageGetBytesPerRow(image);
    if (!height || !stride || width > SIZE_MAX / desc.pixelBytes || width * desc.pixelBytes > stride || height > INT64_MAX / stride)
        return NULL;
    wk_premultiplied_provider *info = calloc(1, sizeof(*info));
    if (!info)
        return NULL;
    info->source = CGDataProviderRetain(CGImageGetDataProvider(image));
    info->width = width;
    info->height = height;
    info->bytesPerRow = stride;
    info->length = height * stride;
    info->required = (height - 1) * stride + width * desc.pixelBytes;
    info->layout = desc;
    pthread_mutex_init(&info->lock, NULL);
    const CGDataProviderDirectCallbacks callbacks = {
        0, NULL, NULL, wk_premultipliedGetBytesAtPosition, wk_premultipliedReleaseProvider
    };
    CGDataProviderRef provider = CGDataProviderCreateDirect(info, (off_t)info->length, &callbacks);
    if (!provider) {
        wk_premultipliedReleaseProvider(info);
        return NULL;
    }
    CGImageRef result = CGImageCreate(width, height, CGImageGetBitsPerComponent(image),
        CGImageGetBitsPerPixel(image), CGImageGetBytesPerRow(image), CGImageGetColorSpace(image), CGImageGetBitmapInfo(image),
        provider, CGImageGetDecode(image), CGImageGetShouldInterpolate(image), CGImageGetRenderingIntent(image));
    CGDataProviderRelease(provider);
    return result;
}

// Tile and pattern draws share the destination-specific image cache with direct draws.
static CGImageRef wk_copyImageForIOSurfacePattern(CGContextRef context, CGImageRef image)
{
    CGColorSpaceRef destination = CGContextGetColorSpace(context);
    CGImageRef copy = destination ? wk_imageForDestinationColorSpace(image, destination) : NULL;
    if (!copy)
        return NULL;
    CGColorSpaceRef source = CGImageGetColorSpace(copy);
    if (source && WK_SYSTEM(CGColorSpaceEqualToColorSpace)(source, destination))
        return CGImageRetain(copy);
    return wk_premultipliedImage(copy);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextDrawTiledImage, (CGContextRef context, CGRect rect, CGImageRef image))
{
    CGImageRef drawn = NULL;
    if (context && image) {
        if (wk_drawsThroughCoreAnimationIOSurface(context))
            drawn = wk_copyImageForIOSurfacePattern(context, image);
    }
    WK_ORIGINAL(CGContextDrawTiledImage)(context, rect, drawn ? drawn : image);
    if (drawn)
        CGImageRelease(drawn);
}

extern CGPatternRef CGPatternCreateWithImage2(CGImageRef, CGAffineTransform, CGPatternTiling);
extern CGImageRef CGPatternGetImage(CGPatternRef);
extern CGAffineTransform CGPatternGetMatrix(CGPatternRef);
extern CGPatternTiling CGPatternGetTiling(CGPatternRef);

// Image patterns use the same IOSurface provider as direct image draws, retaining the pattern transform
// and tiling mode.
static bool wk_cleanedPattern(CGContextRef context, CGPatternRef pattern, CGPatternRef *replacement)
{
    *replacement = NULL;
    CGImageRef image = pattern ? CGPatternGetImage(pattern) : NULL;
    if (!context || !image)
        return false;
    if (!wk_drawsThroughCoreAnimationIOSurface(context))
        return false;
    CGImageRef cleaned = wk_copyImageForIOSurfacePattern(context, image);
    if (cleaned) {
        *replacement = CGPatternCreateWithImage2(cleaned, CGPatternGetMatrix(pattern), CGPatternGetTiling(pattern));
        CGImageRelease(cleaned);
    }
    return true;
}

// CGContextSetFillPattern, CGContextSetStrokePattern, CGContextSetFillColorWithColor and
// CGContextSetStrokeColorWithColor — DELIBERATE REPLACEMENTS of present 10.9 functions, for image
// patterns set on IOSurface contexts.
WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextSetFillPattern, (CGContextRef context, CGPatternRef pattern, const CGFloat *components))
{
    CGPatternRef replacement;
    if (!wk_cleanedPattern(context, pattern, &replacement)) {
        WK_ORIGINAL(CGContextSetFillPattern)(context, pattern, components);
        return;
    }
    WK_ORIGINAL(CGContextSetFillPattern)(context, replacement, components);
    if (replacement)
        CGPatternRelease(replacement);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextSetStrokePattern, (CGContextRef context, CGPatternRef pattern, const CGFloat *components))
{
    CGPatternRef replacement;
    if (!wk_cleanedPattern(context, pattern, &replacement)) {
        WK_ORIGINAL(CGContextSetStrokePattern)(context, pattern, components);
        return;
    }
    WK_ORIGINAL(CGContextSetStrokePattern)(context, replacement, components);
    if (replacement)
        CGPatternRelease(replacement);
}

// The pattern colour to set in place of `color`, or NULL to set `color` itself. `*replaced` says whether a
// replacement applies; a replacement that could not be made is NULL with `*replaced` true.
static CGColorRef wk_copyCleanedPatternColor(CGContextRef context, CGColorRef color, bool *replaced)
{
    *replaced = false;
    CGPatternRef pattern = color ? CGColorGetPattern(color) : NULL;
    if (!pattern)
        return NULL;
    CGPatternRef replacement;
    if (!wk_cleanedPattern(context, pattern, &replacement))
        return NULL;
    *replaced = true;
    if (!replacement)
        return NULL;
    CGColorRef result = CGColorCreateWithPattern(CGColorGetColorSpace(color), replacement, CGColorGetComponents(color));
    CGPatternRelease(replacement);
    return result;
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextSetFillColorWithColor, (CGContextRef context, CGColorRef color))
{
    bool replaced;
    CGColorRef replacement = wk_copyCleanedPatternColor(context, color, &replaced);
    WK_ORIGINAL(CGContextSetFillColorWithColor)(context, replaced ? replacement : color);
    if (replacement)
        CGColorRelease(replacement);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextSetStrokeColorWithColor, (CGContextRef context, CGColorRef color))
{
    bool replaced;
    CGColorRef replacement = wk_copyCleanedPatternColor(context, color, &replaced);
    WK_ORIGINAL(CGContextSetStrokeColorWithColor)(context, replaced ? replacement : color);
    if (replacement)
        CGColorRelease(replacement);
}

// Only a PDF context is tracked (wk_helpers.h): everything else returns before the lock, so a
// screen context's layers cost one type query here and nothing below.
static bool wk_transparencyLayerTracks(CGContextRef context)
{
    return context && WK_SYSTEM(CGContextGetType)(context) == WK_CG_CONTEXT_TYPE_PDF;
}

// The context is retained for as long as an entry exists. Core Graphics requires
// begin and end to balance, but nothing can enforce that a caller does not release a
// context with a layer still open; retaining means the address can never be recycled
// underneath a live entry, so a later context can never inherit a stale "inside a
// layer" answer and have its text silently converted to outlines.
void wk_transparencyLayerBegan(CGContextRef context)
{
    if (!wk_transparencyLayerTracks(context))
        return;
    pthread_mutex_lock(&wk_transparencyLayerLock);
    struct wk_transparency_layer_entry *entry = wk_transparencyLayerHead;
    while (entry && entry->context != context)
        entry = entry->next;
    if (entry) {
        entry->depth++;
        __atomic_fetch_add(&wk_transparencyLayerOpenCount, 1, __ATOMIC_RELEASE);
    } else if ((entry = (struct wk_transparency_layer_entry *)malloc(sizeof(*entry)))) {
        entry->context = CGContextRetain(context);
        entry->depth = 1;
        entry->next = wk_transparencyLayerHead;
        wk_transparencyLayerHead = entry;
        __atomic_fetch_add(&wk_transparencyLayerOpenCount, 1, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&wk_transparencyLayerLock);
}

void wk_transparencyLayerEnded(CGContextRef context)
{
    if (!context || !__atomic_load_n(&wk_transparencyLayerOpenCount, __ATOMIC_ACQUIRE))
        return;
    CGContextRef release = NULL;
    pthread_mutex_lock(&wk_transparencyLayerLock);
    struct wk_transparency_layer_entry **link = &wk_transparencyLayerHead;
    while (*link && (*link)->context != context)
        link = &(*link)->next;
    if (*link) {
        __atomic_fetch_sub(&wk_transparencyLayerOpenCount, 1, __ATOMIC_RELEASE);
        if (--(*link)->depth == 0) {
            struct wk_transparency_layer_entry *closed = *link;
            *link = closed->next;
            release = closed->context;
            free(closed);
        }
    }
    pthread_mutex_unlock(&wk_transparencyLayerLock);
    if (release)
        CGContextRelease(release);
}

bool wk_isInsideTransparencyLayer(CGContextRef context)
{
    if (!__atomic_load_n(&wk_transparencyLayerOpenCount, __ATOMIC_ACQUIRE))
        return false;
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
    WK_ORIGINAL(CGContextBeginTransparencyLayer)(context, auxiliaryInfo);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextBeginTransparencyLayerWithRect, (CGContextRef context, CGRect rect, CFDictionaryRef auxiliaryInfo))
{
    wk_transparencyLayerBegan(context);
    WK_ORIGINAL(CGContextBeginTransparencyLayerWithRect)(context, rect, auxiliaryInfo);
}

WK_POLYFILL_REPLACES("CoreGraphics", void, CGContextEndTransparencyLayer, (CGContextRef context))
{
    WK_ORIGINAL(CGContextEndTransparencyLayer)(context);
    wk_transparencyLayerEnded(context);
}

// The display's Metal device, absent from 10.9 CoreGraphics along with Metal itself (see Metal.c). nil
// is the same "this display has no Metal device" answer MTLCreateSystemDefaultDevice gives, and ANGLE's
// GetGPUInformation falls through to its CGL/IOKit path on it.
WK_POLYFILL_ABSENT("CoreGraphics", id, CGDirectDisplayCopyCurrentMetalDevice, (CGDirectDisplayID displayID))
{ (void)displayID; return nil; }

// The 10.10+ non-varargs form of the scroll-wheel event constructor. 10.9 CoreGraphics exports only
// CGEventCreateScrollWheelEvent, which takes the same source, unit, wheel count and per-wheel deltas
// through a varargs list, so forwarding to it reproduces the entry point exactly.
WK_POLYFILL_ABSENT("CoreGraphics", CGEventRef, CGEventCreateScrollWheelEvent2, (CGEventSourceRef source, CGScrollEventUnit units, uint32_t wheelCount, int32_t wheel1, int32_t wheel2, int32_t wheel3))
{
    return CGEventCreateScrollWheelEvent(source, units, wheelCount, wheel1, wheel2, wheel3);
}
