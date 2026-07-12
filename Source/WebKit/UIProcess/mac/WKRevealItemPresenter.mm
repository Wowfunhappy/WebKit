// Stubbed for MAVERICKS_BACKPORT
#include "config.h"
#import "WKRevealItemPresenter.h"

#if PLATFORM(MAC) && ENABLE(REVEAL)

// MAVERICKS_BACKPORT: Reveal.framework is unavailable on 10.9; provide a no-op WKRevealItemPresenter so
// WebViewImpl's ENABLE(REVEAL) data-detection code links. The "reveal" hover UI is simply inert on this OS.
@implementation WKRevealItemPresenter

// MAVERICKS_BACKPORT: stubbed initializer — ignores all params and just chains to -[NSObject init].
- (instancetype)initWithWebViewImpl:(const WebKit::WebViewImpl&)webViewImpl item:(RVItem *)item frame:(CGRect)frameInView menuLocation:(CGPoint)menuLocationInView
{
    // MAVERICKS_BACKPORT: no-op body — Reveal.framework is unavailable on 10.9, so the presenter does nothing.
    UNUSED_PARAM(webViewImpl);
    UNUSED_PARAM(item);
    UNUSED_PARAM(frameInView);
    UNUSED_PARAM(menuLocationInView);
    return [super init];
}

- (void)showContextMenu
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    CheckedPtr impl = _impl.get();
    if (!impl)
        return;

    RetainPtr view = impl->view();
    if (!view)
        return;

    RetainPtr menuItems = [_presenter menuItemsForItem:_item.get() documentContext:nil presentingContext:_presentingContext.get() options:nil];
    if (![menuItems count])
        return;

    RetainPtr menu = adoptNS([[NSMenu alloc] initWithTitle:@""]);
    [menu setAutoenablesItems:NO];
    [menu setItemArray:menuItems.get()];

    auto clickLocationInWindow = [view convertPoint:_menuLocationInView toView:nil];
    RetainPtr event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:clickLocationInWindow modifierFlags:0 timestamp:0 windowNumber:view.get().window.windowNumber context:0 eventNumber:0 clickCount:1 pressure:1];
    [NSMenu popUpContextMenu:menu.get() withEvent:event.get() forView:view.get()];

    [self _callDidFinishPresentationIfNeeded];
}

- (void)_callDidFinishPresentationIfNeeded
{
    CheckedPtr impl = _impl.get();
    if (!impl || _isHighlightingItem)
        return;

    impl->didFinishPresentation(self);
}

#pragma mark - RVPresenterHighlightDelegate

- (NSArray<NSValue *> *)revealContext:(RVPresentingContext *)context rectsForItem:(RVItem *)item
{
    return @[ [NSValue valueWithRect:_frameInView] ];
}

- (BOOL)revealContext:(RVPresentingContext *)context shouldUseDefaultHighlightForItem:(RVItem *)item
{
    return self.shouldUseDefaultHighlight;
}

- (void)revealContext:(RVPresentingContext *)context startHighlightingItem:(RVItem *)item
{
    _isHighlightingItem = YES;
}

- (void)revealContext:(RVPresentingContext *)context stopHighlightingItem:(RVItem *)item
{
    _isHighlightingItem = NO;

    [self _callDidFinishPresentationIfNeeded];
MAVERICKS_BACKPORT */
}

@end

#endif // PLATFORM(MAC) && ENABLE(REVEAL)
