/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "config.h"
#import "MozillaPushWebSocket.h"

#if USE(MOZILLA_PUSH_SERVICE)

#import "Logging.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/SecRandom.h>
#import <wtf/Assertions.h>

static NSString * const webSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// Frames and complete fragmented messages larger than this indicate a broken peer; autopush
// messages are a few KB at most. Bound the HTTP upgrade too: it is parsed before frame limits apply.
static const uint64_t maxFramePayloadLength = 4 * 1024 * 1024;
static const uint64_t maxMessagePayloadLength = maxFramePayloadLength;
static const NSUInteger maxHandshakeHeaderLength = 64 * 1024;

enum : uint8_t {
    OpcodeContinuation = 0x0,
    OpcodeText = 0x1,
    OpcodeBinary = 0x2,
    OpcodeClose = 0x8,
    OpcodePing = 0x9,
    OpcodePong = 0xA,
};

@implementation MozillaPushWebSocket {
    NSString *_host;
    NSInteger _port;
    NSString *_path;
    BOOL _useTLS;
    __weak id<MozillaPushWebSocketDelegate> _delegate;

    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;

    NSString *_expectedAcceptKey;
    BOOL _handshakeComplete;
    BOOL _outputStreamHasSpace;
    BOOL _sentCloseFrame;
    BOOL _invalidated;

    NSMutableData *_readBuffer;
    NSMutableData *_writeBuffer;

    // Reassembly state for fragmented messages.
    uint8_t _fragmentedOpcode;
    NSMutableData *_fragmentBuffer;
}

- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port path:(NSString *)path useTLS:(BOOL)useTLS delegate:(id<MozillaPushWebSocketDelegate>)delegate
{
    if (!(self = [super init]))
        return nil;

    _host = [host copy];
    _port = port;
    _path = [path copy];
    _useTLS = useTLS;
    _delegate = delegate;
    _readBuffer = [NSMutableData data];
    _writeBuffer = [NSMutableData data];

    return self;
}

- (void)dealloc
{
    [self invalidate];
}

- (BOOL)isOpen
{
    return _handshakeComplete && !_invalidated;
}

- (void)open
{
    ASSERT(!_inputStream);

    CFReadStreamRef readStream = nullptr;
    CFWriteStreamRef writeStream = nullptr;
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)_host, (UInt32)_port, &readStream, &writeStream);
    if (!readStream || !writeStream) {
        [self failWithMessage:@"could not create socket streams"];
        return;
    }

    _inputStream = (__bridge_transfer NSInputStream *)readStream;
    _outputStream = (__bridge_transfer NSOutputStream *)writeStream;

    if (_useTLS) {
        // Secure Transport validates the chain against the system trust store and checks the
        // peer name given here; it also sends it as SNI.
        NSDictionary *sslSettings = @{ (__bridge NSString *)kCFStreamSSLPeerName: _host };
        [_inputStream setProperty:sslSettings forKey:(__bridge NSString *)kCFStreamPropertySSLSettings];
        [_outputStream setProperty:sslSettings forKey:(__bridge NSString *)kCFStreamPropertySSLSettings];
    }

    _inputStream.delegate = self;
    _outputStream.delegate = self;
    [_inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_inputStream open];
    [_outputStream open];

    [self queueHandshakeRequest];
}

- (void)queueHandshakeRequest
{
    uint8_t nonce[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(nonce), nonce) != errSecSuccess) {
        [self failWithMessage:@"could not generate handshake nonce"];
        return;
    }
    NSString *key = [[NSData dataWithBytes:nonce length:sizeof(nonce)] base64EncodedStringWithOptions:0];

    NSData *acceptInput = [[key stringByAppendingString:webSocketGUID] dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(acceptInput.bytes, (CC_LONG)acceptInput.length, digest);
    _expectedAcceptKey = [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];

    BOOL isDefaultPort = (_useTLS && _port == 443) || (!_useTLS && _port == 80);
    NSString *hostHeader = isDefaultPort ? _host : [NSString stringWithFormat:@"%@:%ld", _host, (long)_port];
    NSString *request = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\n"
        "Host: %@\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %@\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n",
        _path, hostHeader, key];
    [_writeBuffer appendData:[request dataUsingEncoding:NSUTF8StringEncoding]];
    [self flushWriteBuffer];
}

