/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlResourceHandle.h"
#include "CocoaCookie.h"
#include "CocoaCurlMultipartHandle.h"
#include "SecurityOrigin.h"
#include "ResourceHandleInternal.h"
#include "CookieJar.h"
#include <wtf/TZoneMallocInlines.h>
#include "CredentialStorage.h"
#include "Cookie.h"
#include "DNS.h"
#include "HTTPParsers.h"
#include "HTTPStatusCodes.h"
#include "HTTPStrictTransportSecurityStore.h"
#include "CocoaMIMESniffing.h"
#include "OriginAccessPatterns.h"
#include "ResourceLoaderOptions.h"
#include "SameSiteInfo.h"
#include "SharedBuffer.h"
#include "Site.h"
#include "SynchronousLoaderClient.h"
#include "FrameLoaderTypes.h"
#include "WebCoreResourceHandleAsOperationQueueDelegate.h"
#include "WebCoreURLResponse.h"
#include <Foundation/Foundation.h>
#include <wtf/HexNumber.h>
#include <wtf/WallTime.h>
#include <wtf/cocoa/VectorCocoa.h>
#include <wtf/text/StringBuilder.h>

@interface NSURLRequest (CocoaCurlHTTPSCertificateAllowance)
+ (BOOL)allowsAnyHTTPSCertificateForHost:(NSString *)host;
@end

