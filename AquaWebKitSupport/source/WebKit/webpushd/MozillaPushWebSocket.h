/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A minimal RFC 6455 WebSocket client over NSStream +
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
// Returns whether the frame reached the socket rather than being left buffered, so a
// caller that treats a send as a liveness probe can tell whether it actually probed.
- (BOOL)sendMessage:(NSString *)message;

// Tears the socket down without a delegate callback. Safe to call at any time; the
// object cannot be reopened afterwards.
- (void)invalidate;

@property (nonatomic, readonly) BOOL isOpen;

@end

#endif // USE(MOZILLA_PUSH_SERVICE)
