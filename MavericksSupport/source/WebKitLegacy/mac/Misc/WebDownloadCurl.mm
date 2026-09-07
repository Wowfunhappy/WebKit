/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import "WebDownloadCurl.h"

// Safari's NSURLDownload subclass delegates HTTP and resume to WebCore's curl transport.
#import "NetworkStorageSessionMap.h"
#import "WebNSFileManagerExtras.h"
#import <WebKitLegacy/WebDownload.h>
#import <WebCore/CocoaCurlAuthentication.h>
#import <WebCore/CocoaCurlConnection.h>
#import <WebCore/CocoaCurlResourceHandle.h>
#import <WebCore/CocoaCookie.h>
#import <WebCore/Cookie.h>
#import <WebCore/CookieJar.h>
#import <WebCore/Credential.h>
#import <WebCore/CredentialStorage.h>
#import <WebCore/NetworkStorageSession.h>
#import <WebCore/HTTPStrictTransportSecurityStore.h>
#import <WebCore/ResourceError.h>
#import <WebCore/ResourceLoaderOptions.h>
#import <WebCore/SameSiteInfo.h>
#import <WebCore/SecurityOrigin.h>
#import <WebCore/SharedBuffer.h>
#import <wtf/FileSystem.h>
#import <wtf/FileHandle.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RefCounted.h>
#import <wtf/text/MakeString.h>
#include <zlib.h>

using namespace WebCore;

class WebDownloadCurlClient final : public RefCounted<WebDownloadCurlClient>, public CocoaCurlTransferClient {
public:
    static Ref<WebDownloadCurlClient> create(WebDownloadCurl *controller, WebDownload *download, id delegate, NSURLRequest *request, NSDictionary *resume, NSString *path, NSString *directory)
    {
        Ref client = adoptRef(*new WebDownloadCurlClient(controller, download, delegate, request, resume, path, directory));
        client->m_startedFromRequest = true;
        return client;
    }
    ~WebDownloadCurlClient()
    {
        if (m_transfer)
            m_transfer->invalidateClient();
        if (m_inflateInitialized)
            inflateEnd(&m_inflate);
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    static Ref<WebDownloadCurlClient> create(WebDownloadCurl* controller, WebDownload* download, id delegate, CocoaCurlDownloadTransfer&& transfer)
    {
        Ref client = adoptRef(*new WebDownloadCurlClient(controller, download, delegate, transfer.request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody), nil, nil, nil));
        client->m_storage = transfer.storage;
        client->m_storageID = transfer.storage->sessionID();
        client->m_pool = WTF::move(transfer.pool);
        client->m_request = WTF::move(transfer.request);
        client->m_generatedCookieHeader = transfer.generatedCookieHeader;
        client->m_allowCredentials = transfer.allowStoredCredentials;
        client->m_transfer = WTF::move(transfer.connection);
        client->m_transfer->setClient(client);
        // finished short bodies still carry their actual completion/error after response policy and buffered-data delivery.
        CompletionHandler<void()> continuation = [client, completion = WTF::move(transfer.completion), result = WTF::move(transfer.result), metrics = transfer.response.metrics]() mutable {
            if (completion)
                completion();
            if (result && !client->m_finished)
                client->curlCompleted(*result, metrics);
        };
        client->m_adoptedResponse = WTF::move(transfer.response);
        client->m_adoptedCompletion = [client, data = WTF::move(transfer.bufferedData), completion = WTF::move(continuation)]() mutable {
            if (!client->m_finished && !data.isEmpty())
                client->curlReceivedData(SharedBuffer::create(WTF::move(data)), WTF::move(completion));
            else
                completion();
        };
        return client;
    }
    void start();
    void cancel();
    void setDestination(NSString *, bool);
    // directory configuration is independent of an explicit destination, as in native NSURLDownload.
    NSString* directoryPath() const { return m_directory.get(); }
    void setDirectoryPath(NSString* path) { m_directory = path; }
    NSURLRequest *request() const { return m_request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody); }
    RetainPtr<NSDictionary> resumeInformation() const;
    bool deletesFileUponFailure() const { return m_deleteOnFailure; }
    void setDeletesFileUponFailure(bool value) { m_deleteOnFailure = value; }
    void answer(NSURLAuthenticationChallenge *, NSURLCredential *, bool cancel, bool useDefault);
