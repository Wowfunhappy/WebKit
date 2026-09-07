/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
 */

// NSURLSessionWebSocketTask / NSURLSessionWebSocketMessage are macOS 10.15+ and absent on 10.9, and
// this WebKit has no other WebSocket transport (WebSocketTaskCocoa is the only channel). This file is
// force-loaded into WebKit.framework (alongside WKWebInspectorProxyObjCAdapter.mm) so its strong class
// definition satisfies the weak `_OBJC_CLASS_$_NSURLSessionWebSocketMessage` import in
// WebSocketTaskCocoa.mm. It provides:
//   * NSURLSessionWebSocketMessage  — the value object WebSocketTaskCocoa constructs.
//   * WKWebSocketStream             — an RFC 6455 client over CFStream (TLS via
//     kCFStreamSocketSecurityLevelNegotiatedSSL) that masquerades as the NSURLSessionWebSocketTask
//     WebSocketTaskCocoa drives (resume/cancel/currentRequest/response/closeCode/taskIdentifier/
//     receiveMessageWithCompletionHandler:/sendMessage:completionHandler:/cancelWithCloseCode:reason:).
//   * -[NSURLSession webSocketTaskWithRequest:] — a WebKit-scoped polyfill block (wk_selref_scope.h)
//     installed on the NSURLSession cluster; NetworkSessionCocoa::createWebSocketTask sends it
//     (respondsToSelector-guarded) and receives a WKWebSocketStream.
// On open/close it invokes the session delegate's NSURLSessionWebSocketDelegate methods (passing itself
// as the task) exactly as NSURLSession would, so the webSocketDataTaskMap -> WebSocketTask::
// didConnect/didClose path is upstream's. Delegate + receive callbacks are delivered on the SESSION'S
// delegateQueue, which is where NSURLSession delivers them (see wsDispatchToCallbackQueue); socket I/O
// runs on a private serial queue.
//
// Compiled with -fobjc-arc (see MavericksSupport/polyfill/build-polyfill.sh). The CFStream client context retains self, so the
// stream outlives any in-flight socket callbacks until teardown clears the client.

#import "wk_selref_scope.h"
#import <CFNetwork/CFNetwork.h>
#import <Security/Security.h>
#import "wk_url_coding.h"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>
#import <atomic>

// The whole NSURLSessionWebSocket surface is 10.15+ in the SDK and absent on the 10.9 runtime -- which
// is what this file exists to supply: it defines NSURLSessionWebSocketMessage and the task that
// masquerades as NSURLSessionWebSocketTask below. Every reference in this file is to those definitions.
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// ---------------------------------------------------------------------------------------------------
// NSURLSessionWebSocketMessage (value object).
// ---------------------------------------------------------------------------------------------------

@implementation NSURLSessionWebSocketMessage {
    NSURLSessionWebSocketMessageType _type;
    NSData *_data;
    NSString *_string;
}

- (instancetype)initWithData:(NSData *)data
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeData;
        _data = data;
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init])) {
        _type = NSURLSessionWebSocketMessageTypeString;
        _string = [string copy];
    }
    return self;
}

- (NSURLSessionWebSocketMessageType)type { return _type; }
- (NSData *)data { return _data; }
- (NSString *)string { return _string; }

@end

// ---------------------------------------------------------------------------------------------------
// WKWebSocketStream: RFC 6455 client over CFStream, shaped like NSURLSessionWebSocketTask.
// ---------------------------------------------------------------------------------------------------

static NSString * const kWebSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

typedef NS_ENUM(NSInteger, WKWSState) {
    WKWSStateConnecting,
    WKWSStateProxyConnect,  // awaiting the proxy's "200 Connection established"
    WKWSStateHandshaking,
    WKWSStateOpen,
    WKWSStateClosing,
    WKWSStateClosed,
};

@interface WKWebSocketStream : NSObject {
    NSURLRequest *_request;         // the hop being made now
    NSURLRequest *_originalRequest; // the request the task was created with
    NSUInteger _redirectCount;
    NSString *_requestedProtocol;
    NSString *_acceptKey;           // expected Sec-WebSocket-Accept
    NSURLResponse *_response;       // handshake response (NSHTTPURLResponse)

    __weak NSURLSession *_session;
    __weak id _delegate;            // session delegate (NSURLSessionWebSocketDelegate)

    NSUInteger _taskIdentifier;
    NSInteger _closeCode;

    CFReadStreamRef _readStream;
    CFWriteStreamRef _writeStream;
    dispatch_queue_t _ioQueue;      // socket I/O + frame parsing run here

    WKWSState _state;
    BOOL _writeStreamOpen;
    BOOL _sentClose;
    uint16_t _sentCloseCode;        // status the close reports; 1005 when the sent Close frame carried no code

    BOOL _secure;                   // wss
    BOOL _peerTrustAnswered;        // the server's certificate has been put to the delegate and accepted
    BOOL _peerTrustPending;         // a server-trust challenge is with the delegate, awaiting its answer
    BOOL _usingProxy;               // tunneling through an HTTP CONNECT proxy
    NSString *_targetHost;          // origin host (for CONNECT + TLS peer name)
    UInt32 _targetPort;             // origin port

    NSMutableData *_inBuffer;       // raw bytes from the socket (handshake then frames)
    NSMutableData *_outBuffer;      // bytes pending write to the socket
    NSMutableData *_messageBuffer;  // reassembly of a fragmented data message
    int _messageOpcode;             // opcode of the in-progress data message (1 text, 2 binary)

    NSHTTPCookieStorage *_explicitCookieStorage; // the jar this task alone uses, when it was given one
    NSURL *_siteForCookies;
    BOOL _isTopLevelNavigation;
    NSArray<NSHTTPCookie *> *(^_cookieTransform)(NSArray<NSHTTPCookie *> *);

    NSInteger _maximumMessageSize;  // largest message this task will assemble

    NSLock *_lock;                  // guards the receive plumbing below
    NSMutableArray *_incomingMessages;
    void (^_pendingReceive)(NSURLSessionWebSocketMessage *, NSError *);
    NSError *_pendingError;
    BOOL _hasPendingClose;          // a close held back until the queued messages have been handed out
    uint16_t _pendingCloseCode;
    NSData *_pendingCloseReason;
}
- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier;
@end

// The script a PAC URL names, fetched once per URL for the life of the process, as CFNetwork's own PAC
// machinery caches it -- otherwise every WebSocket handshake pays a network round trip for the same
// bytes. The fetch is bounded because it runs on the socket's serial queue: an unreachable PAC host
// would otherwise leave the WebSocket neither connected nor failed for as long as it hung.
static NSString *wkProxyAutoConfigurationScriptForURL(NSURL *scriptURL)
{
    static NSMutableDictionary *cache;
    static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;
    NSString *key = [scriptURL absoluteString];
    if (!key.length)
        return nil;

    pthread_mutex_lock(&cacheLock);
    NSString *cached = cache[key];
    pthread_mutex_unlock(&cacheLock);
    if (cached)
        return cached;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:scriptURL
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:NULL error:NULL];
    NSString *script = data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]) : nil;

    // Only a fetched script is remembered. A fetch that failed is retried at full price on the next
    // connect, as the trust-result cache in methods/Foundation.m does with a failed evaluation: one
    // unreachable moment must not become a permanent answer for the life of the process.
    if (script.length) {
        pthread_mutex_lock(&cacheLock);
        if (!cache)
            cache = [[NSMutableDictionary alloc] init];
        cache[key] = script;
        pthread_mutex_unlock(&cacheLock);
    }
    return script;
}

// CFNetworkCopyProxiesForURL does not run a PAC: for an auto-configuration setup it returns an entry
// naming the script (by URL or inline source) that the caller has to execute. Resolving it here is what
// makes the rest of the loop mean "what the system would do" for a PAC-configured machine too; without
// it a PAC entry matches no branch and the connection silently goes direct while every other load is
// proxied. CFNetworkCopyProxiesForAutoConfigurationScript is the synchronous form, which suits this
// path -- it already opens its proxy tunnel with a blocking connect.
static NSArray *wkResolveProxyAutoConfiguration(NSArray *proxies, NSURL *targetURL)
{
    if (!proxies.count)
        return proxies;

    NSMutableArray *resolved = [NSMutableArray array];
    for (NSDictionary *proxy in proxies) {
        NSString *type = proxy[(__bridge NSString *)kCFProxyTypeKey];
        if (![type isEqualToString:(__bridge NSString *)kCFProxyTypeAutoConfigurationURL]
            && ![type isEqualToString:(__bridge NSString *)kCFProxyTypeAutoConfigurationJavaScript]) {
            [resolved addObject:proxy];
            continue;
        }

        NSString *script = proxy[(__bridge NSString *)kCFProxyAutoConfigurationJavaScriptKey];
        if (!script.length) {
            NSURL *scriptURL = proxy[(__bridge NSString *)kCFProxyAutoConfigurationURLKey];
            if (scriptURL)
                script = wkProxyAutoConfigurationScriptForURL(scriptURL);
        }
        if (!script.length)
            continue;

        CFErrorRef error = NULL;
        NSArray *fromScript = (__bridge_transfer NSArray *)CFNetworkCopyProxiesForAutoConfigurationScript(
            (__bridge CFStringRef)script, (__bridge CFURLRef)targetURL, &error);
        if (error)
            CFRelease(error);
        if (fromScript.count)
            [resolved addObjectsFromArray:fromScript];
    }
    return resolved;
}

