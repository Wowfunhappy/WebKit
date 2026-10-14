/*
 * Copyright (C) 2013 Cable Television Laboratories, Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if ENABLE(VIDEO) && USE(GSTREAMER)

#include "InbandTextTrackPrivateGStreamer.h"
#include "GStreamerHLSTrack.h" // AQUAWEBKIT: HLS rendition metadata.

#include <wtf/Lock.h>
#include <wtf/text/StringBuilder.h> // AQUAWEBKIT: see mapWebVTTCueTimingsToStreamTime().
#include <wtf/text/StringToIntegerConversion.h>

namespace WebCore {

GST_DEBUG_CATEGORY(webkit_text_track_debug);
#define GST_CAT_DEFAULT webkit_text_track_debug

static void ensureTextTrackDebugCategoryInitialized()
{
    static std::once_flag debugRegisteredFlag;
    std::call_once(debugRegisteredFlag, [] {
        GST_DEBUG_CATEGORY_INIT(webkit_text_track_debug, "webkittexttrack", 0, "WebKit Text Track");
    });
}

InbandTextTrackPrivateGStreamer::InbandTextTrackPrivateGStreamer(unsigned index, GRefPtr<GstPad>&& pad, TrackID trackId)
    : InbandTextTrackPrivate(CueFormat::WebVTT)
    , TrackPrivateBaseGStreamer(nullptr, GStreamerTrackType::Text, this, index, WTF::move(pad), trackId)
    , m_kind(Kind::Subtitles)
{
    ensureTextTrackDebugCategoryInitialized();
}

InbandTextTrackPrivateGStreamer::InbandTextTrackPrivateGStreamer(unsigned index, GRefPtr<GstStream>&& stream)
    : InbandTextTrackPrivate(CueFormat::WebVTT)
    , TrackPrivateBaseGStreamer(nullptr, GStreamerTrackType::Text, this, index, WTF::move(stream))
{
    ensureTextTrackDebugCategoryInitialized();

    GST_INFO("Track %" PRIu64 " got stream start. GStreamer stream-id: %s", m_data->m_id, m_data->m_gstStreamId.utf8().data());

    GST_DEBUG("Stream %" GST_PTR_FORMAT, m_data->m_stream.get());
    GRefPtr caps = adoptGRef(gst_stream_get_caps(m_data->m_stream.get()));
    m_kind = doCapsHaveType(caps.get(), "closedcaption/"_s) ? Kind::Captions : Kind::Subtitles;
}

// AQUAWEBKIT: HLS characteristics and default-rendition flags use the port adapter.
InbandTextTrackPrivate::Kind InbandTextTrackPrivateGStreamer::kind() const
{
    return hlsTextTrackKind(m_data->m_stream.get(), m_kind);
}

bool InbandTextTrackPrivateGStreamer::isDefault() const
{
    return hlsTextTrackIsDefault(m_data->m_stream.get());
}

void InbandTextTrackPrivateGStreamer::tagsChanged(GRefPtr<GstTagList>&& tags)
{
    ASSERT(isMainThread());
    if (!tags)
        return;

    if (!m_data->updateTrackIDFromTags(tags))
        return;

    GST_DEBUG_OBJECT(m_data->objectForLogging(), "Text track ID set from container-specific-track-id tag %" G_GUINT64_FORMAT, *m_data->m_trackID);
    notifyClients([trackID = *m_data->m_trackID](auto& client) {
        client.idChanged(trackID);
    });
}

void InbandTextTrackPrivateGStreamer::handleSample(GRefPtr<GstSample>&& sample)
{
    {
        Locker locker { m_sampleMutex };
        m_pendingSamples.append(WTF::move(sample));
    }

    RefPtr<InbandTextTrackPrivateGStreamer> protectedThis(this);
    m_data->m_notifier->notify(TrackDataHolder::MainThreadNotification::NewSample, [protectedThis] {
        protectedThis->notifyTrackOfSample();
    });
}

// AQUAWEBKIT: a WebVTT timestamp, [hh:]mm:ss.ttt, in nanoseconds.
static std::optional<int64_t> parseWebVTTTimestamp(StringView timestamp)
{
    auto fields = timestamp.split(':');
    Vector<StringView, 3> parts;
    for (auto field : fields)
        parts.append(field);
    if (parts.size() < 2 || parts.size() > 3)
        return std::nullopt;
    auto secondsAndFraction = parts.last();
    size_t dot = secondsAndFraction.find('.');
    if (dot == notFound || secondsAndFraction.length() - dot - 1 != 3)
        return std::nullopt;
    auto hours = parts.size() == 3 ? parseInteger<int64_t>(parts[0]) : std::optional<int64_t> { 0 };
    auto minutes = parseInteger<int64_t>(parts[parts.size() - 2]);
    auto seconds = parseInteger<int64_t>(secondsAndFraction.left(dot));
    auto milliseconds = parseInteger<int64_t>(secondsAndFraction.substring(dot + 1));
    if (!hours || !minutes || !seconds || !milliseconds)
        return std::nullopt;
    return (((*hours * 60 + *minutes) * 60 + *seconds) * 1000 + *milliseconds) * GST_MSECOND;
}

static void appendWebVTTTimestamp(StringBuilder& builder, int64_t nanoseconds)
{
    int64_t milliseconds = std::max<int64_t>(nanoseconds, 0) / GST_MSECOND;
    auto twoDigits = [](int64_t value) { return value < 10 ? makeString('0', value) : String::number(value); };
    builder.append(twoDigits(milliseconds / 3600000), ':', twoDigits(milliseconds / 60000 % 60), ':', twoDigits(milliseconds / 1000 % 60), '.');
    int64_t fraction = milliseconds % 1000;
    builder.append(fraction < 100 ? "0"_s : ""_s, fraction < 10 ? "0"_s : ""_s, fraction);
}

// AQUAWEBKIT: the WebVTT a sample carries, from webvttenc or as the demuxer delivered it, is timed on the
// sample's buffer timeline, and a cue is timed in stream time; the two are the same unless the demuxer keeps its
// own timeline (hlsdemux2 places an HLS stream after a presentation offset). Each cue timing line is mapped through
// the sample's segment, and a cue that ends before the stream starts is dropped with its payload.
static bool segmentMapsToItself(const GstSegment& segment)
{
    return segment.format != GST_FORMAT_TIME || (segment.time == segment.start && segment.applied_rate == 1.0);
}

static std::optional<int64_t> segmentStreamTime(const GstSegment& segment, int64_t position)
{
    guint64 streamTime;
    int sign = gst_segment_to_stream_time_full(&segment, GST_FORMAT_TIME, position, &streamTime);
    if (!sign)
        return std::nullopt;
    return sign > 0 ? static_cast<int64_t>(streamTime) : -static_cast<int64_t>(streamTime);
}

static CString mapWebVTTCueTimingsToStreamTime(std::span<const uint8_t> data, const GstSegment& segment)
{
    auto text = String::fromUTF8(data);
    StringBuilder builder;
    bool isDroppingCue = false;
    for (auto line : StringView(text).splitAllowingEmptyEntries('\n')) {
        if (isDroppingCue) {
            if (!line.trim(isASCIIWhitespace<char16_t>).isEmpty())
                continue;
            isDroppingCue = false;
        }
        size_t arrow = line.find("-->"_s);
        std::optional<int64_t> start, end;
        size_t endLength = 0;
        if (arrow != notFound) {
            start = parseWebVTTTimestamp(line.left(arrow).trim(isASCIIWhitespace<char16_t>));
            auto rest = line.substring(arrow + 3);
            size_t endStart = 0;
            while (endStart < rest.length() && isASCIIWhitespace(rest[endStart]))
                endStart++;
            endLength = endStart;
            while (endLength < rest.length() && !isASCIIWhitespace(rest[endLength]))
                endLength++;
            end = parseWebVTTTimestamp(rest.substring(endStart, endLength - endStart));
        }
        auto streamStart = start ? segmentStreamTime(segment, *start) : std::nullopt;
        auto streamEnd = end ? segmentStreamTime(segment, *end) : std::nullopt;
        if (streamStart && streamEnd && *streamEnd < 0) {
            isDroppingCue = true;
            continue;
        }
        if (streamStart && streamEnd) {
            appendWebVTTTimestamp(builder, *streamStart);
            builder.append(" --> "_s);
            appendWebVTTTimestamp(builder, *streamEnd);
            builder.append(line.substring(arrow + 3 + endLength));
        } else
            builder.append(line);
        builder.append('\n');
    }
    return builder.toString().utf8();
}

void InbandTextTrackPrivateGStreamer::notifyTrackOfSample()
{
    Vector<GRefPtr<GstSample>> samples;
    {
        Locker locker { m_sampleMutex };
        m_pendingSamples.swap(samples);
    }

    for (auto& sample : samples) {
        GstBuffer* buffer = gst_sample_get_buffer(sample.get());
        if (!buffer) {
            GST_WARNING("Track %" PRIu64 " got sample with no buffer.", m_data->m_id);
            continue;
        }
        GstMappedBuffer mappedBuffer(buffer, GST_MAP_READ);
        ASSERT(mappedBuffer);
        if (!mappedBuffer) {
            GST_WARNING("Track %" PRIu64 " unable to map buffer.", m_data->m_id);
            continue;
        }

        GST_INFO("Track %" PRIu64 " parsing sample: %.*s", m_data->m_id, static_cast<int>(mappedBuffer.size()),
            reinterpret_cast<char*>(mappedBuffer.data()));
        ASSERT(isMainThread());
        ASSERT(!hasClients() || hasOneClient());
        // AQUAWEBKIT: see mapWebVTTCueTimingsToStreamTime().
        auto* segment = gst_sample_get_segment(sample.get());
        bool shouldMapCueTimings = segment && !segmentMapsToItself(*segment);
        CString mappedCueData = shouldMapCueTimings ? mapWebVTTCueTimingsToStreamTime(mappedBuffer.span<uint8_t>(), *segment) : CString();
        notifyMainThreadClient([&](auto& client) {
            // downcast<InbandTextTrackPrivateClient>(client).parseWebVTTCueData(mappedBuffer.span<uint8_t>());
            downcast<InbandTextTrackPrivateClient>(client).parseWebVTTCueData(shouldMapCueTimings ? byteCast<uint8_t>(mappedCueData.span()) : mappedBuffer.span<uint8_t>()); // AQUAWEBKIT: as above.
        });
    }
}

TrackID InbandTextTrackPrivateGStreamer::id() const
{
    return m_data->m_trackID.value_or(m_data->m_id);
}

String InbandTextTrackPrivateGStreamer::label() const
{
    return m_data->m_label;
}

String InbandTextTrackPrivateGStreamer::language() const
{
    return m_data->m_language;
}

int InbandTextTrackPrivateGStreamer::trackIndex() const
{
    return m_data->m_index;
}

#undef GST_CAT_DEFAULT

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER)
