/*
 * Copyright (C) 2010, 2011, 2012 Igalia S.L
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

// MAVERICKS_BACKPORT: CoreGraphics implementation of the ImageGStreamer seam. The upstream tree only
// ships ImageGStreamerSkia.cpp (USE(SKIA)); the GTK/WPE ports otherwise composite GStreamer frames
// through Cairo/TextureMapper, neither of which exists on this Cocoa software build. This converts a
// decoded RGB GstSample into a CGImage so MediaPlayerPrivateGStreamer::paint() (and the appsink
// frame pump) can draw <video> through the normal CG path, exactly as ImageGStreamerSkia does for Skia.

#include "config.h"
#include "ImageGStreamer.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)

#include "GStreamerCommon.h"
#include <CoreGraphics/CoreGraphics.h>
#include <wtf/RetainPtr.h>

namespace WebCore {

ImageGStreamer::ImageGStreamer(GRefPtr<GstSample>&& sample)
    : m_sample(WTF::move(sample))
{
    GstBuffer* buffer = gst_sample_get_buffer(m_sample.get());
    if (!GST_IS_BUFFER(buffer)) [[unlikely]]
        return;

    GstMappedFrame videoFrame(m_sample, GST_MAP_READ);
    if (!videoFrame)
        return;

    // The frame has to be RGB so we can paint it.
    ASSERT(GST_VIDEO_INFO_IS_RGB(videoFrame.info()));

    // GStreamer hands us a packed 32-bit RGB frame. Map each layout to the matching CG byte order +
    // alpha combination. The video sink is configured for { BGRx, BGRA } on little-endian (the common
    // case the negotiated caps request), but accept the other packings too. GStreamer's RGBA/BGRA is
    // NOT alpha-premultiplied (mirrors ImageGStreamerSkia's kUnpremul_SkAlphaType), so use the plain
    // (non-premultiplied) alpha-first / alpha-last variants; the x-padded formats are opaque.
    CGBitmapInfo bitmapInfo;
    switch (videoFrame.format()) {
    case GST_VIDEO_FORMAT_BGRA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaFirst;
        m_hasAlpha = true;
        break;
    case GST_VIDEO_FORMAT_BGRx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_ARGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaFirst;
        m_hasAlpha = true;
        break;
    case GST_VIDEO_FORMAT_xRGB:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipFirst;
        break;
    case GST_VIDEO_FORMAT_RGBA:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaLast;
        m_hasAlpha = true;
        break;
    case GST_VIDEO_FORMAT_RGBx:
        bitmapInfo = static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big) | kCGImageAlphaNoneSkipLast;
        break;
    default:
        ASSERT_NOT_REACHED();
        return;
    }

    int width = videoFrame.width();
    int height = videoFrame.height();
    int stride = videoFrame.planeStride(0);
    m_size = FloatSize(width, height);

    auto planeData = videoFrame.planeData(0);
    // Copy the pixels: the mapped GstVideoFrame is unmapped when videoFrame goes out of scope, so the
    // CGImage must own its own backing store (mirrors ImageGStreamerSkia's RasterFromPixmapCopy).
    RetainPtr<CFDataRef> pixelData = adoptCF(CFDataCreate(nullptr, planeData.data(), static_cast<CFIndex>(stride) * height));
    if (!pixelData)
        return;

    RetainPtr<CGDataProviderRef> provider = adoptCF(CGDataProviderCreateWithCFData(pixelData.get()));
    RetainPtr<CGColorSpaceRef> colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    m_image = adoptCF(CGImageCreate(width, height, 8, 32, stride, colorSpace.get(), bitmapInfo,
        provider.get(), nullptr, false, kCGRenderingIntentDefault));

    if (auto* cropMeta = gst_buffer_get_video_crop_meta(buffer))
        m_cropRect = FloatRect(cropMeta->x, cropMeta->y, cropMeta->width, cropMeta->height);
}

ImageGStreamer::~ImageGStreamer() = default;

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)
