/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "config.h"
#import "WebSocketTaskCurlCocoa.h"

#import "AuthenticationChallengeDisposition.h"
#import "AuthenticationManager.h"
#import "LegacyExtensionNetwork.h"
#import "NetworkConnectionToWebProcess.h"
#import "NetworkDataTaskCurlCocoa.h"
#import "NetworkProcess.h"
#import "NetworkSessionCocoa.h"
#import "NetworkSocketChannel.h"
#import <CFNetwork/CFNetwork.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <GSS/GSS.h>
#import <WebCore/AuthenticationChallenge.h>
#import <WebCore/CertificateInfo.h>
#import <WebCore/ClientOrigin.h>
#import <WebCore/CocoaCurlSocketStream.h>
#import <WebCore/CocoaCurlTLS.h>
#import <WebCore/CocoaCurlTransfer.h>
#import <WebCore/NetworkStorageSession.h>
#import <WebCore/ProtectionSpace.h>
#import <WebCore/ResourceError.h>
#import <WebCore/ThreadableWebSocketChannel.h>
#import <dlfcn.h>
#import <pal/spi/cf/CFNetworkSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/MainThread.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/Base64.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringToIntegerConversion.h>

// NTLM is computed by the generator CFNetwork runs its own NTLM exchanges on, which it exports; version 2 is the one
// CFNetwork asks for, its type-1 message carrying flags 0x00088207 as CFNetwork's does.
typedef struct WKNtlmGenerator* WKNtlmGeneratorRef;
static const int webSocketNtlmVersion2 = 2;
static OSStatus (*webSocketNtlmGeneratorCreate)(int, WKNtlmGeneratorRef*);
static void (*webSocketNtlmGeneratorRelease)(WKNtlmGeneratorRef);
static OSStatus (*webSocketNtlmCreateClientRequest)(WKNtlmGeneratorRef, CFDataRef*);
static OSStatus (*webSocketNtlmCreateClientResponse)(WKNtlmGeneratorRef, CFDataRef, CFStringRef, CFStringRef, CFStringRef, CFDataRef*);

static bool loadNtlmGenerator()
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        webSocketNtlmGeneratorCreate = reinterpret_cast<OSStatus (*)(int, WKNtlmGeneratorRef*)>(dlsym(RTLD_DEFAULT, "NtlmGeneratorCreate"));
        webSocketNtlmGeneratorRelease = reinterpret_cast<void (*)(WKNtlmGeneratorRef)>(dlsym(RTLD_DEFAULT, "NtlmGeneratorRelease"));
        webSocketNtlmCreateClientRequest = reinterpret_cast<OSStatus (*)(WKNtlmGeneratorRef, CFDataRef*)>(dlsym(RTLD_DEFAULT, "NtlmCreateClientRequest"));
        webSocketNtlmCreateClientResponse = reinterpret_cast<OSStatus (*)(WKNtlmGeneratorRef, CFDataRef, CFStringRef, CFStringRef, CFStringRef, CFDataRef*)>(dlsym(RTLD_DEFAULT, "NtlmCreateClientResponse"));
    });
    return webSocketNtlmGeneratorCreate && webSocketNtlmGeneratorRelease && webSocketNtlmCreateClientRequest && webSocketNtlmCreateClientResponse;
}

// Negotiate is SPNEGO through GSS.framework, which WebKit does not link, so it is loaded where first needed.
static struct {
    __typeof__(gss_import_name)* importName;
    __typeof__(gss_init_sec_context)* initSecContext;
    __typeof__(gss_release_buffer)* releaseBuffer;
    __typeof__(gss_release_name)* releaseName;
    __typeof__(gss_release_cred)* releaseCredential;
    __typeof__(gss_delete_sec_context)* deleteContext;
    __typeof__(gss_aapl_initial_cred)* initialCredential;
    gss_OID spnego;
    gss_OID kerberos;
    gss_OID hostBasedService;
    gss_OID userName;
} webSocketGSS;

static bool loadGSS()
{
    static dispatch_once_t once;
    static bool loaded;
    dispatch_once(&once, ^{
        void* image = dlopen("/System/Library/Frameworks/GSS.framework/GSS", RTLD_LAZY | RTLD_LOCAL);
        if (!image)
            return;
        webSocketGSS.importName = reinterpret_cast<__typeof__(gss_import_name)*>(dlsym(image, "gss_import_name"));
        webSocketGSS.initSecContext = reinterpret_cast<__typeof__(gss_init_sec_context)*>(dlsym(image, "gss_init_sec_context"));
        webSocketGSS.releaseBuffer = reinterpret_cast<__typeof__(gss_release_buffer)*>(dlsym(image, "gss_release_buffer"));
        webSocketGSS.releaseName = reinterpret_cast<__typeof__(gss_release_name)*>(dlsym(image, "gss_release_name"));
        webSocketGSS.releaseCredential = reinterpret_cast<__typeof__(gss_release_cred)*>(dlsym(image, "gss_release_cred"));
        webSocketGSS.deleteContext = reinterpret_cast<__typeof__(gss_delete_sec_context)*>(dlsym(image, "gss_delete_sec_context"));
        webSocketGSS.initialCredential = reinterpret_cast<__typeof__(gss_aapl_initial_cred)*>(dlsym(image, "gss_aapl_initial_cred"));
        webSocketGSS.spnego = static_cast<gss_OID>(dlsym(image, "__gss_spnego_mechanism_oid_desc"));
        webSocketGSS.kerberos = static_cast<gss_OID>(dlsym(image, "__gss_krb5_mechanism_oid_desc"));
        webSocketGSS.hostBasedService = static_cast<gss_OID>(dlsym(image, "__gss_c_nt_hostbased_service_oid_desc"));
        webSocketGSS.userName = static_cast<gss_OID>(dlsym(image, "__gss_c_nt_user_name_oid_desc"));
        loaded = webSocketGSS.importName && webSocketGSS.initSecContext && webSocketGSS.releaseBuffer && webSocketGSS.releaseName
            && webSocketGSS.releaseCredential && webSocketGSS.deleteContext && webSocketGSS.initialCredential && webSocketGSS.spnego
            && webSocketGSS.kerberos && webSocketGSS.hostBasedService && webSocketGSS.userName;
    });
    return loaded;
}

static bool isConnectionBasedScheme(const String& scheme)
{
    return scheme == String(kCFHTTPAuthenticationSchemeNTLM) || scheme == String(kCFHTTPAuthenticationSchemeNegotiate);
}

// The token a WWW-Authenticate field carries for `scheme`, written "<scheme> <base64>".
static RetainPtr<NSData> challengeToken(const WebCore::ResourceResponse& response, const String& scheme)
{
    for (auto challenge : StringView(response.httpHeaderField("WWW-Authenticate"_s)).split(',')) {
        auto trimmed = challenge.trim(isASCIIWhitespace<char16_t>);
        if (trimmed.length() > scheme.length() + 1 && trimmed[scheme.length()] == ' ' && equalIgnoringASCIICase(trimmed.left(scheme.length()), scheme))
            return adoptNS([[NSData alloc] initWithBase64EncodedString:trimmed.substring(scheme.length() + 1).createNSString().get() options:0]);
    }
    return nil;
}

// One NTLM or Negotiate exchange: the messages a credential sends, each answering the server's last token.
@interface WKWebSocketConnectionAuthentication : NSObject {
    RetainPtr<NSString> _scheme;
    RetainPtr<NSString> _host;
    RetainPtr<NSString> _user;
    RetainPtr<NSString> _password;
    WKNtlmGeneratorRef _ntlm;
    gss_ctx_id_t _context;
    gss_cred_id_t _gssCredential;
    gss_name_t _service;
    BOOL _gssComplete;
    OM_uint32 _gssFlags;
}
- (instancetype)initWithScheme:(NSString *)scheme host:(NSString *)host user:(NSString *)user password:(NSString *)password;
- (NSString *)scheme;
- (NSString *)authorizationForToken:(NSData *)token;
- (BOOL)completeForToken:(NSData *)token;
@end

@implementation WKWebSocketConnectionAuthentication
- (instancetype)initWithScheme:(NSString *)scheme host:(NSString *)host user:(NSString *)user password:(NSString *)password
{
    if (!(self = [super init]))
        return nil;
    _scheme = scheme;
    _host = host;
    _user = user;
    _password = password;
    return self;
}

- (void)dealloc
{
    if (_ntlm)
        webSocketNtlmGeneratorRelease(_ntlm);
    OM_uint32 minor = 0;
    if (_context)
        webSocketGSS.deleteContext(&minor, &_context, GSS_C_NO_BUFFER);
    if (_gssCredential)
        webSocketGSS.releaseCredential(&minor, &_gssCredential);
    if (_service)
        webSocketGSS.releaseName(&minor, &_service);
    [super dealloc];
}

- (NSString *)scheme
{
    return _scheme.get();
}

// The Authorization field that answers `token`, or opens the exchange when there is none.
- (NSString *)authorizationForToken:(NSData *)token
{
    if ([_scheme.get() isEqualToString:(__bridge NSString *)kCFHTTPAuthenticationSchemeNTLM])
        return [self ntlmAuthorizationForToken:token];
    NSData *data = [self advanceNegotiateWithToken:token];
    return data.length ? [@"Negotiate " stringByAppendingString:[data base64EncodedStringWithOptions:0]] : nil;
}

