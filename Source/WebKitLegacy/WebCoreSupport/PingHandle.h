/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/LegacyLoadInterceptor.h> // AQUAWEBKIT: Safari 7 extensions' webRequest, below.
#include <WebCore/NetworkingContext.h> // AQUAWEBKIT: as above.
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/ResourceLoaderOptions.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/Timer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMallocInlines.h>

// This class triggers asynchronous loads independent of the networking context staying alive (i.e., auditing pingbacks).
// The object just needs to live long enough to ensure the message was actually sent.
// As soon as any callback is received from the ResourceHandle, this class will cancel the load and delete itself.

class PingHandle final : public RefCountedAndCanMakeWeakPtr<PingHandle>, private WebCore::ResourceHandleClient {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(PingHandle);
    WTF_MAKE_NONCOPYABLE(PingHandle);
public:
    // static void start(WebCore::NetworkingContext* networkingContext, const WebCore::ResourceRequest& request, bool shouldUseCredentialStorage, bool shouldFollowRedirects, CompletionHandler<void(const WebCore::ResourceError&, const WebCore::ResourceResponse&)>&& completionHandler) // AQUAWEBKIT: webRequest, below.
    static void start(WebCore::NetworkingContext* networkingContext, const WebCore::ResourceRequest& request, bool shouldUseCredentialStorage, bool shouldFollowRedirects, CompletionHandler<void(const WebCore::ResourceError&, const WebCore::ResourceResponse&)>&& completionHandler, RefPtr<WebCore::LegacyLoadInterceptor::Load>&& webRequest = nullptr)
    {
        Ref handle = adoptRef(*new PingHandle(request, shouldUseCredentialStorage, shouldFollowRedirects));
        handle->m_webRequest = WTF::move(webRequest); // AQUAWEBKIT: Safari 7 extensions' webRequest for the ping.
        handle->start(networkingContext, [handle, completionHandler = WTF::move(completionHandler)](const WebCore::ResourceError& error, const WebCore::ResourceResponse& response) mutable {
            completionHandler(error, response);
        });
    }

    virtual ~PingHandle()
    {
        ASSERT(!m_completionHandler);
        if (m_handle) {
            ASSERT(m_handle->client() == this);
            m_handle->clearClient();
            m_handle->cancel();
        }
    }

private:
    PingHandle(const WebCore::ResourceRequest& request, bool shouldUseCredentialStorage, bool shouldFollowRedirects)
        : m_currentRequest(request)
        , m_timeoutTimer(*this, &PingHandle::timeoutTimerFired)
        , m_shouldUseCredentialStorage(shouldUseCredentialStorage)
        , m_shouldFollowRedirects(shouldFollowRedirects)
    {
    }

    void start(WebCore::NetworkingContext* networkingContext, CompletionHandler<void(const WebCore::ResourceError&, const WebCore::ResourceResponse&)>&& completionHandler)
    {
        m_completionHandler = WTF::move(completionHandler);
        // AQUAWEBKIT: Safari 7 extensions' webRequest decides the request before createHandle sends it.
        if (RefPtr webRequest = m_webRequest) {
            webRequest->willSendRequest(WebCore::ResourceRequest { m_currentRequest }, { }, [this, protectedThis = Ref { *this }, networkingContext = RefPtr { networkingContext }](WebCore::ResourceRequest&& request, WebCore::ResourceError&& error) {
                if (!m_completionHandler)
                    return;
                if (request.isNull())
                    return pingLoadComplete(error);
                m_currentRequest = WTF::move(request);
                createHandle(networkingContext.get());
            });
            return;
        }
        createHandle(networkingContext);
    }

    void createHandle(WebCore::NetworkingContext* networkingContext)
    {
        // AQUAWEBKIT: closes the webRequest steps above; upstream's start() continues here.
        if (m_webRequest)
            m_networkingContext = networkingContext;
        bool defersLoading = false;
        bool shouldContentSniff = false;
        m_handle = WebCore::ResourceHandle::create(networkingContext, m_currentRequest, this, defersLoading, shouldContentSniff, WebCore::ContentEncodingSniffingPolicy::Default, nullptr, false);

        // If the server never responds, this object will hang around forever.
        // Set a very generous timeout, just in case.
        m_timeoutTimer.startOneShot(60000_s);
        if (m_webRequest && m_handle) // AQUAWEBKIT: Safari 7 extensions' webRequest holds the response's cookies.
            m_webRequest->didCreateHandle(*m_handle);
    }

