// GStreamer frames use IOSurface-backed CoreVideo buffers for Cocoa rendering and IPC.

#include "config.h"
#include "VideoFrameGStreamer.h"
#include "VideoFrameGStreamerCocoa.h"

#if USE(GSTREAMER) && PLATFORM(COCOA)

#include "CMUtilities.h"
#include "CVUtilities.h"
#include "DestinationColorSpace.h"
#include "GStreamerCommon.h"
#include "GStreamerVideoFrameConverter.h"
#include "LocalSampleBufferDisplayLayer.h"
#include "MediaPlayerPrivateGStreamer.h"
#include "VideoFrameCV.h"
#include "VideoLayerManagerObjC.h"
#include <AVFoundation/AVSampleBufferDisplayLayer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <QuartzCore/CALayer.h>
#include <gst/video/video-frame.h>
#include <pal/cf/CoreMediaSoftLink.h>
#include <wtf/Scope.h>

// Shared with MediaPlayerPrivateMediaStreamAVFObjC.mm.
@interface WebRootSampleBufferBoundsChangeListener : NSObject
- (id)initWithCallback:(WTF::Function<void()>&&)callback;
- (void)begin:(CALayer*)layer;
- (void)invalidate;
@end

namespace WebCore {

#if ENABLE(VIDEO)
std::pair<bool, VideoFrame::Rotation> videoFrameTransformation(ImageOrientation::Orientation orientation)
{
    bool mirrored = orientation == ImageOrientation::Orientation::OriginTopRight || orientation == ImageOrientation::Orientation::OriginBottomLeft
        || orientation == ImageOrientation::Orientation::OriginLeftTop || orientation == ImageOrientation::Orientation::OriginRightBottom;
    auto rotation = VideoFrame::Rotation::None;
    switch (orientation) {
    case ImageOrientation::Orientation::OriginRightTop:
    case ImageOrientation::Orientation::OriginRightBottom: rotation = VideoFrame::Rotation::Right; break;
    case ImageOrientation::Orientation::OriginBottomRight:
    case ImageOrientation::Orientation::OriginBottomLeft: rotation = VideoFrame::Rotation::UpsideDown; break;
    case ImageOrientation::Orientation::OriginLeftBottom:
    case ImageOrientation::Orientation::OriginLeftTop: rotation = VideoFrame::Rotation::Left; break;
    default: break;
    }
    return { mirrored, rotation };
}

DestinationColorSpace MediaPlayerPrivateGStreamer::colorSpace()
{
    if (RefPtr frame = videoFrameForCurrentTime()) {
        if (RetainPtr buffer = frame->pixelBuffer())
            return DestinationColorSpace { createCGColorSpaceForCVPixelBuffer(buffer.get()) };
    }
    return DestinationColorSpace::SRGB();
}

RefPtr<VideoFrame> MediaPlayerPrivateGStreamer::uprightVideoFrame(Ref<VideoFrame>&& frame)
{
    if (!m_videoFrameRotationSession)
        m_videoFrameRotationSession = makeUnique<ImageRotationSessionVT>();
    auto [mirrored, rotation] = videoFrameTransformation(m_videoSourceOrientation.orientation());
    bool swapsDimensions = m_videoSourceOrientation.usesWidthAsHeight();
    // Container mirroring precedes rotation; VideoToolbox flips the output axes.
    ImageRotationSessionVT::RotationProperties properties {
        .flipX = mirrored && !swapsDimensions,
        .flipY = mirrored && swapsDimensions,
        .angle = static_cast<uint16_t>(rotation)
    };
    auto pixelBuffer = m_videoFrameRotationSession->rotate(frame, properties, ImageRotationSessionVT::IsCGImageCompatible::Yes);
    m_rotatedVideoFrameSample = m_sample;
    m_rotatedVideoFrame = nullptr;
    if (pixelBuffer)
        m_rotatedVideoFrame = VideoFrameCV::create(frame->presentationTime(), false, VideoFrame::Rotation::None, WTF::move(pixelBuffer), PlatformVideoColorSpace { frame->colorSpace() });
    return rotatedVideoFrame();
}

RefPtr<VideoFrame> MediaPlayerPrivateGStreamer::rotatedVideoFrame()
{
    if (!m_rotatedVideoFrame)
        return nullptr;
    return VideoFrameCV::create(m_rotatedVideoFrame->presentationTime(), false, VideoFrame::Rotation::None, RetainPtr { m_rotatedVideoFrame->pixelBuffer() }, PlatformVideoColorSpace { m_rotatedVideoFrame->colorSpace() });
}
#endif

// GStreamerVideoFrameConverter.cpp's s_releaseUnusedPipelinesTimerInterval, for the same kind of resource.
static constexpr Seconds releaseUnusedPixelBufferPoolInterval = 30_s;

RetainPtr<CVPixelBufferRef> GStreamerVideoFrameConverter::pooledPixelBuffer(IntSize size, OSType pixelFormat)
{
    // A pool serves one size and format, as in ImageTransferSessionVT::setSize.
    RetainPtr<CVPixelBufferPoolRef> pool;
    {
        Locker locker { m_cvPixelBufferPoolLock };
        auto now = MonotonicTime::now();
        m_cvPixelBufferPools.removeIf([&](auto& entry) {
            return now - entry.value.lastUse > releaseUnusedPixelBufferPoolInterval;
        });
        std::pair<uint64_t, uint32_t> key { (static_cast<uint64_t>(size.width()) << 32) | static_cast<uint32_t>(size.height()), pixelFormat };
        auto iterator = m_cvPixelBufferPools.find(key);
        if (iterator == m_cvPixelBufferPools.end()) {
            auto result = createIOSurfaceCVPixelBufferPool(size.width(), size.height(), pixelFormat);
            if (!result)
                return nullptr;
            iterator = m_cvPixelBufferPools.add(key, CVPixelBufferPoolEntry { WTF::move(*result), now }).iterator;
        }
        iterator->value.lastUse = now;
        pool = iterator->value.pool;
    }
    auto result = createCVPixelBufferFromPool(pool.get());
    if (!result)
        return nullptr;
    return WTF::move(*result);
}

static bool sampleIsDirectlyConvertible(GstSample* sample, const GstVideoInfo& info, IntSize presentationSize)
{
    return gst_caps_features_contains(gst_caps_get_features(gst_sample_get_caps(sample), 0), GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY)
        && presentationSize == IntSize { GST_VIDEO_INFO_WIDTH(&info), GST_VIDEO_INFO_HEIGHT(&info) };
}

static void packRowAs422(const uint8_t* luma, const uint8_t* u, const uint8_t* v, size_t chromaStep, uint8_t* destination, int width)
{
    for (int x = 0; x < width; x += 2) {
        auto chroma = x / 2 * chromaStep;
        destination[2 * x] = u[chroma];
        destination[2 * x + 1] = luma[x];
        destination[2 * x + 2] = v[chroma];
        destination[2 * x + 3] = luma[x + 1 < width ? x + 1 : x];
    }
}

RetainPtr<CVPixelBufferRef> GStreamerVideoFrameConverter::displayLayerPixelBufferFromSample(const GRefPtr<GstSample>& sample, const GstVideoInfo& info, PlatformVideoColorSpace colorSpace)
{
    @autoreleasepool {
        auto format = GST_VIDEO_INFO_FORMAT(&info);
        IntSize size { GST_VIDEO_INFO_WIDTH(&info), GST_VIDEO_INFO_HEIGHT(&info) };
        auto pixelBuffer = pooledPixelBuffer(size, kCVPixelFormatType_422YpCbCr8);
        if (!pixelBuffer)
            return nullptr;
        GstVideoFrame frame;
        if (!gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample.get()), GST_MAP_READ))
            return nullptr;
        auto unmap = makeScopeExit([&] { gst_video_frame_unmap(&frame); });
        if (CVPixelBufferLockBaseAddress(pixelBuffer.get(), 0) != kCVReturnSuccess)
            return nullptr;
        auto unlock = makeScopeExit([pixelBuffer] { CVPixelBufferUnlockBaseAddress(pixelBuffer.get(), 0); });
        auto* destination = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer.get()));
        auto destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer.get());
        auto plane = [&](unsigned index, int row) {
            return static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, index)) + static_cast<ptrdiff_t>(row) * GST_VIDEO_FRAME_PLANE_STRIDE(&frame, index);
        };
        for (int y = 0; y < size.height(); ++y) {
            auto* luma = plane(0, y);
            auto* u = plane(1, y / 2);
            const uint8_t* v = format == GST_VIDEO_FORMAT_NV12 ? u + 1 : plane(2, y / 2);
            size_t chromaStep = format == GST_VIDEO_FORMAT_NV12 ? 2 : 1;
            packRowAs422(luma, u, v, chromaStep, destination + y * destinationStride, size.width());
        }
        CVBufferRemoveAllAttachments(pixelBuffer.get());
        attachColorSpaceToPixelBuffer(colorSpace, pixelBuffer.get());
        return pixelBuffer;
    }
}