- (NSString *)ntlmAuthorizationForToken:(NSData *)token
{
    if (!loadNtlmGenerator())
        return nil;
    CFDataRef message = nullptr;
    if (!token) {
        if (_ntlm || webSocketNtlmGeneratorCreate(webSocketNtlmVersion2, &_ntlm) != errSecSuccess || webSocketNtlmCreateClientRequest(_ntlm, &message) != errSecSuccess)
            return nil;
    } else {
        if (!_ntlm)
            return nil;
        // A domain account is written DOMAIN\user.
        NSString *user = _user ? _user.get() : @"";
        NSString *domain = @"";
        NSRange separator = [user rangeOfString:@"\\"];
        if (separator.location != NSNotFound) {
            domain = [user substringToIndex:separator.location];
            user = [user substringFromIndex:NSMaxRange(separator)];
        }
        if (webSocketNtlmCreateClientResponse(_ntlm, (__bridge CFDataRef)token, (__bridge CFStringRef)domain, (__bridge CFStringRef)user,
            (__bridge CFStringRef)(_password ? _password.get() : @""), &message) != errSecSuccess)
            return nil;
    }
    NSData *data = CFBridgingRelease(message);
    return data.length ? [@"NTLM " stringByAppendingString:[data base64EncodedStringWithOptions:0]] : nil;
}

- (NSData *)advanceNegotiateWithToken:(NSData *)token
{
    if (!loadGSS())
        return nil;
    OM_uint32 minor = 0;
    if (!_service) {
        NSData *name = [[NSString stringWithFormat:@"HTTP@%@", _host.get()] dataUsingEncoding:NSUTF8StringEncoding];
        gss_buffer_desc buffer = { name.length, const_cast<void*>(name.bytes) };
        if (webSocketGSS.importName(&minor, &buffer, webSocketGSS.hostBasedService, &_service) != GSS_S_COMPLETE)
            return nil;
    }
    // Without a credential the exchange uses the Kerberos tickets the user already holds.
    if (!token && [_user length] && !_gssCredential) {
        NSData *userName = [_user.get() dataUsingEncoding:NSUTF8StringEncoding];
        gss_buffer_desc buffer = { userName.length, const_cast<void*>(userName.bytes) };
        gss_name_t desired = GSS_C_NO_NAME;
        if (webSocketGSS.importName(&minor, &buffer, webSocketGSS.userName, &desired) != GSS_S_COMPLETE)
            return nil;
        OM_uint32 major = webSocketGSS.initialCredential(desired, webSocketGSS.kerberos,
            (__bridge CFDictionaryRef)@{ (__bridge id)kGSSICPassword: _password ? _password.get() : @"" }, &_gssCredential, nullptr);
        webSocketGSS.releaseName(&minor, &desired);
        if (major != GSS_S_COMPLETE)
            return nil;
    }
    gss_buffer_desc input = { token.length, const_cast<void*>(token.bytes) };
    gss_buffer_desc output = GSS_C_EMPTY_BUFFER;
    OM_uint32 major = webSocketGSS.initSecContext(&minor, _gssCredential, &_context, _service, webSocketGSS.spnego, GSS_C_MUTUAL_FLAG,
        GSS_C_INDEFINITE, GSS_C_NO_CHANNEL_BINDINGS, token ? &input : GSS_C_NO_BUFFER, nullptr, &output, &_gssFlags, nullptr);
    NSData *data = [NSData dataWithBytes:output.value length:output.length];
    webSocketGSS.releaseBuffer(&minor, &output);
    _gssComplete = major == GSS_S_COMPLETE;
    return GSS_ERROR(major) ? nil : data;
}

// Whether the server's answer completes the exchange; Negotiate asks for mutual authentication.
- (BOOL)completeForToken:(NSData *)token
{
    if (![_scheme.get() isEqualToString:(__bridge NSString *)kCFHTTPAuthenticationSchemeNegotiate])
        return YES;
    if (token.length && ![self advanceNegotiateWithToken:token])
        return NO;
    return _gssComplete && (_gssFlags & GSS_C_MUTUAL_FLAG);
}
@end

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebSocketTask);

// The handshake follows at most 16 redirects, as 10.9 CFNetwork does.
static constexpr unsigned maximumRedirects = 16;

static bool isSecureURL(const URL& url)
{
    return url.protocolIs("wss"_s) || url.protocolIs("https"_s);
}

// Cookies and authentication for a WebSocket URL are those of its http(s) equivalent, as in WebSocketHandshake's
// httpURLForAuthenticationAndCookies.
static URL httpURL(const URL& url)
{
    URL result = url;
    if (url.protocolIs("ws"_s))
        result.setProtocol("http"_s);
    else if (url.protocolIs("wss"_s))
        result.setProtocol("https"_s);
    return result;
}

// Two URLs are same-origin when scheme, host and effective port all match; ws and wss carry http's and https's ports.
static bool areSameOrigin(const URL& a, const URL& b)
{
    if (!equalIgnoringASCIICase(a.protocol(), b.protocol()) || a.host().isEmpty() || !equalIgnoringASCIICase(a.host(), b.host()))
        return false;
    uint16_t defaultPort = isSecureURL(a) ? 443 : 80;
    return a.port().value_or(defaultPort) == b.port().value_or(defaultPort);
}

static String acceptForKey(const String& key)
{
    auto utf8 = makeString(key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"_s).utf8();
    std::array<uint8_t, CC_SHA1_DIGEST_LENGTH> digest;
    CC_SHA1(utf8.data(), static_cast<CC_LONG>(utf8.length()), digest.data());
    return base64EncodeToString(std::span { digest });
}

// Client frames are always masked (RFC 6455 5.3).
static Vector<uint8_t> maskedFrame(uint8_t opcode, std::span<const uint8_t> payload)
{
    Vector<uint8_t> frame;
    frame.reserveInitialCapacity(payload.size() + 14);
    frame.append(0x80 | opcode);
    size_t length = payload.size();
    if (length <= 125)
        frame.append(0x80 | static_cast<uint8_t>(length));
    else if (length <= 0xFFFF) {
        frame.append(0x80 | 126);
        frame.append(static_cast<uint8_t>(length >> 8));
        frame.append(static_cast<uint8_t>(length));
    } else {
        frame.append(0x80 | 127);
        for (int shift = 56; shift >= 0; shift -= 8)
            frame.append(static_cast<uint8_t>(static_cast<uint64_t>(length) >> shift));
    }
    std::array<uint8_t, 4> mask;
    arc4random_buf(mask.data(), mask.size());
    frame.append(std::span<const uint8_t> { mask });
    size_t payloadStart = frame.size();
    frame.append(payload);
    for (size_t i = 0; i < length; ++i)
        frame[payloadStart + i] ^= mask[i & 3];
    return frame;
}

static WebSocketTask::TaskIdentifier nextTaskIdentifier()
{
    ASSERT(isMainThread());
    static WebSocketTask::TaskIdentifier identifier;
    return ++identifier;
}

Ref<WebSocketTask> WebSocketTask::create(NetworkSocketChannel& channel, WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier> frameID, std::optional<PageIdentifier> pageID, WeakPtr<SessionSet>&& sessionSet, const ResourceRequest& request, const String& protocol, const ClientOrigin& clientOrigin, StoredCredentialsPolicy storedCredentialsPolicy, IsInitiatedByDedicatedWorker isInitiatedByDedicatedWorker)
{
    return adoptRef(*new WebSocketTask(channel, webPageProxyID, frameID, pageID, WTF::move(sessionSet), request, protocol, clientOrigin, storedCredentialsPolicy, isInitiatedByDedicatedWorker));
}

WebSocketTask::WebSocketTask(NetworkSocketChannel& channel, WebPageProxyIdentifier webPageProxyID, std::optional<FrameIdentifier> frameID, std::optional<PageIdentifier> pageID, WeakPtr<SessionSet>&& sessionSet, const ResourceRequest& request, const String& protocol, const ClientOrigin& clientOrigin, StoredCredentialsPolicy storedCredentialsPolicy, IsInitiatedByDedicatedWorker isInitiatedByDedicatedWorker)
    : m_channel(channel)
    , m_identifier(nextTaskIdentifier())
    , m_webPageProxyID(webPageProxyID)
    , m_frameID(frameID)
    , m_pageID(pageID)
    , m_sessionSet(WTF::move(sessionSet))
    , m_partition(request.cachePartition())
    , m_storedCredentialsPolicy(storedCredentialsPolicy)
    , m_isInitiatedByDedicatedWorker(isInitiatedByDedicatedWorker)
    , m_request(request)
    , m_protocol(protocol)
    , m_handshakeTimer(RunLoop::mainSingleton(), "WebSocketTask handshake deadline"_s, this, &WebSocketTask::handshakeTimedOut)
{
    // A service worker's WebSocket has no page behind its pageID, so its challenges name the top origin only for a
    // same-origin connection.
    if (clientOrigin.topOrigin == clientOrigin.clientOrigin)
        m_topOrigin = clientOrigin.topOrigin;
    if (RefPtr connection = channel.m_connectionToWebProcess.get())
        m_proxyFilterResults = LegacyExtensionNetwork::singleton().takeWebSocketProxyFilterResults(*connection, channel.m_identifier);
    // As WebSocketTaskCocoa decides it: a stateless connection, or one third-party cookie blocking covers, sends and
    // stores no cookies.
    m_cookiesBlocked = storedCredentialsPolicy == StoredCredentialsPolicy::EphemeralStateless;
    if (!m_cookiesBlocked)
        updateCookieBlocking(m_request);

    // Web Inspector shows the request the task was made with, as WebSocketTaskCocoa reports its task's.
    ResourceRequest inspectorRequest = m_request;
    if (!m_protocol.isNull())
        inspectorRequest.setHTTPHeaderField(HTTPHeaderName::SecWebSocketProtocol, m_protocol);
    channel.didSendHandshakeRequest(WTF::move(inspectorRequest));
}

WebSocketTask::~WebSocketTask()
{
    closeTransport();
}

NetworkSessionCocoa* WebSocketTask::networkSession()
{
    RefPtr channel = m_channel.get();
    return channel ? downcast<NetworkSessionCocoa>(channel->session()) : nullptr;
}

// The latch NetworkTaskCocoa keeps: once a hop's cookies are blocked, the hops after it send none, unless the
// first-party latch-mode quirk lifts it for a redirect.
bool WebSocketTask::updateCookieBlocking(const ResourceRequest& request)
{
    CheckedPtr session = networkSession();
    CheckedPtr storage = session ? session->networkStorageSession() : nullptr;
    if (!storage)
        return m_cookiesBlocked;
    if (!m_cookiesBlocked) {
        auto relax = session->networkProcess().shouldRelaxThirdPartyCookieBlockingForPage(m_webPageProxyID.asOptional());
        auto decision = storage->thirdPartyCookieBlockingDecisionForRequest(request, m_frameID, m_pageID, relax, NetworkSession::isRequestToKnownCrossSiteTracker(request), m_isInitiatedByDedicatedWorker == IsInitiatedByDedicatedWorker::Yes);
        m_cookiesBlocked = NetworkStorageSession::shouldBlockCookies(decision);
    }
    return m_cookiesBlocked;
}

// The hop's Cookie field, looked up as a network task's is.
String WebSocketTask::cookieHeader() const
{
    CheckedPtr session = const_cast<WebSocketTask*>(this)->networkSession();
    if (!session)
        return { };
    ResourceRequest cookieRequest = m_request;
    cookieRequest.setURL(httpURL(m_request.url()));
    return NetworkDataTaskCurlCocoa::cookieHeader(*session, cookieRequest, m_frameID, m_pageID, m_webPageProxyID.asOptional(), m_storedCredentialsPolicy, m_cookiesBlocked);
}

// A handshake response's Set-Cookie fields reach the session's storage as a network task's do.
void WebSocketTask::storeCookies(const Vector<String>& fields)
{
    if (fields.isEmpty() || m_cookiesBlocked || !m_request.allowCookies() || m_storedCredentialsPolicy == StoredCredentialsPolicy::EphemeralStateless)
        return;
    CheckedPtr session = networkSession();
    if (!session)
        return;
    ResourceRequest cookieRequest = m_request;
    cookieRequest.setURL(httpURL(m_request.url()));
    // The address of a connection made through a proxy is the proxy's, which says nothing of the origin.
    bool capExpiry = !m_forwardingProxyAuthorization && m_stream
        && NetworkDataTaskCurlCocoa::shouldCapCookieExpiryForThirdPartyCloaking(*session, cookieRequest, m_stream->remoteAddress(), { });
    NetworkDataTaskCurlCocoa::storeCookies(*session, cookieRequest, fields, m_frameID, m_pageID, m_webPageProxyID.asOptional(), capExpiry);
}

void WebSocketTask::resume()
{
    if (m_state != State::Connecting || m_stream)
        return;
    // The first hop's Cookie header is attached once the task runs, under the cookie policy it was created with.
    if (!m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie)) {
        if (auto cookie = cookieHeader(); !cookie.isEmpty())
            m_request.setHTTPHeaderField(HTTPHeaderName::Cookie, cookie);
    }
    startConnection();
}

