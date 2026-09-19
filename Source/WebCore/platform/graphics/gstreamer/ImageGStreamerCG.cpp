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

// MAVERICKS_BACKPORT: CoreGraphics implementation of the ImageGStreamer seam; upstream ships only
// ImageGStreamerSkia.cpp. A decoded sample becomes a CGImage through VideoFrame::copyNativeImage(), the
// conversion every Cocoa VideoFrame takes: VideoToolbox converts the frame's CVPixelBuffer to BGRA and
// the image carries the colour space of that buffer's colour attachments.

#include "config.h"
#include "ImageGStreamer.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)

#include "GStreamerCommon.h"
#include "NativeImage.h"
#include "VideoFrameGStreamer.h"

namespace WebCore {

ImageGStreamer::ImageGStreamer(GRefPtr<GstSample>&& sample)
    : m_sample(WTF::move(sample))
{
    GstBuffer* buffer = gst_sample_get_buffer(m_sample.get());
    if (!GST_IS_BUFFER(buffer)) [[unlikely]]
        return;

    Ref frame = VideoFrameGStreamer::createWrappedSample(m_sample);
    RefPtr image = frame->copyNativeImage();
    if (!image)
        return;

    m_image = image->platformImage();
    m_size = image->size();
    m_hasAlpha = GST_VIDEO_INFO_HAS_ALPHA(&frame->info());

    if (auto* cropMeta = gst_buffer_get_video_crop_meta(buffer))
        m_cropRect = FloatRect(cropMeta->x, cropMeta->y, cropMeta->width, cropMeta->height);
}

ImageGStreamer::~ImageGStreamer() = default;

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)