private:
    WebDownloadCurlClient(WebDownloadCurl *controller, WebDownload *download, id delegate, NSURLRequest *request, NSDictionary *resume, NSString *path, NSString *directory)
        : m_controller(controller), m_download(download), m_delegate(delegate), m_request(request), m_resume(resume), m_path(path), m_directory(directory) { }
    void beginTransfer();
    void detachTransfer();
    void finish(NSError *, bool cancelled = false);
    void fail(NSInteger, NSString *);
    void challenge(NSURLProtectionSpace *, NSUInteger failures, NSURLCredential *, Function<void(NSURLCredential *, bool, bool)>&&);
    void authenticate(bool, long);
    void redirect();
    void prepareDestination();
    bool write(std::span<const uint8_t>);
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&&) final;
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) final;
    void curlReceivedInformationalResponse(ResourceResponse&&) final { }
    void curlReceivedData(const SharedBuffer&, CompletionHandler<void()>&&) final;
    void curlSentData(uint64_t, uint64_t) final { }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) final;
    void curlCompleted(const ResourceError&, const NetworkLoadMetrics&) final;

    WebDownloadCurl *m_controller;
    RetainPtr<WebDownload> m_download;
    RetainPtr<id> m_delegate;
    ResourceRequest m_request;
    RetainPtr<NSDictionary> m_resume;
    RetainPtr<NSString> m_path;
    RetainPtr<NSString> m_directory;
    RetainPtr<NSURLAuthenticationChallenge> m_challenge;
    Function<void(NSURLCredential *, bool, bool)> m_challengeAnswer;
    RefPtr<CocoaCurlConnection> m_transfer;
    RefPtr<CocoaCurlConnectionPool> m_pool;
    WeakPtr<NetworkStorageSession> m_storage;
    PAL::SessionID m_storageID { PAL::SessionID::defaultSessionID() };
    std::optional<CocoaCurlTransferResponse> m_adoptedResponse;
    CompletionHandler<void()> m_adoptedCompletion;
    CocoaCurlTransferResponse m_response;
    std::optional<CompletionHandler<void()>> m_responseCompletion;
    FileSystem::FileHandle m_file;
    RetainPtr<CFArrayRef> m_acceptedChain;
    String m_user;
    String m_password;
    String m_proxyUser;
    String m_proxyPassword;
    long m_auth { CURLAUTH_NONE };
    long m_proxyAuth { CURLAUTH_NONE };
    unsigned m_authFailures { 0 };
    unsigned m_proxyFailures { 0 };
    std::optional<ProtectionSpace> m_authSpace;
    std::optional<ProtectionSpace> m_proxySpace;
    uint64_t m_received { 0 };
    unsigned m_redirects { 0 };
    z_stream m_inflate { };
    bool m_inflateInitialized { false };
    bool m_inflateEnded { false };
    bool m_started { false };
    bool m_startedFromRequest { false };
    bool m_finished { false };
    bool m_deleteOnFailure { true };
    bool m_allowOverwrite { false };
    bool m_responsePrepared { false };
    bool m_createdDestination { false };
    bool m_generatedCookieHeader { false };
    bool m_allowCredentials { true };
};

