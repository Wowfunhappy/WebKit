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

// MAVERICKS_BACKPORT (polyfill, no WebKit-logic source edits): NSURLSessionWebSocketTask /
// NSURLSessionWebSocketMessage are macOS 10.15+ and absent on 10.9, and the legacy WebCore
// SocketStreamHandle / WebSocketChannel were removed from this WebKit, so every WebSocket failed with
// "Cannot create a web socket task" (breaks figma's Livegraph, Slack, Discord, etc.). This file lives
// in WebKit.framework (alongside PolyfillClasses_109.mm) so its strong class definition satisfies the
// weak `_OBJC_CLASS_$_NSURLSessionWebSocketMessage` import in WebSocketTaskCocoa.mm. It provides:
//   * NSURLSessionWebSocketMessage  — the value object WebSocketTaskCocoa constructs.
//   * WKWebSocketStream             — an RFC 6455 client that masquerades as the NSURLSessionWebSocketTask
//     WebSocketTaskCocoa drives (resume/cancel/currentRequest/response/closeCode/taskIdentifier/
//     receiveMessageWithCompletionHandler:/sendMessage:completionHandler:/cancelWithCloseCode:reason:).
//   * -[NSURLSession webSocketTaskWithRequest:] — already called (respondsToSelector-guarded) by
//     NetworkSessionCocoa::createWebSocketTask; returns a WKWebSocketStream.
// On open/close it invokes the session delegate's NSURLSessionWebSocketDelegate methods (passing itself
// as the task) exactly as NSURLSession would, so the existing webSocketDataTaskMap -> WebSocketTask::
// didConnect/didClose path is unchanged. Delegate + receive callbacks are delivered on the main queue
// (where createWebSocketTask/addWebSocketTask run); socket I/O runs on a private serial queue.
//
// Transport: a blocking HTTP CONNECT through the system proxy on a plain BSD socket, then an OpenSSL 3
// TLS 1.3 session over that fd (the local MITM proxy only hijacks WebSocket upgrades on TLS 1.3; 10.9's
// SecureTransport is TLS-1.2-only, so we borrow the bundle's vendored OpenSSL), driven non-blocking by GCD
// readiness sources on the serial I/O queue. Compiled with -fobjc-arc (see CMakeLists.txt).

#include "config.h"
#import <CFNetwork/CFNetwork.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>
#import <atomic>
#import <vector>

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
// WKWebSocketStream: RFC 6455 client (OpenSSL 3 / TLS 1.3 transport), shaped like NSURLSessionWebSocketTask.
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
    NSURLRequest *_request;
    NSString *_requestedProtocol;
    NSString *_acceptKey;           // expected Sec-WebSocket-Accept
    NSURLResponse *_response;       // handshake response (NSHTTPURLResponse)

    __weak NSURLSession *_session;
    __weak id _delegate;            // session delegate (NSURLSessionWebSocketDelegate)

    NSUInteger _taskIdentifier;
    NSInteger _closeCode;

    // OpenSSL 3 (TLS 1.3) over a non-blocking tunnel fd, driven by GCD readiness sources on _ioQueue. TLS 1.3
    // is required because the local MITM proxy only hijacks WebSocket upgrades on TLS 1.3 (see startConnection
    // comment); 10.9's SecureTransport caps at TLS 1.2, so we borrow the bundle's vendored OpenSSL.
    void *_ssl;                     // SSL* (NULL for plain ws://)
    void *_sslCtx;                  // SSL_CTX*
    int _fd;                        // tunnel socket fd (non-blocking)
    dispatch_source_t _readSource;  // socket readable (always resumed once started)
    dispatch_source_t _writeSource; // socket writable (armed only on write backpressure)
    BOOL _writeSourceArmed;
    BOOL _tlsHandshakeDone;         // TLS layer ready (always YES for plain ws://)
    dispatch_queue_t _ioQueue;      // OpenSSL, writes, frame parsing, and all state run here

    WKWSState _state;
    BOOL _sentClose;

    BOOL _secure;                   // wss
    BOOL _usingProxy;               // tunneling through an HTTP CONNECT proxy
    NSString *_targetHost;          // origin host (for CONNECT + TLS peer name)
    UInt32 _targetPort;             // origin port

    NSMutableData *_inBuffer;       // raw bytes from the socket (handshake then frames)
    NSMutableData *_outBuffer;      // bytes pending write to the socket
    NSMutableData *_messageBuffer;  // reassembly of a fragmented data message
    int _messageOpcode;             // opcode of the in-progress data message (1 text, 2 binary)

    NSLock *_lock;                  // guards the receive plumbing below
    NSMutableArray *_incomingMessages;
    void (^_pendingReceive)(NSURLSessionWebSocketMessage *, NSError *);
    NSError *_pendingError;
}
- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier;
@end

