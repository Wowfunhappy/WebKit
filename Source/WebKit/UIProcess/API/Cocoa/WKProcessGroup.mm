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

// 10.9 backport: minimal restoration of the legacy WebKit2 ObjC WKProcessGroup,
// removed upstream. QuickLook's Web2.qldisplay creates one to back its WKView.
// We wrap a WKContextRef (WebProcessPool) created through the still-present C
// SPI; WKView pulls it back out via -_contextRef (WKProcessGroupInternal.h).

#import "config.h"
#import "WKProcessGroupInternal.h"

#import "WKContext.h"
#import "WKString.h"
#import "WKStringCF.h"
#import "WKType.h"

@implementation WKProcessGroup {
    WKContextRef _context;
}

- (instancetype)init
{
    return [self initWithInjectedBundleURL:nil];
}

- (instancetype)initWithInjectedBundleURL:(NSURL *)bundleURL
{
    self = [super init];
    if (!self)
        return nil;

    if (bundleURL) {
        WKStringRef path = WKStringCreateWithCFString((__bridge CFStringRef)[bundleURL path]);
        _context = WKContextCreateWithInjectedBundlePath(path);
        WKRelease(path);
    } else
        _context = WKContextCreate();

    return self;
}

- (void)dealloc
{
    if (_context)
        WKRelease(_context);
    [super dealloc];
}

- (WKContextRef)_contextRef
{
    return _context;
}

@end