void WebDownloadCurlClient::start()
{
    if (m_started || m_finished)
        return;
    Ref protectedThis { *this };
    m_started = true;
    if ([m_delegate respondsToSelector:@selector(downloadDidBegin:)])
        [m_delegate downloadDidBegin:m_download.get()];
    if (m_finished)
        return;
    if (m_adoptedResponse) {
        auto response = WTF::move(*m_adoptedResponse);
        m_adoptedResponse.reset();
        curlReceivedResponse(WTF::move(response), std::exchange(m_adoptedCompletion, nullptr));
        return;
    }
    if (id identifier = [m_resume objectForKey:@"WebKitStorageSessionIdentifier"]) {
        if (![identifier isKindOfClass:[NSNumber class]] || !PAL::SessionID::isValidSessionIDValue([identifier unsignedLongLongValue])) {
            fail(NSURLErrorCannotOpenFile, @"Invalid download storage session identifier");
            return;
        }
        m_storageID = PAL::SessionID([identifier unsignedLongLongValue]);
    }
    if (id allowed = [m_resume objectForKey:@"WebKitAllowStoredCredentials"]) {
        if (![allowed isKindOfClass:[NSNumber class]]) {
            fail(NSURLErrorCannotOpenFile, @"Invalid download credential policy");
            return;
        }
        m_allowCredentials = [allowed boolValue];
    }
    m_storage = NetworkStorageSessionMap::storageSession(m_storageID);
    if (!m_storage) {
        fail(NSURLErrorCancelled, @"The download's original storage session is no longer available");
        return;
    }
    if (m_resume) {
        id url = [m_resume objectForKey:@"NSURLDownloadURL"];
        id offset = [m_resume objectForKey:@"NSURLDownloadBytesReceived"];
        if (![url isKindOfClass:[NSString class]] || ![offset isKindOfClass:[NSNumber class]] || [offset longLongValue] < 0 || !m_path) {
            fail(NSURLErrorCannotOpenFile, @"Invalid download resume information");
            return;
        }
        m_received = [offset unsignedLongLongValue];
        m_request = ResourceRequest(URL { String((NSString *)url) });
        if (!restoreCocoaDownloadRequestInformation(m_request, [m_resume objectForKey:@"WebKitRequest"])) {
            fail(NSURLErrorCannotOpenFile, @"Invalid resumed request properties");
            return;
        }
        if (id firstParty = [m_resume objectForKey:@"WebKitFirstPartyForCookies"]) {
            if (![firstParty isKindOfClass:[NSString class]]) {
                fail(NSURLErrorCannotOpenFile, @"Invalid download cookie context");
                return;
            }
            m_request.setFirstPartyForCookies(URL { String((NSString *)firstParty) });
        }
        if (id sameSite = [m_resume objectForKey:@"WebKitSameSiteDisposition"]) {
            if ([sameSite isEqual:@"same-site"])
                m_request.setSameSiteDisposition(ResourceRequest::SameSiteDisposition::SameSite);
            else if ([sameSite isEqual:@"cross-site"])
                m_request.setSameSiteDisposition(ResourceRequest::SameSiteDisposition::CrossSite);
            else if (![sameSite isEqual:@"unspecified"]) {
                fail(NSURLErrorCannotOpenFile, @"Invalid download SameSite context");
                return;
            }
        }
        if (id topSite = [m_resume objectForKey:@"WebKitIsTopSite"]) {
            if (![topSite isKindOfClass:[NSNumber class]]) {
                fail(NSURLErrorCannotOpenFile, @"Invalid download navigation context");
                return;
            }
            m_request.setIsTopSite([topSite boolValue]);
        }
        m_request.setHTTPHeaderField(HTTPHeaderName::Range, makeString("bytes="_s, m_received, '-'));
        id etag = [m_resume objectForKey:@"NSURLDownloadEntityTag"];
        id modified = [m_resume objectForKey:@"NSURLDownloadServerModificationDate"];
        if ([etag isKindOfClass:[NSString class]] && ![etag hasPrefix:@"W/"])
            m_request.setHTTPHeaderField(HTTPHeaderName::IfRange, String((NSString *)etag));
        else if ([modified isKindOfClass:[NSString class]])
            m_request.setHTTPHeaderField(HTTPHeaderName::IfRange, String((NSString *)modified));
        else {
            fail(NSURLErrorCannotOpenFile, @"The partial download has no representation validator");
            return;
        }
        m_file = FileSystem::openFile(String(m_path.get()), FileSystem::FileOpenMode::ReadWrite);
        if (!m_file || m_file.size() != m_received) {
            fail(NSURLErrorCannotOpenFile, @"The partial download has changed");
            return;
        }
        m_createdDestination = true;
    }
    if ([m_delegate respondsToSelector:@selector(download:willSendRequest:redirectResponse:)]) {
        RetainPtr approved = [m_delegate download:m_download.get() willSendRequest:request() redirectResponse:nil];
        if (m_finished)
            return;
        if (!approved) {
            cancel();
            return;
        }
        m_request = ResourceRequest(approved.get());
    }
    beginTransfer();
}

void WebDownloadCurlClient::detachTransfer()
{
    if (auto transfer = std::exchange(m_transfer, nullptr))
        transfer->invalidateClient();
    if (auto completion = std::exchange(m_responseCompletion, std::nullopt))
        (*completion)();
    m_responsePrepared = false;
}

void WebDownloadCurlClient::beginTransfer()
{
    if (m_finished)
        return;
    detachTransfer();
    if (!m_request.url().isValid() || !m_request.url().protocolIsInHTTPFamily()) {
        fail(NSURLErrorUnsupportedURL, @"The download URL is not an HTTP URL");
        return;
    }
    if (!m_storage) {
        fail(NSURLErrorCancelled, @"The download's storage session has closed");
        return;
    }
    auto& storage = *m_storage;
    if (m_request.url().protocolIs("http"_s) && storage.httpStrictTransportSecurityStore().shouldUpgrade(m_request.url())) {
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
    if (std::exchange(m_generatedCookieHeader, false))
        m_request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (m_request.allowCookies() && !m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie)) {
        auto value = storage.cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), SameSiteInfo::create(m_request), m_request.url(), std::nullopt, std::nullopt, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
        if (!value.isEmpty()) {
            m_request.setHTTPHeaderField(HTTPHeaderName::Cookie, value);
            m_generatedCookieHeader = true;
        }
    }
    m_pool = &storage.cocoaCurlConnectionPool(m_allowCredentials);
    Ref scheduler { *m_pool };
    CocoaCurlTransferOptions options;
    options.request = m_request;
    if (auto body = m_request.httpBody())
        options.upload = CocoaCurlUploadBody::create(*body);
    options.acceptedCertificateChain = m_acceptedChain;
    options.user = m_user;
    options.password = m_password;
    options.authentication = m_auth;
    options.proxyCredentialHost = m_response.proxyHost;
    options.proxyCredentialPort = m_response.proxyPort;
    options.proxyUser = m_proxyUser;
    options.proxyPassword = m_proxyPassword;
    options.proxyAuthentication = m_proxyAuth;
    m_transfer = CocoaCurlConnection::create(scheduler.get(), *this, WTF::move(options));
    m_transfer->start();
}

