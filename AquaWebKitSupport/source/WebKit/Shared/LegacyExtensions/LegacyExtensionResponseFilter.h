// The StreamFilters Safari 7 extensions attach to one response with webRequest.filterResponseData, chained as
// Firefox chains them: the filter attached last reads the body first, and each filter's output is the input of
// the filter attached before it. The output of the filter attached first is the body the page receives.
//
// A filter gets `start` before its first input, `data` for each chunk, and `stop` once its input ends. Its output
// is what its extension writes, until the extension closes it, which ends that output, or disconnects it, after
// which its input passes straight through. A filter holds each chunk it sent until its extension reports having
// dispatched it, so a disconnect passes on, in order, the chunks the extension never handled.

#pragma once

#include <WebCore/SharedBuffer.h>
#include <wtf/Deque.h>
#include <wtf/Function.h>
#include <wtf/RefCounted.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class LegacyExtensionResponseFilter : public RefCounted<LegacyExtensionResponseFilter> {
public:
    // An event for one filter: "start", "data" (with its chunk), "stop" or "error" (with its message).
    using EventSender = Function<void(uint64_t filterID, ASCIILiteral event, RefPtr<WebCore::SharedBuffer>&&, const String& error)>;
    // A chunk of the body the page receives; null once that body ends.
    using Output = Function<void(RefPtr<WebCore::SharedBuffer>&&)>;

    static Ref<LegacyExtensionResponseFilter> create(EventSender&& sendEvent, Output&& output)
    {
        return adoptRef(*new LegacyExtensionResponseFilter(WTF::move(sendEvent), WTF::move(output)));
    }

    // A filter attaches before the body starts.
    bool canAttach() const { return !m_hasInput; }
    void attach(uint64_t filterID);
    bool hasFilter(uint64_t filterID) const { return !!stageIndex(filterID); }
    Vector<uint64_t> filterIDs() const;

    void receive(Ref<WebCore::SharedBuffer>&&);
    void finishInput();
    bool hasFinishedOutput() const { return m_hasFinishedOutput; }

    // `dispatched` is how many of the filter's data events its extension has dispatched.
    void write(uint64_t filterID, Ref<WebCore::SharedBuffer>&&, uint64_t dispatched);
    void close(uint64_t filterID);
    void disconnect(uint64_t filterID, uint64_t dispatched);
    void suspend(uint64_t filterID);
    void resume(uint64_t filterID);
    // The load failed: each filter still running reports the error, and the page receives no more of the body.
    void fail(const String& error);

private:
    LegacyExtensionResponseFilter(EventSender&& sendEvent, Output&& output)
        : m_sendEvent(WTF::move(sendEvent))
        , m_output(WTF::move(output))
    {
    }

    enum class State : uint8_t { Waiting, Transferring, Suspended, Finished, Closed, Disconnected, Failed };
    struct Stage {
        uint64_t filterID { 0 };
        State state { State::Waiting };
        bool inputFinished { false };
        // Input that arrived while the filter was suspended.
        Deque<Ref<WebCore::SharedBuffer>> queuedInput;
        // The data events sent and not yet reported dispatched, oldest first, and how many were reported.
        Deque<Ref<WebCore::SharedBuffer>> undispatched;
        uint64_t dispatchedCount { 0 };
    };

    std::optional<size_t> stageIndex(uint64_t filterID) const;
    void deliver(size_t index, Ref<WebCore::SharedBuffer>&&);
    void finish(size_t index);
    void start(Stage&);
    void sendData(Stage&, Ref<WebCore::SharedBuffer>&&);
    void stop(Stage&);
    void acknowledge(Stage&, uint64_t dispatched);

    EventSender m_sendEvent;
    Output m_output;
    // m_stages[0] reads the response's body; each stage's output is the next stage's input.
    Vector<Stage> m_stages;
    bool m_hasInput { false };
    bool m_hasFinishedOutput { false };
};

} // namespace WebKit
