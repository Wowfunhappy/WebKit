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

void MediaRestreamSession::create(WebCore::HTMLMediaElement& element, const std::optional<Vector<Ref<WebCore::TextTrack>>>& textTracks, const WebCore::IntSize& captureSize, const String& videoCodec, std::optional<double> maxHistoryDuration, std::optional<uint64_t> minimumFreeStorage, CompletionHandler<void(Expected<uint64_t, String>&&)>&& completion)
{
    WebCore::MediaRestreamSource::create(element, textTracks, captureSize, videoCodec, maxHistoryDuration, minimumFreeStorage, [this, completion = WTF::move(completion)](auto&& source) mutable {
        if (!source)
            return completion(makeUnexpected(source.error()));
        auto identifier = m_nextIdentifier++;
        source->get().setDidStop([this, identifier] { ended(identifier); });
        m_sources.add(identifier, WTF::move(*source));
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

void MediaRestreamSession::playbackState(uint64_t identifier, double position, double duration, double rate)
{
    if (RefPtr source = m_sources.get(identifier))
        source->remoteStateChanged(position, duration, rate);
}

void MediaRestreamSession::cancel(uint64_t identifier, uint64_t request)
{
    RefPtr source = m_sources.get(identifier);
    if (source)
        source->cancel(request);
}

void MediaRestreamSession::accept(uint64_t identifier, const URL& url)
{
    if (RefPtr source = m_sources.get(identifier))
        source->accept(url);
}

uint64_t MediaRestreamSession::createDirect(WebCore::HTMLMediaElement& element, bool matchingTimeline, bool remote)
{
    auto identifier = m_nextIdentifier++;
    Ref source = WebCore::MediaRestreamSource::createDirect(element, matchingTimeline, remote);
    source->setRemoteControl([identifier](const String& command, double value, CompletionHandler<void(bool)>&& completion) {
        WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::ControlMediaPlayer(identifier, command, value), WTF::move(completion), 0);
    });
    source->setDidStop([this, identifier] { ended(identifier); });
    m_sources.add(identifier, WTF::move(source));
    return identifier;
}

void MediaRestreamSession::stop(uint64_t identifier, bool returnToInline, std::optional<double> position)
{
    RefPtr source = m_sources.get(identifier);
    if (source)
        source->stop(returnToInline, position);
}

void MediaRestreamSession::setDidEnd(uint64_t identifier, Function<void()>&& callback)
{
    ASSERT(m_sources.contains(identifier));
    m_didEnd.set(identifier, WTF::move(callback));
}

void MediaRestreamSession::ended(uint64_t identifier)
{
    m_sources.remove(identifier);
    if (auto callback = m_didEnd.take(identifier))
        callback();
    WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndRestream(identifier), 0);
}
}
