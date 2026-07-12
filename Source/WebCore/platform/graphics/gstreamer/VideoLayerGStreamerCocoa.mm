/*
 * Copyright (C) 2026 Igalia S.L
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// MAVERICKS_BACKPORT: accelerated <video> compositing for the Cocoa+GStreamer hybrid — see
// VideoLayerGStreamerCocoa.h for the design rationale.

#include "config.h"
#include "VideoLayerGStreamerCocoa.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)

#include "FloatRect.h"
#include "GStreamerCommon.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>

#import <QuartzCore/QuartzCore.h>

namespace WebCore {

RetainPtr<CALayer> createGStreamerVideoLayer()
{
    ASSERT(isMainThread());
    auto layer = adoptNS([[CALayer alloc] init]);
    // Frames are stretched to the layer bounds; RenderLayerBacking sizes the contents layer to the
    // element's video box, which already has the frame's aspect ratio.
    [layer setContentsGravity:kCAGravityResize];
    return layer;
}

static void releaseMappedVideoFrame(void* info, const void*, size_t)
{
    delete static_cast<GstMappedFrame*>(info);
}

// Draw the decoded frame through its source orientation into a bitmap sized to the oriented
// (display) dimensions, so the resulting image is the frame the compositor should show and the layer
// carries no geometry transform. The transform sequence mirrors
// GraphicsContextCG::drawNativeImageInternal so the composited frame matches the software
// drawVideoFrame() path pixel-for-pixel.
static RetainPtr<CGImageRef> createOrientedImage(CGImageRef source, ImageOrientation orientation, size_t storedWidth, size_t storedHeight, CGColorSpaceRef colorSpace)
{
    // 90/270-degree rotations swap width and height (matches naturalSize()'s transposedSize()).
    size_t displayWidth = orientation.usesWidthAsHeight() ? storedHeight : storedWidth;
    size_t displayHeight = orientation.usesWidthAsHeight() ? storedWidth : storedHeight;

    CGBitmapInfo bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaNoneSkipFirst;
    auto context = adoptCF(CGBitmapContextCreate(nullptr, displayWidth, displayHeight, 8, 0, colorSpace, bitmapInfo));
    if (!context)
        return nullptr;

    // ImageOrientation::transformFromDefault and the draw sequence below are defined against a
    // top-left (y-down) coordinate space, matching the GraphicsContext the software drawVideoFrame()
    // path draws into; a CGBitmapContext is bottom-left (y-up). Flip once up front so the rotation is
    // applied with the same handedness (otherwise 90/270 come out rotated the wrong way).
    CGContextTranslateCTM(context.get(), 0, displayHeight);
    CGContextScaleCTM(context.get(), 1, -1);

    // From here this mirrors GraphicsContextCG::drawNativeImageInternal exactly, so the composited
    // frame matches the software path pixel-for-pixel.
    FloatRect destRect(0, 0, displayWidth, displayHeight);
    CGContextConcatCTM(context.get(), orientation.transformFromDefault(destRect.size()));
    // The destination rect was given the oriented dimensions above; transformFromDefault expects the
    // pre-transpose (stored) rect for a rotation, so reverse the swap here.
    if (orientation.usesWidthAsHeight())
        destRect = destRect.transposedRect();
    // Flip back to y-up for the image draw (CGContextDrawImage renders upright in a y-up frame).
    CGContextTranslateCTM(context.get(), 0, destRect.height());
    CGContextScaleCTM(context.get(), 1, -1);
    CGContextDrawImage(context.get(), destRect, source);
    return adoptCF(CGBitmapContextCreateImage(context.get()));
}

void setGStreamerVideoLayerContents(CALayer* layer, const GRefPtr<GstSample>& sample, ImageOrientation orientation)
{
    if (!layer || !sample)
        return;

    std::unique_ptr<GstMappedFrame> mappedFrame(new GstMappedFrame(sample, GST_MAP_READ));
    if (!mappedFrame->isValid())
        return;

    // Map the negotiated packed 32-bit RGB layout to the matching CG byte order + alpha combination,
    // mirroring ImageGStreamerCG.cpp. The WebKit fallback video sink negotiates { BGRx, BGRA } on
    // little-endian; the other packings are accepted for completeness.
    CGBitmapInfo bitmapInfo;
    switch (mappedFrame->format()) {
    case GST_VIDEO_FORMAT_BGRA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaFirst;
        break;
    case GST_VIDEO_FORMAT_BGRx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_ARGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaFirst;
        break;
    case GST_VIDEO_FORMAT_xRGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_RGBA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaLast;
        break;
    case GST_VIDEO_FORMAT_RGBx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipLast;
        break;
    default:
        return;
    }

    size_t width = mappedFrame->width();
    size_t height = mappedFrame->height();
    size_t stride = mappedFrame->planeStride(0);
    auto pixels = mappedFrame->planeData(0);
    if (!width || !height || pixels.size() < stride * height)
        return;

    // No pixel copy: the data provider owns the mapped frame (which holds a reference on the
    // underlying GstBuffer), so the pixels stay valid until CoreAnimation releases the image.
    auto provider = adoptCF(CGDataProviderCreateWithData(mappedFrame.get(), pixels.data(), stride * height, releaseMappedVideoFrame));
    if (!provider)
        return;
    mappedFrame.release(); // Now owned by the provider.

    static NeverDestroyed<RetainPtr<CGColorSpaceRef>> colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    auto image = adoptCF(CGImageCreate(width, height, 8, 32, stride, colorSpace.get().get(), bitmapInfo, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    if (!image)
        return;

    // Bake a non-identity source orientation into the pixels; identity streams keep the zero-copy
    // image above. This is what lets every orientation composite through the layer instead of the
    // deadlock-prone software draw-wait path.
    if (orientation.orientation() != ImageOrientation::Orientation::None) {
        if (auto orientedImage = createOrientedImage(image.get(), orientation, width, height, colorSpace.get().get()))
            image = WTF::move(orientedImage);
        else
            return;
    }

    // CALayers may be mutated from any thread inside an explicit transaction. This runs on the
    // GStreamer streaming thread, so frame updates never depend on the main thread being idle.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setContents:(__bridge id)image.get()];
    [CATransaction commit];
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)