void WebSocketTask::cancel()
{
    teardownTransport();
}

// How long each handshake request may take to be answered, as 10.9 NSURLSession times out the NSURLRequest
// ResourceRequestCocoa makes of it: the request's timeout, or the default one. One that is not positive, or too
// long for a dispatch time, means none.
static Seconds handshakeTimeout(const ResourceRequest& request)
{
    double timeout = request.timeoutInterval() ? request.timeoutInterval() : ResourceRequest::defaultTimeoutInterval();
    if (!(timeout > 0) || timeout >= static_cast<double>(INT64_MAX / NSEC_PER_SEC))
        return Seconds::infinity();
    return Seconds(timeout);
}

void WebSocketTask::startConnection()
{
    CheckedPtr session = networkSession();
    if (!session) {
        fail("The WebSocket's network session is gone"_s);
        return;
    }
    auto& url = m_request.url();
    if (!url.isValid() || url.host().isEmpty()) {
        fail("Invalid WebSocket URL"_s);
        return;
    }
    RetainPtr<NSURLSessionConfiguration> configuration = session->sessionWrapperForTask(m_webPageProxyID.asOptional(), m_request, m_storedCredentialsPolicy, std::nullopt)->session.get().configuration;
    armHandshakeDeadline(handshakeTimeout(m_request));

    bool secure = isSecureURL(url);
    CocoaCurlSocketStream::Options options;
    options.url = url;
    options.port = url.port().value_or(secure ? 443 : 80);
    options.secure = secure;
    // An HTTP proxy forwards a ws:// upgrade in absolute form; wss:// is tunnelled.
    options.tunnelsPlainConnections = false;
    options.minimumTLSProtocol = configuration.get().TLSMinimumSupportedProtocolVersion;
    options.serverTrust = CocoaCurlSocketStream::ServerTrust::Client;
    options.presentsPreferredIdentity = !configuration.get()._shouldSkipPreferredClientCertificateLookup;
    // A session routes its tasks by its configuration's proxy dictionary; an empty one means the system settings.
    options.configuredProxySettings = (__bridge CFDictionaryRef)configuration.get().connectionProxyDictionary;
    options.proxyFilterResults = m_proxyFilterResults;
    // The handshake deadline bounds the connection, and waits while a question about it is with the user, as a load's
    // timer does; curl keeps its own limit only for a proxy server's failoverTimeout.
    options.connectTimeout = Seconds::infinity();

    CocoaCurlSocketStream::Client client;
    client.didOpen = [weakThis = ThreadSafeWeakPtr { *this }](std::optional<CocoaCurlSocketStream::ForwardingProxy>&& forwardingProxy) {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->streamDidOpen(forwardingProxy ? std::optional { forwardingProxy->authorization } : std::nullopt);
    };
    client.didReceiveData = [weakThis = ThreadSafeWeakPtr { *this }](std::span<const uint8_t> data) {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->receive(data);
    };
    client.didClose = [weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->handleEndOfConnection();
    };
    client.canSendMore = [weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->flushOutput();
    };
    client.didFail = [weakThis = ThreadSafeWeakPtr { *this }](int, const String& description) {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        // A connection held for a credential that fails is replaced once the credential is chosen.
        if (protectedThis->m_awaitingCredential && protectedThis->m_state == State::Handshaking) {
            protectedThis->resetConnection();
            return;
        }
        protectedThis->fail(makeString("WebSocket connection failed: "_s, description));
    };
    client.decideServerTrust = [weakThis = ThreadSafeWeakPtr { *this }](RetainPtr<SecTrustRef>&& trust, CompletionHandler<void(bool)>&& completion) {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return completion(false);
        protectedThis->decideServerTrust(WTF::move(trust), WTF::move(completion));
    };
    client.requestIdentity = [weakThis = ThreadSafeWeakPtr { *this }](RetainPtr<CFArrayRef>&& authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return completion(nullptr, nullptr);
        protectedThis->requestClientIdentity(WTF::move(authorities), WTF::move(completion));
    };
    m_state = State::Connecting;
    m_stream = CocoaCurlSocketStream::create(WTF::move(options), WTF::move(client));
    m_stream->start();
}

// The server's certificate, answered for inside the TLS handshake as a load's is: the system's trust store, then a
// certificate the user accepted for the host, then the user, through the AuthenticationManager. The handshake deadline
// waits for the answer.
void WebSocketTask::decideServerTrust(RetainPtr<SecTrustRef>&& trust, CompletionHandler<void(bool)>&& completion)
{
    m_handshakeTimeLeft = disarmHandshakeDeadline();
    auto finish = [weakThis = ThreadSafeWeakPtr { *this }, completion = WTF::move(completion)](bool accepted) mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis || protectedThis->m_state == State::Closed)
            return completion(false);
        protectedThis->armHandshakeDeadline(protectedThis->m_handshakeTimeLeft);
        completion(accepted);
    };
    // Revocation checks can wait on the network, so the evaluation runs off the main thread.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), makeBlockPtr([weakThis = ThreadSafeWeakPtr { *this }, trust = WTF::move(trust), finish = WTF::move(finish)]() mutable {
        SecTrustResultType result = kSecTrustResultInvalid;
        bool systemAccepts = SecTrustEvaluate(trust.get(), &result) == errSecSuccess && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified);
        callOnMainThread([weakThis = WTF::move(weakThis), trust = WTF::move(trust), finish = WTF::move(finish), systemAccepts]() mutable {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis || protectedThis->m_state == State::Closed)
                return finish(false);
            if (systemAccepts)
                return finish(true);
            CheckedPtr session = protectedThis->networkSession();
            if (!session)
                return finish(false);
            auto host = protectedThis->m_request.url().host().toString();
            if (auto* allowed = session->networkProcess().allowedHTTPSCertificateForHost(host); allowed && certificatesMatch(allowed->trust().get(), trust.get()))
                return finish(true);
            auto space = cocoaCurlTLSProtectionSpace(httpURL(protectedThis->m_request.url()), 8, nullptr, trust.get());
            if (!space)
                return finish(false);
            AuthenticationChallenge challenge(ProtectionSpace(space.get()), { }, 0, { }, { });
            protectedThis->askAuthenticationManager(WTF::move(challenge), [finish = WTF::move(finish)](AuthenticationChallengeDisposition disposition, const Credential&) mutable {
                finish(disposition == AuthenticationChallengeDisposition::UseCredential);
            });
        });
    }).get());
}

