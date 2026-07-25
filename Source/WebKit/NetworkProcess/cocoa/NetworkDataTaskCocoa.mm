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
// MAVERICKS_BACKPORT: BlobData.h/FormData.h for the file-backed upload-body materialization below.
#import <WebCore/BlobData.h>
#import <WebCore/FormData.h>
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

// MAVERICKS_BACKPORT: system zlib for the "gzip" content-decoder (see GzipStream below); 10.9
// CFNetwork suppresses its transparent gzip decode for .gz/.tgz URLs and delivers the raw body.
#import <zlib.h>

#if HAVE(NW_ACTIVITY)
#import <pal/spi/cocoa/NSURLConnectionSPI.h>
#endif

namespace WebKit {

// MAVERICKS_BACKPORT: per-task streaming zlib decode state. CFNetwork transparently decodes
// Content-Encoding: gzip EXCEPT when the request URL's last path component ends in .gz/.tgz — its
// long-standing heuristic to avoid clobbering gzip-archive downloads that a misconfigured server
// double-gzips. For those URLs it delivers the still-compressed body with the Content-Encoding
// header intact (exactly the br situation above), so a fetch()/XHR of, say, a .tgz that a CDN
// gzip-encodes over the wire sees raw compressed bytes. Created in didReceiveResponse when that
// condition holds; didReceiveData feeds each chunk through inflate(). Downloads bypass
// didReceiveData, so real .gz/.tgz downloads still reach disk intact — matching CFNetwork's intent.
struct NetworkDataTaskCocoa::GzipStream {
    GzipStream()
    {
        stream.zalloc = Z_NULL;
        stream.zfree = Z_NULL;
        stream.opaque = Z_NULL;
        stream.next_in = Z_NULL;
        stream.avail_in = 0;
        // 15 window bits + 32 enables automatic gzip/zlib header detection.
        initialized = inflateInit2(&stream, 15 + 32) == Z_OK;
    }
    ~GzipStream()
    {
        if (initialized)
            inflateEnd(&stream);
    }
    z_stream stream;
    bool initialized { false };
    bool sawInput { false };
    // True while partway through a gzip member (fed bytes that have not yet reached Z_STREAM_END).
    // A body that ends here is truncated. Cleared at each member boundary; gzip permits multiple
    // concatenated members (RFC 1952), so this is NOT a terminal "done" flag.
    bool inMember { false };
    bool failed { false };
};

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
    if (policy.contains(WebCore::AdvancedPrivacyProtections::EnhancedNetworkPrivacy))
        request._useEnhancedPrivacyMode = YES;

    if (policy.contains(WebCore::AdvancedPrivacyProtections::BaselineProtections) && shouldBlockTrackersForThirdPartyCloaking(request))
        request._blockTrackers = YES;
#else
    UNUSED_PARAM(request);
    UNUSED_PARAM(policy);
#endif
}

void setPCMDataCarriedOnRequest(WebCore::PrivateClickMeasurement::PcmDataCarried pcmDataCarried, NSMutableURLRequest *request)
{
#if ENABLE(TRACKER_DISPOSITION)
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
    auto cnameDomain = [this]() {
        if (RetainPtr lastResolvedCNAMEInChain = [[m_task _resolvedCNAMEChain] lastObject])
            return lastCNAMEDomain(lastResolvedCNAMEInChain.get());
        return WebCore::RegistrableDomain { };
    }();
    if (!cnameDomain.isEmpty())
        session->setFirstPartyHostCNAMEDomain(requestURL.host().toString(), WTF::move(cnameDomain));

    if (RetainPtr ipAddress = lastRemoteIPAddress(m_task.get()); [ipAddress length])
        session->setFirstPartyHostIPAddress(requestURL.host().toString(), ipAddress.get());
}

