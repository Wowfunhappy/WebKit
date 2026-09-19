#include "config.h"

#include "Test.h"
#include "GStreamerVideoFrameConverter.h"
#include <WebCore/PlatformVideoColorSpace.h>
#include <CoreVideo/CoreVideo.h>
#include <gst/video/video.h>
#include <wtf/Scope.h>

namespace TestWebKitAPI {
using namespace WebCore;

static GRefPtr<GstSample> makeSample(GstVideoFormat format, unsigned width, unsigned height, bool reverseRows)
{
    GstVideoInfo info;
    gst_video_info_set_format(&info, format, width, height);
    gsize offsets[GST_VIDEO_MAX_PLANES] { };
    gint strides[GST_VIDEO_MAX_PLANES] { };
    unsigned planes = format == GST_VIDEO_FORMAT_I420 ? 3 : format == GST_VIDEO_FORMAT_NV12 ? 2 : 1;
    size_t length = 0;
    for (unsigned plane = 0; plane < planes; ++plane) {
        unsigned rows = plane ? (height + 1) / 2 : height;
        unsigned columns = plane ? (width + 1) / 2 : width;
        unsigned bytes = format == GST_VIDEO_FORMAT_BGRA ? 4 : format == GST_VIDEO_FORMAT_NV12 && plane ? 2 : 1;
        strides[plane] = columns * bytes + 13;
        offsets[plane] = length;
        length += rows * strides[plane];
        if (reverseRows) {
            offsets[plane] += (rows - 1) * strides[plane];
            strides[plane] = -strides[plane];
        }
    }
    auto buffer = adoptGRef(gst_buffer_new_allocate(nullptr, length, nullptr));
    gst_buffer_add_video_meta_full(buffer.get(), GST_VIDEO_FRAME_FLAG_NONE, format, width, height, planes, offsets, strides);
    GstMapInfo map;
    if (!gst_buffer_map(buffer.get(), &map, GST_MAP_WRITE))
        return nullptr;
    memset(map.data, 0xEE, map.size);
    for (unsigned y = 0; y < height; ++y) {
        auto* row = map.data + offsets[0] + static_cast<ptrdiff_t>(y) * strides[0];
        for (unsigned x = 0; x < width; ++x) {
            if (format == GST_VIDEO_FORMAT_BGRA) {
                row[x * 4] = 16 + x;
                row[x * 4 + 1] = 32 + y;
                row[x * 4 + 2] = 64;
                row[x * 4 + 3] = 255;
            } else
                row[x] = 16 + x + y * 7;
        }
    }
    if (format != GST_VIDEO_FORMAT_BGRA) {
        for (unsigned y = 0; y < (height + 1) / 2; ++y) {
            auto* u = map.data + offsets[1] + static_cast<ptrdiff_t>(y) * strides[1];
            auto* v = format == GST_VIDEO_FORMAT_I420 ? map.data + offsets[2] + static_cast<ptrdiff_t>(y) * strides[2] : u + 1;
            for (unsigned x = 0; x < (width + 1) / 2; ++x) {
                unsigned index = format == GST_VIDEO_FORMAT_NV12 ? x * 2 : x;
                u[index] = 64 + x + y * 3;
                v[index] = 128 + x + y * 3;
            }
        }
    }
    gst_buffer_unmap(buffer.get(), &map);
    auto caps = adoptGRef(gst_video_info_to_caps(&info));
    return adoptGRef(gst_sample_new(buffer.get(), caps.get(), nullptr, nullptr));
}

static void checkBuffer(GstVideoFormat format, unsigned width, unsigned height, bool reverseRows, bool fullRange)
{
    auto& converter = GStreamerVideoFrameConverter::singleton();
    auto sample = makeSample(format, width, height, reverseRows);
    ASSERT_NE(sample, nullptr);
    PlatformVideoColorSpace color { PlatformVideoColorPrimaries::Bt709, PlatformVideoTransferCharacteristics::Bt709, PlatformVideoMatrixCoefficients::Bt709, fullRange };
    auto buffer = converter.pixelBufferFromSample(sample, color);
    ASSERT_NE(buffer, nullptr);
    EXPECT_NE(CVPixelBufferGetIOSurface(buffer.get()), nullptr);
    EXPECT_EQ(CVPixelBufferGetWidth(buffer.get()), width);
    EXPECT_EQ(CVPixelBufferGetHeight(buffer.get()), height);
    OSType expectedFormat = format == GST_VIDEO_FORMAT_BGRA ? kCVPixelFormatType_32BGRA
        : fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    EXPECT_EQ(CVPixelBufferGetPixelFormatType(buffer.get()), expectedFormat);
    ASSERT_EQ(CVPixelBufferLockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly), kCVReturnSuccess);
    auto unlock = makeScopeExit([&] { CVPixelBufferUnlockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly); });
    bool planar = format != GST_VIDEO_FORMAT_BGRA;
    auto* base = static_cast<const uint8_t*>(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer.get(), 0) : CVPixelBufferGetBaseAddress(buffer.get()));
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer.get(), 0) : CVPixelBufferGetBytesPerRow(buffer.get());
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x) {
            if (planar)
                EXPECT_EQ(base[y * stride + x], 16 + x + y * 7);
            else {
                auto* pixel = base + y * stride + x * 4;
                EXPECT_EQ(pixel[0], 16 + x);
                EXPECT_EQ(pixel[1], 32 + y);
                EXPECT_EQ(pixel[2], 64);
                EXPECT_EQ(pixel[3], 255);
            }
        }
    }
    if (planar) {
        base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer.get(), 1));
        stride = CVPixelBufferGetBytesPerRowOfPlane(buffer.get(), 1);
        for (unsigned y = 0; y < (height + 1) / 2; ++y) {
            for (unsigned x = 0; x < (width + 1) / 2; ++x) {
                EXPECT_EQ(base[y * stride + x * 2], 64 + x + y * 3);
                EXPECT_EQ(base[y * stride + x * 2 + 1], 128 + x + y * 3);
            }
        }
        auto matrix = CVBufferGetAttachment(buffer.get(), kCVImageBufferYCbCrMatrixKey, nullptr);
        ASSERT_NE(matrix, nullptr);
        EXPECT_TRUE(CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2));
    }
    auto second = converter.pixelBufferFromSample(sample, color);
    ASSERT_NE(second, nullptr);
    EXPECT_NE(second.get(), buffer.get());
}

TEST(GStreamerCocoaPixelBuffer, PaddedPlanesAndPoolFormatChanges)
{
    for (auto format : { GST_VIDEO_FORMAT_NV12, GST_VIDEO_FORMAT_I420, GST_VIDEO_FORMAT_BGRA }) {
        for (bool fullRange : { false, true })
            checkBuffer(format, 6, 4, false, fullRange);
    }
}

TEST(GStreamerCocoaPixelBuffer, OddDimensionsAndNegativeStrides)
{
    for (auto format : { GST_VIDEO_FORMAT_NV12, GST_VIDEO_FORMAT_I420, GST_VIDEO_FORMAT_BGRA })
        checkBuffer(format, 5, 3, true, false);
}

} // namespace TestWebKitAPI