static id wsWebSocketTaskWithRequest(NSURLSession *, SEL, NSURLRequest *);

// MAVERICKS_BACKPORT: -[NSHTTPURLResponse valueForHTTPHeaderField:] is macOS 10.15+ and absent on 10.9
// (WebSocketTaskCocoa::didConnect calls it on the handshake response → doesNotRecognizeSelector crash).
// Inject it, backed by the 10.9-available allHeaderFields with a case-insensitive lookup.
static id wsHTTPResponseValueForHeaderField(NSHTTPURLResponse *self, SEL, NSString *field)
{
    NSDictionary *headers = self.allHeaderFields;
    id direct = headers[field];
    if (direct)
        return direct;
    for (NSString *key in headers) {
        if ([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:field] == NSOrderedSame)
            return headers[key];
    }
    return nil;
}

@implementation WKWebSocketStream

// Inject -[NSURLSession webSocketTaskWithRequest:] (categories on Foundation classes do not reliably
// attach in this backport — same reason objc_inject.m uses class_addMethod). NetworkSessionCocoa::
// createWebSocketTask already calls it, guarded by respondsToSelector:.
+ (void)load
{
    @autoreleasepool {
        SEL sel = @selector(webSocketTaskWithRequest:);
        // NSURLSession is a class cluster: instances are __NSCFURLSession, which is NOT a subclass of
        // the public NSURLSession, so the method must be injected onto the concrete class(es) too.
        const char *names[] = { "NSURLSession", "__NSCFURLSession", "__NSURLSessionLocal" };
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
            Class cls = objc_getClass(names[i]);
            if (cls && !class_getInstanceMethod(cls, sel))
                class_addMethod(cls, sel, (IMP)wsWebSocketTaskWithRequest, "@@:@");
        }

        Class respCls = [NSHTTPURLResponse class];
        SEL headerSel = @selector(valueForHTTPHeaderField:);
        if (respCls && !class_getInstanceMethod(respCls, headerSel))
            class_addMethod(respCls, headerSel, (IMP)wsHTTPResponseValueForHeaderField, "@@:@");
    }
}

- (instancetype)initWithRequest:(NSURLRequest *)request protocol:(NSString *)protocol session:(NSURLSession *)session taskIdentifier:(NSUInteger)identifier
{
    if (!(self = [super init]))
        return nil;
    _request = request;
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
    _lock = [[NSLock alloc] init];
    _fd = -1;
    _ioQueue = dispatch_queue_create("com.apple.WebKit.LegacyWebSocket", DISPATCH_QUEUE_SERIAL);
    return self;
}

// ----- NSURLSessionWebSocketTask-shaped interface used by WebSocketTaskCocoa -----

- (NSUInteger)taskIdentifier { return _taskIdentifier; }
- (NSURLRequest *)currentRequest { return _request; }
- (NSURLRequest *)originalRequest { return _request; }
- (NSURLResponse *)response { return _response; }
- (NSInteger)closeCode { return _closeCode; }
- (void)setMaximumMessageSize:(NSInteger)size { (void)size; }

- (void)resume
{
    dispatch_async(_ioQueue, ^{ [self startConnection]; });
}

- (void)cancel
{
    dispatch_async(_ioQueue, ^{ [self teardownStreams]; });
}

- (void)cancelWithCloseCode:(NSInteger)closeCode reason:(NSData *)reason
{
    dispatch_async(_ioQueue, ^{
        if (self->_state == WKWSStateOpen)
            [self sendCloseFrameWithCode:(uint16_t)closeCode reason:reason];
        [self teardownStreams];
    });
}

- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))handler
{
    [_lock lock];
    if (_pendingError) {
        NSError *err = _pendingError;
        _pendingError = nil;
        [_lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, err); });
        return;
    }
    if (_incomingMessages.count) {
        NSURLSessionWebSocketMessage *msg = _incomingMessages.firstObject;
        [_incomingMessages removeObjectAtIndex:0];
        [_lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{ handler(msg, nil); });
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
    dispatch_async(_ioQueue, ^{
        [self enqueueFrameWithOpcode:opcode payload:payload];
        if (completionHandler)
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil); });
    });
}

// ----- delivery to WebKit -----

- (void)deliverMessage:(NSURLSessionWebSocketMessage *)message
{
    [_lock lock];
    void (^handler)(NSURLSessionWebSocketMessage *, NSError *) = _pendingReceive;
    _pendingReceive = nil;
    if (!handler)
        [_incomingMessages addObject:message];
    [_lock unlock];
    if (handler)
        dispatch_async(dispatch_get_main_queue(), ^{ handler(message, nil); });
}

- (void)deliverError:(NSError *)error
{
    [_lock lock];
    void (^handler)(NSURLSessionWebSocketMessage *, NSError *) = _pendingReceive;
    _pendingReceive = nil;
    if (!handler && !_pendingError)
        _pendingError = error;
    [_lock unlock];
    if (handler)
        dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, error); });
}

- (void)deliverDidOpenWithProtocol:(NSString *)protocol
{
    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<NSURLSessionWebSocketDelegate> d = (id<NSURLSessionWebSocketDelegate>)delegate;
        if ([d respondsToSelector:@selector(URLSession:webSocketTask:didOpenWithProtocol:)])
            [d URLSession:session webSocketTask:(NSURLSessionWebSocketTask *)taskSelf didOpenWithProtocol:protocol];
    });
}

- (void)deliverDidCloseWithCode:(uint16_t)code reason:(NSData *)reason
{
    _closeCode = code;
    __weak id delegate = _delegate;
    __weak NSURLSession *session = _session;
    WKWebSocketStream *taskSelf = self;
    NSData *reasonData = reason ?: [NSData data];
    dispatch_async(dispatch_get_main_queue(), ^{
        id<NSURLSessionWebSocketDelegate> d = (id<NSURLSessionWebSocketDelegate>)delegate;
        if ([d respondsToSelector:@selector(URLSession:webSocketTask:didCloseWithCode:reason:)])
            [d URLSession:session webSocketTask:(NSURLSessionWebSocketTask *)taskSelf didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:reasonData];
    });
}

// ----- connection + TLS: an OpenSSL 3 (TLS 1.3) session over the non-blocking tunnel fd, all on _ioQueue -----
//
// WHY OpenSSL and not SecureTransport: the local MITM proxy (AquaProxy, a Go net/http httputil.ReverseProxy)
// only HIJACKS WebSocket upgrades on TLS 1.3 connections. Over the TLS 1.2 that 10.9's SecureTransport is
// capped at, the proxy relays the 101 but never switches to tunnel mode — it reads the first client frame as
// a (malformed) HTTP request, so server->client frames never flow (verified: identical request bytes succeed
// over TLS 1.3 and fail over TLS 1.2 through the same proxy). 10.9 SecureTransport can't do TLS 1.3, so we
// borrow the OpenSSL 3 already vendored in the bundle (for GStreamer) and drive it non-blocking over the fd.

// OpenSSL constants (stable ABI; declared here so we needn't pull in <openssl/ssl.h>).
enum {
    OSSL_TLS1_3_VERSION = 0x0304,
    OSSL_CTRL_SET_MIN_PROTO_VERSION = 123,
    OSSL_CTRL_SET_MAX_PROTO_VERSION = 124,
    OSSL_CTRL_SET_TLSEXT_HOSTNAME = 55,
    OSSL_TLSEXT_NAMETYPE_host_name = 0,
    OSSL_CTRL_MODE = 33,
    OSSL_MODE_ENABLE_PARTIAL_WRITE = 0x01,
    OSSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 0x02,
    OSSL_VERIFY_NONE = 0x00,
    OSSL_ERROR_WANT_READ = 2,
    OSSL_ERROR_WANT_WRITE = 3,
    OSSL_ERROR_ZERO_RETURN = 6,
};

