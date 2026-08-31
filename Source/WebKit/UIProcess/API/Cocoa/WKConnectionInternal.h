/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT (#137): internal creation/dispatch + body-coding surface for WKConnection.

#import "WKConnection.h"
#import "WKBase.h"

// The send block performs the actual cross-process post (WebProcess: WKBundlePostMessage;
// UIProcess: WKContextPostMessageToInjectedBundle). serializedBody is a +0 WKDataRef (or null).
typedef void (^WKConnectionSendBlock)(NSString *messageName, WKTypeRef serializedBody);

@interface WKConnection ()
- (instancetype)initWithSender:(WKConnectionSendBlock)sender;
// Invoked by the receive sites (bundle/context clients) when a message arrives for this connection.
- (void)_dispatchDidReceiveMessageWithName:(NSString *)messageName serializedBody:(WKTypeRef)serializedBody;
- (void)_dispatchDidClose;
@end

// Body coding: arbitrary NSCoding ObjC object <-> a +1 WKDataRef (NSKeyedArchiver). Mail's message
// classes (MUIMessage*, NSAttributedString, NSData, …) are present in both the app and the WebContent
// (MailUI/MailUIWebBundle is loaded in each), so a plain keyed archive round-trips them.
WKTypeRef WKConnectionCreateSerializedBody(id body);   // +1 WK object graph, or nullptr
id WKConnectionBodyFromSerialized(WKTypeRef serialized); // autoreleased, or nil

// Register a page controller (WKWebProcessPlugInBrowserContextController in the WebProcess, or
// WKBrowsingContextController in the UIProcess) under the page's cross-process WebPageProxyIdentifier,
// so a controller referenced in a message body round-trips to the peer process's controller for the
// same page. Called once per controller, at creation.
void WKConnectionRegisterController(uint64_t pageProxyID, id controller);
