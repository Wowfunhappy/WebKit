/*
 * Copyright (C) 2020 Igalia S.L
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
 * aint with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "ImageDecoderGStreamer.h"

#if USE(GSTREAMER) && ENABLE(VIDEO)

#include "FloatSize.h"
#include "GStreamerRegistryScanner.h"
#include "ImageGStreamer.h"
#include "MediaSampleGStreamer.h"
#include "VideoFrameGStreamer.h"
#include <gst/base/gsttypefindhelper.h>
#include <wtf/MainThread.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ImageDecoderGStreamer);

GST_DEBUG_CATEGORY(webkit_image_decoder_debug);
#define GST_CAT_DEFAULT webkit_image_decoder_debug

static Lock s_decoderLock;
static Vector<RefPtr<ImageDecoderGStreamer>> s_imageDecoders;

static void ensureDebugCategoryIsInitialized()
{
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [] {
        GST_DEBUG_CATEGORY_INIT(webkit_image_decoder_debug, "webkitimagedecoder", 0, "WebKit image decoder");
    });
}

void teardownGStreamerImageDecoders()
{
    Locker lock { s_decoderLock };
    for (auto& decoder : s_imageDecoders)
        decoder->tearDown();
    s_imageDecoders.clear();
}

class ImageDecoderGStreamerSample final : public MediaSampleGStreamer {
public:
    static Ref<ImageDecoderGStreamerSample> create(GRefPtr<GstSample>&& sample, const FloatSize& presentationSize)
    {
        return adoptRef(*new ImageDecoderGStreamerSample(WTF::move(sample), presentationSize));
    }

    PlatformImagePtr image() const
    {
        if (!m_image)
            return nullptr;
        return m_image->image();
    }
    void dropImage()
    {
        m_image = nullptr;
        m_frame = nullptr;
    }

    SampleFlags flags() const override
    {
        return (SampleFlags)(MediaSampleGStreamer::flags() | (m_image && m_image->hasAlpha() ? HasAlpha : 0));
    }

private:
    ImageDecoderGStreamerSample(GRefPtr<GstSample>&& sample, const FloatSize& presentationSize)
        : MediaSampleGStreamer(WTF::move(sample), presentationSize, { })
        , m_frame(VideoFrameGStreamer::createWrappedSample(this->sample()))
    {
        m_image = m_frame->convertToImage();
    }

    RefPtr<VideoFrameGStreamer> m_frame;
    RefPtr<ImageGStreamer> m_image;
};

static ImageDecoderGStreamerSample* toSample(const PresentationOrderSampleMap::value_type& pair)
{
    return (ImageDecoderGStreamerSample*)pair.second.ptr();
}

template <typename Iterator>
ImageDecoderGStreamerSample* toSample(Iterator iter)
{
    return (ImageDecoderGStreamerSample*)iter->second.ptr();
}

RefPtr<ImageDecoderGStreamer> ImageDecoderGStreamer::create(FragmentedSharedBuffer& data, const String& mimeType, AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
{
    RefPtr decoder = adoptRef(*new ImageDecoderGStreamer(data, mimeType, alphaOption, gammaAndColorProfileOption));
    {
        Locker lock { s_decoderLock };
        s_imageDecoders.append(decoder);
    }
    return decoder;
}

ImageDecoderGStreamer::ImageDecoderGStreamer(FragmentedSharedBuffer& data, const String& mimeType, AlphaOption, GammaAndColorProfileOption)
    : m_mimeType(mimeType)
{
    ensureDebugCategoryIsInitialized();
    static Atomic<uint32_t> decoderId;
    GRefPtr<GstElement> parsebin = gst_element_factory_make("parsebin", makeString("image-decoder-parser-"_s, decoderId.exchangeAdd(1)).utf8().data());
    m_parserHarness = GStreamerElementHarness::create(WTF::move(parsebin), [](auto&, auto&&) { }, [this](auto& pad) -> RefPtr<GStreamerElementHarness> {
        auto caps = adoptGRef(gst_pad_query_caps(pad.get(), nullptr));
        auto identityHarness = GStreamerElementHarness::create(GRefPtr<GstElement>(gst_element_factory_make("identity", nullptr)), [](auto&, const auto&) { });
        GST_DEBUG_OBJECT(pad.get(), "Caps on parser source pad: %" GST_PTR_FORMAT, caps.get());
        if (!caps || !doCapsHaveType(caps.get(), "video"_s)) {
            GST_WARNING_OBJECT(m_decoderHarness->element(), "Ignoring non-video track");
            return identityHarness;
        }

        if (m_decoderHarness) {
            GST_WARNING_OBJECT(m_decoderHarness->element(), "Decoder already configured, ignoring additional video track");
            return identityHarness;
        }

        auto& scanner = GStreamerRegistryScanner::singleton();
        auto lookupResult = scanner.areCapsSupported(GStreamerRegistryScanner::Configuration::Decoding, caps, false);
        if (!lookupResult) {
            GST_WARNING_OBJECT(m_parserHarness->element(), "No decoder found for caps %" GST_PTR_FORMAT, caps.get());
            return identityHarness;
        }

        GRefPtr<GstElement> element = gst_element_factory_create(lookupResult.factory.get(), nullptr);
        configureVideoDecoderForHarnessing(element);
        // MAVERICKS_BACKPORT: name the memory this decoder can read, the way GStreamerInternalVideoDecoder
        // already does for the same element class (VideoDecoderGStreamer.cpp). Left unconstrained, vtdec --
        // the factory the registry scanner prefers for H.264 here -- negotiates the
        // video/x-raw(memory:GLMemory) its src template lists first and then produces nothing, because
        // USE(GSTREAMER_GL) is 0 in this port and no GstGLDisplay exists to back it.
        auto allowedSinkCaps = adoptGRef(gst_caps_new_empty());
#if USE(GSTREAMER_GL)
        gst_caps_append(allowedSinkCaps.get(), gst_caps_from_string("video/x-raw(memory:GLMemory)"));
#endif
        gst_caps_append(allowedSinkCaps.get(), gst_caps_from_string("video/x-raw"));
        // m_decoderHarness = GStreamerElementHarness::create(WTF::move(element), [this](auto&, auto&& outputSample) {
        //     storeDecodedSample(WTF::move(outputSample));
        // });
        m_decoderHarness = GStreamerElementHarness::create(WTF::move(element), [this](auto&, auto&& outputSample) {
            storeDecodedSample(WTF::move(outputSample));
        }, std::nullopt, WTF::move(allowedSinkCaps)); // MAVERICKS_BACKPORT: closes the allowed-caps request described above.
        return m_decoderHarness;
    });

    pushEncodedData(data);
}

ImageDecoderGStreamer::~ImageDecoderGStreamer()
{
    tearDown();
}

void ImageDecoderGStreamer::tearDown()
{
    m_sampleData.clear();
    m_decoderHarness = nullptr;
    m_parserHarness = nullptr;
}

// MAVERICKS_BACKPORT: the two image types this decoder answers for beside the video ones.
#if HAVE(HEIF_IMAGE_SEQUENCE)
static bool isHEIFImageSequenceType(const String& type)
{
    return equalLettersIgnoringASCIICase(type, "image/heic-sequence"_s) || equalLettersIgnoringASCIICase(type, "image/heif-sequence"_s);
}
#else
static bool isHEIFImageSequenceType(const String&)
{
    return false;
}
#endif // MAVERICKS_BACKPORT: closes the HEIF image sequence helper above.

bool ImageDecoderGStreamer::supportsContainerType(const String& type)
{
    // Ideally this decoder should operate only from the WebProcess (or from the GPUProcess) which
    // should be the only process where GStreamer has been runtime initialized.
    // MAVERICKS_BACKPORT: widened the same way ensureGStreamerInitialized() is (GStreamerCommon.cpp),
    // because WebKitLegacy hosts render in-process: !processType() is a non-auxiliary application
    // process, where GStreamer is initialized and this decoder is the one that decodes a video loaded
    // as an image. The NetworkProcess and the GPU process are still refused.
    // if (!isInWebProcess())
    if (!isInWebProcess() && processType())
        return false;

    // MAVERICKS_BACKPORT: this decoder also carries the ISO/IEC 23008-12 image sequence types, whose
    // samples are HEVC in an ISO-BMFF file. See HAVE(HEIF_IMAGE_SEQUENCE).
    // if (!type.startsWith("video/"_s))
    if (!type.startsWith("video/"_s) && !isHEIFImageSequenceType(type))
        return false;

    return GStreamerRegistryScanner::singleton().isContainerTypeSupported(GStreamerRegistryScanner::Configuration::Decoding, type);
}

bool ImageDecoderGStreamer::canDecodeType(const String& mimeType)
{
    if (mimeType.isEmpty())
        return false;

    // MAVERICKS_BACKPORT: widened as supportsContainerType above.
    // if (!mimeType.startsWith("video/"_s))
    if (!mimeType.startsWith("video/"_s) && !isHEIFImageSequenceType(mimeType))
        return false;

    // Ideally this decoder should operate only from the WebProcess (or from the GPUProcess) which
    // should be the only process where GStreamer has been runtime initialized.
    // MAVERICKS_BACKPORT: widened to the in-process renderers too; see supportsContainerType above.
    // if (!isInWebProcess())
    if (!isInWebProcess() && processType())
        return false;

    return GStreamerRegistryScanner::singleton().isContainerTypeSupported(GStreamerRegistryScanner::Configuration::Decoding, mimeType);
}

EncodedDataStatus ImageDecoderGStreamer::encodedDataStatus() const
{
    if (m_error)
        return EncodedDataStatus::Error;

    // MAVERICKS_BACKPORT(upstreamable): webkit.org/b/211995. Complete is read as "frameCount() is final"
    // -- ImageFrameAnimator snapshots it at construction and BitmapImageSource holds that animator for
    // the image's life -- and m_eos does not say that. It carries the end-of-stream event the previous
    // pushEncodedData's decoder reset() queued, so it is true only on the call after frames were
    // decoded and false on every later one: the third setData CachedImage makes (one for
    // didReceiveData, one for didFinishLoading) leaves Complete unreachable, and the second reaches it
    // while more data may still arrive. ImageDecoderAVFObjC answers Complete from decoded samples and
    // fills its sample map only once allDataReceived, so this asks for both.
    // if (m_eos)
    if (m_isAllDataReceived && m_sampleData.size())
        return EncodedDataStatus::Complete;
    if (m_size)
        return EncodedDataStatus::SizeAvailable;
    return EncodedDataStatus::Unknown;
}

IntSize ImageDecoderGStreamer::size() const
{
    if (m_size)
        return m_size.value();
    return { };
}

RepetitionCount ImageDecoderGStreamer::repetitionCount() const
{
    // In the absence of instructions to the contrary, assume all media formats repeat infinitely.
    return frameCount() > 1 ? RepetitionCountInfinite : RepetitionCountNone;
}

Seconds ImageDecoderGStreamer::frameDurationAtIndex(size_t index) const
{
    auto* sampleData = sampleAtIndex(index);
    if (!sampleData)
        return { };

    return Seconds(sampleData->duration().toDouble());
}

bool ImageDecoderGStreamer::frameHasAlphaAtIndex(size_t index) const
{
    auto* sampleData = sampleAtIndex(index);
    return sampleData ? sampleData->hasAlpha() : false;
}

PlatformImagePtr ImageDecoderGStreamer::createFrameImageAtIndex(size_t index, SubsamplingLevel, const DecodingOptions&)
{
    Locker locker { m_sampleGeneratorLock };

    auto* sampleData = sampleAtIndex(index);
    if (!sampleData)
        return nullptr;

    if (auto image = sampleData->image())
        return image;

    return nullptr;
}

// MAVERICKS_BACKPORT(upstreamable): the flag is named and recorded, the way
// ImageDecoderAVFObjC::setData records it; see encodedDataStatus().
// void ImageDecoderGStreamer::setData(const FragmentedSharedBuffer& data, bool)
void ImageDecoderGStreamer::setData(const FragmentedSharedBuffer& data, bool allDataReceived)
{
    // MAVERICKS_BACKPORT(upstreamable): recorded here, read by encodedDataStatus().
    if (allDataReceived)
        m_isAllDataReceived = true;
    pushEncodedData(data);
}

void ImageDecoderGStreamer::clearFrameBufferCache(size_t index)
{
    size_t i = 0;
    for (auto& samplePair : m_sampleData.presentationOrder()) {
        toSample(samplePair)->dropImage();
        if (++i > index)
            break;
    }
}

const ImageDecoderGStreamerSample* ImageDecoderGStreamer::sampleAtIndex(size_t index) const
{
    if (index >= m_sampleData.presentationOrder().size())
        return nullptr;

    // FIXME: std::map is not random-accessible; this can get expensive if callers repeatedly call
    // with monotonically increasing indexes. Investigate adding an O(1) side structure to make this
    // style of access faster.
    auto iter = m_sampleData.presentationOrder().begin();
    for (size_t i = 0; i != index; ++i)
        ++iter;

    return toSample(iter);
}

void ImageDecoderGStreamer::storeDecodedSample(GRefPtr<GstSample>&& sample)
{
    auto presentationSize = getVideoResolutionFromCaps(gst_sample_get_caps(sample.get()));
    if (presentationSize && !presentationSize->isEmpty() && (!m_size || m_size != roundedIntSize(*presentationSize)))
        m_size = roundedIntSize(*presentationSize);
    m_sampleData.addSample(ImageDecoderGStreamerSample::create(WTF::move(sample), *m_size));
}

void ImageDecoderGStreamer::pushEncodedData(const FragmentedSharedBuffer& sharedBuffer)
{
    auto data = sharedBuffer.makeContiguous();
    auto bytes = data->createGBytes();
    auto buffer = adoptGRef(gst_buffer_new_wrapped_bytes(bytes.get()));
    m_eos = false;
    m_error = false;

    auto scopeExit = makeScopeExit([&] {
        callOnMainThreadAndWait([&] {
            if (m_encodedDataStatusChangedCallback)
                m_encodedDataStatusChangedCallback(encodedDataStatus());
        });
    });

    auto caps = adoptGRef(gst_type_find_helper_for_buffer(GST_OBJECT_CAST(m_parserHarness->element()), buffer.get(), nullptr));
    GST_DEBUG_OBJECT(m_parserHarness->element(), "Caps typefind result: %" GST_PTR_FORMAT, caps.get());
    if (!caps) {
        GST_WARNING_OBJECT(m_parserHarness->element(), "Typefinding failed");
        m_error = true;
        return;
    }

    if (!m_parserHarness->pushSample(adoptGRef(gst_sample_new(buffer.get(), caps.get(), nullptr, nullptr)))) {
        GST_WARNING_OBJECT(m_parserHarness->element(), "Parser or downstream decoder failed to process data");
        m_error = true;
        return;
    }

    if (!m_decoderHarness) {
        GST_WARNING_OBJECT(m_parserHarness->element(), "Parsing failed");
        m_error = true;
        return;
    }

    for (auto& stream : m_parserHarness->outputStreams()) {
        while (auto event = stream->pullEvent())
            m_decoderHarness->pushEvent(WTF::move(event));
    }

    for (auto& stream : m_decoderHarness->outputStreams()) {
        while (auto event = stream->pullEvent()) {
            if (GST_EVENT_TYPE(event.get()) == GST_EVENT_EOS)
                m_eos = true;
        }
    }

    m_decoderHarness->reset();
}

#undef GST_CAT_DEFAULT

} // namespace WebCore

#endif // USE(GSTREAMER) && ENABLE(VIDEO)
