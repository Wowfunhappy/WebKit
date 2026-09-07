/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// session-owned worker pools bridge curl I/O to main-thread browser policy or a synchronous loader queue.
#include "CocoaCurlTransfer.h"
#include <wtf/Function.h>

namespace WebCore {
class SynchronousLoaderMessageQueue;

class WEBCORE_EXPORT CocoaCurlConnectionPool final : public ThreadSafeRefCounted<CocoaCurlConnectionPool> {
public:
    static Ref<CocoaCurlConnectionPool> create();
    ~CocoaCurlConnectionPool();
    RunLoop& runLoop() const { return m_worker; }
    CocoaCurlScheduler& scheduler();
    void invalidate();
private:
    CocoaCurlConnectionPool();
    Ref<RunLoop> m_worker;
    RefPtr<CocoaCurlScheduler> m_scheduler; // Only accessed on m_worker.
    bool m_invalidated { false }; // Only accessed on m_worker.
};

class WEBCORE_EXPORT CocoaCurlConnection final : public ThreadSafeRefCounted<CocoaCurlConnection, WTF::DestructionThread::Main>, private CocoaCurlTransferClient {
public:
    using ClientDispatcher = Function<void(Function<void()>&&)>;
    static Ref<CocoaCurlConnection> create(CocoaCurlConnectionPool&, CocoaCurlTransferClient&, CocoaCurlTransferOptions&&, SynchronousLoaderMessageQueue* = nullptr, ClientDispatcher&& = { });
    ~CocoaCurlConnection();
    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }
    void start();
    void cancel();
    void invalidateClient();
    void setClient(CocoaCurlTransferClient&);
    void setPriority(ResourceLoadPriority);
    void setDefersLoading(bool);
    std::shared_ptr<CocoaCurlTLSState> tlsState() const { return m_tls; }
private:
    CocoaCurlConnection(CocoaCurlConnectionPool&, CocoaCurlTransferClient&, CocoaCurlTransferOptions&&, SynchronousLoaderMessageQueue*, ClientDispatcher&&);
    void dispatchToClient(Function<void()>&&);
    void acknowledge();
    std::shared_ptr<CocoaCurlTLSState> copyTLSState();
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&&) final;
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) final;
    void curlReceivedInformationalResponse(ResourceResponse&&) final;
    void curlReceivedData(const SharedBuffer&, CompletionHandler<void()>&&) final;
    void curlSentData(uint64_t, uint64_t) final;
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) final;
    void curlCompleted(const ResourceError&, const NetworkLoadMetrics&) final;

    Ref<CocoaCurlConnectionPool> m_pool;
    RefPtr<SynchronousLoaderMessageQueue> m_messageQueue;
    ClientDispatcher m_clientDispatcher; // Immutable after start except for a worker-ordered download adoption.
    CocoaCurlTransferClient* m_client; // Main thread only.
    std::optional<CocoaCurlTransferOptions> m_options; // Main thread, moved to worker when starting.
    std::shared_ptr<CocoaCurlTLSState> m_tls; // Main-thread snapshot; never the worker's mutable handshake state.
    bool m_cancelled { false }; // Main thread only.
    bool m_deferred { false }; // Main thread only.
    RefPtr<CocoaCurlTransfer> m_transfer; // Worker only.
    CompletionHandler<void(std::optional<String>&&)> m_cookieContinuation; // Worker only.
    CompletionHandler<void()> m_continuation; // Worker only; never destroy a transport Ref on the client thread.
    CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)> m_identityContinuation; // Worker only.
};
} // namespace WebCore
