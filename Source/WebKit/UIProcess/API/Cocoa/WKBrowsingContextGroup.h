/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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

#import <WebKit/WKFoundation.h>

#import <Foundation/Foundation.h>
#import <WebKit/WKUserScriptInjectionTime.h>

// FIXME: Remove this header once rdar://112426343 is resolved.

// 10.9 backport: the WKBrowsingContextGroup class interface was gutted upstream
// (only the header shell remains). Restore the minimal surface that Apple's
// QuickLook Web2.qldisplay uses so the HTML preview display bundle can link and
// instantiate it. Without the class, dlopen of Web2 fails on the missing
// _OBJC_CLASS_$_WKBrowsingContextGroup symbol.

#if !TARGET_OS_IPHONE

// visibility("default") so _OBJC_CLASS_$_WKBrowsingContextGroup is exported from
// WebKit2 (the build defaults to hidden visibility).
__attribute__((visibility("default")))
@interface WKBrowsingContextGroup : NSObject

- (instancetype)initWithIdentifier:(NSString *)identifier;

// Web2.qldisplay toggles JavaScript on the preview's page group. The getter it
// sends is -allowsJavascript and the setter -setAllowsJavaScript:; we expose
// both spellings to match whichever the bundle was compiled against.
@property (nonatomic) BOOL allowsJavaScript;
- (BOOL)allowsJavascript;
- (void)setAllowsJavascript:(BOOL)allowsJavascript;

// Web2.qldisplay also toggles plug-ins on the preview's page group while
// configuring it. Modern WebKit has no plug-in support, so this is tracked for
// API fidelity but is inert.
@property (nonatomic) BOOL allowsPlugIns;

// Web2.qldisplay may install a user style sheet on the group to style the
// preview. The page-group user-content C SPI is a no-op on this backport, so the
// preview renders the document's own styles.
- (void)addUserStyleSheet:(NSString *)source baseURL:(NSURL *)baseURL whitelistedURLPatterns:(NSArray *)whitelistedURLPatterns blacklistedURLPatterns:(NSArray *)blacklistedURLPatterns mainFrameOnly:(BOOL)mainFrameOnly;

@end

#endif // !TARGET_OS_IPHONE
