// DataDetectors: Objective-C methods on DataDetectors classes that macOS 10.9 does not have. The class
// is private and not linked, so the methods are installed by name with WK_POLYFILL_ADD.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// DDActionsManager (DataDetectors.framework — the framework IS present on 10.9, so WebKit's
// PAL::isDataDetectorsFrameworkAvailable() guards pass) grew its modern action-flow methods after 10.9;
// each absent one is an unrecognized-selector throw when reached. The class is soft-linked and private,
// so these install by name at runtime (WK_POLYFILL_ADD family).
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
static void wk_ddRequestBubbleClosureUnanchorOnFailure(id self, SEL _cmd, BOOL unanchorOnFailure)
{
    (void)_cmd;
    ((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("requestBubbleClosure"));
    if (unanchorOnFailure)
        ((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("unanchorBubbles"));
}
static void wk_ddDidUseActions(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
}
static BOOL wk_ddShouldUseActionsWithContext(id self, SEL _cmd, id context)
{
    (void)self;
    (void)_cmd;
    (void)context;
    return YES;
}
static BOOL wk_ddHasActionsForResultActionContext(id self, SEL _cmd, id result, id actionContext)
{
    (void)_cmd;
    (void)actionContext;
    NSArray *actions = ((id (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("actionsForResult:"), result);
    return [actions count] > 0;
}
WK_POLYFILL_ADD("DDActionsManager", "wk_requestBubbleClosureUnanchorOnFailure:", wk_ddRequestBubbleClosureUnanchorOnFailure, "v@:c");
WK_POLYFILL_SEL("requestBubbleClosureUnanchorOnFailure:", "wk_requestBubbleClosureUnanchorOnFailure:");
WK_POLYFILL_ADD_CLASS_METHOD("DDActionsManager", "wk_didUseActions", wk_ddDidUseActions, "v@:");
WK_POLYFILL_SEL("didUseActions", "wk_didUseActions");
WK_POLYFILL_ADD_CLASS_METHOD("DDActionsManager", "wk_shouldUseActionsWithContext:", wk_ddShouldUseActionsWithContext, "c@:@");
WK_POLYFILL_SEL("shouldUseActionsWithContext:", "wk_shouldUseActionsWithContext:");
WK_POLYFILL_ADD("DDActionsManager", "wk_hasActionsForResult:actionContext:", wk_ddHasActionsForResultActionContext, "c@:@@");
WK_POLYFILL_SEL("hasActionsForResult:actionContext:", "wk_hasActionsForResult:actionContext:");

#pragma clang diagnostic pop
