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
#import "_WKInspectorWindowInternal.h"

#if PLATFORM(MAC)

const CGFloat WKInspectorWindowDockButtonMargin = 3; // MAVERICKS_BACKPORT: declared in _WKInspectorWindowInternal.h.

@interface NSWindow (AppKitDetails)
- (NSCursor *)_cursorForResizeDirection:(NSInteger)direction;
- (NSRect)_customTitleFrame;
@end

@implementation _WKInspectorWindow

// MAVERICKS_BACKPORT: the two overrides below keep the native dock controls legible, and run only on
// a window that has them.
- (NSCursor *)_cursorForResizeDirection:(NSInteger)direction
{
    // Don't show a resize cursor for the northeast (top right) direction if the dock button is visible.
    // This matches what happens when the full screen button is visible.
    if (direction == 1 && _dockRightButton && ![_dockRightButton isHidden])
        return nil;
    return [super _cursorForResizeDirection:direction];
}

- (NSRect)_customTitleFrame
{
    // Adjust the title frame if needed to prevent it from intersecting the dock button.
    NSRect titleFrame = [super _customTitleFrame];
    if (!_dockBottomButton)
        return titleFrame;
    NSRect dockButtonFrame = _dockBottomButton.frame;
    if (NSMaxX(titleFrame) > NSMinX(dockButtonFrame) - WKInspectorWindowDockButtonMargin)
        titleFrame.size.width -= (NSMaxX(titleFrame) - NSMinX(dockButtonFrame)) + WKInspectorWindowDockButtonMargin;
    return titleFrame;
}

@end

#endif
