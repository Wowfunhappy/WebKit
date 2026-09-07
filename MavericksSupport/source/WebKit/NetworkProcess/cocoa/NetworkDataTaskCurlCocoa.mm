/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "config.h"
#import "NetworkDataTaskCurlCocoa.h"
#import "DownloadProxyMessages.h"

// curl owns HTTP framing; Cocoa retains its native values, session and policy APIs.
#if PLATFORM(COCOA)

#import "LegacyCustomProtocolManager.h"
#import "AuthenticationManager.h"
#import "NetworkLoadParameters.h"
#import "NetworkProcess.h"
#import "NetworkSessionCocoa.h"
#import "PrivateRelayed.h"
#import "AuthenticationChallengeDisposition.h"
#import "Download.h"
#import "DownloadManager.h"
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <Security/Security.h>
#import <WebCore/AuthenticationChallenge.h>
#import <WebCore/CocoaCurlAuthentication.h>
#import <WebCore/CocoaCurlTransfer.h> // all Cocoa clients report the same curl metrics.
#import <WebCore/CertificateInfo.h>
#import <WebCore/CocoaCurlTLS.h>
#import <WebCore/CocoaCookie.h>
#import <WebCore/CocoaCurlMultipartHandle.h>
#import <WebCore/CocoaMIMESniffing.h>
#import <WebCore/Cookie.h>
#import <WebCore/CookieJar.h>
#import <WebCore/CredentialStorage.h>
#import <WebCore/NetworkStorageSession.h>
#import <WebCore/ProtectionSpace.h>
#import <WebCore/RegistrableDomain.h>
#import <WebCore/SameSiteInfo.h>
#import <WebCore/SecurityOrigin.h>
#import <pal/spi/cf/CFNetworkSPI.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <WebCore/HTTPParsers.h>
#import <WebCore/ParsedContentRange.h>
#import <WebCore/DNS.h>
#import <WebCore/ResourceError.h>
#import <WebCore/SharedBuffer.h>
#import <WebCore/CocoaDownloadTransport.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/MakeString.h>
#import <wtf/HexNumber.h>
#import <wtf/text/StringToIntegerConversion.h>
#import <wtf/text/StringView.h>
#import <wtf/text/StringBuilder.h>
#include <cmath>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(NetworkDataTaskCurlCocoa);


bool NetworkDataTaskCurlCocoa::canHandle(NetworkSession& session, const NetworkLoadParameters& parameters)
{
#if ENABLE(LEGACY_CUSTOM_PROTOCOL_MANAGER)
    if (auto* manager = session.networkProcess().supplement<LegacyCustomProtocolManager>(); manager && manager->supportsScheme(parameters.request.url().protocol().toString()))
        return false;
#endif
    return parameters.request.url().protocolIsInHTTPFamily();
}

Ref<NetworkDataTask> NetworkDataTaskCurlCocoa::create(NetworkSession& session, NetworkDataTaskClient& client, const NetworkLoadParameters& parameters)
{
    return adoptRef(*new NetworkDataTaskCurlCocoa(session, client, parameters));
}

NetworkDataTaskCurlCocoa::NetworkDataTaskCurlCocoa(NetworkSession& session, NetworkDataTaskClient& client, const NetworkLoadParameters& parameters)
    : NetworkDataTask(session, client, parameters.request, parameters.storedCredentialsPolicy, parameters.shouldClearReferrerOnHTTPSToHTTPRedirect, parameters.isMainFrameNavigation, parameters.isInitiatedByDedicatedWorker)
    , m_request(parameters.request)
    , m_frameID(parameters.webFrameID.asOptional())
    , m_pageID(parameters.webPageID.asOptional())
    , m_webPageProxyID(parameters.webPageProxyID.asOptional())
    , m_requiredCookiesVersion(parameters.requiredCookiesVersion)
    , m_shouldPreconnect(parameters.shouldPreconnectOnly != PreconnectOnly::No)
    , m_shouldSniff(parameters.contentSniffingPolicy == ContentSniffingPolicy::SniffContent)
    , m_isMainResource(parameters.mainResourceNavigationDataForAnyFrame.has_value())
{
    m_isNavigatingToAppBoundDomain = parameters.isNavigatingToAppBoundDomain;
    if (parameters.downloadResume) {
        m_resumeOffset = parameters.downloadResume->offset;
        m_downloadedBytes = *m_resumeOffset;
        m_pendingDownloadLocation = parameters.downloadResume->destination;
        m_downloadSandboxExtension = parameters.downloadResume->sandboxExtension;
        m_allowOverwriteDownload = true;
    }
    m_metrics.responseBodyBytesReceived = 0;
    m_metrics.responseBodyDecodedSize = 0;
    m_metrics.additionalNetworkLoadMetricsForWebInspector = AdditionalNetworkLoadMetricsForWebInspector::create();
    m_authUser = m_request.url().user();
    m_authPassword = m_request.url().password();
    m_request.removeCredentials();
    if (m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && !m_request.hasHTTPHeaderField(HTTPHeaderName::Authorization)) {
        if (auto* storage = session.networkStorageSession()) {
            m_initialCredential = storage->credentialStorage().get(m_partition, m_request.url());
            if (m_authUser.isEmpty() && !m_initialCredential.isEmpty()) {
                m_authUser = m_initialCredential.user();
                m_authPassword = m_initialCredential.password();
            }
        }
    }
    if (!m_authUser.isEmpty() || !m_authPassword.isEmpty())
        m_authMethod = CURLAUTH_BASIC;
}

NetworkDataTaskCurlCocoa::~NetworkDataTaskCurlCocoa()
{
    ASSERT(RunLoop::isMain());
    detachTransfer();
    if (m_downloadSandboxExtension)
        m_downloadSandboxExtension->revoke();
}








