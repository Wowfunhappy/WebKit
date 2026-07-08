/*
 * Copyright (C) 2016-2025 Apple Inc. All rights reserved.
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
#import "NetworkDataTaskCocoa.h"

#import "AuthenticationChallengeDisposition.h"
#import "AuthenticationManager.h"
#import "DeviceManagementSPI.h"
#import "Download.h"
#import "DownloadProxyMessages.h"
#import "Logging.h"
#import "NetworkIssueReporter.h"
#import "NetworkProcess.h"
#import "NetworkSessionCocoa.h"
#import "WebPrivacyHelpers.h"
#import <WebCore/AdvancedPrivacyProtections.h>
#import <WebCore/AuthenticationChallenge.h>
#import <WebCore/HTTPStatusCodes.h>
#import <WebCore/NetworkStorageSession.h>
#import <WebCore/NotImplemented.h>
#import <WebCore/OriginAccessPatterns.h>
#import <WebCore/RegistrableDomain.h>
#import <WebCore/ResourceRequest.h>
#import <WebCore/TimingAllowOrigin.h>
#import <pal/spi/cf/CFNetworkSPI.h>
#import <pal/spi/cocoa/NetworkSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/FileSystem.h>
#import <wtf/MainThread.h>
#import <wtf/ProcessPrivilege.h>
#import <wtf/SystemTracing.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#import <wtf/text/Base64.h>

// MAVERICKS_BACKPORT: streaming brotli decoder for "br" response bodies (vendored static brotli;
// modern CFNetwork decodes br itself, 10.9 CFNetwork delivers the raw compressed bytes).
#import <brotli/decode.h>

#if HAVE(NW_ACTIVITY)
#import <pal/spi/cocoa/NSURLConnectionSPI.h>
#endif

namespace WebKit {

// MAVERICKS_BACKPORT: per-task streaming brotli decode state. Created in didReceiveResponse when
// the response declares Content-Encoding: br; didReceiveData then feeds each chunk through it.
struct NetworkDataTaskCocoa::BrotliStream {
    BrotliStream()
        : state(BrotliDecoderCreateInstance(nullptr, nullptr, nullptr))
    {
    }
    ~BrotliStream()
    {
        if (state)
            BrotliDecoderDestroyInstance(state);
    }
    BrotliDecoderState* state { nullptr };
    bool sawInput { false };
    bool failed { false };
};

// MAVERICKS_BACKPORT: NSURLSessionTask.taskIdentifier on 10.9 starts from 0, but the
// WTF::HashMap<uint64_t, ...> used as dataTaskMap treats key 0 as the empty-slot
// sentinel and key UINT64_MAX as the deleted sentinel. Shift by 1 so keys start
// at 1 (and UINT64_MAX - 1 -> UINT64_MAX never happens since NSURLSession does not
// produce that many tasks per session).
static inline uint64_t taskIdentifierKey(NSURLSessionTask *task)
{
    return static_cast<uint64_t>([task taskIdentifier]) + 1;
}

#if HAVE(SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS)

inline static bool shouldBlockTrackersForThirdPartyCloaking(NSURLRequest *request)
{
    RetainPtr<NSURL> requestURL = request.URL;
    RetainPtr<NSURL> mainDocumentURL = request.mainDocumentURL;
    if (!requestURL || !mainDocumentURL)
        return false;

    if (!WebCore::areRegistrableDomainsEqual(requestURL.get(), mainDocumentURL.get()))
        return false;

    if ([[requestURL host] isEqualToString:[mainDocumentURL host]])
        return false;

    return true;
}

#endif // HAVE(SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS)

void enableAdvancedPrivacyProtections(NSMutableURLRequest *request, OptionSet<WebCore::AdvancedPrivacyProtections> policy)
{
#if HAVE(SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS)
    // MAVERICKS_BACKPORT: _setUseEnhancedPrivacyMode: / _setBlockTrackers: are 10.15+ SPI.
    if (policy.contains(WebCore::AdvancedPrivacyProtections::EnhancedNetworkPrivacy)
        && [request respondsToSelector:@selector(_setUseEnhancedPrivacyMode:)])
        request._useEnhancedPrivacyMode = YES;

    // MAVERICKS_BACKPORT: _setBlockTrackers: is 10.15+ SPI; guard before calling.
    if (policy.contains(WebCore::AdvancedPrivacyProtections::BaselineProtections)
        && [request respondsToSelector:@selector(_setBlockTrackers:)]
        && shouldBlockTrackersForThirdPartyCloaking(request))
        request._blockTrackers = YES;
#else
    UNUSED_PARAM(request);
    UNUSED_PARAM(policy);
#endif
}

void setPCMDataCarriedOnRequest(WebCore::PrivateClickMeasurement::PcmDataCarried pcmDataCarried, NSMutableURLRequest *request)
{
#if ENABLE(TRACKER_DISPOSITION)
    // MAVERICKS_BACKPORT: _needsNetworkTrackingPrevention is 10.15+ SPI.
    if (![request respondsToSelector:@selector(_needsNetworkTrackingPrevention)]
        || ![request respondsToSelector:@selector(_setNeedsNetworkTrackingPrevention:)]) {
        UNUSED_PARAM(pcmDataCarried);
        return;
    }
    if (request._needsNetworkTrackingPrevention || pcmDataCarried == WebCore::PrivateClickMeasurement::PcmDataCarried::PersonallyIdentifiable)
        return;

    request._needsNetworkTrackingPrevention = YES;
#else
    UNUSED_PARAM(pcmDataCarried);
    UNUSED_PARAM(request);
#endif
}

static void applyBasicAuthorizationHeader(WebCore::ResourceRequest& request, const WebCore::Credential& credential)
{
    request.setHTTPHeaderField(WebCore::HTTPHeaderName::Authorization, credential.serializationForBasicAuthorizationHeader());
}

static float NODELETE toNSURLSessionTaskPriority(WebCore::ResourceLoadPriority priority)
{
    switch (priority) {
    case WebCore::ResourceLoadPriority::VeryLow:
        return 0;
    case WebCore::ResourceLoadPriority::Low:
        return 0.25;
    case WebCore::ResourceLoadPriority::Medium:
        return 0.5;
    case WebCore::ResourceLoadPriority::High:
        return 0.75;
    case WebCore::ResourceLoadPriority::VeryHigh:
        return 1;
    }

    ASSERT_NOT_REACHED();
    return NSURLSessionTaskPriorityDefault;
}

void NetworkDataTaskCocoa::applySniffingPoliciesAndBindRequestToInferfaceIfNeeded(RetainPtr<NSURLRequest>& nsRequest, bool shouldContentSniff, WebCore::ContentEncodingSniffingPolicy contentEncodingSniffingPolicy)
{
#if !USE(CFNETWORK_CONTENT_ENCODING_SNIFFING_OVERRIDE)
    UNUSED_PARAM(contentEncodingSniffingPolicy);
#endif

    CheckedRef cocoaSession = downcast<NetworkSessionCocoa>(*networkSession());
    auto& boundInterfaceIdentifier = cocoaSession->boundInterfaceIdentifier();
    if (shouldContentSniff
#if USE(CFNETWORK_CONTENT_ENCODING_SNIFFING_OVERRIDE)
        && contentEncodingSniffingPolicy == WebCore::ContentEncodingSniffingPolicy::Default 
#endif
        && boundInterfaceIdentifier.isNull())
        return;

    auto mutableRequest = adoptNS([nsRequest mutableCopy]);

#if USE(CFNETWORK_CONTENT_ENCODING_SNIFFING_OVERRIDE)
    if (contentEncodingSniffingPolicy == WebCore::ContentEncodingSniffingPolicy::Disable) {
        // FIXME: webkit.org/b/295204 This is a static analyzer false-positive due to the @YES/@NO constants.
        SUPPRESS_UNRETAINED_ARG [mutableRequest _setProperty:@YES forKey:bridge_cast(kCFURLRequestContentDecoderSkipURLCheck)];
    }
#endif

    if (!shouldContentSniff) {
        // FIXME: FIXME: webkit.org/b/295204 This is a static analyzer false-positive due to the @YES/@NO constants.
        SUPPRESS_UNRETAINED_ARG [mutableRequest _setProperty:@NO forKey:bridge_cast(_kCFURLConnectionPropertyShouldSniff)];
    }

    if (!boundInterfaceIdentifier.isNull())
        [mutableRequest setBoundInterfaceIdentifier:boundInterfaceIdentifier.createNSString().get()];

    nsRequest = WTF::move(mutableRequest);
}

void NetworkDataTaskCocoa::updateFirstPartyInfoForSession(const URL& requestURL)
{
    if (!shouldApplyCookiePolicyForThirdPartyCloaking() || requestURL.host().isEmpty())
        return;

    CheckedPtr session = networkSession();
    // MAVERICKS_BACKPORT: -_resolvedCNAMEChain is 10.13+ SPI.
    auto cnameDomain = [this]() {
        if (![m_task respondsToSelector:@selector(_resolvedCNAMEChain)])
            return WebCore::RegistrableDomain { };
        if (RetainPtr lastResolvedCNAMEInChain = [[m_task _resolvedCNAMEChain] lastObject])
            return lastCNAMEDomain(lastResolvedCNAMEInChain.get());
        return WebCore::RegistrableDomain { };
    }();
    if (!cnameDomain.isEmpty())
        session->setFirstPartyHostCNAMEDomain(requestURL.host().toString(), WTF::move(cnameDomain));

    if (RetainPtr ipAddress = lastRemoteIPAddress(m_task.get()); [ipAddress length])
        session->setFirstPartyHostIPAddress(requestURL.host().toString(), ipAddress.get());
}

NetworkDataTaskCocoa::NetworkDataTaskCocoa(NetworkSession& session, NetworkDataTaskClient& client, const NetworkLoadParameters& parameters)
    : NetworkDataTask(session, client, parameters.request, parameters.storedCredentialsPolicy, parameters.shouldClearReferrerOnHTTPSToHTTPRedirect, parameters.isMainFrameNavigation, parameters.isInitiatedByDedicatedWorker)
    , NetworkTaskCocoa(session)
    , m_sessionWrapper(downcast<NetworkSessionCocoa>(session).sessionWrapperForTask(parameters.webPageProxyID, parameters.request, parameters.storedCredentialsPolicy, parameters.isNavigatingToAppBoundDomain).get())
    , m_frameID(parameters.webFrameID)
    , m_pageID(parameters.webPageID)
    , m_webPageProxyID(parameters.webPageProxyID)
    , m_isForMainResourceNavigationForAnyFrame(!!parameters.mainResourceNavigationDataForAnyFrame)
    , m_sourceOrigin(parameters.sourceOrigin)
    , m_requiredCookiesVersion(parameters.requiredCookiesVersion)
{
    auto request = parameters.request;
    auto url = request.url();
    if (!url.isValid()) {
        scheduleFailure(FailureType::InvalidURL);
        return;
    }

    if (m_storedCredentialsPolicy == WebCore::StoredCredentialsPolicy::Use && url.protocolIsInHTTPFamily()) {
        m_user = url.user();
        m_password = url.password();
        request.removeCredentials();
        url = request.url();
    
        if (CheckedPtr storageSession = protect(NetworkDataTask::networkSession())->networkStorageSession()) {
            if (m_user.isEmpty() && m_password.isEmpty())
                m_initialCredential = storageSession->credentialStorage().get(m_partition, url);
            else
                storageSession->credentialStorage().set(m_partition, WebCore::Credential(m_user, m_password, WebCore::CredentialPersistence::None), url);
        }
    }

    if (!m_initialCredential.isEmpty() && !request.hasHTTPHeaderField(WebCore::HTTPHeaderName::Authorization)) {
        // FIXME: Support Digest authentication, and Proxy-Authorization.
        applyBasicAuthorizationHeader(request, m_initialCredential);
    }

    auto thirdPartyCookieBlockingDecision = requestThirdPartyCookieBlockingDecision(request);
    restrictRequestReferrerToOriginIfNeeded(request);

    RetainPtr<NSURLRequest> nsRequest = request.nsURLRequest(WebCore::HTTPBodyUpdatePolicy::UpdateHTTPBody);
    ASSERT(nsRequest);
    RetainPtr<NSMutableURLRequest> mutableRequest = adoptNS([nsRequest.get() mutableCopy]);

    // MAVERICKS_BACKPORT: _setPrivacyProxy* are 10.15+ SPI on NSMutableURLRequest.
    if ((parameters.isMainFrameNavigation
            || parameters.hadMainFrameMainResourcePrivateRelayed
            || request.url().host() == request.firstPartyForCookies().host())
        && [mutableRequest respondsToSelector:@selector(_setPrivacyProxyFailClosedForUnreachableNonMainHosts:)]) {
        [mutableRequest _setPrivacyProxyFailClosedForUnreachableNonMainHosts:YES];
    }

    // MAVERICKS_BACKPORT: _setProhibitPrivacyProxy: is 10.15+ SPI; guard before calling.
    if (!parameters.allowPrivacyProxy && [mutableRequest respondsToSelector:@selector(_setProhibitPrivacyProxy:)])
        [mutableRequest _setProhibitPrivacyProxy:YES];

    auto advancedPrivacyProtections = parameters.advancedPrivacyProtections;
#if ENABLE(ADVANCED_PRIVACY_PROTECTIONS)
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::BaselineProtections) && parameters.isMainFrameNavigation)
        configureForAdvancedPrivacyProtections(m_sessionWrapper->session.get());

    enableAdvancedPrivacyProtections(mutableRequest.get(), advancedPrivacyProtections);
#endif

#if HAVE(STRICT_FAIL_CLOSED)
    // MAVERICKS_BACKPORT: _setPrivacyProxyStrictFailClosed: is 10.15+ SPI.
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::StrictFailClosed)
        && [mutableRequest respondsToSelector:@selector(_setPrivacyProxyStrictFailClosed:)])
        [mutableRequest _setPrivacyProxyStrictFailClosed:YES];
#endif

    // MAVERICKS_BACKPORT: the _setPrivacyProxy* / _setWebSearchContent / _setAllowPrivateAccessTokensForThirdParty
    // SPIs are all 10.15+. Guard each call.
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::FailClosedForUnreachableHosts)
        && [mutableRequest respondsToSelector:@selector(_setPrivacyProxyFailClosedForUnreachableHosts:)])
        [mutableRequest _setPrivacyProxyFailClosedForUnreachableHosts:YES];

    // MAVERICKS_BACKPORT: _setPrivacyProxyFailClosed: is 10.15+ SPI; guard before calling.
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::FailClosedForAllHosts)
        && [mutableRequest respondsToSelector:@selector(_setPrivacyProxyFailClosed:)])
        [mutableRequest _setPrivacyProxyFailClosed:YES];

    // MAVERICKS_BACKPORT: _setWebSearchContent: is 10.15+ SPI; guard before calling.
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::WebSearchContent)
        && [mutableRequest respondsToSelector:@selector(_setWebSearchContent:)])
        [mutableRequest _setWebSearchContent:YES];

    // MAVERICKS_BACKPORT: _setAllowPrivateAccessTokensForThirdParty: is 10.15+ SPI; guard before calling.
    if (parameters.request.isPrivateTokenUsageByThirdPartyAllowed()
        && [mutableRequest respondsToSelector:@selector(_setAllowPrivateAccessTokensForThirdParty:)])
        [mutableRequest _setAllowPrivateAccessTokensForThirdParty:YES];

#if ENABLE(OPT_IN_PARTITIONED_COOKIES) && defined(CFN_COOKIE_ACCEPTS_POLICY_PARTITION) && CFN_COOKIE_ACCEPTS_POLICY_PARTITION
    if (isOptInCookiePartitioningEnabled() && [mutableRequest respondsToSelector:@selector(_setAllowOnlyPartitionedCookies:)]) {
        auto shouldAllowOnlyPartitioned = thirdPartyCookieBlockingDecision == WebCore::ThirdPartyCookieBlockingDecision::AllExceptPartitioned ? YES : NO;
        [mutableRequest _setAllowOnlyPartitionedCookies:shouldAllowOnlyPartitioned];
    }
#endif

#if ENABLE(APP_PRIVACY_REPORT)
    mutableRequest.get().attribution = request.isAppInitiated() ? NSURLRequestAttributionDeveloper : NSURLRequestAttributionUser;
#endif

    // FIXME: Remove hadMainFrameMainResourcePrivateRelayed, PrivateRelayed, and all the associated piping.
    
    nsRequest = mutableRequest;

#if ENABLE(APP_PRIVACY_REPORT)
    m_session->appPrivacyReportTestingData().didLoadAppInitiatedRequest(nsRequest.get().attribution == NSURLRequestAttributionDeveloper);
#endif

    applySniffingPoliciesAndBindRequestToInferfaceIfNeeded(nsRequest, parameters.contentSniffingPolicy == WebCore::ContentSniffingPolicy::SniffContent && !url.protocolIsFile(), parameters.contentEncodingSniffingPolicy);

    if (url.protocolIs("ws"_s) || url.protocolIs("wss"_s)) {
        // FIXME: Remove this once configuration._usesNWLoader is always effectively YES.
        // It will be no longer needed, as verified by the WebSocket.LoadRequestWSS API test.
        scheduleFailure(FailureType::RestrictedURL);
        return;
    }

    // MAVERICKS_BACKPORT: NSURLSession on Mavericks doesn't auto-inject Cookie headers
    // from configuration.HTTPCookieStorage even when cookies are stored. Without
    // Cookie headers, github's tree-commit-info / latest-commit / refs / etc
    // endpoints reject with HTTP 400. Manually inject cookies whenever the
    // request doesn't already carry a Cookie header — covers fetch() requests
    // whose storedCredentialsPolicy may not be Use even for same-origin endpoints.
    // Honor the loader's intent to suppress cookies: CrossOriginAccessControl
    // clears request.allowCookies() for CORS no-credentials requests and
    // preflights, and HTTPShouldHandleCookies==NO means the same. On 10.9 the
    // per-task suppression in blockCookies() is a no-op (it needs 10.10+/10.13+
    // SPI), so this gate is the only thing keeping us from attaching cookies the
    // loader meant to drop.
    if (parameters.storedCredentialsPolicy != WebCore::StoredCredentialsPolicy::DoNotUse
        && request.allowCookies()
        && [nsRequest HTTPShouldHandleCookies]) {
        NSString *existingCookie = [nsRequest valueForHTTPHeaderField:@"Cookie"];
        if (existingCookie.length == 0) {
            NSHTTPCookieStorage *cookieStorage = m_sessionWrapper->session.get().configuration.HTTPCookieStorage;
            NSArray *cookies = [cookieStorage cookiesForURL:[nsRequest URL]];
            if (cookies.count > 0) {
                NSDictionary *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
                NSString *cookieHeader = [cookieHeaders objectForKey:@"Cookie"];
                if (cookieHeader.length > 0) {
                    NSMutableURLRequest *mutableReq = [nsRequest mutableCopy];
                    [mutableReq setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
                    nsRequest = adoptNS(mutableReq);
                }
            }
        }
    }
    // MAVERICKS_BACKPORT: modern CFNetwork advertises "gzip, deflate, br" on every request and
    // decodes brotli transparently; 10.9 CFNetwork only advertises gzip/deflate. CDNs keep
    // separate cache variants per Accept-Encoding (Vary: Accept-Encoding), and a gzip-only
    // browser can be served a stale/broken variant modern browsers never see (bsky's video CDN
    // cached its gzip playlist variant without Access-Control-Allow-Origin, failing every HLS
    // CORS fetch). Match modern Safari: advertise br here and decode it in didReceiveData
    // (10.9 CFNetwork passes br bodies through raw; it still auto-decodes gzip/deflate even
    // with an explicit Accept-Encoding header — verified against this exact CDN). Skip
    // top-level navigations: those can convert to downloads, whose bodies CFNetwork writes to
    // disk without passing through didReceiveData, which would save raw brotli bytes.
    if (!isTopLevelNavigation() && ![nsRequest valueForHTTPHeaderField:@"Accept-Encoding"]) {
        NSMutableURLRequest *mutableReq = [nsRequest mutableCopy];
        [mutableReq setValue:@"gzip, deflate, br" forHTTPHeaderField:@"Accept-Encoding"];
        nsRequest = adoptNS(mutableReq);
    }
    m_task = [m_sessionWrapper->session dataTaskWithRequest:nsRequest.get()];

#if HAVE(CFNETWORK_HOSTOVERRIDE)
    // Avoid setting host override for WPT, since we are using a local DNS resolver then.
    StringView host = url.host();
    if (session.networkProcess().localhostAliasesForTesting().contains<StringViewHashTranslator>(host) && !host.endsWith("web-platform.test"_s))
        m_task.get()._hostOverride = adoptNS(nw_endpoint_create_host_with_numeric_port("localhost", url.port().value_or(0))).get();
#endif

#if ENABLE(OPT_IN_PARTITIONED_COOKIES) && defined(CFN_COOKIE_ACCEPTS_POLICY_PARTITION) && CFN_COOKIE_ACCEPTS_POLICY_PARTITION
    updateTaskWithStoragePartitionIdentifier(request);
#endif

    WTFBeginSignpost(m_task.get(), DataTask, "%" PUBLIC_LOG_STRING " %" PRIVATE_LOG_STRING " pri: %.2f preconnect: %d", request.httpMethod().utf8().data(), url.string().utf8().data(), toNSURLSessionTaskPriority(request.priority()), parameters.shouldPreconnectOnly == PreconnectOnly::Yes);

    switch (parameters.storedCredentialsPolicy) {
    case WebCore::StoredCredentialsPolicy::Use:
        ASSERT(m_sessionWrapper->session.get().configuration.URLCredentialStorage);
        break;
    case WebCore::StoredCredentialsPolicy::EphemeralStateless:
        ASSERT(!m_sessionWrapper->session.get().configuration.URLCredentialStorage);
        break;
    case WebCore::StoredCredentialsPolicy::DoNotUse:
        // MAVERICKS_BACKPORT: -[NSURLSessionDataTask _adoptEffectiveConfiguration:] is a 10.10+
        // SPI. On 10.9 it raises NSInvalidArgumentException and tears down NetworkProcess
        // (taking out subresource loads — every CDN asset request fails, which is what
        // makes pages like github render blank). Skip the per-task config override; we
        // lose per-request URLCredentialStorage=nil isolation, which is acceptable.
        if ([m_task respondsToSelector:@selector(_adoptEffectiveConfiguration:)]) {
            RetainPtr<NSURLSessionConfiguration> effectiveConfiguration = m_sessionWrapper->session.get().configuration;
            effectiveConfiguration.get().URLCredentialStorage = nil;
            [m_task _adoptEffectiveConfiguration:effectiveConfiguration.get()];
        }
        break;
    };

    // MAVERICKS_BACKPORT: taskIdentifierKey() shifts the 0-based 10.9 taskIdentifier off the HashMap empty-key sentinel.
    RELEASE_ASSERT(!m_sessionWrapper->dataTaskMap.contains(taskIdentifierKey(m_task.get())));
    m_sessionWrapper->dataTaskMap.add(taskIdentifierKey(m_task.get()), this);
    LOG(NetworkSession, "%lu Creating NetworkDataTask with URL %s", (unsigned long)[m_task taskIdentifier], [nsRequest URL].absoluteString.UTF8String);

    if (parameters.shouldPreconnectOnly == PreconnectOnly::Yes) {
#if ENABLE(SERVER_PRECONNECT)
        // MAVERICKS_BACKPORT: -_preconnect is 10.11+. Without it, the task simply
        // executes as a regular request — acceptable since preconnect is just
        // an optimization.
        if ([m_task respondsToSelector:@selector(set_preconnect:)])
            m_task.get()._preconnect = true;
#else
        ASSERT_NOT_REACHED();
#endif
    }

    setCookieTransform(request, IsRedirect::No);
    if (WebCore::NetworkStorageSession::shouldBlockCookies(thirdPartyCookieBlockingDecision)) {
#if !RELEASE_LOG_DISABLED
        if (protect(NetworkDataTask::networkSession())->shouldLogCookieInformation())
            RELEASE_LOG_IF(isAlwaysOnLoggingAllowed(), Network, "%p - NetworkDataTaskCocoa::logCookieInformation: pageID=%" PRIu64 ", frameID=%" PRIu64 ", taskID=%lu: Blocking cookies for URL %s", this, pageID() ? pageID()->toUInt64() : 0, frameID() ? frameID()->toUInt64() : 0, (unsigned long)[m_task taskIdentifier], [nsRequest URL].absoluteString.UTF8String);
#else
        LOG(NetworkSession, "%lu Blocking cookies for URL %s", (unsigned long)[m_task taskIdentifier], [nsRequest URL].absoluteString.UTF8String);
#endif
        blockCookies();
    }

    // MAVERICKS_BACKPORT: NSURLSessionTask.priority property is 10.10+; set it via KVC and guard the selector.
    if (WebCore::ResourceRequest::resourcePrioritiesEnabled())
        if ([m_task.get() respondsToSelector:@selector(setPriority:)])
            [m_task.get() setValue:@(toNSURLSessionTaskPriority(request.priority())) forKey:@"priority"];

    updateTaskWithFirstPartyForSameSiteCookies(m_task.get(), request);

#if HAVE(NW_ACTIVITY)
    if (parameters.networkActivityTracker)
        m_task.get()._nw_activity = parameters.networkActivityTracker->getPlatformObject();
#endif
}

NetworkDataTaskCocoa::~NetworkDataTaskCocoa()
{
    if (m_task)
        WTFEndSignpost(m_task.get(), DataTask);

    if (m_task && m_sessionWrapper) {
        auto& map = m_sessionWrapper->dataTaskMap;
        // MAVERICKS_BACKPORT: taskIdentifierKey() shifts the 0-based 10.9 taskIdentifier off the HashMap empty-key sentinel.
        auto iterator = map.find(taskIdentifierKey(m_task.get()));
        RELEASE_ASSERT(iterator != map.end());
        ASSERT(!iterator->value.get());
        map.remove(iterator);
    }
}

void NetworkDataTaskCocoa::didSendData(uint64_t totalBytesSent, uint64_t totalBytesExpectedToSend)
{
    WTFEmitSignpost(m_task.get(), DataTask, "sent %llu bytes (expected %llu bytes)", totalBytesSent, totalBytesExpectedToSend);

    if (RefPtr client = m_client.get())
        client->didSendData(totalBytesSent, totalBytesExpectedToSend);
}

void NetworkDataTaskCocoa::didReceiveChallenge(WebCore::AuthenticationChallenge&& challenge, NegotiatedLegacyTLS negotiatedLegacyTLS, ChallengeCompletionHandler&& completionHandler)
{
    WTFEmitSignpost(m_task.get(), DataTask, "received challenge");

    if (tryPasswordBasedAuthentication(challenge, completionHandler))
        return;

    if (RefPtr client = m_client.get())
        client->didReceiveChallenge(WTF::move(challenge), negotiatedLegacyTLS, WTF::move(completionHandler));
    else {
        ASSERT_NOT_REACHED();
        completionHandler(AuthenticationChallengeDisposition::PerformDefaultHandling, { });
    }
}

void NetworkDataTaskCocoa::didNegotiateModernTLS(const URL& url)
{
    if (RefPtr client = m_client.get())
        client->didNegotiateModernTLS(url);
}

void NetworkDataTaskCocoa::didCompleteWithError(const WebCore::ResourceError& error, const WebCore::NetworkLoadMetrics& networkLoadMetrics)
{
    WTFEmitSignpost(m_task.get(), DataTask, "completed with error: %d", !error.isNull());

    // MAVERICKS_BACKPORT: a br body that errored mid-decode (we cancel the task on decode error,
    // so the platform error here is "cancelled") or ended before the brotli stream completed
    // must fail the load (CFNetwork reports the same for truncated gzip). Without this, a
    // truncated/corrupt body would be delivered to the client as a successful load.
    if (m_brotliStream
        && (m_brotliStream->failed || (error.isNull() && m_brotliStream->sawInput && !BrotliDecoderIsFinished(m_brotliStream->state)))) {
        if (RefPtr client = m_client.get())
            client->didCompleteWithError(WebCore::ResourceError(String(NSURLErrorDomain), NSURLErrorCannotDecodeContentData, firstRequest().url(), "cannot decode brotli response body"_s), networkLoadMetrics);
        return;
    }

    if (RefPtr client = m_client.get())
        client->didCompleteWithError(error, networkLoadMetrics);
}

void NetworkDataTaskCocoa::didReceiveData(const WebCore::SharedBuffer& data)
{
    WTFEmitSignpost(m_task.get(), DataTask, "received %zd bytes", data.size());

    // MAVERICKS_BACKPORT: -_countOfBytesReceivedEncoded is 10.13+.
    if ([m_task respondsToSelector:@selector(_countOfBytesReceivedEncoded)])
        setBytesTransferredOverNetwork([m_task _countOfBytesReceivedEncoded]);
    else
        setBytesTransferredOverNetwork(data.size());

    // MAVERICKS_BACKPORT: decode br bodies (10.9 CFNetwork delivers the raw compressed bytes).
    if (m_brotliStream) {
        if (m_brotliStream->failed)
            return;
        m_brotliStream->sawInput = true;
        auto span = data.span();
        const uint8_t* nextIn = span.data();
        size_t availableIn = span.size();
        Vector<uint8_t> decoded;
        uint8_t outputChunk[16384];
        while (true) {
            size_t availableOut = sizeof(outputChunk);
            uint8_t* nextOut = outputChunk;
            BrotliDecoderResult result = BrotliDecoderDecompressStream(m_brotliStream->state, &availableIn, &nextIn, &availableOut, &nextOut, nullptr);
            if (size_t produced = sizeof(outputChunk) - availableOut)
                decoded.append(std::span<const uint8_t> { outputChunk, produced });
            if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT)
                continue;
            if (result == BROTLI_DECODER_RESULT_ERROR) {
                m_brotliStream->failed = true;
                [m_task cancel]; // stop the transfer; didCompleteWithError converts to a decode error
                return;
            }
            break; // SUCCESS or NEEDS_MORE_INPUT: this chunk is fully consumed
        }
        if (!decoded.isEmpty()) {
            Ref buffer = WebCore::SharedBuffer::create(WTF::move(decoded));
            if (RefPtr client = m_client.get())
                client->didReceiveData(buffer.get());
        }
        return;
    }

    if (RefPtr client = m_client.get())
        client->didReceiveData(data);
}

void NetworkDataTaskCocoa::didReceiveResponse(WebCore::ResourceResponse&& response, NegotiatedLegacyTLS negotiatedLegacyTLS, PrivateRelayed privateRelayed, WebKit::ResponseCompletionHandler&& completionHandler)
{
    WTFEmitSignpost(m_task.get(), DataTask, "received response headers");
    if (isTopLevelNavigation())
        updateFirstPartyInfoForSession(response.url());
#if ENABLE(NETWORK_ISSUE_REPORTING)
    // MAVERICKS_BACKPORT: -_incompleteTaskMetrics is 10.12+.
    else if ([m_task respondsToSelector:@selector(_incompleteTaskMetrics)]
        && NetworkIssueReporter::shouldReport(retainPtr([m_task _incompleteTaskMetrics]).get())) {
        if (CheckedPtr session = networkSession())
            session->reportNetworkIssue(*m_webPageProxyID, firstRequest().url());
    }
#endif

    // MAVERICKS_BACKPORT: NSURLSession on Mavericks doesn't auto-store Set-Cookie
    // from responses into configuration.HTTPCookieStorage, mirroring its
    // failure to inject Cookie headers on requests. Manually extract Set-Cookie
    // here so subsequent requests pick them up via the cookie injection path.
    {
        NSURLResponse *nsResponse = [m_task response];
        if ([nsResponse isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)nsResponse;
            NSHTTPCookieStorage *cookieStorage = m_sessionWrapper->session.get().configuration.HTTPCookieStorage;
            if (cookieStorage) {
                NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[httpResponse allHeaderFields] forURL:[httpResponse URL]];
                if (cookies.count > 0)
                    [cookieStorage setCookies:cookies forURL:[httpResponse URL] mainDocumentURL:nil];
            }
        }
    }
    // MAVERICKS_BACKPORT: 10.9 CFNetwork can't decode brotli — it delivers the raw br body with
    // the Content-Encoding header intact. Set up a streaming decoder; didReceiveData feeds it.
    // The header is left as-is, matching modern CFNetwork (which also decodes without stripping
    // Content-Encoding). Downloads bypass didReceiveData, but a br'd download body only happens
    // if the server compresses a file transfer — same truncated result stock 10.9 would produce.
    if (equalLettersIgnoringASCIICase(response.httpHeaderField(WebCore::HTTPHeaderName::ContentEncoding), "br"_s))
        m_brotliStream = std::unique_ptr<BrotliStream>(new BrotliStream);

    NetworkDataTask::didReceiveResponse(WTF::move(response), negotiatedLegacyTLS, privateRelayed, WebCore::IPAddress::fromString(lastRemoteIPAddress(m_task.get())), WTF::move(completionHandler));
}

void NetworkDataTaskCocoa::willPerformHTTPRedirection(WebCore::ResourceResponse&& redirectResponse, WebCore::ResourceRequest&& request, RedirectCompletionHandler&& completionHandler)
{
    WTFEmitSignpost(m_task.get(), DataTask, "redirect");

    networkLoadMetrics().hasCrossOriginRedirect = networkLoadMetrics().hasCrossOriginRedirect || !WebCore::SecurityOrigin::create(request.url())->canRequest(redirectResponse.url(), WebCore::EmptyOriginAccessPatterns::singleton());

    const auto& previousRequest = m_previousRequest.isNull() ? m_firstRequest : m_previousRequest;
    if (redirectResponse.httpStatusCode() == httpStatus307TemporaryRedirect || redirectResponse.httpStatusCode() == httpStatus308PermanentRedirect) {
        ASSERT(m_lastHTTPMethod == request.httpMethod());
        RefPtr body = previousRequest.httpBody();
        if (body && !body->isEmpty() && !equalLettersIgnoringASCIICase(m_lastHTTPMethod, "get"_s))
            request.setHTTPBody(WTF::move(body));
        
        String originalContentType = previousRequest.httpContentType();
        if (!originalContentType.isEmpty())
            request.setHTTPHeaderField(WebCore::HTTPHeaderName::ContentType, originalContentType);
    } else if (redirectResponse.httpStatusCode() == httpStatus303SeeOther) { // FIXME: (rdar://problem/13706454).
        if (equalLettersIgnoringASCIICase(previousRequest.httpMethod(), "head"_s))
            request.setHTTPMethod("HEAD"_s);

        String originalContentType = previousRequest.httpContentType();
        if (!originalContentType.isEmpty())
            request.setHTTPHeaderField(WebCore::HTTPHeaderName::ContentType, originalContentType);
    }
    
    // Should not set Referer after a redirect from a secure resource to non-secure one.
    if (m_shouldClearReferrerOnHTTPSToHTTPRedirect && !request.url().protocolIs("https"_s) && WTF::protocolIs(request.httpReferrer(), "https"_s))
        request.clearHTTPReferrer();
    
    const auto& url = request.url();
    m_user = url.user();
    m_password = url.password();
    m_lastHTTPMethod = request.httpMethod();
    request.removeCredentials();
    CheckedPtr session = m_session.get();

    if (!protocolHostAndPortAreEqual(request.url(), redirectResponse.url())) {
        // The network layer might carry over some headers from the original request that
        // we want to strip here because the redirect is cross-origin.
        request.clearHTTPAuthorization();
        request.clearHTTPOrigin();

    } else {
        // Only consider applying authentication credentials if this is actually a redirect and the redirect
        // URL didn't include credentials of its own.
        if (m_user.isEmpty() && m_password.isEmpty() && !redirectResponse.isNull()) {
            auto credential = session->networkStorageSession() ? session->networkStorageSession()->credentialStorage().get(m_partition, request.url()) : WebCore::Credential();
            if (!credential.isEmpty()) {
                m_initialCredential = credential;

                // FIXME: Support Digest authentication, and Proxy-Authorization.
                applyBasicAuthorizationHeader(request, m_initialCredential);
            }
        }
    }

    if (isTopLevelNavigation())
        request.setFirstPartyForCookies(request.url());
    else {
        WebCore::RegistrableDomain firstPartyDomain { request.firstPartyForCookies() };
        if (CheckedPtr storageSession = session->networkStorageSession()) {
            bool didPreviousRequestHaveStorageAccess = storageSession->hasStorageAccess(WebCore::RegistrableDomain { redirectResponse.url() }, firstPartyDomain, m_frameID, m_pageID);
            bool doesRequestHaveStorageAccess = storageSession->hasStorageAccess(WebCore::RegistrableDomain { request.url() }, firstPartyDomain, m_frameID, m_pageID);
            if (didPreviousRequestHaveStorageAccess && doesRequestHaveStorageAccess)
                request.setFirstPartyForCookies(request.url());
        }
    }

    NetworkTaskCocoa::willPerformHTTPRedirection(WTF::move(redirectResponse), WTF::move(request), [completionHandler = WTF::move(completionHandler), weakThis = ThreadSafeWeakPtr { *this }, redirectResponse] (WebCore::ResourceRequest&& request) mutable {
        auto protectedThis = weakThis.get();
        if (!protectedThis)
            return completionHandler({ });
        RefPtr client = protectedThis->m_client.get();
        if (!client)
            return completionHandler({ });
        client->willPerformHTTPRedirection(WTF::move(redirectResponse), WTF::move(request), [completionHandler = WTF::move(completionHandler), weakThis] (WebCore::ResourceRequest&& request) mutable {
            auto protectedThis = weakThis.get();
            if (!protectedThis || !protectedThis->m_session)
                return completionHandler({ });
            if (!request.isNull())
                protectedThis->restrictRequestReferrerToOriginIfNeeded(request);
            protectedThis->m_previousRequest = request;
            completionHandler(WTF::move(request));
        });
    });
}

void NetworkDataTaskCocoa::setPendingDownloadLocation(const WTF::String& filename, SandboxExtension::Handle&& sandboxExtensionHandle, bool allowOverwrite)
{
    NetworkDataTask::setPendingDownloadLocation(filename, { }, allowOverwrite);

    ASSERT(!m_sandboxExtension);
    m_sandboxExtension = SandboxExtension::create(WTF::move(sandboxExtensionHandle));
    if (RefPtr extention = m_sandboxExtension)
        extention->consume();

    m_task.get()._pathToDownloadTaskFile = m_pendingDownloadLocation.createNSString().get();

    if (allowOverwrite && FileSystem::fileExists(m_pendingDownloadLocation))
        FileSystem::deleteFile(filename);
}

bool NetworkDataTaskCocoa::tryPasswordBasedAuthentication(const WebCore::AuthenticationChallenge& challenge, ChallengeCompletionHandler& completionHandler)
{
    if (!challenge.protectionSpace().isPasswordBased())
        return false;
    
    if (!m_user.isEmpty() || !m_password.isEmpty()) {
        auto persistence = m_storedCredentialsPolicy == WebCore::StoredCredentialsPolicy::Use ? WebCore::CredentialPersistence::ForSession : WebCore::CredentialPersistence::None;
        completionHandler(AuthenticationChallengeDisposition::UseCredential, WebCore::Credential(m_user, m_password, persistence));
        m_user = String();
        m_password = String();
        return true;
    }

    CheckedPtr session = m_session.get();
    if (m_storedCredentialsPolicy == WebCore::StoredCredentialsPolicy::Use) {
        if (!m_initialCredential.isEmpty() || challenge.previousFailureCount()) {
            // The stored credential wasn't accepted, stop using it.
            // There is a race condition here, since a different credential might have already been stored by another ResourceHandle,
            // but the observable effect should be very minor, if any.
            if (CheckedPtr storageSession = session->networkStorageSession())
                storageSession->credentialStorage().remove(m_partition, challenge.protectionSpace());
        }

        if (!challenge.previousFailureCount()) {
            auto credential = session->networkStorageSession() ? session->networkStorageSession()->credentialStorage().get(m_partition, challenge.protectionSpace()) : WebCore::Credential();
            if (!credential.isEmpty() && credential != m_initialCredential) {
                ASSERT(credential.persistence() == WebCore::CredentialPersistence::None);
                if (challenge.failureResponse().httpStatusCode() == httpStatus401Unauthorized) {
                    // Store the credential back, possibly adding it as a default for this directory.
                    if (CheckedPtr storageSession = session->networkStorageSession())
                        storageSession->credentialStorage().set(m_partition, credential, challenge.protectionSpace(), challenge.failureResponse().url());
                }
                completionHandler(AuthenticationChallengeDisposition::UseCredential, credential);
                return true;
            }
        }
    }

    if (!challenge.proposedCredential().isEmpty() && !challenge.previousFailureCount()) {
        completionHandler(AuthenticationChallengeDisposition::UseCredential, challenge.proposedCredential());
        return true;
    }
    
    return false;
}

void NetworkDataTaskCocoa::transferSandboxExtensionToDownload(Download& download)
{
    download.setSandboxExtension(WTF::move(m_sandboxExtension));
}

String NetworkDataTaskCocoa::suggestedFilename() const
{
    if (!m_suggestedFilename.isEmpty())
        return m_suggestedFilename;
    return m_task.get().response.suggestedFilename;
}

void NetworkDataTaskCocoa::cancel()
{
    WTFEmitSignpost(m_task.get(), DataTask, "cancel");
    [m_task cancel];
}

void NetworkDataTaskCocoa::resume()
{
    WTFEmitSignpost(m_task.get(), DataTask, "resume");

    if (m_failureScheduled)
        return;

    if (!m_session || m_session->isInvalidated())
        return;

    {
        CheckedRef session = *m_session;
        CheckedPtr storageSession = session->networkStorageSession();
        if (storageSession && storageSession->cookiesVersion() < m_requiredCookiesVersion) {
            RELEASE_LOG(Loading, "%p - NetworkDataTaskCocoa::resume: task is delayed because cookies version (%" PRIu64 ") of session (%" PRIu64 ") is lower than required (%" PRIu64 ")", this, storageSession->cookiesVersion(), storageSession->sessionID().toUInt64(), m_requiredCookiesVersion);
            storageSession->addCookiesVersionChangeCallback({ m_requiredCookiesVersion, [weakThis = ThreadSafeWeakPtr { *this }](auto reason) {
                if (reason != WebCore::NetworkStorageSession::CookieVersionChangeCallback::Reason::VersionChange)
                    return;
                if (auto protectedThis = weakThis.get()) {
                    RELEASE_LOG(Loading, "%p - NetworkDataTaskCocoa::resume: task delayed by cookies version is started", protectedThis.get());
                    protectedThis->resume();
                }
            } });
            return;
        }
    }

    CheckedRef cocoaSession = downcast<NetworkSessionCocoa>(*m_session);
    if (cocoaSession->deviceManagementRestrictionsEnabled() && m_isForMainResourceNavigationForAnyFrame) {
        auto didDetermineDeviceRestrictionPolicyForURL = makeBlockPtr([protectedThis = Ref { *this }](BOOL isBlocked) mutable {
            callOnMainRunLoop([protectedThis = WTF::move(protectedThis), isBlocked] {
                if (isBlocked) {
                    protectedThis->scheduleFailure(FailureType::RestrictedURL);
                    return;
                }

                [protectedThis->m_task resume];
            });
        });

#if HAVE(DEVICE_MANAGEMENT)
        if (cocoaSession->allLoadsBlockedByDeviceManagementRestrictionsForTesting())
            didDetermineDeviceRestrictionPolicyForURL(true);
        else {
            RetainPtr<NSURL> urlToCheck = [m_task currentRequest].URL;
            [cocoaSession->deviceManagementPolicyMonitor() requestPoliciesForWebsites:@[urlToCheck.get()] completionHandler:makeBlockPtr([didDetermineDeviceRestrictionPolicyForURL, urlToCheck] (NSDictionary<NSURL *, NSNumber *> *policies, NSError *error) {
                bool isBlocked = error || policies[urlToCheck.get()].integerValue != DMFPolicyOK;
                didDetermineDeviceRestrictionPolicyForURL(isBlocked);
            }).get()];
        }
#else
        didDetermineDeviceRestrictionPolicyForURL(cocoaSession->allLoadsBlockedByDeviceManagementRestrictionsForTesting());
#endif
        return;
    }

    [m_task resume];
}

NetworkDataTask::State NetworkDataTaskCocoa::state() const
{
    switch ([m_task state]) {
    case NSURLSessionTaskStateRunning:
        return State::Running;
    case NSURLSessionTaskStateSuspended:
        return State::Suspended;
    case NSURLSessionTaskStateCanceling:
        return State::Canceling;
    case NSURLSessionTaskStateCompleted:
        return State::Completed;
    }

    ASSERT_NOT_REACHED();
    return State::Completed;
}

WebCore::Credential serverTrustCredential(const WebCore::AuthenticationChallenge& challenge)
{
    return WebCore::Credential([NSURLCredential credentialForTrust: RetainPtr { protect(challenge.nsURLAuthenticationChallenge()).get().protectionSpace.serverTrust }.get()]);
}

String NetworkDataTaskCocoa::description() const
{
    return String([m_task description]);
}

void NetworkDataTaskCocoa::setH2PingCallback(const URL& url, CompletionHandler<void(Expected<WTF::Seconds, WebCore::ResourceError>&&)>&& completionHandler)
{
    ASSERT(m_task.get()._preconnect);
    auto handler = CompletionHandlerWithFinalizer<void(Expected<WTF::Seconds, WebCore::ResourceError>&&)>(WTF::move(completionHandler), [url = url.isolatedCopy()] (Function<void(Expected<WTF::Seconds, WebCore::ResourceError>&&)>& completionHandler) mutable {
        ensureOnMainRunLoop([completionHandler = WTF::move(completionHandler), url = WTF::move(url).isolatedCopy()]() mutable {
            completionHandler(makeUnexpected(WebCore::internalError(url)));
        });
    }, CompletionHandlerCallThread::AnyThread);
    [m_task getUnderlyingHTTPConnectionInfoWithCompletionHandler:makeBlockPtr([completionHandler = WTF::move(handler), url = url.isolatedCopy()] (_NSHTTPConnectionInfo *connectionInfo) mutable {
        if (!connectionInfo.isValid)
            return completionHandler(makeUnexpected(WebCore::internalError(url)));
        [connectionInfo sendPingWithReceiveHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)](NSError *error, NSTimeInterval interval) mutable {
            completionHandler(Seconds(interval));
        }).get()];
    }).get()];
}

void NetworkDataTaskCocoa::setPriority(WebCore::ResourceLoadPriority priority)
{
    if (!WebCore::ResourceRequest::resourcePrioritiesEnabled())
        return;
    // MAVERICKS_BACKPORT: NSURLSessionTask.priority property is 10.10+; set it via KVC and guard the selector.
    if ([m_task.get() respondsToSelector:@selector(setPriority:)])
        [m_task.get() setValue:@(toNSURLSessionTaskPriority(priority)) forKey:@"priority"];
}

#if ENABLE(INSPECTOR_NETWORK_THROTTLING)

void NetworkDataTaskCocoa::setEmulatedConditions(const std::optional<int64_t>& bytesPerSecondLimit)
{
    m_task.get()._bytesPerSecondLimit = bytesPerSecondLimit.value_or(0);
}

#endif // ENABLE(INSPECTOR_NETWORK_THROTTLING)

void NetworkDataTaskCocoa::setTimingAllowFailedFlag()
{
    networkLoadMetrics().failsTAOCheck = true;
}

NSURLSessionTask* NetworkDataTaskCocoa::task() const
{
    return m_task.get();
}

}