- (BOOL)sendMessage:(NSString *)message
{
    if (_invalidated)
        return NO;
    [self sendFrameWithOpcode:OpcodeText payload:[message dataUsingEncoding:NSUTF8StringEncoding]];
    return !_writeBuffer.length;
}

- (void)sendFrameWithOpcode:(uint8_t)opcode payload:(NSData *)payload
{
    uint64_t length = payload.length;
    uint8_t header[14];
    size_t headerLength = 0;
    header[headerLength++] = 0x80 | opcode; // FIN + opcode; no fragmentation on send.

    if (length < 126)
        header[headerLength++] = 0x80 | (uint8_t)length;
    else if (length <= 0xFFFF) {
        header[headerLength++] = 0x80 | 126;
        header[headerLength++] = (length >> 8) & 0xFF;
        header[headerLength++] = length & 0xFF;
    } else {
        header[headerLength++] = 0x80 | 127;
        for (int shift = 56; shift >= 0; shift -= 8)
            header[headerLength++] = (length >> shift) & 0xFF;
    }

    uint8_t mask[4];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(mask), mask) != errSecSuccess) {
        [self failWithMessage:@"could not generate frame mask"];
        return;
    }
    memcpy(header + headerLength, mask, 4);
    headerLength += 4;

    [_writeBuffer appendBytes:header length:headerLength];

    NSMutableData *maskedPayload = [payload mutableCopy];
    uint8_t *bytes = (uint8_t *)maskedPayload.mutableBytes;
    for (uint64_t i = 0; i < length; i++)
        bytes[i] ^= mask[i % 4];
    [_writeBuffer appendData:maskedPayload];

    [self flushWriteBuffer];
}

