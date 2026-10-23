#include "config.h"
#include "MediaRestreamSession.h"

#include "LegacyExtensionHostMessages.h"
#include "MediaRestreamSessionMessages.h"
#include "WebProcess.h"
#include <wtf/NeverDestroyed.h>

namespace WebKit {
MediaRestreamSession& MediaRestreamSession::singleton()
{
    static NeverDestroyed<MediaRestreamSession> sessions;
    return sessions;
}

MediaRestreamSession::MediaRestreamSession()
{
    WebProcess::singleton().addMessageReceiver(Messages::MediaRestreamSession::messageReceiverName(), *this);
}

uint64_t MediaRestreamSession::reserve()
{
    auto identifier = m_nextIdentifier++;
    m_reserved.add(identifier);
    return identifier;
}

void MediaRestreamSession::setPlaylistProvider(uint64_t identifier, PlaylistProvider&& provider)
{
    if (provider)
        m_playlistProviders.set(identifier, std::make_shared<PlaylistProvider>(WTF::move(provider)));
    else
        m_playlistProviders.remove(identifier);
}

void MediaRestreamSession::create(WebCore::HTMLMediaElement& element, const std::optional<Vector<Ref<WebCore::TextTrack>>>& textTracks, const WebCore::IntSize& captureSize, const String& videoCodec, std::optional<double> maxHistoryDuration, std::optional<uint64_t> minimumFreeStorage, CompletionHandler<void(Expected<uint64_t, String>&&)>&& completion)
{
    WebCore::MediaRestreamSource::create(element, textTracks, captureSize, videoCodec, maxHistoryDuration, minimumFreeStorage, [this, completion = WTF::move(completion)](auto&& source) mutable {
        if (!source)
            return completion(makeUnexpected(source.error()));
        auto identifier = m_nextIdentifier++;
        source->get().setDidStop([this, identifier] { ended(identifier); });
        source->get().setDidFinish([this, identifier] { completed(identifier); });
        bool ended = source->get().ended();
        m_sources.add(identifier, WTF::move(*source));
        if (ended)
            completed(identifier);
        completion(identifier);
    });
}

void MediaRestreamSession::streamDescription(uint64_t identifier, CompletionHandler<void(String&&)>&& completion)
{
    RefPtr source = m_sources.get(identifier);
    completion(source ? source->streamDescription() : String { });
}

void MediaRestreamSession::nextFrame(uint64_t identifier, bool video, CompletionHandler<void(String&&, uint64_t, uint64_t, std::optional<IPC::SharedBufferReference>&&)>&& completion)
{
    RefPtr source = m_sources.get(identifier);
    if (!source)
        return completion({ }, 0, 0, std::nullopt);
    source->nextFrame(video, [completion = WTF::move(completion)](WebCore::MediaRestreamFrameQueue::Frame&& frame) mutable {
        std::optional<IPC::SharedBufferReference> data;
        if (frame.data)
            data.emplace(WTF::move(frame.data));
        completion(WTF::move(frame.caps), frame.time, frame.duration, WTF::move(data));
    });
}

void MediaRestreamSession::playlist(uint64_t identifier, const String& resource, CompletionHandler<void(String&&)>&& completion)
{
    if (auto provider = m_playlistProviders.get(identifier))
        return (*provider)(resource, WTF::move(completion));
    RefPtr source = m_sources.get(identifier);
    if (source)
        source->textResource(resource, WTF::move(completion));
    else
        completion({ });
}

void MediaRestreamSession::segment(uint64_t identifier, uint64_t request, uint64_t index, CompletionHandler<void(std::optional<IPC::SharedBufferReference>&&)>&& completion)
{
    RefPtr source = m_sources.get(identifier);
    if (!source)
        return completion(std::nullopt);
    source->segment(request, index, [completion = WTF::move(completion)](RefPtr<WebCore::SharedBuffer>&& data) mutable {
        if (!data)
            return completion(std::nullopt);
        completion(IPC::SharedBufferReference { WTF::move(data) });
    });
}


void MediaRestreamSession::cancel(uint64_t identifier, uint64_t request)
{
    RefPtr source = m_sources.get(identifier);
    if (source)
        source->cancel(request);
}

void MediaRestreamSession::releasePage(uint64_t identifier, CompletionHandler<void(bool)>&& completion)
{
    RefPtr source = m_sources.get(identifier);
    completion(m_reserved.contains(identifier) || (source && source->releasePage()));
}

void MediaRestreamSession::accept(uint64_t identifier)
{
    if (RefPtr source = m_sources.get(identifier)) {
        source->accept();
        if (m_completed.contains(identifier))
            reportCompleted(identifier);
    }
}


void MediaRestreamSession::stop(uint64_t identifier)
{
    RefPtr source = m_sources.get(identifier);
    if (source)
        source->stop();
    else if (m_reserved.contains(identifier))
        ended(identifier);
}

void MediaRestreamSession::setDidEnd(uint64_t identifier, Function<void()>&& callback)
{
    ASSERT(contains(identifier));
    m_didEnd.set(identifier, WTF::move(callback));
}

void MediaRestreamSession::completed(uint64_t identifier)
{
    RefPtr source = m_sources.get(identifier);
    if (!source || !source->ended())
        return;
    m_completed.add(identifier);
    if (source->accepted())
        reportCompleted(identifier);
}

void MediaRestreamSession::reportCompleted(uint64_t identifier)
{
    if (!m_completed.remove(identifier))
        return;
    WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::CompleteRestream(identifier), 0);
}

void MediaRestreamSession::ended(uint64_t identifier)
{
    m_playlistProviders.remove(identifier);
    m_reserved.remove(identifier);
    m_completed.remove(identifier);
    m_sources.remove(identifier);
    if (auto callback = m_didEnd.take(identifier))
        callback();
    WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndRestream(identifier), 0);
}
}