bool NetworkDataTaskCurlCocoa::cookiesBlocked()
{
    if (!m_request.allowCookies() || m_storedCredentialsPolicy == StoredCredentialsPolicy::EphemeralStateless)
        return true;
    if (auto* storage = m_session->networkStorageSession())
        m_cookieBlockingLatched |= storage->shouldBlockCookies(m_request, m_frameID, m_pageID, m_session->networkProcess().shouldRelaxThirdPartyCookieBlockingForPage(m_webPageProxyID), IsKnownCrossSiteTracker::No);
    return m_cookieBlockingLatched;
}

void NetworkDataTaskCurlCocoa::setup()
{
    // each new HTTP exchange observes current credential/privacy pool ownership, including a credential deletion during an earlier hop.
    m_scheduler = downcast<NetworkSessionCocoa>(*m_session).curlNetworkScheduler(m_webPageProxyID, m_request, m_storedCredentialsPolicy, m_isNavigatingToAppBoundDomain);
    if (std::exchange(m_generatedCookieHeader, false))
        m_request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (!cookiesBlocked() && !m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie)) {
        if (auto* storage = m_session->networkStorageSession()) {
            auto cookie = storage->cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), SameSiteInfo::create(m_request), m_request.url(), m_frameID, m_pageID, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, m_session->networkProcess().shouldRelaxThirdPartyCookieBlockingForPage(m_webPageProxyID), IsKnownCrossSiteTracker::No).first;
            if (!cookie.isEmpty()) {
                m_request.setHTTPHeaderField(HTTPHeaderName::Cookie, cookie);
                m_generatedCookieHeader = true;
            }
        }
    }
    CocoaCurlTransferOptions options;
    options.request = m_request;
    if (auto body = m_request.httpBody())
        options.upload = CocoaCurlUploadBody::create(*body, &m_session->blobRegistry());
    options.proxySettings = downcast<NetworkSessionCocoa>(*m_session).proxyConfiguration();
    options.acceptedCertificateChain = m_acceptedCertificateChain;
    // a certificate the user accepted for this host governs whether or not the host
    // is HSTS-known; the exception stays scoped to that exact host and chain.
    if (auto allowed = m_session->networkProcess().allowedHTTPSCertificateForHost(m_request.url().host().toString()))
        options.allowedServerTrust = allowed->trust();
    options.boundInterface = downcast<NetworkSessionCocoa>(*m_session).boundInterfaceIdentifier();
    options.user = m_authUser;
    options.password = m_authPassword;
    options.authentication = m_authMethod;
    options.proxyCredentialHost = m_proxyHost;
    options.proxyCredentialPort = m_proxyPort;
    options.proxyUser = m_proxyUser;
    options.proxyPassword = m_proxyPassword;
    options.proxyAuthentication = m_proxyAuthMethod;
    options.preconnect = m_shouldPreconnect;
    m_transfer = CocoaCurlConnection::create(*m_scheduler, *this, WTF::move(options));
    m_transfer->start();
}

void NetworkDataTaskCurlCocoa::setPriority(ResourceLoadPriority priority)
{
    m_request.setPriority(priority);
    if (m_transfer)
        m_transfer->setPriority(priority);
}

void NetworkDataTaskCurlCocoa::resume()
{
    ASSERT(RunLoop::isMain());
    if (m_failureScheduled || m_state != State::Suspended)
        return;
    if (!m_session || m_session->isInvalidated()) {
        cancel();
        return;
    }
    if (!m_metrics.fetchStart)
        m_metrics.fetchStart = MonotonicTime::now();
    if (auto* storage = m_session->networkStorageSession(); storage && storage->cookiesVersion() < m_requiredCookiesVersion) {
        storage->addCookiesVersionChangeCallback({ m_requiredCookiesVersion, [weakThis = ThreadSafeWeakPtr { *this }](auto reason) {
            if (reason == NetworkStorageSession::CookieVersionChangeCallback::Reason::VersionChange) {
                if (auto task = weakThis.get())
                    task->resume();
            }
        } });
        return;
    }
    auto& session = downcast<NetworkSessionCocoa>(*m_session);
    if (m_isMainResource && session.deviceManagementRestrictionsEnabled() && session.allLoadsBlockedByDeviceManagementRestrictionsForTesting()) {
        scheduleFailure(FailureType::RestrictedURL);
        return;
    }
    m_state = State::Running;
    m_scheduler = session.curlNetworkScheduler(m_webPageProxyID, m_request, m_storedCredentialsPolicy, m_isNavigatingToAppBoundDomain);
    restrictRequestReferrerToOriginIfNeeded(m_request);
    start();
}

void NetworkDataTaskCurlCocoa::start()
{
    if (m_state != State::Running)
        return;
    auto* storage = m_session->networkStorageSession();
    bool ignoreDynamicHSTS = m_storedCredentialsPolicy == StoredCredentialsPolicy::EphemeralStateless || (storage && storage->shouldBlockCookies(m_request, m_frameID, m_pageID, m_session->networkProcess().shouldRelaxThirdPartyCookieBlockingForPage(m_webPageProxyID), IsKnownCrossSiteTracker::No));
    if (m_request.url().protocolIs("http"_s) && !ignoreDynamicHSTS && downcast<NetworkSessionCocoa>(*m_session).httpStrictTransportSecurityStore().shouldUpgrade(m_request.url())) {
        URL secureURL = m_request.url();
        secureURL.setProtocol("https"_s);
        if (secureURL.port() == 80)
            secureURL.setPort(std::nullopt);
        m_response = ResourceResponse(URL { m_request.url() }, String(), 0, String());
        m_status = 307;
        m_response.setHTTPStatusCode(m_status);
        m_response.setHTTPHeaderField(HTTPHeaderName::Location, secureURL.string());
        m_waitingForPolicy = true;
        redirect();
        return;
    }
    setup();
}






void NetworkDataTaskCurlCocoa::cancel()
{
    m_cancelled = true;
    if (m_state == State::Completed)
        return;
    m_state = State::Canceling;
    finish(NSURLErrorCancelled, "Load cancelled"_s);
}

void NetworkDataTaskCurlCocoa::invalidateAndCancel()
{
    cancel();
}







