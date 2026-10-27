#include "config.h"
#include "MediaRestreamSource.h"
#include "MediaRestreamCapture.h"
#include <JavaScriptCore/JSValue.h>
#include "HTMLVideoElement.h"
#include "HTMLSourceElement.h"
#include "HTMLNames.h"
#include "ElementChildIteratorInlines.h"
#include "MediaQueryEvaluator.h"
#include "CommonAtomStrings.h"
#include "TimeRanges.h"
#include "RemotePlayback.h"
#include "MediaPlayerPrivateGStreamerMSE.h"
#include <cmath>
#include "MediaRestreamSubtitles.h"
#include "DocumentInlines.h"
#include "DocumentPage.h"
#include "EventListener.h"
#include "Event.h"
#include "EventNames.h"
#include "LocalDOMWindow.h"
#include "MediaPlayerPrivateGStreamer.h"
#include "MediaSourcePrivateGStreamer.h"
#include "TextTrackList.h"
#include "AudioTrack.h"
#include "AudioTrackList.h"
#include "AudioSourceProviderGStreamer.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Scope.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mount.h>

namespace WebCore {
// Match the capture queues, including high-bitrate fragments and VBV bursts.
static constexpr uint64_t storageQueueBudget = 128 * 1024 * 1024;

static std::shared_ptr<FileSystem::FileHandle> captureFile()
{
    auto temporary = FileSystem::openTemporaryFile("media-player-stream-"_s);
    if (!temporary.second || !FileSystem::deleteFile(temporary.first))
        return nullptr;
    return std::make_shared<FileSystem::FileHandle>(WTF::move(temporary.second));
}
struct ExternalPlaybackTarget {
    WeakPtr<HTMLMediaElement> element;
    uint64_t owner;
    bool preparing { true };
    bool enabled { true };
};
static Vector<ExternalPlaybackTarget>& externalTargets()
{
    static NeverDestroyed<Vector<ExternalPlaybackTarget>> targets;
    return targets;
}
bool MediaRestreamSource::externalPlaybackTarget(const HTMLMediaElement& element)
{
    return std::any_of(externalTargets().begin(), externalTargets().end(), [&](auto& target) { return target.element.get() == &element && target.enabled; });
}
bool MediaRestreamSource::preparingExternalPlayback(const HTMLMediaElement& element)
{
    return std::any_of(externalTargets().begin(), externalTargets().end(), [&](auto& target) { return target.element.get() == &element && target.preparing; });
}
void MediaRestreamSource::setPreparingExternalPlayback(HTMLMediaElement& element, uint64_t owner, bool preparing)
{
    bool found = false;
    for (auto& target : externalTargets()) {
        if (target.element.get() == &element && target.owner == owner) {
            target.preparing = preparing;
            found = true;
        }
    }
    if (preparing && !found)
        externalTargets().append({ element, owner, true, false });
    externalTargets().removeAllMatching([](auto& target) { return !target.element || (!target.enabled && !target.preparing); });
}
void MediaRestreamSource::setExternalPlaybackTarget(HTMLMediaElement& element, uint64_t owner, bool enabled)
{
    bool before = externalPlaybackTarget(element);
    for (auto& target : externalTargets()) {
        if (target.element.get() == &element && target.owner == owner)
            target.enabled = enabled;
    }
    externalTargets().removeAllMatching([&](auto& target) { return !target.element || (!target.enabled && !target.preparing) || (enabled && target.element.get() == &element); });
    if (enabled)
        externalTargets().append({ element, owner });
    if (!before && externalPlaybackTarget(element))
        element.remote().shouldPlayToRemoteTargetChanged(true);
    if (before && !externalPlaybackTarget(element))
        element.remote().isPlayingToRemoteTargetChanged(false);
    if (before != externalPlaybackTarget(element))
        element.dispatchEvent(Event::create(eventNames().webkitcurrentplaybacktargetiswirelesschangedEvent, Event::CanBubble::No, Event::IsCancelable::Yes));
}
void MediaRestreamSource::confirmExternalPlaybackTarget(HTMLMediaElement& element, uint64_t owner)
{
    if (std::any_of(externalTargets().begin(), externalTargets().end(), [&](auto& target) { return target.element.get() == &element && target.owner == owner && target.enabled; }))
        element.remote().isPlayingToRemoteTargetChanged(true);
}

class RestreamLifetimeListener final : public EventListener {
public:
    static Ref<RestreamLifetimeListener> create(MediaRestreamSource& source) { return adoptRef(*new RestreamLifetimeListener(source)); }
    void handleEvent(ScriptExecutionContext&, Event& event) final
    {
        if (RefPtr source = m_source.get()) {
            if (event.type() == eventNames().loadeddataEvent || event.type() == eventNames().canplayEvent || event.type() == eventNames().playingEvent) {
                source->resumeAfterSourceChange();
                return;
            }
            if (event.type() == eventNames().emptiedEvent || event.type() == eventNames().loadstartEvent) {
                source->beginSourceChange();
                return;
            }
            if (source->m_rebinding && (event.type() == eventNames().seekingEvent || event.type() == eventNames().seekedEvent)) {
                source->resumeAfterSourceChange();
                return;
            }
            if (event.type() == eventNames().playEvent)
                return;
            if (event.type() == eventNames().seekingEvent) {
                if (source->m_element->loop() && (source->m_restartingLoop || (source->m_capture && source->m_capture->inputEnded()))) {
                    source->m_restartingLoop = true;
                    source->m_loopSeeked = false;
                } else
                    source->interruptCapture();
            } else if (event.type() == eventNames().seekedEvent) {
                if (source->m_restartingLoop)
                    source->m_loopSeeked = true;
                source->startCapture();
            } else if (event.type() == eventNames().endedEvent) {
                if (source->m_captureDrained && !source->m_element->loop())
                    source->finishCapture();
            } else
                source->stop();
        }
    }
private:
    explicit RestreamLifetimeListener(MediaRestreamSource& source) : EventListener(NativeEventListenerType), m_source(source) { }
    WeakPtr<MediaRestreamSource> m_source;
};

static Vector<WeakPtr<MediaRestreamSource>>& sources()
{
    static NeverDestroyed<Vector<WeakPtr<MediaRestreamSource>>> value;
    return value;
}

void MediaRestreamSource::disconnectIndependentPlayback(HTMLMediaElement& element)
{
    Vector<uint64_t> owners;
    for (auto& target : externalTargets()) {
        if (target.element.get() == &element && target.enabled)
            owners.append(target.owner);
    }
    for (auto owner : owners)
        setExternalPlaybackTarget(element, owner, false);

}

void MediaRestreamSource::cancelPending(HTMLMediaElement& element, uint64_t owner)
{
    Vector<Ref<MediaRestreamSource>> pending;
    for (auto& source : sources()) {
        if (source && source->m_element.get() == &element && source->m_presentationOwner == owner && source->m_ready)
            pending.append(*source);
    }
    for (auto& source : pending)
        source->stop();
}

bool MediaRestreamSource::isPlayingExternally(const HTMLMediaElement& element)
{
    ASSERT(isMainThread());
    for (auto& source : sources()) {
        if (source && source->m_element.get() == &element && source->valid())
            return true;
    }
    return false;
}

bool HTMLMediaElement::hasMediaPlayerRestream() const { return MediaRestreamSource::isPlayingExternally(*this); }
void HTMLMediaElement::updateMediaPlayerRestreamState() { visibilityStateChanged(); }
void HTMLMediaElement::setMediaPlayerPresentedExternally(bool presented, uint64_t owner, const String& openingMessage)
{
    if (!presented && m_mediaPlayerPresentationOwner != owner)
        return;
    m_mediaPlayerPresentationOwner = presented ? owner : 0;
    bool changed = m_mediaPlayerPresentedExternally != presented || m_mediaPlayerOpeningMessage != openingMessage || m_mediaPlayerOpeningMessage.isNull() != openingMessage.isNull();
    m_mediaPlayerPresentedExternally = presented;
    m_mediaPlayerOpeningMessage = openingMessage;
    if (RefPtr player = m_player) {
        auto* backend = player->playerPrivate();
        if (is<MediaPlayerPrivateGStreamer>(*backend) || is<MediaPlayerPrivateGStreamerMSE>(*backend))
            static_cast<MediaPlayerPrivateGStreamer*>(backend)->setInlineOutputSuppressed(presented);
    }
    if (!changed)
        return;
    configureMediaControls();
    setControllerJSProperty("externalMediaPresentation"_s, JSC::jsBoolean(presented));
    mediaPlayerRenderingModeChanged();
    invalidateStyleAndLayerComposition();
}

void HTMLMediaElement::stopMediaPlayerRestreams() { MediaRestreamSource::elementDestroyed(*this); }

MediaTime MediaSourcePrivateGStreamer::platformCurrentTime() const
{
    MediaTime time;
    callOnMainThreadAndWait([&] { time = MediaSourcePrivate::platformCurrentTime(); });
    return time;
}

bool MediaSourcePrivateGStreamer::timeIsProgressing() const
{
    bool progressing;
    callOnMainThreadAndWait([&] { progressing = MediaSourcePrivate::timeIsProgressing(); });
    return progressing;
}

void MediaRestreamSource::elementWillLoad(HTMLMediaElement& element)
{
    Vector<Ref<MediaRestreamSource>> active;
    for (auto& source : sources()) {
        if (source && source->m_element.get() == &element)
            active.append(*source);
    }
    for (auto& source : active)
        source->beginSourceChange();
}

void MediaRestreamSource::elementDestroyed(HTMLMediaElement& element)
{
    externalTargets().removeAllMatching([&](auto& target) { return !target.element || target.element.get() == &element; });
    Vector<Ref<MediaRestreamSource>> active;
    for (auto& source : sources()) {
        if (source && source->m_element.get() == &element)
            active.append(*source);
    }
    for (auto& source : active) {
        source->m_element = nullptr;
        source->stop();
    }
}

static MediaPlayerPrivateGStreamer* playbackBackend(HTMLMediaElement& element)
{
    if (!element.player())
        return nullptr;
    auto* backend = element.player()->playerPrivate();
    if (auto* mse = dynamicDowncast<MediaPlayerPrivateGStreamerMSE>(backend))
        return mse;
    return dynamicDowncast<MediaPlayerPrivateGStreamer>(backend);
}

void MediaRestreamSource::audioRoutingChanged(AudioSourceProviderGStreamer& provider)
{
#if ENABLE(WEB_AUDIO)
    Vector<Ref<MediaRestreamSource>> affected;
    for (auto& source : sources()) {
        if (!source || !source->m_element)
            continue;
        auto* player = playbackBackend(*source->m_element);
        if (player && player->audioSourceProvider() == &provider)
            affected.append(*source);
    }
    for (auto& source : affected) {
        source->initialized(makeUnexpected("unsupported-source"_s));
        source->stop();
    }
#endif
}

Vector<URL> HTMLMediaElement::externalMediaSourceURLs()
{
    Vector<URL> result;
    if (!MediaRestreamSource::requiresCapture(*this)) {
        if (isSafeToLoadURL(currentSrc(), InvalidURLAction::DoNothing, false))
            result.append(currentSrc());
        return result;
    }
    if (isWirelessPlaybackTargetDisabled())
        return result;
    for (Ref source : childrenOfType<HTMLSourceElement>(*this)) {
        auto url = source->getNonEmptyURLAttribute(HTMLNames::srcAttr);
        if (!url.protocolIsInHTTPFamily() || !isSafeToLoadURL(url, InvalidURLAction::DoNothing, false))
            continue;
        auto queries = source->parsedMediaAttribute(protect(document()));
        if (!queries.isEmpty() && !MQ::MediaQueryEvaluator { screenAtom(), protect(document()) }.evaluate(queries))
            continue;
        if (!result.contains(url))
            result.append(WTF::move(url));
    }
    return result;
}

bool MediaRestreamSource::requiresCapture(HTMLMediaElement& element)
{
#if ENABLE(ENCRYPTED_MEDIA)
    if (element.mediaKeys())
        return true;
#endif
    return !element.currentSrc().protocolIsInHTTPFamily()
        || (element.player() && is<MediaPlayerPrivateGStreamerMSE>(element.player()->playerPrivate()));
}

MediaRestreamSource::MediaRestreamSource(HTMLMediaElement& element, GstElement* pipeline)
    : m_element(element), m_document(element.document()), m_player(element.player()), m_backend(element.player()->playerPrivate()), m_pipeline(pipeline), m_initialURL(element.currentSrc()), m_presentationOwner(element.mediaPlayerPresentationOwner())

{
    sources().append(*this);
    m_listener = RestreamLifetimeListener::create(*this);
    for (auto& name : { eventNames().emptiedEvent, eventNames().loadstartEvent, eventNames().errorEvent, eventNames().seekingEvent, eventNames().seekedEvent, eventNames().endedEvent, eventNames().playEvent, eventNames().loadeddataEvent, eventNames().canplayEvent, eventNames().playingEvent })
        element.addEventListener(name, Ref { *m_listener });
    if (auto* window = element.document().window())
        window->addEventListener(eventNames().pagehideEvent, Ref { *m_listener });
}

MediaRestreamSource::~MediaRestreamSource()
{
    stop();
    sources().removeAllMatching([this](auto& source) { return !source || source.get() == this; });
}

bool MediaRestreamSource::valid() const
{
    return !m_stopped && (m_ended || (m_rebinding && m_element && m_document && &m_element->document() == m_document.get() && m_document->page()) || sameSource());
}
bool MediaRestreamSource::canNegotiateRemotePlayback(HTMLMediaElement& element)
{
    return requiresCapture(element)
        && !element.isWirelessPlaybackTargetDisabled()
        && (element.hasTargetAvailabilityListeners() || element.hasEventListeners(eventNames().webkitcurrentplaybacktargetiswirelesschangedEvent));
}

bool MediaRestreamSource::allowsExternalPlayback(const HTMLMediaElement& element)
{
    return !element.isWirelessPlaybackTargetDisabled();
}

bool MediaRestreamSource::sameSource() const
{
    if (!m_element || m_element->currentSrc() != m_initialURL || !m_document || &m_element->document() != m_document.get() || !m_document->page() || !m_element->player())
        return false;
    auto* player = playbackBackend(*m_element);
    return player && m_element->player() == m_player.get() && m_player->playerPrivate() == m_backend
        && (m_ended || player->pipeline() == m_pipeline.get()
            || (m_capture && m_capture->inputEnded()) || m_restartingLoop);
}

unsigned MediaRestreamSource::textTrackCount(HTMLMediaElement& element)
{
    auto* tracks = element.textTracks();
    return tracks ? tracks->length() : 0;
}

Vector<Ref<TextTrack>> MediaRestreamSource::selectedTextTracks(HTMLMediaElement& element, const std::optional<Vector<Ref<TextTrack>>>& selection)
{
    Vector<Ref<TextTrack>> result;
    if (auto* available = element.textTracks()) {
        for (unsigned i = 0; i < available->length(); ++i) {
            auto* track = available->item(i);
            if (track->mode() == TextTrack::Mode::Disabled
                || (track->kind() != TextTrack::Kind::Subtitles && track->kind() != TextTrack::Kind::Captions && track->kind() != TextTrack::Kind::Forced))
                continue;
            if (!selection || std::any_of(selection->begin(), selection->end(), [&](auto& selected) { return selected.ptr() == track; }))
                result.append(Ref { *track });
        }
    }
    return result;
}

bool MediaRestreamSource::validateTextTracks(HTMLMediaElement& element, const Vector<Ref<TextTrack>>& tracks)
{
    auto* available = element.textTracks();
    return std::all_of(tracks.begin(), tracks.end(), [&](auto& track) {
        return available && available->contains(track) && track->mode() != TextTrack::Mode::Disabled
            && (track->kind() == TextTrack::Kind::Subtitles || track->kind() == TextTrack::Kind::Captions || track->kind() == TextTrack::Kind::Forced);
    });
}

void MediaRestreamSource::create(HTMLMediaElement& element, const std::optional<Vector<Ref<TextTrack>>>& textTracks, const IntSize& captureSize, const String& videoCodec, std::optional<double> maxHistoryDuration, std::optional<uint64_t> minimumFreeStorage, CompletionHandler<void(Expected<Ref<MediaRestreamSource>, String>&&)>&& completion)
{
    auto* player = playbackBackend(element);
    if (!player || !player->pipeline() || element.ended())
        return completion(makeUnexpected("no-source"_s));
    if (element.paused())
        return completion(makeUnexpected("not-playing"_s));
#if ENABLE(WEB_AUDIO)
    if (auto* provider = player->audioSourceProvider(); provider && static_cast<AudioSourceProviderGStreamer*>(provider)->client())
        return completion(makeUnexpected("unsupported-source"_s));
#endif
    Vector<Ref<MediaRestreamSource>> previous;
    for (auto& existing : sources()) {
        if (existing && existing->m_element.get() == &element)
            previous.append(*existing);
    }
    for (auto& existing : previous)
        existing->stop();
    Ref source = adoptRef(*new MediaRestreamSource(element, player->pipeline()));
    source->m_captureSize = captureSize;
    source->m_videoCodec = videoCodec;
    source->m_maxHistoryDuration = maxHistoryDuration;
    source->m_minimumFreeStorage = minimumFreeStorage;
    if (!videoCodec.isEmpty()) {
        source->m_frames = std::make_shared<MediaRestreamFrameQueue>();
        source->m_frames->ready = [weakThis = WeakPtr { source.get() }] {
            if (RefPtr source = weakThis.get(); source && !source->m_stopped)
                source->initialized(Ref { *source });
        };
    }
    source->m_initializing = source.ptr();
    source->m_ready = WTF::move(completion);
    auto file = captureFile();
    if (!file) {
        source->initialized(makeUnexpected("unsupported-source"_s));
        return source->stop();
    }
    source->m_storage = std::make_shared<Storage>();
    source->m_storage->file = WTF::move(file);
    source->m_subtitles = MediaRestreamSubtitles::create(element, textTracks, true, 16 * 1024 * 1024, [weakThis = WeakPtr { source.get() }] {
        if (RefPtr source = weakThis.get(); source && source->m_subtitles && !source->m_stopped) {
            if (!source->m_subtitles->valid()) {
                source->initialized(makeUnexpected("unsupported-source"_s));
                return source->stop();
            }
            if (source->m_ready && source->m_subtitles->ready() && (source->m_ended || source->m_totalDuration >= hlsMinimumDuration))
                source->initialized(Ref { *source });
        }
    });
    source->startCapture();
    if (!source->m_stopped) {
        element.updateMediaPlayerRestreamState();
    }
}

void MediaRestreamSource::beginSourceChange()
{
    if (m_stopped)
        return;
    if (m_ended) {
        interruptCapture();
        if (m_subtitles)
            m_subtitles->freeze();
        detachElement();
        m_player = nullptr;
        m_pipeline = nullptr;
        return;
    }
    if (std::exchange(m_rebinding, true))
        return;
    m_restartingLoop = false;
    if (!m_capture || !m_capture->finishInput()) {
        interruptCapture();
        m_captureDrained = true;
    }
}

void MediaRestreamSource::resumeAfterSourceChange()
{
    if (!m_rebinding || !valid() || !m_captureDrained || m_element->readyState() < HTMLMediaElement::HAVE_CURRENT_DATA || m_element->seeking())
        return;
    auto* backend = playbackBackend(*m_element);
    if (!backend || !backend->pipeline())
        return;
    if (m_capture) {
        m_capture->stop();
        m_capture = nullptr;
    }
    m_initialURL = m_element->currentSrc();
    m_player = m_element->player();
    m_backend = backend;
    m_pipeline = backend->pipeline();
    m_rebinding = false;
    m_discontinuity = true;
    if (m_subtitles)
        m_subtitles->reset();
    m_element->updateMediaPlayerRestreamState();
    startCapture();
}

void MediaRestreamSource::startCapture()
{
    if (!valid() || m_rebinding || m_ended || m_element->seeking())
        return;
    if (m_capture && !(m_captureDrained && m_restartingLoop && m_loopSeeked))
        return;
    if (m_restartingLoop) {
        if (!m_element->loop())
            return finishCapture();
        if (!m_loopSeeked)
            return;
        auto* player = playbackBackend(*m_element);
        if (!player || !player->pipeline())
            return;
        m_pipeline = player->pipeline();
        m_restartingLoop = false;
        m_loopSeeked = false;
        m_discontinuity = true;
        m_subtitles->reset();
    }
    auto previous = std::exchange(m_capture, nullptr);
    m_captureDrained = false;
    auto generation = ++m_generation;
    auto* audioTracks = m_element->audioTracks();
    bool includeAudio = !audioTracks || !audioTracks->length() || audioTracks->firstEnabled();
    m_capture = MediaRestreamCapture::create(m_pipeline.get(), {
        [weakThis = WeakPtr { *this }, generation](double start, double end, double sourceRate, double sourceOffset, Ref<SharedBuffer>&& data, CompletionHandler<void()>&& completion) {
            if (RefPtr source = weakThis.get(); source && source->valid() && source->m_generation == generation)
                source->append(start, end, sourceRate, sourceOffset, WTF::move(data), WTF::move(completion));
            else
                completion();
        },
        [weakThis = WeakPtr { *this }, generation] {
            if (RefPtr source = weakThis.get(); source && source->valid() && source->m_generation == generation) {
                auto storage = source->m_storage;
                storage->queue->dispatch([weakThis = WeakPtr { *source }, generation]() mutable {
                    callOnMainThread([weakThis = WTF::move(weakThis), generation] {
                        RefPtr source = weakThis.get();
                        if (!source || !source->valid() || source->m_generation != generation)
                            return;
                        source->m_captureDrained = true;
                        if (source->m_rebinding) {
                            source->resumeAfterSourceChange();
                            return;
                        }
                        if (source->m_element->loop()) {
                            source->m_restartingLoop = true;
                            source->startCapture();
                            return;
                        }
                        if (source->m_element->ended())
                            source->finishCapture();
                    });
                });
            }
        },
        [weakThis = WeakPtr { *this }, generation] {
            if (RefPtr source = weakThis.get(); source && source->valid() && source->m_generation == generation) {
                source->interruptCapture();
                source->startCapture();
            }
        },
        [weakThis = WeakPtr { *this }, generation] {
            if (RefPtr source = weakThis.get(); source && source->m_generation == generation) {
                source->initialized(makeUnexpected("unsupported-source"_s));
                source->stop();
            }
        }
    }, includeAudio, m_captureSize, m_videoCodec, m_frames);
    if (previous)
        previous->stop();
    if (!m_capture) {
        initialized(makeUnexpected("unsupported-source"_s));
        stop();
    }
}

void MediaRestreamSource::finishCapture()
{
    m_restartingLoop = false;
    m_ended = true;
    if (m_frames)
        m_frames->finish();
    if (m_element->ended()) {
        if (auto capture = std::exchange(m_capture, nullptr))
            capture->stop();
    }
    if (m_ready)
        initialized(m_segments.empty() ? Expected<Ref<MediaRestreamSource>, String>(makeUnexpected("no-source"_s)) : Expected<Ref<MediaRestreamSource>, String>(Ref { *this }));
    if (m_didFinish)
        std::exchange(m_didFinish, { })();
}

bool MediaRestreamSource::releasePage()
{
    if (!m_ended || !m_accepted || m_ready || m_stopped)
        return false;
    if (auto capture = std::exchange(m_capture, nullptr))
        capture->stop();
    if (m_subtitles)
        m_subtitles->freeze();
    detachElement();
    m_player = nullptr;
    m_pipeline = nullptr;
    return true;
}

void MediaRestreamSource::accept()
{
    m_accepted = true;
    if (m_element)
        m_element->setMediaPlayerPresentedExternally(true, m_presentationOwner);
}

void MediaRestreamSource::interruptCapture()
{
    m_captureDrained = false;
    ++m_generation;
    if (auto capture = std::exchange(m_capture, nullptr))
        capture->stop();
    m_discontinuity = true;
    if (m_subtitles)
        m_subtitles->reset();
}

void MediaRestreamSource::append(double start, double end, double sourceRate, double sourceOffset, Ref<SharedBuffer>&& data, CompletionHandler<void()>&& completion)
{
    auto completeOnError = makeScopeExit([&] {
        if (completion)
            completion();
    });
    auto info = MediaRestreamSegmenter::transportInfo(data.get());
    if (!info || end <= start || std::round(end - start) > hlsTargetDuration) {
        initialized(makeUnexpected("unsupported-source"_s));
        return stop();
    }
    auto discontinuity = std::exchange(m_discontinuity, false);
    if (discontinuity)
        m_nextCounters.clear();
    RestreamCounters offsets;
    for (auto& [pid, count] : info->packets) {
        offsets[pid] = (m_nextCounters[pid] + 16 - info->bases.at(pid)) & 15;
        m_nextCounters[pid] += count;
    }
    auto normalized = MediaRestreamSegmenter::withContinuity(data.get(), offsets);
    Vector<String> subtitles;
    if (!m_rebinding)
        m_subtitles->rebind(*m_element);
    m_subtitles->refresh();
    if (!m_subtitles->valid()) {
        initialized(makeUnexpected("unsupported-source"_s));
        return stop();
    }
    for (size_t i = 0; i < m_subtitles->size(); ++i) {
        subtitles.append(m_subtitles->segment(i, start * sourceRate + sourceOffset, end * sourceRate + sourceOffset, sourceRate, sourceOffset));
        if (subtitles.last().isNull()) {
            initialized(makeUnexpected("unsupported-source"_s));
            return stop();
        }
        m_peakSubtitleBandwidth = std::max(m_peakSubtitleBandwidth, 8.0 * subtitles.last().utf8().length() / (end - start));
    }
    m_subtitles->prune(end * sourceRate + sourceOffset);
    auto bytes = normalized->size();
    SharedBufferBuilder payload;
    payload.append(normalized.copyRef());
    Vector<FileRange> subtitleRanges;
    uint64_t payloadSize = bytes;
    auto storage = m_storage;
    auto enteredStoragePressure = updateStoragePressure();
    if (m_storagePressure)
        trimHistory();
    bool rotatesStorage = m_maxHistoryDuration || (m_minimumFreeStorage && *m_minimumFreeStorage);
    double storageFileDuration = m_storagePressure ? hlsMinimumDuration : m_maxHistoryDuration ? std::min(300.0, *m_maxHistoryDuration / 64) : 300;
    if (rotatesStorage && (enteredStoragePressure || storage->writtenDuration >= storageFileDuration)) {
        storage->file = captureFile();
        storage->writtenBytes = 0;
        storage->writtenDuration = 0;
        if (!storage->file) {
            initialized(makeUnexpected("unsupported-source"_s));
            return stop();
        }
    }
    auto file = storage->file;
    auto offset = storage->writtenBytes;
    for (auto& subtitle : subtitles) {
        auto utf8 = subtitle.utf8();
        subtitleRanges.append({ file, offset + payloadSize, utf8.length() });
        payload.append(utf8.span());
        payloadSize += utf8.length();
    }
    if (payloadSize > storageQueueBudget - m_pendingWrites) {
        initialized(makeUnexpected("unsupported-source"_s));
        return stop();
    }
    m_pendingWrites += payloadSize;
    storage->writtenBytes += payloadSize;
    storage->writtenDuration += end - start;
    m_peakBandwidth = std::max(m_peakBandwidth, 8.0 * bytes / (end - start));
    storage->queue->dispatch([weakThis = WeakPtr { *this }, storage, file, completion = WTF::move(completion), data = payload.takeBufferAsContiguous(), payloadSize, segment = Segment { end - start, { file, offset, bytes }, discontinuity, WTF::move(subtitleRanges) }]() mutable {
        auto bytes = data->span();
        bool success = !storage->stopped;
        while (success && !bytes.empty()) {
            auto written = file->write(bytes);
            if (!written || !*written) { success = false; break; }
            bytes = bytes.subspan(*written);
        }
        callOnMainThread([weakThis = WTF::move(weakThis), completion = WTF::move(completion), segment = WTF::move(segment), payloadSize, success]() mutable {
            completion();
            RefPtr source = weakThis.get();
            if (!source)
                return;
            source->m_pendingWrites -= payloadSize;
            if (!source->valid())
                return;
            if (!success) {
                source->initialized(makeUnexpected("unsupported-source"_s));
                return source->stop();
            }
            source->m_totalDuration += segment.duration;
            source->m_playlistDuration += segment.duration;
            source->m_segments.push_back(WTF::move(segment));
            source->trimHistory();
            if (source->m_ready && source->m_totalDuration >= hlsMinimumDuration)
                source->initialized(Ref { *source });
        });
    });
}

bool MediaRestreamSource::updateStoragePressure()
{
    if (!m_minimumFreeStorage || !*m_minimumFreeStorage || !m_storage || !m_storage->file)
        return false;
    struct statfs statistics;
    if (fstatfs(m_storage->file->platformHandle(), &statistics) < 0)
        return false;
    auto available = static_cast<uint64_t>(statistics.f_bavail) * static_cast<uint64_t>(statistics.f_bsize);
    bool pressure = available < *m_minimumFreeStorage;
    return !std::exchange(m_storagePressure, pressure) && pressure;
}

void MediaRestreamSource::trimHistory()
{
    auto now = MonotonicTime::now();
    auto retainedDuration = m_storagePressure ? std::optional<double> { hlsMinimumDuration } : m_maxHistoryDuration;
    while (retainedDuration && m_segments.size() > 1 && m_playlistDuration > *retainedDuration) {
        auto segment = WTF::move(m_segments.front());
        m_segments.pop_front();
        m_playlistDuration -= segment.duration;
        m_discontinuitySequence += segment.discontinuity;
        m_retiredSegments.push_back({ m_firstSequence++, WTF::move(segment), now + Seconds(hlsMinimumDuration + segment.duration) });
    }
    if (m_storagePressure)
        m_retiredSegments.clear();
    else {
        while (!m_retiredSegments.empty() && m_retiredSegments.front().expires <= now)
            m_retiredSegments.pop_front();
    }
}

const MediaRestreamSource::Segment* MediaRestreamSource::segmentForSequence(uint64_t sequence) const
{
    if (sequence >= m_firstSequence) {
        auto index = sequence - m_firstSequence;
        return index < m_segments.size() ? &m_segments[index] : nullptr;
    }
    if (m_retiredSegments.empty() || sequence < m_retiredSegments.front().sequence)
        return nullptr;
    auto index = sequence - m_retiredSegments.front().sequence;
    return index < m_retiredSegments.size() ? &m_retiredSegments[index].segment : nullptr;
}

void MediaRestreamSource::initialized(Expected<Ref<MediaRestreamSource>, String>&& result)
{
    Ref protect { *this };
    if (!m_ready || (result && !m_frames && m_subtitles && !m_subtitles->ready()))
        return;
    auto completion = std::exchange(m_ready, std::nullopt);
    m_initializing = nullptr;
    (*completion)(WTF::move(result));
}

void MediaRestreamSource::read(FileRange entry, CompletionHandler<void(RefPtr<SharedBuffer>&&)>&& completion)
{
    if (!valid() || entry.size > storageQueueBudget - m_pendingReads)
        return completion(nullptr);
    m_pendingReads += entry.size;
    auto storage = m_storage;
    storage->queue->dispatch([weakThis = WeakPtr { *this }, storage, entry, completion = WTF::move(completion)]() mutable {
        Vector<uint8_t> bytes(entry.size);
        uint64_t position = 0;
        while (!storage->stopped && position < entry.size) {
            auto count = pread(entry.file->platformHandle(), bytes.mutableSpan().data() + position, entry.size - position, entry.offset + position);
            if (count < 0 && errno == EINTR)
                continue;
            if (count <= 0)
                break;
            position += count;
        }
        RefPtr<SharedBuffer> result;
        if (position == entry.size)
            result = SharedBuffer::create(WTF::move(bytes));
        callOnMainThread([weakThis = WTF::move(weakThis), size = entry.size, completion = WTF::move(completion), result = WTF::move(result)]() mutable {
            RefPtr source = weakThis.get();
            if (source)
                source->m_pendingReads -= size;
            if (!source || !source->valid())
                result = nullptr;
            completion(WTF::move(result));
        });
    });
}
void MediaRestreamSource::segment(uint64_t request, uint64_t index, CompletionHandler<void(RefPtr<SharedBuffer>&&)>&& completion)
{
    auto* entry = segmentForSequence(index);
    if (!valid() || m_ready || !entry || m_requests.contains(request))
        return completion(nullptr);
    m_requests.add(request);
    read(entry->media, [weakThis = WeakPtr { *this }, request, completion = WTF::move(completion)](RefPtr<SharedBuffer>&& result) mutable {
        RefPtr source = weakThis.get();
        if (source)
            source->m_requests.remove(request);
        if (!source || source->m_cancelledRequests.remove(request))
            result = nullptr;
        completion(WTF::move(result));
    });
}
void MediaRestreamSource::cancel(uint64_t request)
{
    if (m_requests.contains(request))
        m_cancelledRequests.add(request);
}

void MediaRestreamSource::detachElement()
{
    if (m_element && m_listener) {
        for (auto& name : { eventNames().emptiedEvent, eventNames().loadstartEvent, eventNames().errorEvent, eventNames().seekingEvent, eventNames().seekedEvent, eventNames().endedEvent, eventNames().playEvent, eventNames().loadeddataEvent, eventNames().canplayEvent, eventNames().playingEvent })
            m_element->removeEventListener(name, *m_listener, { });
    }
    if (m_document && m_listener) {
        if (auto* window = m_document->window())
            window->removeEventListener(eventNames().pagehideEvent, *m_listener, { });
    }
    m_listener = nullptr;
    if (m_element) {
        if (m_accepted)
            m_element->setMediaPlayerPresentedExternally(false, m_presentationOwner);
        m_element->updateMediaPlayerRestreamState();
    }
    m_element = nullptr;
    m_document = nullptr;
}

void MediaRestreamSource::stop()
{
    if (std::exchange(m_stopped, true))
        return;
    if (m_frames)
        m_frames->finish(true);
    interruptCapture();
    if (m_accepted && m_element)
        m_element->setMediaPlayerPresentedExternally(false, m_presentationOwner);
    if (m_storage)
        m_storage->stopped = true;
    if (sameSource())
        m_element->updateMediaPlayerRestreamState();
    m_subtitles = nullptr;
    detachElement();
    if (m_ready)
        initialized(makeUnexpected("no-source"_s));
    if (m_didStop)
        std::exchange(m_didStop, { })();
}
}