// a download keeps the same per-response native cookie policy as a document load.
void WebDownloadCurlClient::curlReceivedCookies(Vector<String>&& fields, CompletionHandler<void(std::optional<String>&&)>&& completion)
{
    if (m_finished || !m_storage) {
        completion(std::nullopt);
        return;
    }
    auto& storage = *m_storage;
    if (m_request.allowCookies()) {
        auto sameSite = SameSiteInfo::create(m_request);
        for (auto& field : fields) {
            auto cookie = parseHTTPSetCookie(field, m_request.url());
            if (cookie && (cookie->sameSite == Cookie::SameSitePolicy::None || sameSite.isSameSite || sameSite.isTopSite))
                storage.setCookie(*cookie, m_request.url(), m_request.firstPartyForCookies());
        }
    }
    if (!m_request.allowCookies() || (m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie) && !m_generatedCookieHeader)) {
        completion(std::nullopt);
        return;
    }
    auto value = storage.cookieRequestHeaderFieldValue(m_request.firstPartyForCookies(), SameSiteInfo::create(m_request), m_request.url(), std::nullopt, std::nullopt, m_request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
    completion(WTF::move(value));
}
void WebDownloadCurlClient::curlReceivedResponse(CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion)
{
    m_response = WTF::move(response);
    auto tls = m_transfer->tlsState();
    SecTrustResultType trustResult = kSecTrustResultInvalid;
    if (m_storage && tls && tls->trust && SecTrustGetTrustResult(tls->trust.get(), &trustResult) == errSecSuccess && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified))
        m_storage->httpStrictTransportSecurityStore().receiveHeader(m_request.url(), m_response.response.httpHeaderField("Strict-Transport-Security"_s));
    m_responseCompletion = WTF::move(completion);
    if (!m_storage) {
        fail(NSURLErrorCancelled, @"The download's storage session has closed");
        return;
    }
    auto& storage = *m_storage;
    if (m_request.url().protocolIs("http"_s) && storage.httpStrictTransportSecurityStore().shouldUpgrade(m_request.url())) {
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
    int status = m_response.response.httpStatusCode();
    if (m_response.response.isRedirection() && !m_response.response.httpHeaderField(HTTPHeaderName::Location).isEmpty()) {
        redirect();
        return;
    }
    if (status == 401 || status == 407) {
        bool proxy = status == 407;
        long method = cocoaCurlAuthenticationMethod(proxy ? m_response.proxyAuthentication : m_response.authentication);
        if (method) {
            authenticate(proxy, method);
            return;
        }
    }
    // Stock NSURLDownload, measured on this host: a download started from a request fails a 404, 410
    // or 500 with NSURLErrorFileDoesNotExist; a response adopted from a navigation is saved whatever
    // its status.
    if (m_startedFromRequest && status >= 400) {
        fail(NSURLErrorFileDoesNotExist, @"The server rejected the download request");
        return;
    }
    if (m_resume) {
        if (!validateCocoaCurlResumeResponse(m_response.response, m_received, m_request.httpHeaderField(HTTPHeaderName::IfRange))) {
            fail(NSURLErrorBadServerResponse, @"The server returned an inconsistent download range");
            return;
        }
        if (status == 200) {
            if (!m_file.truncate(0)) {
                fail(NSURLErrorCannotWriteToFile, @"Could not replace the changed download representation");
                return;
            }
            m_received = 0;
        }
        if (m_file.seek(m_received, FileSystem::FileSeekOrigin::Beginning) != m_received) {
            fail(NSURLErrorCannotWriteToFile, @"Could not seek to the download continuation");
            return;
        }
        if ([m_delegate respondsToSelector:@selector(download:willResumeWithResponse:fromByte:)])
            [m_delegate download:m_download.get() willResumeWithResponse:m_response.response.nsURLResponse() fromByte:m_received];
    } else if ([m_delegate respondsToSelector:@selector(download:didReceiveResponse:)])
        [m_delegate download:m_download.get() didReceiveResponse:m_response.response.nsURLResponse()];
    if (m_finished)
        return;
    auto mime = m_response.response.mimeType();
    if (!m_resume && (equalIgnoringASCIICase(mime, "application/x-gzip"_s) || equalIgnoringASCIICase(mime, "application/gzip"_s)) && [m_delegate respondsToSelector:@selector(download:shouldDecodeSourceDataOfMIMEType:)] && [m_delegate download:m_download.get() shouldDecodeSourceDataOfMIMEType:mime.createNSString().get()]) {
        if (inflateInit2(&m_inflate, MAX_WBITS + 16) != Z_OK) {
            fail(NSURLErrorCannotDecodeContentData, @"Could not initialize the gzip decoder");
            return;
        }
        m_inflateInitialized = true;
    }
    if (m_finished)
        return;
    m_responsePrepared = true;
    prepareDestination();
}

