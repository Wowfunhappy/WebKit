#import "config.h"
#import "HLSTimedMetadataGStreamer.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && ENABLE(DATACUE_VALUE) && PLATFORM(COCOA)

#import "GStreamerCommon.h"
#import "ID3v2FrameParser.h"
#import "HLSTimedMetadataTrackGStreamer.h"
#import "MediaPlayer.h"
#import "MediaPlayerPrivateGStreamer.h"
#import "SerializedPlatformDataCue.h"
#import "SerializedPlatformDataCueValue.h"
#import <Foundation/Foundation.h>
#import <gst/app/gstappsink.h>
#import <limits>
#import <wtf/MainThread.h>
#import <wtf/RetainPtr.h>
#import <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(HLSTimedMetadataGStreamer);

HLSTimedMetadataGStreamer::HLSTimedMetadataGStreamer() = default;
HLSTimedMetadataGStreamer::~HLSTimedMetadataGStreamer() = default;

void HLSTimedMetadataGStreamer::linkID3Pad(GstElement* pipeline, GstPad* pad, ThreadSafeWeakPtr<MediaPlayerPrivateGStreamer>&& player)
{
    auto caps = adoptGRef(gst_pad_get_current_caps(pad));
    if (!caps)
        caps = adoptGRef(gst_pad_query_caps(pad, nullptr));
    if (!caps || gst_caps_is_empty(caps.get()) || !gst_structure_has_name(gst_caps_get_structure(caps.get(), 0), "meta/x-id3"))
        return;

    auto* sink = makeGStreamerElement("appsink"_s);
    if (!sink)
        return;

    // A metadata stream is sparse: the sink hands over each tag at its time and does not hold up preroll.
    auto sinkCaps = adoptGRef(gst_caps_new_empty_simple("meta/x-id3"));
    g_object_set(sink, "emit-signals", TRUE, "sync", TRUE, "async", FALSE, "enable-last-sample", FALSE, "caps", sinkCaps.get(), nullptr);
    g_signal_connect_data(sink, "new-sample", G_CALLBACK(+[](GstElement* appSink, gpointer userData) -> GstFlowReturn {
        auto sample = adoptGRef(gst_app_sink_pull_sample(GST_APP_SINK(appSink)));
        if (!sample)
            return GST_FLOW_OK;
        callOnMainThread([weakPlayer = *static_cast<ThreadSafeWeakPtr<MediaPlayerPrivateGStreamer>*>(userData), sample = WTF::move(sample)]() mutable {
            if (RefPtr player = weakPlayer.get())
                player->handleHLSID3Sample(WTF::move(sample));
        });
        return GST_FLOW_OK;
    }), new ThreadSafeWeakPtr<MediaPlayerPrivateGStreamer>(WTF::move(player)), [](gpointer data, GClosure*) {
        delete static_cast<ThreadSafeWeakPtr<MediaPlayerPrivateGStreamer>*>(data);
    }, static_cast<GConnectFlags>(0));

    gst_bin_add(GST_BIN_CAST(pipeline), sink);
    gst_element_sync_state_with_parent(sink);
    auto sinkPad = adoptGRef(gst_element_get_static_pad(sink, "sink"));
    if (gst_pad_link(pad, sinkPad.get()) != GST_PAD_LINK_OK)
        GST_WARNING_OBJECT(pipeline, "Could not link the ID3 metadata pad %" GST_PTR_FORMAT, pad);
}

static RetainPtr<NSString> stringFromUTF8(const std::string& string)
{
    RetainPtr<NSString> result = adoptNS([[NSString alloc] initWithBytes:string.data() length:string.size() encoding:NSUTF8StringEncoding]);
    if (!result)
        result = adoptNS([[NSString alloc] initWithBytes:string.data() length:string.size() encoding:NSISOLatin1StringEncoding]);
    return result;
}

