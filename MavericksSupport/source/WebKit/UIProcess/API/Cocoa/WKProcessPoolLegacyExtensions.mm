#import "config.h"

#import "LegacyExtensionHost.h"
#import "WKProcessPoolInternal.h"
#import "WebProcessPool.h"

// The pool's pages created from here on act as Safari tabs to the Safari 7 extensions Safari runs: they get
// the extensions' content scripts and style sheets, and their messages, events and web requests reach the
// extensions' pages in Safari while Safari runs.
@interface WKProcessPool (WKLegacyExtensions)
- (void)_enableSafariExtensions;
@end

@implementation WKProcessPool (WKLegacyExtensions)

- (void)_enableSafariExtensions
{
    WebKit::LegacyExtensionHost::singleton().setUsesSafariExtensions(*_processPool);
}

@end