void WebDownloadCurlClient::redirect()
{
    if (m_redirects >= ResourceLoaderOptions { }.maxRedirectCount) {
        fail(NSURLErrorHTTPTooManyRedirects, @"Too many HTTP redirects");
        return;
    }
    ResourceRequest redirected = m_request;
    URL target { m_request.url(), m_response.response.httpHeaderField(HTTPHeaderName::Location) };
    if (!target.hasFragmentIdentifier())
        target.setFragmentIdentifier(m_request.url().fragmentIdentifier());
    redirected.setURL(WTF::move(target));
    auto status = m_response.response.httpStatusCode();
    auto method = redirected.httpMethod();
    if ((status == 303 && method != "GET"_s && method != "HEAD"_s) || ((status == 301 || status == 302) && method == "POST"_s)) {
        redirected.setHTTPMethod("GET"_s);
        redirected.setHTTPBody(nullptr);
        for (auto header : { HTTPHeaderName::ContentLength, HTTPHeaderName::ContentType, HTTPHeaderName::ContentEncoding, HTTPHeaderName::ContentLanguage, HTTPHeaderName::ContentLocation, HTTPHeaderName::TransferEncoding })
            redirected.removeHTTPHeaderField(header);
    }
    if (m_request.url().protocolIs("https"_s) && !redirected.url().protocolIs("https"_s))
        redirected.clearHTTPReferrer();
    if (!SecurityOrigin::create(redirected.url())->isSameOriginAs(SecurityOrigin::create(m_request.url()).get())) {
        redirected.removeHTTPHeaderField(HTTPHeaderName::Authorization);
        redirected.removeHTTPHeaderField(HTTPHeaderName::Cookie);
        redirected.removeHTTPHeaderField(HTTPHeaderName::Origin);
    }
    if ([m_delegate respondsToSelector:@selector(download:willSendRequest:redirectResponse:)]) {
        RetainPtr approved = [m_delegate download:m_download.get() willSendRequest:redirected.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody) redirectResponse:m_response.response.nsURLResponse()];
        if (m_finished)
            return;
        if (!approved) {
            cancel();
            return;
        }
        redirected = ResourceRequest(approved.get());
    }
    if (!SecurityOrigin::create(redirected.url())->isSameOriginAs(SecurityOrigin::create(m_request.url()).get())) {
        m_user = { };
        m_password = { };
        m_auth = CURLAUTH_NONE;
        m_authFailures = 0;
        m_acceptedChain = nullptr;
    }
    ++m_redirects;
    m_request = WTF::move(redirected);
    beginTransfer();
}

