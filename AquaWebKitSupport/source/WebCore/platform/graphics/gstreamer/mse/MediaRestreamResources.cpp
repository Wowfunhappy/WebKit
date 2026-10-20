#include "config.h"
#include "MediaRestreamSource.h"
#include "MediaRestreamSubtitles.h"
#include <wtf/text/StringBuilder.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <cmath>

namespace WebCore {
static std::optional<uint64_t> resourceIndex(StringView text)
{
    auto value = parseInteger<uint64_t>(text);
    if (!value || text != String::number(*value))
        return std::nullopt;
    return value;
}
String MediaRestreamSource::playlist(std::optional<uint64_t> subtitle) const
{
    if (!valid() || m_ready || m_segments.empty())
        return { };
    StringBuilder result;
    result.append("#EXTM3U\n#EXT-X-VERSION:6\n"_s);
    if (m_ended)
        result.append("#EXT-X-PLAYLIST-TYPE:VOD\n"_s);
    else if (!m_maxHistoryDuration)
        result.append("#EXT-X-PLAYLIST-TYPE:EVENT\n"_s);
    result.append("#EXT-X-TARGETDURATION:"_s, hlsTargetDuration,
        "\n#EXT-X-MEDIA-SEQUENCE:"_s, m_firstSequence, "\n#EXT-X-DISCONTINUITY-SEQUENCE:"_s, m_discontinuitySequence,
        "\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n"_s);
    for (size_t i = 0; i < m_segments.size(); ++i) {
        auto& segment = m_segments[i];
        if (segment.discontinuity)
            result.append("#EXT-X-DISCONTINUITY\n"_s);
        result.append("#EXTINF:"_s, segment.duration, ",\n"_s);
        if (subtitle)
            result.append("sub-"_s, *subtitle, '-', m_firstSequence + i, ".vtt\n"_s);
        else
            result.append(m_firstSequence + i, ".ts\n"_s);
    }
    if (m_ended)
        result.append("#EXT-X-ENDLIST\n"_s);
    return result.toString();
}
String MediaRestreamSource::masterPlaylist() const
{
    return makeString("#EXTM3U\n"_s, m_subtitles->renditions(), "#EXT-X-STREAM-INF:BANDWIDTH="_s,
        static_cast<uint64_t>(std::ceil(m_peakBandwidth + m_peakSubtitleBandwidth)), ",SUBTITLES=\"text\"\nmedia.m3u8\n"_s);
}
void MediaRestreamSource::textResource(const String& resource, CompletionHandler<void(String&&)>&& completion)
{
    if (!valid() || m_ready)
        return completion({ });
    if (resource == "media.m3u8"_s)
        return completion(playlist());
    if (resource == "index.m3u8"_s)
        return completion(!m_subtitles || m_subtitles->empty() ? playlist() : masterPlaylist());
    if (!m_subtitles || !resource.startsWith("sub-"_s))
        return completion({ });
    if (resource.endsWith(".m3u8"_s)) {
        auto track = resourceIndex(StringView(resource).substring(4, resource.length() - 9));
        return completion(track && *track < m_subtitles->size() ? playlist(*track) : String { });
    }
    if (!resource.endsWith(".vtt"_s))
        return completion({ });
    auto components = StringView(resource).substring(4, resource.length() - 8).toString().splitAllowingEmptyEntries('-');
    if (components.size() != 2)
        return completion({ });
    auto track = resourceIndex(components[0]);
    auto sequence = resourceIndex(components[1]);
    auto* segment = sequence ? segmentForSequence(*sequence) : nullptr;
    if (!track || !segment || *track >= segment->subtitles.size())
        return completion({ });
    read(segment->subtitles[*track], [completion = WTF::move(completion)](RefPtr<SharedBuffer>&& data) mutable {
        completion(data ? String::fromUTF8(data->span()) : String { });
    });
}
}