// A server that asks for a certificate is answered as a load's request for one is
// (NetworkDataTaskCurlCocoa::curlRequestedIdentity), and the handshake deadline waits for the answer.
void WebSocketTask::requestClientIdentity(RetainPtr<CFArrayRef>&& authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion)
{
    auto space = cocoaCurlTLSProtectionSpace(httpURL(m_request.url()), 7, authorities.get(), nullptr);
    if (!space) {
        completion(nullptr, nullptr);
        fail("Could not construct a client certificate challenge"_s);
        return;
    }
    m_handshakeTimeLeft = disarmHandshakeDeadline();
    AuthenticationChallenge challenge(ProtectionSpace(space.get()), { }, 0, { }, { });
    askAuthenticationManager(WTF::move(challenge), [weakThis = ThreadSafeWeakPtr { *this }, completion = WTF::move(completion)](AuthenticationChallengeDisposition disposition, const Credential& credential) mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis || protectedThis->m_state == State::Closed)
            return completion(nullptr, nullptr);
        protectedThis->armHandshakeDeadline(protectedThis->m_handshakeTimeLeft);
        if (disposition == AuthenticationChallengeDisposition::UseCredential)
            completion(retainPtr((SecIdentityRef)credential.nsCredential().identity), retainPtr((CFArrayRef)credential.nsCredential().certificates));
        else
            completion(nullptr, nullptr);
        if (disposition == AuthenticationChallengeDisposition::Cancel)
            protectedThis->fail("cancelled"_s);
    });
}

// The challenge goes to the user as NetworkSessionCocoa puts a WebSocket task's: a password the user chose for this
// session is kept in the session's credential storage, under the 401's URL.
void WebSocketTask::askAuthenticationManager(AuthenticationChallenge&& challenge, CompletionHandler<void(AuthenticationChallengeDisposition, const Credential&)>&& completion)
{
    CheckedPtr session = networkSession();
    if (!session)
        return completion(AuthenticationChallengeDisposition::Cancel, { });
    auto handler = [networkProcess = Ref { session->networkProcess() }, sessionID = session->sessionID(), challenge, partition = m_partition, completion = WTF::move(completion)](AuthenticationChallengeDisposition disposition, const Credential& credential) mutable {
        if (credential.persistence() == CredentialPersistence::ForSession && challenge.protectionSpace().isPasswordBased()) {
            Credential nonPersistentCredential(credential.user(), credential.password(), CredentialPersistence::None);
            URL urlToStore;
            if (challenge.failureResponse().httpStatusCode() == 401)
                urlToStore = challenge.failureResponse().url();
            if (CheckedPtr storageSession = networkProcess->storageSession(sessionID))
                storageSession->credentialStorage().set(partition, nonPersistentCredential, challenge.protectionSpace(), urlToStore);
            return completion(disposition, nonPersistentCredential);
        }
        completion(disposition, credential);
    };
    Ref { session->networkProcess().authenticationManager() }->didReceiveAuthenticationChallenge(session->sessionID(), m_webPageProxyID.asOptional(), !m_topOrigin.isNull() ? &m_topOrigin : nullptr, challenge, NegotiatedLegacyTLS::No, WTF::move(handler));
}

void WebSocketTask::streamDidOpen(std::optional<String>&& forwardingProxyAuthorization)
{
    m_transportOpen = true;
    m_forwardingProxyAuthorization = WTF::move(forwardingProxyAuthorization);
    m_state = State::Handshaking;
    sendHandshake();
}

// The request target and Host field as WebSocketHandshake writes them: the encoded path (with any ';' parameters) and
// query, and the port only when it is not the scheme's default. An IPv6 literal keeps its brackets in the Host field.
static String resourceName(const URL& url)
{
    auto path = url.path();
    String name = path.isEmpty() ? "/"_s : path.toString();
    if (url.hasQuery())
        name = makeString(name, '?', url.query());
    return name;
}

static String hostField(const URL& url)
{
    auto host = url.host();
    bool bracketed = host.contains(':') && !host.startsWith('[');
    auto name = makeString(bracketed ? "["_s : ""_s, host, bracketed ? "]"_s : ""_s);
    auto port = url.port();
    if (!port || *port == (isSecureURL(url) ? 443 : 80))
        return name;
    return makeString(name, ':', *port);
}

void WebSocketTask::sendHandshake()
{
    std::array<uint8_t, 16> keyBytes;
    arc4random_buf(keyBytes.data(), keyBytes.size());
    auto key = base64EncodeToString(std::span<const uint8_t> { keyBytes });
    m_acceptKey = acceptForKey(key);

    auto& url = m_request.url();
    auto host = hostField(url);
    auto resource = resourceName(url);
    auto target = m_forwardingProxyAuthorization ? makeString("ws://"_s, host, resource) : resource;

    StringBuilder request;
    request.append("GET "_s, target, " HTTP/1.1\r\n"_s);
    request.append("Host: "_s, host, "\r\n"_s);
    request.append("Upgrade: websocket\r\n"_s);
    request.append("Connection: Upgrade\r\n"_s);
    request.append("Sec-WebSocket-Key: "_s, key, "\r\n"_s);
    request.append("Sec-WebSocket-Version: 13\r\n"_s);
    if (!m_protocol.isEmpty())
        request.append("Sec-WebSocket-Protocol: "_s, m_protocol, "\r\n"_s);
    if (m_forwardingProxyAuthorization && !m_forwardingProxyAuthorization->isEmpty())
        request.append("Proxy-Authorization: "_s, *m_forwardingProxyAuthorization, "\r\n"_s);
    for (auto& field : m_request.httpHeaderFields()) {
        if (equalLettersIgnoringASCIICase(field.key, "host"_s) || equalLettersIgnoringASCIICase(field.key, "upgrade"_s) || equalLettersIgnoringASCIICase(field.key, "connection"_s)
            || equalLettersIgnoringASCIICase(field.key, "content-length"_s) || equalLettersIgnoringASCIICase(field.key, "sec-websocket-key"_s) || equalLettersIgnoringASCIICase(field.key, "sec-websocket-version"_s)
            || equalLettersIgnoringASCIICase(field.key, "sec-websocket-protocol"_s) || equalLettersIgnoringASCIICase(field.key, "sec-websocket-extensions"_s))
            continue;
        request.append(field.key, ": "_s, field.value, "\r\n"_s);
    }
    request.append("\r\n"_s);

    // Each field value is octets, one per character, as the HTTP transport writes them.
    auto bytes = request.toString().latin1();
    write({ Vector<uint8_t> { byteCast<uint8_t>(bytes.span()) }, { } });
}

void WebSocketTask::write(Outgoing&& outgoing)
{
    if (m_state == State::Closed)
        return;
    m_outQueue.append(WTF::move(outgoing));
    if (m_transportOpen)
        flushOutput();
}

void WebSocketTask::flushOutput()
{
    RefPtr stream = m_stream;
    if (!stream || !m_transportOpen)
        return;
    while (!m_outQueue.isEmpty()) {
        auto& outgoing = m_outQueue.first();
        auto sent = stream->send(outgoing.data.span().subspan(m_outOffset));
        if (!sent) {
            fail("WebSocket write failed"_s);
            return;
        }
        if (!*sent)
            return;
        m_outOffset += *sent;
        if (m_outOffset < outgoing.data.size())
            continue;
        m_outOffset = 0;
        auto completion = m_outQueue.takeFirst().completion;
        if (completion)
            completion();
        if (m_stream != stream)
            return;
    }
}

void WebSocketTask::sendFrame(uint8_t opcode, std::span<const uint8_t> payload, CompletionHandler<void()>&& completion)
{
    write({ maskedFrame(opcode, payload), WTF::move(completion) });
}

// The completion runs once the frame is written, or when the connection ends first. No data frame follows a Close
// (RFC 6455 5.5.1), and none goes out before the server's handshake response has been validated (RFC 6455 4.1).
void WebSocketTask::sendString(std::span<const uint8_t> utf8, CompletionHandler<void()>&& callback)
{
    if (String::fromUTF8(utf8).isNull())
        return callback();
    if (m_state == State::Closed || m_sentClose)
        return callback();
    Outgoing frame { maskedFrame(0x1, utf8), WTF::move(callback) };
    if (m_state == State::Open)
        write(WTF::move(frame));
    else
        m_heldSends.append(WTF::move(frame));
}