// CFNetwork stops following redirects after 16 hops and fails the task with
// NSURLErrorHTTPTooManyRedirects; a WebSocket handshake redirect loop ends the same way here.
static const NSUInteger kWKWSMaximumRedirects = 16;

// Cookies for a WebSocket URL are the cookies its http(s) equivalent would get:
// -[NSHTTPCookieStorage cookiesForURL:] treats only http/https as a secure scheme, so a lookup under a
// ws://wss:// URL silently drops every Secure cookie (e.g. figma's __Host-figma.authn / figma.session),
// leaving the handshake unauthenticated. WebKit looks WebSocket cookies up the same way
// (WebSocketHandshake::httpURLForAuthenticationAndCookies).
static NSURL *wsCookieURL(NSURL *url)
{
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"ws"] && ![scheme isEqualToString:@"wss"])
        return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = [scheme isEqualToString:@"wss"] ? @"https" : @"http";
    return components.URL ?: url;
}

// The cookie storage a task is pointed at arrives as CFNetwork's own reference to it.
typedef struct OpaqueCFHTTPCookieStorage *WKCFHTTPCookieStorageRef;

@interface NSHTTPCookieStorage (WKPolyfillCFStorage)
- (id)_initWithCFHTTPCookieStorage:(WKCFHTTPCookieStorageRef)storage;
@end

// The same-site disposition WebKit stamped on this request (ResourceRequestCocoa's
// doUpdateResourceRequest), which is the answer this port reads for every other load -- c/CFNetwork.c's
// wk_contextOfRequest takes the same two properties off the CFURLRequest. The site is compared with the
// URL of the hop being made, which is why the stamp is passed on rather than turned into a yes/no here.
static NSURL *wsSiteForCookies(NSURLRequest *request)
{
    id site = [NSURLProtocol propertyForKey:@"_kCFHTTPCookiePolicyPropertySiteForCookies" inRequest:request];
    return [site isKindOfClass:[NSURL class]] ? site : nil;
}

static BOOL wsIsTopLevelNavigation(NSURLRequest *request)
{
    id isTopLevel = [NSURLProtocol propertyForKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation" inRequest:request];
    return [isTopLevel isKindOfClass:[NSNumber class]] ? [isTopLevel boolValue] : NO;
}

static NSHTTPCookieStorage *wsSessionCookieStorage(NSURLSession *session)
{
    return session.configuration.HTTPCookieStorage ?: [NSHTTPCookieStorage sharedHTTPCookieStorage];
}

@interface NSHTTPCookieStorage (WKPolyfillPolicyProperties)
- (void)_getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)policyProperties completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler;
@end

// The Cookie header NSURLSession attaches to each hop of a task whose request handles cookies.
// HTTPShouldHandleCookies is how a caller withholds cookies from one request, and both
// NetworkSessionCocoa::createWebSocketTask and NetworkTaskCocoa::willPerformHTTPRedirection clear it on
// the request when shouldBlockCookies() says so. This image is WebKit.framework, so the send reaches the
// polyfill's REPLACE body (methods/Foundation.m), which keeps the flag for a ws:// URL where 10.9's own
// method does not.
//
// The cookies come back through the same policy-carrying read the rest of this port uses
// (NetworkStorageSession::cookiesForURL), so a handshake to another site gets exactly the cookies an
// http request to it would; the site this read is for is WebKit's own same-site answer, stamped on the
// request it made or set on the task when a redirect changed it.
static void wsApplyStoredCookies(NSHTTPCookieStorage *storage, NSMutableURLRequest *request, NSURL *siteForCookies, BOOL isTopLevelNavigation)
{
    if (![request HTTPShouldHandleCookies] || [request valueForHTTPHeaderField:@"Cookie"])
        return;
    NSURL *cookieURL = wsCookieURL(request.URL);
    NSMutableDictionary *policyProperties = [NSMutableDictionary dictionary];
    policyProperties[@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation"] = @(isTopLevelNavigation);
    if (siteForCookies)
        policyProperties[@"_kCFHTTPCookiePolicyPropertySiteForCookies"] = wsCookieURL(siteForCookies);
    __block NSArray<NSHTTPCookie *> *cookies = nil;
    [storage _getCookiesForURL:cookieURL mainDocumentURL:request.mainDocumentURL partition:nil
        policyProperties:policyProperties completionHandler:^(NSArray<NSHTTPCookie *> *result) { cookies = result; }];
    if (!cookies.count)
        return;
    NSString *header = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
    if (header.length)
        [request setValue:header forHTTPHeaderField:@"Cookie"];
}

// A handshake response's Set-Cookie fields reach the session's storage, as they do for every other
// NSURLSession task.
static void wsStoreCookiesFromResponse(NSHTTPCookieStorage *storage, NSHTTPURLResponse *response, NSURLRequest *request,
    NSArray<NSHTTPCookie *> *(^cookieTransform)(NSArray<NSHTTPCookie *> *))
{
    if (![request HTTPShouldHandleCookies])
        return;
    // The http(s) form of the handshake's URL, which is the origin the cookie rules are decided against:
    // the parser this calls holds the field to all of them (methods/Foundation.m), so a ws:// handshake
    // is a non-secure origin and a wss:// one is secure, exactly as the equivalent load would be.
    NSURL *cookieURL = wsCookieURL(response.URL ?: request.URL);
    NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:cookieURL];
    // The transform is where NetworkTaskCocoa caps the expiry of a cookie set through third-party CNAME
    // or address cloaking, and where a partitioned store rewrites the cookies it takes in.
    if (cookieTransform)
        cookies = cookieTransform(cookies);
    if (!cookies.count)
        return;
    [storage setCookies:cookies forURL:cookieURL mainDocumentURL:request.mainDocumentURL];
}

// Two URLs are same-origin when scheme, host and effective port all match; ws and wss carry http's and
// https's default ports.
static BOOL wsURLsAreSameOrigin(NSURL *a, NSURL *b)
{
    NSString *schemeA = a.scheme.lowercaseString;
    NSString *schemeB = b.scheme.lowercaseString;
    if (![schemeA isEqualToString:schemeB])
        return NO;
    if (!a.host.length || [a.host caseInsensitiveCompare:b.host] != NSOrderedSame)
        return NO;
    BOOL secure = [schemeA isEqualToString:@"wss"] || [schemeA isEqualToString:@"https"];
    unsigned defaultPort = secure ? 443 : 80;
    unsigned portA = a.port ? a.port.unsignedIntValue : defaultPort;
    unsigned portB = b.port ? b.port.unsignedIntValue : defaultPort;
    return portA == portB;
}

// A server-trust challenge for the certificate |trust| offers, shaped as the one an NSURLSession task
// carries: the protection space names the host and port the connection is to and holds the trust
// itself, which is what a delegate reads to decide (WebKit's reads it through -serverTrust). Built
// through CFNetwork's own protection space because that is the only kind that can carry a trust
// (wk_createProtectionSpace, c/CFNetwork.c).
enum { kWSProtectionSpaceHTTPS = 2, kWSAuthenticationSchemeServerTrust = 8 };

@interface WKWebSocketChallengeSender : NSObject <NSURLAuthenticationChallengeSender>
@end

@implementation WKWebSocketChallengeSender
// The disposition travels through the delegate's completion handler, as it does for every
// NSURLSessionTask challenge; these are the sender methods a caller may still send.
- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { }
- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { }
- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge { }
@end

@interface NSURLProtectionSpace (WKPolyfillCFProtectionSpace)
- (id)_initWithCFURLProtectionSpace:(CFTypeRef)space;
@end

static NSURLAuthenticationChallenge *wsServerTrustChallenge(NSURL *url, SecTrustRef trust)
{
    NSNumber *port = url.port;
    CFTypeRef cfSpace = wk_createProtectionSpace((__bridge CFStringRef)url.host,
        port ? port.intValue : 443, kWSProtectionSpaceHTTPS, NULL,
        kWSAuthenticationSchemeServerTrust, NULL, trust);
    if (!cfSpace)
        return nil;
    NSURLProtectionSpace *space = [[NSURLProtectionSpace alloc] _initWithCFURLProtectionSpace:cfSpace];
    CFRelease(cfSpace);
    if (!space)
        return nil;
    return [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:nil
        previousFailureCount:0 failureResponse:nil error:nil
        sender:[[WKWebSocketChallengeSender alloc] init]];
}

// The queue a callback belongs on. NSURLSession delivers delegate messages and completion handlers on the
// session's delegateQueue, so this polyfill does too rather than hardcoding the main queue: hardcoding was
// correct only for a caller whose delegateQueue happens to be the main one, which is caller-specific
// correctness of exactly the kind a polyfill must not have. A session created without a delegateQueue gets
// one of its own from NSURLSession, so the property is the authority in every case; the main queue remains
// the fallback only if there is no session left to ask (the task outliving its session during teardown).
static void wsDispatchToCallbackQueue(NSURLSession *session, void (^work)(void))
{
    NSOperationQueue *delegateQueue = [session delegateQueue];
    if (delegateQueue) {
        [delegateQueue addOperationWithBlock:work];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), work);
}

@implementation WKWebSocketStream

- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier
{
    if (!(self = [super init]))
        return nil;
    _request = request;
    _originalRequest = request;
    _requestedProtocol = protocol.length ? protocol : nil;
    _session = session;
    _delegate = session.delegate;
    _taskIdentifier = identifier;
    _closeCode = 0;
    _state = WKWSStateConnecting;
    _messageOpcode = -1;
    _inBuffer = [NSMutableData data];
    _outBuffer = [NSMutableData data];
    _messageBuffer = [NSMutableData data];
    _incomingMessages = [NSMutableArray array];
    _maximumMessageSize = 1024 * 1024;
    _lock = [[NSLock alloc] init];
    _ioQueue = dispatch_queue_create("com.apple.WebKit.LegacyWebSocket", DISPATCH_QUEUE_SERIAL);
    return self;
}

// ----- NSURLSessionWebSocketTask-shaped interface used by WebSocketTaskCocoa -----

- (NSUInteger)taskIdentifier { return _taskIdentifier; }
- (NSURLRequest *)currentRequest
{
    // Read from the delegate queue while the socket queue is following a redirect.
    [_lock lock];
    NSURLRequest *request = _request;
    [_lock unlock];
    return request;
}
- (NSURLRequest *)originalRequest { return _originalRequest; }
- (NSURLResponse *)response { return _response; }
- (NSInteger)closeCode { return _closeCode; }
// The largest message a receive will assemble, 1 MiB by default as NSURLSessionWebSocketTask's is; a
// frame, or a fragmented message, that would exceed it fails the receive with
// NSURLErrorDataLengthExceedsMaximum. A limit of 0 or less means no limit.
- (void)setMaximumMessageSize:(NSInteger)size { _maximumMessageSize = size; }
- (NSInteger)maximumMessageSize { return _maximumMessageSize; }
// What the session delegate reads off a task while it answers for it: its state, and the two
// transfer-detail properties NetworkSessionCocoa consults on a challenge. 10.9 collects no task metrics
// (see -[NSURLConnection _timingData] in methods/Foundation.m) and this port makes no preconnect, so
// those are what a task of this platform has to say.
- (NSURLSessionTaskState)state
{
    switch (_state) {
    case WKWSStateClosed:
        return NSURLSessionTaskStateCompleted;
    case WKWSStateClosing:
        return NSURLSessionTaskStateCanceling;
    default:
        return NSURLSessionTaskStateRunning;
    }
}
- (id)_incompleteTaskMetrics { return nil; }
- (BOOL)_preconnect { return NO; }
// The per-task cookie controls NetworkTaskCocoa sets, honoured rather than recorded: this task does its
// own cookie work, so the site-for-cookies WebKit computed is the one its reads are made under, the jar
// it is pointed at is the one it reads and writes, and the transform runs over what its handshake
// response sets.
- (void)set_siteForCookies:(NSURL *)site { _siteForCookies = site; }
- (NSURL *)_siteForCookies { return _siteForCookies; }
- (void)set_isTopLevelNavigation:(BOOL)isTopLevelNavigation { _isTopLevelNavigation = isTopLevelNavigation; }
- (BOOL)_isTopLevelNavigation { return _isTopLevelNavigation; }
- (void)set_cookieTransformCallback:(NSArray<NSHTTPCookie *> *(^)(NSArray<NSHTTPCookie *> *))callback
{
    _cookieTransform = [callback copy];
}
- (NSArray<NSHTTPCookie *> *(^)(NSArray<NSHTTPCookie *> *))_cookieTransformCallback { return _cookieTransform; }
- (void)_setExplicitCookieStorage:(WKCFHTTPCookieStorageRef)storage
{
    _explicitCookieStorage = storage ? [[NSHTTPCookieStorage alloc] _initWithCFHTTPCookieStorage:storage] : nil;
}
- (NSHTTPCookieStorage *)cookieStorage
{
    return _explicitCookieStorage ?: wsSessionCookieStorage(_session);
}

- (void)setCurrentRequest:(NSURLRequest *)request
{
    [_lock lock];
    _request = request;
    [_lock unlock];
}

- (void)resume
{
    dispatch_async(_ioQueue, ^{
        // The first hop's Cookie header is attached here: by the time a task is resumed it has been
        // given whatever cookie storage and site-for-cookies its creator meant it to use.
        NSMutableURLRequest *request = [[self currentRequest] mutableCopy];
        wsApplyStoredCookies([self cookieStorage], request, wsSiteForCookies(request) ?: self->_siteForCookies,
            wsSiteForCookies(request) ? wsIsTopLevelNavigation(request) : self->_isTopLevelNavigation);
        [self setCurrentRequest:request];
        [self startConnection];
    });
}

- (void)cancel
{
    dispatch_async(_ioQueue, ^{ [self teardownStreams]; });
}

// Sends a Close frame and leaves the connection open until the peer's Close frame (processInput) or its
// EOF (handleReadEvent) completes the closing handshake and delivers didCloseWithCode:.
- (void)cancelWithCloseCode:(NSInteger)closeCode reason:(NSData *)reason
{
    dispatch_async(_ioQueue, ^{
        if (self->_state != WKWSStateOpen) {
            [self teardownStreams];
            return;
        }
        self->_state = WKWSStateClosing;
        [self sendCloseFrameWithCode:(uint16_t)closeCode reason:reason];
    });
}

// Messages the peer sent are handed out before any close or error that followed them. WebKit stops
// asking for more the moment either arrives (WebSocketTaskCocoa's readNextMessage), so a queue drained
// in the other order loses every message that shared a read with the peer's Close frame.
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))handler
{
    [_lock lock];
    if (_incomingMessages.count) {
        NSURLSessionWebSocketMessage *msg = _incomingMessages.firstObject;
        [_incomingMessages removeObjectAtIndex:0];
        BOOL closeFollows = !_incomingMessages.count && _hasPendingClose;
        uint16_t closeCode = _pendingCloseCode;
        NSData *closeReason = _pendingCloseReason;
        if (closeFollows) {
            _hasPendingClose = NO;
            _pendingCloseReason = nil;
        }
        // Enqueued while the lock is held: a close deciding stash-vs-dispatch in the gap would land on
        // the delegate queue ahead of this message.
        wsDispatchToCallbackQueue(_session, ^{ handler(msg, nil); });
        if (closeFollows)
            [self dispatchDidCloseWithCode:closeCode reason:closeReason];
        [_lock unlock];
        return;
    }
    if (_pendingError) {
        NSError *err = _pendingError;
        _pendingError = nil;
        wsDispatchToCallbackQueue(_session, ^{ handler(nil, err); });
        [_lock unlock];
        return;
    }
    _pendingReceive = [handler copy];
    [_lock unlock];
}

- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError *))completionHandler
{
    int opcode = message.type == NSURLSessionWebSocketMessageTypeString ? 0x1 : 0x2;
    NSData *payload = message.type == NSURLSessionWebSocketMessageTypeString
        ? [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
    // A string that will not encode as UTF-8 cannot be sent as a text frame; saying nothing and reporting
    // success would lose the message silently.
    if (message.type == NSURLSessionWebSocketMessageTypeString && !payload) {
        if (completionHandler) {
            NSError *encodingError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData
                userInfo:@{ NSLocalizedDescriptionKey: @"WebSocket text message is not valid UTF-8" }];
            wsDispatchToCallbackQueue(_session, ^{ completionHandler(encodingError); });
        }
        return;
    }
    dispatch_async(_ioQueue, ^{
        // The completion handler reports what actually happened to the frame: a socket already closed drops
        // it, and telling the caller nil there would claim a send that never occurred.
        BOOL queued = [self enqueueFrameWithOpcode:opcode payload:payload];
        if (completionHandler) {
            NSError *sendError = queued ? nil : [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost
                userInfo:@{ NSLocalizedDescriptionKey: @"WebSocket is closed; message was not sent" }];
            wsDispatchToCallbackQueue(_session, ^{ completionHandler(sendError); });
        }
    });
}

// ----- delivery to WebKit -----

- (void)deliverMessage:(NSURLSessionWebSocketMessage *)message
{
    [_lock lock];
    void (^handler)(NSURLSessionWebSocketMessage *, NSError *) = _pendingReceive;
    _pendingReceive = nil;
    if (handler)
        wsDispatchToCallbackQueue(_session, ^{ handler(message, nil); });
    else
        [_incomingMessages addObject:message];
    [_lock unlock];
}

- (void)deliverError:(NSError *)error
{
    [_lock lock];
    void (^handler)(NSURLSessionWebSocketMessage *, NSError *) = _pendingReceive;
    _pendingReceive = nil;
    if (handler)
        wsDispatchToCallbackQueue(_session, ^{ handler(nil, error); });
    else if (!_pendingError)
        _pendingError = error;
    [_lock unlock];
}

- (void)deliverDidOpenWithProtocol:(NSString *)protocol
{
    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    wsDispatchToCallbackQueue(_session, ^{
        id<NSURLSessionWebSocketDelegate> d = (id<NSURLSessionWebSocketDelegate>)delegate;
        if ([d respondsToSelector:@selector(URLSession:webSocketTask:didOpenWithProtocol:)])
            [d URLSession:session webSocketTask:(NSURLSessionWebSocketTask *)taskSelf didOpenWithProtocol:protocol];
    });
}

- (void)deliverDidCloseWithCode:(uint16_t)code reason:(NSData *)reason
{
    [_lock lock];
    if (_incomingMessages.count) {
        _hasPendingClose = YES;
        _pendingCloseCode = code;
        _pendingCloseReason = reason;
        [_lock unlock];
        return;
    }
    [self dispatchDidCloseWithCode:code reason:reason];
    [_lock unlock];
}

