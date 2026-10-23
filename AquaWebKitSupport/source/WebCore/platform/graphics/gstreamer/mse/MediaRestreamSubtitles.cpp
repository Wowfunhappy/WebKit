#include "config.h"
#include "MediaRestreamSubtitles.h"
#include "HTMLMediaElement.h"
#include "TextTrackList.h"
#include "TextTrackCueList.h"
#include "VTTCue.h"
#include "WebVTTParser.h"
#include "VTTRegion.h"
#include "LoadableTextTrack.h"
#include "EventListener.h"
#include "EventNames.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizer.h"
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <cmath>
#include <wtf/ASCIICType.h>
#include <glib.h>
#include <unicode/uloc.h>
#include <wtf/glib/GUniquePtr.h>

namespace WebCore {
class RestreamSubtitleListener final : public EventListener {
public:
    static Ref<RestreamSubtitleListener> create(MediaRestreamSubtitles& owner) { return adoptRef(*new RestreamSubtitleListener(owner)); }
    void handleEvent(ScriptExecutionContext&, Event&) final
    {
        if (RefPtr owner = m_owner.get())
            static_cast<MediaRestreamSubtitles&>(*owner).loaded();
    }
private:
    explicit RestreamSubtitleListener(MediaRestreamSubtitles& owner) : EventListener(NativeEventListenerType), m_owner(owner) { }
    WeakPtr<TextTrackClient> m_owner;
};

static String timestamp(uint64_t ms)
{
    auto padded = [](uint64_t number, unsigned width) {
        auto text = String::number(number);
        StringBuilder result;
        for (unsigned i = text.length(); i < width; ++i)
            result.append('0');
        result.append(text);
        return result.toString();
    };
    return makeString(padded(ms / 3600000, 2), ':', padded(ms / 60000 % 60, 2), ':', padded(ms / 1000 % 60, 2), '.', padded(ms % 1000, 3));
}

static String attribute(const String& value)
{
    StringBuilder result;
    for (auto character : StringView(value).codeUnits()) {
        if (character >= 0x20 && character != '"' && character != 0x7f)
            result.append(character);
    }
    return result.toString();
}

static String languageTag(const String& value)
{
    auto text = value.utf8();
    if (text.isEmpty() || text.length() > INT32_MAX)
        return { };
    UErrorCode status = U_ZERO_ERROR;
    int32_t parsed = 0;
    uloc_forLanguageTag(text.data(), nullptr, 0, &parsed, &status);
    return (U_SUCCESS(status) || status == U_BUFFER_OVERFLOW_ERROR) && parsed == static_cast<int32_t>(text.length()) ? value : String { };
}

MediaRestreamSubtitles::MediaRestreamSubtitles(Function<void()>&& changed) : m_changed(WTF::move(changed)) { }
Ref<MediaRestreamSubtitles> MediaRestreamSubtitles::create(HTMLMediaElement& element, const std::optional<Vector<Ref<TextTrack>>>& selectedTracks, bool includeClosedCaptions, uint64_t budget, Function<void()>&& changed)
{
    Ref result = adoptRef(*new MediaRestreamSubtitles(WTF::move(changed)));
    result->m_budget = budget;
    result->m_listener = RestreamSubtitleListener::create(result);
    if (auto* tracks = element.textTracks()) {
        for (unsigned i = 0; i < tracks->length(); ++i) {
            auto* track = tracks->item(i);
            if (selectedTracks && !std::any_of(selectedTracks->begin(), selectedTracks->end(), [&](auto& selected) { return selected.ptr() == track; }))
                continue;
            if (track->mode() == TextTrack::Mode::Disabled || (track->isClosedCaptions() && !includeClosedCaptions)
                || (track->kind() != TextTrack::Kind::Subtitles && track->kind() != TextTrack::Kind::Captions && track->kind() != TextTrack::Kind::Forced))
                continue;
            auto styles = track->styleSheets().value_or(Vector<String> { });
            auto* loadable = dynamicDowncast<LoadableTextTrack>(track);
            RefPtr observedElement = loadable ? loadable->trackElement() : nullptr;
            result->m_tracks.append({ Ref { *track }, { }, WTF::move(styles), track->label(), languageTag(track->language()), track->mode() == TextTrack::Mode::Showing, track->containsOnlyForcedSubtitles(), WTF::move(observedElement) });
            track->addClient(result);
            if (auto* cues = track->cuesInternal())
                result->textTrackAddCues(*track, *cues);
            if (auto* loadable = dynamicDowncast<LoadableTextTrack>(track)) {
                if (auto* element = loadable->trackElement()) {
                    element->addEventListener(eventNames().loadEvent, Ref { *result->m_listener });
                    element->addEventListener(eventNames().errorEvent, Ref { *result->m_listener });
                }
            }
        }
    }
    return result;
}
MediaRestreamSubtitles::~MediaRestreamSubtitles() { detach(); }
void MediaRestreamSubtitles::freeze()
{
    if (m_frozen)
        return;
    refresh();
    detach();
}
void MediaRestreamSubtitles::detach()
{
    if (std::exchange(m_frozen, true))
        return;
    for (auto& track : m_tracks) {
        track.source->clearClient(*this);
        if (track.element) {
            track.element->removeEventListener(eventNames().loadEvent, *m_listener, { });
            track.element->removeEventListener(eventNames().errorEvent, *m_listener, { });
            track.element = nullptr;
        }
    }
    m_listener = nullptr;
}
void MediaRestreamSubtitles::loaded() { refresh(); m_changed(); }
void MediaRestreamSubtitles::refresh()
{
    Ref protect { *this };
    if (m_frozen || m_refreshing)
        return;
    m_refreshing = true;
    for (auto& track : m_tracks) {
        track.styles = track.source->styleSheets().value_or(Vector<String> { });
        track.available = track.source->readinessState() != TextTrack::FailedToLoad;
        Vector<Ref<TextTrackCue>> current;
        for (auto& cue : track.cues) {
            if (RefPtr original = cue.original.get(); original && original->track() == track.source.ptr())
                current.append(*original);
        }
        for (auto& cue : current)
            textTrackAddCue(track.source, cue);
    }
    m_refreshing = false;
    if (bytes() > m_budget)
        m_failed = true;
}
void MediaRestreamSubtitles::textTrackRemoveCue(TextTrack& track, TextTrackCue& original)
{
    for (auto& stored : m_tracks) {
        if (stored.source.ptr() != &track)
            continue;
        for (auto& cue : stored.cues) {
            if (cue.original.get() == &original)
                cue.archived = original.track() != &track;
        }
    }
}
void MediaRestreamSubtitles::textTrackRemoveCues(TextTrack& track, const TextTrackCueList& cues)
{
    for (unsigned i = 0; i < cues.length(); ++i)
        textTrackRemoveCue(track, *cues.item(i));
}
bool MediaRestreamSubtitles::ready() const
{
    return std::all_of(m_tracks.begin(), m_tracks.end(), [](auto& track) {
        return track.source->trackType() != TextTrack::TrackElement || track.source->readinessState() >= TextTrack::Loaded;
    });
}
bool MediaRestreamSubtitles::empty() const
{
    return std::none_of(m_tracks.begin(), m_tracks.end(), [&](auto& track) { return m_frozen ? track.available : track.source->readinessState() != TextTrack::FailedToLoad; });
}
void MediaRestreamSubtitles::textTrackAddCues(TextTrack& track, const TextTrackCueList& cues)
{
    Ref protect { *this };
    for (unsigned i = 0; i < cues.length(); ++i)
        textTrackAddCue(track, *cues.item(i));
}
void MediaRestreamSubtitles::textTrackAddCue(TextTrack& track, TextTrackCue& incoming)
{
    Ref protect { *this };
    if (m_failed || m_frozen)
        return;
    auto target = std::find_if(m_tracks.begin(), m_tracks.end(), [&](auto& entry) { return entry.source.ptr() == &track; });
    if (target == m_tracks.end())
        return;
    auto* cue = dynamicDowncast<VTTCue>(incoming);
    if (!cue || !std::isfinite(cue->startTime()) || !std::isfinite(cue->endTime()) || cue->endTime() <= 0 || cue->endTime() <= cue->startTime()
        || cue->endTime() >= static_cast<double>(std::numeric_limits<int64_t>::max() / 1000)) {
        target->cues.removeAllMatching([&](auto& stored) { return stored.original.get() == &incoming; });
        if (!m_refreshing)
            m_changed();
        return;
    }
    StringBuilder identity;
    auto field = [&](const String& value) { identity.append(value.length(), ':', value); };
    field(cue->id());
    field(cue->text());
    auto lineValue = cue->line();
    auto positionValue = cue->position();
    identity.append(cue->startTime(), ',', cue->endTime(), ',', static_cast<unsigned>(cue->vertical()), ',',
        std::holds_alternative<double>(lineValue), ',', std::get_if<double>(&lineValue) ? *std::get_if<double>(&lineValue) : 0, ',',
        cue->snapToLines(), ',', static_cast<unsigned>(cue->lineAlign()), ',',
        std::holds_alternative<double>(positionValue), ',', std::get_if<double>(&positionValue) ? *std::get_if<double>(&positionValue) : 0, ',',
        static_cast<unsigned>(cue->positionAlign()), ',', cue->size(), ',', static_cast<unsigned>(cue->align()), ';');
    if (auto* region = cue->region()) {
        field(region->id());
        identity.append(region->width(), ',', region->lines(), ',', region->regionAnchorX(), ',', region->regionAnchorY(), ',',
            region->viewportAnchorX(), ',', region->viewportAnchorY(), ',', static_cast<unsigned>(region->scroll()));
    }
    String key = identity.toString();
    auto previous = std::find_if(target->cues.begin(), target->cues.end(), [&](auto& stored) { return stored.original.get() == cue; });
    if (previous == target->cues.end())
        previous = std::find_if(target->cues.begin(), target->cues.end(), [&](auto& stored) { return (stored.archived || !stored.original) && stored.key == key; });
    StringBuilder body;
    auto invalidName = [](const String& name) {
        return name == "NOTE"_s || name.startsWith("NOTE "_s) || name.startsWith("NOTE\t"_s) || name.contains(static_cast<char16_t>(0)) || name.contains('\n') || name.contains('\r') || name.contains("-->"_s)
            || (name.startsWith("STYLE"_s) && StringView(name).substring(5).containsOnly<isASCIIWhitespace>())
            || (name.startsWith("REGION"_s) && StringView(name).substring(6).containsOnly<isASCIIWhitespace>());
    };
    auto collision = [&](const String& name) {
        return std::any_of(target->cues.begin(), target->cues.end(), [&](auto& stored) { return stored.cueName == name && stored.cueStyleID != cue->id(); });
    };
    String cueName = cue->id();
    if (invalidName(cueName) || (!cueName.isEmpty() && collision(cueName))) {
        cueName = previous != target->cues.end() ? previous->cueName : String { };
        while (cueName.isEmpty() || invalidName(cueName) || collision(cueName))
            cueName = makeString("anonymous-cue-"_s, m_nextCue++);
    }
    if (cue->vertical() != VTTCue::DirectionSetting::Horizontal)
        body.append(" vertical:"_s, cue->vertical() == VTTCue::DirectionSetting::VerticalGrowingLeft ? "rl"_s : "lr"_s);
    constexpr ASCIILiteral lineAlign[] { "start"_s, "center"_s, "end"_s };
    constexpr ASCIILiteral positionAlign[] { "line-left"_s, "center"_s, "line-right"_s, "auto"_s };
    constexpr ASCIILiteral align[] { "start"_s, "center"_s, "end"_s, "left"_s, "right"_s };
    auto line = cue->line();
    if (auto* number = std::get_if<double>(&line))
        body.append(" line:"_s, *number, cue->snapToLines() ? ""_s : "%"_s, ',', lineAlign[static_cast<size_t>(cue->lineAlign())]);
    auto position = cue->position();
    if (auto* number = std::get_if<double>(&position))
        body.append(" position:"_s, *number, "%,"_s, positionAlign[static_cast<size_t>(cue->positionAlign())]);
    body.append(" size:"_s, cue->size(), "% align:"_s, align[static_cast<size_t>(cue->align())]);
    String region;
    String regionName;
    if (auto* value = cue->region()) {
        auto sameRegion = std::find_if(target->cues.begin(), target->cues.end(), [&](auto& stored) { return stored.originalRegion.get() == value; });
        if (sameRegion != target->cues.end())
            regionName = sameRegion->regionName;
        else if (previous != target->cues.end() && previous->key == key)
            regionName = previous->regionName;
        else if (!value->id().isEmpty() && !value->id().contains(static_cast<char16_t>(0)) && !StringView(value->id()).contains([](char16_t character) { return isASCIIWhitespace(character); }) && !value->id().contains("-->"_s))
            regionName = value->id();
        else
            regionName = makeString("anonymous-region-"_s, m_nextRegion++);
        while (std::any_of(target->cues.begin(), target->cues.end(), [&](auto& stored) { return stored.originalRegion.get() != value && &stored != (previous == target->cues.end() ? nullptr : &*previous) && stored.regionName == regionName; }))
            regionName = makeString("anonymous-region-"_s, m_nextRegion++);
        auto& name = regionName;
        body.append(" region:"_s, name);
        StringBuilder definition;
        definition.append("REGION\nid:"_s, name, "\nwidth:"_s, value->width(), "%\nlines:"_s, value->lines(),
            "\nregionanchor:"_s, value->regionAnchorX(), "%,"_s, value->regionAnchorY(), "%\nviewportanchor:"_s,
            value->viewportAnchorX(), "%,"_s, value->viewportAnchorY(), "%\n"_s);
        if (value->scroll() == VTTRegion::ScrollSetting::Up)
            definition.append("scroll:up\n"_s);
        definition.append('\n');
        region = definition.toString();
    }
    auto content = makeStringByReplacingAll(cue->text(), "\r\n"_s, "\n"_s);
    content = makeStringByReplacingAll(content, '\r', '\n');
    content = makeStringByReplacingAll(content, "-->"_s, "--&gt;"_s);
    StringBuilder payload;
    for (auto& line : content.splitAllowingEmptyEntries('\n'))
        payload.append(line.isEmpty() ? "\u200b"_s : line, '\n');
    Cue copy { *cue, cue->startTime(), cue->endTime(), body.toString(), payload.toString(), region, cue->region(), regionName, cue->region() ? cue->region()->id() : String { }, cueName, cue->id(), key };
    auto found = previous;
    auto retained = bytes();
    if (found != target->cues.end())
        retained -= 2 * sizeof(Cue) + found->settings.sizeInBytes() + found->content.sizeInBytes() + found->region.sizeInBytes() + found->regionStyleID.sizeInBytes() + found->regionName.sizeInBytes() + found->cueStyleID.sizeInBytes() + found->cueName.sizeInBytes() + found->key.sizeInBytes();
    auto added = 2 * sizeof(Cue) + copy.settings.sizeInBytes() + copy.content.sizeInBytes() + copy.region.sizeInBytes() + copy.regionStyleID.sizeInBytes() + copy.regionName.sizeInBytes() + copy.cueStyleID.sizeInBytes() + copy.cueName.sizeInBytes() + copy.key.sizeInBytes();
    if (retained > m_budget || added > m_budget - retained) {
        m_failed = true;
        if (!m_refreshing)
            m_changed();
        return;
    }
    if (found != target->cues.end())
        *found = WTF::move(copy);
    else
        target->cues.append(WTF::move(copy));
    if (!m_refreshing)
        m_changed();
}
void MediaRestreamSubtitles::reset()
{
    Ref protect { *this };
    m_refreshing = true;
    for (auto& track : m_tracks) {
        track.cues.clear();
        if (auto* cues = track.source->cuesInternal())
            textTrackAddCues(track.source, *cues);
    }
    m_refreshing = false;
}
void MediaRestreamSubtitles::rebind(HTMLMediaElement& element)
{
    auto* available = element.textTracks();
    if (m_frozen || !available)
        return;
    Ref protect { *this };
    m_refreshing = true;
    for (auto& stored : m_tracks) {
        if (stored.source->trackType() != TextTrack::InBand)
            continue;
        bool stillPresent = false;
        RefPtr<TextTrack> replacement;
        unsigned matches = 0;
        for (unsigned i = 0; i < available->length(); ++i) {
            auto* candidate = available->item(i);
            if (candidate == stored.source.ptr()) {
                stillPresent = true;
                break;
            }
            if (candidate->trackType() != TextTrack::InBand || candidate->kind() != stored.source->kind()
                || candidate->id() != stored.source->id() || candidate->language() != stored.source->language()
                || candidate->label() != stored.source->label())
                continue;
            replacement = candidate;
            ++matches;
        }
        if (stillPresent || matches != 1)
            continue;
        auto mode = stored.showing ? TextTrack::Mode::Showing : TextTrack::Mode::Hidden;
        stored.source->clearClient(*this);
        stored.source = replacement.releaseNonNull();
        stored.cues.clear();
        stored.source->addClient(*this);
        stored.source->setMode(mode);
        if (auto* cues = stored.source->cuesInternal())
            textTrackAddCues(stored.source, *cues);
    }
    m_refreshing = false;
}
void MediaRestreamSubtitles::prune(double before)
{
    for (auto& track : m_tracks)
        track.cues.removeAllMatching([&](auto& cue) { return cue.end <= before; });
}
uint64_t MediaRestreamSubtitles::bytes() const
{
    uint64_t bytes = 0;
    for (auto& track : m_tracks) {
        bytes += sizeof(Track) + track.label.sizeInBytes() + track.language.sizeInBytes();
        for (auto& style : track.styles)
            bytes += 2 * sizeof(String) + style.sizeInBytes();
        for (auto& cue : track.cues)
            bytes += 2 * sizeof(Cue) + cue.settings.sizeInBytes() + cue.content.sizeInBytes() + cue.region.sizeInBytes() + cue.regionStyleID.sizeInBytes() + cue.regionName.sizeInBytes() + cue.cueStyleID.sizeInBytes() + cue.cueName.sizeInBytes() + cue.key.sizeInBytes();
    }
    return bytes;
}
String MediaRestreamSubtitles::renditions() const
{
    StringBuilder result;
    bool selected = false;
    for (size_t i = 0; i < m_tracks.size(); ++i) {
        auto& track = m_tracks[i].source;
        if (m_frozen ? !m_tracks[i].available : track->readinessState() == TextTrack::FailedToLoad)
            continue;
        bool use = !selected && m_tracks[i].showing;
        selected |= use;
        result.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"text\",NAME=\""_s, attribute(m_tracks[i].label), " ("_s, i + 1,
            ")\",DEFAULT="_s, use ? "YES"_s : "NO"_s, ",AUTOSELECT="_s, use ? "YES"_s : "NO"_s,
            ",FORCED="_s, m_tracks[i].forced ? "YES"_s : "NO"_s);
        if (!m_tracks[i].language.isEmpty())
            result.append(",LANGUAGE=\""_s, m_tracks[i].language, '"');
        if (track->kind() == TextTrack::Kind::Captions)
            result.append(",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\""_s);
        result.append(",URI=\"sub-"_s, i, ".m3u8\"\n"_s);
    }
    return result.toString();
}
struct SubtitleStyleMapping { ASCIILiteral function; String original; String replacement; };