    // void willSendRequestAsync(WebCore::ResourceHandle*, WebCore::ResourceRequest&& request, WebCore::ResourceResponse&&, CompletionHandler<void(WebCore::ResourceRequest&&)>&& completionHandler) final // AQUAWEBKIT: webRequest, below.
    void willSendRequestAsync(WebCore::ResourceHandle*, WebCore::ResourceRequest&& request, WebCore::ResourceResponse&& redirectResponse, CompletionHandler<void(WebCore::ResourceRequest&&)>&& completionHandler) final
    {
        // AQUAWEBKIT: Safari 7 extensions' webRequest decides the redirect and the request it makes, or the
        // response of a redirect the ping does not follow.
        if (RefPtr webRequest = m_webRequest; webRequest && !m_shouldFollowRedirects) {
            m_currentRequest = WTF::move(request);
            webRequest->didReceiveRedirectResponse(WTF::move(redirectResponse), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](WebCore::ResourceError&& error) mutable {
                completionHandler({ });
                pingLoadComplete(!error.isNull() ? WTF::move(error) : WebCore::ResourceError { String(), 0, m_currentRequest.url(), "Not allowed to follow redirects"_s, WebCore::ResourceError::Type::AccessControl });
            });
            return;
        }
        if (RefPtr webRequest = m_webRequest) {
            webRequest->willSendRequest(WTF::move(request), WTF::move(redirectResponse), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](WebCore::ResourceRequest&& request, WebCore::ResourceError&& error) mutable {
                if (!m_completionHandler)
                    return completionHandler({ });
                if (request.isNull()) {
                    completionHandler({ });
                    return pingLoadComplete(error);
                }
                m_currentRequest = WTF::move(request);
                completionHandler(WebCore::ResourceRequest { m_currentRequest });
            });
            return;
        }
        m_currentRequest = WTF::move(request);
        if (m_shouldFollowRedirects) {
            completionHandler(WebCore::ResourceRequest { m_currentRequest });
            return;
        }
        completionHandler({ });
        pingLoadComplete(WebCore::ResourceError { String(), 0, m_currentRequest.url(), "Not allowed to follow redirects"_s, WebCore::ResourceError::Type::AccessControl });
    }
    void didReceiveResponseAsync(WebCore::ResourceHandle*, WebCore::ResourceResponse&& response, CompletionHandler<void()>&& completionHandler) final
    {
        // AQUAWEBKIT: Safari 7 extensions' webRequest decides the response before the ping completes with it.
        if (RefPtr webRequest = m_webRequest) {
            webRequest->didReceiveResponse(WTF::move(response), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](WebCore::ResourceResponse&& response, WebCore::ResourceRequest&& redirectRequest, WebCore::ResourceError&& error) mutable {
                completionHandler();
                if (redirectRequest.isNull() || !m_completionHandler)
                    return pingLoadComplete(error, response);
                m_handle->clearClient();
                m_handle->cancel();
                m_handle = nullptr;
                m_currentRequest = WTF::move(redirectRequest);
                createHandle(RefPtr { m_networkingContext }.get());
            });
            return;
        }
        completionHandler();
        pingLoadComplete({ }, response);
    }
    void didReceiveData(WebCore::ResourceHandle*, const WebCore::SharedBuffer&, int) final { pingLoadComplete(); }
    void didFinishLoading(WebCore::ResourceHandle*, const WebCore::NetworkLoadMetrics&) final { pingLoadComplete(); }
    void didFail(WebCore::ResourceHandle*, const WebCore::ResourceError& error) final { pingLoadComplete(error); }
    bool shouldUseCredentialStorage(WebCore::ResourceHandle*) final { return m_shouldUseCredentialStorage; }
    void timeoutTimerFired() { pingLoadComplete(WebCore::ResourceError { String(), 0, m_currentRequest.url(), "Load timed out"_s, WebCore::ResourceError::Type::Timeout }); }
#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(WebCore::ResourceHandle*, const WebCore::ProtectionSpace&, CompletionHandler<void(bool)>&& completionHandler)
    {
        completionHandler(false);
        pingLoadComplete(WebCore::ResourceError { String { }, 0, m_currentRequest.url(), "Not allowed to authenticate"_s, WebCore::ResourceError::Type::AccessControl });
    }
#endif

    void pingLoadComplete(const WebCore::ResourceError& error = { }, const WebCore::ResourceResponse& response = { })
    {
        if (RefPtr webRequest = m_webRequest; webRequest && m_completionHandler) // AQUAWEBKIT: Safari 7 extensions' webRequest.onCompleted and onErrorOccurred.
            webRequest->didComplete(error, response);
        if (auto completionHandler = std::exchange(m_completionHandler, nullptr))
            completionHandler(error, response);
    }

    RefPtr<WebCore::ResourceHandle> m_handle;
    WebCore::ResourceRequest m_currentRequest;
    WebCore::Timer m_timeoutTimer;
    bool m_shouldUseCredentialStorage;
    bool m_shouldFollowRedirects;
    CompletionHandler<void(const WebCore::ResourceError&, const WebCore::ResourceResponse&)> m_completionHandler;
    RefPtr<WebCore::LegacyLoadInterceptor::Load> m_webRequest; // AQUAWEBKIT: Safari 7 extensions' webRequest for the ping.
    RefPtr<WebCore::NetworkingContext> m_networkingContext; // AQUAWEBKIT: the context a ping webRequest redirects starts its new load in.
};