// Called with _lock held, so the close keeps its place in the delegate queue relative to the messages
// that preceded it.
- (void)dispatchDidCloseWithCode:(uint16_t)code reason:(NSData *)reason
{
    _closeCode = code;
    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    NSData *reasonData = reason ?: [NSData data];
    wsDispatchToCallbackQueue(_session, ^{
        id<NSURLSessionWebSocketDelegate> d = (id<NSURLSessionWebSocketDelegate>)delegate;
        if ([d respondsToSelector:@selector(URLSession:webSocketTask:didCloseWithCode:reason:)])
            [d URLSession:session webSocketTask:(NSURLSessionWebSocketTask *)taskSelf didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:reasonData];
    });
}

// ----- connection + TLS (on _ioQueue) -----

static void *wsContextRetain(void *info) { return (void *)CFRetain((CFTypeRef)info); }
static void wsContextRelease(void *info) { CFRelease((CFTypeRef)info); }

- (void)startConnection
{
    NSURL *url = _request.URL;
    BOOL secure = [url.scheme caseInsensitiveCompare:@"wss"] == NSOrderedSame || [url.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
    NSString *host = url.host;
    NSNumber *portNum = url.port;
    UInt32 port = portNum ? portNum.unsignedIntValue : (secure ? 443 : 80);
    if (!host.length) {
        [self failWithReason:@"Invalid WebSocket URL"];
        return;
    }
    _secure = secure;
    _targetHost = host;
    _targetPort = port;

    // Raw CFSocketStreams ignore kCFStreamPropertyHTTPProxy, and adding TLS to an already-open CFStream
    // (deferred TLS after a CONNECT) is unreliable. So a proxied connection opens its tunnel on a plain
    // BSD socket (blocking HTTP CONNECT — cheap, the proxy is local), then wraps the established socket
    // in CFStreams with TLS configured BEFORE opening, which engages reliably.
    //
    // Which hosts to tunnel is CFNetworkCopyProxiesForURL's answer, not the proxy dictionary's raw
    // HTTPSEnable/HTTPSProxy fields: the settings also carry an exception list, ExcludeSimpleHostnames,
    // PAC scripts and an implicit loopback exclusion, and reading the fields alone tunnels hosts the rest
    // of the system reaches directly. That is answered per URL, so it is asked per URL here, with the
    // http(s) form of the target that CFNetwork resolves proxies against.
    NSDictionary *sys = (__bridge_transfer NSDictionary *)CFNetworkCopySystemProxySettings();
    NSString *proxyHost = nil;
    NSNumber *proxyPort = nil;
    // An IPv6 literal reaches here unbracketed, because -[NSURL host] strips the brackets. Handing that
    // to NSURLComponents percent-escapes the colons into a host that names nothing, and the settings are
    // then resolved against the wrong question.
    NSString *lookupHost = ([host rangeOfString:@":"].location != NSNotFound && ![host hasPrefix:@"["])
        ? [NSString stringWithFormat:@"[%@]", host] : host;
    NSURLComponents *proxyLookup = [[NSURLComponents alloc] init];
    proxyLookup.scheme = secure ? @"https" : @"http";
    proxyLookup.host = lookupHost;
    proxyLookup.port = @(port);
    NSURL *proxyLookupURL = proxyLookup.URL;
    if (sys && proxyLookupURL) {
        NSArray *proxies = (__bridge_transfer NSArray *)CFNetworkCopyProxiesForURL((__bridge CFURLRef)proxyLookupURL, (__bridge CFDictionaryRef)sys);
        proxies = wkResolveProxyAutoConfiguration(proxies, proxyLookupURL);
        for (NSDictionary *proxy in proxies) {
            NSString *type = proxy[(__bridge NSString *)kCFProxyTypeKey];
            if ([type isEqualToString:(__bridge NSString *)kCFProxyTypeNone])
                break;
            if ([type isEqualToString:(__bridge NSString *)kCFProxyTypeHTTPS] || [type isEqualToString:(__bridge NSString *)kCFProxyTypeHTTP]) {
                proxyHost = proxy[(__bridge NSString *)kCFProxyHostNameKey];
                proxyPort = proxy[(__bridge NSString *)kCFProxyPortNumberKey];
                if (proxyHost.length)
                    break;
                proxyHost = nil;
            }
        }
    }

    if (proxyHost.length) {
        int fd = [self openProxyTunnel:proxyHost port:(proxyPort ? proxyPort.unsignedIntValue : (secure ? 443 : 80)) targetHost:host targetPort:port];
        if (fd < 0) {
            [self failWithReason:@"Proxy CONNECT failed"];
            return;
        }
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, (CFSocketNativeHandle)fd, &_readStream, &_writeStream);
        if (!_readStream || !_writeStream) {
            close(fd);
            [self failWithReason:@"Could not wrap tunnel socket"];
            return;
        }
        CFReadStreamSetProperty(_readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
        CFWriteStreamSetProperty(_writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    } else {
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)host, port, &_readStream, &_writeStream);
        if (!_readStream || !_writeStream) {
            [self failWithReason:@"Could not create socket streams"];
            return;
        }
    }

    if (secure)
        [self enableTLS];

    CFStreamClientContext context = { 0, (__bridge void *)self, wsContextRetain, wsContextRelease, NULL };
    CFOptionFlags readFlags = kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered | kCFStreamEventOpenCompleted;
    CFOptionFlags writeFlags = kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered | kCFStreamEventOpenCompleted;
    CFReadStreamSetClient(_readStream, readFlags, readStreamCallback, &context);
    CFWriteStreamSetClient(_writeStream, writeFlags, writeStreamCallback, &context);
    CFReadStreamSetDispatchQueue(_readStream, _ioQueue);
    CFWriteStreamSetDispatchQueue(_writeStream, _ioQueue);
    CFReadStreamOpen(_readStream);
    CFWriteStreamOpen(_writeStream);
    _state = WKWSStateHandshaking;
    [self sendHandshake];
}

// Blocking HTTP CONNECT through the proxy. Returns a connected, tunneled native socket (or -1).
- (int)openProxyTunnel:(NSString *)proxyHost port:(UInt32)proxyPort targetHost:(NSString *)host targetPort:(UInt32)targetPort
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    NSString *portStr = [NSString stringWithFormat:@"%u", proxyPort];
    if (getaddrinfo(proxyHost.UTF8String, portStr.UTF8String, &hints, &res) || !res)
        return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen)) {
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);

    NSData *req = [[NSString stringWithFormat:@"CONNECT %@:%u HTTP/1.1\r\nHost: %@:%u\r\n\r\n", host, targetPort, host, targetPort] dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = (const uint8_t *)req.bytes;
    size_t remaining = req.length;
    while (remaining) {
        ssize_t w = write(fd, p, remaining);
        if (w <= 0) { close(fd); return -1; }
        p += w; remaining -= w;
    }

    NSMutableData *resp = [NSMutableData data];
    uint8_t buf[512];
    NSData *crlfcrlf = [NSData dataWithBytes:"\r\n\r\n" length:4];
    while (1) {
        ssize_t r = read(fd, buf, sizeof(buf));
        if (r <= 0) { close(fd); return -1; }
        [resp appendBytes:buf length:r];
        if ([resp rangeOfData:crlfcrlf options:0 range:NSMakeRange(0, resp.length)].location != NSNotFound)
            break;
        if (resp.length > 8192) { close(fd); return -1; }
    }
    NSString *statusLine = [[[NSString alloc] initWithData:resp encoding:NSISOLatin1StringEncoding] componentsSeparatedByString:@"\r\n"].firstObject;
    NSArray<NSString *> *parts = [statusLine componentsSeparatedByString:@" "];
    NSInteger status = parts.count >= 2 ? [parts[1] integerValue] : 0;
    if (status != 200) { close(fd); return -1; }
    return fd;
}

