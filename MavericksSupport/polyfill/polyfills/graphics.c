// CoreGraphics, CoreText, QuartzCore, Accelerate, ImageIO, CoreMedia and IOKit entry points modern WebKit calls
// that 10.9 lacks or names differently. Each is implemented over the equivalent API 10.9 does ship,
// or reports the honest "this OS has no such feature" answer where the feature itself postdates 10.9.
#include "wk_polyfill.h"

#include "LegacyCoreTextVariableFontInstancer.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <math.h>
#include <objc/message.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

// vImage's premultiply math touches the three colour bytes and leaves alpha, so it is
// identical for BGRA8888 and RGBA8888; the BGRA-named entry points forward to the RGBA ones.
// We only pass the buffers through, so vImage_Buffer stays opaque -- no Accelerate header.
typedef unsigned long vImage_Flags;
typedef long vImage_Error;
struct vImage_Buffer;
enum { kvImageInternalError = -21058 };
WK_SYSTEM_FN("Accelerate", vImage_Error, vImagePremultiplyData_RGBA8888,
    (const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags));
WK_SYSTEM_FN("Accelerate", vImage_Error, vImageUnpremultiplyData_RGBA8888,
    (const struct vImage_Buffer *, const struct vImage_Buffer *, vImage_Flags));

WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImagePremultiplyData_BGRA8888,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags))
{
    if (!WK_SYSTEM(vImagePremultiplyData_RGBA8888))
        return kvImageInternalError;
    return WK_SYSTEM(vImagePremultiplyData_RGBA8888)(src, dst, flags);
}
WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImageUnpremultiplyData_BGRA8888,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, vImage_Flags flags))
{
    if (!WK_SYSTEM(vImageUnpremultiplyData_RGBA8888))
        return kvImageInternalError;
    return WK_SYSTEM(vImageUnpremultiplyData_RGBA8888)(src, dst, flags);
}

// CTFontGetSbixImageSizeForGlyphAndContentsScale (10.13+) reports the pixel size of the sbix
// (Apple colour-bitmap) strike a glyph would be drawn from, and zero when the glyph has no sbix
// entry -- which is what WebCore reads it for (Font::glyphHasComplexColorFormat). 10.9's CoreText
// hands the sbix table out through CTFontCopyTable, so the answer is read from the table.
//
// sbix layout (Apple TrueType reference): u16 version, u16 flags, u32 numStrikes,
// u32 strikeOffsets[numStrikes] from the table start; each strike is u16 ppem, u16 resolution,
// u32 glyphDataOffsets[numGlyphs + 1] from the strike start. A glyph has a bitmap in a strike iff
// its offset pair is non-empty.
static uint16_t wk_be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t wk_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontGetSbixImageSizeForGlyphAndContentsScale,
                   (CTFontRef font, const CGGlyph glyph, CGFloat contentsScale))
{
    if (!font)
        return 0;
    CFIndex glyphCount = CTFontGetGlyphCount(font);
    if (glyphCount <= 0 || glyph >= glyphCount)
        return 0;
    CFDataRef sbix = CTFontCopyTable(font, kCTFontTableSbix, kCTFontTableOptionNoOptions);
    if (!sbix)
        return 0;

    const uint8_t *bytes = CFDataGetBytePtr(sbix);
    CFIndex length = CFDataGetLength(sbix);
    double wanted = CTFontGetSize(font) * (contentsScale > 0 ? contentsScale : 1);
    double best = 0;
    double largest = 0;

    if (bytes && length >= 8) {
        uint32_t strikeCount = wk_be32(bytes + 4);
        // Each strike offset is 4 bytes and each strike needs at least its own header.
        if ((CFIndex)strikeCount <= (length - 8) / 4) {
            for (uint32_t i = 0; i < strikeCount; ++i) {
                uint32_t strikeOffset = wk_be32(bytes + 8 + i * 4);
                // ppem + resolution + one offset per glyph plus the terminating offset.
                CFIndex needed = 4 + ((CFIndex)glyphCount + 1) * 4;
                if ((CFIndex)strikeOffset > length - needed)
                    continue;
                const uint8_t *strike = bytes + strikeOffset;
                uint32_t start = wk_be32(strike + 4 + (CFIndex)glyph * 4);
                uint32_t end = wk_be32(strike + 4 + ((CFIndex)glyph + 1) * 4);
                if (end <= start)
                    continue;
                double ppem = wk_be16(strike);
                if (ppem > largest)
                    largest = ppem;
                if (ppem >= wanted && (best == 0 || ppem < best))
                    best = ppem;
            }
        }
    }

    CFRelease(sbix);
    return best ? best : largest;
}

// CVBufferCopyAttachments (macOS 12) is CVBufferGetAttachments with +1 ownership.
WK_SYSTEM_FN("CoreVideo", CFDictionaryRef, CVBufferGetAttachments, (CVBufferRef, CVAttachmentMode));
WK_POLYFILL_ABSENT("CoreVideo", CFDictionaryRef, CVBufferCopyAttachments, (CVBufferRef buffer, CVAttachmentMode mode))
{
    if (!WK_SYSTEM(CVBufferGetAttachments))
        return NULL;
    CFDictionaryRef attachments = WK_SYSTEM(CVBufferGetAttachments)(buffer, mode);
    return attachments ? CFDictionaryCreateCopy(kCFAllocatorDefault, attachments) : NULL;
}

// CGPathAddUnevenCornersRoundedRect is macOS 10.13+. It appends a closed rounded-rect subpath whose four
// corners may each have their own radii, in CoreGraphics' corner order: [0] bottom-left, [1] bottom-right,
// [2] top-right, [3] top-left (PathCG.cpp fills the array in exactly that order). Built from four
// elliptical quadrants joined by straight edges, following CGPathAddRoundedRect's own seam: start at the
// midpoint of the right edge, run counter-clockwise, and close from the bottom-right quadrant's end back
// up to the start, so a path built with it strokes (dash phase included) and fills identically. The
// transform is applied by CoreGraphics to every element, as it is for CGPathAddRoundedRect.
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
    CGPathAddLineToPoint(path, transform, maxX, maxY - trh);
    CGPathAddCurveToPoint(path, transform, maxX, maxY - trh + trh * WK_KAPPA,
        maxX - trw + trw * WK_KAPPA, maxY, maxX - trw, maxY);
    CGPathAddLineToPoint(path, transform, minX + tlw, maxY);
    CGPathAddCurveToPoint(path, transform, minX + tlw - tlw * WK_KAPPA, maxY,
        minX, maxY - tlh + tlh * WK_KAPPA, minX, maxY - tlh);
    CGPathAddLineToPoint(path, transform, minX, minY + blh);
    CGPathAddCurveToPoint(path, transform, minX, minY + blh - blh * WK_KAPPA,
        minX + blw - blw * WK_KAPPA, minY, minX + blw, minY);
    CGPathAddLineToPoint(path, transform, maxX - brw, minY);
    CGPathAddCurveToPoint(path, transform, maxX - brw + brw * WK_KAPPA, minY,
        maxX, minY + brh - brh * WK_KAPPA, maxX, minY + brh);
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

// vImageCopyBuffer (10.10+) copies the overlapping region of two buffers row by row, honouring each
// buffer's own rowBytes. That needs the field layout, which the ABI has fixed since 10.3.
struct wk_vImage_Buffer { void *data; unsigned long height; unsigned long width; size_t rowBytes; };
enum { kvImageNoError = 0 };
WK_POLYFILL_ABSENT("Accelerate", vImage_Error, vImageCopyBuffer,
    (const struct vImage_Buffer *src, const struct vImage_Buffer *dst, size_t pixelSize, vImage_Flags flags))
{
    const struct wk_vImage_Buffer *s = (const struct wk_vImage_Buffer *)src;
    const struct wk_vImage_Buffer *d = (const struct wk_vImage_Buffer *)dst;
    (void)flags;
    if (!s || !d || !s->data || !d->data)
        return kvImageInternalError;
    unsigned long rows = s->height < d->height ? s->height : d->height;
    unsigned long cols = s->width < d->width ? s->width : d->width;
    size_t bytes = (size_t)cols * pixelSize;
    for (unsigned long row = 0; row < rows; ++row)
        memcpy((unsigned char *)d->data + row * d->rowBytes, (const unsigned char *)s->data + row * s->rowBytes, bytes);
    return kvImageNoError;
}