void HLSTimedMetadataGStreamer::handleID3Sample(GstSample* sample, MediaPlayer& player, unsigned inbandTextTrackCount, bool isSeeking)
{
    if (isSeeking)
        return;

    auto* buffer = gst_sample_get_buffer(sample);
    auto* segment = gst_sample_get_segment(sample);
    if (!buffer || !segment || !GST_BUFFER_PTS_IS_VALID(buffer))
        return;
    auto streamTime = gst_segment_to_stream_time(segment, GST_FORMAT_TIME, GST_BUFFER_PTS(buffer));
    if (!GST_CLOCK_TIME_IS_VALID(streamTime) || streamTime > static_cast<GstClockTime>(std::numeric_limits<int64_t>::max()))
        return;
    MediaTime start(static_cast<int64_t>(streamTime), GST_SECOND);

    GstMappedBuffer mappedBuffer(buffer, GST_MAP_READ);
    if (!mappedBuffer)
        return;
    auto frames = parseID3v2Frames(mappedBuffer.data(), mappedBuffer.size());
    if (frames.empty())
        return;

    auto& track = ensureTrack(player, inbandTextTrackCount);
    track.updatePendingCueEndTimes(start);
    for (auto& frame : frames) {
        SerializedPlatformDataCueValue::Data data;
        data.key = stringFromUTF8(frame.key).get();
        if (!frame.type.empty())
            data.type = stringFromUTF8(frame.type).get();
        for (auto& attribute : frame.otherAttributes)
            data.otherAttributes.set(String(stringFromUTF8(attribute.first).get()), String(stringFromUTF8(attribute.second).get()));
        switch (frame.valueKind) {
        case ID3v2Frame::ValueKind::Text:
            data.value = stringFromUTF8(frame.text);
            break;
        case ID3v2Frame::ValueKind::Bytes:
            data.value = adoptNS([[NSData alloc] initWithBytes:frame.bytes.data() length:frame.bytes.size()]);
            break;
        case ID3v2Frame::ValueKind::None:
            break;
        }
        track.addDataCue(start, MediaTime::positiveInfiniteTime(), SerializedPlatformDataCue::create(SerializedPlatformDataCueValue { std::optional { WTF::move(data) } }), "org.id3"_s);
    }
}

void HLSTimedMetadataGStreamer::handleDateRanges(const GstStructure* structure, MediaPlayer& player, unsigned inbandTextTrackCount, bool isSeeking)
{
    if (isSeeking)
        return;

    const GValue* ranges = gst_structure_get_value(structure, "ranges");
    if (!ranges || !GST_VALUE_HOLDS_ARRAY(ranges))
        return;

    for (guint i = 0; i < gst_value_array_get_size(ranges); ++i) {
        const GValue* rangeValue = gst_value_array_get_value(ranges, i);
        if (!GST_VALUE_HOLDS_STRUCTURE(rangeValue))
            continue;
        const GstStructure* range = gst_value_get_structure(rangeValue);
        const GValue* attributesValue = gst_structure_get_value(range, "attributes");
        if (!attributesValue || !GST_VALUE_HOLDS_STRUCTURE(attributesValue))
            continue;
        const GstStructure* attributes = gst_value_get_structure(attributesValue);
        if (!gst_structure_n_fields(attributes))
            continue;

        guint64 startTime = 0;
        guint64 duration = GST_CLOCK_TIME_NONE;
        gst_structure_get_uint64(range, "start", &startTime);
        gst_structure_get_uint64(range, "duration", &duration);
        if (startTime > static_cast<guint64>(std::numeric_limits<int64_t>::max()))
            continue;
        MediaTime start(static_cast<int64_t>(startTime), GST_SECOND);
        MediaTime end = MediaTime::positiveInfiniteTime();
        if (GST_CLOCK_TIME_IS_VALID(duration) && duration <= static_cast<guint64>(std::numeric_limits<int64_t>::max()))
            end = start + MediaTime(static_cast<int64_t>(duration), GST_SECOND);

        auto& track = ensureTrack(player, inbandTextTrackCount);
        track.updatePendingCueEndTimes(start);
        for (int field = 0; field < gst_structure_n_fields(attributes); ++field) {
            const gchar* name = gst_structure_nth_field_name(attributes, field);
            const gchar* value = gst_structure_get_string(attributes, name);
            if (!value)
                continue;
            SerializedPlatformDataCueValue::Data data;
            data.key = String::fromLatin1(name);
            data.value = adoptNS([[NSString alloc] initWithUTF8String:value]);
            track.addDataCue(start, end, SerializedPlatformDataCue::create(SerializedPlatformDataCueValue { std::optional { WTF::move(data) } }), "com.apple.quicktime.HLS"_s);
        }
    }
}

HLSTimedMetadataTrackGStreamer& HLSTimedMetadataGStreamer::ensureTrack(MediaPlayer& player, unsigned inbandTextTrackCount)
{
    if (!m_track) {
        m_track = HLSTimedMetadataTrackGStreamer::create(inbandTextTrackCount);
        player.addTextTrack(*m_track);
    }
    return *m_track;
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && ENABLE(DATACUE_VALUE) && PLATFORM(COCOA)