static void *(*ossl_TLS_client_method)(void);
static void *(*ossl_SSL_CTX_new)(const void *);
static void  (*ossl_SSL_CTX_free)(void *);
static long  (*ossl_SSL_CTX_ctrl)(void *, int, long, void *);
static void  (*ossl_SSL_CTX_set_verify)(void *, int, void *);
static void *(*ossl_SSL_new)(void *);
static void  (*ossl_SSL_free)(void *);
static int   (*ossl_SSL_set_fd)(void *, int);
static long  (*ossl_SSL_ctrl)(void *, int, long, void *);
static void  (*ossl_SSL_set_connect_state)(void *);
static int   (*ossl_SSL_connect)(void *);
static int   (*ossl_SSL_read)(void *, void *, int);
static int   (*ossl_SSL_write)(void *, const void *, int);
static int   (*ossl_SSL_get_error)(const void *, int);
static int   (*ossl_SSL_shutdown)(void *);

static BOOL wsLoadOpenSSL(void)
{
    static BOOL ok = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The vendored OpenSSL ships beside the GStreamer libs inside WebCore.framework. Pre-load its
        // dependencies by absolute path so libssl's @rpath references resolve in the NetworkProcess (which
        // has no GStreamer rpath of its own), then load libssl itself.
        const char *dir = "/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/"
                          "WebCore.framework/Versions/A/Frameworks/gstreamer/lib/";
        char path[1024];
        snprintf(path, sizeof(path), "%slibsystem_compat.dylib", dir); dlopen(path, RTLD_GLOBAL | RTLD_NOW);
        snprintf(path, sizeof(path), "%slibcrypto.3.dylib", dir);      dlopen(path, RTLD_GLOBAL | RTLD_NOW);
        snprintf(path, sizeof(path), "%slibssl.3.dylib", dir);
        void *h = dlopen(path, RTLD_GLOBAL | RTLD_NOW);
        if (!h) { NSLog(@"[WebSocket] could not load OpenSSL: %s", dlerror()); return; }
        ossl_TLS_client_method   = (void *(*)(void))dlsym(h, "TLS_client_method");
        ossl_SSL_CTX_new         = (void *(*)(const void *))dlsym(h, "SSL_CTX_new");
        ossl_SSL_CTX_free        = (void (*)(void *))dlsym(h, "SSL_CTX_free");
        ossl_SSL_CTX_ctrl        = (long (*)(void *, int, long, void *))dlsym(h, "SSL_CTX_ctrl");
        ossl_SSL_CTX_set_verify  = (void (*)(void *, int, void *))dlsym(h, "SSL_CTX_set_verify");
        ossl_SSL_new             = (void *(*)(void *))dlsym(h, "SSL_new");
        ossl_SSL_free            = (void (*)(void *))dlsym(h, "SSL_free");
        ossl_SSL_set_fd          = (int (*)(void *, int))dlsym(h, "SSL_set_fd");
        ossl_SSL_ctrl            = (long (*)(void *, int, long, void *))dlsym(h, "SSL_ctrl");
        ossl_SSL_set_connect_state = (void (*)(void *))dlsym(h, "SSL_set_connect_state");
        ossl_SSL_connect         = (int (*)(void *))dlsym(h, "SSL_connect");
        ossl_SSL_read            = (int (*)(void *, void *, int))dlsym(h, "SSL_read");
        ossl_SSL_write           = (int (*)(void *, const void *, int))dlsym(h, "SSL_write");
        ossl_SSL_get_error       = (int (*)(const void *, int))dlsym(h, "SSL_get_error");
        ossl_SSL_shutdown        = (int (*)(void *))dlsym(h, "SSL_shutdown");
        ok = ossl_TLS_client_method && ossl_SSL_CTX_new && ossl_SSL_CTX_ctrl && ossl_SSL_new
            && ossl_SSL_set_fd && ossl_SSL_ctrl && ossl_SSL_connect && ossl_SSL_read
            && ossl_SSL_write && ossl_SSL_get_error;
        if (!ok) NSLog(@"[WebSocket] OpenSSL symbols missing");
    });
    return ok;
}

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

    // This VM has no direct route to external hosts; all traffic goes through the system proxy (the same
    // one NSURLSession uses). So we open the proxy tunnel on a plain BSD socket (blocking HTTP CONNECT —
    // cheap, the proxy is local), then run our own SecureTransport session over the established socket.
    NSDictionary *sys = (__bridge_transfer NSDictionary *)CFNetworkCopySystemProxySettings();
    NSString *proxyHost = secure ? sys[@"HTTPSProxy"] : sys[@"HTTPProxy"];
    NSNumber *proxyPort = secure ? sys[@"HTTPSPort"] : sys[@"HTTPPort"];
    BOOL proxyEnabled = [sys[secure ? @"HTTPSEnable" : @"HTTPEnable"] boolValue];

    int fd = -1;
    if (proxyEnabled && proxyHost.length) {
        fd = [self openProxyTunnel:proxyHost port:(proxyPort ? proxyPort.unsignedIntValue : (secure ? 443 : 80)) targetHost:host targetPort:port];
        if (fd < 0) {
            [self failWithReason:@"Proxy CONNECT failed"];
            return;
        }
    } else {
        fd = [self openDirectSocket:host port:port];
        if (fd < 0) {
            [self failWithReason:@"Could not connect socket"];
            return;
        }
    }
    _fd = fd;

    // Non-blocking from here on: OpenSSL returns SSL_ERROR_WANT_READ/WRITE and the GCD readiness sources
    // re-drive the pump, so nothing ever blocks _ioQueue.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    if (secure && ![self setupTLS]) {
        [self failWithReason:@"Could not initialize TLS"];
        return;
    }

    [self startSources];

    if (secure) {
        // Run the TLS handshake first; sendHandshake (the WS upgrade) is issued once it completes.
        [self driveHandshake];
    } else {
        _tlsHandshakeDone = YES;
        _state = WKWSStateHandshaking;
        [self sendHandshake];
    }
}