void WebDownloadCurlClient::challenge(NSURLProtectionSpace *space, NSUInteger failures, NSURLCredential *proposed, Function<void(NSURLCredential *, bool, bool)>&& answer)
{
    m_challengeAnswer = WTF::move(answer);
    m_challenge = adoptNS([[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:proposed previousFailureCount:failures failureResponse:m_response.response.nsURLResponse() error:nil sender:m_controller]);
    if ([m_delegate respondsToSelector:@selector(download:didReceiveAuthenticationChallenge:)])
        [m_delegate download:m_download.get() didReceiveAuthenticationChallenge:m_challenge.get()];
    else
        this->answer(m_challenge.get(), nil, false, true);
}

void WebDownloadCurlClient::answer(NSURLAuthenticationChallenge *challenge, NSURLCredential *credential, bool cancel, bool useDefault)
{
    Ref protectedThis { *this };
    if (challenge != m_challenge || !m_challengeAnswer)
        return;
    auto answer = std::exchange(m_challengeAnswer, { });
    m_challenge = nullptr;
    answer(credential, cancel, useDefault);
}

void WebDownloadCurlClient::authenticate(bool proxy, long method)
{
    auto space = cocoaCurlProtectionSpace(m_request.url(), proxy ? m_response.proxyHost : emptyString(), m_response.proxyPort, method, m_response.response.httpHeaderField(proxy ? "Proxy-Authenticate"_s : "WWW-Authenticate"_s));
    auto& previousSpace = proxy ? m_proxySpace : m_authSpace;
    auto& failures = proxy ? m_proxyFailures : m_authFailures;
    if (previousSpace && *previousSpace != space)
        failures = 0;
    previousSpace = space;
    if (!m_storage) {
        fail(NSURLErrorCancelled, @"The download's storage session has closed");
        return;
    }
    auto& storage = m_storage->credentialStorage();
    RetainPtr nativeSpace = space.nsSpace();
    RetainPtr<NSURLCredential> proposed;
    if (m_allowCredentials && !failures) {
        proposed = storage.get(m_request.cachePartition(), space).nsCredential();
        if (!proposed && !m_storageID.isEphemeral())
            proposed = [[NSURLCredentialStorage sharedCredentialStorage] defaultCredentialForProtectionSpace:nativeSpace.get()];
    } else if (m_allowCredentials) {
        auto rejected = storage.get(m_request.cachePartition(), space);
        if (rejected.user() == (proxy ? m_proxyUser : m_user) && rejected.password() == (proxy ? m_proxyPassword : m_password))
            storage.remove(m_request.cachePartition(), space);
    }
    challenge(nativeSpace.get(), failures, proposed.get(), [protectedThis = Ref { *this }, proxy, method, space, nativeSpace](NSURLCredential *credential, bool cancelled, bool useDefault) {
        if (protectedThis->m_finished)
            return;
        if (cancelled) {
            protectedThis->fail(NSURLErrorUserCancelledAuthentication, @"Authentication cancelled");
            return;
        }
        auto& failures = proxy ? protectedThis->m_proxyFailures : protectedThis->m_authFailures;
        bool kerberos = useDefault && method == CURLAUTH_NEGOTIATE && protectedThis->m_allowCredentials && !failures;
        if (!credential && !kerberos) {
            protectedThis->fail(NSURLErrorUserAuthenticationRequired, @"The download requires authentication");
            return;
        }
        ++failures;
        (proxy ? protectedThis->m_proxyAuth : protectedThis->m_auth) = method;
        (proxy ? protectedThis->m_proxyUser : protectedThis->m_user) = String(credential.user);
        (proxy ? protectedThis->m_proxyPassword : protectedThis->m_password) = String(credential.password);
        if (credential && credential.persistence != NSURLCredentialPersistenceNone && protectedThis->m_allowCredentials && protectedThis->m_storage) {
            protectedThis->m_storage->credentialStorage().set(protectedThis->m_request.cachePartition(), Credential(credential), space, protectedThis->m_request.url());
            if (credential.persistence == NSURLCredentialPersistencePermanent && !protectedThis->m_storageID.isEphemeral())
                [[NSURLCredentialStorage sharedCredentialStorage] setDefaultCredential:credential forProtectionSpace:nativeSpace.get()];
        }
        protectedThis->beginTransfer();
    });
}

void WebDownloadCurlClient::curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion)
{
    auto space = cocoaCurlTLSProtectionSpace(m_request.url(), 7, authorities, nullptr);
    if (!space) {
        completion(nullptr, nullptr);
        return;
    }
    challenge(space.get(), 0, nil, [protectedThis = Ref { *this }, completion = WTF::move(completion)](NSURLCredential *credential, bool cancelled, bool) mutable {
        completion(retainPtr(credential.identity), retainPtr((__bridge CFArrayRef)credential.certificates));
        if (cancelled && !protectedThis->m_finished)
            protectedThis->fail(NSURLErrorUserCancelledAuthentication, @"Client certificate selection cancelled");
    });
}

void WebDownloadCurlClient::setDestination(NSString *path, bool allowOverwrite)
{
    Ref protectedThis { *this };
    if (m_finished || m_createdDestination)
        return;
    m_path = path;
    m_allowOverwrite = allowOverwrite;
    if (m_responsePrepared)
        prepareDestination();
}

void WebDownloadCurlClient::prepareDestination()
{
    if (!m_path) {
        String filename = m_response.response.suggestedFilename();
        if (m_inflateInitialized && filename.endsWithIgnoringASCIICase(".gz"_s))
            filename = filename.left(filename.length() - 3);
        if ([m_delegate respondsToSelector:@selector(download:decideDestinationWithSuggestedFilename:)]) {
            [m_delegate download:m_download.get() decideDestinationWithSuggestedFilename:filename.createNSString().get()];
            return;
        }
        NSString *directory = m_directory.get() ?: NSTemporaryDirectory();
        m_path = [[NSFileManager defaultManager] _webkit_pathWithUniqueFilenameForPath:[directory stringByAppendingPathComponent:filename.createNSString().get()]];
    }
    if (m_finished || !m_responseCompletion)
        return;
    if (!m_createdDestination) {
        m_file = FileSystem::openFile(String(m_path.get()), FileSystem::FileOpenMode::Truncate, FileSystem::FileAccessPermission::All, { }, !m_allowOverwrite);
        if (!m_file) {
            fail(NSURLErrorCannotCreateFile, @"Could not create the download destination");
            return;
        }
        m_createdDestination = true;
        if ([m_delegate respondsToSelector:@selector(download:didCreateDestination:)])
            [m_delegate download:m_download.get() didCreateDestination:m_path.get()];
    }
    if (m_finished)
        return;
    if (auto completion = std::exchange(m_responseCompletion, std::nullopt))
        (*completion)();
}

