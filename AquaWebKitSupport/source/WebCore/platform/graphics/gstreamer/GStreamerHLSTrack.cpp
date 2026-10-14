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
AudioTrackPrivate::Kind hlsAudioTrackKind(GstStream* stream, AudioTrackPrivate::Kind fallback)
{
    using Kind = AudioTrackPrivate::Kind;
    if (!stream)
        return fallback;
    if (streamHasCharacteristic(stream, "public.auxiliary-content"_s))
        return Kind::Alternative;
    if (streamHasCharacteristic(stream, "public.accessibility.describes-video"_s))
        return Kind::Description;
    if (streamHasCharacteristic(stream, "public.main-program-content"_s) || gst_stream_get_stream_flags(stream) & GST_STREAM_FLAG_SELECT)
        return Kind::Main;
    return fallback;
}

InbandTextTrackPrivate::Kind hlsTextTrackKind(GstStream* stream, InbandTextTrackPrivate::Kind fallback)
{
    using Kind = InbandTextTrackPrivate::Kind;
    if (fallback != Kind::Subtitles || !stream)
        return fallback;
    if (streamHasCharacteristic(stream, "public.subtitles.forced-only"_s))
        return Kind::Forced;
    if (streamHasCharacteristic(stream, "public.accessibility.transcribes-spoken-dialog"_s)
        || streamHasCharacteristic(stream, "public.accessibility.describes-music-and-sound"_s))
        return Kind::Captions;
    return fallback;
}

bool hlsTextTrackIsDefault(GstStream* stream)
{
    return stream && gst_stream_get_stream_flags(stream) & GST_STREAM_FLAG_SELECT;
}

} // namespace WebCore