// Blocking direct connect (used only when no proxy is configured; this VM normally proxies all traffic).
- (int)openDirectSocket:(NSString *)host port:(UInt32)port
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    NSString *portStr = [NSString stringWithFormat:@"%u", port];
    if (getaddrinfo(host.UTF8String, portStr.UTF8String, &hints, &res) || !res)
        return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen)) {
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
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

- (BOOL)setupTLS
{
    if (!wsLoadOpenSSL())
        return NO;
    _sslCtx = ossl_SSL_CTX_new(ossl_TLS_client_method());
    if (!_sslCtx)
        return NO;
    // Pin TLS 1.3 (the only version the proxy hijacks WebSocket upgrades over). PARTIAL_WRITE +
    // MOVING_WRITE_BUFFER let flushTLSWrites advance by the byte count SSL_write reports and retry the
    // remainder from a moved buffer. The hop to the proxy is localhost trusted MITM infra, so we don't
    // verify its leaf (the proxy itself validated the real origin).
    ossl_SSL_CTX_ctrl(_sslCtx, OSSL_CTRL_SET_MIN_PROTO_VERSION, OSSL_TLS1_3_VERSION, NULL);
    ossl_SSL_CTX_ctrl(_sslCtx, OSSL_CTRL_SET_MAX_PROTO_VERSION, OSSL_TLS1_3_VERSION, NULL);
    ossl_SSL_CTX_ctrl(_sslCtx, OSSL_CTRL_MODE, OSSL_MODE_ENABLE_PARTIAL_WRITE | OSSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, NULL);
    if (ossl_SSL_CTX_set_verify)
        ossl_SSL_CTX_set_verify(_sslCtx, OSSL_VERIFY_NONE, NULL);
    _ssl = ossl_SSL_new(_sslCtx);
    if (!_ssl)
        return NO;
    ossl_SSL_set_fd(_ssl, _fd);
    // SNI to the ORIGIN host (never the proxy). SSL_set_tlsext_host_name copies the string.
    char host[256];
    NSData *hostUTF8 = [_targetHost dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger hl = MIN(hostUTF8.length, sizeof(host) - 1);
    memcpy(host, hostUTF8.bytes, hl);
    host[hl] = 0;
    ossl_SSL_ctrl(_ssl, OSSL_CTRL_SET_TLSEXT_HOSTNAME, OSSL_TLSEXT_NAMETYPE_host_name, host);
    ossl_SSL_set_connect_state(_ssl);
    return YES;
}

- (void)startSources
{
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd, 0, _ioQueue);
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)_fd, 0, _ioQueue);
    __weak WKWebSocketStream *weakSelf = self;
    dispatch_source_set_event_handler(_readSource, ^{ [weakSelf socketReadable]; });
    dispatch_source_set_event_handler(_writeSource, ^{ [weakSelf socketWritable]; });
    _writeSourceArmed = NO;
    dispatch_resume(_readSource);   // read source stays active for the life of the connection
    // _writeSource stays suspended until there is write backpressure (a WRITE source spins while writable).
}