- (void)enableTLS
{
    // Enable TLS first, then apply the SSL settings LAST. kCFStreamSSLPeerName both validates the cert
    // and sets the TLS SNI server-name; the proxy's MITM requires SNI, so the settings must not be
    // clobbered by a later kCFStreamPropertySocketSecurityLevel write (which resets the peer name).
    CFReadStreamSetProperty(_readStream, kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
    CFWriteStreamSetProperty(_writeStream, kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
    // The chain is not checked by the stream: a WebSocket task puts its server's certificate to the
    // session delegate the way every other NSURLSession task does (verifyPeerTrust below), and a stream
    // that decided for itself would either refuse before the delegate could answer or hide the question.
    NSDictionary *ssl = @{ (__bridge id)kCFStreamSSLPeerName: _targetHost,
                           (__bridge id)kCFStreamSSLValidatesCertificateChain: @NO };
    CFReadStreamSetProperty(_readStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
    CFWriteStreamSetProperty(_writeStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)ssl);
}

static void readStreamCallback(CFReadStreamRef, CFStreamEventType type, void *info)
{
    [(__bridge WKWebSocketStream *)info handleReadEvent:type];
}
static void writeStreamCallback(CFWriteStreamRef, CFStreamEventType type, void *info)
{
    [(__bridge WKWebSocketStream *)info handleWriteEvent:type];
}

- (void)handleReadEvent:(CFStreamEventType)type
{
    switch (type) {
    case kCFStreamEventHasBytesAvailable:
        [self readAvailableInput];
        break;
    case kCFStreamEventErrorOccurred: {
        NSError *e = (__bridge_transfer NSError *)CFReadStreamCopyError(_readStream);
        [self failWithError:e reason:@"WebSocket socket read error"];
        break;
    }
    case kCFStreamEventEndEncountered:
        if (_state != WKWSStateClosed && _state != WKWSStateClosing) {
            [self failWithReason:@"WebSocket connection closed unexpectedly"];
        } else if (_state == WKWSStateClosing && _sentClose) {
            // The peer ended the connection without echoing a Close frame: the close completes with the
            // status this side sent.
            [self deliverDidCloseWithCode:_sentCloseCode reason:nil];
            [self deliverError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
            [self teardownStreams];
        } else
            [self teardownStreams];
        break;
    default:
        break;
    }
}

// A secure connection is answered for before any of it is used: while the certificate is with the
// delegate the bytes stay in the stream, so no handshake is parsed, no cookie is stored and no callback
// is delivered on a connection the delegate has not accepted. Decrypted bytes mean the TLS handshake
// finished, so this is also where the question is put.
- (void)readAvailableInput
{
    if (!_readStream)
        return;
    if (_secure && !_peerTrustAnswered) {
        [self verifyPeerTrustThenContinue];
        return;
    }
    uint8_t buf[16384];
    while (CFReadStreamHasBytesAvailable(_readStream)) {
        CFIndex n = CFReadStreamRead(_readStream, buf, sizeof(buf));
        if (n <= 0)
            break;
        [_inBuffer appendBytes:buf length:n];
    }
    [self processInput];
}

- (void)handleWriteEvent:(CFStreamEventType)type
{
    switch (type) {
    case kCFStreamEventOpenCompleted:
        _writeStreamOpen = YES;
        [self flushOutput];
        break;
    case kCFStreamEventCanAcceptBytes:
        [self flushOutput];
        break;
    case kCFStreamEventErrorOccurred: {
        NSError *e = (__bridge_transfer NSError *)CFWriteStreamCopyError(_writeStream);
        [self failWithError:e reason:@"WebSocket socket write error"];
        break;
    }
    default:
        break;
    }
}

// The server's certificate, asked about exactly as NSURLSession asks: the session delegate is handed a
// server-trust challenge and its answer decides. A delegate that is not there, or that asks for the
// default handling, gets what the system would have done on its own -- the evaluation below.
- (void)verifyPeerTrustThenContinue
{
    // One challenge per connection: every write event and every read event arriving before the answer
    // reaches this, and a delegate is asked about a certificate once.
    if (_peerTrustPending || !_readStream)
        return;
    SecTrustRef trust = (SecTrustRef)CFReadStreamCopyProperty(_readStream, kCFStreamPropertySSLPeerTrust);
    if (!trust) {
        [self failWithReason:@"WebSocket TLS connection has no server certificate"];
        return;
    }

    // The question the URL asks: this host, over SSL, with the anchors and the date the system uses.
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)_targetHost);
    if (policy) {
        SecTrustSetPolicies(trust, policy);
        CFRelease(policy);
    }
    SecTrustResultType result = kSecTrustResultInvalid;
    OSStatus status = SecTrustEvaluate(trust, &result);
    BOOL systemAccepts = status == errSecSuccess
        && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified);

    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    dispatch_queue_t ioQueue = _ioQueue;
    NSURL *requestURL = _request.URL;
    _peerTrustPending = YES;
    wsDispatchToCallbackQueue(_session, ^{
        void (^answer)(BOOL) = ^(BOOL accepted) {
            dispatch_async(ioQueue, ^{ [taskSelf peerTrustAnswered:accepted]; CFRelease(trust); });
        };
        id<NSURLSessionTaskDelegate> d = (id<NSURLSessionTaskDelegate>)delegate;
        if (![d respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
            answer(systemAccepts);
            return;
        }
        NSURLAuthenticationChallenge *challenge = wsServerTrustChallenge(requestURL, trust);
        if (!challenge) {
            answer(systemAccepts);
            return;
        }
        [d URLSession:session task:(NSURLSessionTask *)taskSelf didReceiveChallenge:challenge
            completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                switch (disposition) {
                case NSURLSessionAuthChallengeUseCredential:
                    answer(credential != nil);
                    break;
                case NSURLSessionAuthChallengePerformDefaultHandling:
                    answer(systemAccepts);
                    break;
                default:
                    answer(NO);
                    break;
                }
            }];
    });
}

- (void)peerTrustAnswered:(BOOL)accepted
{
    _peerTrustPending = NO;
    if (_state == WKWSStateClosed)
        return;
    if (!accepted) {
        [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted
            userInfo:@{ NSLocalizedDescriptionKey: @"The certificate for this server is invalid" }] reason:nil];
        return;
    }
    _peerTrustAnswered = YES;
    [self flushOutput];
    // Bytes that arrived while the question was out were left in the stream, and the read event that
    // announced them will not come again.
    [self readAvailableInput];
}

- (void)flushOutput
{
    // Nothing goes out over a secure connection until its certificate has been answered for.
    if (_secure && !_peerTrustAnswered) {
        if (_writeStreamOpen && CFWriteStreamCanAcceptBytes(_writeStream))
            [self verifyPeerTrustThenContinue];
        return;
    }

    while (_outBuffer.length && CFWriteStreamCanAcceptBytes(_writeStream)) {
        CFIndex n = CFWriteStreamWrite(_writeStream, (const uint8_t *)_outBuffer.bytes, _outBuffer.length);
        if (n <= 0)
            break;
        [_outBuffer replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
    }
}

- (void)writeBytes:(NSData *)data
{
    [_outBuffer appendData:data];
    if (_writeStreamOpen)
        [self flushOutput];
}

// ----- handshake -----

- (void)sendHandshake
{
    uint8_t keyBytes[16];
    arc4random_buf(keyBytes, sizeof(keyBytes));
    NSString *key = [[NSData dataWithBytes:keyBytes length:sizeof(keyBytes)] base64EncodedStringWithOptions:0];
    _acceptKey = [[self class] acceptForKey:key];

    // Every on-the-wire component comes from ONE absolute URL: CFURL copies components exactly as
    // written, so relative URLs must be resolved first or the path would be only the relative
    // fragment ("socket.io/" rather than "/app/socket.io/").
    NSURL *url = _request.URL.absoluteURL;
    // The request target is assembled from the URL's ENCODED components, not
    // from -[NSURL path], which strips a trailing slash and percent-decodes: "/socket.io/?EIO=4"
    // would go out as "/socket.io?EIO=4" — a resource socket.io does not serve, so the origin never
    // handles the upgrade — and "%20" would be sent as a raw space. WTF::URL has no RFC 1808
    // parameter component, so WebSocketHandshake's resourceName() sends "/p;v=1" verbatim; CFURL
    // splits at the ';', so the parameter string has to be joined back on to reproduce that.
    NSString *path = (__bridge_transfer NSString *)CFURLCopyPath((__bridge CFURLRef)url);
    if (!path.length)
        path = @"/";
    NSString *parameters = (__bridge_transfer NSString *)CFURLCopyParameterString((__bridge CFURLRef)url, NULL);
    if (parameters.length)
        path = [NSString stringWithFormat:@"%@;%@", path, parameters];
    // CFURLCopyQueryString answers nil for a URL with no '?' and an empty string for one whose query
    // is empty, and WebSocketHandshake's resourceName() keeps the '?' in the second case.
    NSString *query = (__bridge_transfer NSString *)CFURLCopyQueryString((__bridge CFURLRef)url, NULL);
    NSString *resource = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
    // The port is omitted only when it is the default FOR THIS SCHEME, as WebSocketHandshake's
    // hostName() does: "ws://h:443" must send "Host: h:443", and "wss://h:80" must send "Host: h:80".
    BOOL defaultPort = (url.port == nil) || (url.port.unsignedIntValue == (_secure ? 443 : 80));
    NSString *hostHeader = defaultPort ? url.host : [NSString stringWithFormat:@"%@:%@", url.host, url.port];

    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", resource];
    [req appendFormat:@"Host: %@\r\n", hostHeader];
    [req appendString:@"Upgrade: websocket\r\n"];
    [req appendString:@"Connection: Upgrade\r\n"];
    [req appendFormat:@"Sec-WebSocket-Key: %@\r\n", key];
    [req appendString:@"Sec-WebSocket-Version: 13\r\n"];
    if (_requestedProtocol)
        [req appendFormat:@"Sec-WebSocket-Protocol: %@\r\n", _requestedProtocol];

    NSDictionary<NSString *, NSString *> *headers = _request.allHTTPHeaderFields;
    static NSSet *skip = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skip = [NSSet setWithArray:@[ @"host", @"upgrade", @"connection", @"content-length", @"sec-websocket-key", @"sec-websocket-version", @"sec-websocket-protocol", @"sec-websocket-extensions" ]];
    });
    for (NSString *name in headers) {
        if ([skip containsObject:name.lowercaseString])
            continue;
        [req appendFormat:@"%@: %@\r\n", name, headers[name]];
    }
    [req appendString:@"\r\n"];

    [self writeBytes:[req dataUsingEncoding:NSUTF8StringEncoding]];
}