bool WebDownloadCurlClient::write(std::span<const uint8_t> bytes)
{
    auto written = m_file.write(bytes);
    if (!written || *written != bytes.size()) {
        fail(NSURLErrorCannotWriteToFile, @"Could not write the download");
        return false;
    }
    m_received += *written;
    if ([m_delegate respondsToSelector:@selector(download:didReceiveDataOfLength:)])
        [m_delegate download:m_download.get() didReceiveDataOfLength:*written];
    return !m_finished;
}

void WebDownloadCurlClient::curlReceivedData(const SharedBuffer& buffer, CompletionHandler<void()>&& completion)
{
    if (!m_inflateInitialized) {
        write(buffer.span());
        completion();
        return;
    }
    m_inflate.next_in = const_cast<Bytef *>(buffer.span().data());
    m_inflate.avail_in = buffer.size();
    do {
        if (m_inflateEnded) {
            if (inflateReset2(&m_inflate, MAX_WBITS + 16) != Z_OK) {
                fail(NSURLErrorCannotDecodeContentData, @"Could not initialize the next gzip member");
                break;
            }
            m_inflateEnded = false;
        }
        std::array<uint8_t, 16384> output;
        m_inflate.next_out = output.data();
        m_inflate.avail_out = output.size();
        int result = inflate(&m_inflate, Z_NO_FLUSH);
        if (result == Z_BUF_ERROR && !m_inflate.avail_in && m_inflate.avail_out == output.size())
            break;
        if (result != Z_OK && result != Z_STREAM_END) {
            fail(NSURLErrorCannotDecodeContentData, @"The gzip download is damaged");
            break;
        }
        m_inflateEnded = result == Z_STREAM_END;
        if (!write(std::span(output).first(output.size() - m_inflate.avail_out)))
            break;
        if (m_inflateEnded && !m_inflate.avail_in)
            break;
    } while (m_inflate.avail_in || !m_inflate.avail_out);
    completion();
}

void WebDownloadCurlClient::curlCompleted(const ResourceError& error, const NetworkLoadMetrics&)
{
    if (m_finished)
        return;
    auto tls = m_transfer->tlsState();
    if (!error.isNull() && tls && tls->evaluated && !tls->accepted && tls->trust && !m_acceptedChain) {
        // the challenge is raised for an HSTS-known host too; the user's decision governs.
        auto space = cocoaCurlTLSProtectionSpace(m_request.url(), 8, nullptr, tls->trust.get());
        if (space) {
            challenge(space.get(), 0, nil, [protectedThis = Ref { *this }, tls, error](NSURLCredential *credential, bool cancelled, bool) {
                if (protectedThis->m_finished)
                    return;
                if (!credential || cancelled) {
                    protectedThis->finish(error.nsError());
                    return;
                }
                protectedThis->m_acceptedChain = tls->peerChain;
                protectedThis->beginTransfer();
            });
            return;
        }
    }
    if (!error.isNull()) {
        finish(error.nsError());
        return;
    }
    if (m_resume && !validateCocoaCurlCompletedResume(m_response.response, m_received)) {
        fail(NSURLErrorNetworkConnectionLost, @"The resumed response did not complete the download representation");
        return;
    }
    if (m_inflateInitialized && !m_inflateEnded) {
        fail(NSURLErrorCannotDecodeContentData, @"The gzip download ended before its trailer");
        return;
    }
    if (m_file && !m_file.flush()) {
        fail(NSURLErrorCannotWriteToFile, @"Could not flush the download destination");
        return;
    }
    finish(nil);
}

RetainPtr<NSDictionary> WebDownloadCurlClient::resumeInformation() const
{
    auto encoding = m_response.response.httpHeaderField(HTTPHeaderName::ContentEncoding);
    // a body-dependent GET cannot be reconstructed by native byte-range resume metadata.
    if (!m_createdDestination || !m_received || m_request.httpMethod() != "GET"_s || m_request.httpBody() || m_inflateInitialized || (!encoding.isEmpty() && !equalIgnoringASCIICase(encoding, "identity"_s)))
        return nullptr;
    auto etag = m_response.response.httpHeaderField(HTTPHeaderName::ETag);
    auto modified = m_response.response.httpHeaderField(HTTPHeaderName::LastModified);
    if ((etag.isEmpty() || etag.startsWith("W/"_s)) && modified.isEmpty())
        return nullptr;
    auto result = adoptNS([[NSMutableDictionary alloc] init]);
    [result setObject:m_request.url().string().createNSString().get() forKey:@"NSURLDownloadURL"];
    [result setObject:cocoaDownloadRequestInformation(m_request, m_generatedCookieHeader).get() forKey:@"WebKitRequest"];
    [result setObject:@(m_received) forKey:@"NSURLDownloadBytesReceived"];
    [result setObject:@(m_storageID.toUInt64()) forKey:@"WebKitStorageSessionIdentifier"];
    [result setObject:@(m_allowCredentials) forKey:@"WebKitAllowStoredCredentials"];
    [result setObject:m_request.firstPartyForCookies().string().createNSString().get() forKey:@"WebKitFirstPartyForCookies"];
    [result setObject:@(m_request.isTopSite()) forKey:@"WebKitIsTopSite"];
    NSString* sameSite = m_request.sameSiteDisposition() == ResourceRequest::SameSiteDisposition::SameSite ? @"same-site" : m_request.sameSiteDisposition() == ResourceRequest::SameSiteDisposition::CrossSite ? @"cross-site" : @"unspecified";
    [result setObject:sameSite forKey:@"WebKitSameSiteDisposition"];
    if (!etag.isEmpty())
        [result setObject:etag.createNSString().get() forKey:@"NSURLDownloadEntityTag"];
    if (!modified.isEmpty())
        [result setObject:modified.createNSString().get() forKey:@"NSURLDownloadServerModificationDate"];
    return result;
}