// the legacy loader owns redirect/cookie/authentication policy; its native connection never owns HTTP wire bytes.
namespace WebCore {
WTF_MAKE_TZONE_ALLOCATED_IMPL(CocoaCurlResourceHandle);
Ref<CocoaCurlResourceHandle> CocoaCurlResourceHandle::create(ResourceHandle& handle, NetworkStorageSession& storage, SynchronousLoaderMessageQueue* queue)
{
    return adoptRef(*new CocoaCurlResourceHandle(handle, storage, handle.client() && handle.client()->shouldUseCredentialStorage(&handle), queue));
}
CocoaCurlResourceHandle::CocoaCurlResourceHandle(ResourceHandle& handle, NetworkStorageSession& storage, bool allowStoredCredentials, SynchronousLoaderMessageQueue* queue)
    : m_handle(&handle)
    , m_pool(storage.cocoaCurlConnectionPool(allowStoredCredentials))
    , m_storage(storage)
    , m_queue(queue)
    , m_dispatcher(adoptNS([[WebCoreResourceHandleAsOperationQueueDelegate alloc] initWithHandle:&handle messageQueue:RefPtr { queue }]))
    , m_request(handle.firstRequest())
    , m_deferred(handle.d->m_defersLoading)
    , m_allowCredentials(allowStoredCredentials)
{
    if (m_allowCredentials && m_request.url().protocolIsInHTTPFamily()) {
        if (handle.d->m_user.isEmpty() && handle.d->m_password.isEmpty())
            m_initialCredential = m_storage->credentialStorage().get(m_request.cachePartition(), m_request.url());
        else
            m_storage->credentialStorage().set(m_request.cachePartition(), Credential(handle.d->m_user, handle.d->m_password, CredentialPersistence::None), m_request.url());
    }
    if (!m_initialCredential.isEmpty() && !m_request.hasHTTPHeaderField(HTTPHeaderName::Authorization)) {
        m_user = m_initialCredential.user();
        m_password = m_initialCredential.password();
        m_auth = CURLAUTH_BASIC;
    }
}
CocoaCurlResourceHandle::~CocoaCurlResourceHandle()
{
    detachTransfer();
}
void CocoaCurlResourceHandle::start()
{
    m_handle->d->m_startTime = MonotonicTime::now();
    auto start = [loader = Ref { *this }] { loader->beginTransfer(); };
    [m_dispatcher callFunctionOnMainThread:WTF::move(start)];
}
void CocoaCurlResourceHandle::detachTransfer()
{
    if (auto connection = std::exchange(m_connection, nullptr))
        connection->invalidateClient();
    if (m_continuation)
        std::exchange(m_continuation, nullptr)();
}
void CocoaCurlResourceHandle::detach()
{
    m_handle = nullptr;
    cancel();
}
void CocoaCurlResourceHandle::cancel()
{
    if (std::exchange(m_cancelled, true))
        return;
    detachTransfer();
    if (auto challenge = std::exchange(m_challenge, nullptr))
        [[challenge sender] cancelAuthenticationChallenge:challenge.get()];
}
void CocoaCurlResourceHandle::setDefersLoading(bool deferred)
{
    m_deferred = deferred;
    if (m_connection)
        m_connection->setDefersLoading(deferred);
}
void CocoaCurlResourceHandle::beginTransfer()
{
    detachTransfer();
    if (m_cancelled || !m_handle)
        return;
    if (!m_request.url().isValid()) {
        auto url = cocoaCurlRequestURL(m_request.url());
        if (!url) {
            fail(url.error(), "The request URL is not valid"_s);
            return;
        }
        m_request.setURL(WTF::move(*url));
    }
    if (!m_storage || !m_request.url().protocolIsInHTTPFamily() || !portAllowed(m_request.url()) || isIPAddressDisallowed(m_request.url())) {
        fail(NSURLErrorCannotConnectToHost, "The request URL or storage session is no longer available"_s);
        return;
    }
    if (m_request.url().protocolIs("http"_s) && m_storage->httpStrictTransportSecurityStore().shouldUpgrade(m_request.url())) {
        auto secureURL = m_request.url();
        secureURL.setProtocol("https"_s);
        if (secureURL.port() == 80)
            secureURL.setPort(std::nullopt);
        m_response.response = ResourceResponse(URL { m_request.url() }, String(), 0, String());
        m_response.response.setHTTPStatusCode(307);
        m_response.response.setHTTPHeaderField(HTTPHeaderName::Location, secureURL.string());
        redirect();
        return;
    }
    m_cacheBody.reset();
    auto cache = lookUpCocoaCurlCachedResponse(m_storage.get(), m_request);
    if (cache.answer == CocoaCurlCacheAnswer::Unavailable) {
        fail(NSURLErrorResourceUnavailable, "The resource is not in the cache"_s);
        return;
    }
    if (cache.answer == CocoaCurlCacheAnswer::UseCached) {
        publishCachedResponse(cocoaCurlCachedResponse(cache.entry.get(), m_request), cache.entry.get());
        return;
    }
    m_cachedEntry = cache.answer == CocoaCurlCacheAnswer::Revalidate ? WTF::move(cache.entry) : nullptr;
    if (std::exchange(m_generatedCookie, false))
        m_request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (m_request.allowCookies() && !m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie)) {
        auto cookie = m_storage->cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), cookieRequestSameSiteInfo(m_request), m_request.url(), std::nullopt, std::nullopt, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
        if (!cookie.isEmpty()) {
            m_request.setHTTPHeaderField(HTTPHeaderName::Cookie, cookie);
            m_generatedCookie = true;
        }
    }
    CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
    options.request = m_request;
    if (m_cachedEntry)
        addCocoaCurlCacheValidators(options.request, m_cachedEntry.get());
    if (auto body = m_request.httpBody())
        options.upload = CocoaCurlUploadBody::create(*body);
    options.acceptedCertificateChain = m_acceptedChain;
    options.connectionPartition = Site { m_request.firstPartyForCookies() }.toString();
    options.user = m_user;
    options.password = m_password;
    options.authentication = m_auth;
    options.proxyCredentialHost = m_response.proxyHost;
    options.proxyCredentialPort = m_response.proxyPort;
    options.proxyUser = m_proxyUser;
    options.proxyPassword = m_proxyPassword;
    options.proxyAuthentication = m_proxyAuth;
    m_response = { };
    m_result.reset();
    m_sniffed.clear();
    m_useResponse = false;
    m_waitingForPolicy = false;
    m_pool = m_storage->cocoaCurlConnectionPool(m_allowCredentials);
    m_connection = CocoaCurlConnection::create(m_pool, *this, WTF::move(options), m_queue.get(), [dispatcher = m_dispatcher](Function<void()>&& callback) {
        [dispatcher callFunctionOnMainThread:WTF::move(callback)];
    });
    m_connection->setDefersLoading(m_deferred);
    m_connection->start();
}
// commit each wire field before the next authentication request.
void CocoaCurlResourceHandle::curlReceivedCookies(Vector<String>&& fields, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion)
{
    if (m_cancelled || !m_handle) {
        completion(std::nullopt);
        return;
    }
    if (m_storage && m_request.allowCookies()) {
        auto sameSite = SameSiteInfo::create(m_request);
        for (auto& field : fields) {
            auto cookie = parseHTTPSetCookie(field, m_request.url());
            if (cookie && (cookie->sameSite == Cookie::SameSitePolicy::None || sameSite.isSameSite || sameSite.isTopSite))
                m_storage->setCookie(*cookie, m_request.url(), m_request.firstPartyForCookies());
        }
    }
    if (!m_storage || !m_request.allowCookies() || (m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie) && !m_generatedCookie)) {
        completion(std::nullopt);
        return;
    }
    auto value = m_storage->cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), cookieRequestSameSiteInfo(m_request), m_request.url(), std::nullopt, std::nullopt, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
    completion(WTF::move(value));
}
void CocoaCurlResourceHandle::curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion)
{
    if (m_cancelled || !m_handle) {
        completion();
        return;
    }
    m_continuation = WTF::move(completion);
    m_metrics = response.metrics;
    m_metrics.redirectCount = m_redirects;
    m_response = WTF::move(response);
    invalidateCocoaCurlCacheAfterResponse(m_storage.get(), m_request, m_response.response);
    auto tls = m_connection->tlsState();
    SecTrustResultType trustResult = kSecTrustResultInvalid;
    if (m_storage && tls && tls->trust && SecTrustGetTrustResult(tls->trust.get(), &trustResult) == errSecSuccess && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified))
        m_storage->httpStrictTransportSecurityStore().receiveHeader(m_request.url(), m_response.response.httpHeaderField("Strict-Transport-Security"_s));
    m_responseTimestamp = WallTime::now();
    auto status = m_response.response.httpStatusCode();
    // A 304 refreshes the stored metadata before completing the validating request.
    if (RetainPtr entry = std::exchange(m_cachedEntry, nullptr); entry && status == httpStatus304NotModified) {
        auto revalidated = cocoaCurlRevalidatedResponse(entry.get(), m_response.response);
        auto body = makeVector(cocoaCurlCachedBody(entry.get()));
        if (cocoaCurlCacheMayStore(m_storage.get(), m_request, revalidated)) {
            auto updatedEntry = createCocoaCurlCachedResponse(m_storage.get(), m_request, revalidated, body.span(), m_responseTimestamp);
            storeCocoaCurlCachedResponse(m_storage.get(), updatedEntry.get(), m_request);
        } else
            removeCocoaCurlCachedResponse(m_storage.get(), m_request);
        // Caller-supplied validators retain the 304; cache-generated validation supplies the stored representation.
        if (m_request.isConditional()) {
            for (auto field : { HTTPHeaderName::CrossOriginResourcePolicy, HTTPHeaderName::CrossOriginEmbedderPolicy }) {
                auto value = revalidated.httpHeaderField(field);
                if (!value.isEmpty())
                    m_response.response.setHTTPHeaderField(field, value);
            }
        } else {
            m_response.response = WTF::move(revalidated);
            m_sniffed = WTF::move(body);
        }
        publishResponse();
        return;
    }
    if (m_response.response.isRedirection() && !m_response.response.httpHeaderField(HTTPHeaderName::Location).isEmpty()) {
        if (cocoaCurlCacheMayStore(m_storage.get(), m_request, m_response.response)) {
            auto entry = createCocoaCurlCachedResponse(m_storage.get(), m_request, m_response.response, { }, m_responseTimestamp);
            storeCocoaCurlCachedResponse(m_storage.get(), entry.get(), m_request);
        } else
            removeCocoaCurlCachedResponse(m_storage.get(), m_request);
        redirect();
        return;
    }
    if (status == 401 || status == 407) {
        authenticate(status == 407);
        return;
    }
    if (cocoaCurlCacheMayStore(m_storage.get(), m_request, m_response.response))
        m_cacheBody.emplace();
    else if (m_request.httpMethod() == "GET"_s && m_response.response.httpStatusCode() != httpStatus206PartialContent)
        removeCocoaCurlCachedResponse(m_storage.get(), m_request);
    publishResponse();
}
void CocoaCurlResourceHandle::redirect()
{
    if (m_redirects >= ResourceLoaderOptions { }.maxRedirectCount) {
        fail(NSURLErrorHTTPTooManyRedirects, "Too many HTTP redirects"_s);
        return;
    }
    StringBuilder location;
    for (auto byte : asBytes(m_response.response.httpHeaderField(HTTPHeaderName::Location).latin1().span())) {
        if (byte >= 0x80)
            location.append('%', upperNibbleToASCIIHexDigit(byte), lowerNibbleToASCIIHexDigit(byte));
        else
            location.append(static_cast<char>(byte));
    }
    URL url(m_request.url(), location.toString());
    if (!url.hasFragmentIdentifier() && m_request.url().hasFragmentIdentifier())
        url.setFragmentIdentifier(m_request.url().fragmentIdentifier());
    // CFNetwork refuses a redirect to a file URL before its delegate sees it, failing the current URL.
    if (url.protocolIsFile()) {
        fail(NSURLErrorNoPermissionsToReadFile, "You do not have permission to access the requested resource."_s);
        return;
    }
    auto request = m_request;
    request.setURL(WTF::move(url));
    // Any cross-site redirect makes a request not same-site, as CachedResourceLoader::updateRequestAfterRedirection
    // decides it.
    if (!SecurityOrigin::create(request.url())->isSameSiteAs(SecurityOrigin::create(m_request.url())))
        request.setIsSameSite(false);
    auto status = m_response.response.httpStatusCode();
    auto method = request.httpMethod();
    if ((status == 303 && method != "GET"_s && method != "HEAD"_s) || ((status == 301 || status == 302) && method == "POST"_s)) {
        request.setHTTPMethod("GET"_s);
        clearCocoaCurlHTTPBody(request);
        for (auto field : { HTTPHeaderName::ContentLength, HTTPHeaderName::ContentType, HTTPHeaderName::ContentEncoding, HTTPHeaderName::ContentLanguage, HTTPHeaderName::ContentLocation, HTTPHeaderName::TransferEncoding })
            request.removeHTTPHeaderField(field);
    }
    if (m_handle->context()->shouldClearReferrerOnHTTPSToHTTPRedirect() && !request.url().protocolIs("https"_s) && protocolIs(request.httpReferrer(), "https"_s))
        request.clearHTTPReferrer();
    if (!protocolHostAndPortAreEqual(m_request.url(), request.url())) {
        request.clearHTTPAuthorization();
        request.clearHTTPOrigin();
        request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    }
    m_handle->d->m_user = request.url().user();
    m_handle->d->m_password = request.url().password();
    request.removeCredentials();
    ++m_redirects;
    m_handle->incrementRedirectCount();
    m_handle->checkTAO(m_response.response);
    if (!m_handle->hasCrossOriginRedirect() && !SecurityOrigin::create(request.url())->canRequest(m_response.response.url(), OriginAccessPatternsForWebProcess::singleton()))
        m_handle->markAsHavingCrossOriginRedirect();
    Ref handle { *m_handle };
    if (!handle->client()) {
        cancel();
        return;
    }
    handle->client()->willSendRequestAsync(handle.ptr(), WTF::move(request), ResourceResponse(m_response.response), [loader = Ref { *this }](ResourceRequest&& approved) {
        if (loader->m_cancelled || !loader->m_handle)
            return;
        if (approved.isNull()) {
            loader->cancel();
            if (loader->m_queue)
                loader->m_queue->kill();
            return;
        }
        if (!protocolHostAndPortAreEqual(loader->m_request.url(), approved.url())) {
            loader->m_user = emptyString();
            loader->m_password = emptyString();
            loader->m_auth = CURLAUTH_NONE;
            loader->m_authFailures = 0;
            loader->m_acceptedChain = nullptr;
        } else if (loader->m_allowCredentials && loader->m_handle->d->m_user.isEmpty() && loader->m_handle->d->m_password.isEmpty() && loader->m_user.isEmpty() && loader->m_password.isEmpty()) {
            // A hop that stays on the origin and reaches a path a credential is stored for carries it
            // preemptively, the same way the first request does.
            loader->m_initialCredential = loader->m_storage->credentialStorage().get(approved.cachePartition(), approved.url());
            if (!loader->m_initialCredential.isEmpty() && !approved.hasHTTPHeaderField(HTTPHeaderName::Authorization)) {
                loader->m_user = loader->m_initialCredential.user();
                loader->m_password = loader->m_initialCredential.password();
                loader->m_auth = CURLAUTH_BASIC;
            }
        }
        if (!loader->m_handle->d->m_user.isEmpty() || !loader->m_handle->d->m_password.isEmpty()) {
            loader->m_user = String();
            loader->m_password = String();
            loader->m_auth = CURLAUTH_NONE;
        }
        approved.removeCredentials();
        loader->m_request = WTF::move(approved);
        loader->m_handle->d->m_previousRequest = loader->m_request;
        loader->m_handle->d->m_lastHTTPMethod = loader->m_request.httpMethod();
        loader->beginTransfer();
    });
}
void CocoaCurlResourceHandle::challenge(const ProtectionSpace& space, const Credential& proposed, unsigned failures, const ResourceError& error, CocoaCurlAuthenticationCompletion&& completion)
{
    if (m_cancelled || !m_handle) {
        completion(CocoaCurlAuthenticationDisposition::Cancel, nullptr);
        return;
    }
    // WebCoreResourceHandleAsOperationQueueDelegate's connection:canAuthenticateAgainstProtectionSpace: comes
    // first; a space the client cannot answer gets CFNetwork's default handling.
    Ref handle { *m_handle };
    handle->canAuthenticateAgainstProtectionSpace(space, [weakThis = WeakPtr { *this }, space, proposed, failures, error, completion = WTF::move(completion)](bool canAuthenticate) mutable {
        RefPtr loader = weakThis.get();
        if (!loader || loader->m_cancelled || !loader->m_handle) {
            completion(CocoaCurlAuthenticationDisposition::Cancel, nullptr);
            return;
        }
        if (!canAuthenticate) {
            completion(CocoaCurlAuthenticationDisposition::PerformDefaultHandling, nullptr);
            return;
        }
        loader->m_challenge = cocoaCurlAuthenticationChallenge(space, proposed, failures, loader->m_response.response, error, WTF::move(completion));
        Ref handle { *loader->m_handle };
        handle->didReceiveAuthenticationChallenge(AuthenticationChallenge(loader->m_challenge.get()));
    });
}
void CocoaCurlResourceHandle::authenticate(bool proxy)
{
    long method = cocoaCurlAuthenticationMethod(proxy ? m_response.proxyAuthentication : m_response.authentication, m_response.response.httpHeaderField(proxy ? "Proxy-Authenticate"_s : "WWW-Authenticate"_s));
    if (!method) {
        publishResponse();
        return;
    }
    auto space = cocoaCurlProtectionSpace(m_request.url(), proxy ? m_response.proxyHost : emptyString(), m_response.proxyPort, method, m_response.response.httpHeaderField(proxy ? "Proxy-Authenticate"_s : "WWW-Authenticate"_s));
    unsigned failures = proxy ? m_proxyAuthFailures : m_authFailures;
    RetainPtr nativeSpace = space.nsSpace();
    bool sharedStorage = m_storage && !m_storage->sessionID().isEphemeral();
    // A stored credential that was not accepted stops being used. Only the one that was actually sent
    // is removed, so a credential another loader stored for this space in the meantime survives.
    if (m_storage && m_allowCredentials && (failures || (!proxy && !m_initialCredential.isEmpty()))) {
        auto& user = proxy ? m_proxyUser : m_user;
        auto& password = proxy ? m_proxyPassword : m_password;
        auto rejected = m_storage->credentialStorage().get(m_request.cachePartition(), space);
        if (rejected.user() == user && rejected.password() == password)
            m_storage->credentialStorage().remove(m_request.cachePartition(), space);
    }
    Credential proposed;
    if (m_storage && m_allowCredentials && !failures) {
        proposed = m_storage->credentialStorage().get(m_request.cachePartition(), space);
        if (proposed.isEmpty() && sharedStorage)
            proposed = Credential([[NSURLCredentialStorage sharedCredentialStorage] defaultCredentialForProtectionSpace:nativeSpace.get()]);
    }
    CocoaCurlAuthenticationCompletion completion = [weakThis = WeakPtr { *this }, proxy, method, space, nativeSpace, sharedStorage](CocoaCurlAuthenticationDisposition disposition, RetainPtr<NSURLCredential>&& credential) {
        RefPtr loader = weakThis.get();
        if (!loader || loader->m_cancelled)
            return;
        auto& attempts = proxy ? loader->m_proxyAuthFailures : loader->m_authFailures;
        bool useKerberosCache = disposition == CocoaCurlAuthenticationDisposition::PerformDefaultHandling && method == CURLAUTH_NEGOTIATE && loader->m_allowCredentials && !attempts;
        if (disposition == CocoaCurlAuthenticationDisposition::Cancel) {
            loader->fail(NSURLErrorUserCancelledAuthentication, "Authentication cancelled"_s);
            return;
        }
        // The transport cannot answer an OAuth challenge with a credential, so the 401 is the load's response.
        if (method == cocoaCurlOAuthAuthentication) {
            loader->publishResponse();
            return;
        }
        if (useKerberosCache || (disposition == CocoaCurlAuthenticationDisposition::UseCredential && credential)) {
            ++attempts;
            (proxy ? loader->m_proxyAuth : loader->m_auth) = method;
            (proxy ? loader->m_proxyUser : loader->m_user) = String(credential.get().user);
            (proxy ? loader->m_proxyPassword : loader->m_password) = String(credential.get().password);
            // Per-session credentials are managed here rather than handed to the system store, which
            // offers no way to ignore one for a single request. A 401 names the URL the credential
            // answers, which adds it as the default for that directory. A permanent one also reaches
            // the keychain, which is what the password-saving checkbox asks for.
            if (loader->m_storage && loader->m_allowCredentials && credential
                && credential.get().persistence != NSURLCredentialPersistenceNone) {
                URL urlToStore;
                if (loader->m_response.response.httpStatusCode() == httpStatus401Unauthorized)
                    urlToStore = loader->m_response.response.url();
                loader->m_storage->credentialStorage().set(loader->m_request.cachePartition(), Credential(String(credential.get().user), String(credential.get().password), CredentialPersistence::None), space, urlToStore);
                if (credential.get().persistence == NSURLCredentialPersistencePermanent && sharedStorage)
                    [[NSURLCredentialStorage sharedCredentialStorage] setDefaultCredential:credential.get() forProtectionSpace:nativeSpace.get()];
            }
            loader->beginTransfer();
        } else
            loader->publishResponse();
    };
    if (!proxy) {
        challenge(space, proposed, failures, { }, WTF::move(completion));
        return;
    }
    // CFNetwork answers a proxy challenge from the stored and keychain credentials itself; the one it
    // cannot answer reaches ResourceHandle, whose rule for a proxy space continues without a credential.
    if (!proposed.isEmpty()) {
        completion(CocoaCurlAuthenticationDisposition::UseCredential, retainPtr(proposed.nsCredential()));
        return;
    }
    challenge(space, proposed, failures, { }, WTF::move(completion));
}
void CocoaCurlResourceHandle::publishResponse()
{
    if (m_cancelled || !m_handle)
        return;
    auto& response = m_response.response;
    if (!m_useResponse && m_sniffed.isEmpty() && !m_result) {
        m_noSniff = !m_handle->shouldContentSniff() || equalLettersIgnoringASCIICase(response.httpHeaderField(HTTPHeaderName::XContentTypeOptions), "nosniff"_s);
        m_needsSniff = m_handle->shouldContentSniff() && response.httpStatusCode() != 204 && response.httpStatusCode() != 304 && m_request.httpMethod() != "HEAD"_s && MIMESniffer::holdsResponseForSniffing(response.mimeType());
        if (m_needsSniff) {
            continueTransfer();
            return;
        }
        // WebCoreResourceHandleAsOperationQueueDelegate's didReceiveResponse, which skips a 304 and passes no nosniff.
        if (response.httpStatusCode() != httpStatus304NotModified) {
            bool isMainResourceLoad = m_handle->firstRequest().requester() == ResourceRequestRequester::Main;
            adjustCocoaCurlMIMETypeIfNecessary(response, isMainResourceLoad ? IsMainResourceLoad::Yes : IsMainResourceLoad::No, IsNoSniffSet::No);
        }
    }
    m_waitingForPolicy = true;
    m_handle->checkTAO(response);
    // Cocoa's copyTimingData includes the original start in the response-time snapshot.
    m_metrics.redirectStart = m_handle->startTimeBeforeRedirects();
    if (!m_metrics.fetchStart)
        m_metrics.fetchStart = m_metrics.redirectStart;
    m_metrics.failsTAOCheck = m_handle->failsTAOCheck();
    m_metrics.hasCrossOriginRedirect = m_handle->hasCrossOriginRedirect();
    m_handle->setNetworkLoadMetrics(Box<NetworkLoadMetrics>::create(m_metrics));
    response.setDeprecatedNetworkLoadMetrics(Box<NetworkLoadMetrics>::create(m_metrics));
    Ref handle { *m_handle };
    if (!handle->client()) {
        cancel();
        return;
    }
    handle->didReceiveResponse(ResourceResponse(response), [loader = Ref { *this }] {
        if (loader->m_cancelled || !loader->m_handle)
            return;
        loader->m_waitingForPolicy = false;
        loader->m_useResponse = true;
        loader->m_multipart = createCocoaCurlMultipartHandle(loader.get(), loader->m_response.response);
        auto callback = [loader] {
            if (loader->m_cancelled || !loader->m_handle)
                return;
            if (!loader->m_sniffed.isEmpty())
                loader->deliver(std::exchange(loader->m_sniffed, { }).span());
            loader->continueTransfer();
        };
        [loader->m_dispatcher callFunctionOnMainThread:WTF::move(callback)];
    });
}
void CocoaCurlResourceHandle::publishCachedResponse(ResourceResponse&& response, NSCachedURLResponse *entry)
{
    m_response = { };
    m_response.response = WTF::move(response);
    m_metrics = { };
    m_metrics.redirectCount = m_redirects;
    if (isHttpRedirectStatus(m_response.response.httpStatusCode()) && !m_response.response.httpHeaderField(HTTPHeaderName::Location).isEmpty()) {
        redirect();
        return;
    }
    m_sniffed = makeVector(cocoaCurlCachedBody(entry));
    m_result = ResourceError { };
    m_useResponse = false;
    m_waitingForPolicy = false;
    m_cachedEntry = nullptr;
    publishResponse();
}
void CocoaCurlResourceHandle::curlReceivedInformationalResponse(ResourceResponse&&)
{
    // ResourceHandle has no informational-response callback; curl retains its timing in the final metrics.
}
void CocoaCurlResourceHandle::curlSentData(uint64_t sent, uint64_t total)
{
    RefPtr handle = m_handle;
    if (!m_cancelled && handle && handle->client())
        handle->client()->didSendData(handle.get(), sent, total);
}
void CocoaCurlResourceHandle::curlReceivedData(const SharedBuffer& data, CompletionHandler<void()>&& completion)
{
    if (m_cancelled || !m_handle) {
        completion();
        return;
    }
    m_continuation = WTF::move(completion);
    if (m_needsSniff) {
        m_sniffed.append(data.span());
        if (m_sniffed.size() >= MIMESniffer::sniffedPrefixLength) {
            m_response.response.setMimeType(MIMESniffer::computeHTTPMIMEType(m_sniffed.span().first(MIMESniffer::sniffedPrefixLength), m_response.response.mimeType(), m_response.contentType, m_noSniff));
            m_needsSniff = false;
            publishResponse();
        } else
            continueTransfer();
        return;
    }
    deliver(data.span());
    continueTransfer();
}
void CocoaCurlResourceHandle::deliver(std::span<const uint8_t> bytes)
{
    if (m_cacheBody) {
        if (m_multipart || !cocoaCurlCacheAcceptsLength(m_storage.get(), m_cacheBody->size() + bytes.size()))
            m_cacheBody.reset();
        else
            m_cacheBody->append(bytes);
    }
    if (m_multipart) {
        m_multipart->didReceiveMessage(bytes);
        if (m_multipart->hasError())
            fail(NSURLErrorCannotParseResponse, "Invalid multipart response"_s);
        return;
    }
    didReceiveDataFromMultipart(bytes);
}
void CocoaCurlResourceHandle::didReceiveHeaderFromMultipart(Vector<String>&& fields)
{
    ResourceResponse response = m_response.response;
    for (auto& rawField : fields) {
        // Each field arrives as the header line the multipart parser read, its terminator included.
        auto field = rawField.trim([](auto c) { return c == '\r' || c == '\n'; });
        auto colon = field.find(':');
        if (colon == notFound) {
            fail(NSURLErrorCannotParseResponse, "Invalid multipart header"_s);
            return;
        }
        auto name = field.left(colon);
        auto value = field.substring(colon + 1).trim([](auto c) { return c == ' ' || c == '\t'; });
        if (!isValidHTTPToken(name) || !isValidHTTPHeaderValue(value)) {
            fail(NSURLErrorCannotParseResponse, "Invalid multipart header"_s);
            return;
        }
        response.setHTTPHeaderField(name, value);
    }
    auto type = response.httpHeaderField(HTTPHeaderName::ContentType);
    setCocoaCurlContentType(response, type);
    m_waitingForPolicy = true;
    auto callback = [loader = Ref { *this }, response = WTF::move(response)]() mutable {
        RefPtr handle = loader->m_handle;
        if (loader->m_cancelled || !handle || !handle->client())
            return;
        handle->didReceiveResponse(WTF::move(response), [loader] {
            if (loader->m_cancelled)
                return;
            loader->m_waitingForPolicy = false;
            loader->m_multipart->completeHeaderProcessing();
            loader->continueTransfer();
        });
    };
    [m_dispatcher callFunctionOnMainThread:WTF::move(callback)];
}
void CocoaCurlResourceHandle::didReceiveDataFromMultipart(std::span<const uint8_t> data)
{
    RefPtr handle = m_handle;
    if (!m_cancelled && handle && handle->client())
        handle->client()->didReceiveData(handle.get(), SharedBuffer::create(data).get(), -1);
}
void CocoaCurlResourceHandle::didCompleteFromMultipart()
{
    if (m_result && m_result->isNull())
        finish({ });
}
void CocoaCurlResourceHandle::curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion)
{
    auto space = cocoaCurlTLSProtectionSpace(m_request.url(), 7, authorities, nullptr);
    if (!space) {
        completion(nullptr, nullptr);
        fail(NSURLErrorClientCertificateRejected, "Could not construct a client certificate challenge"_s);
        return;
    }
    challenge(ProtectionSpace(space.get()), { }, 0, { }, [completion = WTF::move(completion)](CocoaCurlAuthenticationDisposition disposition, RetainPtr<NSURLCredential>&& credential) mutable {
        if (disposition == CocoaCurlAuthenticationDisposition::UseCredential && credential)
            completion(retainPtr((SecIdentityRef)credential.get().identity), retainPtr((CFArrayRef)credential.get().certificates));
        else
            completion(nullptr, nullptr);
    });
}
void CocoaCurlResourceHandle::curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion)
{
    // A host given +[NSURLRequest setAllowsAnyHTTPSCertificate:forHost:] is trusted by the handshake
    // itself, with no challenge, as NSURLConnection trusts it.
    bool hostAllowsAnyCertificate = [NSURLRequest allowsAnyHTTPSCertificateForHost:m_request.url().host().createNSString().get()];
    completion(!m_cancelled && (m_connection->tlsState()->accepted || hostAllowsAnyCertificate));
}
void CocoaCurlResourceHandle::curlCompleted(const ResourceError& error, const NetworkLoadMetrics& metrics)
{
    if (m_cancelled || !m_handle)
        return;
    m_metrics = metrics;
    m_metrics.redirectCount = m_redirects;
    m_metrics.failsTAOCheck = m_handle->failsTAOCheck();
    m_metrics.hasCrossOriginRedirect = m_handle->hasCrossOriginRedirect();
    if (m_redirects)
        m_metrics.redirectStart = m_handle->startTimeBeforeRedirects();
    auto tls = m_connection->tlsState();
    if (error.errorCode() == NSURLErrorServerCertificateUntrusted && tls && tls->trust && !m_acceptedChain) {
        // the challenge is raised for an HSTS-known host too; the user's decision governs.
        auto space = cocoaCurlTLSProtectionSpace(m_request.url(), 8, nullptr, tls->trust.get());
        if (space) {
            challenge(ProtectionSpace(space.get()), { }, 0, error, [weakThis = WeakPtr { *this }, tls, error](CocoaCurlAuthenticationDisposition disposition, RetainPtr<NSURLCredential>&& credential) {
                RefPtr loader = weakThis.get();
                if (!loader || loader->m_cancelled)
                    return;
                if (disposition != CocoaCurlAuthenticationDisposition::UseCredential || !credential) {
                    loader->finish(error);
                    return;
                }
                loader->m_acceptedChain = tls->peerChain;
                loader->beginTransfer();
            });
            return;
        }
    }
    m_result = error;
    // NSURLConnection holds a response whose type is still being sniffed until its body is complete; a load
    // that fails first delivers only its error.
    if (m_needsSniff && error.isNull()) {
        m_response.response.setMimeType(MIMESniffer::computeHTTPMIMEType(m_sniffed.span(), m_response.response.mimeType(), m_response.contentType, m_noSniff));
        m_needsSniff = false;
        publishResponse();
        return;
    }
    continueTransfer();
}
void CocoaCurlResourceHandle::continueTransfer()
{
    if (m_cancelled || m_waitingForPolicy)
        return;
    if (m_continuation) {
        std::exchange(m_continuation, nullptr)();
        return;
    }
    if (!m_result)
        return;
    if (m_result->isNull() && m_multipart) {
        m_multipart->didCompleteMessage();
        if (m_multipart->hasError())
            fail(NSURLErrorCannotParseResponse, "Invalid multipart response"_s);
        return;
    }
    finish(*m_result);
}
void CocoaCurlResourceHandle::fail(int code, const String& message)
{
    finish(ResourceError(NSURLErrorDomain, code, m_request.url(), message));
}
void CocoaCurlResourceHandle::finish(const ResourceError& error)
{
    Ref protectedThis { *this };
    RefPtr handle = m_handle;
    auto cacheBody = std::exchange(m_cacheBody, std::nullopt);
    cancel();
    if (!handle || !handle->client())
        return;
    if (!error.isNull()) {
        handle->client()->didFail(handle.get(), error);
        return;
    }
    if (!cacheBody) {
        handle->client()->didFinishLoading(handle.get(), m_metrics);
        return;
    }
    // NSURLConnection offers the finished response to connection:willCacheResponse: before it reports the load finished.
    RetainPtr entry = createCocoaCurlCachedResponse(m_storage.get(), m_request, m_response.response, cacheBody->span(), m_responseTimestamp);
    handle->client()->willCacheResponseAsync(handle.get(), entry.get(), [handle, storage = m_storage, request = m_request, metrics = m_metrics](NSCachedURLResponse *approved) {
        if (approved)
            storeCocoaCurlCachedResponse(storage.get(), approved, request);
        if (handle->client())
            handle->client()->didFinishLoading(handle.get(), metrics);
    });
}
std::optional<CocoaCurlDownloadTransfer> CocoaCurlResourceHandle::takeDownload()
{
    // a short representation can finish while MIME detection still holds its response policy; transfer that buffered terminal state too.
    if (m_queue || m_cancelled || !m_storage || !m_waitingForPolicy || (!m_continuation && !m_result))
        return std::nullopt;
    m_handle = nullptr;
    m_cancelled = true;
    m_response.metrics = m_metrics;
    m_cacheBody.reset();
    return CocoaCurlDownloadTransfer { std::exchange(m_connection, nullptr),m_pool.copyRef(), m_storage, m_request, m_response, std::exchange(m_continuation, nullptr), std::exchange(m_sniffed, { }), m_generatedCookie, m_allowCredentials, m_result };
}
}