// enforce native cookie and tracking policy at every final header section, including authentication.
void NetworkDataTaskCurlCocoa::curlReceivedCookies(Vector<String>&& fields, CompletionHandler<void(std::optional<String>&&)>&& completion)
{
    auto* storage = m_session->networkStorageSession();
    if (m_state != State::Running || !storage || cookiesBlocked()) {
        completion(std::nullopt);
        return;
    }
    auto sameSite = SameSiteInfo::create(m_request);
    for (const auto& field : fields) {
        auto cookie = parseHTTPSetCookie(field, m_request.url());
        if (cookie && (cookie->sameSite == Cookie::SameSitePolicy::None || sameSite.isSameSite || sameSite.isTopSite))
            storage->setCookie(*cookie, m_request.url(), m_request.firstPartyForCookies());
    }
    if (m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie) && !m_generatedCookieHeader) {
        completion(std::nullopt);
        return;
    }
    auto value = storage->cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), sameSite, m_request.url(), m_frameID, m_pageID, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, m_session->networkProcess().shouldRelaxThirdPartyCookieBlockingForPage(m_webPageProxyID), IsKnownCrossSiteTracker::No).first;
    completion(WTF::move(value));
}


void NetworkDataTaskCurlCocoa::continueAfterHeaders()
{
    if (m_state != State::Running)
        return;
    if (m_serverTrust && m_storedCredentialsPolicy != StoredCredentialsPolicy::EphemeralStateless) {
        SecTrustResultType trustResult = kSecTrustResultInvalid;
        if (SecTrustGetTrustResult(m_serverTrust.get(), &trustResult) == errSecSuccess && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified))
            downcast<NetworkSessionCocoa>(*m_session).httpStrictTransportSecurityStore().receiveHeader(m_request.url(), m_response.httpHeaderField("Strict-Transport-Security"_s));
    }
    if (m_response.isRedirection() && !m_response.httpHeaderField(HTTPHeaderName::Location).isEmpty()) {
        redirect();
        return;
    }
    if (m_status == 401 && !m_authResponseApproved) {
        authenticate(false);
        return;
    }
    if (m_status == 407 && !m_proxyResponseApproved) {
        authenticate(true);
        return;
    }
    publishResponse();
}

void NetworkDataTaskCurlCocoa::redirect()
{
    if (m_redirectCount >= ResourceLoaderOptions { }.maxRedirectCount) {
        finish(NSURLErrorHTTPTooManyRedirects, "Too many HTTP redirects"_s);
        return;
    }
    auto location = m_response.httpHeaderField(HTTPHeaderName::Location);
    // Location is a byte sequence; retain invalid UTF-8 octets as percent escapes.
    StringBuilder encodedLocation;
    for (auto byte : asBytes(location.latin1().span())) {
        if (byte >= 0x80)
            encodedLocation.append('%', upperNibbleToASCIIHexDigit(byte), lowerNibbleToASCIIHexDigit(byte));
        else
            encodedLocation.append(static_cast<char>(byte));
    }
    URL url { m_request.url(), encodedLocation.toString() };
    if (!url.isValid() || !url.protocolIsInHTTPFamily()) {
        finish(NSURLErrorUnsupportedURL, "Redirect target is not an HTTP URL"_s);
        return;
    }
    if (!url.hasFragmentIdentifier())
        url.setFragmentIdentifier(m_request.url().fragmentIdentifier());
    ResourceRequest request = m_request;
    // The first-party latch quirk NetworkTaskCocoa applies on its redirects un-blocks cookies for the
    // continuing request here as well.
    if (m_cookieBlockingLatched && m_storedCredentialsPolicy != StoredCredentialsPolicy::EphemeralStateless
        && NetworkTaskCocoa::needsFirstPartyCookieBlockingLatchModeQuirk(m_request.firstPartyForCookies(), url, m_request.url()))
        m_cookieBlockingLatched = false;
    request.setURL(URL { url });
    auto method = request.httpMethod();
    if ((m_status == 303 && method != "GET"_s && method != "HEAD"_s) || ((m_status == 301 || m_status == 302) && method == "POST"_s)) {
        request.setHTTPMethod("GET"_s);
        request.setHTTPBody(nullptr);
        for (auto name : { HTTPHeaderName::ContentLength, HTTPHeaderName::ContentType, HTTPHeaderName::ContentEncoding, HTTPHeaderName::ContentLanguage, HTTPHeaderName::ContentLocation, HTTPHeaderName::TransferEncoding })
            request.removeHTTPHeaderField(name);
    }
    if (m_shouldClearReferrerOnHTTPSToHTTPRedirect && !url.protocolIs("https"_s) && request.httpReferrer().startsWithIgnoringASCIICase("https:"_s))
        request.clearHTTPReferrer();
    if (!SecurityOrigin::create(url)->isSameOriginAs(SecurityOrigin::create(m_request.url()).get())) {
        request.removeHTTPHeaderField(HTTPHeaderName::Authorization);
        request.removeHTTPHeaderField(HTTPHeaderName::Origin);
        request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
        m_authMethod = CURLAUTH_NONE;
        m_authUser = emptyString();
        m_authPassword = emptyString();
        m_acceptedCertificateChain = nullptr;
        m_metrics.hasCrossOriginRedirect = true;
    }
    ++m_redirectCount;
    if (RefPtr client = m_client.get()) {
        client->willPerformHTTPRedirection(ResourceResponse(m_response), WTF::move(request), [protectedThis = Ref { *this }](ResourceRequest&& approved) {
            if (protectedThis->m_state != State::Running)
                return;
            if (approved.isNull()) {
                protectedThis->cancel();
                return;
            }
            protectedThis->restart(WTF::move(approved));
        });
    } else
        cancel();
}