RetainPtr<CVPixelBufferRef> GStreamerVideoFrameConverter::pixelBufferFromSample(const GRefPtr<GstSample>& sample, PlatformVideoColorSpace colorSpace)
{
    @autoreleasepool {
        GstVideoInfo info;
        if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample.get())))
            return nullptr;
        auto format = GST_VIDEO_INFO_FORMAT(&info);
        if (format != GST_VIDEO_FORMAT_BGRA && format != GST_VIDEO_FORMAT_NV12 && format != GST_VIDEO_FORMAT_I420)
            return nullptr;
        OSType pixelFormat = format == GST_VIDEO_FORMAT_BGRA ? kCVPixelFormatType_32BGRA
            : colorSpace.fullRange.value_or(false) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        IntSize size { GST_VIDEO_INFO_WIDTH(&info), GST_VIDEO_INFO_HEIGHT(&info) };
        auto pixelBuffer = pooledPixelBuffer(size, pixelFormat);
        if (!pixelBuffer)
            return nullptr;
        GstVideoFrame frame;
        if (!gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample.get()), GST_MAP_READ))
            return nullptr;
        auto unmap = makeScopeExit([&] { gst_video_frame_unmap(&frame); });
        if (CVPixelBufferLockBaseAddress(pixelBuffer.get(), 0) != kCVReturnSuccess)
            return nullptr;
        auto unlock = makeScopeExit([pixelBuffer] { CVPixelBufferUnlockBaseAddress(pixelBuffer.get(), 0); });
        auto copyRows = [&](unsigned plane, uint8_t* destination, size_t destinationStride, size_t rowBytes, size_t rows) {
            auto* source = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, plane));
            auto sourceStride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, plane);
            for (size_t y = 0; y < rows; ++y)
                memcpy(destination + y * destinationStride, source + static_cast<ptrdiff_t>(y) * sourceStride, rowBytes);
        };
        if (format == GST_VIDEO_FORMAT_BGRA) {
            copyRows(0, static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer.get())), CVPixelBufferGetBytesPerRow(pixelBuffer.get()), size.width() * 4, size.height());
            colorSpace.matrix = std::nullopt;
            colorSpace.fullRange = true;
        } else {
            copyRows(0, static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer.get(), 0)), CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer.get(), 0), size.width(), size.height());
            auto chromaWidth = (size.width() + 1) / 2;
            auto chromaHeight = (size.height() + 1) / 2;
            auto* destination = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer.get(), 1));
            auto destinationStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer.get(), 1);
            if (format == GST_VIDEO_FORMAT_NV12)
                copyRows(1, destination, destinationStride, chromaWidth * 2, chromaHeight);
            else {
                auto* u = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1));
                auto* v = static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 2));
                for (int y = 0; y < chromaHeight; ++y) {
                    for (int x = 0; x < chromaWidth; ++x) {
                        destination[x * 2] = u[x];
                        destination[x * 2 + 1] = v[x];
                    }
                    destination += destinationStride;
                    u += GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1);
                    v += GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 2);
                }
            }
        }
        CVBufferRemoveAllAttachments(pixelBuffer.get());
        attachColorSpaceToPixelBuffer(colorSpace, pixelBuffer.get());
        return pixelBuffer;
    }
}