// MAVERICKS_BACKPORT: 10.9 CFNetwork sends every NSInputStream-bodied NSURLSession task with
// Transfer-Encoding: chunked and DISCARDS an explicitly-set Content-Length header (verified
// empirically against both dataTaskWithRequest: and uploadTaskWithStreamedRequest: — the wire
// carries "Transfer-Encoding: Chunked" and no Content-Length). Bodies made only of in-memory
// bytes coalesce into a single data element and ship as an NSData HTTPBody with a correct
// Content-Length, so only bodies containing file-backed elements remain streams — and many
// endpoints (GitHub/S3 asset uploads) reject length-less chunked uploads, which broke every
// <input type=file> / drag-drop file upload. uploadTaskWithRequest:fromFile: is the one 10.9
// body form that both carries Content-Length and replays safely across redirects/auth retries,
// so file-backed bodies are materialized into a file for it: a body that is exactly one whole
// file uploads straight from the original file (no copy); mixed multipart bodies are written
// once to a temporary file (disk cost = upload size; still streams, no memory blowup), which
// the caller deletes when the task dies. Returns nil to keep the regular stream body (and its
// canonical failure semantics) when the body has no file elements, still has unresolved blob
// elements, a file flunks the File.lastModified staleness check, or temporary-file IO fails.
// Redirects: probed on 10.9 — an upload-from-file task re-sends the file body with a correct
// Content-Length on a 307 hop even when the redirect delegate's request carries a fresh
// HTTPBodyStream (WebKit's HTTPBodyUpdatePolicy::UpdateHTTPBody conversion does), so the
// willPerformHTTPRedirection path needs no special handling. Cost: the multipart copy runs
// synchronously at task creation on the NetworkProcess main thread; this VM copies 500MB in
// ~1.7s (~300MB/s), so typical uploads (a few MB) cost single-digit milliseconds — an accepted
// bound; only a multi-GB multipart upload would produce a user-visible stall.
static RetainPtr<NSURL> materializeFileBackedRequestBody(const WebCore::FormData& body, String& temporaryPathOut)
{
    bool hasFileElement = false;
    for (auto& element : body.elements()) {
        if (std::holds_alternative<WebCore::FormDataElement::EncodedFileData>(element.data))
            hasFileElement = true;
        else if (std::holds_alternative<WebCore::FormDataElement::EncodedBlobData>(element.data))
            return nil;
    }
    if (!hasFileElement)
        return nil;

    if (body.elements().size() == 1) {
        auto& fileData = std::get<WebCore::FormDataElement::EncodedFileData>(body.elements()[0].data);
        if (!fileData.fileStart && fileData.fileLength == WebCore::BlobDataItem::toEndOfFile && fileData.fileModificationTimeMatchesExpectation())
            return adoptNS([[NSURL alloc] initFileURLWithPath:fileData.filename.createNSString().get() isDirectory:NO]);
    }

    auto [temporaryPath, temporaryHandle] = FileSystem::openTemporaryFile("WebKitUploadBody"_s);
    if (!temporaryHandle)
        return nil;

    bool succeeded = true;
    for (auto& element : body.elements()) {
        succeeded = WTF::switchOn(element.data,
            [&](const Vector<uint8_t>& bytes) {
                return temporaryHandle.write(bytes.span()) == bytes.size();
            },
            [&](const WebCore::FormDataElement::EncodedFileData& fileData) {
                if (!fileData.fileModificationTimeMatchesExpectation())
                    return false;
                auto sourceHandle = FileSystem::openFile(fileData.filename, FileSystem::FileOpenMode::Read);
                if (!sourceHandle)
                    return false;
                if (fileData.fileStart && !sourceHandle.seek(fileData.fileStart, FileSystem::FileSeekOrigin::Beginning))
                    return false;
                long long remaining = fileData.fileLength;
                Vector<uint8_t> buffer(1 << 16);
                while (remaining) {
                    size_t bytesToRead = buffer.size();
                    if (remaining != WebCore::BlobDataItem::toEndOfFile)
                        bytesToRead = std::min<long long>(remaining, bytesToRead);
                    auto bytesRead = sourceHandle.read(buffer.mutableSpan().first(bytesToRead));
                    if (!bytesRead)
                        return false;
                    if (!*bytesRead)
                        break;
                    if (temporaryHandle.write(buffer.span().first(*bytesRead)) != *bytesRead)
                        return false;
                    if (remaining != WebCore::BlobDataItem::toEndOfFile)
                        remaining -= *bytesRead;
                }
                return true;
            },
            [](const WebCore::FormDataElement::EncodedBlobData&) {
                return false;
            });
        if (!succeeded)
            break;
    }
    temporaryHandle = { };

    if (!succeeded) {
        FileSystem::deleteFile(temporaryPath);
        return nil;
    }
    temporaryPathOut = temporaryPath;
    return adoptNS([[NSURL alloc] initFileURLWithPath:temporaryPath.createNSString().get() isDirectory:NO]);
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

    if (parameters.isMainFrameNavigation
        || parameters.hadMainFrameMainResourcePrivateRelayed
        || request.url().host() == request.firstPartyForCookies().host()) {
        [mutableRequest _setPrivacyProxyFailClosedForUnreachableNonMainHosts:YES];
    }

    if (!parameters.allowPrivacyProxy)
        [mutableRequest _setProhibitPrivacyProxy:YES];

    auto advancedPrivacyProtections = parameters.advancedPrivacyProtections;
#if ENABLE(ADVANCED_PRIVACY_PROTECTIONS)
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::BaselineProtections) && parameters.isMainFrameNavigation)
        configureForAdvancedPrivacyProtections(m_sessionWrapper->session.get());

    enableAdvancedPrivacyProtections(mutableRequest.get(), advancedPrivacyProtections);
