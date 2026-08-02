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

// MAVERICKS_BACKPORT: new file. A minimal RFC 6455 WebSocket client over NSStream +
// Secure Transport, used by MozillaPushServiceConnection to reach the Mozilla autopush
// service. webpushd runs on macOS 10.9, which has no NSURLSessionWebSocketTask (10.15+),
// so the daemon carries its own client: TLS via the kCFStreamSSLPeerName-validated
// socket-stream pair, frames parsed/written by hand. Text, binary, ping/pong, close and
// fragmented messages are handled; extensions and subprotocols are not offered.

#pragma once

#if USE(MOZILLA_PUSH_SERVICE)

#import <Foundation/Foundation.h>

@class MozillaPushWebSocket;

@protocol MozillaPushWebSocketDelegate <NSObject>
- (void)webSocketDidOpen:(MozillaPushWebSocket *)webSocket;
- (void)webSocket:(MozillaPushWebSocket *)webSocket didReceiveMessage:(NSString *)message;
- (void)webSocket:(MozillaPushWebSocket *)webSocket didCloseWithError:(NSError *)error;
// Ping/pong control frames prove the connection is alive without carrying a message;
// the connection's dead-socket detector counts them as activity.
- (void)webSocketDidReceiveControlFrame:(MozillaPushWebSocket *)webSocket;
@end

@interface MozillaPushWebSocket : NSObject <NSStreamDelegate>

// Scheduled on the main run loop; all delegate callbacks arrive there.
- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port path:(NSString *)path useTLS:(BOOL)useTLS delegate:(id<MozillaPushWebSocketDelegate>)delegate;

- (void)open;
- (void)sendMessage:(NSString *)message;

// Tears the socket down without a delegate callback. Safe to call at any time; the
// object cannot be reopened afterwards.
- (void)invalidate;

@property (nonatomic, readonly) BOOL isOpen;

@end

#endif // USE(MOZILLA_PUSH_SERVICE)