void WebSocketTask::sendData(std::span<const uint8_t> data, CompletionHandler<void()>&& callback)
{
    if (m_state == State::Closed || m_sentClose)
        return callback();
    Outgoing frame { maskedFrame(0x2, data), WTF::move(callback) };
    if (m_state == State::Open)
        write(WTF::move(frame));
    else
        m_heldSends.append(WTF::move(frame));
}

// A Close frame goes out and the connection stays open; the peer's Close frame, or the end of the connection,
// completes the closing handshake. A connection not yet open just ends.
void WebSocketTask::close(int32_t code, const String& reason)
{
    if (m_state != State::Open) {
        teardownTransport();
        return;
    }
    m_state = State::Closing;
    auto utf8 = reason.utf8();
    sendCloseFrame(code == ThreadableWebSocketChannel::CloseEventCodeNotSpecified ? 0 : static_cast<uint16_t>(code), byteCast<uint8_t>(utf8.span()));
}

// A code of 0 sends a Close frame with an empty payload (RFC 6455 5.5.1), which the peer reports as 1005.
void WebSocketTask::sendCloseFrame(uint16_t code, std::span<const uint8_t> reason)
{
    if (std::exchange(m_sentClose, true))
        return;
    Vector<uint8_t> payload;
    if (code) {
        payload.append(static_cast<uint8_t>(code >> 8));
        payload.append(static_cast<uint8_t>(code));
        payload.append(reason);
    }
    sendFrame(0x8, payload.span());
}

void WebSocketTask::receive(std::span<const uint8_t> data)
{
    m_inBuffer.append(data);
    if (m_state == State::Handshaking) {
        if (m_discardedBodyBytes) {
            size_t skipped = std::min(m_discardedBodyBytes, m_inBuffer.size());
            m_inBuffer.removeAt(0, skipped);
            m_discardedBodyBytes -= skipped;
            if (m_discardedBodyBytes)
                return;
        }
        static constexpr std::array<uint8_t, 4> terminator { '\r', '\n', '\r', '\n' };
        auto end = std::search(m_inBuffer.begin(), m_inBuffer.end(), terminator.begin(), terminator.end());
        if (end == m_inBuffer.end())
            return;
        size_t headerEnd = (end - m_inBuffer.begin()) + terminator.size();
        Vector<uint8_t> header { m_inBuffer.span().first(headerEnd) };
        m_inBuffer.removeAt(0, headerEnd);
        disarmHandshakeDeadline();
        if (!completeHandshake(header.span()))
            return;
    }
    if (m_state == State::Open || m_state == State::Closing)
        parseFrames();
}

// The peer ended the connection.
void WebSocketTask::handleEndOfConnection()
{
    // A connection held for a credential that closes is replaced once the credential is chosen.
    if (m_awaitingCredential && m_state == State::Handshaking) {
        resetConnection();
        return;
    }
    if (m_state == State::Open || (m_state == State::Closing && m_sentClose)) {
        deliverClose(ThreadableWebSocketChannel::CloseEventCodeAbnormalClosure, { });
        teardownTransport();
    } else if (m_state != State::Closed && m_state != State::Closing)
        fail("WebSocket connection closed unexpectedly"_s);
    else
        teardownTransport();
}

// RFC 6455 4.1: "The HTTP version MUST be at least 1.1." The version is the status line up to its first space, and
// everything after its dot is the minor version's digits; a major version alone is enough from 2 on.
static bool hasValidHTTPVersion(std::span<const uint8_t> version)
{
    static constexpr auto preamble = "HTTP/"_span;
    if (version.size() < preamble.size() + 3 || !std::equal(preamble.begin(), preamble.end(), version.begin()))
        return false;
    auto rest = version.subspan(preamble.size());
    size_t dot = 0;
    while (dot < rest.size() && rest[dot] != '.')
        ++dot;
    if (dot == rest.size())
        return false;
    auto major = parseInteger<int>(rest.first(dot));
    auto minor = parseInteger<int>(rest.subspan(dot + 1));
    if (!major || !minor)
        return false;
    return *major > 1 || (*major == 1 && *minor >= 1);
}

// The status line as 10.9 CFNetwork accepts one: no non-ASCII character, no embedded null, CRLF-terminated within
// 1024 bytes, an HTTP version of at least 1.1, and a three-digit status code.
bool WebSocketTask::parseStatusLine(std::span<const uint8_t> header, int& statusCode, size_t& lineLength)
{
    static constexpr size_t maximumLength = 1024;
    std::optional<size_t> firstSpace;
    std::optional<size_t> secondSpace;
    size_t index = 0;
    for (; index < header.size(); ++index) {
        uint8_t character = header[index];
        if (character == ' ') {
            if (!firstSpace)
                firstSpace = index;
            else if (!secondSpace)
                secondSpace = index;
        } else if (!character) {
            failProtocol("WebSocket handshake status line contains an embedded null"_s);
            return false;
        } else if (character >= 0x80) {
            failProtocol("WebSocket handshake status line contains a non-ASCII character"_s);
            return false;
        } else if (character == '\n')
            break;
    }
    if (index == header.size()) {
        failProtocol("WebSocket handshake status line has no line ending"_s);
        return false;
    }
    size_t length = index + 1;
    if (length > maximumLength) {
        failProtocol("WebSocket handshake status line is too long"_s);
        return false;
    }
    if (length < 2 || header[index - 1] != '\r') {
        failProtocol("WebSocket handshake status line does not end with CRLF"_s);
        return false;
    }
    if (!firstSpace || !secondSpace) {
        failProtocol("WebSocket handshake status line has no response code"_s);
        return false;
    }
    if (!hasValidHTTPVersion(header.first(*firstSpace))) {
        failProtocol("WebSocket handshake status line names an HTTP version below 1.1"_s);
        return false;
    }
    if (*secondSpace - *firstSpace - 1 != 3) {
        failProtocol("WebSocket handshake status code is not three digits"_s);
        return false;
    }
    int code = 0;
    for (size_t i = *firstSpace + 1; i < *secondSpace; ++i) {
        if (!isASCIIDigit(header[i])) {
            failProtocol("WebSocket handshake status code is not three digits"_s);
            return false;
        }
        code = code * 10 + (header[i] - '0');
    }
    statusCode = code;
    lineLength = length;
    return true;
}

bool WebSocketTask::completeHandshake(std::span<const uint8_t> header)
{
    int statusCode = 0;
    size_t statusLineLength = 0;
    if (!parseStatusLine(header, statusCode, statusLineLength))
        return false;

    ResourceResponse response(URL { m_request.url() }, String(), 0, String());
    response.setHTTPStatusCode(statusCode);
    response.setHTTPVersion("HTTP/1.1"_s);
    Vector<String> setCookieFields;
    unsigned extensionsFields = 0;
    unsigned acceptFields = 0;
    unsigned protocolFields = 0;
    String fields { byteCast<Latin1Character>(header.subspan(statusLineLength)) };
    for (auto line : StringView(fields).split('\n')) {
        if (line.endsWith('\r'))
            line = line.left(line.length() - 1);
        size_t colon = line.find(':');
        if (colon == notFound)
            continue;
        auto name = line.left(colon).trim(isASCIIWhitespace<char16_t>).toString();
        auto value = line.substring(colon + 1).trim(isASCIIWhitespace<char16_t>).toString();
        // RFC 6455 4.1: each of these three answers exactly one of the client's own fields, so a response repeating
        // any of them is not a handshake this side asked for.
        if (equalLettersIgnoringASCIICase(name, "sec-websocket-extensions"_s))
            ++extensionsFields;
        else if (equalLettersIgnoringASCIICase(name, "sec-websocket-accept"_s))
            ++acceptFields;
        else if (equalLettersIgnoringASCIICase(name, "sec-websocket-protocol"_s))
            ++protocolFields;
        // Set-Cookie is a list of individual fields, not a comma-separated field value.
        if (equalLettersIgnoringASCIICase(name, "set-cookie"_s)) {
            setCookieFields.append(WTF::move(value));
            continue;
        }
        auto existing = response.httpHeaderField(name);
        response.setHTTPHeaderField(name, existing.isEmpty() ? value : makeString(existing, ", "_s, value));
    }
    if (extensionsFields > 1 || acceptFields > 1 || protocolFields > 1) {
        failProtocol("WebSocket handshake response repeats a Sec-WebSocket header field"_s);
        return false;
    }
    m_response = WTF::move(response);
    storeCookies(setCookieFields);

    if (statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308)
        return followRedirect();
    if (statusCode == 401)
        return authenticate();
    if (statusCode != 101)
        return handshakeFailed(statusCode);

    auto upgrade = m_response.httpHeaderField(HTTPHeaderName::Upgrade);
    auto connection = m_response.httpHeaderField(HTTPHeaderName::Connection);
    auto accept = m_response.httpHeaderField(HTTPHeaderName::SecWebSocketAccept);
    auto serverProtocol = m_response.httpHeaderField(HTTPHeaderName::SecWebSocketProtocol);
    if (!equalLettersIgnoringASCIICase(upgrade, "websocket"_s)) {
        failProtocol("WebSocket handshake response has no 'Upgrade: websocket'"_s);
        return false;
    }
    // RFC 6455 4.1: Connection carries a token list, and one of its tokens is "Upgrade".
    bool upgradeRequested = false;
    for (auto token : StringView(connection).split(',')) {
        if (equalLettersIgnoringASCIICase(token.trim(isASCIIWhitespace<char16_t>), "upgrade"_s)) {
            upgradeRequested = true;
            break;
        }
    }
    if (!upgradeRequested) {
        failProtocol("WebSocket handshake response has no 'Connection: Upgrade'"_s);
        return false;
    }
    if (accept != m_acceptKey) {
        failProtocol("WebSocket handshake response has the wrong Sec-WebSocket-Accept"_s);
        return false;
    }
    // This client offers no extension, so any the response names was never negotiated (RFC 6455 4.1).
    if (extensionsFields && !m_response.httpHeaderField(HTTPHeaderName::SecWebSocketExtensions).isEmpty()) {
        failProtocol("WebSocket handshake response names an extension that was not offered"_s);
        return false;
    }
    // The subprotocol has to be one of those the request offered; WebSocket joins them with ", ".
    if (!serverProtocol.isEmpty()) {
        bool offered = false;
        for (auto protocol : StringView(m_protocol).split(','))
            offered |= protocol.trim(isASCIIWhitespace<char16_t>) == serverProtocol;
        if (!offered) {
            failProtocol("WebSocket handshake response names a subprotocol that was not offered"_s);
            return false;
        }
    }
    if (RetainPtr exchange = std::exchange(m_connectionAuthentication, nullptr); exchange && ![exchange.get() completeForToken:challengeToken(m_response, String([exchange.get() scheme])).get()])
        return handshakeFailed(statusCode);

    m_state = State::Open;
    m_didConnect = true;
    if (RefPtr channel = m_channel.get()) {
        channel->didConnect(serverProtocol, { });
        channel->didReceiveHandshakeResponse(ResourceResponse { m_response });
    }
    for (auto& held : std::exchange(m_heldSends, { }))
        m_outQueue.append(WTF::move(held));
    flushOutput();
    return true;
}