#endif

#if HAVE(STRICT_FAIL_CLOSED)
    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::StrictFailClosed))
        [mutableRequest _setPrivacyProxyStrictFailClosed:YES];
#endif

    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::FailClosedForUnreachableHosts))
        [mutableRequest _setPrivacyProxyFailClosedForUnreachableHosts:YES];

    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::FailClosedForAllHosts))
        [mutableRequest _setPrivacyProxyFailClosed:YES];

    if (advancedPrivacyProtections.contains(WebCore::AdvancedPrivacyProtections::WebSearchContent))
        [mutableRequest _setWebSearchContent:YES];

    if (parameters.request.isPrivateTokenUsageByThirdPartyAllowed())
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
    // MAVERICKS_BACKPORT: see materializeFileBackedRequestBody above — file-backed bodies must go
    // out as upload-from-file tasks on 10.9 or they are sent chunked without a Content-Length.
    RetainPtr<NSURL> uploadBodyFileURL;
    if ([nsRequest HTTPBodyStream]) {
        if (RefPtr body = request.httpBody())
            uploadBodyFileURL = materializeFileBackedRequestBody(*body, m_uploadBodyTemporaryPath);
    }
    if (uploadBodyFileURL) {
        RetainPtr<NSMutableURLRequest> uploadRequest = adoptNS([nsRequest.get() mutableCopy]);
        [uploadRequest setHTTPBodyStream:nil];
        // Drop the stream-derived Content-Length so CFNetwork recomputes it from the actual file.
        [uploadRequest setValue:nil forHTTPHeaderField:@"Content-Length"];
        nsRequest = uploadRequest;
        m_task = [m_sessionWrapper->session uploadTaskWithRequest:nsRequest.get() fromFile:uploadBodyFileURL.get()];
    } else
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
        RetainPtr<NSURLSessionConfiguration> effectiveConfiguration = m_sessionWrapper->session.get().configuration;
        effectiveConfiguration.get().URLCredentialStorage = nil;
        [m_task _adoptEffectiveConfiguration:effectiveConfiguration.get()];
        break;
    };

    RELEASE_ASSERT(!m_sessionWrapper->dataTaskMap.contains([m_task taskIdentifier]));
    m_sessionWrapper->dataTaskMap.add([m_task taskIdentifier], this);
    LOG(NetworkSession, "%lu Creating NetworkDataTask with URL %s", (unsigned long)[m_task taskIdentifier], [nsRequest URL].absoluteString.UTF8String);

    if (parameters.shouldPreconnectOnly == PreconnectOnly::Yes) {
#if ENABLE(SERVER_PRECONNECT)
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

    if (WebCore::ResourceRequest::resourcePrioritiesEnabled())
        m_task.get().priority = toNSURLSessionTaskPriority(request.priority());

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
        auto iterator = map.find([m_task taskIdentifier]);
        RELEASE_ASSERT(iterator != map.end());
        ASSERT(!iterator->value.get());
        map.remove(iterator);
    }

    // MAVERICKS_BACKPORT: reclaim the materialized upload body (see materializeFileBackedRequestBody).
    if (!m_uploadBodyTemporaryPath.isNull())
        FileSystem::deleteFile(m_uploadBodyTemporaryPath);
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


    // MAVERICKS_BACKPORT: same guard for the gzip decoder — a decode error, or a body that ended
    // partway through a member (inMember, i.e. never reached the member's Z_STREAM_END), must fail
    // the load rather than surface truncated. A body ending exactly at a member boundary is clean.
    if (m_gzipStream
        && (m_gzipStream->failed || (error.isNull() && m_gzipStream->sawInput && m_gzipStream->inMember))) {
        if (RefPtr client = m_client.get())
            client->didCompleteWithError(WebCore::ResourceError(String(NSURLErrorDomain), NSURLErrorCannotDecodeContentData, firstRequest().url(), "cannot decode gzip response body"_s), networkLoadMetrics);
        return;
    }

    if (RefPtr client = m_client.get())
        client->didCompleteWithError(error, networkLoadMetrics);
}

