/*
 * Copyright (C) 2004-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: the upstream file uses NSScrollView -contentInsets /
// -automaticallyAdjustsContentInsets / NSEdgeInsets (all 10.10+) and
// -[NSWindow convertPointToScreen:]/convertPointFromScreen: (10.12+). On 10.9
// content insets do not exist (they are always zero) and the point<->screen
// conversions are done via the 10.7+ rect variants. Everything else — most
// importantly platformSetContentsSize(), which sizes the document NSView and
// without which Legacy-WebKit WebViews leave their document view 0x0 and never
// paint — is restored verbatim. This file had been stubbed to two lines, which
// dropped the whole Mac ScrollView platform layer to the polyfill's empty
// return-0 stubs.

#import "config.h"
#import "ScrollView.h"

#if PLATFORM(MAC)

#import "FloatRect.h"
#import "FloatSize.h"
#import "IntRect.h"
#import "Logging.h"
#import "NotImplemented.h"
#import "WebCoreFrameView.h"
#import <wtf/BlockObjCExceptions.h>

@interface NSWindow (WebWindowDetails)
- (BOOL)_needsToResetDragMargins;
- (void)_setNeedsToResetDragMargins:(BOOL)needs;
@end

namespace WebCore {

inline NSScrollView<WebCoreFrameScrollView> *ScrollView::scrollView() const
{
    ASSERT(!platformWidget() || [platformWidget() isKindOfClass:[NSScrollView class]]);
    ASSERT(!platformWidget() || [platformWidget() conformsToProtocol:@protocol(WebCoreFrameScrollView)]);
    return static_cast<NSScrollView<WebCoreFrameScrollView> *>(platformWidget());
}

NSView *ScrollView::documentView() const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    return [protect(scrollView()) documentView];
    END_BLOCK_OBJC_EXCEPTIONS
    return nil;
}

void ScrollView::platformAddChild(Widget* child)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    RetainPtr parentView = documentView();
    RetainPtr childView = child->outerView();
    ASSERT(![parentView isDescendantOf:childView.get()]);

    // Suppress the resetting of drag margins since we know we can't affect them.
    RetainPtr<NSWindow> window = [parentView window];
    BOOL resetDragMargins = [window _needsToResetDragMargins];
    [window _setNeedsToResetDragMargins:NO];
    if ([childView superview] != parentView)
        [parentView addSubview:childView.get()];
    [window _setNeedsToResetDragMargins:resetDragMargins];
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollView::platformRemoveChild(Widget* child)
{
    child->removeFromSuperview();
}

void ScrollView::platformSetScrollbarModes()
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [protect(scrollView()) setScrollingModes:m_horizontalScrollbarMode vertical:m_verticalScrollbarMode andLock:NO];
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollView::platformScrollbarModes(ScrollbarMode& horizontal, ScrollbarMode& vertical) const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [protect(scrollView()) scrollingModes:&horizontal vertical:&vertical];
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollView::platformSetCanBlitOnScroll(bool canBlitOnScroll)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    [[protect(scrollView()) contentView] setCopiesOnScroll:canBlitOnScroll];
ALLOW_DEPRECATED_DECLARATIONS_END
    END_BLOCK_OBJC_EXCEPTIONS
}

bool ScrollView::platformCanBlitOnScroll() const
{
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    return [[protect(scrollView()) contentView] copiesOnScroll];
ALLOW_DEPRECATED_DECLARATIONS_END
}

FloatBoxExtent ScrollView::platformContentInsets() const
{
    // 10.9: NSScrollView content insets (10.10+) are unavailable; they are always zero.
    return { };
}

void ScrollView::platformSetContentInsets(const FloatBoxExtent&)
{
    // 10.9: NSScrollView -contentInsets / -automaticallyAdjustsContentInsets (10.10+) are unavailable.
}

IntRect ScrollView::platformVisibleContentRect(bool includeScrollbars) const
{
    // 10.9: content insets are always zero, so this is just the obscured-area rect.
    return platformVisibleContentRectIncludingObscuredArea(includeScrollbars);
}

IntSize ScrollView::platformVisibleContentSize(bool includeScrollbars) const
{
    return platformVisibleContentRect(includeScrollbars).size();
}

IntRect ScrollView::platformVisibleContentRectIncludingObscuredArea(bool includeScrollbars) const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    RetainPtr scrollView = this->scrollView();
    IntRect visibleContentRectIncludingObscuredArea = enclosingIntRect([scrollView documentVisibleRect]);

    if (includeScrollbars) {
        IntSize frameSize = IntSize([scrollView frame].size);
        visibleContentRectIncludingObscuredArea.setSize(frameSize);
    }

    return visibleContentRectIncludingObscuredArea;
    END_BLOCK_OBJC_EXCEPTIONS

    return IntRect();
}

IntSize ScrollView::platformVisibleContentSizeIncludingObscuredArea(bool includeScrollbars) const
{
    return platformVisibleContentRectIncludingObscuredArea(includeScrollbars).size();
}

IntRect ScrollView::platformUnobscuredContentRect(VisibleContentRectIncludesScrollbars scrollbarInclusion) const
{
    return unobscuredContentRectInternal(scrollbarInclusion);
}

void ScrollView::platformSetContentsSize()
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    int w = m_contentsSize.width();
    int h = m_contentsSize.height();
    LOG(Frames, "%p %@ at w %d h %d\n", documentView(), [(id)[documentView() class] className], w, h);
    [protect(documentView()) setFrameSize:NSMakeSize(std::max(0, w), std::max(0, h))];
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollView::platformSetScrollbarsSuppressed(bool repaintOnUnsuppress)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [protect(scrollView()) setScrollBarsSuppressed:m_scrollbarsSuppressed
                      repaintOnUnsuppress:repaintOnUnsuppress];
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollView::platformSetScrollPosition(const IntPoint& scrollPoint)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    RetainPtr scrollView = this->scrollView();
    NSPoint floatPoint = scrollPoint;
    NSPoint tempPoint = { std::max(-[scrollView scrollOrigin].x, floatPoint.x), std::max(-[scrollView scrollOrigin].y, floatPoint.y) };  // Don't use NSMakePoint to work around 4213314.

    // 10.9: no content insets to factor out of the scroll position.
    [protect(documentView()) scrollPoint:tempPoint];
    END_BLOCK_OBJC_EXCEPTIONS
}

bool ScrollView::platformScroll(ScrollDirection, ScrollGranularity)
{
    // FIXME: It would be nice to implement this so that all of the code in WebFrameView could go away.
    notImplemented();
    return false;
}

void ScrollView::platformRepaintContentRectangle(const IntRect& rect)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    RetainPtr view = documentView();
    [view setNeedsDisplayInRect:rect];

    END_BLOCK_OBJC_EXCEPTIONS
}

// "Containing Window" means the NSWindow's coord system, which is origin lower left

IntRect ScrollView::platformContentsToScreen(const IntRect& rect) const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    if (RetainPtr documentView = this->documentView()) {
        NSRect tempRect = rect;
        tempRect = [documentView convertRect:tempRect toView:nil];
        // 10.9: -[NSWindow convertPointToScreen:] is 10.12+; use the 10.7+ rect variant.
        tempRect.origin = [retainPtr([documentView window]) convertRectToScreen:NSMakeRect(tempRect.origin.x, tempRect.origin.y, 0, 0)].origin;
        return enclosingIntRect(tempRect);
    }
    END_BLOCK_OBJC_EXCEPTIONS
    return IntRect();
}

IntPoint ScrollView::platformScreenToContents(const IntPoint& point) const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    if (RetainPtr documentView = this->documentView()) {
        // 10.9: -[NSWindow convertPointFromScreen:] is 10.12+; use the 10.7+ rect variant.
        NSPoint windowCoord = [retainPtr([documentView window]) convertRectFromScreen:NSMakeRect(point.x(), point.y(), 0, 0)].origin;
        return IntPoint([documentView convertPoint:windowCoord fromView:nil]);
    }
    END_BLOCK_OBJC_EXCEPTIONS
    return IntPoint();
}

bool ScrollView::platformIsOffscreen() const
{
    RetainPtr widget = platformWidget();
    return ![widget window] || ![[widget window] isVisible];
}

static inline NSScrollerKnobStyle NODELETE toNSScrollerKnobStyle(ScrollbarOverlayStyle style)
{
    switch (style) {
    case ScrollbarOverlayStyle::Dark:
        return NSScrollerKnobStyleDark;
    case ScrollbarOverlayStyle::Light:
        return NSScrollerKnobStyleLight;
    default:
        return NSScrollerKnobStyleDefault;
    }
}

void ScrollView::platformSetScrollbarOverlayStyle(ScrollbarOverlayStyle overlayStyle)
{
    [protect(scrollView()) setScrollerKnobStyle:toNSScrollerKnobStyle(overlayStyle)];
}

void ScrollView::platformSetScrollOrigin(const IntPoint& origin, bool updatePositionAtAll, bool updatePositionSynchronously)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [protect(scrollView()) setScrollOrigin:origin updatePositionAtAll:updatePositionAtAll immediately:updatePositionSynchronously];
    END_BLOCK_OBJC_EXCEPTIONS
}

} // namespace WebCore

#endif // PLATFORM(MAC)