// Messages sent during the handshake stay held for the connection that replaces this one.
void WebSocketTask::resetConnection()
{
    if (RefPtr stream = std::exchange(m_stream, nullptr))
        stream->close();
    m_state = State::Connecting;
    m_inBuffer.clear();
    m_outQueue.clear();
    m_outOffset = 0;
    m_transportOpen = false;
    m_forwardingProxyAuthorization = std::nullopt;
    m_discardedBodyBytes = 0;
    m_awaitingCredential = false;
    m_connectionAuthentication = nullptr;
}

// A refused handshake leaves its connection usable when the response keeps it open and frames its body with a
// length; that body is skipped before the next response is read.
bool WebSocketTask::holdConnectionAfterRefusal()
{
    for (auto token : StringView(m_response.httpHeaderField(HTTPHeaderName::Connection)).split(',')) {
        if (equalLettersIgnoringASCIICase(token.trim(isASCIIWhitespace<char16_t>), "close"_s))
            return false;
    }
    if (!m_response.httpHeaderField(HTTPHeaderName::TransferEncoding).isNull())
        return false;
    auto length = parseInteger<uint64_t>(m_response.httpHeaderField(HTTPHeaderName::ContentLength));
    if (!length)
        return false;
    m_discardedBodyBytes = static_cast<size_t>(*length);
    return m_transportOpen;
}

// The challenges of a WWW-Authenticate field (RFC 7235 4.1; repeated fields arrive folded with ", "), each as
// { scheme, its own text, realm }. A comma ends an element only outside a quoted-string; an element of the form
// `name = value` is an auth-param of the challenge before it.
static String authParamValue(StringView value)
{
    if (!value.startsWith('"'))
        return value.toString();
    StringBuilder unquoted;
    for (size_t i = 1; i < value.length(); ++i) {
        auto character = value[i];
        if (character == '"')
            break;
        if (character == '\\' && i + 1 < value.length())
            character = value[++i];
        unquoted.append(character);
    }
    return unquoted.toString();
}

static bool isTokenCharacter(char16_t character)
{
    return isASCIIAlphanumeric(character) || (character && character < 128 && strchr("!#$%&'*+-.^_`|~", static_cast<char>(character)));
}

struct ParsedChallenge {
    String scheme;
    String challenge;
    String realm;
};

static Vector<ParsedChallenge> authenticationChallenges(const String& field)
{
    Vector<String> elements;
    size_t start = 0;
    bool quoted = false;
    for (size_t i = 0; i <= field.length(); ++i) {
        char16_t character = i < field.length() ? field[i] : ',';
        if (quoted) {
            if (character == '\\')
                ++i;
            else if (character == '"')
                quoted = false;
            continue;
        }
        if (character == '"')
            quoted = true;
        else if (character == ',') {
            auto element = StringView(field).substring(start, std::min<size_t>(i, field.length()) - start).trim(isASCIIWhitespace<char16_t>);
            if (!element.isEmpty())
                elements.append(element.toString());
            start = i + 1;
        }
    }

    Vector<ParsedChallenge> challenges;
    for (auto& element : elements) {
        size_t tokenEnd = 0;
        while (tokenEnd < element.length() && isTokenCharacter(element[tokenEnd]))
            ++tokenEnd;
        if (!tokenEnd)
            continue;
        auto token = StringView(element).left(tokenEnd);
        auto rest = StringView(element).substring(tokenEnd).trim(isASCIIWhitespace<char16_t>);
        if (rest.startsWith('=')) {
            if (challenges.isEmpty())
                continue;
            auto& challenge = challenges.last();
            challenge.challenge = makeString(challenge.challenge, ", "_s, element);
            if (equalLettersIgnoringASCIICase(token, "realm"_s))
                challenge.realm = authParamValue(rest.substring(1).trim(isASCIIWhitespace<char16_t>));
            continue;
        }
        ParsedChallenge challenge { token.toString(), element, { } };
        // After the scheme: a token68, or the challenge's first auth-param.
        size_t nameEnd = 0;
        while (nameEnd < rest.length() && isTokenCharacter(rest[nameEnd]))
            ++nameEnd;
        auto afterName = rest.substring(nameEnd).trim(isASCIIWhitespace<char16_t>);
        if (nameEnd && afterName.startsWith('=') && afterName.length() > 1 && equalLettersIgnoringASCIICase(rest.left(nameEnd), "realm"_s))
            challenge.realm = authParamValue(afterName.substring(1).trim(isASCIIWhitespace<char16_t>));
        challenges.append(WTF::move(challenge));
    }
    return challenges;
}

// A server challenge is answered with the credential the user, or the session's credential storage, supplies; the
// schemes are offered strongest first, the order 10.9 NSURLSession puts them in.
bool WebSocketTask::authenticate()
{
    if (RetainPtr exchange = std::exchange(m_connectionAuthentication, nullptr)) {
        // The server's answer to the exchange's last message, on the connection that sent it: the exchange goes on
        // without asking anyone, and this 401 does not refuse the credential.
        if (RetainPtr token = challengeToken(m_response, String([exchange.get() scheme])); [token.get() length]) {
            NSString *authorization = [exchange.get() authorizationForToken:token.get()];
            if (!authorization || !holdConnectionAfterRefusal())
                return handshakeFailed(401);
            m_connectionAuthentication = WTF::move(exchange);
            ResourceRequest next = m_request;
            next.setHTTPHeaderField(HTTPHeaderName::Authorization, String(authorization));
            next.removeHTTPHeaderField(HTTPHeaderName::Cookie);
            RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }, next = WTF::move(next)]() mutable {
                protectedThis->continueWithHandshakeRequest(WTF::move(next), 401);
            });
            return false;
        }
    }
    auto offered = authenticationChallenges(m_response.httpHeaderField("WWW-Authenticate"_s));
    m_offeredChallenges.clear();
    for (CFStringRef scheme : { kCFHTTPAuthenticationSchemeNegotiate, kCFHTTPAuthenticationSchemeNTLM, kCFHTTPAuthenticationSchemeDigest, kCFHTTPAuthenticationSchemeBasic }) {
        String schemeName = scheme;
        for (auto& challenge : offered) {
            if (equalIgnoringASCIICase(challenge.scheme, schemeName)) {
                m_offeredChallenges.append({ schemeName, challenge.challenge, challenge.realm });
                break;
            }
        }
    }
    if (m_offeredChallenges.isEmpty())
        return handshakeFailed(401);
    // Every protection space of one 401 carries the strongest challenge's realm, which for NTLM and Negotiate is the
    // host (measured against 10.9 NSURLSession).
    auto& strongest = m_offeredChallenges.first();
    m_offeredRealm = isConnectionBasedScheme(strongest.scheme) ? m_request.url().host().toString() : strongest.realm;

    // NTLM and Negotiate answer on the connection that asked, which is held while the answer is sought. Any other
    // refused connection is finished with.
    bool offersConnectionBasedScheme = m_offeredChallenges.containsIf([](auto& challenge) { return isConnectionBasedScheme(challenge.scheme); });
    if (offersConnectionBasedScheme && holdConnectionAfterRefusal())
        m_awaitingCredential = true;
    else
        resetConnection();

    // A URL that carries its own userinfo, or a credential the session holds for the space, answers the first
    // challenge directly: only a challenge nothing answers reaches the user.
    if (!m_authenticationFailureCount) {
        if (auto credential = proposedCredential(0)) {
            RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }, credential = WTF::move(*credential)]() mutable {
                protectedThis->continueWithCredential(WTF::move(credential), 0);
            });
            return false;
        }
    }
    presentChallenge(0);
    return false;
}