void WebDownloadCurlClient::fail(NSInteger code, NSString *description)
{
    auto information = adoptNS([[NSMutableDictionary alloc] initWithObjectsAndKeys:description, NSLocalizedDescriptionKey, nil]);
    if (NSURL *url = [NSURL URLWithString:m_request.url().string().createNSString().get()])
        [information setObject:url forKey:NSURLErrorFailingURLErrorKey];
    finish([NSError errorWithDomain:NSURLErrorDomain code:code userInfo:information.get()]);
}

void WebDownloadCurlClient::cancel()
{
    finish(nil, true);
}

void WebDownloadCurlClient::finish(NSError *error, bool cancelled)
{
    Ref protectedThis { *this };
    if (std::exchange(m_finished, true))
        return;
    detachTransfer();
    if (m_adoptedCompletion)
        std::exchange(m_adoptedCompletion, nullptr)();
    m_adoptedResponse.reset();
    if (m_challengeAnswer) {
        auto answer = std::exchange(m_challengeAnswer, { });
        m_challenge = nullptr;
        answer(nil, true, false);
    }
    m_file = { };
    if ((error || cancelled) && m_deleteOnFailure && m_createdDestination)
        FileSystem::deleteFile(String(m_path.get()));
    if (!cancelled) {
        if (error && [m_delegate respondsToSelector:@selector(download:didFailWithError:)])
            [m_delegate download:m_download.get() didFailWithError:error];
        else if (!error && [m_delegate respondsToSelector:@selector(downloadDidFinish:)])
            [m_delegate downloadDidFinish:m_download.get()];
    }
    m_delegate = nullptr;
    m_download = nullptr;
}

@implementation WebDownloadCurl
- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate request:(NSURLRequest *)request resumeInformation:(NSDictionary *)resume path:(NSString *)path directory:(NSString *)directory
{
    if (!(self = [super init]))
        return nil;
    _client = WebDownloadCurlClient::create(self, download, delegate, request, resume, path, directory);
    return self;
}
- (instancetype)initWithDownload:(WebDownload *)download delegate:(id)delegate transfer:(WebCore::CocoaCurlDownloadTransfer&&)transfer
{
    if (!(self = [super init]))
        return nil;
    _client = WebDownloadCurlClient::create(self, download, delegate, WTF::move(transfer));
    return self;
}
- (void)start { _client->start(); }
- (void)cancel { _client->cancel(); }
- (void)setDestination:(NSString *)path allowOverwrite:(BOOL)allowOverwrite { _client->setDestination(path, allowOverwrite); }
// retain the native directory SPI through the curl client.
- (NSString *)directoryPath { return _client->directoryPath(); }
- (void)setDirectoryPath:(NSString *)path { _client->setDirectoryPath(path); }
- (NSURLRequest *)request { return _client->request(); }
- (NSDictionary *)resumeInformation { return _client->resumeInformation().autorelease(); }
- (NSData *)resumeData
{
    auto information = _client->resumeInformation();
    if (!information)
        return nil;
    return [NSPropertyListSerialization dataWithPropertyList:information.get() format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}
- (BOOL)deletesFileUponFailure { return _client->deletesFileUponFailure(); }
- (void)setDeletesFileUponFailure:(BOOL)value { _client->setDeletesFileUponFailure(value); }
- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { _client->answer(challenge, credential, false, false); }
- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { _client->answer(challenge, nil, false, false); }
- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { _client->answer(challenge, nil, true, false); }
- (void)performDefaultHandlingForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { _client->answer(challenge, nil, false, true); }
- (void)rejectProtectionSpaceAndContinueWithChallenge:(NSURLAuthenticationChallenge *)challenge { _client->answer(challenge, nil, false, false); }
@end