- (void)flushWriteBuffer
{
    if (!_writeBuffer.length || _invalidated)
        return;
    if (!_outputStreamHasSpace && !_outputStream.hasSpaceAvailable)
        return;

    NSInteger written = [_outputStream write:(const uint8_t *)_writeBuffer.bytes maxLength:_writeBuffer.length];
    if (written < 0) {
        [self closeWithError:_outputStream.streamError];
        return;
    }
    if (written > 0)
        [_writeBuffer replaceBytesInRange:NSMakeRange(0, written) withBytes:nullptr length:0];

    // A short write means the stream is full, and anything still buffered waits for the next
    // NSStreamEventHasSpaceAvailable. A write that drained the buffer says nothing about the
    // stream being full, so ask it rather than assuming the worst -- assuming it would strand
    // the next frame in the buffer until an unrelated event happened to arrive.
    _outputStreamHasSpace = _writeBuffer.length ? NO : _outputStream.hasSpaceAvailable;
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event
{
    if (_invalidated)
        return;

    switch (event) {
    case NSStreamEventHasSpaceAvailable:
        _outputStreamHasSpace = YES;
        [self flushWriteBuffer];
        break;
    case NSStreamEventHasBytesAvailable:
        [self readAvailableBytes];
        break;
    case NSStreamEventErrorOccurred:
        [self closeWithError:stream.streamError];
        break;
    case NSStreamEventEndEncountered:
        [self closeWithError:nil];
        break;
    default:
        break;
    }
}

- (void)readAvailableBytes
{
    uint8_t chunk[4096];
    while (_inputStream.hasBytesAvailable) {
        NSInteger bytesRead = [_inputStream read:chunk maxLength:sizeof(chunk)];
        if (bytesRead < 0) {
            [self closeWithError:_inputStream.streamError];
            return;
        }
        if (!bytesRead) {
            // Zero from -read:maxLength: is end of stream, not "nothing right now". The peer
            // has closed; the connection has to be reported closed here, because discovering
            // the EOF by reading consumes it and NSStreamEventEndEncountered may never come.
            [self closeWithError:nil];
            return;
        }
        [_readBuffer appendBytes:chunk length:bytesRead];
    }

    if (!_handshakeComplete && ![self tryCompleteHandshake])
        return;

    [self parseFrames];
}

- (BOOL)tryCompleteHandshake
{
    NSData *delimiter = [NSData dataWithBytes:"\r\n\r\n" length:4];
    NSRange headerEnd = [_readBuffer rangeOfData:delimiter options:0 range:NSMakeRange(0, _readBuffer.length)];
    if (headerEnd.location == NSNotFound) {
        if (_readBuffer.length > maxHandshakeHeaderLength)
            [self failWithMessage:@"oversized handshake response"];
        return NO;
    }
    if (headerEnd.location + headerEnd.length > maxHandshakeHeaderLength) {
        [self failWithMessage:@"oversized handshake response"];
        return NO;
    }

    NSString *response = [[NSString alloc] initWithData:[_readBuffer subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding];
    [_readBuffer replaceBytesInRange:NSMakeRange(0, headerEnd.location + headerEnd.length) withBytes:nullptr length:0];
    if (!response) {
        [self failWithMessage:@"handshake response is not valid UTF-8"];
        return NO;
    }

    NSArray<NSString *> *lines = [response componentsSeparatedByString:@"\r\n"];
    NSRegularExpression *statusPattern = [NSRegularExpression regularExpressionWithPattern:@"^HTTP/1\\.[01] 101(?: |$)" options:NSRegularExpressionCaseInsensitive error:nil];
    if (!lines.count || ![statusPattern firstMatchInString:lines[0] options:0 range:NSMakeRange(0, [lines[0] length])]) {
        [self failWithMessage:[NSString stringWithFormat:@"handshake rejected: %@", lines.count ? lines[0] : @"(empty)"]];
        return NO;
    }

    NSString *acceptValue = nil;
    NSString *upgradeValue = nil;
    NSString *connectionValue = nil;
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name isEqualToString:@"sec-websocket-accept"]) {
            if (acceptValue) {
                [self failWithMessage:@"duplicate handshake accept header"];
                return NO;
            }
            acceptValue = value;
        } else if ([name isEqualToString:@"upgrade"])
            upgradeValue = value;
        else if ([name isEqualToString:@"connection"])
            connectionValue = value;
    }
    if (![acceptValue isEqualToString:_expectedAcceptKey]) {
        [self failWithMessage:@"handshake accept key mismatch"];
        return NO;
    }
    if (!upgradeValue || [upgradeValue caseInsensitiveCompare:@"websocket"] != NSOrderedSame) {
        [self failWithMessage:@"handshake Upgrade header mismatch"];
        return NO;
    }
    BOOL connectionUpgrades = NO;
    for (NSString *token in [connectionValue componentsSeparatedByString:@","]) {
        if ([[token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] caseInsensitiveCompare:@"upgrade"] == NSOrderedSame) {
            connectionUpgrades = YES;
            break;
        }
    }
    if (!connectionUpgrades) {
        [self failWithMessage:@"handshake Connection header mismatch"];
        return NO;
    }

    _handshakeComplete = YES;
    RELEASE_LOG(Push, "MozillaPushWebSocket: connection to %{public}s established", _host.UTF8String);
    [_delegate webSocketDidOpen:self];
    return YES;
}

- (void)parseFrames
{
    while (!_invalidated) {
        const uint8_t *bytes = (const uint8_t *)_readBuffer.bytes;
        NSUInteger available = _readBuffer.length;
        if (available < 2)
            return;

        BOOL fin = bytes[0] & 0x80;
        uint8_t opcode = bytes[0] & 0x0F;
        BOOL masked = bytes[1] & 0x80;
        uint64_t payloadLength = bytes[1] & 0x7F;
        NSUInteger offset = 2;

        if (bytes[0] & 0x70) {
            [self failWithMessage:@"frame sets a reserved bit"];
            return;
        }
        if (masked) {
            [self failWithMessage:@"server frame is masked"];
            return;
        }

        if (payloadLength == 126) {
            if (available < 4)
                return;
            payloadLength = ((uint64_t)bytes[2] << 8) | bytes[3];
            offset = 4;
            if (payloadLength < 126) {
                [self failWithMessage:@"frame length is not minimally encoded"];
                return;
            }
        } else if (payloadLength == 127) {
            if (available < 10)
                return;
            payloadLength = 0;
            for (int i = 0; i < 8; i++)
                payloadLength = (payloadLength << 8) | bytes[2 + i];
            offset = 10;
            if (payloadLength & 0x8000000000000000ULL) {
                [self failWithMessage:@"frame length has its most significant bit set"];
                return;
            }
            if (payloadLength <= 0xFFFF) {
                [self failWithMessage:@"frame length is not minimally encoded"];
                return;
            }
        }

        if (payloadLength > maxFramePayloadLength) {
            [self failWithMessage:@"oversized frame"];
            return;
        }

        switch (opcode) {
        case OpcodeContinuation:
        case OpcodeText:
        case OpcodeBinary:
        case OpcodeClose:
        case OpcodePing:
        case OpcodePong:
            break;
        default:
            [self failWithMessage:[NSString stringWithFormat:@"reserved opcode %u", opcode]];
            return;
        }
        if (opcode & 0x8) {
            if (!fin) {
                [self failWithMessage:@"fragmented control frame"];
                return;
            }
            if (payloadLength > 125) {
                [self failWithMessage:@"oversized control frame"];
                return;
            }
            if (opcode == OpcodeClose && payloadLength == 1) {
                [self failWithMessage:@"invalid close frame payload"];
                return;
            }
        } else if ((uint64_t)_fragmentBuffer.length + payloadLength > maxMessagePayloadLength) {
            [self failWithMessage:@"oversized message"];
            return;
        }

        if (available < offset + payloadLength)
            return;

        NSData *payload = [_readBuffer subdataWithRange:NSMakeRange(offset, (NSUInteger)payloadLength)];
        [_readBuffer replaceBytesInRange:NSMakeRange(0, offset + (NSUInteger)payloadLength) withBytes:nullptr length:0];

        [self handleFrameWithOpcode:opcode fin:fin payload:payload];
    }
}

