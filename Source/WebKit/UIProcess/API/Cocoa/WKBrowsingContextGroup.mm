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

// 10.9 backport: minimal restoration of the legacy WebKit2 ObjC
// WKBrowsingContextGroup, removed upstream. QuickLook's Web2.qldisplay creates
// one to back its WKView. We wrap a WKPageGroupRef created through the still-
// present C SPI; WKView pulls it back out via -_pageGroupRef.

#import "config.h"
#import "WKBrowsingContextGroupInternal.h"

#import "WKPageGroup.h"
#import "WKPreferencesRef.h"
#import "WKString.h"
#import "WKStringCF.h"
#import "WKType.h"

@implementation WKBrowsingContextGroup {
    WKPageGroupRef _pageGroup;
    BOOL _allowsJavaScript;
}

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    self = [super init];
    if (!self)
        return nil;

    WKStringRef wkIdentifier = WKStringCreateWithCFString((__bridge CFStringRef)identifier);
    _pageGroup = WKPageGroupCreateWithIdentifier(wkIdentifier);
    WKRelease(wkIdentifier);

    _allowsJavaScript = YES;
    [self setAllowsJavaScript:YES];

    return self;
}

- (void)dealloc
{
    if (_pageGroup)
        WKRelease(_pageGroup);
    [super dealloc];
}

- (WKPageGroupRef)_pageGroupRef
{
    return _pageGroup;
}

- (BOOL)allowsJavaScript
{
    return _allowsJavaScript;
}

- (void)setAllowsJavaScript:(BOOL)allowsJavaScript
{
    _allowsJavaScript = allowsJavaScript;
    if (_pageGroup)
        WKPreferencesSetJavaScriptEnabled(WKPageGroupGetPreferences(_pageGroup), allowsJavaScript);
}

// Web2.qldisplay's getter is spelled -allowsJavascript and its setter
// -setAllowsJavaScript:; provide the lowercase-'s' spellings as aliases.
- (BOOL)allowsJavascript
{
    return [self allowsJavaScript];
}

- (void)setAllowsJavascript:(BOOL)allowsJavascript
{
    [self setAllowsJavaScript:allowsJavascript];
}

@end