+ (NSString *)acceptForKey:(NSString *)key
{
    NSData *utf8 = [[key stringByAppendingString:kWebSocketGUID] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(utf8.bytes, (CC_LONG)utf8.length, digest);
    return [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
}

- (void)processInput
{
    if (_state == WKWSStateProxyConnect) {
        const char terminator[] = "\r\n\r\n";
        NSRange end = [_inBuffer rangeOfData:[NSData dataWithBytes:terminator length:4] options:0 range:NSMakeRange(0, _inBuffer.length)];
        if (end.location == NSNotFound)
            return;
        NSUInteger headerEnd = end.location + end.length;
        NSData *respData = [_inBuffer subdataWithRange:NSMakeRange(0, headerEnd)];
        [_inBuffer replaceBytesInRange:NSMakeRange(0, headerEnd) withBytes:NULL length:0];
        NSString *resp = [[NSString alloc] initWithData:respData encoding:NSISOLatin1StringEncoding];
        NSString *statusLine = [resp componentsSeparatedByString:@"\r\n"].firstObject;
        NSArray<NSString *> *parts = [statusLine componentsSeparatedByString:@" "];
        NSInteger status = parts.count >= 2 ? [parts[1] integerValue] : 0;
        if (status != 200) {
            [self failWithReason:[NSString stringWithFormat:@"Proxy CONNECT failed (%ld)", (long)status]];
            return;
        }
        // Tunnel established. Start TLS to the origin inside it (for wss), then the WebSocket handshake.
        if (_secure)
            [self enableTLS];
        _state = WKWSStateHandshaking;
        [self sendHandshake];
        return; // the handshake response arrives later (after TLS); _inBuffer is empty here
    }
    if (_state == WKWSStateHandshaking) {
        const char terminator[] = "\r\n\r\n";
        NSRange end = [_inBuffer rangeOfData:[NSData dataWithBytes:terminator length:4] options:0 range:NSMakeRange(0, _inBuffer.length)];
        if (end.location == NSNotFound)
            return;
        NSUInteger headerEnd = end.location + end.length;
        NSData *headerData = [_inBuffer subdataWithRange:NSMakeRange(0, headerEnd)];
        [_inBuffer replaceBytesInRange:NSMakeRange(0, headerEnd) withBytes:NULL length:0];
        if (![self completeHandshakeWithHeaderData:headerData])
            return;
    }
    if (_state == WKWSStateOpen || _state == WKWSStateClosing)
        [self parseFrames];
}

// RFC 6455 4.1: "The HTTP version MUST be at least 1.1." The version is the status line up to its
// first space; a major version alone is enough from 2 on.
static BOOL wsParseIntegerRun(const uint8_t *bytes, NSUInteger length, int *value)
{
    if (!length)
        return NO;
    NSUInteger i = 0;
    int sign = 1;
    if (bytes[0] == '-' || bytes[0] == '+') {
        sign = bytes[0] == '-' ? -1 : 1;
        i = 1;
        if (length == 1)
            return NO;
    }
    long long accumulated = 0;
    for (; i < length; i++) {
        if (bytes[i] < '0' || bytes[i] > '9')
            return NO;
        accumulated = accumulated * 10 + (bytes[i] - '0');
        if (accumulated > 2147483647LL)
            return NO;
    }
    *value = (int)(sign * accumulated);
    return YES;
}

static BOOL wsHeaderHasValidHTTPVersion(const uint8_t *line, NSUInteger length)
{
    static const char preamble[] = "HTTP/";
    const NSUInteger preambleLength = 5;
    if (length < preambleLength + 3 || memcmp(line, preamble, preambleLength))
        return NO;

    NSUInteger dot = preambleLength;
    while (dot < length && line[dot] != '.')
        dot++;
    if (dot == length)
        return NO;

    int major = 0;
    if (!wsParseIntegerRun(line + preambleLength, dot - preambleLength, &major))
        return NO;

    NSUInteger minorDigits = 0;
    while (dot + 1 + minorDigits < length && line[dot + 1 + minorDigits] >= '0' && line[dot + 1 + minorDigits] <= '9')
        minorDigits++;
    int minor = 0;
    if (!wsParseIntegerRun(line + dot + 1, minorDigits, &minor))
        return NO;

    return (major >= 1 && minor >= 1) || major >= 2;
}

// The status line the peer sent, validated as WebSocketHandshake::readStatusLine does: ASCII only, no
// embedded null, CRLF-terminated within 1024 bytes, an HTTP version of at least 1.1, and a three-digit
// status code. Returns NO and names the fault when any of that does not hold.
- (BOOL)parseStatusLine:(NSData *)headerData statusCode:(NSInteger *)statusCode length:(NSUInteger *)lineLength
{
    static const NSUInteger maximumLength = 1024;
    const uint8_t *raw = (const uint8_t *)headerData.bytes;
    NSUInteger rawLength = headerData.length;
    NSUInteger firstSpace = NSNotFound;
    NSUInteger secondSpace = NSNotFound;
    NSUInteger index = 0;

    for (; index < rawLength; index++) {
        uint8_t c = raw[index];
        if (c == ' ') {
            if (firstSpace == NSNotFound)
                firstSpace = index;
            else if (secondSpace == NSNotFound)
                secondSpace = index;
        } else if (!c) {
            [self failProtocol:@"WebSocket handshake status line contains an embedded null"];
            return NO;
        } else if (c >= 0x80) {
            [self failProtocol:@"WebSocket handshake status line contains a non-ASCII character"];
            return NO;
        } else if (c == '\n')
            break;
    }
    if (index == rawLength) {
        [self failProtocol:@"WebSocket handshake status line has no line ending"];
        return NO;
    }

    NSUInteger length = index + 1;
    if (length > maximumLength) {
        [self failProtocol:@"WebSocket handshake status line is too long"];
        return NO;
    }
    if (length < 2 || raw[index - 1] != '\r') {
        [self failProtocol:@"WebSocket handshake status line does not end with CRLF"];
        return NO;
    }
    if (firstSpace == NSNotFound || secondSpace == NSNotFound) {
        [self failProtocol:@"WebSocket handshake status line has no response code"];
        return NO;
    }
    if (!wsHeaderHasValidHTTPVersion(raw, firstSpace)) {
        [self failProtocol:@"WebSocket handshake status line names an HTTP version below 1.1"];
        return NO;
    }
    if (secondSpace - firstSpace - 1 != 3) {
        [self failProtocol:@"WebSocket handshake status code is not three digits"];
        return NO;
    }
    NSInteger code = 0;
    for (NSUInteger i = firstSpace + 1; i < secondSpace; i++) {
        if (raw[i] < '0' || raw[i] > '9') {
            [self failProtocol:@"WebSocket handshake status code is not three digits"];
            return NO;
        }
        code = code * 10 + (raw[i] - '0');
    }
    *statusCode = code;
    *lineLength = length;
    return YES;
}

- (BOOL)completeHandshakeWithHeaderData:(NSData *)headerData
{
    NSInteger statusCode = 0;
    NSUInteger statusLineLength = 0;
    if (![self parseStatusLine:headerData statusCode:&statusCode length:&statusLineLength])
        return NO;

    NSString *headerString = [[NSString alloc] initWithData:[headerData subdataWithRange:NSMakeRange(statusLineLength, headerData.length - statusLineLength)]
        encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];

    NSMutableDictionary<NSString *, NSString *> *responseHeaders = [NSMutableDictionary dictionary];
    NSUInteger extensionsFields = 0;
    NSUInteger acceptFields = 0;
    NSUInteger protocolFields = 0;
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // RFC 6455 4.1: each of these three answers exactly one of the client's own fields, so a
        // response repeating any of them is not a handshake this side asked for.
        if ([name caseInsensitiveCompare:@"Sec-WebSocket-Extensions"] == NSOrderedSame)
            extensionsFields++;
        else if ([name caseInsensitiveCompare:@"Sec-WebSocket-Accept"] == NSOrderedSame)
            acceptFields++;
        else if ([name caseInsensitiveCompare:@"Sec-WebSocket-Protocol"] == NSOrderedSame)
            protocolFields++;
        // A header the response repeats -- Set-Cookie, above all -- is folded into one field value, as
        // NSHTTPURLResponse folds it; keeping only the last would drop every cookie but one.
        NSString *existing = responseHeaders[name];
        responseHeaders[name] = existing.length ? [existing stringByAppendingFormat:@", %@", value] : value;
    }
    if (extensionsFields > 1 || acceptFields > 1 || protocolFields > 1) {
        [self failProtocol:@"WebSocket handshake response repeats a Sec-WebSocket header field"];
        return NO;
    }

    _response = [[NSHTTPURLResponse alloc] initWithURL:_request.URL statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:responseHeaders];
    wsStoreCookiesFromResponse([self cookieStorage], (NSHTTPURLResponse *)_response, _request, _cookieTransform);

    if (statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308)
        return [self followRedirect];

    if (statusCode != 101)
        return [self handshakeFailed:statusCode];

    // The response's own (case-insensitive) header lookup is used throughout: an intermediary -- a Go
    // reverse proxy, for one -- may canonicalize the names to "Sec-Websocket-Accept".
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)_response;
    NSString *upgrade = [response valueForHTTPHeaderField:@"Upgrade"];
    NSString *connection = [response valueForHTTPHeaderField:@"Connection"] ?: @"";
    NSString *accept = [response valueForHTTPHeaderField:@"Sec-WebSocket-Accept"];
    NSString *serverProtocol = [response valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"];

    if (!upgrade || [upgrade caseInsensitiveCompare:@"websocket"] != NSOrderedSame) {
        [self failProtocol:@"WebSocket handshake response has no 'Upgrade: websocket'"];
        return NO;
    }
    // RFC 6455 4.1: Connection carries a token list, and one of its tokens is "Upgrade".
    BOOL upgradeRequested = NO;
    for (NSString *token in [connection componentsSeparatedByString:@","]) {
        if ([[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] caseInsensitiveCompare:@"upgrade"] == NSOrderedSame) {
            upgradeRequested = YES;
            break;
        }
    }
    if (!upgradeRequested) {
        [self failProtocol:@"WebSocket handshake response has no 'Connection: Upgrade'"];
        return NO;
    }
    if (![accept isEqualToString:_acceptKey]) {
        [self failProtocol:@"WebSocket handshake response has the wrong Sec-WebSocket-Accept"];
        return NO;
    }
    // This client offers no extension, so any the response names was never negotiated (RFC 6455 4.1).
    if (extensionsFields && [response valueForHTTPHeaderField:@"Sec-WebSocket-Extensions"].length) {
        [self failProtocol:@"WebSocket handshake response names an extension that was not offered"];
        return NO;
    }
    // The subprotocol has to be one of those the request offered; WebSocket joins them with ", ".
    if (serverProtocol.length) {
        NSArray<NSString *> *offered = _requestedProtocol ? [_requestedProtocol componentsSeparatedByString:@", "] : @[];
        if (![offered containsObject:serverProtocol]) {
            [self failProtocol:@"WebSocket handshake response names a subprotocol that was not offered"];
            return NO;
        }
    }

    _state = WKWSStateOpen;
    [self deliverDidOpenWithProtocol:serverProtocol ?: @""];
    return YES;
}

// A handshake that answers with a redirect is followed on a new connection, with the session delegate
// approving each hop: NetworkSessionCocoa answers URLSession:task:willPerformHTTPRedirection: for a
// WebSocket task too, and that is where WebSocketTask applies its cookie policy to the continuing
// request.
- (BOOL)followRedirect
{
    NSHTTPURLResponse *redirectResponse = (NSHTTPURLResponse *)_response;
    NSString *location = [redirectResponse valueForHTTPHeaderField:@"Location"];
    NSURL *newURL = location.length ? [[NSURL URLWithString:location relativeToURL:_request.URL] absoluteURL] : nil;
    NSString *scheme = newURL.scheme.lowercaseString;
    BOOL reachable = [scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"wss"]
        || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    if (!newURL.host.length || !reachable)
        return [self handshakeFailed:redirectResponse.statusCode];

    if (++_redirectCount > kWKWSMaximumRedirects) {
        _state = WKWSStateClosed;
        [self deliverError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorHTTPTooManyRedirects userInfo:nil]];
        [self teardownStreams];
        return NO;
    }

    NSMutableURLRequest *newRequest = [_request mutableCopy];
    newRequest.URL = newURL;
    // The Cookie header belongs to the hop that sent it; the next hop's is looked up for its own URL
    // once the delegate has answered.
    [newRequest setValue:nil forHTTPHeaderField:@"Cookie"];
    // Fetch: a request whose origin is not the redirect target's carries an opaque origin from there on.
    if ([newRequest valueForHTTPHeaderField:@"Origin"] && !wsURLsAreSameOrigin(_request.URL, newURL))
        [newRequest setValue:@"null" forHTTPHeaderField:@"Origin"];

    [self teardownStreams];
    _state = WKWSStateConnecting;
    [_inBuffer setLength:0];
    [_outBuffer setLength:0];
    _writeStreamOpen = NO;
    _peerTrustAnswered = NO;
    _peerTrustPending = NO;

    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    dispatch_queue_t ioQueue = _ioQueue;
    wsDispatchToCallbackQueue(_session, ^{
        void (^continueWithRequest)(NSURLRequest *) = ^(NSURLRequest *request) {
            dispatch_async(ioQueue, ^{ [taskSelf continueWithRedirectRequest:request status:redirectResponse.statusCode]; });
        };
        id<NSURLSessionTaskDelegate> d = (id<NSURLSessionTaskDelegate>)delegate;
        if ([d respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)])
            [d URLSession:session task:(NSURLSessionTask *)taskSelf willPerformHTTPRedirection:redirectResponse newRequest:newRequest completionHandler:continueWithRequest];
        else
            continueWithRequest(newRequest);
    });
    return NO;
}