// IOMainPort (the macOS 12.0 rename of IOMasterPort) has no 10.9 runtime symbol; forward to
// IOMasterPort, which 10.9 ships. Both are declared in the 26.1 SDK's IOKitLib.h, so WebCore can call
// the upstream IOMainPort name unchanged (platform/graphics/mac/GraphicsChecksMac.cpp).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
WK_SYSTEM_FN("IOKit", kern_return_t, IOMasterPort, (mach_port_t, mach_port_t *));
WK_POLYFILL_ABSENT("IOKit", kern_return_t, IOMainPort, (mach_port_t bootstrapPort, mach_port_t *mainPort))
{
    if (!WK_SYSTEM(IOMasterPort))
        return KERN_FAILURE;
    return WK_SYSTEM(IOMasterPort)(bootstrapPort, mainPort);
}
#pragma clang diagnostic pop

// Additional newer-OS C entry points absent at RUNTIME on 10.9, reached by unmodified upstream
// WebCore call sites. Each is declared either by WebKit's own PAL SPI header (the CG/CT ones) or by
// the 26.1 SDK; here we supply the missing definition via the classic 10.9 API so the upstream source
// links and runs (and its in-tree 10.9 workaround reverts to upstream).

// CTFontCreateForCharactersWithLanguage is itself CoreText SPI (declared in WebKit's PAL
// CoreTextSPI.h, not the public SDK headers); forward-declare it so the forwarding impl below compiles.
extern CTFontRef CTFontCreateForCharactersWithLanguage(CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, CFIndex *coveredLength);

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

// The option key itself is one of this layer's constants (polyfills/constants.m); 10.9's SDK, which this
// file compiles against, does not declare it.
extern const CFStringRef kCGGradientInterpolatesPremultiplied;

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

// CTFontCreateForCharactersWithLanguageAndOption (10.13+): the option only restricts fallback to
// system (non-user-installed) fonts. The classic CTFontCreateForCharactersWithLanguage returns the
// same fallback font on 10.9 and is present there.
WK_SYSTEM_FN("CoreText", bool, CTFontManagerRegisterFontsForURLs, (CFArrayRef, CTFontManagerScope, CFArrayRef *));
WK_SYSTEM_FN("CoreText", CFArrayRef, CTFontManagerCreateFontDescriptorsFromURL, (CFURLRef));
WK_SYSTEM_FN("CoreText", void, CTFontManagerEnableFontDescriptors, (CFArrayRef, bool));

WK_POLYFILL_ABSENT("CoreText", CTFontRef, CTFontCreateForCharactersWithLanguageAndOption,
    (CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, unsigned long option, CFIndex *coveredLength))
{
    (void)option;
    return CTFontCreateForCharactersWithLanguage(currentFont, characters, length, language, coveredLength);
}

// Variable fonts. 10.9's CoreText cannot instance one. Two behaviours were measured on 10.9.5
// (with Amstelvar-Roman-VF104, whose 'H' advances 87.0 units at wght=400 and 97.1 at wght=900):
//
//   * realizing a descriptor that carries kCTFontVariationAttribute silently ignores it and
//     yields the fvar default master (advance 87.0 whatever wght is asked for), and
//   * the one path CoreText does route variations through — CTFontCreateWithGraphicsFont with
//     that attribute, which reaches CGFontCreateCopyWithVariations — collapses every outline:
//     advance 0, bounding box 0x0.
//
// CGFontCreateCopyWithVariations is the function that is actually broken, but replacing it would
// fix nothing: WebKit never calls it, and this layer is scoped to WebKit's own images (hidden
// visibility, force_load), so CoreText's internal call to it can never reach our definition.
// The reachable entry point is the descriptor realization below, and that is what is replaced.
//
// The two halves work together. CTFontManagerCreateFontDescriptorFromData is where the layer sees
// a web font's sfnt bytes, so it stashes them on the descriptor it returns under a private key;
// CTFontDescriptorCreateCopyWithAttributes, which is how every caller narrows a descriptor,
// carries unknown attributes through unchanged (measured), so the bytes are still there when the
// descriptor is realized with a variation dictionary. The realization then software-cuts a static
// instance at the requested axis values and builds the font from that.
#define WK_LEGACY_VARIABLE_FONT_SOURCE_KEY CFSTR("WKMavericksLegacyVariableFontSourceSFNT")

// CTFontManagerCreateFontDescriptorFromData — a DELIBERATE REPLACEMENT of a present-but-broken 10.9
// function. The 10.9 implementation returns
// descriptors that crash when realized: TFontFeatures loading (TBaseFont::CopyFeatures →
// CreateFontWithFontURL) message-sends a freed object for many downloaded fonts (DDG and
// others). Descriptors built from a CGFont avoid TFontFeatures setup entirely, so the
// replacement round-trips the data through CGFontCreateWithDataProvider →
// CTFontCreateWithGraphicsFont → CTFontCopyFontDescriptor. Costs on this path (accepted):
// CTFontCopyVariationAxes returns null and font-feature-settings are skipped.
// Data a CGFont cannot parse falls through to the real CoreText implementation so exotic
// inputs keep exact system behavior.
//
// For a variable font the descriptor describes the default master — the variation tables are
// stripped, so that CoreGraphics reads a plain static font — and the original bytes ride along
// under WK_LEGACY_VARIABLE_FONT_SOURCE_KEY for CTFontCreateWithFontDescriptor to instance from.
WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontManagerCreateFontDescriptorFromData, (CFDataRef data))
{
    if (data) {
        bool variable = wk_legacy_variable_font_is_instanceable(data);
        CFDataRef master = variable ? wk_legacy_variable_font_strip_variations(data) : (CFDataRef)CFRetain(data);
        CGDataProviderRef provider = master ? CGDataProviderCreateWithCFData(master) : NULL;
        if (master)
            CFRelease(master);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
            if (cgFont) {
                CTFontRef ctFont = CTFontCreateWithGraphicsFont(cgFont, 12.0, NULL, NULL);
                CGFontRelease(cgFont);
                if (ctFont) {
                    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(ctFont);
                    CFRelease(ctFont);
                    if (descriptor && variable) {
                        CFMutableDictionaryRef source = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                        CFDictionarySetValue(source, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY, data);
                        CTFontDescriptorRef withSource = CTFontDescriptorCreateCopyWithAttributes(descriptor, source);
                        CFRelease(source);
                        if (withSource) {
                            CFRelease(descriptor);
                            descriptor = withSource;
                        }
                    }
                    if (descriptor)
                        return descriptor;
                }
            }
        }
    }
    return WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)
        ? WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data) : NULL;
}

// The size CoreText would use for a descriptor realized at `size`: an explicit size wins, then the
// descriptor's own kCTFontSizeAttribute, then CoreText's 12pt default.
static CGFloat wk_sizeForRealizedFont(CTFontDescriptorRef descriptor, CGFloat size)
{
    if (size > 0)
        return size;
    CFNumberRef sizeAttribute = (CFNumberRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontSizeAttribute);
    if (sizeAttribute) {
        double descriptorSize = 0;
        bool valid = CFGetTypeID(sizeAttribute) == CFNumberGetTypeID()
            && CFNumberGetValue(sizeAttribute, kCFNumberDoubleType, &descriptorSize) && descriptorSize > 0;
        CFRelease(sizeAttribute);
        if (valid)
            return (CGFloat)descriptorSize;
    }
    return 12.0;
}

// The descriptor's attributes minus everything that names or sizes the font: what identity the cut
// instance has is settled by the CGFont it is built from, and the variations have been baked in.
// Whatever else the caller asked for (feature settings, palettes, …) is passed on untouched.
static CTFontDescriptorRef wk_descriptorAttributesToCarryOver(CTFontDescriptorRef descriptor)
{
    CFDictionaryRef attributes = CTFontDescriptorCopyAttributes(descriptor);
    if (!attributes)
        return NULL;
    CFMutableDictionaryRef remaining = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFRelease(attributes);
    CFDictionaryRemoveValue(remaining, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    CFDictionaryRemoveValue(remaining, kCTFontVariationAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontNameAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontFamilyNameAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontSizeAttribute);
    CTFontDescriptorRef result = CFDictionaryGetCount(remaining) ? CTFontDescriptorCreateWithAttributes(remaining) : NULL;
    CFRelease(remaining);
    return result;
}

// Realizes a variable font at the axis values its descriptor asks for, or returns NULL to let
// 10.9's own realization run. NULL is the answer for every font that is not a variable web font
// this layer created the descriptor for, and for every request that lands on the fvar defaults.
static CTFontRef wk_realizeVariableFontInstance(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix)
{
    if (!descriptor)
        return NULL;
    CFDataRef sourceData = (CFDataRef)CTFontDescriptorCopyAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    if (!sourceData)
        return NULL;

    CTFontRef font = NULL;
    CFDictionaryRef variations = (CFDictionaryRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAttribute);
    CFDataRef instance = wk_legacy_variable_font_instance(sourceData, variations);
    if (instance) {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(instance);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
            if (cgFont) {
                CTFontDescriptorRef carriedOver = wk_descriptorAttributesToCarryOver(descriptor);
                font = CTFontCreateWithGraphicsFont(cgFont, wk_sizeForRealizedFont(descriptor, size), matrix, carriedOver);
                if (carriedOver)
                    CFRelease(carriedOver);
                CGFontRelease(cgFont);
            }
        }
        CFRelease(instance);
    }
    if (variations)
        CFRelease(variations);
    CFRelease(sourceData);
    return font;
}