static NSString *authenticationMethodForScheme(const String& scheme)
{
    if (scheme == String(kCFHTTPAuthenticationSchemeBasic))
        return NSURLAuthenticationMethodHTTPBasic;
    if (scheme == String(kCFHTTPAuthenticationSchemeDigest))
        return NSURLAuthenticationMethodHTTPDigest;
    if (scheme == String(kCFHTTPAuthenticationSchemeNTLM))
        return NSURLAuthenticationMethodNTLM;
    if (scheme == String(kCFHTTPAuthenticationSchemeNegotiate))
        return NSURLAuthenticationMethodNegotiate;
    return nil;
}

RetainPtr<NSURLProtectionSpace> WebSocketTask::protectionSpace(size_t index)
{
    auto& url = m_request.url();
    bool secure = isSecureURL(url);
    return adoptNS([[NSURLProtectionSpace alloc] initWithHost:url.host().createNSString().get() port:url.port().value_or(secure ? 443 : 80)
        protocol:secure ? NSURLProtectionSpaceHTTPS : NSURLProtectionSpaceHTTP realm:m_offeredRealm.createNSString().get()
        authenticationMethod:authenticationMethodForScheme(m_offeredChallenges[index].scheme)]);
}

// Before any refusal: the credentials the URL names, then the session's default for the space. After one: the
// credential the server refused, which is what default handling sends again.
std::optional<Credential> WebSocketTask::proposedCredential(size_t index)
{
    if (m_authenticationFailureCount)
        return m_lastCredential;
    auto& url = m_request.url();
    if (url.hasCredentials())
        return Credential(url.user(), url.password(), CredentialPersistence::None);
    CheckedPtr session = networkSession();
    if (!session || m_storedCredentialsPolicy != StoredCredentialsPolicy::Use)
        return std::nullopt;
    RetainPtr space = protectionSpace(index);
    if (CheckedPtr storage = session->networkStorageSession()) {
        if (auto credential = storage->credentialStorage().get(m_partition, ProtectionSpace(space.get())); !credential.isEmpty())
            return credential;
    }
    if (NSURLCredential *credential = [session->nsCredentialStorage() defaultCredentialForProtectionSpace:space.get()])
        return Credential(credential);
    return std::nullopt;
}

// The schemes are put to the user strongest first; rejecting a protection space moves on to the next, and the
// handshake fails once none is left.
void WebSocketTask::presentChallenge(size_t index)
{
    if (m_state == State::Closed)
        return;
    if (index >= m_offeredChallenges.size()) {
        handshakeFailed(401);
        return;
    }
    auto proposed = proposedCredential(index);
    RetainPtr space = protectionSpace(index);
    AuthenticationChallenge challenge(ProtectionSpace(space.get()), proposed.value_or(Credential { }), m_authenticationFailureCount, m_response, { });
    askAuthenticationManager(WTF::move(challenge), [weakThis = ThreadSafeWeakPtr { *this }, index, proposed](AuthenticationChallengeDisposition disposition, const Credential& credential) mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis || protectedThis->m_state == State::Closed)
            return;
        switch (disposition) {
        case AuthenticationChallengeDisposition::UseCredential:
            protectedThis->continueWithCredential(credential.isEmpty() ? std::nullopt : std::optional { credential }, index);
            break;
        case AuthenticationChallengeDisposition::PerformDefaultHandling:
            protectedThis->continueWithCredential(WTF::move(proposed), index);
            break;
        case AuthenticationChallengeDisposition::Cancel:
            protectedThis->fail("Authentication cancelled"_s);
            break;
        case AuthenticationChallengeDisposition::RejectProtectionSpaceAndContinue:
            protectedThis->presentChallenge(index + 1);
            break;
        }
    });
}

void WebSocketTask::continueWithCredential(std::optional<Credential>&& credential, size_t index)
{
    if (m_state == State::Closed)
        return;
    auto scheme = m_offeredChallenges[index].scheme;
    m_awaitingCredential = false;
    // The userinfo has been spent on the field; a URL that still carried it would put it on the wire.
    URL hopURL = m_request.url();
    hopURL.removeCredentials();

    String authorization;
    if (isConnectionBasedScheme(scheme)) {
        // Negotiate without a credential uses the Kerberos ticket the user holds.
        if (credential || scheme == String(kCFHTTPAuthenticationSchemeNegotiate)) {
            m_connectionAuthentication = adoptNS([[WKWebSocketConnectionAuthentication alloc] initWithScheme:scheme.createNSString().get() host:hopURL.host().createNSString().get()
                user:credential ? credential->user().createNSString().get() : nil password:credential ? credential->password().createNSString().get() : nil]);
            authorization = [m_connectionAuthentication.get() authorizationForToken:nil];
        }
    } else if (credential) {
        // CFHTTPAuthentication builds the Basic or Digest field from a response carrying that challenge alone, under
        // the http(s) URL it answers.
        auto challengeResponse = makeString("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: "_s, m_offeredChallenges[index].challenge, "\r\n\r\n"_s).latin1();
        auto message = adoptCF(CFHTTPMessageCreateEmpty(nullptr, false));
        RetainPtr<CFHTTPAuthenticationRef> authentication;
        if (CFHTTPMessageAppendBytes(message.get(), byteCast<UInt8>(challengeResponse.span()).data(), challengeResponse.length())) {
            _CFHTTPMessageSetResponseURL(message.get(), httpURL(hopURL).createCFURL().get());
            authentication = adoptCF(CFHTTPAuthenticationCreateFromResponse(nullptr, message.get()));
        }
        if (authentication && CFHTTPAuthenticationIsValid(authentication.get(), nullptr)) {
            auto hop = adoptCF(CFHTTPMessageCreateRequest(nullptr, CFSTR("GET"), hopURL.createCFURL().get(), kCFHTTPVersion1_1));
            if (CFHTTPMessageApplyCredentials(hop.get(), authentication.get(), credential->user().createCFString().get(), credential->password().createCFString().get(), nullptr))
                authorization = adoptCF(CFHTTPMessageCopyHeaderFieldValue(hop.get(), CFSTR("Authorization"))).get();
        }
    }
    if (authorization.isEmpty()) {
        handshakeFailed(401);
        return;
    }
    m_lastCredential = WTF::move(credential);
    ++m_authenticationFailureCount;

    ResourceRequest authenticatedRequest = m_request;
    authenticatedRequest.setURL(WTF::move(hopURL));
    authenticatedRequest.setHTTPHeaderField(HTTPHeaderName::Authorization, authorization);
    authenticatedRequest.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    continueWithHandshakeRequest(WTF::move(authenticatedRequest), 401);
}

// A handshake that answers with a redirect is followed on a new connection, with NetworkTaskCocoa's cookie policy
// applied to the continuing request.
bool WebSocketTask::followRedirect()
{
    auto location = m_response.httpHeaderField(HTTPHeaderName::Location);
    URL newURL = location.isEmpty() ? URL { } : URL { m_request.url(), location };
    bool reachable = newURL.protocolIs("ws"_s) || newURL.protocolIs("wss"_s) || newURL.protocolIs("http"_s) || newURL.protocolIs("https"_s);
    if (!newURL.isValid() || newURL.host().isEmpty() || !reachable)
        return handshakeFailed(m_response.httpStatusCode());
    if (++m_redirectCount > maximumRedirects) {
        fail("Too many HTTP redirects"_s);
        return false;
    }

    ResourceRequest newRequest = m_request;
    newRequest.setURL(URL { newURL });
    // The Cookie field belongs to the hop that sent it; the next hop's is looked up for its own URL.
    newRequest.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    if (!areSameOrigin(m_request.url(), newURL))
        newRequest.removeHTTPHeaderField(HTTPHeaderName::Authorization);
    // Fetch: a request whose origin is not the redirect target's carries an opaque origin from there on.
    if (newRequest.hasHTTPHeaderField(HTTPHeaderName::Origin) && !areSameOrigin(m_request.url(), newURL))
        newRequest.setHTTPHeaderField(HTTPHeaderName::Origin, "null"_s);

    auto redirectingURL = m_request.url();
    resetConnection();
    if (m_cookiesBlocked) {
        if (m_storedCredentialsPolicy != StoredCredentialsPolicy::EphemeralStateless && NetworkTaskCocoa::needsFirstPartyCookieBlockingLatchModeQuirk(newRequest.firstPartyForCookies(), newRequest.url(), redirectingURL))
            m_cookiesBlocked = false;
    } else
        updateCookieBlocking(newRequest);
    RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }, newRequest = WTF::move(newRequest), status = m_response.httpStatusCode()]() mutable {
        protectedThis->continueWithHandshakeRequest(WTF::move(newRequest), status);
    });
    return false;
}

void WebSocketTask::continueWithHandshakeRequest(ResourceRequest&& request, int status)
{
    if (m_state == State::Closed)
        return;
    if (request.isNull()) {
        handshakeFailed(status);
        return;
    }
    m_request = WTF::move(request);
    if (!m_request.hasHTTPHeaderField(HTTPHeaderName::Cookie)) {
        if (auto cookie = cookieHeader(); !cookie.isEmpty())
            m_request.setHTTPHeaderField(HTTPHeaderName::Cookie, cookie);
    }
    if (m_transportOpen && m_stream) {
        armHandshakeDeadline(handshakeTimeout(m_request));
        m_state = State::Handshaking;
        sendHandshake();
    } else
        startConnection();
}

bool WebSocketTask::handshakeFailed(int status)
{
    fail(makeString("WebSocket handshake failed (HTTP "_s, status, ')'));
    return false;
}

