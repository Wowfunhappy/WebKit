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

// MAVERICKS_BACKPORT: the NSScrollView -contentInsets forward-declaration is dropped — content insets are
// 10.10+ and the platform code below never calls them on 10.9.
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
    // MAVERICKS_BACKPORT: NSScrollView content insets (10.10+) are unavailable on 10.9; they are always zero.
    return { };
}

// MAVERICKS_BACKPORT: NSScrollView -contentInsets / -automaticallyAdjustsContentInsets (10.10+) are unavailable on 10.9; the parameter is unused.
void ScrollView::platformSetContentInsets(const FloatBoxExtent&)
{
    // MAVERICKS_BACKPORT: NSScrollView -contentInsets / -automaticallyAdjustsContentInsets (10.10+) are unavailable on 10.9.
}

IntRect ScrollView::platformVisibleContentRect(bool includeScrollbars) const
{
    // MAVERICKS_BACKPORT: content insets (10.10+) are always zero on 10.9, so this is just the obscured-area rect.
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

    // MAVERICKS_BACKPORT: no content insets (10.10+) to factor out of the scroll position on 10.9.
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
        tempRect.origin = [retainPtr([documentView window]) convertPointToScreen:tempRect.origin];
        return enclosingIntRect(tempRect);
    }
    END_BLOCK_OBJC_EXCEPTIONS
    return IntRect();
}

IntPoint ScrollView::platformScreenToContents(const IntPoint& point) const
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    if (RetainPtr documentView = this->documentView()) {
        NSPoint windowCoord = [retainPtr([documentView window]) convertPointFromScreen: point];
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
