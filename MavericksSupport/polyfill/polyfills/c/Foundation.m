// Foundation: entry points and constants modern WebKit references that 10.9's Foundation does not export.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>

// WK_POLYFILL_CONST spells the type ahead of the name ("const TYPE NAME"), so a pointer constant
// needs a typedef for the const to land on the POINTER -- the "NSString * const" shape the SDK
// declares these with, rather than a pointer to const.
typedef NSString *PolyNSStringConst;

// NSHTTPCookie SameSite property key (NSString, 10.13+). WebKit only reads it behind a
// respondsToSelector(@selector(sameSitePolicy)) guard that fails on 10.9, so it is never dereferenced.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSHTTPCookieSameSitePolicy, @"SameSitePolicy");

// NSError userInfo key NSLocalizedFailureErrorKey (NSString, 10.13+). CoreIPCError reads and writes
// it when round-tripping NSErrors over IPC. REAL Foundation value, not the name-string: the key is
// interpreted by -[NSError localizedDescription] on OSes that know it, and both IPC sides must agree.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSLocalizedFailureErrorKey, @"NSLocalizedFailure");

WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSPresentationIntentAttributeName, @"NSPresentationIntent");
// NSURLContentTypeKey (Foundation, 11.0+): the resource key answered with a UTType. 10.9's Foundation
// does not interpret it; the NSURL getResourceValue:forKey:error: polyfill (methods/Foundation.m) recognizes this
// key and answers it from the classic NSURLTypeIdentifierKey.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSURLContentTypeKey, @"NSURLContentTypeKey");
// NSURLQuarantinePropertiesKey (Foundation, 10.10+): the resource key that reads/writes a file's
// LaunchServices quarantine dictionary. 10.9's Foundation does not interpret it; the NSURL
// setResourceValue:forKey:error: polyfill (methods/Foundation.m) recognizes this key and applies it through the
// classic LSSetItemAttribute/kLSItemQuarantineProperties, which is the same mechanism the modern key
// is implemented over -- WKShareSheet.mm's own comment names LSSetItemAttribute as what writing this
// key ends up calling. Declared here for the load-from-0 reason above: WKShareSheet passes it straight
// to -setResourceValue:forKey:error:, so an absent symbol faults on the argument.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSURLQuarantinePropertiesKey, @"NSURLQuarantinePropertiesKey");

// NSProcessInfoPowerStateDidChangeNotification (Foundation, 10.12+): the Low Power Mode change
// notification. A unique name used only to register and match an observer; nothing on 10.9 posts it,
// so the observer never fires. Paired with -[NSProcessInfo isLowPowerModeEnabled] in methods/Foundation.m.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSProcessInfoPowerStateDidChangeNotification, @"NSProcessInfoPowerStateDidChangeNotification");
// NSLanguageIdentifierAttributeName (Foundation, macos(12.0); absent on 10.9) is Foundation's public
// name for the long-standing NSAttributedString/CoreText language attribute. Its runtime value is
// PROVABLY @"NSLanguage": on 10.9, kCTLanguageAttributeName (present, the single CoreText language
// key) reads as "NSLanguage" (verified on-host), and Foundation's constant must resolve to the same
// key to influence CoreText layout. WebKit already uses kCTLanguageAttributeName directly elsewhere.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSLanguageIdentifierAttributeName, @"NSLanguage");

// --- NSHTTPCookie SameSite policy constants (10.15+) ----------------------
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSHTTPCookieSameSiteLax, @"lax");
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSHTTPCookieSameSiteStrict, @"strict");

// --- NSURLSessionTask priority constants (float, macos(10.10)) -----------
// Absent on 10.9's Foundation/CFNetwork. WebKit uses them as plain KVC float
// values (NetworkSessionCocoa/NetworkDataTaskCocoa). The values are the
// documented modern defaults, correct for any caller.
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityDefault, 0.5f);
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityLow, 0.0f);
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityHigh, 1.0f);

// --- NSEdgeInsetsEqual (10.10+) ------------------------------------------
// WebKit has an undefined ref, so the SDK exposes it as an extern function
// (not static inline) — define the real symbol with the SDK signature.
WK_POLYFILL_ABSENT("Foundation", BOOL, NSEdgeInsetsEqual, (NSEdgeInsets a, NSEdgeInsets b))
{
    return a.top == b.top && a.left == b.left
        && a.bottom == b.bottom && a.right == b.right;
}
