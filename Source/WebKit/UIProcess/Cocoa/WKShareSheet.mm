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

#import "config.h"
// MAVERICKS_BACKPORT status: minimal implementation. The full WKShareSheet drives an
// NSSharingServicePicker; that exists on 10.9, so the share menu can be restored
// from upstream. For initial bring-up this implementation reports the share as
// declined (completionHandler(false)) so that requesting navigator.share simply
// does nothing rather than crashing. Real ObjC metadata lives in WebKit.framework.

// MAVERICKS_BACKPORT: import the in-tree header directly (no <WebKit/...> umbrella for this minimal stub).
#import "WKShareSheet.h"

#if HAVE(SHARE_SHEET_UI)

#import "PickerDismissalReason.h"
// MAVERICKS_BACKPORT: reduced include set for the minimal stub (no LinkPresentation/UniformTypeIdentifiers/NSSharingServicePicker SPI).
#import <WebCore/FloatRect.h>
#import <WebCore/ShareData.h>
#import <wtf/StdLibExtras.h> // MAVERICKS_BACKPORT: minimal include set for the stub (no LinkPresentation/UTI/NSSharingServicePicker SPI).

@implementation WKShareSheet {
// MAVERICKS_BACKPORT: this file is compiled as manual-reference-counting (it is in the PlatformMac
// explicit source list, not the ARC-tagged unified bundles), so the header's
// `weak` delegate property cannot be @synthesize'd. Back it with an explicitly
// unretained ivar and manual accessors — valid under both MRR and ARC. The
// delegate (the WKWebView) outlives this transient share sheet.
    __unsafe_unretained id<WKShareSheetDelegate> _delegate; // MAVERICKS_BACKPORT: unretained ivar backs the header's weak delegate under MRR (see above).
}

- (id<WKShareSheetDelegate>)delegate
{
// MAVERICKS_BACKPORT: manual delegate getter backing the unretained ivar (see above).
    return _delegate;
}

- (void)setDelegate:(id<WKShareSheetDelegate>)delegate
{
    _delegate = delegate;
}

- (instancetype)initWithView:(WKWebView *)view
{
// MAVERICKS_BACKPORT: minimal share-sheet stub holds no web-view reference (nothing is presented).
    self = [super init];
    if (!self)
        return nil;
    UNUSED_PARAM(view); // MAVERICKS_BACKPORT: stub keeps no web-view reference (nothing is presented).
    return self;
}

// MAVERICKS_BACKPORT: minimal share-sheet stub — report the share as declined (completionHandler(false))
// and immediately notify the delegate of dismissal so navigator.share() resolves without crashing.
- (void)presentWithParameters:(const WebCore::ShareDataWithParsedURL&)data inRect:(std::optional<WebCore::FloatRect>)rect completionHandler:(WTF::CompletionHandler<void(bool)>&&)completionHandler
{
    UNUSED_PARAM(data); // MAVERICKS_BACKPORT: stub reports the share declined; see marker above.
    UNUSED_PARAM(rect);
    completionHandler(false);
    if ([_delegate respondsToSelector:@selector(shareSheetDidDismiss:)])
        [_delegate shareSheetDidDismiss:self];
}

- (BOOL)dismissIfNeededWithReason:(WebKit::PickerDismissalReason)reason
{
// MAVERICKS_BACKPORT: minimal share-sheet stub — nothing presented, so there is nothing to dismiss.
    UNUSED_PARAM(reason);
    return NO;
}

@end

#endif // HAVE(SHARE_SHEET_UI)
