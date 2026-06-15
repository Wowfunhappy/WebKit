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

// 10.9 backport: this legacy WebKit2 Objective-C SPI class was reduced to a
// stub upstream. It is restored here because Apple's QuickLook HTML preview
// display bundle (Web2.qldisplay -> QLWeb2DisplayBundle) instantiates it to
// host a WKView. Without it, dlopen of Web2.qldisplay fails on the missing
// _OBJC_CLASS_$_WKProcessGroup and HTML files fall back to a generic icon.

#import <WebKit/WKFoundation.h>

#if !TARGET_OS_IPHONE

#import <Cocoa/Cocoa.h>

@class WKProcessGroup;

@protocol WKProcessGroupDelegate <NSObject>
@end

// visibility("default") so _OBJC_CLASS_$_WKProcessGroup is exported from WebKit2
// (the build defaults to hidden visibility; cf. WK_CLASS_DEPRECATED_WITH_REPLACEMENT).
__attribute__((visibility("default")))
@interface WKProcessGroup : NSObject

- (instancetype)init;
- (instancetype)initWithInjectedBundleURL:(NSURL *)bundleURL;

@property (weak) id <WKProcessGroupDelegate> delegate;

@end

#endif // !TARGET_OS_IPHONE