// CTFontCreateWithFontDescriptor / ...AndOptions — DELIBERATE REPLACEMENTS of present-but-broken
// 10.9 functions: they are where a descriptor's kCTFontVariationAttribute is meant to take effect
// and where 10.9 instead drops it (see the block comment above). Everything that is not a variable
// web font realizes through 10.9's own implementation, unchanged.
WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithFontDescriptor,
                     (CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix))
{
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix);
    if (instance)
        return instance;
    return WK_ORIGINAL(CTFontCreateWithFontDescriptor)
        ? WK_ORIGINAL(CTFontCreateWithFontDescriptor)(descriptor, size, matrix) : NULL;
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithFontDescriptorAndOptions,
                     (CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CFOptionFlags options))
{
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix);
    if (instance)
        return instance;
    return WK_ORIGINAL(CTFontCreateWithFontDescriptorAndOptions)
        ? WK_ORIGINAL(CTFontCreateWithFontDescriptorAndOptions)(descriptor, size, matrix, options) : NULL;
}

// libFontParser's FPFont* system font parser, which WebCore uses to split a downloaded font file
// into its constituent fonts and take the chosen one's canonical sfnt bytes. Asked of the running
// 10.9 through dlsym: FPFontCopyPostScriptName is there, FPFontCreateFontsFromData and
// FPFontCopySFNTData are not.
//
// 10.9 has no font-collection parser to stand in for the missing pair, so the polyfill's answer is
// the honest one for a machine without one: the data is a single font, and its sfnt bytes are the
// bytes themselves. An FPFontRef here is therefore the CFData, and the two functions that consume
// one recognise that. Since 10.9 does export FPFontCopyPostScriptName, that one is a replacement
// and hands anything it does not recognise back to the system implementation.
typedef const struct __FPFont* FPFontRef;

WK_POLYFILL_ABSENT("CoreText", CFArrayRef, FPFontCreateFontsFromData, (CFDataRef data))
{
    if (!data)
        return NULL;
    // Upstream reads an empty result as "something is wrong with the font" and rejects the
    // @font-face outright, so the parse has to be attempted here rather than deferred. Accept
    // exactly what CTFontManagerCreateFontDescriptorFromData above accepts: CoreGraphics' parser
    // first, then 10.9's own for the data it cannot read.
    bool usable = false;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    if (provider) {
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (cgFont) {
            CGFontRelease(cgFont);
            usable = true;
        }
    }
    if (!usable && WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)) {
        CTFontDescriptorRef descriptor = WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data);
        if (descriptor) {
            CFRelease(descriptor);
            usable = true;
        }
    }
    if (!usable)
        return NULL;
    const void *values[1] = { data };
    return CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
}

WK_POLYFILL_ABSENT("CoreText", CFDataRef, FPFontCopySFNTData, (FPFontRef font))
{
    if (font && CFGetTypeID((CFTypeRef)font) == CFDataGetTypeID())
        return (CFDataRef)CFRetain((CFTypeRef)font);
    return NULL;
}

WK_POLYFILL_REPLACES("CoreText", CFStringRef, FPFontCopyPostScriptName, (FPFontRef font))
{
    if (font && CFGetTypeID((CFTypeRef)font) == CFDataGetTypeID()) {
        CFStringRef name = NULL;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)font);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
            if (cgFont) {
                name = CGFontCopyPostScriptName(cgFont);
                CGFontRelease(cgFont);
            }
        }
        return name;
    }
    return WK_ORIGINAL(FPFontCopyPostScriptName) ? WK_ORIGINAL(FPFontCopyPostScriptName)(font) : NULL;
}
#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------------
// CoreGraphics
// ---------------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------------
// CoreText — text rendering hits these live; where 10.9 ships an equivalent, the body calls through to it.
// ---------------------------------------------------------------------------------------------------

// Color-glyph coverage bit vectors (color emoji / feature coverage). 10.9 lacks both; callers guard
// the null return (FontCoreText only proceeds "if (bitVector)").
// CTFontManagerRegisterFontURLs (10.15) is the block-callback replacement for
// CTFontManagerRegisterFontsForURLs, which 10.9 HAS (nm-verified, alongside the singular
// _CTFontManagerRegisterFontsForURL). The modern spelling is a strict superset: same URLs, same
// scope, plus an `enabled` flag and a handler that may be called several times with `done` marking
// the last. The old call is synchronous and reports every failure in one out-parameter array, so a
// faithful emulation registers, then invokes the handler EXACTLY once with those errors and
// done=true. The handler's bool result asks whether to continue; nothing remains to continue after a
// synchronous call, so it is read and discarded.
//
// `enabled` is NOT dropped. It means "should the font participate in descriptor matching", and 10.9
// spells that with CTFontManagerEnableFontDescriptors (10.6+, nm-verified), fed by
// CTFontManagerCreateFontDescriptorsFromURL (10.6+, nm-verified) per URL. So enabled=false is
// registered and then disabled, which is the modern behaviour rather than an approximation of it.
// Verified on this host with a font the process does not otherwise have (LayoutTests Ahem.ttf):
// process-scope registration makes the family visible, CTFontManagerEnableFontDescriptors(descs,
// false) makes it invisible again, and Enable(true) restores it -- so it genuinely suppresses the
// PROCESS-scope registration. Measured again with a system-installed family (Al Bayan): the same
// sequence leaves it visible throughout, and a FRESH process still sees it, so it writes no
// persistent user-visible font-activation state. Refusing enabled=false with a synthesized CFError
// would invent a failure for something the OS can do.
WK_POLYFILL_ABSENT("CoreText", void, CTFontManagerRegisterFontURLs,
    (CFArrayRef fontURLs, CTFontManagerScope scope, bool enabled,
     bool (^registrationHandler)(CFArrayRef errors, bool done)))
{
    CFArrayRef errors = NULL;

    // WK_SYSTEM() is NULL when the provider cannot be dlopened or the symbol is missing; calling
    // through it unchecked would be a branch to address 0, the very fault this layer exists to stop.
    if (!WK_SYSTEM(CTFontManagerRegisterFontsForURLs)) {
        CFStringRef descKeys[] = { kCFErrorLocalizedDescriptionKey, kCTFontManagerErrorFontURLsKey };
        const void *descValues[] = { CFSTR("CoreText's font registration entry point is unavailable"), fontURLs };
        CFDictionaryRef userInfo = CFDictionaryCreate(kCFAllocatorDefault, (const void **)descKeys,
            descValues, fontURLs ? 2 : 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFErrorRef error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainPOSIX, ENOTSUP, userInfo);
        if (userInfo)
            CFRelease(userInfo);
        if (error) {
            const void *one[] = { error };
            errors = CFArrayCreate(kCFAllocatorDefault, one, 1, &kCFTypeArrayCallBacks);
            CFRelease(error);
        }
    } else {
        WK_SYSTEM(CTFontManagerRegisterFontsForURLs)(fontURLs, scope, &errors);

        // Registration on 10.9 always enables; take the fonts back out of descriptor matching when
        // the caller asked for enabled=false, which is what the modern flag means.
        if (!enabled && fontURLs && WK_SYSTEM(CTFontManagerCreateFontDescriptorsFromURL) && WK_SYSTEM(CTFontManagerEnableFontDescriptors)) {
            CFIndex count = CFArrayGetCount(fontURLs);
            for (CFIndex i = 0; i < count; i++) {
                CFArrayRef descriptors = WK_SYSTEM(CTFontManagerCreateFontDescriptorsFromURL)((CFURLRef)CFArrayGetValueAtIndex(fontURLs, i));
                if (!descriptors)
                    continue;
                WK_SYSTEM(CTFontManagerEnableFontDescriptors)(descriptors, false);
                CFRelease(descriptors);
            }
        }
    }

    if (registrationHandler) {
        CFArrayRef reported = errors;
        CFArrayRef empty = NULL;
        if (!reported) {
            empty = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
            reported = empty;   // the modern handler documents an EMPTY array as "no errors", never NULL
        }
        (void)registrationHandler(reported, true);
        if (empty)
            CFRelease(empty);
    }
    if (errors)
        CFRelease(errors);
}

WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyColorGlyphCoverage, (CTFontRef font))
{
    (void)font;
    return NULL;
}

// CTFontCopyGlyphCoverageForFeature (10.13+) answers WHICH GLYPHS a given font feature acts on. 10.9
// exposes no equivalent: CTFontCopyFeatures lists a font's features but never their per-glyph coverage,
// and recovering that would mean parsing the font's own GSUB/morx lookup and coverage tables.
//
// So the honest answer is an EMPTY coverage set — "this OS cannot report any covered glyph" — and the
// important part is that it is a real, valid CFBitVector rather than NULL: upstream's
// unionBitVectors() hands the result straight to CFBitVectorGetCount() with no null check, so NULL
// crashes there. An empty vector makes that call answer 0 and the union contribute nothing.
//
// Consequence, stated plainly: Font::supportsSmallCaps() sees no covered glyphs and answers NO, so
// WebKit synthesizes small capitals instead of using a font's own small-cap glyphs. That is a real
// degradation, it is what this port already did, and it is confined to appearance.
//
// Note the contrast with CTFontCopyColorGlyphCoverage just above, which legitimately returns NULL:
// upstream null-checks THAT one at its call site (FontCoreText.cpp wraps it in `if (RetainPtr ...)`),
// so NULL is a value upstream expects there.
WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyGlyphCoverageForFeature, (CTFontRef font, CFDictionaryRef feature))
{
    (void)font; (void)feature;
    return CFBitVectorCreate(kCFAllocatorDefault, NULL, 0);
}

// CSS generic family -> concrete 10.9 font descriptor. The cssFamily argument is one of the
// kCTFontCSSFamily* constants supplied by constants.m (its value is its own name). Map each to a
// font that ships on 10.9 so generic families (serif/sans-serif/monospace/cursive/fantasy) resolve.
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateForCSSFamily, (CFStringRef cssFamily, CFStringRef language))
{
    (void)language;
    if (!cssFamily)
        return NULL;
    CFStringRef name = NULL;
    if (CFStringHasSuffix(cssFamily, CFSTR("Serif")) && !CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Times");
    else if (CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Helvetica");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Monospace")))
        name = CFSTR("Courier");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Cursive")))
        name = CFSTR("Apple Chancery");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Fantasy")))
        name = CFSTR("Papyrus");
    if (!name)
        return NULL;
    return CTFontDescriptorCreateWithNameAndSize(name, 0.0);
}

// "Last Resort" tofu fallback font descriptor. The LastResort font ships on 10.9.
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateLastResort, (void))
{
    return CTFontDescriptorCreateWithNameAndSize(CFSTR("LastResort"), 0.0);
}

// Dynamic-Type text-style descriptor (style/size/language). 10.9 has no Dynamic Type; return the
// system UI font's descriptor so system/caption text resolves to a real font.
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateWithTextStyle, (CFStringRef style, CFStringRef size, CFStringRef language))
{
    (void)style; (void)size; (void)language;
    CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 0.0, NULL);
    if (!system)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(system);
    CFRelease(system);
    return descriptor;
}

// CTFontDescriptorGetTextStyleSize (10.10+): the default point size (return value) and weight (out-param,
// on the CTFontWeight -1..1 scale) for a Dynamic-Type text style at a content-size category. 10.9 has no
// Dynamic Type — a single, non-scaling size class — so return the documented default ("Large" category)
// metrics for each -apple-system-* text style; the family itself resolves to the plain system font via
// CTFontDescriptorCreateWithTextStyle above. The style keys arrive as the polyfilled kCTUIFontTextStyle*
// CFStrings (constants.m), whose values are their own token names, so match on that text. sizeCategory and
// platform are irrelevant on 10.9 (fontPlatform() is kCTFontTextStylePlatformDefault here). Only Headline /
// ShortHeadline are semibold (0.3); every other style is regular (0.0). Sizes are the standard Dynamic-Type
// point sizes (Body/Headline 17, Subhead 15, Footnote 13, Caption1 12, Caption2 11, Title1 28, Title2 22,
// Title3 20); the short/tall variants share their base style's point size (they differ only in leading),
// and the non-standard Title0 (largest) / Title4 (a step below Title3) take 34 / 18.
// (platform is the CTFontTextStylePlatform enum — WebKit SPI, not in the system SDK header — typed here as
// its underlying int so this TU needs no SPI header; it is unused, and C linkage is by name.)
WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontDescriptorGetTextStyleSize, (CFStringRef style, CFTypeRef sizeCategory, int platform, CGFloat* weight, CGFloat* lineSpacing))
{
    (void)sizeCategory; (void)platform;
    static const struct { const char* token; CGFloat size; CGFloat weight; } table[] = {
        { "kCTUIFontTextStyleTitle0",        34, 0.0 },
        { "kCTUIFontTextStyleTitle1",        28, 0.0 },
        { "kCTUIFontTextStyleTitle2",        22, 0.0 },
        { "kCTUIFontTextStyleTitle3",        20, 0.0 },
        { "kCTUIFontTextStyleTitle4",        18, 0.0 },
        { "kCTUIFontTextStyleHeadline",      17, 0.3 },
        { "kCTUIFontTextStyleBody",          17, 0.0 },
        { "kCTUIFontTextStyleSubhead",       15, 0.0 },
        { "kCTUIFontTextStyleFootnote",      13, 0.0 },
        { "kCTUIFontTextStyleCaption1",      12, 0.0 },
        { "kCTUIFontTextStyleCaption2",      11, 0.0 },
        { "kCTUIFontTextStyleShortHeadline", 17, 0.3 },
        { "kCTUIFontTextStyleShortBody",     17, 0.0 },
        { "kCTUIFontTextStyleShortSubhead",  15, 0.0 },
        { "kCTUIFontTextStyleShortFootnote", 13, 0.0 },
        { "kCTUIFontTextStyleShortCaption1", 12, 0.0 },
        { "kCTUIFontTextStyleTallBody",      17, 0.0 },
    };
    char buf[64];
    if (!style || !CFStringGetCString(style, buf, sizeof(buf), kCFStringEncodingUTF8))
        buf[0] = '\0';
    CGFloat size = 17.0, w = 0.0; // default: Body
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); ++i) {
        if (!strcmp(buf, table[i].token)) {
            size = table[i].size;
            w = table[i].weight;
            break;
        }
    }
    if (weight)
        *weight = w;
    if (lineSpacing)
        *lineSpacing = 0.0;
    return size;
}

// CTFontGetAccessibilityBoldWeightOfWeight (10.13+): the weight a system font should use when the
// "Bold Text" accessibility setting is on, given its normal weight (CTFontWeight, -1..1). 10.9 has no
// Bold Text accessibility feature — the whole AccessibilitySupport legibility subsystem is absent (see
// _AXSEnhanceTextLegibilityEnabled -> 0) — so there is no enhancement to apply: return the weight
// unchanged. WebKit only calls this under `shouldEnhanceTextLegibility`, which is driven by that same
// absent setting and is therefore false on 10.9, so this identity result is never actually consumed; it
// exists so the byte-upstream caller links and behaves correctly if the gate ever opens.
WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontGetAccessibilityBoldWeightOfWeight, (CGFloat weight))
{
    return weight;
}

// Descriptor option flags (newer). 10.9 descriptors carry none; report none.
WK_POLYFILL_ABSENT("CoreText", uint64_t, CTFontDescriptorGetOptions, (CTFontDescriptorRef descriptor))
{
    (void)descriptor;
    return 0;
}

