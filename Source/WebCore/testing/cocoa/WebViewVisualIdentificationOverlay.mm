// MAVERICKS_BACKPORT: minimal real implementation so the +class method exists.
#include "config.h"
#import "WebViewVisualIdentificationOverlay.h"

// MAVERICKS_BACKPORT: minimal stub implementation replacing the upstream debug-overlay class (CATiledLayer/CGPattern debug tinting is unneeded on 10.9).
@implementation WebViewVisualIdentificationOverlay

+ (void)installForWebViewIfNeeded:(CocoaView *)view kind:(NSString *)kind deprecated:(BOOL)isDeprecated
{
    // MAVERICKS_BACKPORT: no-op body; arguments intentionally unused on 10.9.
    (void)view;
    (void)kind;
    (void)isDeprecated;
}

@end
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//
// #endif // PLATFORM(COCOA)
// (end MAVERICKS_BACKPORT restored block)
