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
}

@end

#endif // PLATFORM(MAC) && ENABLE(REVEAL)