// Glyphs for a run of consecutive BMP characters. The modern convenience over CTFontGetGlyphsFor
// Characters (which 10.9 has): the caller passes a CFRange of UniChar code points and a glyph buffer
// sized to the range length.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontGetGlyphsForCharacterRange, (CTFontRef font, CGGlyph glyphs[], CFRange range))
{
    if (!font || range.length <= 0)
        return false;
    UniChar *characters = (UniChar *)malloc(sizeof(UniChar) * (size_t)range.length);
    if (!characters)
        return false;
    for (CFIndex i = 0; i < range.length; ++i)
        characters[i] = (UniChar)(range.location + i);
    bool result = CTFontGetGlyphsForCharacters(font, characters, glyphs, range.length);
    free(characters);
    return result;
}

// "Physical" (non-synthesized) symbolic traits. 10.9 exposes only CTFontGetSymbolicTraits; the
// physical traits are the same set for a real (non-synthesized) font.
WK_POLYFILL_ABSENT("CoreText", CTFontSymbolicTraits, CTFontGetPhysicalSymbolicTraits, (CTFontRef font))
{
    return CTFontGetSymbolicTraits(font);
}

// UI-font-type classification (newer). 10.9 cannot classify an arbitrary font; report "no type".
WK_POLYFILL_ABSENT("CoreText", uint32_t, CTFontGetUIFontType, (CTFontRef font))
{
    (void)font;
    return (uint32_t)-1; /* kCTFontNoFontType */
}

// Is this the Apple Color Emoji font? Compare the PostScript name (the emoji font ships on 10.9).
WK_POLYFILL_ABSENT("CoreText", bool, CTFontIsAppleColorEmoji, (CTFontRef font))
{
    if (!font)
        return false;
    CFStringRef postScriptName = CTFontCopyPostScriptName(font);
    bool result = postScriptName && CFStringCompare(postScriptName, CFSTR("AppleColorEmoji"), 0) == kCFCompareEqualTo;
    if (postScriptName)
        CFRelease(postScriptName);
    return result;
}

// Is this the system UI font? 10.9 has no such predicate, but it does have a system UI font, and
// names it the same way every later system does: CTFontCreateUIFontForLanguage(kCTFontUIFontSystem).
// So ask that font what family it belongs to and compare — on this OS the answer is Lucida Grande,
// on later ones it is the hidden .AppleSystemUIFont family, and the comparison is written against
// neither. Family rather than PostScript name so the family's other faces (bold, italic) answer
// true, matching the real predicate.
//
// The family name is fetched once: this runs on every FontPlatformData construction
// (FontPlatformDataCoreText.cpp:82), and the system UI font does not change within a process.
static CFStringRef wkSystemUIFontFamilyName;

static void wkCopySystemUIFontFamilyName(void)
{
    CTFontRef systemFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 0.0, NULL);
    if (!systemFont)
        return;
    wkSystemUIFontFamilyName = CTFontCopyFamilyName(systemFont);
    CFRelease(systemFont);
}

WK_POLYFILL_ABSENT("CoreText", bool, CTFontIsSystemUIFont, (CTFontRef font))
{
    if (!font)
        return false;

    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wkCopySystemUIFontFamilyName);
    if (!wkSystemUIFontFamilyName)
        return false;

    CFStringRef familyName = CTFontCopyFamilyName(font);
    if (!familyName)
        return false;
    bool result = CFStringCompare(familyName, wkSystemUIFontFamilyName, 0) == kCFCompareEqualTo;
    CFRelease(familyName);
    return result;
}

// Enable user-installed fonts process-wide (newer). User fonts are already enabled on 10.9.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontManagerEnableAllUserFonts, (bool postFontChangeNotification))
{
    (void)postFontChangeNotification;
    return true;
}

// Composition language hint on a paragraph style (newer). No effect on 10.9 line layout.
WK_POLYFILL_ABSENT("CoreText", void, CTParagraphStyleSetCompositionLanguage, (CTParagraphStyleRef style, int language))
{
    (void)style; (void)language;
}

// Does the font contain a given sfnt table? 10.9 lacks the predicate but has the underlying copy.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontHasTable, (CTFontRef font, CTFontTableTag tag))
{
    CFDataRef table = CTFontCopyTable(font, tag, 0);
    bool present = table != NULL;
    if (table)
        CFRelease(table);
    return present;
}

// CTFontShapeGlyphs (10.13+) shapes a run: it applies kerning and OpenType/AAT substitutions to the
// caller's glyph array, growing or shrinking it through `handler` when substitution changes the glyph
// count, and returns the run's initial advance.
//
// 10.9 has no such entry point, but it CAN shape — CTTypesetter/CTLine do it, which is measurable:
// with kCTLigatureAttributeName 2, Hoefler Text and Zapfino turn the two characters "fi" into ONE
// glyph on this host. This shapes over CTLine on that basis.
//
// THE ONE THING CTLine DOES THAT THIS API MUST NOT: font fallback. CTFontShapeGlyphs shapes with the
// font it is given, and its caller renders the resulting glyph IDs with that same font; a glyph ID
// from a substituted font written into that buffer draws as garbage. Measured on this host, an empty
// kCTFontCascadeListAttribute does NOT suppress substitution — "A" + CJK still produced a second run
// in a different font. There is no way to forbid it, so instead every run is checked and, if any run
// came back in another font, this reports base advances only and substitutes nothing. Same for any
// other shape it cannot map back safely. That degradation is the honest one: correct glyphs with no
// shaping, never wrong glyphs.
// CTFontShapeOptions, mirrored from PAL/pal/spi/cf/CoreTextSPI.h so the bit tested here can be checked
// against the enum that defines it rather than against a bare literal:
//     kCTFontShapeWithKerning            = (1 << 0)
//     kCTFontShapeWithClusterComposition = (1 << 1)
//     kCTFontShapeRightToLeft            = (1 << 2)
// Getting this wrong is silent: WebCore sets cluster composition on EVERY call, so testing bit 1 for
// kerning reads as "always true" and font-kerning:none is quietly ignored.
#define WK_CTFONT_SHAPE_WITH_KERNING             (1u << 0)
#define WK_CTFONT_SHAPE_WITH_CLUSTER_COMPOSITION (1u << 1)
#define WK_CTFONT_SHAPE_RIGHT_TO_LEFT            (1u << 2)

static bool wk_ctline_shape(CTFontRef font, const UniChar *chars, CFIndex count, CFOptionFlags options,
    CTLineRef *outLine, CFIndex *outGlyphCount)
{
    *outLine = NULL; *outGlyphCount = 0;
    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, count);
    if (!string)
        return false;
    int ligature = 2, kern = 0;
    CFNumberRef ligNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ligature);
    CFNumberRef kernZero = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &kern);
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCTFontAttributeName, font);
    CFDictionarySetValue(attrs, kCTLigatureAttributeName, ligNum);
    if (!(options & WK_CTFONT_SHAPE_WITH_KERNING))
        CFDictionarySetValue(attrs, kCTKernAttributeName, kernZero);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attrs);
    CTLineRef line = attributed ? CTLineCreateWithAttributedString(attributed) : NULL;
    bool ok = false;
    if (line) {
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex runCount = runs ? CFArrayGetCount(runs) : 0;
        CFIndex total = 0;
        ok = runCount > 0;
        for (CFIndex i = 0; i < runCount && ok; i++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
            CFDictionaryRef runAttrs = CTRunGetAttributes(run);
            CTFontRef runFont = runAttrs ? (CTFontRef)CFDictionaryGetValue(runAttrs, kCTFontAttributeName) : NULL;
            if (!runFont || !CFEqual(runFont, font))
                ok = false;   // substituted font: its glyph IDs are meaningless to our caller
            else
                total += CTRunGetGlyphCount(run);
        }
        if (ok) { *outLine = (CTLineRef)CFRetain(line); *outGlyphCount = total; }
        CFRelease(line);
    }
    if (attributed) CFRelease(attributed);
    CFRelease(attrs); CFRelease(kernZero); CFRelease(ligNum); CFRelease(string);
    return ok;
}

