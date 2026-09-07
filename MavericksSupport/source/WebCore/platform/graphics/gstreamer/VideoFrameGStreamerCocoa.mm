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
#include "GStreamerCommon.h"
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

// The reverse direction. WebCodecs frames are VideoFrameCV on this build -- the shared
// VideoFrame::createFromPixelBuffer factories come from VideoFrameCV on Cocoa -- while the GStreamer
// encoder takes a GstSample, so a CoreVideo frame reaching it needs wrapping. The copy is one memcpy
// per plane out of the locked CVPixelBuffer; the caps name the layout CoreVideo reports rather than
// converting, so the encoder negotiates the format it was already given.
GRefPtr<GstSample> gstSampleFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, const MediaTime& presentationTime)
{
    if (!pixelBuffer)
        return nullptr;

    auto width = static_cast<int>(CVPixelBufferGetWidth(pixelBuffer));
    auto height = static_cast<int>(CVPixelBufferGetHeight(pixelBuffer));
    if (width <= 0 || height <= 0)
        return nullptr;

    // NV12 names limited-range Y'CbCr in GStreamer, so the full-range CoreVideo format carries the
    // matching colorimetry rather than being silently read as limited. The full-range string is derived
    // from BT.601 with the range replaced, not written out: the numeric form is
    // range:matrix:transfer:primaries and gst_video_colorimetry_from_string does not validate the
    // fields, so a hand-written quadruple parses and then propagates whatever it says.
    ASCIILiteral format;
    char* colorimetry = nullptr;
    GstVideoFormat videoFormat;
    switch (CVPixelBufferGetPixelFormatType(pixelBuffer)) {
    case kCVPixelFormatType_32BGRA:
        format = "BGRA"_s;
        videoFormat = GST_VIDEO_FORMAT_BGRA;
        break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        format = "NV12"_s;
        videoFormat = GST_VIDEO_FORMAT_NV12;
        colorimetry = g_strdup(GST_VIDEO_COLORIMETRY_BT601);
        break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
        format = "NV12"_s;
        videoFormat = GST_VIDEO_FORMAT_NV12;
        GstVideoColorimetry fullRange;
        if (gst_video_colorimetry_from_string(&fullRange, GST_VIDEO_COLORIMETRY_BT601)) {
            fullRange.range = GST_VIDEO_COLOR_RANGE_0_255;
            colorimetry = gst_video_colorimetry_to_string(&fullRange);
        }
        break;
    }
    default:
        return nullptr;
    }
    auto freeColorimetry = makeScopeExit([&] {
        if (colorimetry)
            g_free(colorimetry);
    });

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return nullptr;
    auto unlock = makeScopeExit([&] {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    });

    // CoreVideo pads each row to its own alignment -- a 300-wide BGRA buffer reports 1216 bytes per row,
    // not 1200 -- so the rows are copied at the source stride and the real strides and plane offsets are
    // declared on the buffer. Without that meta, downstream derives both from the caps and reads every
    // row after the first at the wrong offset.
    auto planeCount = CVPixelBufferIsPlanar(pixelBuffer) ? CVPixelBufferGetPlaneCount(pixelBuffer) : 0;
    gsize planeOffsets[GST_VIDEO_MAX_PLANES] = { 0, };
    gint planeStrides[GST_VIDEO_MAX_PLANES] = { 0, };
    size_t totalSize = 0;
    if (!planeCount) {
        planeStrides[0] = static_cast<gint>(CVPixelBufferGetBytesPerRow(pixelBuffer));
        totalSize = planeStrides[0] * height;
    } else {
        for (size_t plane = 0; plane < planeCount; ++plane) {
            planeOffsets[plane] = totalSize;
            planeStrides[plane] = static_cast<gint>(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane));
            totalSize += planeStrides[plane] * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
        }
    }
    if (!totalSize)
        return nullptr;

    auto buffer = adoptGRef(gst_buffer_new_allocate(nullptr, totalSize, nullptr));
    if (!buffer)
        return nullptr;

    GstMapInfo map;
    if (!gst_buffer_map(buffer.get(), &map, GST_MAP_WRITE))
        return nullptr;
    if (!planeCount)
        memcpy(map.data, CVPixelBufferGetBaseAddress(pixelBuffer), totalSize);
    else {
        for (size_t plane = 0; plane < planeCount; ++plane) {
            auto planeSize = planeStrides[plane] * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
            memcpy(map.data + planeOffsets[plane], CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), planeSize);
        }
    }
    gst_buffer_unmap(buffer.get(), &map);

    gst_buffer_add_video_meta_full(buffer.get(), GST_VIDEO_FRAME_FLAG_NONE, videoFormat, width, height,
        planeCount ? planeCount : 1, planeOffsets, planeStrides);

    GST_BUFFER_DTS(buffer.get()) = GST_BUFFER_PTS(buffer.get()) = toValidGstClockTime(presentationTime);

    auto caps = adoptGRef(gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, format.characters(),
        "width", G_TYPE_INT, width, "height", G_TYPE_INT, height, nullptr));
    if (colorimetry)
        gst_caps_set_simple(caps.get(), "colorimetry", G_TYPE_STRING, colorimetry, nullptr);
    return adoptGRef(gst_sample_new(buffer.get(), caps.get(), nullptr, nullptr));
}

} // namespace WebCore

#endif // USE(GSTREAMER) && PLATFORM(COCOA)