- (void)handleFrameWithOpcode:(uint8_t)opcode fin:(BOOL)fin payload:(NSData *)payload
{
    switch (opcode) {
    case OpcodeText:
    case OpcodeBinary:
        if (_fragmentBuffer) {
            [self failWithMessage:@"data frame interrupts a fragmented message"];
            return;
        }
        if (!fin) {
            _fragmentedOpcode = opcode;
            _fragmentBuffer = [payload mutableCopy];
            return;
        }
        [self dispatchMessageWithOpcode:opcode payload:payload];
        return;
    case OpcodeContinuation:
        if (!_fragmentBuffer) {
            [self failWithMessage:@"continuation frame without initial fragment"];
            return;
        }
        [_fragmentBuffer appendData:payload];
        if (fin) {
            NSData *message = _fragmentBuffer;
            uint8_t messageOpcode = _fragmentedOpcode;
            _fragmentBuffer = nil;
            [self dispatchMessageWithOpcode:messageOpcode payload:message];
        }
        return;
    case OpcodePing:
        [self sendFrameWithOpcode:OpcodePong payload:payload];
        [_delegate webSocketDidReceiveControlFrame:self];
        return;
    case OpcodePong:
        [_delegate webSocketDidReceiveControlFrame:self];
        return;
    case OpcodeClose:
        if (!_sentCloseFrame) {
            _sentCloseFrame = YES;
            [self sendFrameWithOpcode:OpcodeClose payload:payload.length >= 2 ? [payload subdataWithRange:NSMakeRange(0, 2)] : [NSData data]];
        }
        [self closeWithError:nil];
        return;
    default:
        [self failWithMessage:[NSString stringWithFormat:@"unknown opcode %u", opcode]];
        return;
    }
}

- (void)dispatchMessageWithOpcode:(uint8_t)opcode payload:(NSData *)payload
{
    // autopush only sends JSON text; tolerate a peer that marks it binary.
    NSString *message = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (!message) {
        [self failWithMessage:@"message is not valid UTF-8"];
        return;
    }
    [_delegate webSocket:self didReceiveMessage:message];
}

- (void)failWithMessage:(NSString *)message
{
    RELEASE_LOG_ERROR(Push, "MozillaPushWebSocket: %{public}s", message.UTF8String);
    [self closeWithError:[NSError errorWithDomain:@"MozillaPushWebSocket" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }]];
}

- (void)closeWithError:(NSError *)error
{
    if (_invalidated)
        return;
    id<MozillaPushWebSocketDelegate> delegate = _delegate;
    [self invalidate];
    [delegate webSocket:self didCloseWithError:error];
}

- (void)invalidate
{
    if (_invalidated)
        return;
    _invalidated = YES;
    _delegate = nil;

    _inputStream.delegate = nil;
    _outputStream.delegate = nil;
    [_inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_inputStream close];
    [_outputStream close];
    _inputStream = nil;
    _outputStream = nil;
}

@end

#endif // USE(MOZILLA_PUSH_SERVICE)