CVPixelBufferRef VideoFrameGStreamer::pixelBuffer() const
{
    Locker locker { m_cvPixelBufferLock };
    if (!m_cvPixelBuffer) {
        auto format = pixelFormat();
        bool directFormat = format == GST_VIDEO_FORMAT_BGRA || format == GST_VIDEO_FORMAT_NV12 || format == GST_VIDEO_FORMAT_I420;
        auto sample = directFormat && sampleIsDirectlyConvertible(m_sample.get(), m_info.info, presentationSize())
            ? m_sample : const_cast<VideoFrameGStreamer*>(this)->downloadSample(GST_VIDEO_FORMAT_BGRA);
        if (sample)
            m_cvPixelBuffer = GStreamerVideoFrameConverter::singleton().pixelBufferFromSample(sample, colorSpace());
    }
    return m_cvPixelBuffer.get();
}

#if ENABLE(VIDEO)
void MediaPlayerPrivateGStreamer::initializeVideoLayer()
{
    m_videoLayerManager = makeUnique<VideoLayerManagerObjC>(m_logger, m_logIdentifier);
    createSampleBufferDisplayLayer();
}

void MediaPlayerPrivateGStreamer::createSampleBufferDisplayLayer()
{
    RefPtr sampleBufferDisplayLayer = LocalSampleBufferDisplayLayer::create(*this);
    if (!sampleBufferDisplayLayer)
        return;
    sampleBufferDisplayLayer->setLogIdentifier(m_logIdentifier);
    // GstBaseSink delivers preroll and clock-scheduled frames, including after pause/seek.
    sampleBufferDisplayLayer->setRenderPolicy(SampleBufferDisplayLayer::RenderPolicy::Immediately);
    sampleBufferDisplayLayer->initialize(false, { }, m_shouldMaintainAspectRatio, [](bool) { });
    // Frames are displayed immediately, so the control timebase stays stopped; Mavericks' display
    // layer polls at the display refresh rate while its timebase runs.
    CMTimebaseRef timebase = nullptr;
    if (PAL::CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, PAL::CMClockGetHostTimeClock(), &timebase) == noErr) {
        PAL::CMTimebaseSetRate(timebase, 0);
        [(AVSampleBufferDisplayLayer *)sampleBufferDisplayLayer->displayLayer() setControlTimebase:adoptCF(timebase).get()];
    }
    m_videoLayerManager->setVideoLayer(sampleBufferDisplayLayer->rootLayer(), { });
    m_videoLayerBoundsObserver = adoptNS([[WebRootSampleBufferBoundsChangeListener alloc] initWithCallback:[weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr self = weakThis.get())
            self->m_sampleBufferDisplayLayer->updateBoundsAndPosition(self->m_sampleBufferDisplayLayer->rootLayer().bounds);
    }]);
    [m_videoLayerBoundsObserver begin:sampleBufferDisplayLayer->rootLayer()];
    Locker locker { m_videoLayerLock };
    m_sampleBufferDisplayLayer = WTF::move(sampleBufferDisplayLayer);
}