void NetworkDataTaskCurlCocoa::authenticate(bool proxy)
{
    long available = proxy ? m_availableProxyAuthentication : m_availableAuthentication;
    long method = cocoaCurlAuthenticationMethod(available);
    if (!method) {
        publishResponse();
        return;
    }
    auto space = cocoaCurlProtectionSpace(m_request.url(), proxy ? m_proxyHost : emptyString(), m_proxyPort, method, m_response.httpHeaderField(proxy ? "Proxy-Authenticate"_s : "WWW-Authenticate"_s));
    auto nativeSpace = retainPtr(space.nsSpace());
    unsigned& failures = proxy ? m_proxyAuthFailureCount : m_authFailureCount;
    auto& previousSpace = proxy ? m_lastProxyAuthenticationSpace : m_lastAuthenticationSpace;
    if (previousSpace && *previousSpace != space)
        failures = 0;
    previousSpace = space;
    if (m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && (failures || (!proxy && !m_initialCredential.isEmpty()))) {
        auto& user = proxy ? m_proxyUser : m_authUser;
        auto& password = proxy ? m_proxyPassword : m_authPassword;
        if (auto* storage = m_session->networkStorageSession()) {
            auto rejected = storage->credentialStorage().get(m_partition, space);
            if (rejected.user() == user && rejected.password() == password)
                storage->credentialStorage().remove(m_partition, space);
        }
        RetainPtr nativeStorage = downcast<NetworkSessionCocoa>(*m_session).nsCredentialStorage();
        RetainPtr rejected = [nativeStorage defaultCredentialForProtectionSpace:nativeSpace.get()];
        if (rejected && String(rejected.get().user) == user && String(rejected.get().password) == password)
            [nativeStorage removeCredential:rejected.get() forProtectionSpace:nativeSpace.get()];
    }
    Credential proposed;
    if (m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && !failures) {
        if (auto* storage = m_session->networkStorageSession())
            proposed = storage->credentialStorage().get(m_partition, space);
        if (proposed.isEmpty())
            proposed = Credential([downcast<NetworkSessionCocoa>(*m_session).nsCredentialStorage() defaultCredentialForProtectionSpace:nativeSpace.get()]);
    }
    AuthenticationChallenge challenge(space, proposed, failures, m_response, { });
    auto answer = [protectedThis = Ref { *this }, proxy, method, space, nativeSpace](AuthenticationChallengeDisposition disposition, const Credential& credential) {
        if (protectedThis->m_state != State::Running)
            return;
        if (disposition == AuthenticationChallengeDisposition::Cancel) {
            protectedThis->finish(NSURLErrorUserCancelledAuthentication, "Authentication cancelled"_s);
            return;
        }
        auto& attempts = proxy ? protectedThis->m_proxyAuthFailureCount : protectedThis->m_authFailureCount;
        bool useKerberosCache = disposition == AuthenticationChallengeDisposition::PerformDefaultHandling && method == CURLAUTH_NEGOTIATE
            && protectedThis->m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && !attempts;
        if (useKerberosCache || (disposition == AuthenticationChallengeDisposition::UseCredential && !credential.isEmpty())) {
            auto& count = proxy ? protectedThis->m_proxyAuthFailureCount : protectedThis->m_authFailureCount;
            ++count;
            (proxy ? protectedThis->m_proxyAuthMethod : protectedThis->m_authMethod) = method;
            (proxy ? protectedThis->m_proxyUser : protectedThis->m_authUser) = credential.user();
            (proxy ? protectedThis->m_proxyPassword : protectedThis->m_authPassword) = credential.password();
            if (protectedThis->m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && credential.persistence() != CredentialPersistence::None) {
                if (auto* storage = protectedThis->m_session->networkStorageSession())
                    storage->credentialStorage().set(protectedThis->m_partition, Credential(credential.user(), credential.password(), CredentialPersistence::None), space, protectedThis->m_request.url());
                if (credential.persistence() == CredentialPersistence::Permanent)
                    [downcast<NetworkSessionCocoa>(*protectedThis->m_session).nsCredentialStorage() setDefaultCredential:credential.nsCredential() forProtectionSpace:nativeSpace.get()];
            }
            protectedThis->restart(ResourceRequest(protectedThis->m_request));
            return;
        }
        (proxy ? protectedThis->m_proxyResponseApproved : protectedThis->m_authResponseApproved) = true;
        protectedThis->publishResponse();
    };
    if (!proposed.isEmpty()) {
        answer(AuthenticationChallengeDisposition::UseCredential, proposed);
        return;
    }
    if (RefPtr client = m_client.get())
        client->didReceiveChallenge(WTF::move(challenge), NegotiatedLegacyTLS::No, WTF::move(answer));
    else if (m_isDownloadSink) {
        if (auto download = m_session->networkProcess().downloadManager().download(*m_pendingDownloadID))
            download->didReceiveChallenge(challenge, WTF::move(answer));
    } else
        cancel();
}

void NetworkDataTaskCurlCocoa::challengeServerTrust()
{
    // the challenge is raised for an HSTS-known host too; the user's decision governs.
    m_waitingForPolicy = true;
    auto space = cocoaCurlTLSProtectionSpace(m_request.url(), 8, nullptr, m_serverTrust.get());
    if (!space) {
        finish(NSURLErrorServerCertificateUntrusted, "Could not construct a certificate challenge"_s);
        return;
    }
    AuthenticationChallenge challenge(ProtectionSpace(space.get()), { }, 0, m_response, { });
    auto answer = [protectedThis = Ref { *this }](AuthenticationChallengeDisposition disposition, const Credential&) {
        if (protectedThis->m_state != State::Running)
            return;
        if (disposition != AuthenticationChallengeDisposition::UseCredential) {
            protectedThis->finish(NSURLErrorServerCertificateUntrusted, "The server certificate is not trusted"_s);
            return;
        }
        protectedThis->m_acceptedCertificateChain = protectedThis->m_tlsState->peerChain;
        protectedThis->restart(ResourceRequest(protectedThis->m_request));
    };
    if (RefPtr client = m_client.get())
        client->didReceiveChallenge(WTF::move(challenge), NegotiatedLegacyTLS::No, WTF::move(answer));
    else
        finish(NSURLErrorServerCertificateUntrusted, "The server certificate is not trusted"_s);
}

