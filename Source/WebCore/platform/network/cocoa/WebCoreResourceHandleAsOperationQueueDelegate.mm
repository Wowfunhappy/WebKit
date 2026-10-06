/*
 * Copyright (C) 2004-2018 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WebCoreResourceHandleAsOperationQueueDelegate.h"

#import "AuthenticationChallenge.h"
#import "AuthenticationCocoa.h"
#import "Logging.h"
#import "NetworkingContext.h"
#import "OriginAccessPatterns.h"
#import "ResourceHandle.h"
#import "ResourceHandleClient.h"
#import "ResourceRequest.h"
#import "ResourceResponse.h"
#import "SecurityOrigin.h"
#import "SharedBuffer.h"
#import "SynchronousLoaderClient.h"
#import "WebCoreURLResponse.h"
#import <pal/spi/cf/CFNetworkSPI.h>
#import <pal/spi/cocoa/NSURLConnectionSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/MainThread.h>
#import <wtf/SetForScope.h> // AQUAWEBKIT: for m_deliveringResponse.
#import <wtf/ThreadSafeRefCounted.h> // AQUAWEBKIT: for ConnectionCallback.
#import <wtf/cocoa/TypeCastsCocoa.h>

using namespace WebCore;

// AQUAWEBKIT: one callback of a connection scheduled on the main run loop. Its work runs in place,
// so the answer is in hand when the completion handler runs before the callback returns; a completion
// handler that runs later, after work held behind a pending completion or a deferral, answers late.
class ConnectionCallback : public ThreadSafeRefCounted<ConnectionCallback> {
public:
    static Ref<ConnectionCallback> create(bool runsInPlace) { return adoptRef(*new ConnectionCallback(runsInPlace)); }
    bool runsInPlace() const { return m_runsInPlace; }
    bool isLate() const { return m_runsInPlace && m_returned; }
    void setReturned() { m_returned = true; }
    void setAnswered() { m_answered = true; }
    bool wasAnswered() const { return m_answered; }
private:
    explicit ConnectionCallback(bool runsInPlace)
        : m_runsInPlace(runsInPlace)
    {
    }
    const bool m_runsInPlace;
    bool m_returned { false };
    bool m_answered { false };
};

static bool NODELETE scheduledWithCustomRunLoopMode(const std::optional<SchedulePairHashSet>& pairs)
{
    if (!pairs)
        return false;
    for (auto& pair : *pairs) {
        auto mode = pair->mode();
        if (mode != kCFRunLoopCommonModes && mode != kCFRunLoopDefaultMode)
            return true;
    }
    return false;
}

@implementation WebCoreResourceHandleAsOperationQueueDelegate

- (void)callFunctionOnMainThread:(Function<void()>&&)function
{
    // AQUAWEBKIT: while a response or redirect waits for its completion handler, or the handle
    // defers loading, the main thread holds the connection's later work, in order.
    function = [protectedSelf = retainPtr(self), function = WTF::move(function)] mutable {
        if (protectedSelf->m_waitingForCompletion || protectedSelf->m_defersLoading || !protectedSelf->m_heldWork.isEmpty()) {
            protectedSelf->m_heldWork.append(WTF::move(function));
            return;
        }
        function();
    };

    // AQUAWEBKIT: a connection on the main run loop calls back on the main thread; its work runs in place.
    if (m_callbacksOnMainThread && !m_messageQueue && isMainThread())
        return function();

    [self dispatchFunctionOnMainThread:WTF::move(function)];
}

// AQUAWEBKIT: upstream's -callFunctionOnMainThread: dispatch, which held work's drain also takes.
- (void)dispatchFunctionOnMainThread:(Function<void()>&&)function
{
    // Sync xhr uses the message queue.
    if (m_messageQueue)
        return protect(m_messageQueue)->append(makeUnique<Function<void()>>(WTF::move(function)));

    // This is the common case.
    if (!scheduledWithCustomRunLoopMode(m_scheduledPairs))
        return callOnMainThread(WTF::move(function));

    // If we have been scheduled in a custom run loop mode, schedule a block in that mode.
    auto block = makeBlockPtr([alreadyCalled = false, function = WTF::move(function)] mutable {
        if (alreadyCalled)
            return;
        alreadyCalled = true;
        function();
        function = nullptr;
    });
    // AQUAWEBKIT: enqueueing a block does not wake its run loop; curl's worker must also signal the custom delegate loop.
    // for (auto& pair : *m_scheduledPairs)
    //     CFRunLoopPerformBlock(pair->runLoop(), pair->mode(), block.get());
    for (auto& pair : *m_scheduledPairs) {
        CFRunLoopPerformBlock(pair->runLoop(), pair->mode(), block.get());
        CFRunLoopWakeUp(pair->runLoop()); // AQUAWEBKIT: wake the loop whose delegate block was just queued.
    }
}

// AQUAWEBKIT: the main-run-loop connection state; see callFunctionOnMainThread:.
- (void)setCallbacksOnMainThread
{
    m_callbacksOnMainThread = true;
}

- (void)setDefersLoading:(BOOL)defers connection:(NSURLConnection *)connection
{
    m_defersLoading = defers;
    [connection setDefersCallbacks:defers || m_deferredForCompletion];
    [self scheduleHeldWork];
}

- (BOOL)isDeliveringResponse
{
    return m_deliveringResponse;
}

// Held work runs from its own run loop callout, as the connection's callbacks do.
- (void)scheduleHeldWork
{
    if (m_waitingForCompletion || m_defersLoading || m_heldWork.isEmpty() || m_heldWorkScheduled)
        return;
    m_heldWorkScheduled = true;
    [self dispatchFunctionOnMainThread:[protectedSelf = retainPtr(self)] {
        protectedSelf->m_heldWorkScheduled = false;
        while (!protectedSelf->m_waitingForCompletion && !protectedSelf->m_defersLoading && !protectedSelf->m_heldWork.isEmpty())
            protectedSelf->m_heldWork.takeFirst()();
    }];
}

// The connection stops calling back while a completion handler is outstanding past its callback.
- (void)deferConnectionForCompletion:(NSURLConnection *)connection
{
    if (!m_waitingForCompletion || m_deferredForCompletion)
        return;
    m_deferredForCompletion = true;
    [connection setDefersCallbacks:YES];
}

- (void)continueAfterCompletion:(NSURLConnection *)connection
{
    m_waitingForCompletion = false;
    if (std::exchange(m_deferredForCompletion, false))
        [connection setDefersCallbacks:m_defersLoading];
    [self scheduleHeldWork];
}

- (id)initWithHandle:(WebCore::ResourceHandle*)handle messageQueue:(RefPtr<WebCore::SynchronousLoaderMessageQueue>&&)messageQueue
{
    self = [self init];
    if (!self)
        return nil;

    m_handle = handle;
    if (m_handle && m_handle->context()) {
        if (auto* pairs = protect(m_handle.get())->context()->scheduledRunLoopPairs())
            m_scheduledPairs = *pairs;
    }
    m_messageQueue = WTF::move(messageQueue);

    return self;
}

- (void)detachHandle
{
    Locker locker { m_lock };

    m_handle = nullptr;

    m_messageQueue = nullptr;
    m_requestResult = nullptr;
    m_cachedResponseResult = nullptr;
    m_boolResult = NO;
    m_semaphore.signal(); // OK to signal even if we are not waiting.
    // AQUAWEBKIT: held work has no handle left to reach.
    m_waitingForCompletion = false;
    m_heldWork.clear();
}

- (void)dealloc
{
    [super dealloc];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)newRequest redirectResponse:(NSURLResponse *)redirectResponse
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    redirectResponse = synthesizeRedirectResponseIfNecessary([connection currentRequest], newRequest, redirectResponse);

    // See <rdar://problem/5380697>. This is a workaround for a behavior change in CFNetwork where willSendRequest gets called more often.
    if (!redirectResponse)
        return newRequest;

#if !LOG_DISABLED
    if ([redirectResponse isKindOfClass:[NSHTTPURLResponse class]])
        LOG(Network, "Handle %p delegate connection:%p willSendRequest:%@ redirectResponse:%d, Location:<%@>", m_handle.get(), connection, [newRequest description], static_cast<int>([(id)redirectResponse statusCode]), [[(id)redirectResponse allHeaderFields] objectForKey:@"Location"]);
    else
        LOG(Network, "Handle %p delegate connection:%p willSendRequest:%@ redirectResponse:non-HTTP", m_handle.get(), connection, [newRequest description]);
#endif

    auto protectedSelf = retainPtr(self);
    // AQUAWEBKIT: see ConnectionCallback.
    // auto work = [protectedSelf, newRequest = retainPtr(newRequest), redirectResponse = retainPtr(redirectResponse)] mutable {
    Ref callback = ConnectionCallback::create(m_callbacksOnMainThread && isMainThread());
    auto work = [protectedSelf, newRequest = retainPtr(newRequest), redirectResponse = retainPtr(redirectResponse), connection = retainPtr(connection), callback] mutable {
        if (!protectedSelf->m_handle) {
            protectedSelf->m_requestResult = nullptr;
            // protectedSelf->m_semaphore.signal(); // AQUAWEBKIT: only a blocked callback waits.
            if (!callback->runsInPlace())
                protectedSelf->m_semaphore.signal();
            callback->setAnswered(); // AQUAWEBKIT: see ConnectionCallback.
            return;
        }

        ResourceResponse response(redirectResponse.get());
        ResourceRequest redirectRequest = newRequest.get();
        if ([newRequest HTTPBodyStream]) {
            ASSERT(protectedSelf->m_handle->firstRequest().httpBody());
            redirectRequest.setHTTPBody(protectedSelf->m_handle->firstRequest().httpBody());
        }
        if (protectedSelf->m_handle->firstRequest().httpContentType().isEmpty())
            redirectRequest.clearHTTPContentType();

        // Check if the redirected url is allowed to access the redirecting url's timing information.
        if (!protectedSelf->m_handle->hasCrossOriginRedirect() && !WebCore::SecurityOrigin::create(redirectRequest.url())->canRequest(redirectResponse.get().URL, OriginAccessPatternsForWebProcess::singleton()))
            protectedSelf->m_handle->markAsHavingCrossOriginRedirect();
        protect(protectedSelf->m_handle.get())->checkTAO(response);

        protectedSelf->m_handle->incrementRedirectCount();

        protectedSelf->m_waitingForCompletion = true; // AQUAWEBKIT: see callFunctionOnMainThread:.
        // AQUAWEBKIT: the completion handler continues the connection; see below.
        // protect(protectedSelf->m_handle.get())->willSendRequest(WTF::move(redirectRequest), WTF::move(response), [protectedSelf = WTF::move(protectedSelf)](ResourceRequest&& request) {
        protect(protectedSelf->m_handle.get())->willSendRequest(WTF::move(redirectRequest), WTF::move(response), [protectedSelf = WTF::move(protectedSelf), connection = WTF::move(connection), callback](ResourceRequest&& request) {
            // AQUAWEBKIT: the curl transport owns HTTP; leaving this connection detaches its delegate. A
            // late answer finds that the callback gave CFNetwork nil: an approved request continues on a new
            // connection, and a nil answer lets the connection deliver the redirect response.
            protectedSelf->m_waitingForCompletion = false;
            RefPtr handle = protectedSelf->m_handle.get();
            if (handle && !request.isNull() && request.url().protocolIsInHTTPFamily()) {
                callback->setAnswered();
                handle->continueRedirectOnCocoaCurl(WTF::move(request), RefPtr { protectedSelf->m_messageQueue });
                return;
            }
            if (callback->isLate()) {
                if (handle && !request.isNull())
                    handle->continueRedirectOnNewConnection(WTF::move(request));
                else
                    [protectedSelf continueAfterCompletion:connection.get()];
                return;
            }
            callback->setAnswered();
            protectedSelf->m_requestResult = request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody);
            // protectedSelf->m_semaphore.signal(); // AQUAWEBKIT: only a blocked callback waits.
            if (!callback->runsInPlace())
                protectedSelf->m_semaphore.signal();
        });
    };

    [self callFunctionOnMainThread:WTF::move(work)];
    // AQUAWEBKIT: see ConnectionCallback.
    // m_semaphore.wait();
    if (callback->runsInPlace()) {
        callback->setReturned();
        if (!callback->wasAnswered()) {
            [self deferConnectionForCompletion:connection];
            return nil;
        }
    } else
        m_semaphore.wait();

    Locker locker { m_lock };
    if (!m_handle)
        return nil;

    RetainPtr<NSURLRequest> requestResult = m_requestResult;

    // Make sure protectedSelf gets destroyed on the main thread in case this is the last strong reference to self
    // as we do not want to get destroyed on a non-main thread.
    [self callFunctionOnMainThread:[protectedSelf = WTF::move(protectedSelf)] { }];

    return requestResult.autorelease();
}

ALLOW_DEPRECATED_IMPLEMENTATIONS_BEGIN
- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
ALLOW_DEPRECATED_IMPLEMENTATIONS_END
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    LOG(Network, "Handle %p delegate connection:%p didReceiveAuthenticationChallenge:%p", m_handle.get(), connection, challenge);

    auto work = [protectedSelf = retainPtr(self), challenge = retainPtr(challenge)] mutable {
        if (!protectedSelf->m_handle) {
            [[challenge sender] cancelAuthenticationChallenge:challenge.get()];
            return;
        }
        // AQUAWEBKIT: connection:canAuthenticateAgainstProtectionSpace: answered YES before the client
        // could, and the client's answer arrived with the held work ahead of this challenge. A NO gets what
        // 10.9 CFNetwork does for a protection space its delegate declines: it continues without a credential.
        if (std::exchange(protectedSelf->m_protectionSpaceUnanswered, false) && !std::exchange(protectedSelf->m_lateProtectionSpaceAnswer, NO)) {
            [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge.get()];
            return;
        }
        protect(protectedSelf->m_handle.get())->didReceiveAuthenticationChallenge(core(challenge.get()));
    };

    [self callFunctionOnMainThread:WTF::move(work)];
}

ALLOW_DEPRECATED_IMPLEMENTATIONS_BEGIN
- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
ALLOW_DEPRECATED_IMPLEMENTATIONS_END
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    LOG(Network, "Handle %p delegate connection:%p canAuthenticateAgainstProtectionSpace:%@://%@:%zd realm:%@ method:%@ %@%@", m_handle.get(), connection, [protectionSpace protocol], [protectionSpace host], [protectionSpace port], [protectionSpace realm], [protectionSpace authenticationMethod], [protectionSpace isProxy] ? @"proxy:" : @"", [protectionSpace isProxy] ? [protectionSpace proxyType] : @"");

    auto protectedSelf = retainPtr(self);
    // AQUAWEBKIT: see ConnectionCallback.
    // auto work = [protectedSelf, protectionSpace = retainPtr(protectionSpace)] mutable {
    Ref callback = ConnectionCallback::create(m_callbacksOnMainThread && isMainThread());
    auto work = [protectedSelf, protectionSpace = retainPtr(protectionSpace), callback] mutable {
        if (!protectedSelf->m_handle) {
            protectedSelf->m_boolResult = NO;
            // protectedSelf->m_semaphore.signal(); // AQUAWEBKIT: only a blocked callback waits.
            if (!callback->runsInPlace())
                protectedSelf->m_semaphore.signal();
            callback->setAnswered(); // AQUAWEBKIT: see ConnectionCallback.
            return;
        }
        // AQUAWEBKIT: see ConnectionCallback; the challenge takes a late answer.
        // protect(protectedSelf->m_handle.get())->canAuthenticateAgainstProtectionSpace(ProtectionSpace(protectionSpace.get()), [protectedSelf = WTF::move(protectedSelf)](bool result) mutable {
        //     protectedSelf->m_boolResult = result;
        //     protectedSelf->m_semaphore.signal();
        // });
        protect(protectedSelf->m_handle.get())->canAuthenticateAgainstProtectionSpace(ProtectionSpace(protectionSpace.get()), [protectedSelf = WTF::move(protectedSelf), callback](bool result) mutable {
            if (callback->isLate()) {
                protectedSelf->m_lateProtectionSpaceAnswer = result;
                return;
            }
            callback->setAnswered();
            protectedSelf->m_boolResult = result;
            if (!callback->runsInPlace()) // AQUAWEBKIT: only a blocked callback waits.
                protectedSelf->m_semaphore.signal();
        });
    };

    [self callFunctionOnMainThread:WTF::move(work)];
    // AQUAWEBKIT: see ConnectionCallback; held work answers YES and leaves the client's answer to the challenge.
    // m_semaphore.wait();
    if (callback->runsInPlace()) {
        callback->setReturned();
        if (!callback->wasAnswered()) {
            m_protectionSpaceUnanswered = true;
            return YES;
        }
    } else
        m_semaphore.wait();

    Locker locker { m_lock };
    if (!m_handle)
        return NO;

    auto boolResult = m_boolResult;

    // Make sure protectedSelf gets destroyed on the main thread in case this is the last strong reference to self
    // as we do not want to get destroyed on a non-main thread.
    [self callFunctionOnMainThread:[protectedSelf = WTF::move(protectedSelf)] { }];

    return boolResult;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)r
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.

    LOG(Network, "Handle %p delegate connection:%p didReceiveResponse:%p (HTTP status %zd, reported MIMEType '%s')", m_handle.get(), connection, r, [r respondsToSelector:@selector(statusCode)] ? [(id)r statusCode] : 0, [[r MIMEType] UTF8String]);

    auto protectedSelf = retainPtr(self);
    // AQUAWEBKIT: see ConnectionCallback.
    // auto work = [protectedSelf, r = retainPtr(r), connection = retainPtr(connection)] mutable {
    Ref callback = ConnectionCallback::create(m_callbacksOnMainThread && isMainThread());
    auto work = [protectedSelf, r = retainPtr(r), connection = retainPtr(connection), callback] mutable {
        RefPtr handle = protectedSelf->m_handle.get();
        if (!handle || !handle->client()) {
            // protectedSelf->m_semaphore.signal(); // AQUAWEBKIT: only a blocked callback waits.
            if (!callback->runsInPlace())
                protectedSelf->m_semaphore.signal();
            return;
        }

        // Avoid MIME type sniffing if the response comes back as 304 Not Modified.
        int statusCode = [r respondsToSelector:@selector(statusCode)] ? [(id)r statusCode] : 0;
        if (statusCode != 304) {
            bool isMainResourceLoad = handle->firstRequest().requester() == ResourceRequestRequester::Main;
            adjustMIMETypeIfNecessary([r _CFURLResponse], isMainResourceLoad ? IsMainResourceLoad::Yes : IsMainResourceLoad::No, IsNoSniffSet::No);
        }

        if ([protect(handle->firstRequest().nsURLRequest(HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody)) _propertyForKey:@"ForceHTMLMIMEType"])
            [r _setMIMEType:@"text/html"];

        ResourceResponse resourceResponse(r.get());
        handle->checkTAO(resourceResponse);

        auto metrics = copyTimingData(connection.get(), *handle);
        resourceResponse.setSource(ResourceResponse::Source::Network);
        resourceResponse.setDeprecatedNetworkLoadMetrics(Box<NetworkLoadMetrics> { metrics });

        handle->setNetworkLoadMetrics(WTF::move(metrics));

        protectedSelf->m_waitingForCompletion = true; // AQUAWEBKIT: see callFunctionOnMainThread:.
        // AQUAWEBKIT: a callback that ran in place continues the connection when the completion
        // handler runs; see ConnectionCallback and -isDeliveringResponse.
        // handle->didReceiveResponse(WTF::move(resourceResponse), [protectedSelf = WTF::move(protectedSelf)] {
        //     protectedSelf->m_semaphore.signal();
        // });
        SetForScope delivering { protectedSelf->m_deliveringResponse, callback->runsInPlace() && !callback->isLate() };
        handle->didReceiveResponse(WTF::move(resourceResponse), [protectedSelf, connection, callback] {
            if (callback->runsInPlace()) {
                [protectedSelf continueAfterCompletion:connection.get()];
                return;
            }
            protectedSelf->m_waitingForCompletion = false;
            protectedSelf->m_semaphore.signal();
        });
        if (callback->runsInPlace())
            [protectedSelf deferConnectionForCompletion:connection.get()];
    }; // AQUAWEBKIT: closes the response work above.

    [self callFunctionOnMainThread:WTF::move(work)];
    // AQUAWEBKIT: see ConnectionCallback.
    // m_semaphore.wait();
    if (callback->runsInPlace())
        callback->setReturned();
    else
        m_semaphore.wait();

    // Make sure we get destroyed on the main thread.
    [self callFunctionOnMainThread:[protectedSelf = WTF::move(protectedSelf)] { }];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data lengthReceived:(long long)lengthReceived
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);
    UNUSED_PARAM(lengthReceived);

    LOG(Network, "Handle %p delegate connection:%p didReceiveData:%p lengthReceived:%lld", m_handle.get(), connection, data, lengthReceived);

    auto work = [protectedSelf = retainPtr(self), data = retainPtr(data)] mutable {
        if (!protectedSelf->m_handle || !protectedSelf->m_handle->client())
            return;
        // FIXME: If we get more than 2B bytes in a single chunk, this code won't do the right thing.
        // However, with today's computers and networking speeds, this won't happen in practice.
        // Could be an issue with a giant local file.

        // FIXME: https://bugs.webkit.org/show_bug.cgi?id=19793
        // -1 means we do not provide any data about transfer size to inspector so it would use
        // Content-Length headers or content size to show transfer size.
        protectedSelf->m_handle->client()->didReceiveData(protect(protectedSelf->m_handle.get()), SharedBuffer::create(data.get()), -1);
    };

    [self callFunctionOnMainThread:WTF::move(work)];
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);
    UNUSED_PARAM(bytesWritten);

    LOG(Network, "Handle %p delegate connection:%p didSendBodyData:%zd totalBytesWritten:%zd totalBytesExpectedToWrite:%zd", m_handle.get(), connection, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);

    auto work = [protectedSelf = retainPtr(self), totalBytesWritten = totalBytesWritten, totalBytesExpectedToWrite = totalBytesExpectedToWrite] mutable {
        if (!protectedSelf->m_handle || !protectedSelf->m_handle->client())
            return;
        protectedSelf->m_handle->client()->didSendData(protect(protectedSelf->m_handle.get()), totalBytesWritten, totalBytesExpectedToWrite);
    };

    [self callFunctionOnMainThread:WTF::move(work)];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    LOG(Network, "Handle %p delegate connectionDidFinishLoading:%p", m_handle.get(), connection);

    auto work = [protectedSelf = retainPtr(self), connection = retainPtr(connection), timingData = retainPtr([connection _timingData])] mutable {
        if (!protectedSelf->m_handle || !protectedSelf->m_handle->client())
            return;

        if (auto metrics = protectedSelf->m_handle->networkLoadMetrics()) {
            if (double responseEndTime = [[timingData objectForKey:@"_kCFNTimingDataResponseEnd"] doubleValue])
                metrics->responseEnd = WallTime::fromRawSeconds(adoptNS([[NSDate alloc] initWithTimeIntervalSinceReferenceDate:responseEndTime]).get().timeIntervalSince1970).approximate<MonotonicTime>();
            else
                metrics->responseEnd = metrics->responseStart;
            metrics->protocol = checked_objc_cast<NSString>([timingData objectForKey:@"_kCFNTimingDataNetworkProtocolName"]);
            metrics->responseBodyBytesReceived = [[timingData objectForKey:@"_kCFNTimingDataResponseBodyBytesReceived"] unsignedLongLongValue];
            metrics->responseBodyDecodedSize = [[timingData objectForKey:@"_kCFNTimingDataResponseBodyBytesDecoded"] unsignedLongLongValue];
            metrics->markComplete();
            protectedSelf->m_handle->client()->didFinishLoading(protect(protectedSelf->m_handle.get()), *metrics);
        } else {
            NetworkLoadMetrics emptyMetrics;
            emptyMetrics.markComplete();
            protectedSelf->m_handle->client()->didFinishLoading(protect(protectedSelf->m_handle.get()), emptyMetrics);
        }

        if (protectedSelf->m_messageQueue) {
            protect(protectedSelf->m_messageQueue)->kill();
            protectedSelf->m_messageQueue = nullptr;
        }
    };

    [self callFunctionOnMainThread:WTF::move(work)];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    LOG(Network, "Handle %p delegate connection:%p didFailWithError:%@", m_handle.get(), connection, error);

    auto work = [protectedSelf = retainPtr(self), error = retainPtr(error)] mutable {
        if (!protectedSelf->m_handle || !protectedSelf->m_handle->client())
            return;

        protectedSelf->m_handle->client()->didFail(protect(protectedSelf->m_handle.get()), error.get());
        if (protectedSelf->m_messageQueue) {
            protect(protectedSelf->m_messageQueue)->kill();
            protectedSelf->m_messageQueue = nullptr;
        }
    };

    [self callFunctionOnMainThread:WTF::move(work)];
}


- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);

    LOG(Network, "Handle %p delegate connection:%p willCacheResponse:%p", m_handle.get(), connection, cachedResponse);

    auto protectedSelf = retainPtr(self);
    // AQUAWEBKIT: see ConnectionCallback.
    // auto work = [protectedSelf, cachedResponse = retainPtr(cachedResponse)] mutable {
    Ref callback = ConnectionCallback::create(m_callbacksOnMainThread && isMainThread());
    auto work = [protectedSelf, cachedResponse = retainPtr(cachedResponse), callback] mutable {
        if (!protectedSelf->m_handle || !protectedSelf->m_handle->client()) {
            protectedSelf->m_cachedResponseResult = nullptr;
            // protectedSelf->m_semaphore.signal(); // AQUAWEBKIT: only a blocked callback waits.
            if (!callback->runsInPlace())
                protectedSelf->m_semaphore.signal();
            callback->setAnswered(); // AQUAWEBKIT: see ConnectionCallback.
            return;
        }

        // AQUAWEBKIT: see ConnectionCallback.
        // protectedSelf->m_handle->client()->willCacheResponseAsync(protect(protectedSelf->m_handle.get()), cachedResponse.get(), [protectedSelf = WTF::move(protectedSelf)](NSCachedURLResponse * response) mutable {
        //     protectedSelf->m_cachedResponseResult = response;
        //     protectedSelf->m_semaphore.signal();
        // });
        protectedSelf->m_handle->client()->willCacheResponseAsync(protect(protectedSelf->m_handle.get()), cachedResponse.get(), [protectedSelf = WTF::move(protectedSelf), callback](NSCachedURLResponse * response) mutable {
            if (callback->isLate())
                return;
            callback->setAnswered();
            protectedSelf->m_cachedResponseResult = response;
            if (!callback->runsInPlace()) // AQUAWEBKIT: only a blocked callback waits.
                protectedSelf->m_semaphore.signal();
        });
    };

    [self callFunctionOnMainThread:WTF::move(work)];
    // AQUAWEBKIT: see ConnectionCallback. Held work answers nil: 10.9's NSURLCache stores HTTP
    // responses only, and HTTP loads run on curl, so no response reaching this connection is ever stored.
    // m_semaphore.wait();
    if (callback->runsInPlace()) {
        callback->setReturned();
        if (!callback->wasAnswered())
            return nil;
    } else
        m_semaphore.wait();

    Locker locker { m_lock };
    if (!m_handle)
        return nil;

    RetainPtr<NSCachedURLResponse> cachedResponseResult = m_cachedResponseResult;

    // Make sure protectedSelf gets destroyed on the main thread in case this is the last strong reference to self
    // as we do not want to get destroyed on a non-main thread.
    [self callFunctionOnMainThread:[protectedSelf = WTF::move(protectedSelf)] { }];

    return cachedResponseResult.autorelease();
}

@end

@implementation WebCoreResourceHandleWithCredentialStorageAsOperationQueueDelegate

- (BOOL)connectionShouldUseCredentialStorage:(NSURLConnection *)connection
{
    // ASSERT(!isMainThread()); // AQUAWEBKIT: a connection on the main run loop calls back on the main thread.
    UNUSED_PARAM(connection);
    return NO;
}

@end
