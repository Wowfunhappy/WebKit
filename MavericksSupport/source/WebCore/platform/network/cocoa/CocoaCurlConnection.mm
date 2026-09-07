/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlConnection.h"
#include "ResourceError.h"
#include "SharedBuffer.h"
#include "HTTPParsers.h"
#include <cmath>
#include "SynchronousLoaderClient.h"

// one worker owns every easy/multi handle in a session pool; policy callbacks retain their original client queue.
namespace WebCore {
Ref<CocoaCurlConnectionPool> CocoaCurlConnectionPool::create()
{
    return adoptRef(*new CocoaCurlConnectionPool);
}
CocoaCurlConnectionPool::CocoaCurlConnectionPool()
    : m_worker(RunLoop::create("Cocoa curl transport"_s))
{
}
CocoaCurlConnectionPool::~CocoaCurlConnectionPool()
{
    // All jobs hold the pool alive. Its last release therefore observes the worker's final scheduler ownership.
    m_worker->dispatch([scheduler = WTF::move(m_scheduler), worker = m_worker]() mutable {
        scheduler = nullptr;
        worker->stop();
    });
}
CocoaCurlScheduler& CocoaCurlConnectionPool::scheduler()
{
    ASSERT(m_worker->isCurrent());
    if (!m_scheduler) {
        m_scheduler = CocoaCurlScheduler::create();
        if (m_invalidated)
            m_scheduler->invalidate();
    }
    return *m_scheduler;
}
void CocoaCurlConnectionPool::invalidate()
{
    m_worker->dispatch([pool = Ref { *this }] {
        pool->m_invalidated = true;
        if (pool->m_scheduler)
            pool->m_scheduler->invalidate();
    });
}
Ref<CocoaCurlConnection> CocoaCurlConnection::create(CocoaCurlConnectionPool& pool, CocoaCurlTransferClient& client, CocoaCurlTransferOptions&& options, SynchronousLoaderMessageQueue* queue, ClientDispatcher&& dispatcher)
{
    ASSERT(isMainThread());
    return adoptRef(*new CocoaCurlConnection(pool, client, WTF::move(options), queue, WTF::move(dispatcher)));
}
CocoaCurlConnection::CocoaCurlConnection(CocoaCurlConnectionPool& pool, CocoaCurlTransferClient& client, CocoaCurlTransferOptions&& options, SynchronousLoaderMessageQueue* queue, ClientDispatcher&& dispatcher)
    : m_pool(pool)
    , m_messageQueue(queue)
    , m_clientDispatcher(WTF::move(dispatcher))
    , m_client(&client)
    , m_options(WTF::move(options))
{
}
CocoaCurlConnection::~CocoaCurlConnection()
{
    ASSERT(isMainThread());
    ASSERT(!m_transfer);
}
void CocoaCurlConnection::start()
{
    ASSERT(isMainThread());
    if (!m_options || m_cancelled)
        return;
    auto options = *std::exchange(m_options, std::nullopt);
    options.request = options.request.isolatedCopy();
    // Upload ownership is the prepared body, independent of the request's main-thread FormData.
    options.request.setHTTPBody(nullptr);
    options.boundInterface = options.boundInterface.isolatedCopy();
    options.user = options.user.isolatedCopy();
    options.password = options.password.isolatedCopy();
    options.proxyCredentialHost = options.proxyCredentialHost.isolatedCopy();
    options.proxyUser = options.proxyUser.isolatedCopy();
    options.proxyPassword = options.proxyPassword.isolatedCopy();
    m_pool->runLoop().dispatch([connection = Ref { *this }, options = WTF::move(options), deferred = m_deferred]() mutable {
        connection->m_transfer = CocoaCurlTransfer::create(connection->m_pool->scheduler(), connection.get(), WTF::move(options));
        connection->m_transfer->setDefersLoading(deferred);
        connection->m_transfer->start();
    });
}
void CocoaCurlConnection::cancel()
{
    ASSERT(isMainThread());
    if (std::exchange(m_cancelled, true))
        return;
    m_options.reset();
    m_pool->runLoop().dispatch([connection = Ref { *this }] {
        if (connection->m_transfer)
            connection->m_transfer->invalidateClient();
        if (connection->m_continuation)
            std::exchange(connection->m_continuation, nullptr)();
        if (connection->m_cookieContinuation)
            std::exchange(connection->m_cookieContinuation, nullptr)(std::nullopt);
        if (connection->m_identityContinuation)
            std::exchange(connection->m_identityContinuation, nullptr)(nullptr, nullptr);
        connection->m_transfer = nullptr;
    });
}
void CocoaCurlConnection::invalidateClient()
{
    ASSERT(isMainThread());
    m_client = nullptr;
    cancel();
}
void CocoaCurlConnection::setClient(CocoaCurlTransferClient& client)
{
    ASSERT(isMainThread());
    ASSERT(!m_cancelled && !m_messageQueue);
    m_client = &client;
    m_pool->runLoop().dispatch([connection = Ref { *this }] { connection->m_clientDispatcher = nullptr; });
}
void CocoaCurlConnection::setPriority(ResourceLoadPriority priority)
{
    ASSERT(isMainThread());
    if (m_options)
        m_options->request.setPriority(priority);
    m_pool->runLoop().dispatch([connection = Ref { *this }, priority] {
        if (connection->m_transfer)
            connection->m_transfer->setPriority(priority);
    });
}
void CocoaCurlConnection::setDefersLoading(bool deferred)
{
    ASSERT(isMainThread());
    m_deferred = deferred;
    m_pool->runLoop().dispatch([connection = Ref { *this }, deferred] {
        if (connection->m_transfer)
            connection->m_transfer->setDefersLoading(deferred);
    });
}
void CocoaCurlConnection::dispatchToClient(Function<void()>&& callback)
{
    ASSERT(m_pool->runLoop().isCurrent());
    if (m_messageQueue)
        m_messageQueue->append(makeUnique<Function<void()>>(WTF::move(callback)));
    else if (m_clientDispatcher)
        m_clientDispatcher(WTF::move(callback));
    else
        RunLoop::mainSingleton().dispatch(WTF::move(callback));
}
void CocoaCurlConnection::acknowledge()
{
    ASSERT(isMainThread());
    m_pool->runLoop().dispatch([connection = Ref { *this }] {
        if (connection->m_continuation)
            std::exchange(connection->m_continuation, nullptr)();
    });
}
std::shared_ptr<CocoaCurlTLSState> CocoaCurlConnection::copyTLSState()
{
    ASSERT(m_pool->runLoop().isCurrent());
    auto original = m_transfer->tlsState();
    if (!original)
        return nullptr;
    auto state = std::make_shared<CocoaCurlTLSState>();
    state->url = original->url.isolatedCopy();
    state->trust = original->trust;
    state->peerChain = original->peerChain;
    state->evaluated = original->evaluated;
    state->accepted = original->accepted;
    return state;
}
// the cookie owner runs on its client queue; its continuation remains on the transport worker.
void CocoaCurlConnection::curlReceivedCookies(Vector<String>&& fields, CompletionHandler<void(std::optional<String>&&)>&& completion)
{
    ASSERT(!m_cookieContinuation);
    m_cookieContinuation = WTF::move(completion);
    auto cookies = fields.map([](const String& field) { return field.isolatedCopy(); });
    dispatchToClient([connection = Ref { *this }, cookies = WTF::move(cookies)]() mutable {
        if (connection->m_cancelled)
            return;
        RefPtr client = connection->m_client;
        if (!client) {
            connection->cancel();
            return;
        }
        client->curlReceivedCookies(WTF::move(cookies), [connection](std::optional<String>&& cookie) {
            connection->m_pool->runLoop().dispatch([connection, cookie = cookie ? std::optional { cookie->isolatedCopy() } : std::nullopt]() mutable {
                if (connection->m_cookieContinuation)
                    std::exchange(connection->m_cookieContinuation, nullptr)(WTF::move(cookie));
            });
        });
    });
}
void CocoaCurlConnection::curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion)
{
    ASSERT(!m_continuation);
    m_continuation = WTF::move(completion);
    auto data = response.response.crossThreadData();
    dispatchToClient([connection = Ref { *this }, data = WTF::move(data), proxy = response.proxyHost.isolatedCopy(), port = response.proxyPort, authentication = response.authentication, proxyAuthentication = response.proxyAuthentication, metrics = response.metrics.isolatedCopy(), tls = copyTLSState()]() mutable {
        if (connection->m_cancelled)
            return;
        connection->m_tls = WTF::move(tls);
        if (RefPtr client = connection->m_client)
            client->curlReceivedResponse({ ResourceResponse::fromCrossThreadData(WTF::move(data)), WTF::move(proxy), port, authentication, proxyAuthentication, WTF::move(metrics) }, [connection] { connection->acknowledge(); });
        else
            connection->cancel();
    });
}
void CocoaCurlConnection::curlReceivedInformationalResponse(ResourceResponse&& response)
{
    dispatchToClient([connection = Ref { *this }, data = response.crossThreadData()]() mutable {
        if (!connection->m_cancelled) {
            if (RefPtr client = connection->m_client)
                client->curlReceivedInformationalResponse(ResourceResponse::fromCrossThreadData(WTF::move(data)));
        }
    });
}
void CocoaCurlConnection::curlReceivedData(const SharedBuffer& data, CompletionHandler<void()>&& completion)
{
    ASSERT(!m_continuation);
    m_continuation = WTF::move(completion);
    dispatchToClient([connection = Ref { *this }, data = Ref { data }] {
        if (connection->m_cancelled)
            return;
        if (RefPtr client = connection->m_client)
            client->curlReceivedData(data, [connection] { connection->acknowledge(); });
        else
            connection->cancel();
    });
}
void CocoaCurlConnection::curlSentData(uint64_t sent, uint64_t total)
{
    dispatchToClient([connection = Ref { *this }, sent, total] {
        if (!connection->m_cancelled) {
            if (RefPtr client = connection->m_client)
                client->curlSentData(sent, total);
        }
    });
}
void CocoaCurlConnection::curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion)
{
    ASSERT(!m_identityContinuation);
    m_identityContinuation = WTF::move(completion);
    dispatchToClient([connection = Ref { *this }, authorities = retainPtr(authorities)] {
        if (connection->m_cancelled)
            return;
        if (RefPtr client = connection->m_client) {
            client->curlRequestedIdentity(authorities.get(), [connection](RetainPtr<SecIdentityRef>&& identity, RetainPtr<CFArrayRef>&& chain) {
                connection->m_pool->runLoop().dispatch([connection, identity = WTF::move(identity), chain = WTF::move(chain)]() mutable {
                    if (connection->m_identityContinuation)
                        std::exchange(connection->m_identityContinuation, nullptr)(WTF::move(identity), WTF::move(chain));
                });
            });
        } else
            connection->cancel();
    });
}
void CocoaCurlConnection::curlCompleted(const ResourceError& error, const NetworkLoadMetrics& metrics)
{
    // NSError is immutable; retain its native trust and diagnostic userInfo while each thread constructs its own lazy ResourceError wrapper.
    dispatchToClient([connection = Ref { *this }, error = retainPtr(error.nsError()), metrics = metrics.isolatedCopy(), tls = copyTLSState()] {
        if (connection->m_cancelled)
            return;
        connection->m_tls = tls;
        if (RefPtr client = connection->m_client)
            client->curlCompleted(ResourceError(error.get()), metrics);
    });
    m_transfer->invalidateClient();
    m_transfer = nullptr;
}
} // namespace WebCore