void NetworkDataTaskCurlCocoa::restart(ResourceRequest&& request)
{
    detachTransfer();
    if (!request.url().isValid() || !request.url().protocolIsInHTTPFamily()) {
        finish(NSURLErrorUnsupportedURL, "Invalid HTTP redirect target"_s);
        return;
    }
    if (!portAllowed(request.url()) || isIPAddressDisallowed(request.url())) {
        finish(NSURLErrorCannotConnectToHost, "The redirect target is blocked by URL policy"_s);
        return;
    }
    if (!SecurityOrigin::create(request.url())->isSameOriginAs(SecurityOrigin::create(m_request.url()).get())) {
        m_authMethod = CURLAUTH_NONE;
        m_authUser = emptyString();
        m_authPassword = emptyString();
        m_authFailureCount = 0;
        m_acceptedCertificateChain = nullptr;
    }
    if (!request.url().user().isEmpty() || !request.url().password().isEmpty()) {
        m_authUser = request.url().user();
        m_authPassword = request.url().password();
        m_authMethod = CURLAUTH_BASIC;
    }
    if (m_storedCredentialsPolicy == StoredCredentialsPolicy::Use && m_authUser.isEmpty() && m_authPassword.isEmpty() && !request.hasHTTPHeaderField(HTTPHeaderName::Authorization)) {
        if (auto* storage = m_session->networkStorageSession()) {
            m_initialCredential = storage->credentialStorage().get(request.cachePartition(), request.url());
            if (!m_initialCredential.isEmpty()) {
                m_authUser = m_initialCredential.user();
                m_authPassword = m_initialCredential.password();
                m_authMethod = CURLAUTH_BASIC;
            }
        }
    }
    request.removeCredentials();
    m_request = WTF::move(request);
    m_previousRequest = m_request;
    m_lastHTTPMethod = m_request.httpMethod();
    m_partition = m_request.cachePartition();
    m_serverTrust = nullptr;
    m_authResponseApproved = false;
    m_proxyResponseApproved = false;
    restrictRequestReferrerToOriginIfNeeded(m_request);
    m_result.reset();
    m_finalHeaders = false;
    m_waitingForPolicy = false;
    m_useResponse = false;
    m_pendingData = nullptr;
    m_response = { };
    m_status = 0;
    m_sniffPrefix.clear();
    m_responseNeedsSniff = false;
    m_scheduler = downcast<NetworkSessionCocoa>(*m_session).curlNetworkScheduler(m_webPageProxyID, m_request, m_storedCredentialsPolicy, m_isNavigatingToAppBoundDomain);
    start();
}

void NetworkDataTaskCurlCocoa::publishResponse()
{
    if (m_state != State::Running)
        return;
    if (m_responseNeedsSniff && !m_result) {
        continueTransfer();
        return;
    }
    m_waitingForPolicy = true;
    auto& address = m_metrics.additionalNetworkLoadMetricsForWebInspector->remoteAddress;
    auto resolvedAddress = IPAddress::fromString(address);
    // The metrics NetworkResourceLoader reads for Navigation and Resource Timing, as
    // NetworkSessionCocoa and NetworkDataTaskCurl both attach them.
    m_response.setDeprecatedNetworkLoadMetrics(Box<NetworkLoadMetrics>::create(m_metrics));
    didReceiveResponse(ResourceResponse(m_response), NegotiatedLegacyTLS::No, PrivateRelayed::No, resolvedAddress, [weakThis = ThreadSafeWeakPtr { *this }](PolicyAction policy) {
        if (auto task = weakThis.get())
            task->decidePolicy(policy);
    });
}

void NetworkDataTaskCurlCocoa::decidePolicy(PolicyAction policy)
{
    ASSERT(RunLoop::isMain());
    if (m_state != State::Running)
        return;
    m_waitingForPolicy = false;
    if (policy == PolicyAction::Ignore) {
        cancel();
        return;
    }
    if (policy == PolicyAction::Download) {
        if (m_resumeOffset) {
            ParsedContentRange range(m_response.httpHeaderField(HTTPHeaderName::ContentRange));
            if (!validateCocoaCurlResumeResponse(m_response, *m_resumeOffset, m_request.httpHeaderField(HTTPHeaderName::IfRange))) {
                finish(NSURLErrorBadServerResponse, "The server returned an inconsistent download representation"_s);
                return;
            }
            m_downloadFile = FileSystem::openFile(m_pendingDownloadLocation, FileSystem::FileOpenMode::ReadWrite);
            if (!m_downloadFile || m_downloadFile.size() != m_resumeOffset) {
                finish(NSURLErrorCannotOpenFile, "The partial download changed before resuming"_s);
                return;
            }
            if (m_status == 200) {
                if (!m_downloadFile.truncate(0)) {
                    finish(NSURLErrorCannotWriteToFile, "Could not replace the changed download representation"_s);
                    return;
                }
                m_downloadedBytes = 0;
            }
            if (m_downloadFile.seek(m_downloadedBytes, FileSystem::FileSeekOrigin::Beginning) != m_downloadedBytes) {
                finish(NSURLErrorCannotWriteToFile, "Could not seek to the download continuation"_s);
                return;
            }
            if (m_status == 206 && range.instanceLength() != ParsedContentRange::unknownLength)
                m_downloadExpectedBytes = range.instanceLength();
        } else
            m_downloadFile = FileSystem::openFile(m_pendingDownloadLocation, FileSystem::FileOpenMode::Truncate, FileSystem::FileAccessPermission::All, { }, !m_allowOverwriteDownload);
        if (!m_downloadFile) {
            finish(NSURLErrorCannotCreateFile, "Could not open the download destination"_s);
            return;
        }
        m_isDownloadSink = true;
        if (!m_downloadExpectedBytes)
            m_downloadExpectedBytes = m_response.expectedContentLength() >= 0 ? m_downloadedBytes + m_response.expectedContentLength() : std::numeric_limits<uint64_t>::max();
        auto& manager = m_session->networkProcess().downloadManager();
        Ref download = Download::create(manager, *m_pendingDownloadID, *this, *m_session, suggestedFilename());
        download->setSandboxExtension(WTF::move(m_downloadSandboxExtension));
        manager.dataTaskBecameDownloadTask(*m_pendingDownloadID, download.copyRef());
        if (m_resumeOffset) {
            if (RefPtr connection = manager.downloadProxyConnection())
                connection->send(Messages::DownloadProxy::DidResumeWithResponse(m_response, m_downloadedBytes), *m_pendingDownloadID);
        }
        download->didCreateDestination(m_pendingDownloadLocation);
    }
    m_useResponse = true;
    if (!m_isDownloadSink)
        m_multipart = createCocoaCurlMultipartHandle(*this, m_response);
    if (!m_sniffPrefix.isEmpty()) {
        m_pendingData = SharedBuffer::create(std::exchange(m_sniffPrefix, { }));
        deliverData();
        return;
    }
    continueTransfer();
}