WK_POLYFILL_ABSENT("CoreText", CGSize, CTFontShapeGlyphs,
    (CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**)))
{
    (void)language;
    CGSize zero = { 0, 0 };
    if (count <= 0 || !glyphs || !advances)
        return zero;

    // An RTL run's return value is its initial advance — where the run starts — and the caller feeds
    // that straight back into layout (FontCoreText.cpp captures it and returns it out of
    // applyTransforms). Reporting 0 for an RTL run would misplace the whole run, and deriving the true
    // offset from a CTLine built without the caller's paragraph context is not something this can do
    // reliably. So RTL is declined outright: base advances, no substitution, and no positional claim.
    CTLineRef line = NULL;
    CFIndex shaped = 0;
    if ((options & WK_CTFONT_SHAPE_RIGHT_TO_LEFT)
        || !chars || !wk_ctline_shape(font, chars, count, options, &line, &shaped)) {
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, count);
        return zero;
    }

    // Resize the caller's buffers through the handler when shaping changed the glyph count, then take
    // the fresh pointers it hands back. Without a handler we can only proceed if the count matched.
    CGGlyph *outGlyphs = glyphs; CGSize *outAdvances = advances;
    CGPoint *outOrigins = origins; CFIndex *outIndexes = indexes;
    if (shaped != count) {
        if (!handler) {
            CFRelease(line);
            CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, count);
            return zero;
        }
        // Positive length inserts that many slots at `location`; negative removes them ending there.
        CFRange range = CFRangeMake(count, shaped - count);
        handler(range, &outGlyphs, &outAdvances, &outOrigins, &outIndexes);
        if (!outGlyphs || !outAdvances) {
            CFRelease(line);
            return zero;
        }
    }

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex written = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(runs) && written < shaped; i++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        CFIndex n = CTRunGetGlyphCount(run);
        if (n <= 0)
            continue;
        if (written + n > shaped)
            n = shaped - written;
        CFRange all = CFRangeMake(0, n);
        CTRunGetGlyphs(run, all, outGlyphs + written);
        CTRunGetAdvances(run, all, outAdvances + written);
        if (outIndexes)
            CTRunGetStringIndices(run, all, outIndexes + written);
        if (outOrigins) {
            for (CFIndex g = 0; g < n; g++)
                outOrigins[written + g] = CGPointZero;   // 10.9 has no per-glyph origin offsets here
        }
        written += n;
    }
    CFRelease(line);
    return zero;   // LTR runs start at the origin; RTL initial advance is applied by the caller's path
}

// 10.9 backport: CTRunGetBaseAdvancesAndOrigins is 10.11+, so implement it here. A naive return-0 stub
// would zero every glyph's advance and origin, so any complex-text run that reports
// kCTRunStatusHasOrigins (e.g. ligature-substituted icon fonts like Material Icons) would collapse all
// its glyphs onto x=0 and render blank. Instead take the base advances from the real (10.9)
// CTRunGetAdvances and leave the origins zero (10.9 CoreText has no per-glyph origin offsets for the
// scripts WebKit shapes here).
WK_POLYFILL_ABSENT("CoreText", void, CTRunGetBaseAdvancesAndOrigins,
    (CTRunRef run, CFRange range, CGSize *advances, CGPoint *origins))
{
    if (!run)
        return;
    CFIndex glyphCount = CTRunGetGlyphCount(run);
    CFIndex count = range.length ? range.length : glyphCount;
    if (advances)
        CTRunGetAdvances(run, range, advances);
    if (origins) {
        for (CFIndex i = 0; i < count; ++i)
            origins[i] = CGPointZero;
    }
}

// ---------------------------------------------------------------------------------------------------
// QuartzCore
// ---------------------------------------------------------------------------------------------------

// CAFrameRateRangeMake (12.0+) — CADisplayLink frame-rate range constructor. Build the
// {minimum,maximum,preferred} struct directly. The local struct stands in for the SDK's
// CAFrameRateRange (which the 10.9 headers this file compiles against do not declare); the layout is
// ABI-identical (three floats), so the returned value is passed back exactly as callers expect.
typedef struct { float minimum; float maximum; float preferred; } PolyCAFrameRateRange;
WK_POLYFILL_ABSENT("QuartzCore", PolyCAFrameRateRange, CAFrameRateRangeMake,
    (float minimum, float maximum, float preferred)) {
    PolyCAFrameRateRange r = { minimum, maximum, preferred };
    return r;
}

// ---------------------------------------------------------------------------------------------------
// ImageIO decode-policy controls (newer, security hardening).
//
// These three are NOT interchangeable, and the difference is whether 10.9 already satisfies the
// postcondition the caller is asking for. Reporting success for a restriction the system never
// applied is a fake value -- the caller then believes a security boundary is in place that is not --
// which is the same defect class as an invented KERN_SUCCESS from a kernel call the OS does not have.
// ---------------------------------------------------------------------------------------------------

// "Do not use hardware decode." 10.9's ImageIO has no hardware decode path, so the postcondition is
// already true and noErr is honest: nothing was asked for that is not the case.
WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceDisableHardwareDecoding, (void))
{
    return 0; /* noErr */
}

// "Enter restricted decoding mode." 10.9's ImageIO has no restricted mode to enter, so nothing is
// restricted and unimpErr is the truth. Reporting noErr would tell WebProcessCocoa.mm:473 that the
// WebContent decode path is hardened before it enables HEIC/AVIF, which it is not. The call site
// checks the status with ASSERT_UNUSED, compiled out of the Release build this port ships, so the
// honest status costs no shipping behaviour.
WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceEnableRestrictedDecoding, (void))
{
    return -4; /* unimpErr */
}

// "Restrict ImageIO to this UTI set." 10.9's ImageIO has no such mode, so the restriction is
// implemented here, at the same seam ImageIO enforces it: a source whose container type is outside
// the set never produces pixels. WebKit sets the list once per process
// (UTIUtilities.mm setImageSourceAllowableTypes, from WebPageCocoa.mm), and it is a real security
// boundary -- it is what keeps a hostile `image/*` response away from ImageIO's other codecs inside
// WebContent. Reporting success without applying it would tell WebKit a boundary exists that does not.
//
// Enforcement sits on the two image-PRODUCING entry points, and only those. That is where the real
// API enforces, and it is the only point an INCREMENTAL source (the one ImageDecoderCG.cpp:306 uses)
// can be judged at all -- at construction it has no bytes and no type. Refusing to CREATE a source
// for a disallowed container would be a contract the real API does not have: a caller that opens a
// source purely to read CGImageSourceGetType, the frame count or the properties of a container
// outside the set still gets its source from real ImageIO, and still does from this one.
// A NULL/unknown type is never rejected: "not yet determined" is not "not allowed".
//
// The restriction is inert until WebKit installs a non-empty list, so every other process, and
// WebKit itself before that call, behaves exactly as stock 10.9.
// The list lives in PROCESS-global storage, not a plain C static. libpolyfill.a is force-loaded into
// every framework, so a file-scope static is duplicated per image: WebCore's copy would be the only
// one the setter ever reaches, while the enforcement hooks linked into WebKit2 (WebModelPlayer.mm,
// ImageAnalysisUtilities.mm, WebIconUtilities.mm all create image sources there) would read a copy
// that is forever empty -- and CGImageSourceSetAllowableTypes would still report noErr, claiming a
// process-wide restriction that covers one framework. The ObjC runtime's associated-object table is
// process-global, and a SEL makes a process-global key because the runtime uniques selector names.
//
// Published once and never freed: readers on the image-decoding thread hold the array while the main
// thread could publish again, so the array is made immortal (an extra CFRetain, no release path)
// rather than protected by a lock. That costs one small array per call to a function callers make
// once, and it removes the use-after-free instead of relying on the caller's std::call_once.
static const void *wk_allowableImageTypesKey(void)
{
    return (const void *)sel_registerName("wk_allowableImageTypes");
}

static id wk_allowableImageTypesAnchor(void)
{
    return (id)objc_getClass("NSObject");   // any process-global object; the runtime owns it
}

static CFArrayRef wk_allowableImageTypes(void)
{
    // Read on every query, never cached per image. A cache would latch the first list installed and
    // keep enforcing it after a caller republishes a different one or retracts the restriction with
    // an empty list (GPUProcess.cpp:264 passes {}), while CGImageSourceSetAllowableTypes had already
    // reported the change applied -- success for a postcondition this code did not establish.
    // The published array is immortal, so the pointer this returns can never dangle.
    id anchor = wk_allowableImageTypesAnchor();
    return anchor ? (CFArrayRef)objc_getAssociatedObject(anchor, wk_allowableImageTypesKey()) : NULL;
}

static bool wk_imageTypeIsAllowed(CFStringRef type)
{
    CFArrayRef allowable = wk_allowableImageTypes();
    if (!allowable || !type)
        return true;   // no restriction installed, or the type is not yet known
    CFIndex count = CFArrayGetCount(allowable);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef candidate = (CFStringRef)CFArrayGetValueAtIndex(allowable, i);
        if (candidate && CFGetTypeID(candidate) == CFStringGetTypeID()
            && CFStringCompare(candidate, type, kCFCompareCaseInsensitive) == kCFCompareEqualTo)
            return true;
    }
    return false;
}

