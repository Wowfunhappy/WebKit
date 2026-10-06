#include "config.h"
#include "GStreamerHLSTrack.h"

#include "GStreamerCommon.h"
#include <gst/tag/tag.h>
#include <wtf/glib/GUniquePtr.h>
#include <wtf/text/StringView.h>

namespace WebCore {

static std::optional<String> tagString(GstTagList* tags, const char* name)
{
    GUniqueOutPtr<gchar> value;
    if (!gst_tag_list_get_string(tags, name, &value.outPtr()))
        return std::nullopt;
    return String::fromUTF8(value.get());
}

// Adaptive demuxers carry BCP 47 tags in LANGUAGE_NAME when they are not ISO 639 codes.
std::optional<String> hlsTrackLanguage(GstTagList* tags)
{
    auto language = tagString(tags, GST_TAG_LANGUAGE_CODE);
    if (!language)
        return tagString(tags, GST_TAG_LANGUAGE_NAME);
    const char* converted = gst_tag_get_language_code_iso_639_1(language->utf8().data());
    return converted ? String::fromUTF8(converted) : *language;
}

GRefPtr<GstStream> hlsDescribingStream(GRefPtr<GstStream> stream, const GRefPtr<GstPad>& pad)
{
    if (stream || !pad)
        return stream;
    auto event = adoptGRef(gst_pad_get_sticky_event(pad.get(), GST_EVENT_STREAM_START, 0));
    if (!event)
        return nullptr;
    GstStream* announcedStream = nullptr;
    gst_event_parse_stream(event.get(), &announcedStream);
    return adoptGRef(announcedStream);
}

GRefPtr<GstTagList> hlsTrackTags(const GRefPtr<GstPad>& pad)
{
    auto stream = hlsDescribingStream(nullptr, pad);
    return stream ? adoptGRef(gst_stream_get_tags(stream.get())) : nullptr;
}

static bool streamHasCharacteristic(GstStream* stream, ASCIILiteral characteristic)
{
    auto tags = adoptGRef(gst_stream_get_tags(stream));
    if (!tags)
        return false;
    GUniqueOutPtr<gchar> characteristics;
    if (!gst_tag_list_get_string(tags.get(), "hls-characteristics", &characteristics.outPtr()))
        return false;
    for (auto item : StringView::fromLatin1(characteristics.get()).split(',')) {
        if (item.trim(isASCIIWhitespace<char16_t>) == characteristic)
            return true;
    }
    return false;
}

// Characteristic precedence follows AVTrackPrivateAVFObjCImpl's audioKind/textKind.
AudioTrackPrivate::Kind hlsAudioTrackKind(GRefPtr<GstStream> stream, const GRefPtr<GstPad>& pad, AudioTrackPrivate::Kind fallback)
{
    using Kind = AudioTrackPrivate::Kind;
    stream = hlsDescribingStream(WTF::move(stream), pad);
    if (!stream)
        return fallback;
    if (streamHasCharacteristic(stream.get(), "public.auxiliary-content"_s))
        return Kind::Alternative;
    if (streamHasCharacteristic(stream.get(), "public.accessibility.describes-video"_s))
        return Kind::Description;
    if (streamHasCharacteristic(stream.get(), "public.main-program-content"_s) || gst_stream_get_stream_flags(stream.get()) & GST_STREAM_FLAG_SELECT)
        return Kind::Main;
    return fallback;
}

InbandTextTrackPrivate::Kind hlsTextTrackKind(GRefPtr<GstStream> stream, const GRefPtr<GstPad>& pad, InbandTextTrackPrivate::Kind fallback)
{
    using Kind = InbandTextTrackPrivate::Kind;
    if (fallback != Kind::Subtitles)
        return fallback;
    stream = hlsDescribingStream(WTF::move(stream), pad);
    if (!stream)
        return fallback;
    if (streamHasCharacteristic(stream.get(), "public.subtitles.forced-only"_s))
        return Kind::Forced;
    if (streamHasCharacteristic(stream.get(), "public.accessibility.transcribes-spoken-dialog"_s)
        || streamHasCharacteristic(stream.get(), "public.accessibility.describes-music-and-sound"_s))
        return Kind::Captions;
    return fallback;
}

bool hlsTextTrackIsDefault(const GRefPtr<GstPad>& pad)
{
    if (!pad)
        return false;
    auto event = adoptGRef(gst_pad_get_sticky_event(pad.get(), GST_EVENT_STREAM_START, 0));
    if (!event)
        return false;
    GstStreamFlags flags = GST_STREAM_FLAG_NONE;
    gst_event_parse_stream_flags(event.get(), &flags);
    return flags & GST_STREAM_FLAG_SELECT;
}

} // namespace WebCore