void NetworkDataTaskCurlCocoa::deliverData()
{
    if (m_state != State::Running)
        return;
    auto data = std::exchange(m_pendingData, nullptr);
    m_metrics.responseBodyDecodedSize += data->size();
    if (m_isDownloadSink) {
        auto written = m_downloadFile.write(data->span());
        if (!written || *written != data->size()) {
            finish(NSURLErrorCannotWriteToFile, "Could not write the download"_s);
            return;
        }
        m_downloadedBytes += *written;
        if (auto download = m_session->networkProcess().downloadManager().download(*m_pendingDownloadID))
            download->didReceiveData(*written, m_downloadedBytes, m_downloadExpectedBytes);
    } else if (m_multipart) {
        m_multipart->didReceiveMessage(data->span());
        if (m_multipart->hasError()) {
            finish(NSURLErrorCannotParseResponse, "Invalid multipart response"_s);
            return;
        }
    } else if (RefPtr client = m_client.get())
        client->didReceiveData(*data);
    else {
        cancel();
        return;
    }
    if (m_state != State::Running)
        return;
    if (m_waitingForMultipartPolicy)
        return;
    continueTransfer();
}

void NetworkDataTaskCurlCocoa::didReceiveHeaderFromMultipart(Vector<String>&& fields)
{
    ResourceResponse response = m_response;
    for (const auto& field : fields) {
        auto colon = field.find(':');
        if (colon == notFound)
            continue;
        auto name = field.left(colon);
        auto value = field.substring(colon + 1).trim(deprecatedIsSpaceOrNewline);
        if (!isValidHTTPToken(name) || !isValidHTTPHeaderValue(value)) {
            finish(NSURLErrorCannotParseResponse, "Invalid multipart header"_s);
            return;
        }
        response.setHTTPHeaderField(name, value);
    }
    auto contentType = response.httpHeaderField(HTTPHeaderName::ContentType);
    response.setMimeType(extractMIMETypeFromMediaType(contentType));
    response.setTextEncodingName(extractCharsetFromMediaType(contentType).toString());
    m_waitingForMultipartPolicy = true;
    // The parser enters WaitingForHeaderProcessing after returning from this callback.
    response.setDeprecatedNetworkLoadMetrics(Box<NetworkLoadMetrics>::create(m_metrics));
    RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }, response = WTF::move(response)]() mutable {
        if (protectedThis->m_state != State::Running)
            return;
        protectedThis->didReceiveResponse(WTF::move(response), NegotiatedLegacyTLS::No, PrivateRelayed::No, std::nullopt, [protectedThis](PolicyAction policy) {
            if (protectedThis->m_state != State::Running)
                return;
            if (policy != PolicyAction::Use) {
                protectedThis->cancel();
                return;
            }
            protectedThis->m_waitingForMultipartPolicy = false;
            protectedThis->m_multipart->completeHeaderProcessing();
            if (protectedThis->m_multipart->hasError()) {
                protectedThis->finish(NSURLErrorCannotParseResponse, "Invalid multipart response"_s);
                return;
            }
            if (protectedThis->m_state != State::Running || protectedThis->m_waitingForMultipartPolicy)
                return;
            protectedThis->continueTransfer();
        });
    });
}

void NetworkDataTaskCurlCocoa::didReceiveDataFromMultipart(std::span<const uint8_t> bytes)
{
    if (m_state == State::Running) {
        if (RefPtr client = m_client.get())
            client->didReceiveData(SharedBuffer::create(bytes).get());
    }
}

void NetworkDataTaskCurlCocoa::didCompleteFromMultipart()
{
    if (m_result && m_result->isNull())
        finish(0, emptyString());
}



void NetworkDataTaskCurlCocoa::setPendingDownloadLocation(const String& path, SandboxExtension::Handle&& handle, bool allowOverwrite)
{
    NetworkDataTask::setPendingDownloadLocation(path, { }, allowOverwrite);
    m_allowOverwriteDownload = allowOverwrite;
    m_downloadSandboxExtension = SandboxExtension::create(WTF::move(handle));
    if (m_downloadSandboxExtension && !m_downloadSandboxExtension->consume())
        finish(NSURLErrorNoPermissionsToReadFile, "The download destination could not be authorized"_s);
}

String NetworkDataTaskCurlCocoa::suggestedFilename() const
{
    return m_suggestedFilename.isEmpty() ? m_response.suggestedFilename() : m_suggestedFilename;
}

