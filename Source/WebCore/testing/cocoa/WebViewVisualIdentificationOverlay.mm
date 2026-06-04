// 10.9 backport: minimal real implementation so the +class method exists.
#include "config.h"
#import "WebViewVisualIdentificationOverlay.h"

@implementation WebViewVisualIdentificationOverlay

+ (void)installForWebViewIfNeeded:(CocoaView *)view kind:(NSString *)kind deprecated:(BOOL)isDeprecated
{
    (void)view;
    (void)kind;
    (void)isDeprecated;
}

@end
