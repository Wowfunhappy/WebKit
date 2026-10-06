// WK_ORIGINAL_METHOD from a REPLACE body reached through a WebKit-image override that calls super —
// the WebCoreFullScreenWindow / WKDataListSuggestionWindow shape.
//
// This image carries __wk_marker, so its [super ping] is a rewritten wk_ping super-send, and
// wk_alias_class gives the override its own wk_ping entry point (the WebKit-image exception). The
// body's call-through must then walk past that aliased override to find itself, and stand in for
// what super means there: the system implementation.
#include "wk_selref_scope.h"
#import "wk_selref_replace_super_fixture.h"
#import <Foundation/Foundation.h>
#include <stdio.h>

__attribute__((used, section("__DATA,__wk_marker"))) static const char wk_marker[] = "WebKitPolyfillScope";

@interface WKReplaceProbeOverride : WKReplaceProbeSystem @end
@implementation WKReplaceProbeOverride
- (int)ping { return [super ping] + 10; }
@end

@interface WKReplaceProbePlain : WKReplaceProbeSystem @end
@implementation WKReplaceProbePlain @end

WK_POLYFILL_REPLACE_METHODS(WKReplaceProbeSystem)
- (int)ping { return WK_ORIGINAL_METHOD(int, ()) + 100; }
@end

static int wk_failures;
static void check(int got, int expect, const char *what)
{
    printf("  %-58s %s (%d)\n", what, got == expect ? "ok" : "FAIL", got);
    if (got != expect)
        wk_failures++;
}

int main(void)
{
    printf("wk_selref_replace_super: WK_ORIGINAL_METHOD through an aliased WebKit-image override\n");
    check([[[[WKReplaceProbeSystem alloc] init] autorelease] ping], 101, "target class: body + system");
    check([[[[WKReplaceProbePlain alloc] init] autorelease] ping], 101, "inheriting subclass: body + system");
    check([[[[WKReplaceProbeOverride alloc] init] autorelease] ping], 111, "overriding subclass: override + body + system");
    if (wk_failures) {
        printf("wk_selref_replace_super: %d FAILURE(S)\n", wk_failures);
        return 1;
    }
    printf("wk_selref_replace_super: all checks passed\n");
    return 0;
}