void MediaPlayerPrivateGStreamer::setShouldMaintainAspectRatio(bool shouldMaintainAspectRatio)
{
    ASSERT(isMainThread());
    m_shouldMaintainAspectRatio = shouldMaintainAspectRatio;
    if (RefPtr sampleBufferDisplayLayer = m_sampleBufferDisplayLayer)
        sampleBufferDisplayLayer->setShouldMaintainAspectRatio(shouldMaintainAspectRatio);
}

void MediaPlayerPrivateGStreamer::destroyVideoLayer()
{
    [m_videoLayerBoundsObserver invalidate];
    m_videoLayerBoundsObserver = nullptr;
    m_videoLayerManager->didDestroyVideoLayer();
    RefPtr<SampleBufferDisplayLayer> sampleBufferDisplayLayer;
    Locker locker { m_videoLayerLock };
    sampleBufferDisplayLayer = std::exchange(m_sampleBufferDisplayLayer, nullptr);
}

// A failed layer stays failed, so the presenter replaces it.
void MediaPlayerPrivateGStreamer::sampleBufferDisplayLayerStatusDidFail()
{
    destroyVideoLayer();
    createSampleBufferDisplayLayer();
    if (RefPtr player = m_player.get())
        player->renderingModeChanged();
    pushSampleToVideoLayer(true);
}

void MediaPlayerPrivateGStreamer::updateVideoFrameCounters(uint64_t totalFrameCount, uint64_t droppedFrameCount)
{
    m_totalVideoFrames = totalFrameCount;
    m_droppedVideoFrames = droppedFrameCount;
}

PlatformLayer* MediaPlayerPrivateGStreamer::platformLayer() const
{
    return m_videoLayerManager->videoInlineLayer();
}

// A hidden page's player enqueues no frames, as MediaPlayerPrivateMediaStreamAVFObjC enqueues none:
// Mavericks' display layer holds every frame it is given until it is displayed. The layer is flushed
// as the page's visibility changes, and shows the current frame again once the page is visible.
void MediaPlayerPrivateGStreamer::setPageIsVisible(bool visible)
{
    m_pageIsVisible = visible;
    {
        Locker locker { m_videoLayerLock };
        if (m_videoLayerPageIsVisible == visible)
            return;
        m_videoLayerPageIsVisible = visible;
        if (m_sampleBufferDisplayLayer)
            m_sampleBufferDisplayLayer->flush();
    }
    if (visible)
        pushSampleToVideoLayer(true);
}

void MediaPlayerPrivateGStreamer::setInlineOutputSuppressed(bool suppressed)
{
    m_inlineAudioOutput.setSuppressed(suppressed);
    {
        Locker locker { m_videoLayerLock };
        if (std::exchange(m_inlineVideoOutputSuppressed, suppressed) == suppressed)
            return;
        if (m_sampleBufferDisplayLayer)
            m_sampleBufferDisplayLayer->flush();
    }
    if (!suppressed)
        pushSampleToVideoLayer(true);
}