// ----- frames (RFC 6455) -----

void WebSocketTask::parseFrames()
{
    size_t offset = 0;
    auto bytes = m_inBuffer.span();
    while (bytes.size() - offset >= 2) {
        size_t p = offset;
        uint8_t b0 = bytes[p++];
        uint8_t b1 = bytes[p++];
        bool fin = b0 & 0x80;
        // This client never offers Sec-WebSocket-Extensions, so a set RSV bit means the peer is using an extension that
        // was never negotiated. RFC 6455 3.2 requires failing the connection.
        if (b0 & 0x70) {
            failProtocol("WebSocket frame sets a reserved bit without a negotiated extension"_s);
            return;
        }
        uint8_t opcode = b0 & 0x0F;
        uint64_t length = b1 & 0x7F;
        // RFC 6455 5.1: a server never masks a frame it sends.
        if (b1 & 0x80) {
            failProtocol("WebSocket frame from the server is masked"_s);
            return;
        }
        // RFC 6455 5.2: the payload length is carried in the fewest bytes that hold it, and the 64-bit form's most
        // significant bit is 0.
        if (length == 126) {
            if (bytes.size() - p < 2)
                break;
            length = (static_cast<uint64_t>(bytes[p]) << 8) | bytes[p + 1];
            p += 2;
            if (length < 126) {
                failProtocol("WebSocket frame length is not minimally encoded"_s);
                return;
            }
        } else if (length == 127) {
            if (bytes.size() - p < 8)
                break;
            length = 0;
            for (int i = 0; i < 8; ++i)
                length = (length << 8) | bytes[p + i];
            p += 8;
            if (length & 0x8000000000000000ULL) {
                failProtocol("WebSocket frame length has its most significant bit set"_s);
                return;
            }
            if (length <= 0xFFFF) {
                failProtocol("WebSocket frame length is not minimally encoded"_s);
                return;
            }
        }
        // The opcode and the control-frame rules are settled before the payload is waited for.
        switch (opcode) {
        case 0x0:
        case 0x1:
        case 0x2:
        case 0x8:
        case 0x9:
        case 0xA:
            break;
        default:
            failProtocol("WebSocket frame uses a reserved opcode"_s);
            return;
        }
        // RFC 6455 5.5: a control frame is never fragmented and carries at most 125 bytes.
        if (opcode & 0x8) {
            if (!fin) {
                failProtocol("WebSocket control frame is fragmented"_s);
                return;
            }
            if (length > 125) {
                failProtocol("WebSocket control frame payload exceeds 125 bytes"_s);
                return;
            }
        }
        if (static_cast<uint64_t>(bytes.size() - p) < length)
            break;
        auto payload = bytes.subspan(p, static_cast<size_t>(length));
        p += static_cast<size_t>(length);
        offset = p;
        handleFrame(opcode, fin, payload);
        // The handler may end the connection, or append to the buffer while it is being parsed.
        if (m_state == State::Closed)
            return;
        bytes = m_inBuffer.span();
    }
    if (offset)
        m_inBuffer.removeAt(0, offset);
}

void WebSocketTask::handleFrame(uint8_t opcode, bool fin, std::span<const uint8_t> payload)
{
    switch (opcode) {
    case 0x0:
    case 0x1:
    case 0x2:
        // RFC 6455 5.4: a continuation belongs to a message already begun, and a data frame starts a message only when
        // no fragmented one is in progress.
        if (!opcode && m_messageOpcode < 0) {
            failProtocol("WebSocket continuation frame has no message to continue"_s);
            return;
        }
        if (opcode) {
            if (m_messageOpcode >= 0) {
                failProtocol("WebSocket data frame interrupts a fragmented message"_s);
                return;
            }
            m_messageBuffer.clear();
            m_messageOpcode = opcode;
        }
        m_messageBuffer.append(payload);
        if (fin) {
            auto message = std::exchange(m_messageBuffer, { });
            int messageOpcode = std::exchange(m_messageOpcode, -1);
            RefPtr channel = m_channel.get();
            if (messageOpcode == 0x1) {
                // RFC 6455 makes an undecodable text frame a failure of the connection (close 1007).
                auto text = message.isEmpty() ? emptyString() : String::fromUTF8(message.span());
                if (text.isNull()) {
                    fail("WebSocket text frame is not valid UTF-8"_s);
                    return;
                }
                if (channel)
                    channel->didReceiveText(text);
            } else if (channel)
                channel->didReceiveBinaryData(message.span());
        }
        break;
    case 0x8: {
        // RFC 6455 5.5.1: a Close payload is empty or carries a two-byte status code first, and 7.4.1 reserves
        // 1005/1006/1015 for the local end to report -- none of the three, nor a code below 1000, may appear on the wire.
        if (payload.size() == 1) {
            failProtocol("WebSocket Close frame payload is one byte"_s);
            return;
        }
        uint16_t code = ThreadableWebSocketChannel::CloseEventCodeNoStatusRcvd;
        String reason = emptyString();
        if (payload.size() >= 2) {
            code = (payload[0] << 8) | payload[1];
            if (code < 1000 || code == 1005 || code == 1006 || code == 1015) {
                failProtocol("WebSocket Close frame carries a status code that may not be sent"_s);
                return;
            }
            // WebSocketTaskCocoa reads a reason that is not UTF-8 as none.
            if (payload.size() > 2) {
                if (auto decoded = String::fromUTF8(payload.subspan(2)); !decoded.isNull())
                    reason = WTF::move(decoded);
            }
        }
        if (!m_sentClose) {
            m_sentClose = true;
            // A Close with no payload carries no status code (reported as 1005); it is echoed with an empty payload.
            Vector<uint8_t> echo;
            if (payload.size() >= 2)
                echo = { payload[0], payload[1] };
            sendFrame(0x8, echo.span());
            flushOutput();
        }
        m_state = State::Closing;
        deliverClose(code, reason);
        teardownTransport();
        break;
    }
    case 0x9:
        sendFrame(0xA, payload);
        break;
    default:
        break;
    }
}

// ----- the handshake deadline -----

void WebSocketTask::armHandshakeDeadline(Seconds remaining)
{
    disarmHandshakeDeadline();
    if (remaining.isInfinity()) {
        m_handshakeDeadline = std::nullopt;
        return;
    }
    remaining = std::max(0_s, remaining);
    m_handshakeDeadline = MonotonicTime::now() + remaining;
    m_handshakeTimer.startOneShot(remaining);
}

// Returns the time the deadline had left, infinity for none.
Seconds WebSocketTask::disarmHandshakeDeadline()
{
    m_handshakeTimer.stop();
    if (!m_handshakeDeadline)
        return Seconds::infinity();
    return std::max(0_s, *m_handshakeDeadline - MonotonicTime::now());
}

void WebSocketTask::handshakeTimedOut()
{
    if (m_state != State::Connecting && m_state != State::Handshaking)
        return;
    fail("The request timed out."_s);
}

// ----- failure and teardown -----

// A violation of the framing or handshake rules fails the connection; RFC 6455 7.1.7 has an established connection
// send a Close frame with 1002 first.
void WebSocketTask::failProtocol(const String& reason)
{
    if ((m_state == State::Open || m_state == State::Closing) && !m_sentClose) {
        sendCloseFrame(ThreadableWebSocketChannel::CloseEventCodeProtocolError, { });
        flushOutput();
    }
    fail(reason);
}

// A failed connection reports its handshake response, when one came before the failure, then the error and an
// abnormal closure, as WebSocketTaskCocoa reported a failed task's.
void WebSocketTask::fail(const String& reason)
{
    if (m_state == State::Closed)
        return;
    bool deliver = !m_didClose;
    teardownTransport();
    RefPtr channel = m_channel.get();
    if (!deliver || !channel)
        return;
    if (!m_didConnect && !m_response.isNull())
        channel->didReceiveHandshakeResponse(ResourceResponse { m_response });
    channel->didReceiveMessageError(String { reason });
    deliverClose(ThreadableWebSocketChannel::CloseEventCodeAbnormalClosure, emptyString());
}

void WebSocketTask::deliverClose(unsigned short code, const String& reason)
{
    if (std::exchange(m_didClose, true))
        return;
    if (RefPtr channel = m_channel.get())
        channel->didClose(code, reason);
}

// Messages that never went out complete when the connection ends, on a later turn of the run loop, as a session
// task's send completions arrive: the channel may be ending the task from its own destructor.
void WebSocketTask::teardownTransport()
{
    m_state = State::Closed;
    closeTransport();
    Vector<CompletionHandler<void()>> completions;
    for (auto& outgoing : std::exchange(m_outQueue, { })) {
        if (outgoing.completion)
            completions.append(WTF::move(outgoing.completion));
    }
    for (auto& outgoing : std::exchange(m_heldSends, { })) {
        if (outgoing.completion)
            completions.append(WTF::move(outgoing.completion));
    }
    m_outOffset = 0;
    if (completions.isEmpty())
        return;
    RunLoop::mainSingleton().dispatch([completions = WTF::move(completions)]() mutable {
        for (auto& completion : completions)
            completion();
    });
}

void WebSocketTask::closeTransport()
{
    disarmHandshakeDeadline();
    m_transportOpen = false;
    if (RefPtr stream = std::exchange(m_stream, nullptr))
        stream->close();
}

} // namespace WebKit
