/*
 * Copyright (C) 2018 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT status: minimal implementation. The full WKShareSheet drives an
// NSSharingServicePicker; that exists on 10.9, so the share menu can be restored
// from upstream. For initial bring-up this implementation reports the share as
// declined (completionHandler(false)) so that requesting navigator.share simply
// does nothing rather than crashing. Real ObjC metadata lives in WebKit.framework.

#import "config.h"
#import "WKShareSheet.h"

#if HAVE(SHARE_SHEET_UI)

#import "PickerDismissalReason.h"
#import <WebCore/FloatRect.h>
#import <WebCore/ShareData.h>
#import <wtf/StdLibExtras.h>

// This file is compiled as manual-reference-counting (it is in the PlatformMac
// explicit source list, not the ARC-tagged unified bundles), so the header's
// `weak` delegate property cannot be @synthesize'd. Back it with an explicitly
// unretained ivar and manual accessors — valid under both MRR and ARC. The
// delegate (the WKWebView) outlives this transient share sheet.
@implementation WKShareSheet {
    __unsafe_unretained id<WKShareSheetDelegate> _delegate;
}

- (id<WKShareSheetDelegate>)delegate
{
    return _delegate;
}

- (void)setDelegate:(id<WKShareSheetDelegate>)delegate
{
    _delegate = delegate;
}

- (instancetype)initWithView:(WKWebView *)view
{
    self = [super init];
    if (!self)
        return nil;
    UNUSED_PARAM(view);
    return self;
}

- (void)presentWithParameters:(const WebCore::ShareDataWithParsedURL&)data inRect:(std::optional<WebCore::FloatRect>)rect completionHandler:(WTF::CompletionHandler<void(bool)>&&)completionHandler
{
    UNUSED_PARAM(data);
    UNUSED_PARAM(rect);
    completionHandler(false);
    if ([_delegate respondsToSelector:@selector(shareSheetDidDismiss:)])
        [_delegate shareSheetDidDismiss:self];
}

- (BOOL)dismissIfNeededWithReason:(WebKit::PickerDismissalReason)reason
{
    UNUSED_PARAM(reason);
    return NO;
}

@end

#endif // HAVE(SHARE_SHEET_UI)