void MediaPlayerPrivateGStreamer::pushSampleToVideoLayer(bool isDuplicateSample)
{
    Locker layerLocker { m_videoLayerLock };
    if (!m_sampleBufferDisplayLayer)
        return;
    GRefPtr<GstSample> sample;
    ImageOrientation::Orientation orientation;
    {
        Locker locker { m_sampleMutex };
        sample = m_sample;
        if (!sample)
            return;
        orientation = m_videoSourceOrientation.orientation();
        if (!isDuplicateSample)
            ++m_sampleCount;
    }
    if (!m_videoLayerPageIsVisible || m_inlineVideoOutputSuppressed)
        return;
    Ref frame = VideoFrameGStreamer::createWrappedSample(sample);
    auto format = GST_VIDEO_INFO_FORMAT(&frame->info());
    auto colorSpace = frame->colorSpace();
    // Video-range 4:2:0 is repacked as 4:2:2 for the display layer.
    bool packsAs422 = (format == GST_VIDEO_FORMAT_NV12 || format == GST_VIDEO_FORMAT_I420) && !colorSpace.fullRange.value_or(false)
        && sampleIsDirectlyConvertible(sample.get(), frame->info(), frame->presentationSize());
    RetainPtr pixelBuffer = packsAs422 ? GStreamerVideoFrameConverter::singleton().displayLayerPixelBufferFromSample(sample, frame->info(), colorSpace) : RetainPtr { static_cast<VideoFrame&>(frame.get()).pixelBuffer() };
    if (!pixelBuffer)
        return;
    auto [mirrored, rotation] = videoFrameTransformation(orientation);
    // LocalSampleBufferDisplayLayer takes presentation times on the host clock (MonotonicTime), as
    // capture and WebRTC frames carry them; GstBaseSink has already clock-scheduled this frame, which
    // is enqueued for immediate display.
    auto displayFrame = VideoFrameCV::create(MediaTime::createWithDouble(MonotonicTime::now().secondsSinceEpoch().value()), mirrored, rotation, WTF::move(pixelBuffer));
    m_sampleBufferDisplayLayer->enqueueVideoFrame(displayFrame);
}

#if ENABLE(VIDEO_PRESENTATION_MODE)
void MediaPlayerPrivateGStreamer::setVideoFullscreenLayer(PlatformLayer* layer, Function<void()>&& completionHandler)
{
    RefPtr frame = videoFrameForCurrentTime();
    RefPtr image = frame ? frame->copyNativeImage() : nullptr;
    m_videoLayerManager->setVideoFullscreenLayer(layer, WTF::move(completionHandler), image ? image->platformImage() : nullptr);
}

void MediaPlayerPrivateGStreamer::setVideoFullscreenFrame(const FloatRect& frame)
{
    m_videoLayerManager->setVideoFullscreenFrame(frame);
}
#endif
#endif

GRefPtr<GstSample> gstSampleFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, const MediaTime& presentationTime, const PlatformVideoColorSpace& colorSpace)
{
    if (!pixelBuffer)
        return nullptr;

    auto width = static_cast<int>(CVPixelBufferGetWidth(pixelBuffer));
    auto height = static_cast<int>(CVPixelBufferGetHeight(pixelBuffer));
    if (width <= 0 || height <= 0)
        return nullptr;

    GstVideoFormat videoFormat;
    switch (CVPixelBufferGetPixelFormatType(pixelBuffer)) {
    case kCVPixelFormatType_32BGRA:
        videoFormat = GST_VIDEO_FORMAT_BGRA;
        break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        videoFormat = GST_VIDEO_FORMAT_NV12;
        break;
    default:
        return nullptr;
    }

    GstVideoInfo videoInfo;
    gst_video_info_set_format(&videoInfo, videoFormat, width, height);
    fillVideoInfoColorimetryFromColorSpace(&videoInfo, colorSpace);
    // A BGRA buffer carries no YCbCr matrix attachment, so the matrix GStreamer requires is supplied here.
    if (videoFormat == GST_VIDEO_FORMAT_BGRA)
        videoInfo.colorimetry.matrix = GST_VIDEO_COLOR_MATRIX_RGB;

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return nullptr;
    auto unlock = makeScopeExit([&] {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    });

    // Video metadata carries CoreVideo's row strides and plane offsets.
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

    auto caps = adoptGRef(gst_video_info_to_caps(&videoInfo));
    return adoptGRef(gst_sample_new(buffer.get(), caps.get(), nullptr, nullptr));
}

} // namespace WebCore

#endif // USE(GSTREAMER) && PLATFORM(COCOA)