void NetworkDataTaskCocoa::didReceiveData(const WebCore::SharedBuffer& data)
{
    WTFEmitSignpost(m_task.get(), DataTask, "received %zd bytes", data.size());

    setBytesTransferredOverNetwork([m_task _countOfBytesReceivedEncoded]);

    // MAVERICKS_BACKPORT: decode gzip bodies CFNetwork suppressed for .gz/.tgz URLs (see didReceiveResponse).
    if (m_gzipStream) {
        if (m_gzipStream->failed)
            return;
        if (!m_gzipStream->initialized) {
            m_gzipStream->failed = true;
            [m_task cancel]; // stop the transfer; didCompleteWithError converts to a decode error
            return;
        }
        m_gzipStream->sawInput = true;
        auto span = data.span();
        m_gzipStream->stream.next_in = const_cast<Bytef*>(span.data());
        m_gzipStream->stream.avail_in = span.size();
        Vector<uint8_t> decoded;
        uint8_t outputChunk[16384];
        while (m_gzipStream->stream.avail_in) {
            m_gzipStream->stream.next_out = outputChunk;
            m_gzipStream->stream.avail_out = sizeof(outputChunk);
            int result = inflate(&m_gzipStream->stream, Z_NO_FLUSH);
            if (size_t produced = sizeof(outputChunk) - m_gzipStream->stream.avail_out)
                decoded.append(std::span<const uint8_t> { outputChunk, produced });
            if (result == Z_STREAM_END) {
                // This member is complete. gzip streams may concatenate more members; reset and keep
                // draining so we decode ALL of them (a plain break would silently drop the rest).
                m_gzipStream->inMember = false;
                if (inflateReset(&m_gzipStream->stream) != Z_OK) {
                    m_gzipStream->failed = true;
                    [m_task cancel];
                    return;
                }
                continue;
            }
            // Z_BUF_ERROR here means the stream needs more input than this chunk carries; we are
            // still inside a member, so wait for the next didReceiveData (zlib keeps its state).
            if (result == Z_BUF_ERROR) {
                m_gzipStream->inMember = true;
                break;
            }
            if (result != Z_OK) {
                m_gzipStream->failed = true;
                [m_task cancel]; // stop the transfer; didCompleteWithError converts to a decode error
                return;
            }
            m_gzipStream->inMember = true; // consumed input within a member that has not yet ended
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

// MAVERICKS_BACKPORT: true when CFNetwork will have delivered this response's body still
// gzip-compressed. CFNetwork auto-decodes Content-Encoding: gzip transparently, but suppresses that
// for URLs whose last path component ends in .gz or .tgz (case-insensitive) — its long-standing
// heuristic to keep gzip-archive downloads intact when a server double-gzips them. Reversing it for
// a fetch()/XHR *load* matches the Fetch spec and every other browser (Chrome/Firefox decode
// Content-Encoding regardless of extension), which is what a site like marciot.com's icon catalog
// relies on; downloads bypass didReceiveData so archive downloads still reach disk raw. This is the
// same spirit as the br decoder above — reverse a CFNetwork content-decoding gap so the real web
// works — not a claim of parity with any particular Safari.
//
// The trigger was pinned empirically on this 10.9 host (byte-length probes on a double-gzipped body:
// 4746 = CFNetwork decoded, 4769 = raw): .gz/.tgz/.tar.gz/.GZ are delivered raw; .svgz/.gzip/.z and
// non-archive extensions are decoded. Because the Content-Encoding header is present in BOTH cases,
// the extension is the only available signal, so this must key on the SAME URL CFNetwork does. A
// redirect probe (orig .tgz -> final no-ext, and orig no-ext -> final .tgz) showed CFNetwork keys the
// FINAL, post-redirect URL — response.url() here — with zero double-decode in either direction.
static bool responseIsCFNetworkSuppressedGzip(const WebCore::ResourceResponse& response)
{
    auto contentEncoding = response.httpHeaderField(WebCore::HTTPHeaderName::ContentEncoding);
    if (!equalLettersIgnoringASCIICase(contentEncoding, "gzip"_s) && !equalLettersIgnoringASCIICase(contentEncoding, "x-gzip"_s))
        return false;
    auto lastPathComponent = response.url().lastPathComponent();
    return lastPathComponent.endsWithIgnoringASCIICase(".gz"_s) || lastPathComponent.endsWithIgnoringASCIICase(".tgz"_s);
}

void NetworkDataTaskCocoa::didReceiveResponse(WebCore::ResourceResponse&& response, NegotiatedLegacyTLS negotiatedLegacyTLS, PrivateRelayed privateRelayed, WebKit::ResponseCompletionHandler&& completionHandler)
{
    WTFEmitSignpost(m_task.get(), DataTask, "received response headers");
    if (isTopLevelNavigation())
        updateFirstPartyInfoForSession(response.url());
#if ENABLE(NETWORK_ISSUE_REPORTING)
    else if (NetworkIssueReporter::shouldReport(retainPtr([m_task _incompleteTaskMetrics]).get())) {
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
                if (cookies.count > 0) {
                    // Store with the real main-document URL so the storage's accept policy can do
                    // the third-party check on 10.9 (our own blockCookies() is a no-op there).
                    RetainPtr<NSURL> mainDocumentURL = isTopLevelNavigation() ? retainPtr([httpResponse URL]) : firstRequest().firstPartyForCookies().createNSURL();
                    [cookieStorage setCookies:cookies forURL:[httpResponse URL] mainDocumentURL:mainDocumentURL.get()];
                }
            }
        }
    }
        // MAVERICKS_BACKPORT: reverse CFNetwork's .gz/.tgz gzip-decode suppression for non-download loads
    // so fetch()/XHR of a gzip-encoded archive sees decoded bytes, matching every other browser and
    // the Fetch spec. Gated on the exact condition CFNetwork suppresses (Content-Encoding: gzip AND a
    // .gz/.tgz URL extension), so it never double-decodes a body CFNetwork already handled.
    if (responseIsCFNetworkSuppressedGzip(response))
        m_gzipStream = std::unique_ptr<GzipStream>(new GzipStream);

    NetworkDataTask::didReceiveResponse(WTF::move(response), negotiatedLegacyTLS, privateRelayed, WebCore::IPAddress::fromString(lastRemoteIPAddress(m_task.get())), WTF::move(completionHandler));
}

void NetworkDataTaskCocoa::willPerformHTTPRedirection(WebCore::ResourceResponse&& redirectResponse, WebCore::ResourceRequest&& request, RedirectCompletionHandler&& completionHandler)
{
    WTFEmitSignpost(m_task.get(), DataTask, "redirect");

    // MAVERICKS_BACKPORT: 10.9's NSURLSession does not persist Set-Cookie headers from a 3xx
    // redirect response — the same gap this file already works around for the initial request
    // (manual Cookie injection above) and the final response (manual Set-Cookie storage in
    // didReceiveResponse). NSURLSession only surfaces the redirect's cookies here, and it has
    // ALREADY built the followed request's Cookie header from the pre-redirect storage state.
    // Without this, a cookie set on a redirect — e.g. a login POST that 302s and sets the
    // session cookie — is dropped: the followed request carries the stale pre-redirect cookie
    // and the server treats the user as logged out. Persist the redirect response's cookies,
    // then rebuild the followed request's Cookie header so they are actually sent.
    if (RetainPtr<NSHTTPCookieStorage> cookieStorage = m_sessionWrapper->session.get().configuration.HTTPCookieStorage) {
        RetainPtr<NSURLResponse> nsRedirectResponse = redirectResponse.nsURLResponse();
        if ([nsRedirectResponse isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpRedirect = (NSHTTPURLResponse *)nsRedirectResponse.get();
            NSArray<NSHTTPCookie *> *setCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[httpRedirect allHeaderFields] forURL:[httpRedirect URL]];
            if (setCookies.count) {
                // Store with the real main-document URL so the storage's accept policy (which
                // does the third-party check on 10.9, where our own blockCookies() is a no-op)
                // can decide, exactly as the initial request and final response do. For a
                // top-level navigation the main document IS the redirecting hop that set these
                // cookies ([httpRedirect URL], as in didReceiveResponse) — NOT the redirect
                // target, which would wrongly reject a cross-domain top-level handoff (idp →
                // 302 Set-Cookie → app) under OnlyFromMainDocumentDomain.
                RetainPtr<NSURL> mainDocumentURL = isTopLevelNavigation() ? retainPtr([httpRedirect URL]) : request.firstPartyForCookies().createNSURL();
                [cookieStorage setCookies:setCookies forURL:[httpRedirect URL] mainDocumentURL:mainDocumentURL.get()];
            }
        }

        // The followed request's Cookie header was built from the pre-redirect storage state, and
        // 10.9 CFNetwork can carry a Cookie header over from the previous — possibly cross-site —
        // request. Neither is correct for the target after the redirect. Drop it unconditionally
        // (so no source-site cookies survive an origin hop, mirroring the Authorization/Origin
        // stripping below), then rebuild from storage for the target URL when this load is allowed
        // cookies (same gate as the initial-request injection above).
        request.removeHTTPHeaderField(WebCore::HTTPHeaderName::Cookie);
        if (m_storedCredentialsPolicy != WebCore::StoredCredentialsPolicy::DoNotUse && request.allowCookies()) {
            RetainPtr<NSURL> nsRequestURL = request.url().createNSURL();
            NSArray<NSHTTPCookie *> *cookies = [cookieStorage cookiesForURL:nsRequestURL.get()];
            if (cookies.count) {
                NSString *cookieHeader = [[NSHTTPCookie requestHeaderFieldsWithCookies:cookies] objectForKey:@"Cookie"];
                if (cookieHeader.length)
                    request.setHTTPHeaderField(WebCore::HTTPHeaderName::Cookie, String(cookieHeader));
            }
        }
    }

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
    m_task.get().priority = toNSURLSessionTaskPriority(priority);
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