// WebKit registers its typed resume provider when its Objective-C classes load; WebCore does not link upward to WebKit or WebKitLegacy.
#import "CocoaDownloadTransport.h"
namespace WebCore {
RetainPtr<NSDictionary> cocoaDownloadRequestInformation(const ResourceRequest& request, bool generatedCookieHeader)
{
    auto headers = adoptNS([[NSMutableDictionary alloc] init]);
    for (auto& field : request.httpHeaderFields()) {
        if (generatedCookieHeader && equalLettersIgnoringASCIICase(field.key, "cookie"_s))
            continue;
        [headers setObject:field.value.createNSString().get() forKey:field.key.createNSString().get()];
    }
    return @{
        @"headers": headers.get(),
        @"timeout": @(request.timeoutInterval()),
        @"priority": @(static_cast<unsigned>(request.priority())),
        @"allowCookies": @(request.allowCookies())
    };
}
bool restoreCocoaDownloadRequestInformation(ResourceRequest& request, id information)
{
    if (!information)
        return false;
    if (![information isKindOfClass:[NSDictionary class]])
        return false;
    id headers = [information objectForKey:@"headers"];
    id timeout = [information objectForKey:@"timeout"];
    id priority = [information objectForKey:@"priority"];
    id cookies = [information objectForKey:@"allowCookies"];
    if (![headers isKindOfClass:[NSDictionary class]] || ![timeout isKindOfClass:[NSNumber class]] || ![priority isKindOfClass:[NSNumber class]] || ![cookies isKindOfClass:[NSNumber class]])
        return false;
    double interval = [timeout doubleValue];
    NSInteger importance = [priority integerValue];
    if (!std::isfinite(interval) || interval < 0 || importance < 0 || importance > static_cast<NSInteger>(ResourceLoadPriority::Highest))
        return false;
    for (id name in headers) {
        id value = [headers objectForKey:name];
        if (![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]] || !isValidHTTPToken(String((NSString*)name)) || !isValidHTTPHeaderValue(String((NSString*)value)))
            return false;
        request.setHTTPHeaderField(String((NSString*)name), String((NSString*)value));
    }
    request.setTimeoutInterval(interval);
    request.setPriority(static_cast<ResourceLoadPriority>(importance));
    request.setAllowCookies([cookies boolValue]);
    return true;
}

static std::atomic<CocoaRemoteDownloadFactory> remoteDownloadFactory;
void setCocoaRemoteDownloadFactory(CocoaRemoteDownloadFactory factory)
{
    auto previous = remoteDownloadFactory.exchange(factory, std::memory_order_acq_rel);
    RELEASE_ASSERT(!previous || previous == factory);
}
RetainPtr<id<WebCoreCocoaDownloadTransport>> createCocoaRemoteDownload(NSURLDownload* download, id<NSURLDownloadDelegate> delegate, NSDictionary* information, NSString* path)
{
    auto factory = remoteDownloadFactory.load(std::memory_order_acquire);
    return factory ? factory(download, delegate, information, path) : nullptr;
}
}
