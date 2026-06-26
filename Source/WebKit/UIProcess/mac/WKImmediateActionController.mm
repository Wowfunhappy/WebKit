/*
 * Copyright (C) 2014 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT status: minimal implementation. NSImmediateActionGestureRecognizer
// (force-touch) is a 10.10+ trackpad feature that does not exist on 10.9 hardware,
// so this controller is inert here: it owns its members and answers queries safely
// but performs no force-touch UI. The class keeps real ObjC metadata in
// WebKit.framework so WebViewImpl links and runs. Full force-touch behavior can be
// restored from upstream if a 10.10+ host ever runs these frameworks.

#import "config.h"
#import "WKImmediateActionController.h"

#if PLATFORM(MAC)

#import "APIObject.h"
#import "WebPageProxy.h"
#import "WebViewImpl.h"

@implementation WKImmediateActionController

- (instancetype)initWithPage:(std::reference_wrapper<WebKit::WebPageProxy>)page view:(NSView *)view viewImpl:(std::reference_wrapper<WebKit::WebViewImpl>)viewImpl recognizer:(NSImmediateActionGestureRecognizer *)immediateActionRecognizer
{
    self = [super init];
    if (!self)
        return nil;

    _page = page.get();
    _view = view;
    _viewImpl = viewImpl.get();
    _state = WebKit::ImmediateActionState::None;
    _immediateActionRecognizer = immediateActionRecognizer;
    _hasActiveImmediateAction = NO;

    return self;
}

- (void)willDestroyView:(NSView *)view
{
    UNUSED_PARAM(view);
    _page = nullptr;
    _viewImpl = nullptr;
    _view = nil;
    _immediateActionRecognizer = nil;
}

- (void)didPerformImmediateActionHitTest:(const WebKit::WebHitTestResultData&)hitTestResult contentPreventsDefault:(BOOL)contentPreventsDefault userData:(API::Object*)userData
{
    _hitTestResultData = hitTestResult;
    _contentPreventsDefault = contentPreventsDefault;
    _userData = userData;
}

- (void)dismissContentRelativeChildWindows
{
}

- (BOOL)hasActiveImmediateAction
{
    return _hasActiveImmediateAction;
}

@end

#endif // PLATFORM(MAC)
