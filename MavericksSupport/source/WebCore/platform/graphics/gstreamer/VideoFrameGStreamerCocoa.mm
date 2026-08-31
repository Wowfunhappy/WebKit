/*
 * VideoFrameGStreamer::pixelBuffer() for the Cocoa+GStreamer build.
 *
 * VideoFrame::pixelBuffer() answers null unless the frame is CoreVideo-backed. With DOM rendering
 * remote, drawImage(video) reaches RemoteGraphicsContextProxy::drawVideoFrame, which ships the frame
 * to the GPU process through SharedVideoFrameWriter::write -> writeBuffer(frame.pixelBuffer()).
 * Without an answer here that carries nothing for a GStreamer-backed frame and the canvas draws an
 * empty rect. The GPU process rebuilds what it receives as a VideoFrameCV, so this is the only
 * direction a GStreamer frame travels.
 *
 * This lives outside VideoFrameGStreamer.cpp because that file is compiled into a unified source,
 * and <CoreVideo/CVPixelBuffer.h> pulls in ApplicationServices -> QuickDraw, whose global `Style`
 * is ambiguous against WebCore::Style in any bundle that also has `using namespace WebCore`.
 */

#include "config.h"
#include "VideoFrameGStreamer.h"

#if USE(GSTREAMER) && PLATFORM(COCOA)

#include "CVUtilities.h"
#include <CoreVideo/CVPixelBuffer.h>
#include <gst/video/video-frame.h>
#include <wtf/Scope.h>

namespace WebCore {

// Locked because VideoFrame is ThreadSafeRefCounted and this is reached from a background thread.
// The frame is downloaded to BGRA and copied into an IOSurface-backed CVPixelBuffer: that is the
// backing every Cocoa consumer of this path expects. SharedVideoFrameWriter::writeBuffer sends an
// IOSurface straight across as a Mach send right, and its shared-memory fallback reads the pixels
// with CVPixelBufferGetBaseAddressOfPlane(), which answers null for a non-planar buffer -- so a
// plain CVPixelBufferCreateWithBytes() wrapper of the mapped GstVideoFrame reaches neither path and
// the frame is dropped before it is sent.
CVPixelBufferRef VideoFrameGStreamer::pixelBuffer() const
{
    Locker locker { m_cvPixelBufferLock };
    if (m_cvPixelBuffer)
        return m_cvPixelBuffer.get();

    auto sample = const_cast<VideoFrameGStreamer*>(this)->downloadSample(GST_VIDEO_FORMAT_BGRA);
    if (!sample)
        return nullptr;

    GstVideoInfo videoInfo;
    if (!gst_video_info_from_caps(&videoInfo, gst_sample_get_caps(sample.get())))
        return nullptr;

    GstVideoFrame frame;
    if (!gst_video_frame_map(&frame, &videoInfo, gst_sample_get_buffer(sample.get()), GST_MAP_READ))
        return nullptr;

    auto unmapFrame = makeScopeExit([&] {
        gst_video_frame_unmap(&frame);
    });

    auto width = GST_VIDEO_FRAME_WIDTH(&frame);
    auto height = GST_VIDEO_FRAME_HEIGHT(&frame);
    auto pool = createIOSurfaceCVPixelBufferPool(width, height, kCVPixelFormatType_32BGRA, 1, true);
    if (!pool)
        return nullptr;
    auto buffer = createCVPixelBufferFromPool(pool->get());
    if (!buffer)
        return nullptr;

    if (CVPixelBufferLockBaseAddress(buffer->get(), 0) != kCVReturnSuccess)
        return nullptr;
    auto* destination = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer->get()));
    auto destinationStride = CVPixelBufferGetBytesPerRow(buffer->get());
    auto* source = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
    auto sourceStride = static_cast<size_t>(GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0));
    auto rowBytes = std::min(destinationStride, sourceStride);
    for (int row = 0; row < height; ++row)
        memcpy(destination + row * destinationStride, source + row * sourceStride, rowBytes);
    CVPixelBufferUnlockBaseAddress(buffer->get(), 0);

    m_cvPixelBuffer = WTF::move(*buffer);
    return m_cvPixelBuffer.get();
}

} // namespace WebCore

#endif // USE(GSTREAMER) && PLATFORM(COCOA)