static String mappedSelector(CSSParserTokenRange tokens, const Vector<SubtitleStyleMapping>& mappings)
{
    StringBuilder result;
    Vector<unsigned> contexts;
    unsigned context = 0;
    while (!tokens.atEnd()) {
        auto token = tokens.consume();
        auto* next = tokens.atEnd() ? nullptr : &tokens.peek();
        if (token.getBlockType() == CSSParserToken::BlockStart) {
            contexts.append(context);
            if (token.type() == FunctionToken && equalIgnoringASCIICase(token.value(), "cue"_s))
                context = 1;
            else if (token.type() == FunctionToken && equalIgnoringASCIICase(token.value(), "cue-region"_s))
                context = 2;
        }
        if (context && token.type() == HashToken) {
            Vector<String> replacements;
            for (auto& mapping : mappings) {
                if (mapping.function == (context == 1 ? "cue"_s : "cue-region"_s) && mapping.original == token.value() && !replacements.contains(mapping.replacement))
                    replacements.append(mapping.replacement);
            }
            if (replacements.isEmpty()) {
                token.serialize(result);
                result.append(":not(*)"_s);
            } else if (replacements.size() == 1)
                CSSParserToken(HashTokenId, replacements[0]).serialize(result, next);
            else {
                result.append(":is("_s);
                for (size_t i = 0; i < replacements.size(); ++i) {
                    if (i)
                        result.append(',');
                    CSSParserToken(HashTokenId, replacements[i]).serialize(result);
                }
                result.append(')');
            }
        } else
            token.serialize(result, next);
        if (token.getBlockType() == CSSParserToken::BlockEnd && !contexts.isEmpty())
            context = contexts.takeLast();
    }
    return result.toString();
}