static bool wk_imageSourceIsAllowed(CGImageSourceRef source)
{
    return !source || wk_imageTypeIsAllowed(CGImageSourceGetType(source));
}

WK_POLYFILL_ABSENT("ImageIO", OSStatus, CGImageSourceSetAllowableTypes, (CFArrayRef allowableTypes))
{
    // Matches the modern contract: an empty/absent list means "no restriction".
    id anchor = wk_allowableImageTypesAnchor();
    if (!anchor)
        return -4; /* unimpErr -- without process-global storage the restriction cannot be enforced */
    CFArrayRef installed = NULL;
    if (allowableTypes && CFArrayGetCount(allowableTypes)) {
        installed = CFArrayCreateCopy(kCFAllocatorDefault, allowableTypes);
        if (!installed)
            return -108; /* memFullErr */
        CFRetain(installed);   // immortal: a decode thread may hold it across a later publish
    }
    // ASSIGN, not RETAIN: the array is already immortal, so a retain policy only adds a
    // retain/autorelease to every read on the image-decoding thread, which has no pool of its own.
    objc_setAssociatedObject(anchor, wk_allowableImageTypesKey(), (id)installed, OBJC_ASSOCIATION_ASSIGN);
    return 0; /* noErr -- the restriction is in force for the process */
}

WK_POLYFILL_REPLACES("ImageIO", CGImageRef, CGImageSourceCreateImageAtIndex, (CGImageSourceRef source, size_t index, CFDictionaryRef options))
{
    if (!WK_ORIGINAL(CGImageSourceCreateImageAtIndex) || !wk_imageSourceIsAllowed(source))
        return NULL;
    return WK_ORIGINAL(CGImageSourceCreateImageAtIndex)(source, index, options);
}

WK_POLYFILL_REPLACES("ImageIO", CGImageRef, CGImageSourceCreateThumbnailAtIndex, (CGImageSourceRef source, size_t index, CFDictionaryRef options))
{
    if (!WK_ORIGINAL(CGImageSourceCreateThumbnailAtIndex) || !wk_imageSourceIsAllowed(source))
        return NULL;
    return WK_ORIGINAL(CGImageSourceCreateThumbnailAtIndex)(source, index, options);
}

// CGImageSourceGetPrimaryImageIndex (10.14+): the primary-image concept (a HEIF/HEIC container's
// primary item) postdates 10.9, and 10.9's ImageIO exports no such symbol. On 10.9 the primary frame
// is always index 0 (single-frame images have only frame 0; animated GIF/APNG treat frame 0 as
// primary). Declared in the 26.1 SDK's ImageIO headers, so ImageDecoderCG.cpp calls the upstream name
// unchanged.
WK_POLYFILL_ABSENT("ImageIO", size_t, CGImageSourceGetPrimaryImageIndex, (CGImageSourceRef source))
{
    (void)source;
    return 0;
}

// ---------------------------------------------------------------------------------------------------
// IOKit HID event system client (newer HID API) — used to read the pointer scroll-acceleration curve.
// Absent on 10.9; returning null/no-op leaves WebKit on the default acceleration curve.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("IOKit", void, IOHIDEventSystemClientActivate, (void *client))
{
    (void)client;
}

WK_POLYFILL_ABSENT("IOKit", void *, IOHIDEventSystemClientCopyServiceForRegistryID, (void *client, uint64_t registryID))
{
    (void)client; (void)registryID;
    return NULL;
}

WK_POLYFILL_ABSENT("IOKit", void, IOHIDEventSystemClientSetDispatchQueue, (void *client, void *queue))
{
    (void)client; (void)queue;
}

// IOHIDEventGetScrollMomentum (10.9's IOKit lacks this one; the sibling IOHIDEvent accessors
// IOHIDEventGetFloatValue/GetTimeStamp/GetSenderID/GetType ARE present and link to the real
// symbols). Momentum-phase bits aren't reported through this API on 10.9; returning 0 (no bits)
// is the honest answer — scroll deltas still come through the present IOHIDEventGetFloatValue path.
WK_POLYFILL_ABSENT("IOKit", unsigned char, IOHIDEventGetScrollMomentum, (void *event))
{
    (void)event;
    return 0;
}

// ---------------------------------------------------------------------------------------------
// CoreMedia
//
// Both of these are 10.10 conveniences over a 10.9 entry point that is still there and still does
// the work; each is defined in terms of the one it wraps, so the behaviour is the OS's own.

// Both bodies reach 10.9's CoreMedia through WK_SYSTEM_FN rather than by calling it directly: a
// direct call emits an undefined symbol that EVERY image force-loading this archive has to satisfy,
// including JavaScriptCore and the NetworkProcess, which have no reason to link CoreMedia. (Observed:
// a direct call here failed the JavaScriptCore link on CMSampleBufferCreate and
// CMSampleBufferCallForEachSample.) See the WK_SYSTEM_FN note in mechanism/wk_polyfill.h.
WK_SYSTEM_FN("CoreMedia", OSStatus, CMSampleBufferCreate,
    (CFAllocatorRef, CMBlockBufferRef, Boolean, CMSampleBufferMakeDataReadyCallback, void *,
     CMFormatDescriptionRef, CMItemCount, CMItemCount, const CMSampleTimingInfo *, CMItemCount,
     const size_t *, CMSampleBufferRef *));

WK_SYSTEM_FN("CoreMedia", OSStatus, CMSampleBufferCallForEachSample,
    (CMSampleBufferRef, OSStatus (*)(CMSampleBufferRef, CMItemCount, void *), void *));

// CMSampleBufferCreateReady is CMSampleBufferCreate with dataReady=true and no make-data-ready
// callback -- that is its definition, not an approximation of it. The two argument lists are
// identical apart from those three parameters.
WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMSampleBufferCreateReady,
    (CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, CMFormatDescriptionRef formatDescription,
     CMItemCount numSamples, CMItemCount numSampleTimingEntries,
     const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries,
     const size_t *sampleSizeArray, CMSampleBufferRef *sampleBufferOut))
{
    if (!WK_SYSTEM(CMSampleBufferCreate))
        return kCMSampleBufferError_AllocationFailed;
    return WK_SYSTEM(CMSampleBufferCreate)(allocator, dataBuffer, true, NULL, NULL, formatDescription,
                                           numSamples, numSampleTimingEntries, sampleTimingArray,
                                           numSampleSizeEntries, sampleSizeArray, sampleBufferOut);
}

// CMSampleBufferCallBlockForEachSample is the block-taking form of CMSampleBufferCallForEachSample,
// which 10.9 has. The function-pointer form already carries a refcon, so the block travels in it and
// this trampoline hands each sample to it; the handler's OSStatus is returned unchanged, so an
// early-out (a non-zero status) stops the iteration exactly as it does on the block form.
static OSStatus wkCallBlockForEachSampleTrampoline(CMSampleBufferRef sampleBuffer, CMItemCount index,
                                                   void *refcon)
{
    OSStatus (^handler)(CMSampleBufferRef, CMItemCount) = (OSStatus (^)(CMSampleBufferRef, CMItemCount))refcon;
    return handler(sampleBuffer, index);
}

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMSampleBufferCallBlockForEachSample,
    (CMSampleBufferRef sampleBuffer, OSStatus (^handler)(CMSampleBufferRef, CMItemCount)))
{
    if (!handler)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!WK_SYSTEM(CMSampleBufferCallForEachSample))
        return kCMSampleBufferError_AllocationFailed;
    return WK_SYSTEM(CMSampleBufferCallForEachSample)(sampleBuffer, wkCallBlockForEachSampleTrampoline,
                                                      (void *)handler);
}

// CGContextSetOwnerIdentity (12+): tags a context's backing store to another process's memory
// ledger, using a task identity token. 10.9 has neither -- see task_create_identity_token in
// system-spi.m -- so there is no ledger to move the pages to and no token that could name one. The
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

// VTRegisterSupplementalVideoDecoderIfAvailable (macOS 11+, absent on 10.9, nm-verified) asks VideoToolbox to load an out-of-band decoder plugin
// for a codec. 10.9's VideoToolbox has no supplemental-decoder registry to load one into, so there is
// nothing to register and nothing to report -- the routine returns void, and the caller discovers the
// outcome by asking whether the codec is supported afterwards, which is answered above.
WK_POLYFILL_ABSENT("VideoToolbox", void, VTRegisterSupplementalVideoDecoderIfAvailable, (int32_t codecType))
{
    (void)codecType;
}

