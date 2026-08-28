// DataDetectors: Objective-C methods on DataDetectors classes that macOS 10.9 does not have. The class
// is private and not linked, so the block names it by string.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// DDActionsManager (DataDetectors.framework — the framework IS present on 10.9, so WebKit's
// PAL::isDataDetectorsFrameworkAvailable() guards pass) grew its modern action-flow methods after 10.9;
// each absent one is an unrecognized-selector throw when reached. The class is soft-linked and private,
// so the block names it by string and installs when it loads.
//
// -requestBubbleClosureUnanchorOnFailure: is sent UNGUARDED from both view stacks' dismissal paths
// (WebViewImpl::dismissContentRelativeChildWindowsFromViewOnly — fires on every main-frame commit in a
// WKWebView-backed view, reproduced killing a WKWebView host on load — and WK1's
// WebImmediateActionController _clearImmediateActionState). Upstream history of this call site
// (bug 138600, stale-anchored popovers): its first form sent plain -unanchorBubbles ("we'll settle
// for unanchoring", 402d006), was switched the same day to -requestBubbleClosureUnanchorOnFailure:
// when that SPI appeared, and later grew a respondsToSelector: guard for older OSes that upstream has
// since dropped. 10.9 has the two halves as separate primitives, -requestBubbleClosure and
// -unanchorBubbles, but no closure-failure signal to sequence them with — so honor the parameter the
// conservative way: request closure, and when the caller asked for unanchor-on-failure also unanchor,
// which is exactly the outcome the call site's original form settled for.
//
// +didUseActions / +shouldUseActionsWithContext: / -hasActionsForResult:actionContext: sit on the
// immediate-action flows, dormant on 10.9 (NSImmediateActionGestureRecognizer resolves to nil) but
// unguarded where they are sent. 10.9's classic flow had no use-notification and no should-use gate —
// actions always proceeded — so the notification is a no-op and the gate answers YES.
// -hasActionsForResult:actionContext: answers via the classic -actionsForResult:.
@interface DDActionsManager : NSObject
- (void)requestBubbleClosure;
- (void)unanchorBubbles;
- (NSArray *)actionsForResult:(id)result;
@end

WK_POLYFILL_ADD_METHODS_ON(NSObject, "DDActionsManager")
- (void)requestBubbleClosureUnanchorOnFailure:(BOOL)unanchorOnFailure
{
    DDActionsManager *manager = (DDActionsManager *)self;
    [manager requestBubbleClosure];
    if (unanchorOnFailure)
        [manager unanchorBubbles];
}
+ (void)didUseActions
{
}
+ (BOOL)shouldUseActionsWithContext:(id)context
{
    (void)context;
    return YES;
}
- (BOOL)hasActionsForResult:(id)result actionContext:(id)actionContext
{
    (void)actionContext;
    return [[(DDActionsManager *)self actionsForResult:result] count] > 0;
}
@end

#pragma clang diagnostic pop