- (void)armWriteSource
{
    if (!_writeSource || _writeSourceArmed)
        return;
    _writeSourceArmed = YES;
    dispatch_resume(_writeSource);
}

- (void)disarmWriteSource
{
    if (!_writeSource || !_writeSourceArmed)
        return;
    _writeSourceArmed = NO;
    dispatch_suspend(_writeSource);
}

// OpenSSL ops can each want the opposite readiness (SSL_read wanting writable during a key update, SSL_write
// wanting readable, etc.), so each readiness event drives BOTH directions.
- (void)socketReadable
{
    if (_state == WKWSStateClosed)
        return;
    if (!_tlsHandshakeDone) {
        [self driveHandshake];
        return;
    }
    [self drainReads];
    if (_outBuffer.length)
        [self flushTLSWrites];
}

- (void)socketWritable
{
    if (_state == WKWSStateClosed)
        return;
    if (!_tlsHandshakeDone) {
        [self driveHandshake];
        return;
    }
    [self flushTLSWrites];
    [self drainReads];
}

// Drive the TLS 1.3 handshake to completion. SSL_get_error tells us which readiness it is waiting on; the
// read source is always armed, the write source is armed on demand. On completion, send the WS GET.
- (void)driveHandshake
{
    if (_state == WKWSStateClosed || _tlsHandshakeDone)
        return;
    int ret = ossl_SSL_connect(_ssl);
    if (ret == 1) {
        _tlsHandshakeDone = YES;
        _state = WKWSStateHandshaking;
        [self sendHandshake];       // queues the WS GET; writeBytes flushes it now that TLS is up
        [self drainReads];          // in case the 101 already arrived
        return;
    }
    int err = ossl_SSL_get_error(_ssl, ret);
    if (err == OSSL_ERROR_WANT_READ)
        return;                     // read source is always armed
    if (err == OSSL_ERROR_WANT_WRITE) {
        [self armWriteSource];
        return;
    }
    [self failWithReason:@"TLS handshake failed"];
}

// Pump decrypted plaintext until OpenSSL has none left (SSL_read is the decrypt engine; loop until it can't
// produce more), hand it to the frame parser, then act on close/error.
- (void)drainReads
{
    if (!_tlsHandshakeDone || _state == WKWSStateClosed)
        return;
    BOOL peerClosed = NO, failed = NO;
    for (;;) {
        uint8_t buf[16384];
        if (_ssl) {
            int ret = ossl_SSL_read(_ssl, buf, sizeof(buf));
            if (ret > 0) { [_inBuffer appendBytes:buf length:ret]; continue; }
            int err = ossl_SSL_get_error(_ssl, ret);
            if (err == OSSL_ERROR_WANT_READ) break;
            if (err == OSSL_ERROR_WANT_WRITE) { [self armWriteSource]; break; }
            if (err == OSSL_ERROR_ZERO_RETURN) { peerClosed = YES; break; }
            failed = YES; break;
        } else {
            ssize_t n = read(_fd, buf, sizeof(buf));
            if (n > 0) { [_inBuffer appendBytes:buf length:n]; continue; }
            if (n == 0) { peerClosed = YES; break; }
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            failed = YES; break;
        }
    }
    [self processInput];
    if (failed) {
        [self failWithReason:@"WebSocket read error"];
        return;
    }
    if (peerClosed) {
        if (_state != WKWSStateClosed && _state != WKWSStateClosing)
            [self failWithReason:@"WebSocket connection closed unexpectedly"];
        else
            [self teardownStreams];
    }
}