// ---------------------------------------------------------------------------------------------
// Wide-gamut / extended-range colour space names (10.11-10.12+), all ABSENT on 10.9 (probed: only
// kCGColorSpaceSRGB exists; even kCGColorSpaceLinearSRGB is missing, and
// CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceExtendedSRGB")) returns NULL).
//
// Supplying the NAMES alone would be worse than useless: DestinationColorSpace would hold a NULL
// CGColorSpaceRef and trip its own ASSERT. So the names come with a CGColorSpaceCreateWithName that
// knows what to do with them.
// Only Rec2020 is new here; the other five extended/wide-gamut names are already supplied in
// polyfills/constants.m (the build gate's duplicate-symbol check caught the overlap).
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRec2020, CFSTR("kCGColorSpaceExtendedRec2020"));

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
// EVERY name constants.m publishes is answered. Probed on this host, stock CGColorSpaceCreateWithName
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


// ============================================================================
// Text drawn into a CGPDFContext while a transparency layer is open
// ============================================================================
// 10.9's CGPDFContext records nothing for a glyph run PAINTED while a transparency
// layer is open: the emitted page carries no text-showing operators and the font is
// never embedded. The characters are absent from the document itself rather than only
// from its rasterization, so a printed or saved PDF loses every painted glyph that
// falls under an opacity, mask, blend or clip layer.
//
// Measured on this OS by rasterizing the emitted page and counting ink:
//
//   outlined text, fill / stroke / fill+stroke   plain 1516 / 724 / 2016   layer 0 / 0 / 0
//   color glyphs (Apple Color Emoji)             plain 1408                layer 1408
//   a plain CGImage                              plain 2304                layer 2304
//   text clip, then fill the whole page          plain  758                layer  758
//
// So the defect is confined to PAINTING outlined glyphs. Core Text emits color glyphs
// as images, and images -- like paths -- are recorded correctly, so a color run is
// handed to the system implementation untouched; converting it to outlines would erase
// emoji that print correctly today, because CTFontCreatePathForGlyph returns NULL for
// them. Text clipping also works inside a layer, so clip modes keep the system
// implementation for the clip itself.
//
// Splitting one run across several CTFontDrawGlyphs calls is safe ONLY for the pure
// painting modes. CG intersects the text clip once per CALL, not per glyph: two
// clip-mode calls leave an EMPTY clip where a single call clipping the same two glyphs
// yields their union (measured). Clip-mode runs are therefore never split.
//
// 10.9 offers no way to ask a context whether a layer is open
// (CGContextGetTransparencyLayerDepth and CGContextIsInTransparencyLayer are both
// absent from CoreGraphics here), so the layer entry points below carry the count.

// CGContextGetType's PDF result, measured on 10.9; bitmap contexts report 4. Matches
// kCGContextTypePDF in PAL's CoreGraphicsSPI.h.
#define WK_CG_CONTEXT_TYPE_PDF 1

WK_SYSTEM_FN("CoreGraphics", int, CGContextGetType, (CGContextRef));
WK_SYSTEM_FN("CoreGraphics", CGTextDrawingMode, CGContextGetTextDrawingMode, (CGContextRef));

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
static void wk_transparencyLayerBegan(CGContextRef context)
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

static void wk_transparencyLayerEnded(CGContextRef context)
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

static bool wk_isInsideTransparencyLayer(CGContextRef context)
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

// Defined after the CTFontDrawGlyphs replacement below, because it re-issues color
// runs through that entry point's original implementation.
static void wk_drawGlyphsInPDFTransparencyLayer(CGContextRef context, CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count);

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

WK_POLYFILL_REPLACES("CoreText", void, CTFontDrawGlyphs, (CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context))
{
    if (font && glyphs && positions && count && context && wk_isInsideTransparencyLayer(context)
        && WK_SYSTEM(CGContextGetType) && WK_SYSTEM(CGContextGetType)(context) == WK_CG_CONTEXT_TYPE_PDF) {
        wk_drawGlyphsInPDFTransparencyLayer(context, font, glyphs, positions, count);
        return;
    }
    if (WK_ORIGINAL(CTFontDrawGlyphs))
        WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
}

// CTFontCreatePathForGlyph places an outline the same way CTFontDrawGlyphs places a
// glyph: device = CTM * textMatrix * (position + outline). Vertical runs arrive with
// the vertical text matrix already installed on the context, so reading it here keeps
// both orientations aligned with the system implementation.
static CGAffineTransform wk_glyphMatrix(const CGPoint *positions, size_t index, CGAffineTransform textMatrix)
{
    return CGAffineTransformConcat(CGAffineTransformMakeTranslation(positions[index].x, positions[index].y), textMatrix);
}

static void wk_paintOutlines(CGContextRef context, CGPathRef path, bool fills, bool strokes)
{
    if (!fills && !strokes)
        return;
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextDrawPath(context, fills && strokes ? kCGPathFillStroke : (fills ? kCGPathFill : kCGPathStroke));
}

static void wk_drawGlyphsInPDFTransparencyLayer(CGContextRef context, CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    CGTextDrawingMode mode = kCGTextFill;
    if (WK_SYSTEM(CGContextGetTextDrawingMode))
        mode = WK_SYSTEM(CGContextGetTextDrawingMode)(context);

    // Invisible paints nothing, and clip-only establishes a clip the layer already
    // records correctly. Neither needs anything from this code.
    if (mode == kCGTextInvisible || mode == kCGTextClip) {
        if (WK_ORIGINAL(CTFontDrawGlyphs))
            WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
        return;
    }

    bool fills = mode == kCGTextFill || mode == kCGTextFillStroke || mode == kCGTextFillClip || mode == kCGTextFillStrokeClip;
    bool strokes = mode == kCGTextStroke || mode == kCGTextFillStroke || mode == kCGTextStrokeClip || mode == kCGTextFillStrokeClip;
    CGAffineTransform textMatrix = CGContextGetTextMatrix(context);

    if (mode >= kCGTextFillClip) {
        // CG paints the run and THEN unions the whole call into the clip. Paint every
        // outlined glyph as one path first, then hand the UNSPLIT run to the system
        // implementation: its painting is what the layer drops, but its clip -- and
        // its handling of color glyphs -- is correct.
        CGMutablePathRef path = CGPathCreateMutable();
        for (size_t i = 0; i < count; ++i) {
            CGAffineTransform matrix = wk_glyphMatrix(positions, i, textMatrix);
            CGPathRef glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], &matrix);
            if (!glyphPath)
                continue;
            CGPathAddPath(path, NULL, glyphPath);
            CFRelease(glyphPath);
        }
        wk_paintOutlines(context, path, fills, strokes);
        CGPathRelease(path);
        if (WK_ORIGINAL(CTFontDrawGlyphs))
            WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
        return;
    }

    // A pure painting mode. Walk the run in index order and process maximal spans of
    // one kind, so glyphs composite in the order CTFontDrawGlyphs would paint them and
    // nothing is allocated per run -- an allocation that could fail is an opportunity
    // to silently drop glyphs.
    size_t i = 0;
    while (i < count) {
        CGAffineTransform matrix = wk_glyphMatrix(positions, i, textMatrix);
        CGPathRef glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], &matrix);
        size_t next = i + 1;
        if (glyphPath) {
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddPath(path, NULL, glyphPath);
            CFRelease(glyphPath);
            for (; next < count; ++next) {
                CGAffineTransform nextMatrix = wk_glyphMatrix(positions, next, textMatrix);
                CGPathRef nextPath = CTFontCreatePathForGlyph(font, glyphs[next], &nextMatrix);
                if (!nextPath)
                    break;
                CGPathAddPath(path, NULL, nextPath);
                CFRelease(nextPath);
            }
            wk_paintOutlines(context, path, fills, strokes);
            CGPathRelease(path);
        } else {
            for (; next < count; ++next) {
                CGAffineTransform nextMatrix = wk_glyphMatrix(positions, next, textMatrix);
                CGPathRef nextPath = CTFontCreatePathForGlyph(font, glyphs[next], &nextMatrix);
                if (nextPath) {
                    CFRelease(nextPath);
                    break;
                }
            }
            if (WK_ORIGINAL(CTFontDrawGlyphs))
                WK_ORIGINAL(CTFontDrawGlyphs)(font, &glyphs[i], &positions[i], next - i, context);
        }
        i = next;
    }
}
