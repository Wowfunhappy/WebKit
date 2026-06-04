// Stubbed for macOS 10.9 backport
#include "config.h"
#import "WKRevealItemPresenter.h"

#if PLATFORM(MAC) && ENABLE(REVEAL)

// Reveal.framework is unavailable on 10.9; provide a no-op WKRevealItemPresenter so WebViewImpl's
// ENABLE(REVEAL) data-detection code links. The "reveal" hover UI is simply inert on this OS.
@implementation WKRevealItemPresenter

- (instancetype)initWithWebViewImpl:(const WebKit::WebViewImpl&)webViewImpl item:(RVItem *)item frame:(CGRect)frameInView menuLocation:(CGPoint)menuLocationInView
{
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
