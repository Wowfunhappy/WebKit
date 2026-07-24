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
//   * WKWebSocketStream             — an RFC 6455 client over CFStream (TLS via
//     kCFStreamSocketSecurityLevelNegotiatedSSL) that masquerades as the NSURLSessionWebSocketTask
//     WebSocketTaskCocoa drives (resume/cancel/currentRequest/response/closeCode/taskIdentifier/
//     receiveMessageWithCompletionHandler:/sendMessage:completionHandler:/cancelWithCloseCode:reason:).
//   * -[NSURLSession webSocketTaskWithRequest:] — already called (respondsToSelector-guarded) by
//     NetworkSessionCocoa::createWebSocketTask; returns a WKWebSocketStream.
// On open/close it invokes the session delegate's NSURLSessionWebSocketDelegate methods (passing itself
// as the task) exactly as NSURLSession would, so the existing webSocketDataTaskMap -> WebSocketTask::
// didConnect/didClose path is unchanged. Delegate + receive callbacks are delivered on the main queue
// (where createWebSocketTask/addWebSocketTask run); socket I/O runs on a private serial queue.
//
// Compiled with -fobjc-arc (see CMakeLists.txt). The CFStream client context retains self, so the
// stream outlives any in-flight socket callbacks until teardown clears the client.

#include "config.h"
#import "wk_selref_scope.h" // MAVERICKS_BACKPORT: WK_POLYFILL_SEL/WK_POLYFILL_ADD host-safe polyfill registry.
#import <CFNetwork/CFNetwork.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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
    NSURLRequest *_request;
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

// MAVERICKS_BACKPORT: expose -[NSURLSession webSocketTaskWithRequest:] (10.15+) host-safely via the
// WebKit-scoped selref mechanism, exactly like its valueForHTTPHeaderField: sibling. WK_POLYFILL_SEL
// rewrites WebKit images' `webSocketTaskWithRequest:` selrefs to the PRIVATE `wk_webSocketTaskWithRequest:`,
// and WK_POLYFILL_ADD installs that private method (backed by wsWebSocketTaskWithRequest) on each concrete
// NSURLSession class-cluster class at runtime (the cluster's instances are __NSCFURLSession, NOT an
// NSURLSession subclass, so every concrete class needs it). On 10.9 the cluster has exactly one concrete
// class, __NSCFURLSession — probed on-host; __NSURLSessionLocal is a later OS's name and does not exist
// here, and an entry no class can ever satisfy sits in the installer's retry list for the life of the
// process. The PUBLIC selector stays absent on the class, so an embedder's
// -respondsToSelector:@selector(webSocketTaskWithRequest:) still returns NO on 10.9 — no 10.15+
// misdetection (the meta-crash family the old process-global class_addMethod injection risked).
WK_POLYFILL_SEL("webSocketTaskWithRequest:", "wk_webSocketTaskWithRequest:");
WK_POLYFILL_ADD("NSURLSession", "wk_webSocketTaskWithRequest:", wsWebSocketTaskWithRequest, "@@:@");
WK_POLYFILL_ADD("__NSCFURLSession", "wk_webSocketTaskWithRequest:", wsWebSocketTaskWithRequest, "@@:@");

@implementation WKWebSocketStream

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

    // This VM has no direct route to external hosts; all traffic goes through the system proxy (the same
    // one NSURLSession uses). Raw CFSocketStreams ignore kCFStreamPropertyHTTPProxy, and adding TLS to an
    // already-open CFStream (deferred TLS after a CONNECT) is unreliable. So we open the proxy tunnel on a
    // plain BSD socket (blocking HTTP CONNECT — cheap, the proxy is local), then wrap the established
    // socket in CFStreams with TLS configured BEFORE opening, which engages reliably.
    NSDictionary *sys = (__bridge_transfer NSDictionary *)CFNetworkCopySystemProxySettings();
    NSString *proxyHost = secure ? sys[@"HTTPSProxy"] : sys[@"HTTPProxy"];
    NSNumber *proxyPort = secure ? sys[@"HTTPSPort"] : sys[@"HTTPPort"];
    BOOL proxyEnabled = [sys[secure ? @"HTTPSEnable" : @"HTTPEnable"] boolValue];

    if (proxyEnabled && proxyHost.length) {
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
    NSDictionary *ssl = @{ (__bridge id)kCFStreamSSLPeerName: _targetHost };
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
    case kCFStreamEventHasBytesAvailable: {
        uint8_t buf[16384];
        while (CFReadStreamHasBytesAvailable(_readStream)) {
            CFIndex n = CFReadStreamRead(_readStream, buf, sizeof(buf));
            if (n <= 0)
                break;
            [_inBuffer appendBytes:buf length:n];
        }
        [self processInput];
        break;
    }
    case kCFStreamEventErrorOccurred: {
        NSError *e = (__bridge_transfer NSError *)CFReadStreamCopyError(_readStream);
        [self failWithReason:@"WebSocket socket read error"];
        break;
    }
    case kCFStreamEventEndEncountered:
        if (_state != WKWSStateClosed && _state != WKWSStateClosing) {
            [self failWithReason:@"WebSocket connection closed unexpectedly"];
        } else
            [self teardownStreams];
        break;
    default:
        break;
    }
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
        [self failWithReason:@"WebSocket socket write error"];
        break;
    }
    default:
        break;
    }
}

- (void)flushOutput
{
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
    [self flushOutput];
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

- (void)teardownStreams
{
    _state = WKWSStateClosed;
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
        // MAVERICKS_BACKPORT: -[NSHTTPCookieStorage cookiesForURL:] only treats http/https as a
        // secure scheme, so looking cookies up under a ws://wss:// URL silently drops every Secure
        // cookie (e.g. figma's __Host-figma.authn / figma.session), leaving the WebSocket handshake
        // unauthenticated. WebKit always looks WebSocket cookies up under the http(s) equivalent URL
        // (WebSocketHandshake::httpURLForAuthenticationAndCookies); mirror that here so a wss:// URL
        // gets exactly the cookies https:// would.
        NSURL *cookieURL = request.URL;
        NSString *scheme = cookieURL.scheme.lowercaseString;
        if ([scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"ws"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:cookieURL resolvingAgainstBaseURL:NO];
            components.scheme = [scheme isEqualToString:@"wss"] ? @"https" : @"http";
            if (components.URL)
                cookieURL = components.URL;
        }
        NSArray<NSHTTPCookie *> *cookies = [storage cookiesForURL:cookieURL];
        if (cookies.count) {
            NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
            if (cookieHeader.length)
                [mutableRequest setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        }
    }

    WKWebSocketStream *stream = [[WKWebSocketStream alloc] initWithRequest:mutableRequest protocol:protocol session:session taskIdentifier:identifier];
    return (NSURLSessionWebSocketTask *)stream;
}
