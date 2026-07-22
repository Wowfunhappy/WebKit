/*
 * Copyright (C) 2003-2019 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "GraphicsContext.h"

#import "DisplayListRecorder.h"
#import "Font.h"
#import "GraphicsContextCG.h"
#import "IOSurface.h"
#import "ImageAdapter.h"
#import "IntRect.h"
#import <CoreText/CoreText.h>
#import <numeric>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/cocoa/FeatureFlagsSPI.h>
#import <pal/spi/mac/NSGraphicsSPI.h>
#import <wtf/SoftLinking.h>
#import <wtf/StdLibExtras.h>

#if ENABLE(MULTI_REPRESENTATION_HEIC)
#import "MultiRepresentationHEICMetrics.h"
#endif

#if USE(APPKIT)
#import <AppKit/AppKit.h>
#endif

#if PLATFORM(IOS_FAMILY)
#import "Color.h"
#import "WKGraphics.h"
#import <UIKit/UIKit.h>
#import <pal/ios/UIKitSoftLink.h>
#import <pal/spi/ios/UIKitSPI.h>
#endif

@class NSColor;

// FIXME: More of this should use CoreGraphics instead of AppKit.
// FIXME: More of this should move into GraphicsContextCG.cpp.

namespace WebCore {

// NSColor, NSBezierPath, and NSGraphicsContext calls do not raise exceptions
// so we don't block exceptions.

#if ENABLE(MULTI_REPRESENTATION_HEIC)

ImageDrawResult GraphicsContext::drawMultiRepresentationHEIC(Image& image, const Font& font, const FloatRect& destination, ImagePaintingOptions options)
{
    RetainPtr multiRepresentationHEIC = image.adapter().multiRepresentationHEIC();
    if (!multiRepresentationHEIC)
        return ImageDrawResult::DidNothing;

    RefPtr imageBuffer = createScaledImageBuffer(destination.size(), scaleFactor(), DestinationColorSpace::SRGB(), RenderingMode::Unaccelerated, RenderingMethod::Local);
    if (!imageBuffer)
        return ImageDrawResult::DidNothing;

    CGContextRef cgContext = imageBuffer->context().platformContext();

    CGContextScaleCTM(cgContext, 1, -1);
    CGContextTranslateCTM(cgContext, 0, -destination.height());

    // FIXME (rdar://123044459): This needs to account for vertical writing modes.
    CGContextSetTextPosition(cgContext, 0, font.metricsForMultiRepresentationHEIC().descent);

    CTFontDrawImageFromAdaptiveImageProviderAtPoint(font.ctFont(), multiRepresentationHEIC.get(), CGContextGetTextPosition(cgContext), cgContext);

    auto orientation = options.orientation();
    if (orientation == ImageOrientation::Orientation::FromImage)
        orientation = image.orientation();

    drawImageBuffer(*imageBuffer, destination, { options, orientation });

    return ImageDrawResult::DidDraw;
}

#endif

#if USE(APPKIT)
// MAVERICKS_BACKPORT: keyboard focus ring. Upstream draws it with CoreGraphics' CGStyle focus ring
// (NSInitializeCGFocusRingStyleForTime -> CGStyleCreateFocusRingWithColor -> CGContextSetStyle -> fill).
// That path is unusable on 10.9, verified on-device: the CGStyle focus ring does NOT composite into
// WebKit's offscreen (WK2 / layer-backed) drawing context at all — it renders nothing there, while
// ordinary drawing in the SAME context renders normally (10.9's focus-ring accumulation is a
// window-server-composited effect that never reaches WebKit's offscreen surface; modern macOS draws it
// directly into any context, which is why upstream needs no special handling). And where the CGStyle
// ring DOES render (a standalone bitmap) it draws the flat MODERN ring, not the classic Mavericks Aqua
// glow. The authentic Mavericks ring is AppKit's classic NSSetFocusRingStyle; it also does not composite
// offscreen but DOES render into a standalone bitmap. So draw the native ring into a scratch bitmap and
// composite it back. The scratch bitmap is filled in TWO passes (see wkCompositeNativeFocusRing): a plain
// coverage pass that unions the shape/mask into one silhouette (a raw CGContext fill IS honored there,
// since no focus-ring style is set yet), then a ring pass that draws that silhouette under
// NSSetFocusRingStyle. So a caller holding a CGPath fills it straight into the coverage context — no
// NSBezierPath conversion is needed (10.9 AppKit has no bezierPathWithCGPath: anyway).

// Render the native AppKit focus ring around drawShape's silhouette into a scratch bitmap sized to
// `bounds` (in `destination` user space) plus a glow margin, then composite the result into `destination`.
void wkCompositeNativeFocusRing(CGContextRef destination, CGRect bounds, void (^drawShape)(void))
{
    if (CGRectIsEmpty(bounds))
        return;
    constexpr CGFloat glowMargin = 8; // room for the ~4px soft-blue Aqua bleed outside the shape
    CGRect tile = CGRectInset(bounds, -glowMargin, -glowMargin);
    // MAVERICKS_BACKPORT: render the scratch bitmaps at the destination's device scale so the ring is crisp
    // on HiDPI/Retina — a 1x bitmap would be upsampled by the composite below and read blurry. Derive the
    // scale from the destination CTM (covers both callers without threading deviceScaleFactor through).
    CGSize deviceUnit = CGContextConvertSizeToDeviceSpace(destination, CGSizeMake(1, 1));
    CGFloat scale = std::max<CGFloat>(1, std::max(std::abs(deviceUnit.width), std::abs(deviceUnit.height)));
    size_t width = static_cast<size_t>(std::ceil(tile.size.width * scale));
    size_t height = static_cast<size_t>(std::ceil(tile.size.height * scale));
    if (!width || !height)
        return;
    RetainPtr colorSpace = adoptCF(CGColorSpaceCreateDeviceRGB());
    auto makeTileBitmap = [&]() -> RetainPtr<CGContextRef> {
        RetainPtr ctx = adoptCF(CGBitmapContextCreate(nullptr, width, height, 8, 0, colorSpace.get(),
            static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Host)));
        if (ctx) {
            CGContextScaleCTM(ctx.get(), scale, scale); // draw in points; the bitmap is `scale`x device pixels
            CGContextTranslateCTM(ctx.get(), -tile.origin.x, -tile.origin.y); // draw in the destination's space
        }
        return ctx;
    };

    // Pass 1: flatten the shape to a plain opaque coverage silhouette. A themed control can draw its
    // focus-ring mask as SEVERAL sub-regions (NSPopUpButtonCell draws the button body and the arrow well
    // separately); running that straight through NSSetFocusRingStyle rings each sub-region, so a popup gets a
    // spurious inner rectangle inside the correct outer rounded ring. Unioning the sub-regions into one
    // coverage bitmap first collapses them to a single outline. (A plain single-path caller is unaffected —
    // its coverage is just that one shape.)
    RetainPtr coverage = makeTileBitmap();
    if (!coverage)
        return;
    RetainPtr coverageContext = [NSGraphicsContext graphicsContextWithGraphicsPort:coverage.get() flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:coverageContext.get()];
    [[NSColor blackColor] set];
    drawShape();
    [NSGraphicsContext restoreGraphicsState];
    RetainPtr coverageImage = adoptCF(CGBitmapContextCreateImage(coverage.get()));
    if (!coverageImage)
        return;

    // Pass 2: draw that single silhouette under NSSetFocusRingStyle so the authentic Aqua ring traces the
    // union outline exactly once. The image must be drawn through AppKit (-[NSImage drawInRect:]) — a raw
    // CGContextDrawImage bypasses the focus-ring state and would emit nothing.
    RetainPtr bitmap = makeTileBitmap();
    if (!bitmap)
        return;
    RetainPtr nsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:bitmap.get() flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsContext.get()];
    NSSetFocusRingStyle(NSFocusRingOnly);
    RetainPtr silhouette = adoptNS([[NSImage alloc] initWithCGImage:coverageImage.get() size:NSMakeSize(tile.size.width, tile.size.height)]);
    [silhouette drawInRect:NSMakeRect(tile.origin.x, tile.origin.y, tile.size.width, tile.size.height)];
    [NSGraphicsContext restoreGraphicsState];
    RetainPtr image = adoptCF(CGBitmapContextCreateImage(bitmap.get()));
    if (image)
        CGContextDrawImage(destination, tile, image.get());
}
#endif

void GraphicsContextCG::drawFocusRing(const Path& path, float, const Color& color)
{
    if (path.isEmpty())
        return;

#if USE(APPKIT)
    // MAVERICKS_BACKPORT: draw the authentic native 10.9 focus ring via a scratch bitmap and return; the
    // upstream CGStyle focus-ring path (kept intact in the #else below for the non-APPKIT build) does not
    // render in WebKit's offscreen context on 10.9, and draws the flat modern ring rather than the Aqua
    // glow where it does. See wkCompositeNativeFocusRing.
    UNUSED_PARAM(color); // NSSetFocusRingStyle draws in the system focus color (the Aqua blue).
    CGPathRef cgPath = path.platformPath();
    wkCompositeNativeFocusRing(platformContext(), CGPathGetPathBoundingBox(cgPath), ^{
        // The coverage pass runs in a plain (non-focus-ring) context, so fill the CGPath straight into it —
        // no NSBezierPath needed; wkCompositeNativeFocusRing then rings the filled silhouette once.
        CGContextRef coverageContext = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
        CGContextSetGrayFillColor(coverageContext, 0, 1);
        CGContextAddPath(coverageContext, cgPath);
        CGContextFillPath(coverageContext);
    });
#else
    CGFocusRingStyle focusRingStyle;
#if USE(APPKIT)
    NSInitializeCGFocusRingStyleForTime(NSFocusRingOnly, &focusRingStyle, std::numeric_limits<double>::max());
#else
    focusRingStyle.version = 0;
    focusRingStyle.tint = kCGFocusRingTintBlue;
    focusRingStyle.ordering = kCGFocusRingOrderingNone;
    focusRingStyle.alpha = [PAL::getUIFocusRingStyleClassSingleton() maxAlpha];
    focusRingStyle.radius = [PAL::getUIFocusRingStyleClassSingleton() borderThickness];
    focusRingStyle.threshold = [PAL::getUIFocusRingStyleClassSingleton() alphaThreshold];
    focusRingStyle.bounds = CGRectZero;
#endif

    // We want to respect the CGContext clipping and also not overpaint any
    // existing focus ring. The way to do this is set accumulate to
    // -1. According to CoreGraphics, the reasoning for this behavior has been
    // lost in time.
    focusRingStyle.accumulate = -1;
    auto style = adoptCF(CGStyleCreateFocusRingWithColor(&focusRingStyle, cachedCGColor(color).get()));

    CGContextRef platformContext = this->platformContext();

    CGContextStateSaver stateSaver(platformContext);

    CGContextSetStyle(platformContext, style.get());
    CGContextBeginPath(platformContext);
    CGContextAddPath(platformContext, path.platformPath());

    CGContextFillPath(platformContext);
#endif // MAVERICKS_BACKPORT: end of the APPKIT native-focus-ring override
}

void GraphicsContextCG::drawFocusRing(const Vector<FloatRect>& rects, float outlineOffset, float outlineWidth, const Color& color)
{
    Path path;
    for (const auto& rect : rects) {
        auto r = rect;
        r.inflate(-outlineOffset);
        path.addRect(r);
    }
    drawFocusRing(path, outlineWidth, color);
}

static inline void setPatternPhaseInUserSpace(CGContextRef context, CGPoint phasePoint)
{
    CGAffineTransform userToBase = getUserToBaseCTM(context);
    CGPoint phase = CGPointApplyAffineTransform(phasePoint, userToBase);

    CGContextSetPatternPhase(context, CGSizeMake(phase.x, phase.y));
}

static inline void drawDotsForDocumentMarker(CGContextRef context, const FloatRect& rect, DocumentMarkerLineStyle style)
{
    // We want to find the number of full dots, so we're solving the equations:
    // dotDiameter = height
    // dotDiameter / dotGap = 13.247 / 9.457
    // numberOfGaps = numberOfDots - 1
    // dotDiameter * numberOfDots + dotGap * numberOfGaps = width

    auto width = rect.width();
    auto dotDiameter = rect.height();
    auto dotGap = dotDiameter * 9.457 / 13.247;
    auto numberOfDots = (width + dotGap) / (dotDiameter + dotGap);
    auto numberOfWholeDots = static_cast<unsigned>(numberOfDots);
    auto numberOfWholeGaps = numberOfWholeDots - 1;

    // Center the dots
    auto offset = (width - (dotDiameter * numberOfWholeDots + dotGap * numberOfWholeGaps)) / 2;

    CGContextStateSaver stateSaver { context };
    CGContextSetFillColorWithColor(context, cachedCGColor(style.color).get());
    for (unsigned i = 0; i < numberOfWholeDots; ++i) {
        auto location = rect.location();
        location.move(offset + i * (dotDiameter + dotGap), 0);
        auto size = FloatSize(dotDiameter, dotDiameter);
        CGContextAddEllipseInRect(context, FloatRect(location, size));
    }
    CGContextSetCompositeOperation(context, kCGCompositeSover);
    CGContextFillPath(context);
}

#if HAVE(AUTOCORRECTION_ENHANCEMENTS)

static inline void drawRoundedRectForDocumentMarker(CGContextRef context, const FloatRect& rect, DocumentMarkerLineStyle style)
{
    CGContextStateSaver stateSaver { context };
    CGContextSetFillColorWithColor(context, cachedCGColor(style.color).get());
    CGContextSetCompositeOperation(context, kCGCompositeSover);

    auto radius = rect.height() / 2.0;
    auto minX = rect.x();
    auto maxX = rect.maxX();
    auto minY = rect.y();
    auto maxY = rect.maxY();
    auto midY = std::midpoint(minY, maxY);

    CGContextMoveToPoint(context, minX + radius, maxY);
    CGContextAddArc(context, minX + radius, midY, radius, piOverTwoDouble, 3 * piOverTwoDouble, 0);
    CGContextAddLineToPoint(context, maxX - radius, minY);
    CGContextAddArc(context, maxX - radius, midY, radius, 3 * piOverTwoDouble, piOverTwoDouble, 0);
    CGContextClosePath(context);
    CGContextFillPath(context);
}

#endif

void GraphicsContextCG::drawDotsForDocumentMarker(const FloatRect& rect, DocumentMarkerLineStyle style)
{
#if HAVE(AUTOCORRECTION_ENHANCEMENTS)
    if (style.mode == DocumentMarkerLineStyleMode::AutocorrectionReplacement) {
        drawRoundedRectForDocumentMarker(this->platformContext(), rect, style);
        return;
    }
#endif
    WebCore::drawDotsForDocumentMarker(this->platformContext(), rect, style);
}

} // namespace WebCore