// Flush pending plaintext. With PARTIAL_WRITE + MOVING_WRITE_BUFFER, SSL_write reports the bytes it consumed;
// advance by that and retry the remainder. On WANT_WRITE arm the write source so it finishes when writable.
- (void)flushTLSWrites
{
    while (_outBuffer.length) {
        if (_ssl) {
            int len = (int)MIN(_outBuffer.length, (NSUInteger)INT_MAX);
            int ret = ossl_SSL_write(_ssl, _outBuffer.bytes, len);
            if (ret > 0) { [_outBuffer replaceBytesInRange:NSMakeRange(0, ret) withBytes:NULL length:0]; continue; }
            int err = ossl_SSL_get_error(_ssl, ret);
            if (err == OSSL_ERROR_WANT_WRITE) { [self armWriteSource]; return; }
            if (err == OSSL_ERROR_WANT_READ) return;   // needs readable; read source is armed
            [self failWithReason:@"WebSocket write error"];
            return;
        } else {
            ssize_t n = write(_fd, _outBuffer.bytes, _outBuffer.length);
            if (n > 0) { [_outBuffer replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0]; continue; }
            if (n == 0 || errno == EAGAIN || errno == EWOULDBLOCK) { [self armWriteSource]; return; }
            if (errno == EINTR) continue;
            [self failWithReason:@"WebSocket write error"];
            return;
        }
    }
    if (!_outBuffer.length)
        [self disarmWriteSource];
}

- (void)writeBytes:(NSData *)data
{
    [_outBuffer appendData:data];
    if (_tlsHandshakeDone)
        [self flushTLSWrites];
}

// ----- handshake -----