static String mappedStyleRules(CSSParserTokenRange tokens, const Vector<SubtitleStyleMapping>& mappings)
{
    StringBuilder result;
    Vector<CSSParserTokenRange> parents;
    while (true) {
        if (tokens.atEnd()) {
            if (parents.isEmpty())
                break;
            result.append('}');
            tokens = parents.takeLast();
            continue;
        }
        auto start = tokens;
        while (!tokens.atEnd() && tokens.peek().type() != LeftBraceToken && tokens.peek().type() != SemicolonToken)
            tokens.consumeComponentValue();
        auto header = start.rangeUntil(tokens);
        if (tokens.atEnd()) {
            result.append(header.serialize());
            continue;
        }
        if (tokens.peek().type() == SemicolonToken) {
            result.append(header.serialize());
            tokens.consume().serialize(result);
            continue;
        }
        auto body = tokens.consumeBlock();
        auto first = header;
        first.consumeWhitespace();
        bool grouping = !first.atEnd() && first.peek().type() == AtKeywordToken;
        result.append(grouping ? header.serialize() : mappedSelector(header, mappings), '{');
        if (grouping) {
            parents.append(tokens);
            tokens = body;
        } else
            result.append(body.serialize(), '}');
    }
    return result.toString();
}

String MediaRestreamSubtitles::segment(size_t track, double start, double end, double rate, double offset) const
{
    if (track >= m_tracks.size() || !std::isfinite(rate) || rate <= 0 || !std::isfinite(offset))
        return { };
    StringBuilder result;
    result.append("WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:324000000\n\n"_s);
    Vector<const Cue*> selected;
    for (auto& cue : m_tracks[track].cues) {
        if (cue.start < end && cue.end > start)
            selected.append(&cue);
    }
    std::stable_sort(selected.begin(), selected.end(), [](auto* a, auto* b) { return a->start < b->start; });
    Vector<SubtitleStyleMapping> mappings;
    auto appendMapping = [&](ASCIILiteral function, const String& original, const String& replacement) {
        if (std::none_of(mappings.begin(), mappings.end(), [&](auto& mapping) { return mapping.function == function && mapping.original == original && mapping.replacement == replacement; }))
            mappings.append({ function, original, replacement });
    };
    for (auto* cue : selected) {
        if (!cue->regionStyleID.isEmpty())
            appendMapping("cue-region"_s, cue->regionStyleID, cue->regionName);
        if (!cue->cueStyleID.isEmpty())
            appendMapping("cue"_s, cue->cueStyleID, cue->cueName);
    }
    for (auto& sheet : m_tracks[track].styles) {
        CSSTokenizer tokenizer(sheet);
        result.append("STYLE\n"_s, mappedStyleRules(tokenizer.tokenRange(), mappings), "\n\n"_s);
    }
    Vector<String> regions;
    for (auto* cue : selected) {
        if (!cue->region.isEmpty() && !regions.contains(cue->regionName)) {
            regions.append(cue->regionName);
            result.append(cue->region);
        }
    }
    auto milliseconds = [&](double time) -> std::optional<uint64_t> {
        auto value = (time - offset) / rate * 1000;
        if (!std::isfinite(value) || value >= static_cast<double>(std::numeric_limits<int64_t>::max()))
            return std::nullopt;
        return static_cast<uint64_t>(std::round(std::max(0.0, value)));
    };
    for (auto* cue : selected) {
        auto begin = milliseconds(cue->start);
        auto end = milliseconds(cue->end);
        if (!begin || !end)
            return { };
        auto first = *begin;
        auto last = std::max(first + 1, *end);
        if (!cue->cueName.isEmpty())
            result.append(cue->cueName, '\n');
        result.append(timestamp(first), " --> "_s, timestamp(last), cue->settings, '\n');
        StringView content(cue->content);
        unsigned position = 0;
        uint64_t previous = first;
        while (position < content.length()) {
            auto open = content.find('<', position);
            if (open == notFound) {
                result.append(content.substring(position));
                break;
            }
            result.append(content.substring(position, open - position));
            auto close = content.find('>', open + 1);
            MediaTime inlineTime;
            if (close != notFound && WebVTTParser::collectTimeStamp(content.substring(open + 1, close - open - 1).toString(), inlineTime)) {
                auto mapped = milliseconds(inlineTime.toDouble());
                if (!mapped)
                    return { };
                if (*mapped > previous && *mapped < last) {
                    result.append('<', timestamp(*mapped), '>');
                    previous = *mapped;
                }
                position = close + 1;
            } else {
                result.append('<');
                position = open + 1;
            }
        }
        result.append('\n');
    }
    return result.toString();
}
}
