/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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

#include "config.h"
#include "InjectedBundlePageResourceLoadClient.h"

#include "WKAPICast.h"
#include "WKBundleAPICast.h"
#include "WebFrame.h"
#include "WebPage.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(InjectedBundlePageResourceLoadClient);

InjectedBundlePageResourceLoadClient::InjectedBundlePageResourceLoadClient(const WKBundlePageResourceLoadClientBase* client)
{
    initialize(client);
}

void InjectedBundlePageResourceLoadClient::didInitiateLoadForResource(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier, const ResourceRequest& request, bool pageIsProvisionallyLoading)
{
    if (!m_client.didInitiateLoadForResource)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): Safari's didInitiateLoadForResource handler WKRetains the
    // page/frame it is handed (-> WebPage::ref()/WebFrame::ref()). During github's heavy Turbo/SPA
    // resource churn the frame can be a transient/provisional one whose refcount has already dropped
    // to 0 when this fires; Safari (asserts-on) then traps in ref() (EXC_BREAKPOINT). Pin both across
    // the callback so they are guaranteed refcount >= 1 when Safari retains them. No-op in the common
    // case (object already live); only matters for the racing transient frame.
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    m_client.didInitiateLoadForResource(toAPI(&page), toAPI(&frame), identifier.toUInt64(), toAPI(request), pageIsProvisionallyLoading, m_client.base.clientInfo);
}

void InjectedBundlePageResourceLoadClient::willSendRequestForFrame(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier, ResourceRequest& request, const ResourceResponse& redirectResponse)
{
    if (!m_client.willSendRequestForFrame)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback — Safari's handler WKRetains them (same transient-frame ref() trap as didInitiateLoadForResource).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    RefPtr<API::URLRequest> returnedRequest = adoptRef(toImpl(m_client.willSendRequestForFrame(toAPI(&page), toAPI(&frame), identifier.toUInt64(), toAPI(request), toAPI(redirectResponse), m_client.base.clientInfo)));
    if (returnedRequest) {
        // If the client returned an HTTP body, we want to use that http body. This is needed to fix <rdar://problem/23763584>
        auto& returnedResourceRequest = returnedRequest->resourceRequest();
        RefPtr<FormData> returnedHTTPBody = returnedResourceRequest.httpBody();
        request.updateFromDelegatePreservingOldProperties(returnedResourceRequest);
        if (returnedHTTPBody)
            request.setHTTPBody(WTF::move(returnedHTTPBody));
    } else {
        // MAVERICKS_BACKPORT DIAGNOSTIC (sentinel-gated): the bundle client blocked this request.
        if (!access("/tmp/wk-debug-on", F_OK)) {
            fprintf(stderr, "[BUNDLE-WSR-NULL] url=%s\n", request.url().string().utf8().data());
            fflush(stderr);
        }
        request = { };
    }
}

void InjectedBundlePageResourceLoadClient::didReceiveResponseForResource(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier, const ResourceResponse& response)
{
    if (!m_client.didReceiveResponseForResource)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    m_client.didReceiveResponseForResource(toAPI(&page), toAPI(&frame), identifier.toUInt64(), toAPI(response), m_client.base.clientInfo);
}

void InjectedBundlePageResourceLoadClient::didReceiveContentLengthForResource(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier, uint64_t contentLength)
{
    if (!m_client.didReceiveContentLengthForResource)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    m_client.didReceiveContentLengthForResource(toAPI(&page), toAPI(&frame), identifier.toUInt64(), contentLength, m_client.base.clientInfo);
}

void InjectedBundlePageResourceLoadClient::didFinishLoadForResource(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier)
{
    if (!m_client.didFinishLoadForResource)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    m_client.didFinishLoadForResource(toAPI(&page), toAPI(&frame), identifier.toUInt64(), m_client.base.clientInfo);
}

void InjectedBundlePageResourceLoadClient::didFailLoadForResource(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier, const ResourceError& error)
{
    if (!m_client.didFailLoadForResource)
        return;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    m_client.didFailLoadForResource(toAPI(&page), toAPI(&frame), identifier.toUInt64(), toAPI(error), m_client.base.clientInfo);
}

bool InjectedBundlePageResourceLoadClient::shouldCacheResponse(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier)
{
    if (!m_client.shouldCacheResponse)
        return true;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    return m_client.shouldCacheResponse(toAPI(&page), toAPI(&frame), identifier.toUInt64(), m_client.base.clientInfo);
}

bool InjectedBundlePageResourceLoadClient::shouldUseCredentialStorage(WebPage& page, WebFrame& frame, WebCore::ResourceLoaderIdentifier identifier)
{
    if (!m_client.shouldUseCredentialStorage)
        return true;

    // MAVERICKS_BACKPORT (github SIGTRAP fix): pin page/frame across the callback (Safari WKRetains them; same transient-frame ref() trap).
    Ref protectedPage { page };
    Ref protectedFrame { frame };
    return m_client.shouldUseCredentialStorage(toAPI(&page), toAPI(&frame), identifier.toUInt64(), m_client.base.clientInfo);
}

} // namespace WebKit
