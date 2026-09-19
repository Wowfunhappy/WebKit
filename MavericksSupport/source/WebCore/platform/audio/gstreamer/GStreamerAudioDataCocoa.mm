/*
 * The CoreAudio -> GStreamer sample bridge GStreamerMediaStreamSource's audio path takes.
 *
 * RealtimeMediaSourceCenterMac selects the Cocoa capture factories, so a MediaStream audio track's
 * samples arrive as a WebAudioBufferList, while this port's media engine is GStreamer and its
 * MediaStream source element pushes GstSamples. This converts a capture unit's buffer list into a
 * GstSample carrying a copy of its frames: the list's memory belongs to the unit, which reuses it
 * for the next callback.
 *
 * This runs on the CoreAudio render thread, once per buffer, so the caps and the GstAudioInfo the
 * caller holds are rebuilt only when the capture format changes.
 *
 * This lives outside GStreamerAudioData.h because <CoreAudio/CoreAudioTypes.h> reaches
 * ApplicationServices -> QuickDraw, whose global `Style` is ambiguous against WebCore::Style in any
 * unified source that also has `using namespace WebCore`.
 */

#include "config.h"
#include "GStreamerAudioData.h"

#if USE(GSTREAMER) && PLATFORM(COCOA)

#include "AudioStreamDescription.h"
#include "GStreamerCommon.h"
#include "WebAudioBufferList.h"
#include <CoreAudio/CoreAudioTypes.h>

namespace WebCore {

static GstAudioFormat gstAudioFormat(const AudioStreamDescription& description)
{
    bool littleEndian = description.isNativeEndian() == (G_BYTE_ORDER == G_LITTLE_ENDIAN);
    switch (description.format()) {
    case AudioStreamDescription::Uint8:
        return GST_AUDIO_FORMAT_U8;
    case AudioStreamDescription::Int16:
        return littleEndian ? GST_AUDIO_FORMAT_S16LE : GST_AUDIO_FORMAT_S16BE;
    case AudioStreamDescription::Int24:
        return littleEndian ? GST_AUDIO_FORMAT_S24LE : GST_AUDIO_FORMAT_S24BE;
    case AudioStreamDescription::Int32:
        return littleEndian ? GST_AUDIO_FORMAT_S32LE : GST_AUDIO_FORMAT_S32BE;
    case AudioStreamDescription::Float32:
        return littleEndian ? GST_AUDIO_FORMAT_F32LE : GST_AUDIO_FORMAT_F32BE;
    case AudioStreamDescription::Float64:
        return littleEndian ? GST_AUDIO_FORMAT_F64LE : GST_AUDIO_FORMAT_F64BE;
    case AudioStreamDescription::None:
        break;
    }
    return GST_AUDIO_FORMAT_UNKNOWN;
}

GRefPtr<GstSample> gstSampleFromWebAudioBufferList(const PlatformAudioData& audioData, const AudioStreamDescription& description, size_t sampleCount, const MediaTime& presentationTime, WebAudioBufferListCaps& cached)
{
    auto format = gstAudioFormat(description);
    if (format == GST_AUDIO_FORMAT_UNKNOWN) {
        GST_WARNING("Unsupported audio sample format for a MediaStream source");
        return nullptr;
    }

    // The description and the buffer list both come from the capture unit and describe the same
    // frames, so a disagreement between them is a broken contract rather than an input to handle.
    auto channels = description.numberOfChannels();
    auto wordSize = description.sampleWordSize();
    auto sampleRate = description.sampleRate();
    RELEASE_ASSERT(channels && wordSize && sampleRate > 0 && sampleCount);

    auto& bufferList = downcast<WebAudioBufferList>(audioData);
    // A non-interleaved list carries one buffer per channel; an interleaved one carries a single
    // buffer holding every channel. The source element's caps are interleaved either way, so the
    // per-channel case is woven together here.
    bool interleaved = description.isInterleaved();
    unsigned sourceBuffers = interleaved ? 1 : channels;
    RELEASE_ASSERT(bufferList.bufferCount() >= sourceBuffers);

    if (cached.format != format || cached.rate != static_cast<int>(sampleRate) || cached.channels != static_cast<int>(channels)) {
        gst_audio_info_set_format(&cached.info, format, static_cast<gint>(sampleRate), channels, nullptr);
        cached.caps = adoptGRef(gst_audio_info_to_caps(&cached.info));
        cached.format = format;
        cached.rate = static_cast<int>(sampleRate);
        cached.channels = channels;
    }

    size_t frameSize = static_cast<size_t>(channels) * wordSize;
    auto buffer = adoptGRef(gst_buffer_new_allocate(nullptr, sampleCount * frameSize, nullptr));
    if (!buffer)
        return nullptr;

    GstMapInfo map;
    if (!gst_buffer_map(buffer.get(), &map, GST_MAP_WRITE))
        return nullptr;

    auto destination = unsafeMakeSpan(map.data, map.size);
    for (unsigned channel = 0; channel < sourceBuffers; ++channel) {
        auto source = bufferList.bufferAsSpan<const uint8_t>(channel);
        size_t stride = interleaved ? frameSize : wordSize;
        RELEASE_ASSERT(source.size() >= sampleCount * stride);
        if (interleaved) {
            memcpySpan(destination, source.first(sampleCount * frameSize));
            break;
        }
        for (size_t frame = 0; frame < sampleCount; ++frame)
            memcpySpan(destination.subspan(frame * frameSize + channel * wordSize, wordSize), source.subspan(frame * wordSize, wordSize));
    }
    gst_buffer_unmap(buffer.get(), &map);

    GST_BUFFER_PTS(buffer.get()) = toGstClockTime(presentationTime);
    GST_BUFFER_DURATION(buffer.get()) = gst_util_uint64_scale(sampleCount, GST_SECOND, static_cast<guint64>(sampleRate));
    gst_buffer_add_audio_meta(buffer.get(), &cached.info, sampleCount, nullptr);

    return adoptGRef(gst_sample_new(buffer.get(), cached.caps.get(), nullptr, nullptr));
}

} // namespace WebCore

#endif // USE(GSTREAMER) && PLATFORM(COCOA)
