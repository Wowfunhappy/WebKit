#pragma once

#include "MessageReceiver.h"
#include "SharedBufferReference.h"
#include <WebCore/MediaRestreamSource.h>
#include <wtf/HashMap.h>

namespace WebKit {
class MediaRestreamSession final : public IPC::MessageReceiver {
public:
    static MediaRestreamSession& singleton();
    MediaRestreamSession();
    void ref() const final { }
    void deref() const final { }
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void create(WebCore::HTMLMediaElement&, const std::optional<Vector<Ref<WebCore::TextTrack>>>& textTracks, const WebCore::IntSize& captureSize, const String& videoCodec, std::optional<double> maxHistoryDuration, CompletionHandler<void(Expected<uint64_t, String>&&)>&&);
    uint64_t createDirect(WebCore::HTMLMediaElement&, bool matchingTimeline, bool remote = false);
    void stop(uint64_t, bool returnToInline = false, std::optional<double> position = std::nullopt);
    void accept(uint64_t, const URL&);
    void setDidEnd(uint64_t, Function<void()>&&);
    bool contains(uint64_t identifier) const { return m_sources.contains(identifier); }
private:
    void streamDescription(uint64_t, CompletionHandler<void(String&&)>&&);
    void nextFrame(uint64_t, bool, CompletionHandler<void(String&&, uint64_t, uint64_t, std::optional<IPC::SharedBufferReference>&&)>&&);
    void playlist(uint64_t, const String&, CompletionHandler<void(String&&)>&&);
    void segment(uint64_t, uint64_t, uint64_t, CompletionHandler<void(std::optional<IPC::SharedBufferReference>&&)>&&);
    void cancel(uint64_t, uint64_t);
    void playbackState(uint64_t, double position, double duration, double rate);
    void ended(uint64_t);
    uint64_t m_nextIdentifier { 1 };
    HashMap<uint64_t, Ref<WebCore::MediaRestreamSource>> m_sources;
    HashMap<uint64_t, Function<void()>> m_didEnd;
};
}
