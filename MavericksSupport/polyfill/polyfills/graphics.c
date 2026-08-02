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
#include <IOKit/IOKitLib.h>
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
WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyColorGlyphCoverage, (CTFontRef font))
{
    (void)font;
    return NULL;
}

WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyGlyphCoverageForFeature, (CTFontRef font, CFDictionaryRef feature))
{
    (void)font; (void)feature;
    return NULL;
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

// Is this the system UI font? 10.9 has no such predicate; WebKit only uses it to take a fast path,
// so reporting false (treat as an ordinary font) is correct, just not the fast path.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontIsSystemUIFont, (CTFontRef font))
{
    (void)font;
    return false;
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

// CTFontShapeGlyphs (the unified glyph-shaping entry point) is 10.13+ and absent on 10.9. It is called
// from Font::applyTransforms (the SimpleShaper path) to fill per-glyph horizontal advances (and, for
// complex cases, reorder glyphs via the handler). On 10.9 that path historically used the still-present
// CTFontGetAdvancesForGlyphs to fill base horizontal advances, and complex-script reshaping/reordering
// went through WebCore's ComplexTextController (CTLine/CTTypesetter), NOT this simple path. So the
// faithful 10.9 behavior here is: fill base horizontal advances from CTFontGetAdvancesForGlyphs, keep
// the caller's glyphs/origins/indexes (horizontal simple text has zero origins and no reordering), and
// return a zero initial advance (LTR). This is a real implementation over the present 10.9 API, not a
// value stub. CTFontShapeOptions is a CFOptionFlags; the reorder handler is unused on this OS path.
WK_POLYFILL_ABSENT("CoreText", CGSize, CTFontShapeGlyphs,
    (CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**)))
{
    (void)origins; (void)indexes; (void)chars; (void)options; (void)language; (void)handler;
    if (count > 0 && advances && glyphs)
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, count);
    CGSize zero = { 0, 0 };
    return zero;
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
// ImageIO decode-policy controls (newer, security hardening). No-op on 10.9: images decode normally.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceDisableHardwareDecoding, (void))
{
    return 0; /* noErr */
}

WK_POLYFILL_ABSENT("ImageIO", int, CGImageSourceEnableRestrictedDecoding, (void))
{
    return 0; /* noErr */
}

// Restricts which image UTIs may be decoded (newer hardening). No-op on 10.9: all types decode.
WK_POLYFILL_ABSENT("ImageIO", OSStatus, CGImageSourceSetAllowableTypes, (CFArrayRef allowableTypes))
{
    (void)allowableTypes;
    return 0;
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
// The substitute is sRGB. 10.9's colour pipeline has no extended-range or wide-gamut representation at all
// -- there is no display path that could show a colour outside sRGB -- so sRGB is both the closest space
// available and the one whose rendering matches what the screen actually produces. Colours outside the
// sRGB gamut clamp, which is what happens on this hardware regardless of how they were tagged. The
// alternative, a NULL colour space, is not a lesser answer but a broken one: it fails the caller's ASSERT
// and leaves CGBitmapContext creation without a colour space.
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef));

WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef name))
{
    if (!WK_SYSTEM(CGColorSpaceCreateWithName))
        return NULL;

    CGColorSpaceRef space = WK_SYSTEM(CGColorSpaceCreateWithName)(name);
    if (space || !name)
        return space;   // 10.9 knew this name (or there is no name): its answer stands

    static const CFStringRef substituted[] = {
        CFSTR("kCGColorSpaceExtendedSRGB"), CFSTR("kCGColorSpaceLinearSRGB"),
        CFSTR("kCGColorSpaceExtendedLinearSRGB"), CFSTR("kCGColorSpaceDisplayP3"),
        CFSTR("kCGColorSpaceExtendedLinearDisplayP3"), CFSTR("kCGColorSpaceExtendedRec2020"),
        CFSTR("kCGColorSpaceExtendedDisplayP3"), CFSTR("kCGColorSpaceITUR_2020"),
    };
    for (size_t i = 0; i < sizeof(substituted) / sizeof(substituted[0]); i++) {
        if (CFStringCompare(name, substituted[i], 0) == kCFCompareEqualTo)
            return WK_SYSTEM(CGColorSpaceCreateWithName)(kCGColorSpaceSRGB);
    }
    return NULL;   // some other unknown name: 10.9's own answer, unchanged
}