// The delegate's answer: a request to continue with, or nil for a redirect it declines to follow --
// which leaves the handshake unfinished, so it is reported as the failure it is.
- (void)continueWithRedirectRequest:(NSURLRequest *)request status:(NSInteger)statusCode
{
    if (_state == WKWSStateClosed)
        return;
    if (!request) {
        [self handshakeFailed:statusCode];
        return;
    }
    NSMutableURLRequest *hop = [request mutableCopy];
    wsApplyStoredCookies([self cookieStorage], hop, wsSiteForCookies(hop) ?: _siteForCookies,
        wsSiteForCookies(hop) ? wsIsTopLevelNavigation(hop) : _isTopLevelNavigation);
    [self setCurrentRequest:hop];
    [self startConnection];
}

- (BOOL)handshakeFailed:(NSInteger)statusCode
{
    _state = WKWSStateClosed;
    NSString *desc = [NSString stringWithFormat:@"WebSocket handshake failed (HTTP %ld)", (long)statusCode];
    [self deliverError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{ NSLocalizedDescriptionKey: desc }]];
    [self teardownStreams];
    return NO;
}

// ----- frame parsing (RFC 6455) -----

// XOR `length` bytes with the 4-byte mask in place, eight bytes at a time.
static void maskBytes(uint8_t *bytes, NSUInteger length, const uint8_t key[4])
{
    uint64_t mask64;
    uint8_t key8[8] = { key[0], key[1], key[2], key[3], key[0], key[1], key[2], key[3] };
    memcpy(&mask64, key8, 8);
    NSUInteger i = 0;
    for (; i + 8 <= length; i += 8) {
        uint64_t word;
        memcpy(&word, bytes + i, 8);
        word ^= mask64;
        memcpy(bytes + i, &word, 8);
    }
    for (; i < length; i++)
        bytes[i] ^= key[i & 3];
}

- (void)parseFrames
{
    const uint8_t *bytes = (const uint8_t *)_inBuffer.bytes;
    NSUInteger available = _inBuffer.length;
    NSUInteger offset = 0;

    while (available - offset >= 2) {
        NSUInteger p = offset;
        uint8_t b0 = bytes[p++];
        uint8_t b1 = bytes[p++];
        BOOL fin = (b0 & 0x80) != 0;
        // This client never offers Sec-WebSocket-Extensions, so a set RSV bit means the peer is
        // using an extension that was never negotiated (permessage-deflate compresses the payload,
        // for one). RFC 6455 3.2 requires failing the connection: parsing on would hand JS a
        // "message" holding bytes that are not the payload the peer sent.
        if (b0 & 0x70) {
            [self failProtocol:@"WebSocket frame sets a reserved bit without a negotiated extension"];
            return;
        }
        int opcode = b0 & 0x0F;
        uint64_t len = b1 & 0x7F;

        // RFC 6455 5.1: a server never masks a frame it sends.
        if (b1 & 0x80) {
            [self failProtocol:@"WebSocket frame from the server is masked"];
            return;
        }

        // RFC 6455 5.2: the payload length is carried in the fewest bytes that hold it, and the
        // 64-bit form's most significant bit is 0. A longer encoding lets a peer announce a length
        // this side would wait for without bound.
        if (len == 126) {
            if (available - p < 2) break;
            len = ((uint64_t)bytes[p] << 8) | bytes[p + 1];
            p += 2;
            if (len < 126) {
                [self failProtocol:@"WebSocket frame length is not minimally encoded"];
                return;
            }
        } else if (len == 127) {
            if (available - p < 8) break;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | bytes[p + i];
            p += 8;
            if (len & 0x8000000000000000ULL) {
                [self failProtocol:@"WebSocket frame length has its most significant bit set"];
                return;
            }
            if (len <= 0xFFFF) {
                [self failProtocol:@"WebSocket frame length is not minimally encoded"];
                return;
            }
        }

        // The opcode and the control-frame rules are settled before the payload is waited for, so a
        // frame announcing a length no control frame may carry fails now rather than after the peer
        // has sent that many bytes.
        switch (opcode) {
        case 0x0:
        case 0x1:
        case 0x2:
        case 0x8:
        case 0x9:
        case 0xA:
            break;
        default:
            [self failProtocol:@"WebSocket frame uses a reserved opcode"];
            return;
        }
        // RFC 6455 5.5: a control frame is never fragmented and carries at most 125 bytes.
        if (opcode & 0x8) {
            if (!fin) {
                [self failProtocol:@"WebSocket control frame is fragmented"];
                return;
            }
            if (len > 125) {
                [self failProtocol:@"WebSocket control frame payload exceeds 125 bytes"];
                return;
            }
        }

        // A data frame that would carry the message past the maximum fails the receive, as it does on
        // a real task, rather than being buffered.
        if (!(opcode & 0x8) && _maximumMessageSize > 0
            && (uint64_t)_messageBuffer.length + len > (uint64_t)_maximumMessageSize) {
            [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum
                userInfo:@{ NSLocalizedDescriptionKey: @"WebSocket message exceeds the maximum message size" }]
                reason:@"WebSocket message exceeds the maximum message size"];
            return;
        }

        if ((uint64_t)(available - p) < len) break;

        // The payload is handed out as a pointer into _inBuffer: the frame's bytes are dead once
        // `offset` moves past them, and handleFrameOpcode: copies what it keeps.
        const uint8_t *payload = bytes + p;
        p += len;
        offset = p;

        [self handleFrameOpcode:opcode fin:fin payload:payload length:len];
        if (_state == WKWSStateClosed)
            return; // the connection is closed; nothing after this frame is parsed
    }

    if (offset)
        [_inBuffer replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
}

