/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

#import <WebKit/_WKInspectorWindow.h>

#if !TARGET_OS_IPHONE

NS_ASSUME_NONNULL_BEGIN

// MAVERICKS_BACKPORT: the margin from the top and right of a dock button (same as the full screen
// button), shared by the window's title layout and the placement in platformCreateFrontendWindow.
extern const CGFloat WKInspectorWindowDockButtonMargin;

@interface _WKInspectorWindow ()

@property (nonatomic, readwrite, getter=isForRemoteTarget) BOOL forRemoteTarget;
@property (nonatomic, nullable, readwrite, weak) WKWebView *inspectedWebView SUPPRESS_UNRETAINED_MEMBER;

// MAVERICKS_BACKPORT: the window's native dock controls, so it can lay its title out around them and
// suppress the northeast resize cursor they sit under (WebInspectorUIProxy::platformCreateFrontendWindow
// builds them). Nil on a window without them, which is every remote-target window.
@property (nonatomic, nullable, readwrite, strong) NSButton *dockBottomButton;
@property (nonatomic, nullable, readwrite, strong) NSButton *dockRightButton;

@end

NS_ASSUME_NONNULL_END

#endif // !TARGET_OS_IPHONE