Vector<uint8_t> NetworkDataTaskCurlCocoa::downloadResumeData() const
{
    auto encoding = m_response.httpHeaderField(HTTPHeaderName::ContentEncoding);
    auto entityTag = m_response.httpHeaderField(HTTPHeaderName::ETag);
    auto lastModified = m_response.httpHeaderField(HTTPHeaderName::LastModified);
    // byte-range resume must reproduce the representation; its metadata cannot discard a request body.
    if (!m_downloadedBytes || m_request.httpMethod() != "GET"_s || m_request.httpBody() || (!encoding.isEmpty() && !equalIgnoringASCIICase(encoding, "identity"_s)) || ((entityTag.isEmpty() || entityTag.startsWith("W/"_s)) && lastModified.isEmpty()))
        return { };
    auto values = adoptNS([@{
        @"NSURLSessionResumeInfoVersion": @1,
        @"WebKitRequest": cocoaDownloadRequestInformation(m_request, m_generatedCookieHeader).get(),
        @"WebKitStorageSessionIdentifier": @(m_session->sessionID().toUInt64()),
        // private/credential-free/stateless resume retains its original policy.
        @"WebKitStoredCredentialsPolicy": m_storedCredentialsPolicy == StoredCredentialsPolicy::Use ? @"use" : m_storedCredentialsPolicy == StoredCredentialsPolicy::DoNotUse ? @"do-not-use" : @"ephemeral-stateless",
        @"WebKitFirstPartyForCookies": m_request.firstPartyForCookies().string().createNSString().get(),
        @"WebKitIsTopSite": @(m_request.isTopSite()),
        @"WebKitSameSiteDisposition": m_request.sameSiteDisposition() == ResourceRequest::SameSiteDisposition::SameSite ? @"same-site" : m_request.sameSiteDisposition() == ResourceRequest::SameSiteDisposition::CrossSite ? @"cross-site" : @"unspecified",
        @"NSURLSessionDownloadURL": m_request.url().string().createNSString().get(),
        @"NSURLSessionResumeBytesReceived": @(m_downloadedBytes),
        @"NSURLSessionResumeInfoLocalPath": m_pendingDownloadLocation.createNSString().get(),
        @"NSURLSessionResumeEntityTag": m_response.httpHeaderField(HTTPHeaderName::ETag).createNSString().get(),
        @"NSURLSessionResumeServerDownloadDate": m_response.httpHeaderField(HTTPHeaderName::LastModified).createNSString().get()
    } mutableCopy]);
    auto data = [NSPropertyListSerialization dataWithPropertyList:values.get() format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return makeVector(data);
}

void NetworkDataTaskCurlCocoa::cancelWithResumeData(CompletionHandler<void(std::span<const uint8_t>)>&& completion)
{
    auto data = downloadResumeData();
    m_isDownloadSink = false;
    m_downloadFile = { };
    clearClient();
    cancel();
    completion(data.span());
}

// retain native trust/signing/transport metadata while keeping local policy and file errors native.
void NetworkDataTaskCurlCocoa::finish(int errorCode, const String& description, const ResourceError& originalError)
{
    ASSERT(RunLoop::isMain());
    Ref protectedThis { *this };
    if (m_state == State::Completed)
        return;
    m_state = State::Completed;
    detachTransfer();
    // report durable file-write failures before completing a download.
    String failureDescription = description;
    if (!errorCode && m_isDownloadSink && m_resumeOffset && !validateCocoaCurlCompletedResume(m_response, m_downloadedBytes)) {
        errorCode = NSURLErrorNetworkConnectionLost;
        failureDescription = "The resumed response did not complete the download representation"_s;
    }
    if (!errorCode && m_downloadFile && !m_downloadFile.flush()) {
        errorCode = NSURLErrorCannotWriteToFile;
        failureDescription = "Could not flush the download destination"_s;
    }
    m_downloadFile = { };
    m_pendingData = nullptr;
    m_metrics.responseEnd = MonotonicTime::now();
    m_metrics.markComplete();
    ResourceError error = originalError;
    if (errorCode && error.isNull()) {
        auto url = m_request.url().createNSURL();
        auto userInfo = adoptNS([@{
            NSURLErrorFailingURLStringErrorKey: m_request.url().string().createNSString().get(),
            NSLocalizedDescriptionKey: failureDescription.createNSString().get()
        } mutableCopy]);
        if (url)
            [userInfo setObject:url.get() forKey:NSURLErrorFailingURLErrorKey];
        if (m_serverTrust)
            [userInfo setObject:(id)m_serverTrust.get() forKey:NSURLErrorFailingURLPeerTrustErrorKey];
        error = ResourceError([NSError errorWithDomain:NSURLErrorDomain code:errorCode userInfo:userInfo.get()]);
    }
    RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }, error = WTF::move(error)] {
        if (protectedThis->m_isDownloadSink && protectedThis->m_session) {
            if (auto download = protectedThis->m_session->networkProcess().downloadManager().download(*protectedThis->m_pendingDownloadID)) {
                if (error.isNull())
                    download->didFinish();
                else {
                    auto data = protectedThis->downloadResumeData();
                    download->didFail(error, data.span());
                }
            }
        } else if (RefPtr client = protectedThis->m_client.get())
            client->didCompleteWithError(error, protectedThis->m_metrics);
    });
}

// browser policy stays on main; response parsing, uploads and trust evaluation run in the session's curl worker.
void NetworkDataTaskCurlCocoa::detachTransfer()
{
    if (auto transfer = std::exchange(m_transfer, nullptr))
        transfer->invalidateClient();
    if (m_continueTransfer)
        std::exchange(m_continueTransfer, nullptr)();
}

void NetworkDataTaskCurlCocoa::updateMetrics(const NetworkLoadMetrics& metrics)
{
    auto fetchStart = m_metrics.fetchStart;
    auto decoded = m_metrics.responseBodyDecodedSize;
    bool failedTAO = m_metrics.failsTAOCheck;
    bool crossedOrigin = m_metrics.hasCrossOriginRedirect;
    m_metrics = metrics.isolatedCopy();
    m_metrics.fetchStart = fetchStart;
    m_metrics.responseBodyDecodedSize = decoded;
    m_metrics.failsTAOCheck = failedTAO;
    m_metrics.hasCrossOriginRedirect = crossedOrigin;
    m_metrics.redirectCount = m_redirectCount;
    setBytesTransferredOverNetwork(m_metrics.responseBodyBytesReceived);
}