- (void)handleFrameOpcode:(int)opcode fin:(BOOL)fin payload:(const uint8_t *)payload length:(uint64_t)length
{
    switch (opcode) {
    case 0x0:
    case 0x1:
    case 0x2:
        // RFC 6455 5.4: a continuation belongs to a message already begun, and a data frame starts a
        // message only when no fragmented one is in progress.
        if (opcode == 0x0 && _messageOpcode < 0) {
            [self failProtocol:@"WebSocket continuation frame has no message to continue"];
            return;
        }
        if (opcode != 0x0) {
            if (_messageOpcode >= 0) {
                [self failProtocol:@"WebSocket data frame interrupts a fragmented message"];
                return;
            }
            [_messageBuffer setLength:0];
            _messageOpcode = opcode;
        }
        if (length)
            [_messageBuffer appendBytes:payload length:length];
        if (fin) {
            if (_messageOpcode == 0x1) {
                // RFC 6455 makes an undecodable text frame a protocol failure (close 1007). Substituting an
                // empty string would hand JS a message the peer never sent and hide the fault.
                NSString *text = [[NSString alloc] initWithData:_messageBuffer encoding:NSUTF8StringEncoding];
                if (!text) {
                    [_messageBuffer setLength:0];
                    _messageOpcode = -1;
                    [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData
                        userInfo:@{ NSLocalizedDescriptionKey: @"WebSocket text frame is not valid UTF-8" }]
                        reason:@"WebSocket text frame is not valid UTF-8"];
                    return;
                }
                [self deliverMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]];
            } else
                [self deliverMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:[_messageBuffer copy]]];
            [_messageBuffer setLength:0];
            _messageOpcode = -1;
        }
        break;
    case 0x8: {
        // RFC 6455 5.5.1: a Close payload is empty or carries a two-byte status code first, and
        // 7.4.1 reserves 1005/1006/1015 for the local end to report -- none of the three, nor a
        // code below 1000, may appear on the wire.
        if (length == 1) {
            [self failProtocol:@"WebSocket Close frame payload is one byte"];
            return;
        }
        uint16_t code = 1005;
        NSData *reason = nil;
        if (length >= 2) {
            code = (uint16_t)((payload[0] << 8) | payload[1]);
            if (code < 1000 || code == 1005 || code == 1006 || code == 1015) {
                [self failProtocol:@"WebSocket Close frame carries a status code that may not be sent"];
                return;
            }
            if (length > 2)
                reason = [NSData dataWithBytes:payload + 2 length:length - 2];
        }
        if (!_sentClose) {
            _sentClose = YES;
            // A Close with no payload carries no status code (reported as 1005); it is echoed
            // with an empty payload.
            NSData *echoPayload = [NSData data];
            if (length >= 2) {
                uint8_t echo[2] = { (uint8_t)(code >> 8), (uint8_t)(code & 0xFF) };
                echoPayload = [NSData dataWithBytes:echo length:2];
            }
            [self enqueueFrameWithOpcode:0x8 payload:echoPayload];
        }
        _state = WKWSStateClosing;
        [self deliverDidCloseWithCode:code reason:reason];
        [self deliverError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]];
        [self teardownStreams];
        break;
    }
    case 0x9:
        [self enqueueFrameWithOpcode:0xA payload:length ? [NSData dataWithBytes:payload length:length] : [NSData data]];
        break;
    case 0xA:
    default:
        break;
    }
}

// ----- frame generation (client frames MUST be masked) -----

// Returns NO when the frame was not queued, so a caller's completion handler can report that rather than
// being told the send succeeded.
- (BOOL)enqueueFrameWithOpcode:(int)opcode payload:(NSData *)payload
{
    if (_state == WKWSStateClosed)
        return NO;
    NSUInteger len = payload.length;
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | (uint8_t)opcode;
    [frame appendBytes:&b0 length:1];

    if (len <= 125) {
        uint8_t b1 = 0x80 | (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 0xFFFF) {
        uint8_t b1 = 0x80 | 126;
        uint8_t ext[2] = { (uint8_t)(len >> 8), (uint8_t)(len & 0xFF) };
        [frame appendBytes:&b1 length:1];
        [frame appendBytes:ext length:2];
    } else {
        uint8_t b1 = 0x80 | 127;
        uint8_t ext[8];
        uint64_t l = len;
        for (int i = 7; i >= 0; i--) { ext[i] = (uint8_t)(l & 0xFF); l >>= 8; }
        [frame appendBytes:&b1 length:1];
        [frame appendBytes:ext length:8];
    }

    uint8_t maskKey[4];
    arc4random_buf(maskKey, 4);
    [frame appendBytes:maskKey length:4];

    NSUInteger headerLength = frame.length;
    if (payload)
        [frame appendData:payload];   // appendData: throws for nil, and a nil payload is a legal empty frame
    if (len)
        maskBytes((uint8_t *)frame.mutableBytes + headerLength, len, maskKey);

    [self writeBytes:frame];
    return YES;
}

// NSURLSessionWebSocketCloseCodeInvalid (0) means "no status code": the Close frame then carries an
// empty payload (RFC 6455 5.5.1), which the peer reports as 1005.
- (void)sendCloseFrameWithCode:(uint16_t)code reason:(NSData *)reason
{
    if (_sentClose)
        return;
    _sentClose = YES;
    _sentCloseCode = code ? code : 1005;
    NSMutableData *payload = [NSMutableData data];
    if (code) {
        uint8_t codeBytes[2] = { (uint8_t)(code >> 8), (uint8_t)(code & 0xFF) };
        [payload appendBytes:codeBytes length:2];
        if (reason.length)
            [payload appendData:reason];
    }
    [self enqueueFrameWithOpcode:0x8 payload:payload];
    [self flushOutput];
}

// ----- teardown / failure -----

// The transport's own NSError is delivered; the synthesized NSURLErrorNetworkConnectionLost is used only
// where no underlying error exists (an unexpected close, a protocol violation).
- (void)failWithError:(NSError *)error reason:(NSString *)reason
{
    if (_state == WKWSStateClosed)
        return;
    _state = WKWSStateClosed;
    NSError *delivered = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:@{ NSLocalizedDescriptionKey: reason }];
    [self deliverError:delivered];
    [self teardownStreams];
}

- (void)failWithReason:(NSString *)reason
{
    [self failWithError:nil reason:reason];
}

// A violation of the framing or handshake rules ends the connection without a close status, so WebKit
// reports it as the abnormal closure it is (WebSocketTaskCocoa reads closeCode to tell the two apart).
// RFC 6455 7.1.7: an established connection is failed by sending a Close frame with 1002 first.
- (void)failProtocol:(NSString *)reason
{
    if ((_state == WKWSStateOpen || _state == WKWSStateClosing) && !_sentClose)
        [self sendCloseFrameWithCode:1002 reason:nil];
    [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse
        userInfo:@{ NSLocalizedDescriptionKey: reason }] reason:reason];
}

- (void)teardownStreams
{
    _state = WKWSStateClosed;
    _writeStreamOpen = NO;
    if (_readStream) {
        CFReadStreamSetClient(_readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamSetDispatchQueue(_readStream, NULL);
        CFReadStreamClose(_readStream);
        CFRelease(_readStream);
        _readStream = NULL;
    }
    if (_writeStream) {
        CFWriteStreamSetClient(_writeStream, kCFStreamEventNone, NULL, NULL);
        CFWriteStreamSetDispatchQueue(_writeStream, NULL);
        CFWriteStreamClose(_writeStream);
        CFRelease(_writeStream);
        _writeStream = NULL;
    }
}

@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLSession webSocketTaskWithRequest:] (10.15+), a WebKit-scoped polyfill. Installed on each
// concrete class of the NSURLSession cluster: instances are __NSCFURLSession, not an NSURLSession
// subclass, and on 10.9 that is the cluster's only concrete class (probed on-host). The public
// selector stays absent on the class, so an embedder's
// -respondsToSelector:@selector(webSocketTaskWithRequest:) answers NO on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ADD_METHODS_ON(NSURLSession, "NSURLSession", "__NSCFURLSession")
- (NSURLSessionWebSocketTask *)webSocketTaskWithRequest:(NSURLRequest *)request
{
    NSURLSession *session = self;
    static std::atomic<uint32_t> identifierCounter { 0x10000 };
    NSUInteger identifier = ++identifierCounter;

    NSString *protocol = [request valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"];

    // The Cookie header is attached when the task is resumed rather than here: NetworkSessionCocoa
    // creates the task and only then hands it its cookie storage and its site-for-cookies.
    WKWebSocketStream *stream = [[WKWebSocketStream alloc] initWithRequest:request protocol:protocol session:session taskIdentifier:identifier];
    return (NSURLSessionWebSocketTask *)stream;
}
@end