- (void)sendHandshake
{
    uint8_t keyBytes[16];
    arc4random_buf(keyBytes, sizeof(keyBytes));
    NSString *key = [[NSData dataWithBytes:keyBytes length:sizeof(keyBytes)] base64EncodedStringWithOptions:0];
    _acceptKey = [[self class] acceptForKey:key];

    NSURL *url = _request.URL;
    NSString *path = url.path.length ? url.path : @"/";
    NSString *resource = url.query.length ? [NSString stringWithFormat:@"%@?%@", path, url.query] : path;
    BOOL defaultPort = (url.port == nil) || (url.port.unsignedIntValue == 80) || (url.port.unsignedIntValue == 443);
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

- (BOOL)completeHandshakeWithHeaderData:(NSData *)headerData
{
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    if (!lines.count)
        return [self handshakeFailed:0];

    NSArray<NSString *> *statusParts = [lines.firstObject componentsSeparatedByString:@" "];
    NSInteger statusCode = statusParts.count >= 2 ? [statusParts[1] integerValue] : 0;

    NSMutableDictionary<NSString *, NSString *> *responseHeaders = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[lines[i] substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        responseHeaders[name] = value;
    }

    _response = [[NSHTTPURLResponse alloc] initWithURL:_request.URL statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:responseHeaders];

    if (statusCode != 101)
        return [self handshakeFailed:statusCode];

    // Validate Sec-WebSocket-Accept. Use the response's (case-insensitive) header lookup since
    // intermediaries — e.g. a Go reverse proxy — may canonicalize the name to "Sec-Websocket-Accept".
    NSString *accept = [(NSHTTPURLResponse *)_response valueForHTTPHeaderField:@"Sec-WebSocket-Accept"];
    if (![accept isEqualToString:_acceptKey])
        return [self handshakeFailed:statusCode];

    _state = WKWSStateOpen;
    NSString *protocol = [(NSHTTPURLResponse *)_response valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"] ?: @"";
    [self deliverDidOpenWithProtocol:protocol];
    return YES;
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
        int opcode = b0 & 0x0F;
        BOOL masked = (b1 & 0x80) != 0;
        uint64_t len = b1 & 0x7F;

        if (len == 126) {
            if (available - p < 2) break;
            len = ((uint64_t)bytes[p] << 8) | bytes[p + 1];
            p += 2;
        } else if (len == 127) {
            if (available - p < 8) break;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | bytes[p + i];
            p += 8;
        }
        uint8_t maskKey[4] = { 0, 0, 0, 0 };
        if (masked) {
            if (available - p < 4) break;
            memcpy(maskKey, bytes + p, 4);
            p += 4;
        }
        if ((uint64_t)(available - p) < len) break;

        std::vector<uint8_t> payload(len);
        for (uint64_t i = 0; i < len; i++)
            payload[i] = masked ? (bytes[p + i] ^ maskKey[i & 3]) : bytes[p + i];
        p += len;
        offset = p;

        [self handleFrameOpcode:opcode fin:fin payload:payload.data() length:len];
        if (_state == WKWSStateClosed)
            return; // _inBuffer was torn down
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
        if (opcode != 0x0) {
            [_messageBuffer setLength:0];
            _messageOpcode = opcode;
        }
        if (length)
            [_messageBuffer appendBytes:payload length:length];
        if (fin) {
            if (_messageOpcode == 0x1) {
                NSString *text = [[NSString alloc] initWithData:_messageBuffer encoding:NSUTF8StringEncoding] ?: @"";
                [self deliverMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]];
            } else
                [self deliverMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:[_messageBuffer copy]]];
            [_messageBuffer setLength:0];
            _messageOpcode = -1;
        }
        break;
    case 0x8: {
        uint16_t code = 1005;
        NSData *reason = nil;
        if (length >= 2) {
            code = (uint16_t)((payload[0] << 8) | payload[1]);
            if (length > 2)
                reason = [NSData dataWithBytes:payload + 2 length:length - 2];
        }
        if (!_sentClose) {
            _sentClose = YES;
            uint8_t echo[2] = { (uint8_t)(code >> 8), (uint8_t)(code & 0xFF) };
            [self enqueueFrameWithOpcode:0x8 payload:[NSData dataWithBytes:echo length:2]];
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

- (void)enqueueFrameWithOpcode:(int)opcode payload:(NSData *)payload
{
    if (_state == WKWSStateClosed)
        return;
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

    const uint8_t *src = (const uint8_t *)payload.bytes;
    std::vector<uint8_t> masked(len);
    for (NSUInteger i = 0; i < len; i++)
        masked[i] = src[i] ^ maskKey[i & 3];
    [frame appendBytes:masked.data() length:len];

    [self writeBytes:frame];
}

- (void)sendCloseFrameWithCode:(uint16_t)code reason:(NSData *)reason
{
    if (_sentClose)
        return;
    _sentClose = YES;
    NSMutableData *payload = [NSMutableData data];
    uint8_t codeBytes[2] = { (uint8_t)(code >> 8), (uint8_t)(code & 0xFF) };
    [payload appendBytes:codeBytes length:2];
    if (reason.length)
        [payload appendData:reason];
    [self enqueueFrameWithOpcode:0x8 payload:payload];
    [self flushTLSWrites];
}

// ----- teardown / failure -----

- (void)failWithReason:(NSString *)reason
{
    if (_state == WKWSStateClosed)
        return;
    _state = WKWSStateClosed;
    [self deliverError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:@{ NSLocalizedDescriptionKey: reason }]];
    [self teardownStreams];
}

// Called on _ioQueue (the only queue touching OpenSSL + the sources), so there is no concurrent handler to
// race. Cancel the readiness sources (resuming the write source first if suspended — releasing a suspended
// dispatch source crashes), tear down the OpenSSL session, then close the fd.
- (void)teardownStreams
{
    _state = WKWSStateClosed;
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = NULL;
    }
    if (_writeSource) {
        if (!_writeSourceArmed) {
            _writeSourceArmed = YES;
            dispatch_resume(_writeSource);  // must not release a suspended source
        }
        dispatch_source_cancel(_writeSource);
        _writeSource = NULL;
    }
    if (_ssl) {
        ossl_SSL_shutdown(_ssl);            // best-effort close_notify
        ossl_SSL_free(_ssl);
        _ssl = NULL;
    }
    if (_sslCtx) {
        ossl_SSL_CTX_free(_sslCtx);
        _sslCtx = NULL;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@end

// ---------------------------------------------------------------------------------------------------
// -[NSURLSession webSocketTaskWithRequest:] implementation (injected via +load above).
// `session` is the receiver (the NSURLSession instance).
// ---------------------------------------------------------------------------------------------------

static id wsWebSocketTaskWithRequest(NSURLSession *session, SEL, NSURLRequest *request)
{
    static std::atomic<uint32_t> identifierCounter { 0x10000 };
    NSUInteger identifier = ++identifierCounter;

    NSString *protocol = [request valueForHTTPHeaderField:@"Sec-WebSocket-Protocol"];

    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    if (![mutableRequest valueForHTTPHeaderField:@"Cookie"]) {
        NSHTTPCookieStorage *storage = session.configuration.HTTPCookieStorage ?: [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray<NSHTTPCookie *> *cookies = [storage cookiesForURL:request.URL];
        if (cookies.count) {
            NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
            if (cookieHeader.length)
                [mutableRequest setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        }
    }

    WKWebSocketStream *stream = [[WKWebSocketStream alloc] initWithRequest:mutableRequest protocol:protocol session:session taskIdentifier:identifier];
    return (NSURLSessionWebSocketTask *)stream;
}