void NetworkDataTaskCurlCocoa::curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion)
{
    if (m_state != State::Running) {
        completion();
        return;
    }
    ASSERT(!m_continueTransfer);
    m_continueTransfer = WTF::move(completion);
    updateMetrics(response.metrics);
    m_response = WTF::move(response.response);
    m_status = m_response.httpStatusCode();
    m_availableAuthentication = response.authentication;
    m_availableProxyAuthentication = response.proxyAuthentication;
    if (m_proxyHost != response.proxyHost || m_proxyPort != response.proxyPort) {
        m_proxyAuthMethod = CURLAUTH_NONE;
        m_proxyUser = emptyString();
        m_proxyPassword = emptyString();
        m_proxyAuthFailureCount = 0;
        m_lastProxyAuthenticationSpace = std::nullopt;
    }
    m_proxyHost = WTF::move(response.proxyHost);
    m_proxyPort = response.proxyPort;
    m_tlsState = m_transfer->tlsState();
    m_serverTrust = m_tlsState ? m_tlsState->trust : nullptr;
    auto type = m_response.httpHeaderField(HTTPHeaderName::ContentType);
    m_noSniff = !m_shouldSniff || equalLettersIgnoringASCIICase(m_response.httpHeaderField(HTTPHeaderName::XContentTypeOptions), "nosniff"_s);
    m_responseNeedsSniff = m_status != 204 && m_status != 304 && m_request.httpMethod() != "HEAD"_s && MIMESniffer::needsHTTPContentSniffing(type, m_noSniff);
    m_finalHeaders = true;
    continueAfterHeaders();
}

void NetworkDataTaskCurlCocoa::curlReceivedInformationalResponse(ResourceResponse&& response)
{
    if (m_state == State::Running)
        didReceiveInformationalResponse(WTF::move(response));
}

void NetworkDataTaskCurlCocoa::curlReceivedData(const SharedBuffer& data, CompletionHandler<void()>&& completion)
{
    if (m_state != State::Running) {
        completion();
        return;
    }
    ASSERT(!m_continueTransfer);
    m_continueTransfer = WTF::move(completion);
    if (m_responseNeedsSniff) {
        m_sniffPrefix.append(data.span());
        if (m_sniffPrefix.size() < MIMESniffer::resourceHeaderSize) {
            continueTransfer();
            return;
        }
        m_response.setMimeType(MIMESniffer::computeHTTPMIMEType(m_sniffPrefix.span().first(MIMESniffer::resourceHeaderSize), m_response.httpHeaderField(HTTPHeaderName::ContentType), m_noSniff));
        m_responseNeedsSniff = false;
        publishResponse();
        return;
    }
    ASSERT(m_useResponse);
    m_pendingData = &data;
    deliverData();
}

void NetworkDataTaskCurlCocoa::curlSentData(uint64_t sent, uint64_t total)
{
    if (m_state == State::Running) {
        if (RefPtr client = m_client.get())
            client->didSendData(sent, total);
    }
}

void NetworkDataTaskCurlCocoa::curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion)
{
    auto native = cocoaCurlTLSProtectionSpace(m_request.url(), 7, authorities, nullptr);
    if (!native || m_state != State::Running) {
        completion(nullptr, nullptr);
        if (!native)
            finish(NSURLErrorClientCertificateRejected, "Could not construct a client certificate challenge"_s);
        return;
    }
    AuthenticationChallenge challenge(ProtectionSpace(native.get()), { }, 0, m_response, { });
    auto answer = [protectedThis = Ref { *this }, completion = WTF::move(completion)](AuthenticationChallengeDisposition disposition, const Credential& credential) mutable {
        if (disposition == AuthenticationChallengeDisposition::UseCredential && protectedThis->m_state == State::Running)
            completion(retainPtr((SecIdentityRef)credential.nsCredential().identity), retainPtr((CFArrayRef)credential.nsCredential().certificates));
        else
            completion(nullptr, nullptr);
        if (disposition == AuthenticationChallengeDisposition::Cancel)
            protectedThis->cancel();
    };
    if (RefPtr client = m_client.get())
        client->didReceiveChallenge(WTF::move(challenge), NegotiatedLegacyTLS::No, WTF::move(answer));
    else if (m_isDownloadSink) {
        if (auto download = m_session->networkProcess().downloadManager().download(*m_pendingDownloadID))
            download->didReceiveChallenge(challenge, WTF::move(answer));
        else
            answer(AuthenticationChallengeDisposition::Cancel, { });
    } else
        answer(AuthenticationChallengeDisposition::Cancel, { });
}

void NetworkDataTaskCurlCocoa::curlCompleted(const ResourceError& error, const NetworkLoadMetrics& metrics)
{
    if (m_state != State::Running)
        return;
    updateMetrics(metrics);
    m_tlsState = m_transfer->tlsState();
    m_serverTrust = m_tlsState ? m_tlsState->trust : nullptr;
    if (error.errorCode() == NSURLErrorServerCertificateUntrusted && m_serverTrust && !m_acceptedCertificateChain) {
        challengeServerTrust();
        return;
    }
    m_result = error;
    // preserve response policy and the received sniffing prefix on an incomplete body, then deliver its transport error.
    if (m_responseNeedsSniff) {
        m_response.setMimeType(MIMESniffer::computeHTTPMIMEType(m_sniffPrefix.span(), m_response.httpHeaderField(HTTPHeaderName::ContentType), m_noSniff));
        m_responseNeedsSniff = false;
        publishResponse();
        return;
    }
    continueTransfer();
}

void NetworkDataTaskCurlCocoa::continueTransfer()
{
    if (m_state != State::Running || m_waitingForPolicy || m_waitingForMultipartPolicy)
        return;
    if (m_continueTransfer) {
        std::exchange(m_continueTransfer, nullptr)();
        return;
    }
    if (!m_result)
        return;
    if (!m_result->isNull()) {
        finish(m_result->errorCode(), m_result->localizedDescription(), *m_result);
        return;
    }
    if (m_multipart) {
        m_multipart->didCompleteMessage();
        if (m_multipart->hasError())
            finish(NSURLErrorCannotParseResponse, "Invalid multipart response"_s);
        return;
    }
    finish(m_finalHeaders || m_shouldPreconnect ? 0 : NSURLErrorBadServerResponse, "Missing HTTP response"_s);
}

} // namespace WebKit

#endif
