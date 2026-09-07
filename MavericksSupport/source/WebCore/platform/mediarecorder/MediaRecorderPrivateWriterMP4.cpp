/*
 * Copyright (C) 2026 Jonathan. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "MediaRecorderPrivateWriterMP4.h"

#if ENABLE(MEDIA_RECORDER)

#include "CAAudioStreamDescription.h"
#include "Logging.h"
#include "MediaSamplesBlock.h"
#include "TrackInfo.h"
#include "WebMAudioUtilitiesCocoa.h"
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreMedia/CMFormatDescription.h>
#include <wtf/NativePromise.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UniqueRef.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
}

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(MediaRecorderPrivateWriterMP4);

// The time base the encoder's frames arrive in; each packet is rescaled into its own track's
// before it is muxed.
static constexpr AVRational timeBase { 1, 1000000 };
static constexpr int ioBufferSize = 65536;

static enum AVCodecID codecIDForVideoCodecName(FourCC codec)
{
    switch (codec.value) {
    case kCMVideoCodecType_H264: return AV_CODEC_ID_H264;
    case kCMVideoCodecType_HEVC: return AV_CODEC_ID_HEVC;
    case kCMVideoCodecType_AV1: return AV_CODEC_ID_AV1;
    default: return AV_CODEC_ID_NONE;
    }
}

static enum AVCodecID codecIDForAudioCodecName(FourCC codec)
{
    switch (codec.value) {
    case kAudioFormatMPEG4AAC:
    case kAudioFormatMPEG4AAC_HE:
    case kAudioFormatMPEG4AAC_HE_V2:
    case kAudioFormatMPEG4AAC_LD:
    case kAudioFormatMPEG4AAC_ELD: return AV_CODEC_ID_AAC;
    case kAudioFormatOpus: return AV_CODEC_ID_OPUS;
    case kAudioFormatAppleLossless: return AV_CODEC_ID_ALAC;
    case kAudioFormatLinearPCM: return AV_CODEC_ID_PCM_F32LE;
    default: return AV_CODEC_ID_NONE;
    }
}

// The MPEG-4 DecoderSpecificInfo (an AudioSpecificConfig for AAC) inside a CoreAudio magic cookie,
// which holds an ES_Descriptor (tag 3) wrapping a DecoderConfigDescriptor (tag 4) wrapping it.
// The container tags carry fixed-size fields ahead of their children.
static std::span<const uint8_t> decoderSpecificInfo(std::span<const uint8_t> cookie)
{
    size_t position = 0;
    while (position < cookie.size()) {
        uint8_t tag = cookie[position++];
        size_t length = 0;
        for (unsigned byteCount = 0; position < cookie.size() && byteCount < 4; byteCount++) {
            uint8_t byte = cookie[position++];
            length = (length << 7) | (byte & 0x7f);
            if (!(byte & 0x80))
                break;
        }
        if (position + length > cookie.size())
            return { };
        if (tag == 0x05)
            return cookie.subspan(position, length);
        if (tag == 0x03)
            position += 3; // ES_ID and the stream-dependency/URL/OCR flags.
        else if (tag == 0x04)
            position += 13; // Object type, stream type with the buffer size, and both bitrates.
        else
            position += length;
    }
    return { };
}

// libavcodec spells ALAC's configuration as the whole 'alac' box; CoreAudio's magic cookie is that
// box's 24-byte payload, optionally preceded by the channel-layout boxes.
static Vector<uint8_t> alacExtradata(std::span<const uint8_t> cookie)
{
    static constexpr size_t configSize = 24;
    if (cookie.size() < configSize)
        return { };
    auto config = cookie.last(configSize);
    for (size_t position = 4; position + 4 <= cookie.size(); position++) {
        if (!memcmp(cookie.subspan(position, 4).data(), "alac", 4) && position + 8 + configSize <= cookie.size()) {
            config = cookie.subspan(position + 8, configSize);
            break;
        }
    }
    uint32_t boxSize = 12 + configSize;
    Vector<uint8_t> extradata;
    extradata.reserveInitialCapacity(boxSize);
    extradata.append(static_cast<uint8_t>(boxSize >> 24));
    extradata.append(static_cast<uint8_t>(boxSize >> 16));
    extradata.append(static_cast<uint8_t>(boxSize >> 8));
    extradata.append(static_cast<uint8_t>(boxSize));
    extradata.append("alac"_span8);
    for (unsigned byteCount = 0; byteCount < 4; byteCount++)
        extradata.append(static_cast<uint8_t>(0));
    extradata.append(config);
    return extradata;
}

class MediaRecorderPrivateWriterMP4Delegate {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(MediaRecorderPrivateWriterMP4Delegate);

public:
    explicit MediaRecorderPrivateWriterMP4Delegate(MediaRecorderPrivateWriterListener& listener)
        : m_listener(listener)
    {
        if (avformat_alloc_output_context2(&m_context, nullptr, "mp4", nullptr) < 0 || !m_context)
            return;
        if (auto* buffer = static_cast<unsigned char*>(av_malloc(ioBufferSize)))
            m_context->pb = avio_alloc_context(buffer, ioBufferSize, 1, this, nullptr, writeData, nullptr);
        m_packet = av_packet_alloc();
    }

    ~MediaRecorderPrivateWriterMP4Delegate()
    {
        av_packet_free(&m_packet);
        if (m_context && m_context->pb) {
            av_freep(&m_context->pb->buffer);
            avio_context_free(&m_context->pb);
        }
        avformat_free_context(m_context);
    }

    std::optional<uint8_t> addAudioTrack(const AudioInfo& info)
    {
        auto codecID = codecIDForAudioCodecName(info.codecName());
        AVStream* stream = codecID != AV_CODEC_ID_NONE ? addStream(codecID) : nullptr;
        if (!stream)
            return { };

        auto* parameters = stream->codecpar;
        parameters->codec_type = AVMEDIA_TYPE_AUDIO;
        parameters->sample_rate = static_cast<int>(info.rate());
        parameters->frame_size = static_cast<int>(info.framesPerPacket());
        av_channel_layout_default(&parameters->ch_layout, static_cast<int>(info.channels()));

        RefPtr cookie = info.cookieData();
        auto cookieSpan = cookie ? cookie->span() : std::span<const uint8_t> { };
        switch (codecID) {
        case AV_CODEC_ID_AAC:
            if (!setExtradata(*parameters, decoderSpecificInfo(cookieSpan)))
                return { };
            break;
        case AV_CODEC_ID_ALAC:
            if (!setExtradata(*parameters, alacExtradata(cookieSpan).span()))
                return { };
            break;
        case AV_CODEC_ID_OPUS: {
            // The Opus encoder answers no magic cookie, so the identification header is built from
            // the stream description, as the WebM container writer builds it.
            auto description = CAAudioStreamDescription { static_cast<double>(info.rate()), info.channels(), AudioStreamDescription::Float32, CAAudioStreamDescription::IsInterleaved::Yes };
            auto header = cookieSpan.size() ? Vector<uint8_t>(cookieSpan) : createOpusPrivateData(description.streamDescription());
            if (!setExtradata(*parameters, header.span()))
                return { };
            break;
        }
        case AV_CODEC_ID_PCM_F32LE:
            parameters->bits_per_coded_sample = 32;
            parameters->block_align = 4 * parameters->ch_layout.nb_channels;
            break;
        default:
            break;
        }
        return trackIndexFor(*stream);
    }

    std::optional<uint8_t> addVideoTrack(const VideoInfo& info)
    {
        auto codecID = codecIDForVideoCodecName(info.codecName());
        AVStream* stream = codecID != AV_CODEC_ID_NONE ? addStream(codecID) : nullptr;
        if (!stream)
            return { };

        auto* parameters = stream->codecpar;
        parameters->codec_type = AVMEDIA_TYPE_VIDEO;
        parameters->width = static_cast<int>(info.size().width());
        parameters->height = static_cast<int>(info.size().height());
        if (info.extensionAtoms().size()) {
            Ref configuration = info.extensionAtoms()[0].second;
            if (!setExtradata(*parameters, configuration->span()))
                return { };
        }
        return trackIndexFor(*stream);
    }

    bool writeHeader()
    {
        if (!m_context || !m_context->pb || !m_packet)
            return false;
        AVDictionary* options = nullptr;
        // A movie header with no sample tables followed by self-contained fragments, each one cut
        // where flushFragment() asks for it rather than on a duration the muxer picks.
        av_dict_set(&options, "movflags", "frag_custom+empty_moov+default_base_moof", 0);
        int result = avformat_write_header(m_context, &options);
        av_dict_free(&options);
        if (result < 0) {
            RELEASE_LOG_ERROR(MediaStream, "MediaRecorderPrivateWriterMP4: avformat_write_header failed with %d", result);
            m_failed = true;
            return false;
        }
        avio_flush(m_context->pb);
        m_headerWritten = true;
        return true;
    }

    bool writeSample(uint8_t trackIndex, std::span<const uint8_t> data, const MediaTime& presentationTime, const MediaTime& decodeTime, const MediaTime& duration, bool isSync)
    {
        if (m_failed || !m_headerWritten || trackIndex > m_streams.size() || !trackIndex)
            return false;

        if (av_new_packet(m_packet, static_cast<int>(data.size())) < 0)
            return false;
        memcpySpan(unsafeMakeSpan(m_packet->data, data.size()), data);
        // The muxer settles each track's timescale while writing the header, so timestamps go out
        // in the time base the stream carries afterwards.
        AVStream& stream = *m_streams[trackIndex - 1];
        m_packet->stream_index = stream.index;
        m_packet->pts = av_rescale_q(presentationTime.toMicroseconds(), timeBase, stream.time_base);
        m_packet->dts = decodeTime.isValid() ? av_rescale_q(decodeTime.toMicroseconds(), timeBase, stream.time_base) : m_packet->pts;
        m_packet->duration = av_rescale_q(duration.toMicroseconds(), timeBase, stream.time_base);
        if (isSync)
            m_packet->flags |= AV_PKT_FLAG_KEY;
        int result = av_write_frame(m_context, m_packet);
        av_packet_unref(m_packet);
        if (result < 0) {
            RELEASE_LOG_ERROR(MediaStream, "MediaRecorderPrivateWriterMP4: av_write_frame failed with %d", result);
            m_failed = true;
            return false;
        }
        return true;
    }

    void flushFragment()
    {
        if (m_failed || !m_headerWritten)
            return;
        av_write_frame(m_context, nullptr);
        avio_flush(m_context->pb);
    }

    void finalize()
    {
        if (m_failed || !m_headerWritten)
            return;
        av_write_trailer(m_context);
        avio_flush(m_context->pb);
        m_headerWritten = false;
    }

private:
    static int writeData(void* opaque, const uint8_t* data, int size)
    {
        auto& delegate = *static_cast<MediaRecorderPrivateWriterMP4Delegate*>(opaque);
        if (RefPtr listener = delegate.m_listener.get())
            listener->appendData(unsafeMakeSpan(data, static_cast<size_t>(size)));
        return size;
    }

    AVStream* addStream(enum AVCodecID codecID)
    {
        if (!m_context || !m_context->pb || m_headerWritten || m_streams.size() >= std::numeric_limits<uint8_t>::max())
            return nullptr;
        AVStream* stream = avformat_new_stream(m_context, nullptr);
        if (!stream)
            return nullptr;
        stream->codecpar->codec_id = codecID;
        stream->time_base = timeBase;
        return stream;
    }

    uint8_t trackIndexFor(AVStream& stream)
    {
        m_streams.append(&stream);
        return static_cast<uint8_t>(m_streams.size());
    }

    static bool setExtradata(AVCodecParameters& parameters, std::span<const uint8_t> data)
    {
        if (data.empty())
            return false;
        parameters.extradata = static_cast<uint8_t*>(av_mallocz(data.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!parameters.extradata)
            return false;
        memcpySpan(unsafeMakeSpan(parameters.extradata, data.size()), data);
        parameters.extradata_size = static_cast<int>(data.size());
        return true;
    }

    ThreadSafeWeakPtr<MediaRecorderPrivateWriterListener> m_listener;
    AVFormatContext* m_context { nullptr };
    AVPacket* m_packet { nullptr };
    Vector<AVStream*> m_streams;
    bool m_headerWritten { false };
    bool m_failed { false };
};

std::unique_ptr<MediaRecorderPrivateWriter> MediaRecorderPrivateWriterMP4::create(MediaRecorderPrivateWriterListener& listener)
{
    return std::unique_ptr<MediaRecorderPrivateWriter> { new MediaRecorderPrivateWriterMP4(listener) };
}

MediaRecorderPrivateWriterMP4::MediaRecorderPrivateWriterMP4(MediaRecorderPrivateWriterListener& listener)
    : m_delegate(makeUniqueRef<MediaRecorderPrivateWriterMP4Delegate>(listener))
{
}

MediaRecorderPrivateWriterMP4::~MediaRecorderPrivateWriterMP4() = default;

std::optional<uint8_t> MediaRecorderPrivateWriterMP4::addAudioTrack(const AudioInfo& info)
{
    return m_delegate->addAudioTrack(info);
}

std::optional<uint8_t> MediaRecorderPrivateWriterMP4::addVideoTrack(const VideoInfo& info, const std::optional<CGAffineTransform>&)
{
    return m_delegate->addVideoTrack(info);
}

bool MediaRecorderPrivateWriterMP4::allTracksAdded()
{
    return m_delegate->writeHeader();
}

MediaRecorderPrivateWriterMP4::Result MediaRecorderPrivateWriterMP4::writeFrame(const MediaSamplesBlock& block)
{
    for (auto& sample : block) {
        ASSERT(sample.data);
        Ref buffer = Ref { *sample.data }->makeContiguous();
        if (!m_delegate->writeSample(static_cast<uint8_t>(block.trackID()), buffer->span(), sample.presentationTime, sample.decodeTime, sample.duration, sample.isSync()))
            return Result::Failure;
    }
    return Result::Success;
}

void MediaRecorderPrivateWriterMP4::forceNewSegment(const MediaTime&)
{
    m_delegate->flushFragment();
}

Ref<GenericPromise> MediaRecorderPrivateWriterMP4::close(Deque<UniqueRef<MediaSamplesBlock>>&& samples, const MediaTime&)
{
    auto result = Result::Success;
    while (!samples.isEmpty() && result == Result::Success)
        result = writeFrame(samples.takeFirst().get());

    m_delegate->finalize();
    return result == Result::Success ? GenericPromise::createAndResolve() : GenericPromise::createAndReject();
}

} // namespace WebCore

#endif // ENABLE(MEDIA_RECORDER)
