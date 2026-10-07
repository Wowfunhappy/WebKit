/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// session-owned worker pools bridge curl I/O to main-thread browser policy or a synchronous loader queue.
#include "CocoaCurlTransfer.h"
#include <wtf/Deque.h>
#include <wtf/Function.h>
#include <wtf/ListHashSet.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {
class SynchronousLoaderMessageQueue;

class WEBCORE_EXPORT CocoaCurlConnectionPool final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<CocoaCurlConnectionPool> {
public:
    static Ref<CocoaCurlConnectionPool> create();
    ~CocoaCurlConnectionPool();
    RunLoop& runLoop() const { return m_worker; }
    // Each network partition has a scheduler, and so a connection cache, of its own. A synchronous load
    // blocks the main thread, which every asynchronous transfer waits on to resume, so synchronous loads
    // take connections from a scheduler of their own.
    enum class Loader : bool { Asynchronous, Synchronous };
    CocoaCurlScheduler& scheduler(const String& partition = { }, Loader = Loader::Asynchronous);
    void invalidate();
private:
    using SchedulerKey = std::pair<String, bool>;
    CocoaCurlConnectionPool();
    void removeScheduler(const SchedulerKey&, CocoaCurlScheduler&);
    void evictIdleSessionCaches();
    Ref<RunLoop> m_worker;
    HashMap<SchedulerKey, Ref<CocoaCurlScheduler>> m_schedulers; // Only accessed on m_worker.
    // A scheduler leaves m_schedulers once its partition is idle; its TLS sessions stay here for the next
    // one. The pool keeps four partitions' caches (curl sizes each for 256 peers in build_deps.sh), and
    // gives up the least recently active idle partition's first.
    static constexpr unsigned retainedSessionCaches = 4;
    HashMap<SchedulerKey, Ref<CocoaCurlSessionCache>> m_sessionCaches; // Only accessed on m_worker.
    ListHashSet<SchedulerKey> m_sessionCacheRecency; // Least recently active first. Only accessed on m_worker.
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
    // A client that cannot take the body yet, because the response it published awaits policy, holds
    // delivery: the transfer is deferred, and callbacks already on their way wait, in order, until release.
    void setHoldsDelivery(bool);
    std::shared_ptr<CocoaCurlTLSState> tlsState() const { return m_tls; }
private:
    CocoaCurlConnection(CocoaCurlConnectionPool&, CocoaCurlTransferClient&, CocoaCurlTransferOptions&&, SynchronousLoaderMessageQueue*, ClientDispatcher&&);
    void dispatchToClient(Function<void()>&&);
    // A transfer callback for the client, which waits while the client defers loading or holds delivery.
    void deliverToClient(Function<void()>&&);
    void runClientCallback(Function<void()>&&);
    void runHeldCallbacks();
    void updateTransferDeferral();
    void acknowledge();
    std::shared_ptr<CocoaCurlTLSState> copyTLSState();
    void curlReceivedCookies(Vector<String>&&, int statusCode, const String& remoteAddress, const String& canonicalName, CompletionHandler<void(std::optional<String>&&)>&&) final;
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) final;
    void curlReceivedInformationalResponse(ResourceResponse&&) final;
    void curlReceivedData(const SharedBuffer&) final;
    void curlSentData(uint64_t, uint64_t) final;
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) final;
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&&) final;
    void curlCompleted(const ResourceError&, const NetworkLoadMetrics&) final;

    Ref<CocoaCurlConnectionPool> m_pool;
    RefPtr<SynchronousLoaderMessageQueue> m_messageQueue;
    ClientDispatcher m_clientDispatcher; // Immutable after start except for a worker-ordered download adoption.
    CocoaCurlTransferClient* m_client; // Main thread only.
    std::optional<CocoaCurlTransferOptions> m_options; // Main thread, moved to worker when starting.
    std::shared_ptr<CocoaCurlTLSState> m_tls; // Main-thread snapshot; never the worker's mutable handshake state.
    bool m_cancelled { false }; // Main thread only.
    bool m_deferred { false }; // Main thread only.
    bool m_holdsDelivery { false }; // Main thread only.
    Deque<Function<void()>> m_heldCallbacks; // Main thread only.
    RefPtr<CocoaCurlTransfer> m_transfer; // Worker only.
    CompletionHandler<void(std::optional<String>&&)> m_cookieContinuation; // Worker only.
    CompletionHandler<void()> m_continuation; // Worker only; never destroy a transport Ref on the client thread.
    CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)> m_identityContinuation; // Worker only.
    // A reused connection can carry a second transfer that asks before the first answer lands; one
    // peer has one trust decision, so every waiter takes the same one.
    Vector<CompletionHandler<void(bool)>> m_trustContinuations; // Worker only.
};
} // namespace WebCore
