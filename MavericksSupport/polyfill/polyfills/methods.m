// methods.m — Objective-C methods on system classes that macOS 10.9 does not have (or gets wrong),
// implemented with the APIs 10.9 does have.
//
// To add one: implement the method as a category on the real system class under a `wk_`-prefixed name,
// then register it with WK_POLYFILL_SEL("<name>", "wk_<name>"). WebKit's call sites keep saying
// `[obj <name>]` and get the polyfill. That is the whole recipe.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real API that still exists and adapts) over a frozen
// literal. Hardcoded sRGB is used only for the system tint palette (systemBlue…systemYellow) and the
// fill hierarchy, which have no 10.9 equivalent — those constants are Apple's documented values. A
// polyfill's contract is the system API's modern behavior, so it is correct at every caller.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <errno.h>
#import <limits.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <mach/mach.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>
#import <pthread.h>

// CFNetwork SPI, exported on 10.9 but not declared in any public header.
typedef struct OpaqueCFHTTPCookieStorage *CFHTTPCookieStorageRef;
// TWO parameters, read off the 10.9 disassembly: the second is an existing storage to seed the new one
// from (NULL for an empty jar), passed straight through to
// HTTPCookieStorage::initialize(PrivateHTTPCookieStorage*, int, OpaqueCFHTTPCookieStorage*). Declaring it
// with one parameter left %rsi holding whatever the caller happened to leave there and initialize
// dereferenced it -- SIGSEGV in objc_msgSend on every task that blocks cookies.
extern CFHTTPCookieStorageRef _CFHTTPCookieStorageCreateInMemory(CFAllocatorRef, CFHTTPCookieStorageRef);
#import <unistd.h>

#define SRGB(r, g, b, a) [NSColor colorWithSRGBRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)/255.0]

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// NSGraphicsContext CGContext accessors (10.10+) via the classic 10.9 graphics-port SPI. -CGContext and
// +graphicsContextWithCGContext:flipped: are the 10.10 renames of -graphicsPort and
// +graphicsContextWithGraphicsPort:flipped:.
@interface NSGraphicsContext (WKPolyfillScope)
- (CGContextRef)wk_CGContext;
+ (NSGraphicsContext *)wk_graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped;
@end
@implementation NSGraphicsContext (WKPolyfillScope)
- (CGContextRef)wk_CGContext { return (CGContextRef)[self graphicsPort]; }
+ (NSGraphicsContext *)wk_graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped
{
    return [NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:flipped];
}
@end
WK_POLYFILL_SEL("CGContext", "wk_CGContext");
WK_POLYFILL_SEL("graphicsContextWithCGContext:flipped:", "wk_graphicsContextWithCGContext:flipped:");

// ---------------------------------------------------------------------------------------------------
// -[NSButtonCell _setState:animated:] / _setHighlighted:animated: (10.10+) animate the transition; the
// plain -setState: / -setHighlighted: 10.9 already has make it instantly. Every call site passes
// animated:NO, so the instant form is exactly what they ask for.
@interface NSButtonCell (WKPolyfillScope)
- (void)wk__setState:(NSInteger)state animated:(BOOL)animated;
- (void)wk__setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
@end
@implementation NSButtonCell (WKPolyfillScope)
- (void)wk__setState:(NSInteger)state animated:(BOOL)animated { (void)animated; [self setState:state]; }
- (void)wk__setHighlighted:(BOOL)highlighted animated:(BOOL)animated { (void)animated; [self setHighlighted:highlighted]; }
@end
WK_POLYFILL_SEL("_setState:animated:", "wk__setState:animated:");
WK_POLYFILL_SEL("_setHighlighted:animated:", "wk__setHighlighted:animated:");

// ---------------------------------------------------------------------------------------------------
// -[NSError underlyingErrors] (10.14+) is the array-valued successor to the single NSUnderlyingErrorKey
// that 10.9's NSError already carries, so return that one error when the userInfo has it and an empty
// array otherwise — the same shape callers iterate, carrying the real underlying error 10.9 records.
@interface NSError (WKPolyfillScope)
- (NSArray<NSError *> *)wk_underlyingErrors;
@end
@implementation NSError (WKPolyfillScope)
- (NSArray<NSError *> *)wk_underlyingErrors
{
    NSError *underlying = [[self userInfo] objectForKey:NSUnderlyingErrorKey];
    return [underlying isKindOfClass:[NSError class]] ? @[underlying] : @[];
}
@end
WK_POLYFILL_SEL("underlyingErrors", "wk_underlyingErrors");

// ---------------------------------------------------------------------------------------------------
// -[NSProcessInfo isLowPowerModeEnabled] (10.12+). Low Power Mode is a battery-saver state 10.9 has no
// concept of, so the honest answer on this OS is not-enabled. NSProcessInfoPowerStateDidChangeNotification
// (constants.m) is the paired notification; nothing on 10.9 posts it, so an observer of it simply never
// fires.
@interface NSProcessInfo (WKPolyfillScope)
- (BOOL)wk_isLowPowerModeEnabled;
@end
@implementation NSProcessInfo (WKPolyfillScope)
- (BOOL)wk_isLowPowerModeEnabled { return NO; }
@end
WK_POLYFILL_SEL("isLowPowerModeEnabled", "wk_isLowPowerModeEnabled");

// ---------------------------------------------------------------------------------------------------
// Private NSHTTPCookieStorage / NSHTTPCookie cookie SPI (10.10+) that WebCore's NetworkStorageSession
// (Source/WebCore/platform/network/cocoa/NetworkStorageSessionCocoa.mm) uses for the modern
// partition-/SameSite-aware cookie jar. None of these selectors exist on 10.9, so the NetworkProcess
// aborted with an "unrecognized selector" NSInvalidArgumentException the moment a page read or wrote a
// cookie or subscribed to cookie changes. 10.9 has no cookie partitioning, and on this build cookie
// partitioning is off in every sense (NetworkStorageSession::m_isOptInCookiePartitioningEnabled is
// false and CFN_COOKIE_ACCEPTS_POLICY_PARTITION is undefined, so the _getCookiesForPartition: path is
// compiled out), which means the partition/policyProperties arguments carry no information here. Each
// modern selector therefore reduces to the classic 10.9 public API — exactly the mapping the previous
// in-tree minimal rewrite of this file used before it was folded back to upstream.

// -[NSHTTPCookieStorage _getCookiesForURL:…completionHandler:] is the async-shaped successor to
// -cookiesForURL:; it invokes the handler synchronously (the caller RELEASE_ASSERTs this). With a nil
// partition, -cookiesForURL: is the whole answer.
// _setCookies:forURL:mainDocumentURL:policyProperties: is -setCookies:forURL:mainDocumentURL: plus a
// policy dictionary 10.9 cannot honour. _getCookiesForDomain: returns every unpartitioned cookie whose
// domain attribute domain-matches the host (RFC 6265). _saveCookies: is polyfilled further down, over 10.9's
// PRESENT argument-less -_saveCookies.
// _setCookiesChangedHandler:/_setCookiesRemovedHandler:/_setSubscribedDomainsForCookieChanges: are the
// HAVE(COOKIE_CHANGE_LISTENER_API) observer hooks (CookieStore API / document.cookie change events);
// 10.9 has no cookie-change machinery, so registering them as no-ops lets the observer path run and
// simply never fire — the same graceful degradation the isLowPowerModeEnabled pair above uses.
@interface NSHTTPCookieStorage (WKPolyfillScope)
- (void)wk__getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)policyProperties completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler;
- (void)wk__setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL policyProperties:(NSDictionary *)policyProperties;
- (NSArray<NSHTTPCookie *> *)wk__getCookiesForDomain:(NSString *)domain;
- (void)wk__setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *addedCookies, NSString *domainForChangedCookie))handler onQueue:(dispatch_queue_t)queue;
- (void)wk__setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *removedCookies, NSString *domainForRemovedCookies, BOOL removeAllCookies))handler onQueue:(dispatch_queue_t)queue;
- (void)wk__setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains;
@end
@implementation NSHTTPCookieStorage (WKPolyfillScope)
- (void)wk__getCookiesForURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL partition:(NSString *)partition policyProperties:(NSDictionary *)policyProperties completionHandler:(void (^)(NSArray<NSHTTPCookie *> *))completionHandler
{
    (void)mainDocumentURL; (void)partition; (void)policyProperties;
    completionHandler([self cookiesForURL:url]);
}
- (void)wk__setCookies:(NSArray<NSHTTPCookie *> *)cookies forURL:(NSURL *)url mainDocumentURL:(NSURL *)mainDocumentURL policyProperties:(NSDictionary *)policyProperties
{
    (void)policyProperties;
    [self setCookies:cookies forURL:url mainDocumentURL:mainDocumentURL];
}
- (NSArray<NSHTTPCookie *> *)wk__getCookiesForDomain:(NSString *)domain
{
    NSMutableArray<NSHTTPCookie *> *result = [NSMutableArray array];
    for (NSHTTPCookie *cookie in [self cookies]) {
        NSString *cookieDomain = cookie.domain;
        if (!cookieDomain.length)
            continue;
        if ([cookieDomain hasPrefix:@"."])
            cookieDomain = [cookieDomain substringFromIndex:1];
        if ([domain isEqualToString:cookieDomain] || [domain hasSuffix:[@"." stringByAppendingString:cookieDomain]])
            [result addObject:cookie];
    }
    return result;
}
- (void)wk__setCookiesChangedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *))handler onQueue:(dispatch_queue_t)queue { (void)handler; (void)queue; }
- (void)wk__setCookiesRemovedHandler:(void (^)(NSArray<NSHTTPCookie *> *, NSString *, BOOL))handler onQueue:(dispatch_queue_t)queue { (void)handler; (void)queue; }
- (void)wk__setSubscribedDomainsForCookieChanges:(NSSet<NSString *> *)domains { (void)domains; }
@end
WK_POLYFILL_SEL("_getCookiesForURL:mainDocumentURL:partition:policyProperties:completionHandler:", "wk__getCookiesForURL:mainDocumentURL:partition:policyProperties:completionHandler:");
WK_POLYFILL_SEL("_setCookies:forURL:mainDocumentURL:policyProperties:", "wk__setCookies:forURL:mainDocumentURL:policyProperties:");
WK_POLYFILL_SEL("_getCookiesForDomain:", "wk__getCookiesForDomain:");
WK_POLYFILL_SEL("_setCookiesChangedHandler:onQueue:", "wk__setCookiesChangedHandler:onQueue:");
WK_POLYFILL_SEL("_setCookiesRemovedHandler:onQueue:", "wk__setCookiesRemovedHandler:onQueue:");
WK_POLYFILL_SEL("_setSubscribedDomainsForCookieChanges:", "wk__setSubscribedDomainsForCookieChanges:");

// -[NSHTTPCookie _storagePartition] is the per-cookie partition key; 10.9 stores everything
// unpartitioned, so nil (the "no partition" value the callers already treat as the default) is honest.
// +[NSHTTPCookie _cookieForSetCookieString:forURL:partition:] parses a single Set-Cookie header field
// into a cookie — -cookiesWithResponseHeaderFields:forURL: is 10.9's parser for exactly that.
// -[NSHTTPCookie sameSitePolicy] (10.13+) reports a cookie's stored SameSite attribute (paired with the
// NSHTTPCookieSameSiteLax/Strict constants polyfilled in constants.m). 10.9's cookie store keeps no
// SameSite attribute, so nil ("None"/unspecified, which coreSameSitePolicy maps to SameSitePolicy::None)
// is the honest answer — WebCore's own SameSite enforcement lives above the platform cookie jar.
@interface NSHTTPCookie (WKPolyfillScope)
- (NSString *)wk_sameSitePolicy;
- (NSString *)wk__storagePartition;
+ (NSHTTPCookie *)wk__cookieForSetCookieString:(NSString *)setCookieString forURL:(NSURL *)url partition:(NSString *)partition;
@end
@implementation NSHTTPCookie (WKPolyfillScope)
- (NSString *)wk_sameSitePolicy { return nil; }
- (NSString *)wk__storagePartition { return nil; }
+ (NSHTTPCookie *)wk__cookieForSetCookieString:(NSString *)setCookieString forURL:(NSURL *)url partition:(NSString *)partition
{
    (void)partition;
    if (!setCookieString.length || !url)
        return nil;
    return [[NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": setCookieString } forURL:url] firstObject];
}
@end
WK_POLYFILL_SEL("sameSitePolicy", "wk_sameSitePolicy");
WK_POLYFILL_SEL("_storagePartition", "wk__storagePartition");
WK_POLYFILL_SEL("_cookieForSetCookieString:forURL:partition:", "wk__cookieForSetCookieString:forURL:partition:");

// ---------------------------------------------------------------------------------------------------
// -[NSURLConnection _timingData] is a newer CFNetwork/Foundation SPI absent on 10.9 (verified: 10.9's
// NSURLConnection does not respond to it). WebCore's synchronous WebKitLegacy loader reads it in two
// upstream places — copyTimingData() in NetworkLoadMetrics.mm (didReceiveResponse:) and
// connectionDidFinishLoading: — to populate NetworkLoadMetrics (Resource Timing / Inspector network
// timings). Unguarded it throws an unrecognized-selector NSInvalidArgumentException → std::terminate,
// which aborts the whole app; this is what crashes Messages on launch as it loads its iMessage
// transcript over WK1. 10.9's NSURLConnection collects no such timing dictionary, so nil is the honest
// answer: every _kCFNTimingData* key then resolves to nil and the metrics stay empty (best-effort, the
// same result the classic 10.9 loader gave). Polyfilling it keeps both WebCore call sites byte-identical
// to upstream.
@interface NSURLConnection (WKPolyfillScope)
- (NSDictionary *)wk__timingData;
@end
@implementation NSURLConnection (WKPolyfillScope)
- (NSDictionary *)wk__timingData { return nil; }
@end
WK_POLYFILL_SEL("_timingData", "wk__timingData");

// ---------------------------------------------------------------------------------------------------
// -[NSControl setMaximumNumberOfLines:] (10.11+) and -[NSView sizeThatFits:] (10.10+). maximumNumberOfLines
// caps how many wrapped lines a label lays out; sizeThatFits: measures the label at a target width.
// 10.9's -sizeToFit already does the wrapped measurement, so sizeThatFits: reuses it (saving and
// restoring the frame so the measure has no side effect) and then clamps the height to the stored
// line cap. maximumNumberOfLines stores the cap on the control; 0 (the default) means no cap.
static const char kWKMaxLinesKey;
@interface NSControl (WKPolyfillScope)
- (void)wk_setMaximumNumberOfLines:(NSInteger)maximumNumberOfLines;
- (NSSize)wk_sizeThatFits:(NSSize)size;
@end
@implementation NSControl (WKPolyfillScope)
- (void)wk_setMaximumNumberOfLines:(NSInteger)maximumNumberOfLines
{
    objc_setAssociatedObject(self, &kWKMaxLinesKey, @(maximumNumberOfLines), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSSize)wk_sizeThatFits:(NSSize)size
{
    NSRect saved = [self frame];
    [self setFrameSize:NSMakeSize(size.width, size.height)];
    [self sizeToFit];
    NSSize fit = [self frame].size;
    [self setFrame:saved];

    NSInteger maxLines = [objc_getAssociatedObject(self, &kWKMaxLinesKey) integerValue];
    if (maxLines > 0) {
        NSFont *font = [self respondsToSelector:@selector(font)] ? [(id)self font] : nil;
        if (font) {
            NSLayoutManager *lm = [[NSLayoutManager alloc] init];
            CGFloat cap = maxLines * [lm defaultLineHeightForFont:font];
            if (fit.height > cap)
                fit.height = cap;
        }
    }
    return fit;
}
@end
WK_POLYFILL_SEL("setMaximumNumberOfLines:", "wk_setMaximumNumberOfLines:");
WK_POLYFILL_SEL("sizeThatFits:", "wk_sizeThatFits:");

// ---------------------------------------------------------------------------------------------------
// -[CALayerHost setPreservesFlip:] (10.10+). It controls whether a hosted remote layer tree inherits
// the hosting tree's ambient geometry flip. 10.9's CALayerHost has no such method — a direct send
// throws unrecognized-selector — and 10.9's compositor has no host-flip-flag concept, so accept the
// value and leave the host as its default (unflipped) self. Every TiledCoreAnimation host passes NO,
// which is that default; the RemoteLayerTreeHost custom/AVPlayerLayer path can pass YES, which this OS
// cannot honor.
@interface CALayerHost : CALayer
- (void)wk_setPreservesFlip:(BOOL)preservesFlip;
@end
@implementation CALayerHost (WKPolyfillScope)
- (void)wk_setPreservesFlip:(BOOL)preservesFlip { (void)preservesFlip; }
@end
WK_POLYFILL_SEL("setPreservesFlip:", "wk_setPreservesFlip:");

// ---------------------------------------------------------------------------------------------------
// -[NSSearchFieldCell setCenteredLook:] (10.10+). The centered look is the Yosemite rounded search
// field; 10.9's search field cell is the earlier bezeled style, which is the look setCenteredLook:NO
// selects. WebKit only ever passes NO, so this reaches 10.9's state without doing anything.
@interface NSSearchFieldCell (WKPolyfillScope)
- (void)wk_setCenteredLook:(BOOL)centeredLook;
@end
@implementation NSSearchFieldCell (WKPolyfillScope)
- (void)wk_setCenteredLook:(BOOL)centeredLook { (void)centeredLook; }
@end
WK_POLYFILL_SEL("setCenteredLook:", "wk_setCenteredLook:");

// ---------------------------------------------------------------------------------------------------
// NSColor semantic + system palette (10.10+/10.14+). Semantic names map to the 10.9 control-text /
// selection semantics (a real color that still adapts); the systemXxx tint palette and systemFill
// hierarchy have no 10.9 equivalent, so use Apple's documented sRGB constants.
@interface NSColor (WKPolyfillScope)
+ (NSColor *)wk_labelColor; + (NSColor *)wk_secondaryLabelColor; + (NSColor *)wk_tertiaryLabelColor;
+ (NSColor *)wk_quaternaryLabelColor; + (NSColor *)wk_quinaryLabelColor; + (NSColor *)wk_placeholderTextColor;
+ (NSColor *)wk_selectedContentBackgroundColor; + (NSColor *)wk_unemphasizedSelectedTextColor;
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor; + (NSColor *)wk_unemphasizedSelectedTextBackgroundColor;
+ (NSColor *)wk_controlAccentColor; + (NSColor *)wk_separatorColor; + (NSColor *)wk_containerBorderColor;
+ (NSColor *)wk_findHighlightColor;
+ (NSColor *)wk_systemBlueColor; + (NSColor *)wk_systemBrownColor; + (NSColor *)wk_systemGrayColor;
+ (NSColor *)wk_systemGreenColor; + (NSColor *)wk_systemOrangeColor; + (NSColor *)wk_systemPinkColor;
+ (NSColor *)wk_systemPurpleColor; + (NSColor *)wk_systemRedColor; + (NSColor *)wk_systemYellowColor;
+ (NSColor *)wk_systemFillColor; + (NSColor *)wk_secondarySystemFillColor; + (NSColor *)wk_tertiarySystemFillColor;
@end
@implementation NSColor (WKPolyfillScope)
+ (NSColor *)wk_labelColor                              { return [NSColor controlTextColor]; }
+ (NSColor *)wk_secondaryLabelColor                     { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_tertiaryLabelColor                      { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_quaternaryLabelColor                    { return [NSColor gridColor]; }
+ (NSColor *)wk_quinaryLabelColor                       { return [NSColor gridColor]; }
+ (NSColor *)wk_placeholderTextColor                    { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_selectedContentBackgroundColor          { return SRGB(56, 117, 215, 255); } // list-box active selection (sRGB; see note)
+ (NSColor *)wk_unemphasizedSelectedTextColor           { return [NSColor textColor]; }
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)wk_unemphasizedSelectedTextBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)wk_controlAccentColor                      { return [NSColor alternateSelectedControlColor]; } // 10.9 system blue
+ (NSColor *)wk_separatorColor                          { return [NSColor gridColor]; }
+ (NSColor *)wk_containerBorderColor                    { return [NSColor gridColor]; }
+ (NSColor *)wk_findHighlightColor                      { return SRGB(255, 237, 102, 255); } // real find-highlight yellow
+ (NSColor *)wk_systemBlueColor   { return SRGB(0, 122, 255, 255); }
+ (NSColor *)wk_systemBrownColor  { return SRGB(162, 132, 94, 255); }
+ (NSColor *)wk_systemGrayColor   { return SRGB(142, 142, 147, 255); }
+ (NSColor *)wk_systemGreenColor  { return SRGB(52, 199, 89, 255); }
+ (NSColor *)wk_systemOrangeColor { return SRGB(255, 149, 0, 255); }
+ (NSColor *)wk_systemPinkColor   { return SRGB(255, 45, 85, 255); }
+ (NSColor *)wk_systemPurpleColor { return SRGB(175, 82, 222, 255); }
+ (NSColor *)wk_systemRedColor    { return SRGB(255, 59, 48, 255); }
+ (NSColor *)wk_systemYellowColor { return SRGB(255, 204, 0, 255); }
+ (NSColor *)wk_systemFillColor          { return SRGB(0, 0, 0, 26); }
+ (NSColor *)wk_secondarySystemFillColor { return SRGB(0, 0, 0, 20); }
+ (NSColor *)wk_tertiarySystemFillColor  { return SRGB(0, 0, 0, 13); }
@end
WK_POLYFILL_SEL("labelColor", "wk_labelColor");
WK_POLYFILL_SEL("secondaryLabelColor", "wk_secondaryLabelColor");
WK_POLYFILL_SEL("tertiaryLabelColor", "wk_tertiaryLabelColor");
WK_POLYFILL_SEL("quaternaryLabelColor", "wk_quaternaryLabelColor");
WK_POLYFILL_SEL("quinaryLabelColor", "wk_quinaryLabelColor");
WK_POLYFILL_SEL("placeholderTextColor", "wk_placeholderTextColor");
WK_POLYFILL_SEL("selectedContentBackgroundColor", "wk_selectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextColor", "wk_unemphasizedSelectedTextColor");
WK_POLYFILL_SEL("unemphasizedSelectedContentBackgroundColor", "wk_unemphasizedSelectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextBackgroundColor", "wk_unemphasizedSelectedTextBackgroundColor");
// selectedTextBackgroundColor and alternateSelectedControlTextColor stay 10.9's own: both are present
// here, both convert cleanly through makeSimpleColorFromNSColor (measured: rgb(181,213,255) and
// rgb(255,255,255)), and 10.9's answer tracks the highlight colour set in System Preferences, which a
// fixed value cannot. The catalog colours whose deviceRGB conversion does return nil are the patterned
// controlColor and windowBackgroundColor, and upstream already reads those through its swatch fallback.
WK_POLYFILL_SEL("controlAccentColor", "wk_controlAccentColor");
WK_POLYFILL_SEL("separatorColor", "wk_separatorColor");
WK_POLYFILL_SEL("containerBorderColor", "wk_containerBorderColor");
WK_POLYFILL_SEL("findHighlightColor", "wk_findHighlightColor");
WK_POLYFILL_SEL("systemBlueColor", "wk_systemBlueColor");
WK_POLYFILL_SEL("systemBrownColor", "wk_systemBrownColor");
WK_POLYFILL_SEL("systemGrayColor", "wk_systemGrayColor");
WK_POLYFILL_SEL("systemGreenColor", "wk_systemGreenColor");
WK_POLYFILL_SEL("systemOrangeColor", "wk_systemOrangeColor");
WK_POLYFILL_SEL("systemPinkColor", "wk_systemPinkColor");
WK_POLYFILL_SEL("systemPurpleColor", "wk_systemPurpleColor");
WK_POLYFILL_SEL("systemRedColor", "wk_systemRedColor");
WK_POLYFILL_SEL("systemYellowColor", "wk_systemYellowColor");
WK_POLYFILL_SEL("systemFillColor", "wk_systemFillColor");
WK_POLYFILL_SEL("secondarySystemFillColor", "wk_secondarySystemFillColor");
WK_POLYFILL_SEL("tertiarySystemFillColor", "wk_tertiarySystemFillColor");

// ---------------------------------------------------------------------------------------------------
// The NSAppearance drawing API. 10.9 has the whole appearance mechanism — +currentAppearance,
// +setCurrentAppearance: (both PER THREAD, verified on 10.9.5, exactly like their 10.14+ successors),
// +appearanceNamed:, -name and the CoreUI-backed -_drawInRect:context:options:… family. What it lacks is
// the RENAMES and the two capabilities below, which is what these polyfills supply.
//
// The gap is spelling, not capability. 10.9 reaches the same CoreUI entry point through
// -_drawInRect:context:options:inView: / :delegate: / :inWindow:; the 3-argument
// -_drawInRect:context:options: is the 10.14+ name for it. -bestMatchFromAppearancesWithNames: (10.14+)
// and -_usesMetricsAppearance (11.0+) are renames in the same sense. Supplying all four as renames is
// what lets a real appearance reach CoreUI, and none of it involves the tint.
//
// With them supplied, 10.9's CoreUI draws the real widgets — measured on 10.9.5 (13F34) via
// -_drawInRect:context:options:inView:, kCUIWidgetScrollBarTrackCorner fills 900/1024 bytes of a 16x16
// bitmap, kCUIWidgetProgressBar 7600/8000 of a 100x20, kCUIWidgetButtonLittleArrows 935/1536 of a 16x24.
// A widget key this CoreUI does not know draws nothing and throws nothing. The only such key WebCore
// would ever pass is the 12.0+ kCUIWidgetSwitch* family — the one widget family this CoreUI has never
// heard of — and that never arrives, because the switch control is disabled at the WebCore layer on
// this port (see SwitchControlEnabled) and renders as the checkbox it is. Every other key is a real
// 10.9 widget and goes through to CoreUI untouched.
//
// BEHAVIOURAL DIVERGENCE, from two capabilities 10.9's AppKit genuinely does not have:
//   - Dark Aqua. 10.9 ships no dark appearance. +appearanceNamed:NSAppearanceNameDarkAqua returns a
//     stand-in object that carries the name but renders as Aqua, so a dark-appearance draw comes out
//     light. Nothing crashes and no call site is guarded; dark form controls simply look light.
//   - Per-appearance tint. -appearanceByApplyingTintColor: (11.0+) has no 10.9 equivalent: CoreUI on 10.9
//     draws with the system-wide accent (blue/graphite) and takes no per-appearance tint, so the polyfill
//     returns the receiver unchanged and a requested tint is ignored. On this OS the only tint that ever
//     reaches it is the one -tintColor below just handed out — the system accent — so the round trip is
//     exact for every value WebKit actually passes; a tint from anywhere else would be dropped.

// 10.9's spelling of the CoreUI draw, which no SDK we build against declares.
@interface NSAppearance (WKMavericksSPI)
- (void)_drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options inView:(NSView *)view;
@end

// ---------------------------------------------------------------------------------------------------
// kCUIIsFlippedKey, resolved from CoreUI itself so the option dictionary is keyed by the very string
// CoreUI uses. It is the one CoreUI option this layer supplies; every widget key WebCore passes names a
// real 10.9 CoreUI widget that the real -_drawInRect: below draws. (The switch — the one control family
// 10.9's CoreUI has never heard of — is disabled at the WebCore layer on this port and renders as the
// checkbox it is, so no switch key ever reaches here.)
static NSString *wkCoreUIIsFlippedKey(void)
{
    static void *cache;
    CFStringRef *slot = (CFStringRef *)wk_polyfill_system_symbol(
        "/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", "kCUIIsFlippedKey", &cache);
    return slot ? (__bridge NSString *)*slot : nil;
}

// A negative determinant means the caller's context puts the origin at the top left and grows y
// downwards, which is the transform WebCore's ImageBuffer contexts arrive with. This is what
// kCUIIsFlippedKey below is derived from.
static BOOL wkContextYGrowsDown(CGContextRef context)
{
    CGAffineTransform ctm = CGContextGetCTM(context);
    return (ctm.a * ctm.d - ctm.b * ctm.c) < 0;
}

@interface NSAppearance (WKPolyfillScope)
+ (NSAppearance *)wk_currentDrawingAppearance;
- (NSColor *)wk_tintColor;
- (void)wk__drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options;
- (NSString *)wk_bestMatchFromAppearancesWithNames:(NSArray *)names;
- (BOOL)wk__usesMetricsAppearance;
- (NSAppearance *)wk_appearanceByApplyingTintColor:(NSColor *)tintColor;
@end
@implementation NSAppearance (WKPolyfillScope)
// 10.14 renamed +currentAppearance (which it deprecated for the setter's sake) to +currentDrawingAppearance;
// the value is the same one -setCurrentAppearance:/-_performWithCurrentAppearance: install for the calling
// thread. 10.9 never leaves it unset, but fall back to Aqua rather than hand back nil, as 10.14+ does not.
+ (NSAppearance *)wk_currentDrawingAppearance
{
    NSAppearance *current = [NSAppearance currentAppearance];
    return current ?: [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}
- (NSColor *)wk_tintColor { return [NSColor alternateSelectedControlColor]; } // 10.9 accent
// 10.9's name for the same CoreUI draw. The view argument only supplies a backing-scale/geometry context
// the callers here do not have either (they pass a bare CGContext), so nil is the faithful mapping. Every
// widget key WebCore passes is one this CoreUI knows (the switch is disabled at the WebCore layer, so it
// never reaches here — see the section note above).
//
// ORIENTATION. kCUIIsFlippedKey is how CoreUI is told which way up the destination runs, and it composes
// with the CTM exactly: measured on 10.9.5, a y-down context drawing kCUIWidgetProgressBar with
// is.flipped:YES is byte-identical to the same widget drawn y-up, and byte-mirrored without it. The
// 10.14+ entry point this stands in for takes no such key and infers the orientation, so deriving it from
// the CTM supplies what the caller no longer says. A caller that does set it is describing its own
// destination and is left alone — ScrollbarTrackCornerSystemImageMac passes YES and InnerSpinButtonMac
// passes NO, and overriding either would mirror a widget CoreUI has already landed correctly.
- (void)wk__drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options
{
    NSString *isFlippedKey = wkCoreUIIsFlippedKey();
    if (context && isFlippedKey && ![options objectForKey:isFlippedKey]) {
        NSMutableDictionary *oriented = [options mutableCopy] ?: [NSMutableDictionary dictionary];
        oriented[isFlippedKey] = @(wkContextYGrowsDown(context));
        options = oriented;
    }
    [self _drawInRect:rect context:context options:options inView:nil];
}
// 10.9's appearances (Aqua and LightContent) all descend from Aqua and none of them is dark, so the
// receiver's own name wins when it is offered and Aqua is the best match otherwise — the same resolution
// 10.14+ performs over its inheritance graph, on the graph this OS has.
- (NSString *)wk_bestMatchFromAppearancesWithNames:(NSArray *)names
{
    NSString *name = [self name];
    if (name && [names containsObject:name])
        return name;
    for (NSString *candidate in names) {
        if ([candidate isEqualToString:NSAppearanceNameAqua])
            return candidate;
    }
    return nil;
}
// The metrics appearance is the 11.0 large-control geometry. 10.9 has no such appearance, so NO is the
// answer, not a missing one.
- (BOOL)wk__usesMetricsAppearance { return NO; }
// 10.9's CoreUI has no per-appearance tint — see the divergence note above.
- (NSAppearance *)wk_appearanceByApplyingTintColor:(NSColor *)tintColor
{
    (void)tintColor;
    return self;
}
@end
WK_POLYFILL_SEL("currentDrawingAppearance", "wk_currentDrawingAppearance");
WK_POLYFILL_SEL("tintColor", "wk_tintColor");
WK_POLYFILL_SEL("_drawInRect:context:options:", "wk__drawInRect:context:options:");
WK_POLYFILL_SEL("bestMatchFromAppearancesWithNames:", "wk_bestMatchFromAppearancesWithNames:");
WK_POLYFILL_SEL("_usesMetricsAppearance", "wk__usesMetricsAppearance");
WK_POLYFILL_SEL("appearanceByApplyingTintColor:", "wk_appearanceByApplyingTintColor:");

// ---------------------------------------------------------------------------------------------------
// NSWorkspace accessibility display options (10.10+). 10.9 has no such preferences → report NO, letting
// WebCore's ReducedMotion/increased-contrast/invert queries run unguarded.
@interface NSWorkspace (WKPolyfillScope)
- (BOOL)wk_accessibilityDisplayShouldIncreaseContrast;
- (BOOL)wk_accessibilityDisplayShouldDifferentiateWithoutColor;
- (BOOL)wk_accessibilityDisplayShouldReduceMotion;
- (BOOL)wk_accessibilityDisplayShouldInvertColors;
@end
@implementation NSWorkspace (WKPolyfillScope)
- (BOOL)wk_accessibilityDisplayShouldIncreaseContrast          { return NO; }
- (BOOL)wk_accessibilityDisplayShouldDifferentiateWithoutColor { return NO; }
- (BOOL)wk_accessibilityDisplayShouldReduceMotion              { return NO; }
- (BOOL)wk_accessibilityDisplayShouldInvertColors              { return NO; }
@end
WK_POLYFILL_SEL("accessibilityDisplayShouldIncreaseContrast", "wk_accessibilityDisplayShouldIncreaseContrast");
WK_POLYFILL_SEL("accessibilityDisplayShouldDifferentiateWithoutColor", "wk_accessibilityDisplayShouldDifferentiateWithoutColor");
WK_POLYFILL_SEL("accessibilityDisplayShouldReduceMotion", "wk_accessibilityDisplayShouldReduceMotion");
WK_POLYFILL_SEL("accessibilityDisplayShouldInvertColors", "wk_accessibilityDisplayShouldInvertColors");

// ---------------------------------------------------------------------------------------------------
// NSScreen -canRepresentDisplayGamut: (10.11+). 10.9 displays are sRGB → NO. Lets PlatformScreenMac
// (collectScreenProperties / screenSupportsExtendedColor) call it unguarded.
@interface NSScreen (WKPolyfillScope)
- (BOOL)wk_canRepresentDisplayGamut:(NSInteger)gamut;
@end
@implementation NSScreen (WKPolyfillScope)
- (BOOL)wk_canRepresentDisplayGamut:(NSInteger)gamut { (void)gamut; return NO; }
@end
WK_POLYFILL_SEL("canRepresentDisplayGamut:", "wk_canRepresentDisplayGamut:");

// ---------------------------------------------------------------------------------------------------
// NSScrollView content insets (10.10+): -contentInsets / -setContentInsets: and
// -setAutomaticallyAdjustsContentInsets:. WebKit1's WebDynamicScrollBarsView is an NSScrollView subclass,
// and ScrollViewMac.mm both reads and writes these on it — FrameView::obscuredContentInsets(WebCoreOrPlatformInset)
// round-trips WebCore's own inset back out through platformContentInsets()/platformSetContentInsets().
// 10.9's NSScrollView has none of them, so Mail's WebKit1 view sent -contentInsets and AppKit raised
// unrecognized-selector, which WebCore's BEGIN/END_BLOCK_OBJC_EXCEPTIONS discarded — leaving
// platformVisibleContentRect / platformSetScrollPosition to bail out mid-computation. Emulate the property
// faithfully with a stored NSEdgeInsets rather than a frozen zero: the getter returns exactly what the
// setter stored (zero by default), so WebCore's value round-trips the way the real property does. On this
// port the web scroll view is never inset in practice (no titlebar-overlapping full-size content view, no
// translucent overlay toolbar over web content), so the stored value stays zero.
// -setAutomaticallyAdjustsContentInsets: gates AppKit's automatic titlebar-overlap adjustment, which 10.9's
// scroll view never performs; the insets above are honored explicitly regardless, so accepting and ignoring
// the flag is faithful.
static const char kWKContentInsetsKey;
@interface NSScrollView (WKPolyfillScope)
- (NSEdgeInsets)wk_contentInsets;
- (void)wk_setContentInsets:(NSEdgeInsets)contentInsets;
- (void)wk_setAutomaticallyAdjustsContentInsets:(BOOL)automaticallyAdjustsContentInsets;
@end
@implementation NSScrollView (WKPolyfillScope)
- (NSEdgeInsets)wk_contentInsets
{
    NSEdgeInsets insets = (NSEdgeInsets){ .top = 0, .left = 0, .bottom = 0, .right = 0 };
    NSValue *stored = objc_getAssociatedObject(self, &kWKContentInsetsKey);
    if (stored)
        [stored getValue:&insets];
    return insets;
}
- (void)wk_setContentInsets:(NSEdgeInsets)contentInsets
{
    objc_setAssociatedObject(self, &kWKContentInsetsKey,
        [NSValue valueWithBytes:&contentInsets objCType:@encode(NSEdgeInsets)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)wk_setAutomaticallyAdjustsContentInsets:(BOOL)automaticallyAdjustsContentInsets { (void)automaticallyAdjustsContentInsets; }
@end
WK_POLYFILL_SEL("contentInsets", "wk_contentInsets");
WK_POLYFILL_SEL("setContentInsets:", "wk_setContentInsets:");
WK_POLYFILL_SEL("setAutomaticallyAdjustsContentInsets:", "wk_setAutomaticallyAdjustsContentInsets:");

// ---------------------------------------------------------------------------------------------------
// NSEvent -stage (Force Touch click stage, 10.10.3+). 10.9 has no Force Touch hardware → 0. Lets the
// pressure-event code (PlatformEventFactoryMac) read event.stage unguarded.
@interface NSEvent (WKPolyfillScope)
- (NSInteger)wk_stage;
@end
@implementation NSEvent (WKPolyfillScope)
- (NSInteger)wk_stage { return 0; }
@end
WK_POLYFILL_SEL("stage", "wk_stage");

// ---------------------------------------------------------------------------------------------------
// NSWindow -performWindowDragWithEvent: (10.11+). 10.9 has no native window drag from web content, so
// WebViewImpl::startWindowDrag() (Web Inspector unified toolbar, -webkit-app-region:drag) never moved
// the window. Provide the classic pre-10.11 manual drag loop: follow the mouse until mouse-up.
// -[NSWindow convertPointToScreen:] / -convertPointFromScreen: (10.12+) are the point-based renames of
// the classic -convertBaseToScreen: / -convertScreenToBase: (present, deprecated, on 10.9).
@interface NSWindow (WKPolyfillScope)
- (NSPoint)wk_convertPointToScreen:(NSPoint)point;
- (NSPoint)wk_convertPointFromScreen:(NSPoint)point;
- (void)wk_performWindowDragWithEvent:(NSEvent *)event;
- (NSRect)wk_contentLayoutRect;
@end
@implementation NSWindow (WKPolyfillScope)
- (NSPoint)wk_convertPointToScreen:(NSPoint)point { return [self convertBaseToScreen:point]; }
- (NSPoint)wk_convertPointFromScreen:(NSPoint)point { return [self convertScreenToBase:point]; }
// -[NSWindow contentLayoutRect] is 10.10+: the content region not obscured by a full-size-content-view
// title bar, in window coordinates. 10.9 has no full-size content view, so that region is exactly the
// content view's frame -- which is also the fallback the WebKit call sites used before this polyfill.
- (NSRect)wk_contentLayoutRect { return [[self contentView] frame]; }
- (void)wk_performWindowDragWithEvent:(NSEvent *)event
{
    (void)event;
    NSPoint startMouse = [NSEvent mouseLocation];
    NSRect startFrame = [self frame];
    while (YES) {
        @autoreleasepool {
            NSEvent *e = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                            untilDate:[NSDate distantFuture]
                                               inMode:NSEventTrackingRunLoopMode
                                              dequeue:YES];
            if (!e || e.type == NSEventTypeLeftMouseUp)
                break;
            NSPoint now = [NSEvent mouseLocation];
            [self setFrameOrigin:NSMakePoint(startFrame.origin.x + (now.x - startMouse.x),
                                             startFrame.origin.y + (now.y - startMouse.y))];
        }
    }
}
@end
WK_POLYFILL_SEL("performWindowDragWithEvent:", "wk_performWindowDragWithEvent:");
WK_POLYFILL_SEL("convertPointToScreen:", "wk_convertPointToScreen:");
WK_POLYFILL_SEL("convertPointFromScreen:", "wk_convertPointFromScreen:");
WK_POLYFILL_SEL("contentLayoutRect", "wk_contentLayoutRect");

// ---------------------------------------------------------------------------------------------------
// NSURL -_lp_simplifiedDisplayString (LinkPresentation, 10.15+). LinkPresentation is absent on 10.9, so
// createDragImageForLink (DragImageCocoa) would send an unrecognized selector to NSURL. Return the host
// (nearest 10.9 meaning of a "simplified" display URL), falling back to the absolute string.
//
// +URLByResolvingAliasFileAtURL:options:error: (10.10+). A Finder alias file has been a bookmark file
// since 10.6, so resolve it with the bookmark API 10.9 has; the NSURLBookmarkResolutionOptions bits are
// the same ones the modern method takes. Per the modern contract, a URL that is not an alias file
// (NSURLIsAliasFileKey, which also covers symlinks) comes back unchanged, and symlinks — which carry no
// bookmark data — resolve to their destination.
@interface NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString;
+ (NSURL *)wk_URLByResolvingAliasFileAtURL:(NSURL *)url options:(NSURLBookmarkResolutionOptions)options error:(NSError **)error;
- (instancetype)wk_initWithString:(NSString *)string;
+ (instancetype)wk_URLWithString:(NSString *)string;
@end
@implementation NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString
{
    NSString *host = [self host];
    return host.length ? host : [self absoluteString];
}
+ (NSURL *)wk_URLByResolvingAliasFileAtURL:(NSURL *)url options:(NSURLBookmarkResolutionOptions)options error:(NSError **)error
{
    NSNumber *isAlias = nil;
    [url getResourceValue:&isAlias forKey:NSURLIsAliasFileKey error:NULL];
    if (![isAlias boolValue])
        return url;
    NSError *bookmarkError = nil;
    NSData *bookmarkData = [NSURL bookmarkDataWithContentsOfURL:url error:&bookmarkError];
    if (!bookmarkData) {
        NSNumber *isSymlink = nil;
        if ([url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:NULL] && [isSymlink boolValue])
            return [url URLByResolvingSymlinksInPath];
        if (error)
            *error = bookmarkError;
        return nil;
    }
    BOOL stale = NO;
    return [NSURL URLByResolvingBookmarkData:bookmarkData options:options relativeToURL:nil bookmarkDataIsStale:&stale error:error];
}
// -getResourceValue:forKey:error: exists on 10.9 but does not know the modern NSURLContentTypeKey
// (11.0+, answered with a UTType). REPLACE it for WebKit's callers: that one key is answered from the
// classic NSURLTypeIdentifierKey wrapped in the UTType polyfill class; every other key forwards to
// 10.9's implementation (reached through a runtime-built selector, which the selref rewrite cannot
// touch, so this cannot recurse into itself).
- (BOOL)wk_getResourceValue:(id *)value forKey:(NSString *)key error:(NSError **)error
{
    typedef BOOL (*WKGetResourceValueFn)(id, SEL, id *, NSString *, NSError **);
    WKGetResourceValueFn original = (WKGetResourceValueFn)objc_msgSend;
    SEL originalSelector = sel_registerName("getResourceValue:forKey:error:");
    if ([key isEqualToString:NSURLContentTypeKey]) {
        NSString *typeIdentifier = nil;
        if (!original(self, originalSelector, (id *)&typeIdentifier, NSURLTypeIdentifierKey, error))
            return NO;
        if (value)
            *value = typeIdentifier ? [UTType typeWithIdentifier:typeIdentifier] : nil;
        return YES;
    }
    return original(self, originalSelector, value, key, error);
}
// -[NSURL initWithString:] and +[NSURL URLWithString:] throw NSInvalidArgumentException on a nil string
// on 10.9 (modern Foundation returns nil). REPLACE both for WebKit's callers with the modern contract:
// nil in -> nil out; any non-nil string forwards to 10.9's real implementation, reached through a
// runtime-built selector the selref rewrite cannot touch (so this cannot recurse into itself). The init
// consumes its already-alloc'd receiver on the nil path to keep the alloc/init ownership contract (methods.m
// is MRR). +URLWithString: is not an init-family selector, so it just returns nil/the autoreleased URL.
- (instancetype)wk_initWithString:(NSString *)string
{
    if (!string) {
        [self release];
        return nil;
    }
    // The same modern-vs-10.9 contract gap, one case over: modern -initWithString:@"" returns a non-nil
    // URL whose relativeString is empty, and does so for an NSURL SUBCLASS too. 10.9 returns nil for the
    // empty string on a subclass, though it answers correctly for NSURL itself -- measured on this host:
    //   [[NSURL alloc]         initWithString:@""] -> object
    //   [[NSURLSubclass alloc] initWithString:@""] -> nil
    //   [[NSURLSubclass alloc] initWithString:@"" relativeToURL:[NSURL URLWithString:@""]]
    //                                              -> object, relativeString "", subclass preserved
    // so the relative form is 10.9's way to spell what the modern initializer means, and it is applied
    // only where 10.9 would otherwise hand back nil. Decided BEFORE calling the real initializer, never
    // after: a failed init has already released the receiver, so a second init on it is a use-after-free.
    if (![string length] && ![self isMemberOfClass:[NSURL class]]) {
        typedef id (*WKURLInitRelativeFn)(id, SEL, NSString *, NSURL *);
        WKURLInitRelativeFn originalRelative = (WKURLInitRelativeFn)objc_msgSend;
        typedef id (*WKURLWithStringFn)(id, SEL, NSString *);
        WKURLWithStringFn urlWithString = (WKURLWithStringFn)objc_msgSend;
        NSURL *emptyBase = urlWithString([NSURL class], sel_registerName("URLWithString:"), @"");
        return originalRelative(self, sel_registerName("initWithString:relativeToURL:"), string, emptyBase);
    }
    typedef id (*WKURLInitFn)(id, SEL, NSString *);
    WKURLInitFn original = (WKURLInitFn)objc_msgSend;
    return original(self, sel_registerName("initWithString:"), string);
}
+ (instancetype)wk_URLWithString:(NSString *)string
{
    if (!string)
        return nil;
    typedef id (*WKURLWithStringFn)(id, SEL, NSString *);
    WKURLWithStringFn original = (WKURLWithStringFn)objc_msgSend;
    return original(self, sel_registerName("URLWithString:"), string);
}
@end
WK_POLYFILL_SEL("_lp_simplifiedDisplayString", "wk__lp_simplifiedDisplayString");
WK_POLYFILL_SEL("URLByResolvingAliasFileAtURL:options:error:", "wk_URLByResolvingAliasFileAtURL:options:error:");
WK_POLYFILL_SEL_REPLACES("getResourceValue:forKey:error:", "wk_getResourceValue:forKey:error:");
WK_POLYFILL_SEL_REPLACES("initWithString:", "wk_initWithString:");
WK_POLYFILL_SEL_REPLACES("URLWithString:", "wk_URLWithString:");

// ---------------------------------------------------------------------------------------------------
// -[NSAttributedString _htmlDocumentFragmentString:documentAttributes:subresources:] (returns interchange
// HTML fragment markup + collects WebArchive subresources) is ABSENT on 10.9 (verified on-host:
// instancesRespondToSelector == NO; the older -_documentFromRange:document:documentAttributes:subresources:
// exists but yields a WebKit1 DOMDocumentFragment, not a string). WebContentReaderCocoa's
// createFragmentInternal(NSAttributedString*) needs the STRING form when pasting RTF / attributed-string
// content from a native app (TextEdit, Mail, Notes) that puts NO html on the pasteboard; without it rich
// paste is silently stripped to plain text. Reimplement from the PUBLIC exporter
// -dataFromRange:documentAttributes:error: (present on 10.9): NSHTMLTextDocumentType output honors the
// caller's NSExcludedElementsDocumentAttribute, which already excludes doctype/html/head/body/style/xml, so
// the result is fragment markup rather than a full document. Subresources (embedded images) are not
// collected by the public path — return an empty array; inline text formatting (bold/italic/color/underline/
// lists/links) is preserved, which is the overwhelming majority of native-app rich paste.
@interface NSAttributedString (WKPolyfillScope)
- (NSString *)wk__htmlDocumentFragmentString:(NSRange)range documentAttributes:(NSDictionary *)dict subresources:(NSArray **)subresources;
@end
@implementation NSAttributedString (WKPolyfillScope)
- (NSString *)wk__htmlDocumentFragmentString:(NSRange)range documentAttributes:(NSDictionary *)dict subresources:(NSArray **)subresources
{
    if (subresources)
        *subresources = @[];
    NSMutableDictionary *docAttributes = [NSMutableDictionary dictionary];
    [docAttributes setObject:NSHTMLTextDocumentType forKey:NSDocumentTypeDocumentAttribute];
    // Carry over only the public exclusion list; drop the private WebResourceHandler/OutputBaseURL/
    // InterchangeNewline/CoalesceTabSpans keys the public exporter does not understand.
    id excluded = [dict objectForKey:NSExcludedElementsDocumentAttribute];
    if (excluded)
        [docAttributes setObject:excluded forKey:NSExcludedElementsDocumentAttribute];
    NSData *data = [self dataFromRange:range documentAttributes:docAttributes error:NULL];
    if (!data)
        return @"";
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}
@end
WK_POLYFILL_SEL("_htmlDocumentFragmentString:documentAttributes:subresources:", "wk__htmlDocumentFragmentString:documentAttributes:subresources:");

// ---------------------------------------------------------------------------------------------------
// NSView -_subviewsIvar / -_setSubviewsIvar: (10.12+ SPI): raw accessors for the _subviews ivar, used
// by WebHTMLView's set-aside/restore dance during drawing. The ivar itself exists on 10.9's NSView;
// the SPI is only the accessor pair, with raw-assign semantics (no retain/release, no layout side
// effects) — which is exactly what object_getIvar/object_setIvar do under MRR.
@interface NSView (WKPolyfillScope)
- (NSMutableArray *)wk__subviewsIvar;
- (void)wk__setSubviewsIvar:(NSMutableArray *)subviews;
@end
@implementation NSView (WKPolyfillScope)
- (NSMutableArray *)wk__subviewsIvar
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    return ivar ? object_getIvar(self, ivar) : nil;
}
- (void)wk__setSubviewsIvar:(NSMutableArray *)subviews
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    if (ivar)
        object_setIvar(self, ivar, subviews);
}
@end
WK_POLYFILL_SEL("_subviewsIvar", "wk__subviewsIvar");
WK_POLYFILL_SEL("_setSubviewsIvar:", "wk__setSubviewsIvar:");

// ---------------------------------------------------------------------------------------------------
// NSTextAttachment modern accessors: -initWithData:ofType: and the image property are 10.11+ on Mac;
// -accessibilityLabel / -setAccessibilityLabel: are 10.10+ (NSTextAttachment adopts NSAccessibility
// then). 10.9 stores the same ideas elsewhere: contents live in the attachment's NSFileWrapper, and a
// displayed image lives in an NSTextAttachmentCell. The polyfills store through those, so an attachment
// built here renders identically in 10.9's own text system; the explicitly-set image object and the
// accessibility label — values 10.9 has no storage for — ride along as associated objects, so the
// getters answer exactly what was set, like the modern properties.
static char kWKTextAttachmentImageKey;
static char kWKTextAttachmentAccessibilityLabelKey;
static char kWKTextAttachmentContentsKey;
static char kWKTextAttachmentFileTypeKey;
@interface NSTextAttachment (WKPolyfillScope)
- (id)wk_initWithData:(NSData *)contentData ofType:(NSString *)uti;
- (NSData *)wk_contents;
- (void)wk_setContents:(NSData *)contents;
- (NSString *)wk_fileType;
- (void)wk_setFileType:(NSString *)fileType;
- (NSImage *)wk_image;
- (void)wk_setImage:(NSImage *)image;
- (NSString *)wk_accessibilityLabel;
- (void)wk_setAccessibilityLabel:(NSString *)label;
@end
@implementation NSTextAttachment (WKPolyfillScope)
- (id)wk_initWithData:(NSData *)contentData ofType:(NSString *)uti
{
    // Modern AppKit keeps (data, type) directly, answerable back through the contents/fileType
    // properties; 10.9 renders from a file wrapper. Store both ways: the pair as associated objects
    // (the modern properties' storage) and the data in a wrapper so 10.9's own text system draws it.
    // nil data makes an attachment with no contents yet (the caller sets an image or a wrapper after).
    NSFileWrapper *wrapper = nil;
    if (contentData) {
        wrapper = [[[NSFileWrapper alloc] initRegularFileWithContents:contentData] autorelease];
        CFStringRef extension = uti ? UTTypeCopyPreferredTagWithClass((CFStringRef)uti, kUTTagClassFilenameExtension) : NULL;
        if (extension) {
            [wrapper setPreferredFilename:[@"attachment" stringByAppendingPathExtension:(NSString *)extension]];
            CFRelease(extension);
        }
    }
    self = [self initWithFileWrapper:wrapper];
    if (self) {
        objc_setAssociatedObject(self, &kWKTextAttachmentContentsKey, contentData, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, &kWKTextAttachmentFileTypeKey, uti, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return self;
}
- (NSData *)wk_contents
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentContentsKey);
}
- (void)wk_setContents:(NSData *)contents
{
    objc_setAssociatedObject(self, &kWKTextAttachmentContentsKey, contents, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSString *)wk_fileType
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentFileTypeKey);
}
- (void)wk_setFileType:(NSString *)fileType
{
    objc_setAssociatedObject(self, &kWKTextAttachmentFileTypeKey, fileType, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSImage *)wk_image
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentImageKey);
}
- (void)wk_setImage:(NSImage *)image
{
    objc_setAssociatedObject(self, &kWKTextAttachmentImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Also store it where 10.9's text system actually draws from.
    if (image) {
        NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell:image] autorelease];
        [self setAttachmentCell:cell];
    } else
        [self setAttachmentCell:nil];
}
- (NSString *)wk_accessibilityLabel
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey);
}
- (void)wk_setAccessibilityLabel:(NSString *)label
{
    objc_setAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
@end
WK_POLYFILL_SEL("initWithData:ofType:", "wk_initWithData:ofType:");
WK_POLYFILL_SEL("contents", "wk_contents");
WK_POLYFILL_SEL("setContents:", "wk_setContents:");
WK_POLYFILL_SEL("fileType", "wk_fileType");
WK_POLYFILL_SEL("setFileType:", "wk_setFileType:");
WK_POLYFILL_SEL("image", "wk_image");
WK_POLYFILL_SEL("setImage:", "wk_setImage:");
WK_POLYFILL_SEL("accessibilityLabel", "wk_accessibilityLabel");
WK_POLYFILL_SEL("setAccessibilityLabel:", "wk_setAccessibilityLabel:");

// ---------------------------------------------------------------------------------------------------
// -[NSString containsString:] (10.10+) via the classic -rangeOfString:.
@interface NSString (WKPolyfillScope)
- (BOOL)wk_containsString:(NSString *)str;
@end
@implementation NSString (WKPolyfillScope)
- (BOOL)wk_containsString:(NSString *)str { return [self rangeOfString:str].location != NSNotFound; }
@end
WK_POLYFILL_SEL("containsString:", "wk_containsString:");

// ---------------------------------------------------------------------------------------------------
// +[NSMenu menuTypeForEvent:] (10.10+): classify a mouse event into a menu type. On 10.9, reproduce the
// documented mapping — right-click or control+left-click opens a context menu, otherwise none.
// NSMenuType is not in the public AppKit headers (WebKit declares it in pal/spi/mac/NSMenuSPI.h); this
// polyfill lives outside WebKit's include paths, so forward-declare the enum to match.
typedef NS_ENUM(NSInteger, NSMenuType) {
    NSMenuTypeNone = 0,
    NSMenuTypeContextMenu = 1,
};
@interface NSMenu (WKPolyfillScope)
+ (NSMenuType)wk_menuTypeForEvent:(NSEvent *)event;
@end
@implementation NSMenu (WKPolyfillScope)
+ (NSMenuType)wk_menuTypeForEvent:(NSEvent *)event
{
    if (event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp)
        return NSMenuTypeContextMenu;
    if ((event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp)
        && (event.modifierFlags & NSEventModifierFlagControl))
        return NSMenuTypeContextMenu;
    return NSMenuTypeNone;
}
@end
WK_POLYFILL_SEL("menuTypeForEvent:", "wk_menuTypeForEvent:");

// ---------------------------------------------------------------------------------------------------
// -[NSPasteboard _setExpirationDate:] (11.0+ private SPI): auto-clears ephemeral pasteboard data after a
// delay. 10.9 has no such pasteboard-server mechanism, so the faithful 10.9 behavior is a no-op (the data
// simply persists, exactly as when the guard skipped the call).
@interface NSPasteboard (WKPolyfillScope)
- (void)wk__setExpirationDate:(NSDate *)date;
@end
@implementation NSPasteboard (WKPolyfillScope)
- (void)wk__setExpirationDate:(NSDate *)date { (void)date; }
@end
WK_POLYFILL_SEL("_setExpirationDate:", "wk__setExpirationDate:");

// ---------------------------------------------------------------------------------------------------
// -[PDFPage drawWithBox:toContext:] (10.12+) via the classic -[PDFPage drawWithBox:] (10.4+), which
// renders into the CURRENT NSGraphicsContext. Wrap the passed CGContext as current for the duration of
// the draw, restoring the prior context after — the CTM the caller applied to `context` is honored.
@interface PDFPage (WKPolyfillScope)
- (void)wk_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context;
@end
@implementation PDFPage (WKPolyfillScope)
- (void)wk_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context
{
    NSGraphicsContext *priorContext = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:NO]];
    [self drawWithBox:box];
    [NSGraphicsContext setCurrentContext:priorContext];
}
@end
WK_POLYFILL_SEL("drawWithBox:toContext:", "wk_drawWithBox:toContext:");

// ---------------------------------------------------------------------------------------------------
// Post-10.9 side-effect-only SPIs with no 10.9 equivalent — faithful no-ops (identical to the current
// guarded skip). NSURLSession +_disableAppSSO (10.13), NSApplication +_preventDockConnections (10.10) /
// -_setAccentColor: (10.14), NSWindow -setTitlebarAppearsTransparent: (10.10) / -setTitleVisibility:
// (10.10) — 10.9 has no App-SSO, no dock-connection control, no window accent, no transparent titlebar,
// and the window title is always shown.
@interface NSURLSession (WKPolyfillScope)
+ (void)wk__disableAppSSO;
@end
@implementation NSURLSession (WKPolyfillScope)
+ (void)wk__disableAppSSO { }
@end
WK_POLYFILL_SEL("_disableAppSSO", "wk__disableAppSSO");

@interface NSApplication (WKPolyfillScope)
+ (void)wk__preventDockConnections;
- (void)wk__setAccentColor:(NSColor *)color;
@end
@implementation NSApplication (WKPolyfillScope)
+ (void)wk__preventDockConnections { }
- (void)wk__setAccentColor:(NSColor *)color { (void)color; }
@end
WK_POLYFILL_SEL("_preventDockConnections", "wk__preventDockConnections");
WK_POLYFILL_SEL("_setAccentColor:", "wk__setAccentColor:");

// NSWindowStyleMaskFullSizeContentView + -setTitlebarAppearsTransparent: (both 10.10+), implemented for
// real rather than stubbed.
//
// The 10.10 behaviour is: the content view is laid out over the FULL window frame, extending up behind the
// titlebar, and the titlebar stops drawing its own background so the content shows through. 10.9 ignores
// the style-mask bit and lacks the setter, so a window asking for it gets an ordinary titled window with
// its content pushed below the titlebar.
//
// Measured on this host, which rules out the easy implementations:
//   * overriding -contentRectForFrameRect: (and the class version) does NOT move the content view --
//     it stays 400pt tall inside a 422pt frame view; and
//   * placing the content view over the frame view by hand DOES work, but NSThemeFrame re-lays-it-out on
//     the very next resize (600x422 full-size -> 800x578 back under the titlebar).
// So the behaviour is reproducible only by placing the content view AND re-placing it whenever the window
// resizes. That is what the adapter below does, keeping the standard window buttons above the content view
// so the traffic lights stay visible and clickable, exactly as they float over a full-size content view on
// 10.10+.
//
// Trigger: -setTitlebarAppearsTransparent: with the style mask's full-size-content bit set. 10.9 offers no
// hook at window-creation time (the content view is installed before any public setter runs), and these
// two are a matched pair in AppKit's own API -- a full-size content view without a transparent titlebar
// would just be content hidden behind an opaque bar. A window that sets the bit and never calls the
// companion setter keeps 10.9's default layout.
enum { WKFullSizeContentViewStyleMask = 1 << 15 };   // NSWindowStyleMaskFullSizeContentView
static const char wkTitlebarAppearsTransparentKey;
static const char wkFullSizeContentAdapterKey;

@interface WKPolyfillFullSizeContentAdapter : NSObject {
    NSWindow *_window;   // unretained: the window owns this adapter through an associated object
}
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)apply;
@end

@implementation WKPolyfillFullSizeContentAdapter

- (instancetype)initWithWindow:(NSWindow *)window
{
    if (!(self = [super init]))
        return nil;
    _window = window;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(wkWindowDidResize:)
                                                 name:NSWindowDidResizeNotification object:window];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)apply
{
    NSView *contentView = [_window contentView];
    NSView *frameView = [contentView superview];
    if (!contentView || !frameView)
        return;

    [contentView setFrame:[frameView bounds]];

    // The traffic lights are siblings of the content view inside the frame view. A full-size content view
    // covers the whole frame, so without this they would be painted over.
    //
    // Reorder with remove + append, NOT -addSubview:positioned:relativeTo:. 10.9's move path for an
    // already-parented view computes the insertion index and mutates the subviews array inside one call;
    // when NSThemeFrame's own button management mutates that array mid-call (seen on real hardware opening
    // the Web Inspector), the insert lands out of bounds and throws NSRangeException. That throw happens
    // after the button has been pulled out of the array but before -removeFromSuperview bookkeeping, so it
    // strands the button with a dangling _window; the exception then unwinds window creation, the window is
    // freed, and the button's later dealloc messages the freed window (crash in -[NSControl currentEditor]
    // under fieldEditor:forObject:). Two separate whole calls each keep AppKit's invariants and cannot
    // leave a stale index. Appending puts the button after the content view in the subview order, which is
    // exactly the "drawn above the full-size content view" placement being restored.
    NSWindowButton buttons[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton,
                                 NSWindowFullScreenButton };
    BOOL raisedAnyButton = NO;
    for (size_t i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
        NSButton *button = [_window standardWindowButton:buttons[i]];
        if (!button || [button superview] != frameView)
            continue;
        [[button retain] autorelease];   // keep the button alive across its removal
        [button removeFromSuperview];
        [frameView addSubview:button];
        raisedAnyButton = YES;
    }

    // On 10.9 a layer-backed subview (the Web Inspector's frontend web view is one) is a standalone
    // layer ISLAND whose surface composites above every non-layer view in the window regardless of
    // subview order, so the buttons raised above are covered anyway, and the island's square-edged
    // surface paints over NSThemeFrame's rounded titlebar corners. Layer-backing the content view makes
    // AppKit promote the overlapping frame-view subviews (the buttons) into one layer tree with it, so
    // subview z-order holds and transparent content corners reveal the native rounded corners — which is
    // how a full-size content view composites on 10.10+. Verified load-bearing by live view-tree dump
    // (buttons present but covered without it); scoped to windows with raised buttons so buttonless
    // full-size-content windows (e.g. the datalist dropdown) keep non-layer-backed text rendering.
    if (raisedAnyButton && ![contentView wantsLayer])
        [contentView setWantsLayer:YES];
}

- (void)wkWindowDidResize:(NSNotification *)notification
{
    (void)notification;
    [self apply];   // NSThemeFrame has just re-laid-out the content view under the titlebar; undo that
}

@end

@interface NSWindow (WKPolyfillScopeChrome)
- (void)wk_setTitlebarAppearsTransparent:(BOOL)flag;
- (BOOL)wk_titlebarAppearsTransparent;
- (void)wk_setTitleVisibility:(NSInteger)visibility;
@end
@implementation NSWindow (WKPolyfillScopeChrome)

- (void)wk_setTitlebarAppearsTransparent:(BOOL)flag
{
    objc_setAssociatedObject(self, (const void *)&wkTitlebarAppearsTransparentKey,
                             flag ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!flag || !([self styleMask] & WKFullSizeContentViewStyleMask))
        return;
    if (objc_getAssociatedObject(self, (const void *)&wkFullSizeContentAdapterKey))
        return;

    WKPolyfillFullSizeContentAdapter *adapter = [[[WKPolyfillFullSizeContentAdapter alloc] initWithWindow:self] autorelease];
    objc_setAssociatedObject(self, (const void *)&wkFullSizeContentAdapterKey, adapter,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [adapter apply];
}

// Reports what the setter stored. It used to answer a fixed NO, which contradicted its own setter: a
// caller that set the property and read it back was told its request had been ignored. WebKit reads this
// (PageClientImpl::computeAutomaticTopObscuredInset) to lay content out under the titlebar, so a wrong
// answer here is what leaves a window drawing its own title bar underneath the real one.
- (BOOL)wk_titlebarAppearsTransparent
{
    return objc_getAssociatedObject(self, (const void *)&wkTitlebarAppearsTransparentKey) != nil;
}

// -setTitleVisibility: (10.10+) hides the title STRING while keeping the titlebar. 10.9 draws the title
// as part of NSThemeFrame's titlebar with no separate control over it.
- (void)wk_setTitleVisibility:(NSInteger)visibility { (void)visibility; }

@end
WK_POLYFILL_SEL("setTitlebarAppearsTransparent:", "wk_setTitlebarAppearsTransparent:");
WK_POLYFILL_SEL("titlebarAppearsTransparent", "wk_titlebarAppearsTransparent");
WK_POLYFILL_SEL("setTitleVisibility:", "wk_setTitleVisibility:");

// ---------------------------------------------------------------------------------------------------
// -[NSString stringByApplyingTransform:reverse:] (10.11+) via CFStringTransform (10.4+), which accepts
// the same ICU transform IDs (e.g. @"Hans-Hant"). Returns the transformed string, or nil if the
// transform fails — matching the modern method's contract. (Verified CFStringTransform(@"Hans-Hant")
// works on 10.9.)
@interface NSString (WKPolyfillScopeTransform)
- (NSString *)wk_stringByApplyingTransform:(NSString *)transform reverse:(BOOL)reverse;
@end
@implementation NSString (WKPolyfillScopeTransform)
- (NSString *)wk_stringByApplyingTransform:(NSString *)transform reverse:(BOOL)reverse
{
    NSMutableString *result = [[self mutableCopy] autorelease];
    CFRange range = CFRangeMake(0, result.length);
    if (CFStringTransform((CFMutableStringRef)result, &range, (CFStringRef)transform, reverse))
        return result;
    return nil;
}
@end
WK_POLYFILL_SEL("stringByApplyingTransform:reverse:", "wk_stringByApplyingTransform:reverse:");

// ---------------------------------------------------------------------------------------------------
// -[NSRunLoop performBlock:] (10.13+) via CFRunLoopPerformBlock (10.6+): enqueue the block to run on the
// next iteration of this run loop in the common modes, then wake the loop so it fires promptly. This is
// exactly what the modern method does, and (like it) is safe to call from another thread — WebKit uses it
// from async completion handlers (spell-check results, XPC teardown) to hop back onto a run loop.
@interface NSRunLoop (WKPolyfillScope)
- (void)wk_performBlock:(void (^)(void))block;
@end
@implementation NSRunLoop (WKPolyfillScope)
- (void)wk_performBlock:(void (^)(void))block
{
    CFRunLoopRef runLoop = [self getCFRunLoop];
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(runLoop);
}
@end
WK_POLYFILL_SEL("performBlock:", "wk_performBlock:");

// ---------------------------------------------------------------------------------------------------
// -[NSColorWell setSupportsAlpha:] (14.0+): 10.9 honors alpha through the shared color panel's alpha slider
// (NSPopoverColorWell, the receiver, is backed by +[NSColorPanel sharedColorPanel]).
@interface NSColorWell (WKPolyfillScope)
- (void)wk_setSupportsAlpha:(BOOL)flag;
@end
@implementation NSColorWell (WKPolyfillScope)
- (void)wk_setSupportsAlpha:(BOOL)flag { [[NSColorPanel sharedColorPanel] setShowsAlpha:flag]; }
@end
WK_POLYFILL_SEL("setSupportsAlpha:", "wk_setSupportsAlpha:");

// ---------------------------------------------------------------------------------------------------
// -[NSApplication _effectiveAccentColor] (10.14+ SPI): the default macOS accent/control-tint blue. Must be an
// EXPLICIT sRGB color, NOT a catalog color like alternateSelectedControlColor: PageClientImpl::accentColor()
// feeds this through colorFromCocoaColor() -> [color colorUsingColorSpace:], which resolves 10.9 catalog
// colors to BLACK (same trap as the text-selection colors above). colorWithSRGBRed: is already concrete, so
// the downstream space conversion is a no-op and the accent stays blue.
@interface NSApplication (WKPolyfillScopeAccent)
- (NSColor *)wk__effectiveAccentColor;
@end
@implementation NSApplication (WKPolyfillScopeAccent)
- (NSColor *)wk__effectiveAccentColor { return SRGB(0, 122, 255, 255); }
@end
WK_POLYFILL_SEL("_effectiveAccentColor", "wk__effectiveAccentColor");

// ---------------------------------------------------------------------------------------------------
// -[NSTextInputContext handleEvent:completionHandler:] and
// -[NSTextInputContext handleEventByInputMethod:completionHandler:] (10.10+ SPI): delegate to the
// synchronous 10.6 -handleEvent: and report its result — routing the event through the input context
// first, as upstream does. (Do not polyfill "handleEvent:" itself: this body calls it.)
//
// The KEY-EVENT pair, -handleEventByInputMethod:completionHandler: and -handleEventByKeyboardLayout:
// (both 10.10+), split what 10.6's -handleEvent: does in one step: first offer the event to the input
// method alone, then, if the input method did not consume it, translate it through the keyboard layout
// and key bindings. 10.9 has no entry point for the first half on its own. Emulating it with
// -handleEvent: is WRONG — that performs the whole translation, and WebKit then runs the
// keyboard-layout half as well, so every keystroke was inserted TWICE (typing 1234 in the Web
// Inspector console produced 11223344).
//
// So: report that the input method did not consume the event (translating nothing), and do the single
// translation in the keyboard-layout half, where -handleEvent: belongs. Composition still works,
// because -handleEvent: consults the input method itself — this is exactly the pre-10.10 flow, which
// is what WebKit did on this OS before the SPI existed. Without these two, the sends raised
// unrecognized-selector exceptions and no completion handler ever ran, so key input on every
// WKWebView-backed surface in the process — the Web Inspector front end above all — went nowhere.
@interface NSTextInputContext (WKPolyfillScope)
- (void)wk_handleEvent:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler;
- (void)wk_handleEventByInputMethod:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler;
- (BOOL)wk_handleEventByKeyboardLayout:(NSEvent *)event;
@end
@implementation NSTextInputContext (WKPolyfillScope)
- (void)wk_handleEvent:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler
{
    BOOL handled = [self handleEvent:event];
    if (completionHandler)
        completionHandler(handled);
}
- (void)wk_handleEventByInputMethod:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler
{
    (void)event;
    if (completionHandler)
        completionHandler(NO);
}
- (BOOL)wk_handleEventByKeyboardLayout:(NSEvent *)event
{
    return [self handleEvent:event];
}
@end
WK_POLYFILL_SEL("handleEvent:completionHandler:", "wk_handleEvent:completionHandler:");
WK_POLYFILL_SEL("handleEventByInputMethod:completionHandler:", "wk_handleEventByInputMethod:completionHandler:");
WK_POLYFILL_SEL("handleEventByKeyboardLayout:", "wk_handleEventByKeyboardLayout:");

// ---------------------------------------------------------------------------------------------------
// SF Symbols (11.0+): no system symbols exist on 10.9, so +imageWithSystemSymbolName: (and the private
// variant) return nil for every name — matching the real API's unknown-symbol contract. Callers that pass the
// result to -setImage:/-_setActionImage:/+imageViewWithImage: tolerate nil; the one caller that dereferences
// the image (RenderThemeMac's attachment-progress placeholder) carries its own MAVERICKS_BACKPORT nil-guard.
// +[NSImageView imageViewWithImage:] (10.12+) builds the view the classic way; -setSymbolConfiguration: and
// -setContentTintColor: are cosmetic template-image properties with nothing to configure for a nil image.
@interface NSImage (WKPolyfillScope)
+ (NSImage *)wk_imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc;
+ (NSImage *)wk_imageWithPrivateSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc;
@end
@implementation NSImage (WKPolyfillScope)
+ (NSImage *)wk_imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { return nil; }
+ (NSImage *)wk_imageWithPrivateSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { return nil; }
@end
WK_POLYFILL_SEL("imageWithSystemSymbolName:accessibilityDescription:", "wk_imageWithSystemSymbolName:accessibilityDescription:");
WK_POLYFILL_SEL("imageWithPrivateSystemSymbolName:accessibilityDescription:", "wk_imageWithPrivateSystemSymbolName:accessibilityDescription:");

@interface NSImageView (WKPolyfillScope)
+ (NSImageView *)wk_imageViewWithImage:(NSImage *)image;
- (void)wk_setSymbolConfiguration:(id)configuration;
- (void)wk_setContentTintColor:(NSColor *)color;
@end
@implementation NSImageView (WKPolyfillScope)
+ (NSImageView *)wk_imageViewWithImage:(NSImage *)image
{
    NSImageView *view = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
    [view setImage:image];
    return view;
}
- (void)wk_setSymbolConfiguration:(id)configuration { (void)configuration; }
- (void)wk_setContentTintColor:(NSColor *)color { (void)color; }
@end
WK_POLYFILL_SEL("imageViewWithImage:", "wk_imageViewWithImage:");
WK_POLYFILL_SEL("setSymbolConfiguration:", "wk_setSymbolConfiguration:");
WK_POLYFILL_SEL("setContentTintColor:", "wk_setContentTintColor:");

// ---------------------------------------------------------------------------------------------------
// CAContext cross-process fence ports (createFencePort/setFencePort:/invalidateFences, ~10.10+): 10.9's
// QuartzCore has no cross-process CA fencing. A null port end-to-end (producer's createFencePort plus every
// consumer's setFencePort:/invalidateFences) is behavior-identical to the pre-fence path: no live-resize
// flicker suppression, correct eventual rendering, and — because nobody waits on a real port — no hang.
// CAContext is SPI (absent from the public QuartzCore headers), so it is declared here.
@interface CAContext : NSObject
@end
@interface CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort;
- (void)wk_setFencePort:(mach_port_t)port;
- (void)wk_invalidateFences;
@end
@implementation CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort { return MACH_PORT_NULL; }
- (void)wk_setFencePort:(mach_port_t)port { (void)port; }
- (void)wk_invalidateFences { }
@end
WK_POLYFILL_SEL("createFencePort", "wk_createFencePort");
WK_POLYFILL_SEL("setFencePort:", "wk_setFencePort:");
WK_POLYFILL_SEL("invalidateFences", "wk_invalidateFences");

// ---------------------------------------------------------------------------------------------------
// -[NSOperationQueue underlyingQueue] (10.10+): the main operation queue is backed by the main dispatch
// queue on 10.9; any other queue has no underlying dispatch queue (nil) — the honest 10.9 answer.
@interface NSOperationQueue (WKPolyfillScope)
- (dispatch_queue_t)wk_underlyingQueue;
@end
@implementation NSOperationQueue (WKPolyfillScope)
- (dispatch_queue_t)wk_underlyingQueue
{
    return self == [NSOperationQueue mainQueue] ? dispatch_get_main_queue() : nil;
}
@end
WK_POLYFILL_SEL("underlyingQueue", "wk_underlyingQueue");

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPCookieStorage _saveCookies:] (block variant, ~10.13+): 10.9 has the argument-less -_saveCookies,
// which hands the cookies to nsurlstoraged for the on-disk write. Call it, then run the completion (the
// caller's block redispatches to the main run loop itself).
@interface NSHTTPCookieStorage (WKPolyfillScope)
- (void)_saveCookies;   // 10.9 argument-less private SPI (do not polyfill it: this body calls it)
- (void)wk__saveCookies:(dispatch_block_t)completionHandler;
@end
@implementation NSHTTPCookieStorage (WKPolyfillScope)
- (void)wk__saveCookies:(dispatch_block_t)completionHandler
{
    [self _saveCookies];
    if (completionHandler)
        completionHandler();
}
@end
WK_POLYFILL_SEL("_saveCookies:", "wk__saveCookies:");

// ---------------------------------------------------------------------------------------------------
// Secure-coding archiver convenience API (10.11+/10.13+) built on the classic secure-coding primitives
// present since 10.8. EVERY polyfill enforces requiresSecureCoding:YES (or honors the caller's BOOL) — never
// a secure->insecure downgrade. The modern convenience methods return nil + *error on a malformed archive
// rather than raising; the classic primitives RAISE (NSInvalidUnarchiveOperationException etc.). The
// @try/@catch here is therefore REQUIRED to implement the modern non-throwing contract faithfully — it
// converts the classic exception into the nil+error the caller expects (it is not a blanket swallow: the
// callers explicitly branch on nil/error). -[NSKeyedUnarchiver initForReadingWithData:] and
// -[NSKeyedArchiver initForWritingWithMutableData:] are deprecated (hence the -Wdeprecated push above).
@interface NSKeyedUnarchiver (WKPolyfillScope)
- (instancetype)wk_initForReadingFromData:(NSData *)data error:(NSError **)error;
- (void)wk_setDecodingFailurePolicy:(NSInteger)policy;
+ (id)wk_unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error;
+ (id)wk_unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end
@implementation NSKeyedUnarchiver (WKPolyfillScope)
- (instancetype)wk_initForReadingFromData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    @try {
        self = [self initForReadingWithData:data];
        [self setRequiresSecureCoding:YES];   // initForReadingFromData:error: defaults to secure — never downgrade
    } @catch (NSException *exception) {
        // Modern initForReadingFromData:error: is NON-throwing (returns nil + *error). The classic
        // initForReadingWithData: RAISES "incomprehensible archive" on malformed/truncated input, so it must
        // be inside the @try or an untrusted-IPC/.webarchive decode would crash instead of failing cleanly.
        // (self was consumed by the throwing initializer; releasing a half-initialized archiver is unsafe, so
        // return nil directly — the rare-error-path leak of the alloc'd shell is preferable to a crash.)
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"incomprehensible archive" }];
        return nil;
    }
    return self;
}
- (void)wk_setDecodingFailurePolicy:(NSInteger)policy
{
    // 10.9's sole decoding-failure behavior is NSDecodingFailurePolicyRaiseException — exactly what every
    // WebKit caller requests; the decode polyfills @catch that raise. Nothing to configure.
    (void)policy;
}
+ (id)wk_unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    NSKeyedUnarchiver *unarchiver = nil;
    id object = nil;
    @try {
        // Modern +unarchivedObjectOfClasses:fromData:error: is NON-throwing (nil + *error). Both the classic
        // initForReadingWithData: (RAISES "incomprehensible archive" on malformed/truncated input) and
        // decodeObjectOfClasses: (raises on a class/format violation) are inside the @try, or an untrusted
        // IPC/on-disk decode would crash instead of failing cleanly.
        unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        [unarchiver setRequiresSecureCoding:YES];   // secure + class-restricted, matching the modern convenience
        object = [unarchiver decodeObjectOfClasses:classes forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        object = nil;
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"decode failed" }];
    } @finally {
        [unarchiver finishDecoding];   // send-to-nil no-op if the init raised (unarchiver stays nil)
        [unarchiver release];
    }
    return object;
}
+ (id)wk_unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return [self wk_unarchivedObjectOfClasses:(cls ? [NSSet setWithObject:cls] : nil) fromData:data error:error];
}
@end
WK_POLYFILL_SEL("initForReadingFromData:error:", "wk_initForReadingFromData:error:");
WK_POLYFILL_SEL("setDecodingFailurePolicy:", "wk_setDecodingFailurePolicy:");
WK_POLYFILL_SEL("unarchivedObjectOfClass:fromData:error:", "wk_unarchivedObjectOfClass:fromData:error:");
WK_POLYFILL_SEL("unarchivedObjectOfClasses:fromData:error:", "wk_unarchivedObjectOfClasses:fromData:error:");

static char kWKKeyedArchiverDataKey;
@interface NSKeyedArchiver (WKPolyfillScope)
+ (NSData *)wk_archivedDataWithRootObject:(id)root requiringSecureCoding:(BOOL)requireSecure error:(NSError **)error;
- (instancetype)wk_initRequiringSecureCoding:(BOOL)requireSecure;
- (NSData *)wk_encodedData;
@end
@implementation NSKeyedArchiver (WKPolyfillScope)
// -initRequiringSecureCoding: / -encodedData (10.13+): the classic pairing is an explicit mutable
// data buffer plus finishEncoding. The buffer rides along as an associated object so encodedData can
// answer it; encodedData finishes encoding on first read, exactly the modern property's contract.
- (instancetype)wk_initRequiringSecureCoding:(BOOL)requireSecure
{
    NSMutableData *data = [NSMutableData data];
    self = [self initForWritingWithMutableData:data];
    if (self) {
        [self setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
        objc_setAssociatedObject(self, &kWKKeyedArchiverDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (NSData *)wk_encodedData
{
    // -finishEncoding unconditionally: measured on this host, 10.9's is idempotent (three consecutive
    // calls all succeed and leave the archive intact), so there is nothing to guard against and a
    // caller that finished the archive itself is not penalised.
    [self finishEncoding];
    // nil for an archiver built through some other initializer: only the paired init above records a
    // buffer, and that pairing is the modern API's own (initRequiringSecureCoding: -> encodedData).
    // Copied because the modern property vends immutable NSData; handing back the live NSMutableData
    // would let a caller mutate the archive it just asked for.
    NSMutableData *backing = objc_getAssociatedObject(self, &kWKKeyedArchiverDataKey);
    return backing ? [[backing copy] autorelease] : nil;
}
+ (NSData *)wk_archivedDataWithRootObject:(id)root requiringSecureCoding:(BOOL)requireSecure error:(NSError **)error
{
    if (error)
        *error = nil;
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    [archiver setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
    NSData *result = nil;
    @try {
        [archiver encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        result = data;
    } @catch (NSException *exception) {
        result = nil;
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"archive failed" }];
    }
    [archiver release];
    return result;
}
@end
WK_POLYFILL_SEL("archivedDataWithRootObject:requiringSecureCoding:error:", "wk_archivedDataWithRootObject:requiringSecureCoding:error:");
WK_POLYFILL_SEL("initRequiringSecureCoding:", "wk_initRequiringSecureCoding:");
WK_POLYFILL_SEL("encodedData", "wk_encodedData");

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPURLResponse valueForHTTPHeaderField:] (10.13+): 10.9 lacks it, but -allHeaderFields is present;
// look the field up there case-insensitively (HTTP header names are case-insensitive), matching the modern
// method's contract.
@interface NSHTTPURLResponse (WKPolyfillScope)
- (NSString *)wk_valueForHTTPHeaderField:(NSString *)field;
@end
@implementation NSHTTPURLResponse (WKPolyfillScope)
- (NSString *)wk_valueForHTTPHeaderField:(NSString *)field
{
    NSDictionary *headers = [self allHeaderFields];
    NSString *direct = [headers objectForKey:field];
    if (direct)
        return direct;
    for (NSString *key in headers)
        if ([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:field] == NSOrderedSame)
            return [headers objectForKey:key];
    return nil;
}
@end
WK_POLYFILL_SEL("valueForHTTPHeaderField:", "wk_valueForHTTPHeaderField:");

// ---------------------------------------------------------------------------------------------------
// -[NSScrollerImp/NSMenu setUserInterfaceLayoutDirection:] + getter (10.10+/10.11+, absent on these two
// classes on 10.9). 10.9 has no RTL platform scroller/menu layout, so the value has no visual effect
// here; store it via an associated object so WebKit's own read-back
// (ScrollerMac/ScrollbarThemeMac/ScrollbarsControllerMac/PopupMenu) is faithful, defaulting to
// LeftToRight when unset. (Vertical-scrollbar-on-left is positioned by WebCore geometry independently.)
// NSScrollerImp is SPI (absent from public AppKit headers), so declare it here.
@interface NSScrollerImp : NSObject
- (CALayer *)layer;   // real 10.9 NSScrollerImp accessor (the layer WebKit assigns it via -setLayer:)
@end
static const void *const wk_uildScrollerKey = &wk_uildScrollerKey;
static const void *const wk_uildMenuKey = &wk_uildMenuKey;
@interface NSScrollerImp (WKPolyfillScope)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction;
- (NSInteger)wk_userInterfaceLayoutDirection;
// -[NSScrollerImp setNeedsDisplay:] (a later-macOS addition). On 10.9 the scroller imp WebKit uses (e.g.
// NSRegularOverlayScrollerImp) does not respond to it, so an unconditional send would raise
// doesNotRecognizeSelector (ScrollbarsControllerMac::invalidateScrollbarPartLayers and
// ScrollerMac::setNeedsDisplay both send it; the latter killed WebContent in a loop on Slack's dark
// theme). The modern method marks the imp's backing for redraw; on 10.9 the imp draws into the layer
// WebKit assigns it (-[NSScrollerImp setLayer:], present here), so marking THAT layer dirty is the
// faithful 10.9 equivalent — exactly what ScrollerMac's fallback did by hand. -layer is nil in the WK1
// path (no imp layer set), where [nil setNeedsDisplay] is a harmless no-op and the repaint comes from
// ScrollbarThemeMac::paint. (GAP_FILL: 10.9 lacks -setNeedsDisplay: on NSScrollerImp — the build gate
// confirms the absence — and the body always runs.)
- (void)wk_setNeedsDisplay:(BOOL)flag;
@end
@implementation NSScrollerImp (WKPolyfillScope)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction
{ objc_setAssociatedObject(self, wk_uildScrollerKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)wk_userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildScrollerKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
- (void)wk_setNeedsDisplay:(BOOL)flag { if (flag) [[self layer] setNeedsDisplay]; }
@end
WK_POLYFILL_SEL("setNeedsDisplay:", "wk_setNeedsDisplay:");
@interface NSMenu (WKPolyfillScopeUILD)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction;
- (NSInteger)wk_userInterfaceLayoutDirection;
@end
@implementation NSMenu (WKPolyfillScopeUILD)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction
{ objc_setAssociatedObject(self, wk_uildMenuKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)wk_userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildMenuKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
@end
WK_POLYFILL_SEL("setUserInterfaceLayoutDirection:", "wk_setUserInterfaceLayoutDirection:");
WK_POLYFILL_SEL("userInterfaceLayoutDirection", "wk_userInterfaceLayoutDirection");

// ---------------------------------------------------------------------------------------------------
// -[NSLocale languageCode]/scriptCode/countryCode (10.12+) via the classic component keys (10.4+).
// (Do not polyfill "objectForKey:": these bodies call it.)
@interface NSLocale (WKPolyfillScope)
- (NSString *)wk_languageCode;
- (NSString *)wk_scriptCode;
- (NSString *)wk_countryCode;
@end
@implementation NSLocale (WKPolyfillScope)
- (NSString *)wk_languageCode { return [self objectForKey:NSLocaleLanguageCode]; }
- (NSString *)wk_scriptCode   { return [self objectForKey:NSLocaleScriptCode]; }
- (NSString *)wk_countryCode  { return [self objectForKey:NSLocaleCountryCode]; }
@end
WK_POLYFILL_SEL("languageCode", "wk_languageCode");
WK_POLYFILL_SEL("scriptCode", "wk_scriptCode");
WK_POLYFILL_SEL("countryCode", "wk_countryCode");

// ---------------------------------------------------------------------------------------------------
// +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] (10.10+ SPI). WebCoreNSURLExtras sends it
// unconditionally to decide whether a request is claimed by a registered NSURLProtocol before it takes
// the App SSO path; on 10.9 the selector does not exist and the send throws. App SSO (the Kerberos/AAA
// extension point the flag names) does not exist on 10.9 at all, so no protocol class can be the App SSO
// one: Nil is the whole answer, and WebCoreNSURLExtras falls back to the standard URL-loading path.
//
// A plain category, not WK_POLYFILL_ADD: NSURLProtocol is a class this build's SDK and the 10.9 runtime
// agree on (both home _OBJC_CLASS_$_NSURLProtocol in Foundation — checked in MacOSX26.1.sdk's
// Foundation.tbd and in 10.9.5's Foundation export table), so there is no moved-framework classref to
// avoid, and a category is what expresses a CLASS method here: WK_POLYFILL_ADD installs through
// objc_getClass(), i.e. on the class, so it can only add INSTANCE methods.
@interface NSURLProtocol (WKPolyfillScopeAppSSO)
+ (Class)wk__protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO;
@end
@implementation NSURLProtocol (WKPolyfillScopeAppSSO)
+ (Class)wk__protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO
{
    (void)request;
    (void)skipAppSSO;
    return Nil;
}
@end
WK_POLYFILL_SEL("_protocolClassForRequest:skipAppSSO:", "wk__protocolClassForRequest:skipAppSSO:");

// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionTask priority]/-setPriority: (10.10+, absent on 10.9's NSURLSessionTask). NSURLSessionTask
// is a MOVED-FRAMEWORK class (CFNetwork on the 26.1 SDK, Foundation at 10.9 runtime), so it must be
// resolved at runtime BY NAME — hence WK_POLYFILL_ADD (runtime class_addMethod) rather than a compile-time
// category. 10.9's URL loading has no per-task scheduling priority, so the value can't affect
// scheduling; store it in an associated object so the property round-trips for its only reader (the Web
// Inspector task metrics), defaulting to NSURLSessionTaskPriorityDefault (0.5). On 10.9 the concrete task
// instances do NOT subclass the public NSURLSessionTask class — their hierarchy is
// __NSCFLocalDataTask : __NSCFLocalSessionTask : __NSCFURLSessionTask : NSObject (CFNetwork) — so the
// methods must be added to __NSCFURLSessionTask, the root of the concrete hierarchy, to reach real
// instances (adding only to NSURLSessionTask leaves them unrecognized -> NetworkProcess crash in the
// NetworkDataTaskCocoa constructor). NSURLSessionTask keeps the registration too, for the abstract class
// itself and for any OS variant whose concrete tasks do inherit from it.
static const void *const wk_taskPriorityKey = &wk_taskPriorityKey;
static float wk_urlSessionTask_priority(id self, SEL _cmd)
{
    (void)_cmd;
    NSNumber *v = objc_getAssociatedObject(self, wk_taskPriorityKey);
    return v ? [v floatValue] : 0.5f;
}
static void wk_urlSessionTask_setPriority(id self, SEL _cmd, float priority)
{
    (void)_cmd;
    objc_setAssociatedObject(self, wk_taskPriorityKey, @(priority), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
WK_POLYFILL_ADD("NSURLSessionTask", "wk_priority", wk_urlSessionTask_priority, "f@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_setPriority:", wk_urlSessionTask_setPriority, "v@:f");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_priority", wk_urlSessionTask_priority, "f@:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_setPriority:", wk_urlSessionTask_setPriority, "v@:f");
WK_POLYFILL_SEL("priority", "wk_priority");
WK_POLYFILL_SEL("setPriority:", "wk_setPriority:");

// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionDownloadTask cancelByProducingResumeData:] — 10.9's implementation ABORTS the process
// when the download cannot produce resume information (github #94: cancelling any such download killed
// the NetworkProcess, and with it Safari).
//
// What 10.9 does, read off CFNetwork 673.3: -[__NSCFLocalDownloadTask _private_fileCompletion] asks
// -createResumeInformation: for the resume dictionary and stuffs the result into the cancellation
// error's userInfo under NSURLSessionDownloadTaskResumeData — with no nil check.
// createResumeInformation: returns nil whenever resuming is impossible, and for a plain HTTP download
// that is the ordinary case: it requires an http/https GET whose response carries an ETag or a
// Last-Modified (a validator, without which no server can be asked to continue), or, for a non-HTTP
// response, a task that was itself created from resume data (_originalResumeInfo). nil then reaches
// -[NSMutableDictionary setObject:forKey:] -> NSInvalidArgumentException -> abort(). Later OS versions
// fixed this by reporting no resume data; this restores that behaviour by not entering the broken path:
// when 10.9 cannot produce resume information, cancel plainly and report no resume data, which is
// exactly what the API's callers already handle (WebKit's Download::platformCancelNetworkLoad passes an
// empty span on). When it CAN, 10.9's own implementation runs, so resuming a download still works.
//
// The gate replicates createResumeInformation:'s preconditions rather than calling it, because calling
// it is not side-effect-free on the path that succeeds (it captures the partial file and sets
// skipUnlink, which the real cancel would then redo). Note allHeaderFields is a CASE-INSENSITIVE
// dictionary on 10.9 (verified: a server's "ETag:" is listed as "Etag" and both spellings look it up),
// so these lookups see the same headers CFNetwork's own do.
static BOOL wk_downloadTaskCanProduceResumeInformation(id task)
{
    NSURLRequest *request = [task currentRequest];
    NSString *scheme = [[request URL] scheme];
    BOOL isHTTPFamily = [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame || [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
    if (!isHTTPFamily)
        return NO;
    // A nil HTTPMethod compares equal here, matching CFNetwork's own nil-receiver comparison.
    NSString *method = [request HTTPMethod];
    if (method && [method caseInsensitiveCompare:@"GET"] != NSOrderedSame)
        return NO;

    id response = [task response];
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
        return [headers objectForKey:@"Etag"] != nil || [headers objectForKey:@"Last-Modified"] != nil;
    }

    // Non-HTTP response: 10.9 can only re-emit the resume information the task was created from.
    Ivar originalResumeInfo = class_getInstanceVariable(object_getClass(task), "_originalResumeInfo");
    return originalResumeInfo && object_getIvar(task, originalResumeInfo) != nil;
}

static void wk_downloadTask_cancelByProducingResumeData(id self, SEL _cmd, void (^completionHandler)(NSData *resumeData))
{
    (void)_cmd;
    if (wk_downloadTaskCanProduceResumeInformation(self)) {
        // sel_registerName rather than @selector: this file is compiled into WebCore, whose
        // __objc_selrefs are rewritten, so a compiled `cancelByProducingResumeData:` selref arrives
        // here as the wk_ name and would recurse. Idempotent — see the other users of this pattern.
        static SEL cancelByProducingResumeDataSelector;
        if (!cancelByProducingResumeDataSelector)
            cancelByProducingResumeDataSelector = sel_registerName("cancelByProducingResumeData:");
        void (*cancelByProducingResumeData)(id, SEL, void (^)(NSData *)) = (void (*)(id, SEL, void (^)(NSData *)))objc_msgSend;
        cancelByProducingResumeData(self, cancelByProducingResumeDataSelector, completionHandler);
        return;
    }

    static SEL cancelSelector;
    if (!cancelSelector)
        cancelSelector = sel_registerName("cancel");
    void (*cancel)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    cancel(self, cancelSelector);
    if (completionHandler)
        completionHandler(nil);
}

// Both concrete download-task classes 10.9 vends (a local session and a background/URL session), each
// of which implements the real selector itself — hence _REPLACES, so the body wins over the aliased
// real method. The public NSURLSessionDownloadTask does NOT implement it on 10.9 and is not in the
// concrete classes' superclass chain (__NSCFLocalDownloadTask : __NSCFLocalSessionTask :
// __NSCFURLSessionTask : NSObject), so registering it there would reach no instance.
WK_POLYFILL_ADD_REPLACES("__NSCFLocalDownloadTask", "wk_cancelByProducingResumeData:", wk_downloadTask_cancelByProducingResumeData, "v@:@?");
WK_POLYFILL_ADD_REPLACES("__NSCFURLSessionDownloadTask", "wk_cancelByProducingResumeData:", wk_downloadTask_cancelByProducingResumeData, "v@:@?");
WK_POLYFILL_SEL_REPLACES("cancelByProducingResumeData:", "wk_cancelByProducingResumeData:");

// ---------------------------------------------------------------------------------------------------
// NSURLSession SPI that arrived after 10.9, on NSURLSessionConfiguration, NSMutableURLRequest, the
// session tasks and NSHTTPCookieStorage.
//
// Every selector below was probed on this 10.9 host and is absent. They configure behaviour 10.9 has no
// notion of -- App SSO, tracker blocking and enhanced privacy mode, the privacy proxy, W3C timing data,
// source-application attribution, per-task metrics, CNAME cloaking resolution -- so the honest 10.9
// answer to each is "nothing happens", which is exactly what these do: the setters accept and discard,
// and the getters report the absence (nil, NO, 0) that the caller already has to handle. That is correct
// for any caller, not just for WebKit's, which is why it belongs here rather than in a pile of
// respondsToSelector: checks at the call sites -- those were removed with this.
//
// Deliberately NOT stubbed: +[NSURLSession _strictTrustEvaluate:queue:completionHandler:], because
// "nothing happens" is not a safe answer for a trust evaluation. NetworkSessionCocoa keeps its check
// there and falls back to evaluating the trust itself.

static void wk_noopSetObject(id self, SEL _cmd, id value) { (void)self; (void)_cmd; (void)value; }
static void wk_noopSetBool(id self, SEL _cmd, BOOL value) { (void)self; (void)_cmd; (void)value; }
static void wk_noopSetUnsigned(id self, SEL _cmd, NSUInteger value) { (void)self; (void)_cmd; (void)value; }
static id wk_absentObject(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }
static BOOL wk_absentFlag(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }

#if __LP64__
#define WK_UNSIGNED_SETTER_TYPES "v@:Q"
#else
#define WK_UNSIGNED_SETTER_TYPES "v@:I"
#endif

#define WK_POLYFILL_NOOP_SETTER(CLS, SEL_NAME, IMP, TYPES) \
    WK_POLYFILL_ADD(CLS, "wk_" SEL_NAME, IMP, TYPES); \
    WK_POLYFILL_SEL(SEL_NAME, "wk_" SEL_NAME)

// NSURLSessionConfiguration.
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_shouldSkipPreferredClientCertificateLookup:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_shouldSkipPreferredClientCertificateLookup:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_connectionCacheNumPriorityLevels:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_connectionCacheNumPriorityLevels:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_connectionCacheMinimumFastLanePriority:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_connectionCacheMinimumFastLanePriority:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_connectionCacheNumFastLanes:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_connectionCacheNumFastLanes:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_preventsAppSSO:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_preventsAppSSO:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_suppressedAutoAddedHTTPHeaders:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_suppressedAutoAddedHTTPHeaders:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_sourceApplicationAuditTokenData:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_sourceApplicationAuditTokenData:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_sourceApplicationBundleIdentifier:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_sourceApplicationBundleIdentifier:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_sourceApplicationSecondaryIdentifier:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_sourceApplicationSecondaryIdentifier:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_preventsSystemHTTPProxyAuthentication:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_preventsSystemHTTPProxyAuthentication:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_requiresSecureHTTPSProxyConnection:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_requiresSecureHTTPSProxyConnection:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_timingDataOptions:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_timingDataOptions:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_skipsStackTraceCapture:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_skipsStackTraceCapture:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "_sourceApplicationSecondaryIdentifier", wk_absentObject, "@@:");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "_sourceApplicationSecondaryIdentifier", wk_absentObject, "@@:");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "_allowsHSTSWithUntrustedRootCertificate", wk_absentFlag, "c@:");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "_allowsHSTSWithUntrustedRootCertificate", wk_absentFlag, "c@:");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_allowsHSTSWithUntrustedRootCertificate:", wk_noopSetBool, "v@:c");
// The two storage handles the session configuration can be given. 10.9's configuration has no slot for
// either (probed absent on both the public and the concrete class), and the stub storages themselves keep
// nothing, so accepting and discarding is consistent: no HSTS state and no known alternative services.
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_hstsStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_hstsStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "_hstsStorage", wk_absentObject, "@@:");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "_hstsStorage", wk_absentObject, "@@:");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "set_alternativeServicesStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_alternativeServicesStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_NOOP_SETTER("NSURLSessionConfiguration", "_alternativeServicesStorage", wk_absentObject, "@@:");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "_alternativeServicesStorage", wk_absentObject, "@@:");
WK_POLYFILL_ADD("__NSCFURLSessionConfiguration", "wk_" "set_allowsHSTSWithUntrustedRootCertificate:", wk_noopSetBool, "v@:c");


// NSMutableURLRequest.
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setUseEnhancedPrivacyMode:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setBlockTrackers:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setNeedsNetworkTrackingPrevention:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_needsNetworkTrackingPrevention", wk_absentFlag, "c@:");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setPrivacyProxyFailClosedForUnreachableNonMainHosts:", wk_noopSetBool, "v@:c");
// The read side of the same flag. NSURLRequest, not NSMutableURLRequest: the getter is read off immutable
// requests too. NO is the honest answer -- there is no Private Relay on 10.9 to have failed closed.
WK_POLYFILL_ADD("NSURLRequest", "wk__privacyProxyFailClosedForUnreachableNonMainHosts", wk_absentFlag, "c@:");
WK_POLYFILL_ADD("NSMutableURLRequest", "wk__privacyProxyFailClosedForUnreachableNonMainHosts", wk_absentFlag, "c@:");
WK_POLYFILL_SEL("_privacyProxyFailClosedForUnreachableNonMainHosts", "wk__privacyProxyFailClosedForUnreachableNonMainHosts");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setProhibitPrivacyProxy:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setPrivacyProxyStrictFailClosed:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setPrivacyProxyFailClosedForUnreachableHosts:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setPrivacyProxyFailClosed:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setWebSearchContent:", wk_noopSetBool, "v@:c");
WK_POLYFILL_NOOP_SETTER("NSMutableURLRequest", "_setAllowPrivateAccessTokensForThirdParty:", wk_noopSetBool, "v@:c");

// The session tasks. Registered on the shared root of the concrete classes for the same reason
// -_pathToDownloadTaskFile is, and on the public class WebKit compiles against.
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__incompleteTaskMetrics", wk_absentObject, "@@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__incompleteTaskMetrics", wk_absentObject, "@@:");
WK_POLYFILL_SEL("_incompleteTaskMetrics", "wk__incompleteTaskMetrics");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__resolvedCNAMEChain", wk_absentObject, "@@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__resolvedCNAMEChain", wk_absentObject, "@@:");
WK_POLYFILL_SEL("_resolvedCNAMEChain", "wk__resolvedCNAMEChain");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__adoptEffectiveConfiguration:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__adoptEffectiveConfiguration:", wk_noopSetObject, "v@:@");
WK_POLYFILL_SEL("_adoptEffectiveConfiguration:", "wk__adoptEffectiveConfiguration:");
// MAVERICKS_BACKPORT: -_preconnect is the one that cannot be a no-op. Accepting it and doing nothing else would leave a task
// that is only supposed to warm a connection running as an ordinary request, i.e. a full GET of the target
// URL -- not a harmless extra fetch: against a server that rotates a Set-Cookie session on every response
// it rotates the session out from under the page that was just rendered, whose CSRF-protected forms then
// fail with HTTP 422, and it double-requests every main resource. 10.9 cannot warm a connection without
// transferring, so the honest emulation of "preconnect" here is to perform NO transfer: the flag is
// recorded and the task is cancelled instead of ever being sent. A hint that does nothing is what a
// preconnect is allowed to be; a hint that fetches the whole resource is not.
//
// Turning ENABLE(SERVER_PRECONNECT) off so no such task exists is not available in this tree: with it off
// PreconnectTask.cpp compiles to nothing while six unguarded call sites still reference it
// (NetworkCacheSpeculativeLoadManager.cpp:488, EarlyHintsResourceLoader.cpp:148,
// NetworkConnectionToWebProcess.cpp:725 and :755, NetworkProcess.cpp:1651 and :1658), so the link fails on
// PreconnectTask::create/start/setH2PingCallback, and the flag also gates away the _preconnect property
// declaration that NetworkSessionCocoa:586 reads outside any guard.
static const void *wk_taskIsPreconnectKey = &wk_taskIsPreconnectKey;

static void wk_urlSessionTask_setPreconnect(id self, SEL _cmd, BOOL preconnect)
{
    (void)_cmd;
    objc_setAssociatedObject(self, wk_taskIsPreconnectKey, preconnect ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!preconnect)
        return;
    static SEL cancelSelector;
    if (!cancelSelector)
        cancelSelector = sel_registerName("cancel");
    ((void (*)(id, SEL))objc_msgSend)(self, cancelSelector);
}

static BOOL wk_urlSessionTask_preconnect(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, wk_taskIsPreconnectKey) != nil;
}

WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_set_preconnect:", wk_urlSessionTask_setPreconnect, "v@:c");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_set_preconnect:", wk_urlSessionTask_setPreconnect, "v@:c");
WK_POLYFILL_SEL("set_preconnect:", "wk_set_preconnect:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__preconnect", wk_urlSessionTask_preconnect, "c@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__preconnect", wk_urlSessionTask_preconnect, "c@:");
WK_POLYFILL_SEL("_preconnect", "wk__preconnect");

// Bytes as they arrived on the wire. 10.9 counts only the decoded body, which is the same number for a
// response that is not content-encoded and the closest true value for one that is -- far closer than the
// zero an "absent" answer would report into the transfer-size accounting.
static int64_t wk_urlSessionTask_countOfBytesReceivedEncoded(id self, SEL _cmd)
{
    (void)_cmd;
    static SEL countSelector;
    if (!countSelector)
        countSelector = sel_registerName("countOfBytesReceived");
    return ((int64_t (*)(id, SEL))objc_msgSend)(self, countSelector);
}

WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__countOfBytesReceivedEncoded", wk_urlSessionTask_countOfBytesReceivedEncoded, "q@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__countOfBytesReceivedEncoded", wk_urlSessionTask_countOfBytesReceivedEncoded, "q@:");
WK_POLYFILL_SEL("_countOfBytesReceivedEncoded", "wk__countOfBytesReceivedEncoded");

// NSHTTPCookieStorage.
WK_POLYFILL_NOOP_SETTER("NSHTTPCookieStorage", "set_overrideSessionCookieAcceptPolicy:", wk_noopSetUnsigned, WK_UNSIGNED_SETTER_TYPES);

// Per-task cookie controls (10.13+). 10.9's CFNetwork has no per-task cookie storage, no SameSite
// notion, and no cookie-transform hook, so each of these accepts and discards -- the same thing the
// real API does on a system without the feature behind it. The visible consequence is that tracking
// prevention cannot swap a task onto a stateless jar and SameSite attributes are not enforced at the
// network layer; both are honest statements about 10.9 rather than something hidden from the caller.
static id wk_absentBlock(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }

WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_set_cookieTransformCallback:", wk_noopSetObject, "v@:@?");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_set_cookieTransformCallback:", wk_noopSetObject, "v@:@?");
WK_POLYFILL_SEL("set_cookieTransformCallback:", "wk_set_cookieTransformCallback:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__cookieTransformCallback", wk_absentBlock, "@?@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__cookieTransformCallback", wk_absentBlock, "@?@:");
WK_POLYFILL_SEL("_cookieTransformCallback", "wk__cookieTransformCallback");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__setExplicitCookieStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("NSURLSessionTask", "wk__setExplicitCookieStorage:", wk_noopSetObject, "v@:@");
WK_POLYFILL_SEL("_setExplicitCookieStorage:", "wk__setExplicitCookieStorage:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_set_siteForCookies:", wk_noopSetObject, "v@:@");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_set_siteForCookies:", wk_noopSetObject, "v@:@");
WK_POLYFILL_SEL("set_siteForCookies:", "wk_set_siteForCookies:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_set_isTopLevelNavigation:", wk_noopSetBool, "v@:c");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_set_isTopLevelNavigation:", wk_noopSetBool, "v@:c");
WK_POLYFILL_SEL("set_isTopLevelNavigation:", "wk_set_isTopLevelNavigation:");

// ---------------------------------------------------------------------------------------------------
// +[NSURLSession _strictTrustEvaluate:queue:completionHandler:] (10.10+).
//
// Evaluates a server-trust challenge off the calling thread and reports the result as an OSStatus, so a
// client can decide the challenge itself instead of leaving it to CFNetwork's default handling. 10.9 has
// everything that needs: the challenge carries the SecTrustRef, and SecTrustEvaluate is the same
// evaluation the system performs. So this runs it -- on the queue the caller supplied, as the name says
// -- rather than answering "cannot evaluate", which for a trust decision would be the one wrong answer
// to give.
//
// noErr means trusted, which is how the caller reads it. kSecTrustResultProceed is an explicit user/admin
// trust decision and kSecTrustResultUnspecified is "valid chain, no explicit decision"; every other
// result (recoverable failure, fatal failure, deny, invalid setup) is not trusted, and errSecNotTrusted
// is what the modern SPI reports for those.
static void wk_urlSession_strictTrustEvaluate(id self, SEL _cmd, NSURLAuthenticationChallenge *challenge, dispatch_queue_t queue, void (^completionHandler)(NSURLAuthenticationChallenge *, OSStatus))
{
    (void)self;
    (void)_cmd;
    // challenge is captured by the block, which retains it; the SecTrustRef is owned by the challenge, so
    // it is retained across the hop explicitly.
    SecTrustRef trust = [[challenge protectionSpace] serverTrust];
    if (trust)
        CFRetain(trust);
    dispatch_async(queue ?: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        OSStatus status = errSecNotTrusted;
        SecTrustResultType trustResult = kSecTrustResultInvalid;
        if (trust && SecTrustEvaluate(trust, &trustResult) == errSecSuccess
            && (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified))
            status = noErr;
        completionHandler(challenge, status);
        if (trust)
            CFRelease(trust);
    });
}

WK_POLYFILL_ADD_CLASS_METHOD("NSURLSession", "wk__strictTrustEvaluate:queue:completionHandler:", wk_urlSession_strictTrustEvaluate, "v@:@@@?");
WK_POLYFILL_SEL("_strictTrustEvaluate:queue:completionHandler:", "wk__strictTrustEvaluate:queue:completionHandler:");

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPCookieStorage _initWithIdentifier:private:] (10.13+).
//
// Arities read off the disassembly rather than guessed: _CFURLStorageSessionCreate uses rdi/rsi/rdx
// (three), each Copy*Storage uses rdi/rsi (two). Shared by the cookie and credential initializers below.
// The properties dictionary a storage session is created with. CFNetwork keys privacy off the literal
// _kCFURLStorageSessionIsPrivate value, so build the dictionary the API actually reads -- the same key
// upstream WebCore uses in NetworkStorageSessionCocoa. Resolved through the soft-link path because the
// SDK stub is not a reliable guide to what 10.9's CFNetwork exports.
static CFStringRef wk_storageSessionIsPrivateKey(void)
{
    static CFStringRef key;
    static bool resolved;
    if (!resolved) {
        CFStringRef *slot = (CFStringRef *)dlsym(RTLD_DEFAULT, "_kCFURLStorageSessionIsPrivate");
        key = slot ? *slot : NULL;
        resolved = true;
    }
    return key;
}

// Returns NULL ONLY as "could not build the contract"; callers must treat that as a hard failure, never
// as "create the session without the key". Passing NULL properties selects CFNetwork's PERSISTENT branch,
// so a private:YES request that fell back to NULL would silently get an on-disk, app-identifier-keyed jar
// -- the exact defect this key was added to fix.
static CFDictionaryRef wk_storageSessionProperties(BOOL isPrivate, bool *outFailed)
{
    *outFailed = false;
    CFStringRef key = wk_storageSessionIsPrivateKey();
    if (!key) {
        *outFailed = true;
        return NULL;
    }
    const void *keys[] = { key };
    const void *values[] = { isPrivate ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef properties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties)
        *outFailed = true;
    return properties;
}

typedef struct OpaqueCFURLStorageSession *CFURLStorageSessionRef;
typedef struct OpaqueCFURLCredentialStorage *CFURLCredentialStorageRef;
extern CFURLStorageSessionRef _CFURLStorageSessionCreate(CFAllocatorRef, CFStringRef, CFDictionaryRef);
extern CFURLCredentialStorageRef _CFURLStorageSessionCopyCredentialStorage(CFAllocatorRef, CFURLStorageSessionRef);
extern CFHTTPCookieStorageRef _CFURLStorageSessionCopyCookieStorage(CFAllocatorRef, CFURLStorageSessionRef);

// Both parameters mean something and both are honoured, the same way the credential-storage twin below
// honours them -- the identifier names a CFNetwork STORAGE SESSION (not a file), and private selects
// whether that session is backed by the process's persistent state. 10.9 exports the whole pair:
// _CFURLStorageSessionCreate makes a session of its own and _CFURLStorageSessionCopyCookieStorage takes
// that session's cookie storage (both probed present), which is the identical mapping upstream WebKit
// uses for identified sessions in NetworkStorageSessionCocoa. -[NSHTTPCookieStorage
// _initWithCFHTTPCookieStorage:] then wraps the result in the ObjC class.
//
// Doing it this way is what makes the identifier MEAN the same thing here as everywhere else: a component
// that names a store through _CFURLStorageSessionCreate and one that names it through this initializer
// land on the same jar. Ignoring the arguments -- which this used to do -- was correct only for the
// private:YES caller WebKit happens to have, and inventing a per-identifier file path instead would have
// created a second, private naming scheme that agrees with nothing else in the system.
//
// NetworkTaskCocoa::statelessCookieStorage is the private:YES caller that matters: it needs a storage
// whose cookies are never sent with a redirected request. Without this it fell back to the SHARED storage
// and set NSHTTPCookieAcceptPolicyNever on it -- turning cookie acceptance off process-wide.

static id wk_httpCookieStorage_initWithIdentifierPrivate(id self, SEL _cmd, NSString *identifier, BOOL isPrivate)
{
    (void)_cmd;
    static SEL initWithCFStorageSelector;
    if (!initWithCFStorageSelector)
        initWithCFStorageSelector = sel_registerName("_initWithCFHTTPCookieStorage:");

    // The session properties must carry the REAL key, not merely be non-NULL: CFNetwork's
    // StorageSession::copyCookieStorage tests GetValue(props, _kCFURLStorageSessionIsPrivate) ==
    // kCFBooleanTrue and takes the PERSISTENT branch otherwise, so an empty dictionary produced an
    // on-disk, app-identifier-keyed jar that outlived the process -- the opposite of private, and
    // measured surviving across two runs before this was corrected.
    bool propertiesFailed = false;
    CFDictionaryRef privateProperties = wk_storageSessionProperties(isPrivate, &propertiesFailed);
    if (propertiesFailed) {
        // No key means the privacy contract cannot be expressed. Creating the session anyway would hand a
        // private:YES caller a persistent jar and a private:NO caller no guarantee at all, so fail here.
        [self release];
        return nil;
    }
    CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, (CFStringRef)identifier, privateProperties);
    if (privateProperties)
        CFRelease(privateProperties);

    CFHTTPCookieStorageRef storage = session ? _CFURLStorageSessionCopyCookieStorage(kCFAllocatorDefault, session) : NULL;
    if (session)
        CFRelease(session);

    // No in-memory substitution: for private:NO that would be a jar that silently never persists, which is
    // a fake value. A failed session is an initializer failure, reported the way the twin below reports it.
    if (!storage) {
        [self release];
        return nil;
    }

    id result = ((id (*)(id, SEL, CFHTTPCookieStorageRef))objc_msgSend)(self, initWithCFStorageSelector, storage);
    CFRelease(storage);
    return result;
}

WK_POLYFILL_ADD("NSHTTPCookieStorage", "wk__initWithIdentifier:private:", wk_httpCookieStorage_initWithIdentifierPrivate, "@@:@c");
WK_POLYFILL_SEL("_initWithIdentifier:private:", "wk__initWithIdentifier:private:");

// -[NSURLCredentialStorage _initWithIdentifier:private:] (10.13+), the same contract one layer over:
// credentials that belong to this data store alone and are not the process-wide set. Built the same way,
// from primitives 10.9 exports: _CFURLStorageSessionCreate makes a storage session of its own,
// _CFURLStorageSessionCopyCredentialStorage takes that session's credential storage, and
// -[NSURLCredentialStorage _initWithCFURLCredentialStorage:] (probed present) wraps it.
//
// NOT CFURLCredentialStorageCreate, which looks like the obvious call and is the wrong one: read off the
// disassembly it fetches _CFURLStorageSessionGetDefault and copies THAT session's storage, i.e. it hands
// back the shared credentials — the opposite of private. Arities also read off the disassembly rather
// than guessed: _CFURLStorageSessionCreate uses rdi/rsi/rdx (three), the copy uses rdi/rsi (two).

static id wk_credentialStorage_initWithIdentifierPrivate(id self, SEL _cmd, NSString *identifier, BOOL isPrivate)
{
    (void)_cmd;
    static SEL initWithCFStorageSelector;
    if (!initWithCFStorageSelector)
        initWithCFStorageSelector = sel_registerName("_initWithCFURLCredentialStorage:");

    // private:YES has to mean the caller does not see the process's persistent credentials, and 10.9 can
    // express that: measured on this host, a session created with a non-NULL properties dictionary yields
    // a credential storage reporting ZERO protection spaces, while the same call with NULL properties
    // reports the keychain-backed set the shared storage shows. So the flag selects the properties
    // argument -- it is not decoration, and ignoring it would have made this correct only for the
    // private:NO caller WebKit happens to be.
    // Same real key as the cookie twin above. The credential path happens to read any non-NULL dict as
    // private (it tests == kCFBooleanFalse for persistent), but spelling the contract out is what makes
    // both correct for the same reason instead of by opposite accident.
    bool propertiesFailed = false;
    CFDictionaryRef privateProperties = wk_storageSessionProperties(isPrivate, &propertiesFailed);
    if (propertiesFailed) {
        [self release];
        return nil;
    }
    CFURLStorageSessionRef session = _CFURLStorageSessionCreate(kCFAllocatorDefault, (CFStringRef)identifier, privateProperties);
    if (privateProperties)
        CFRelease(privateProperties);
    CFURLCredentialStorageRef storage = session ? _CFURLStorageSessionCopyCredentialStorage(kCFAllocatorDefault, session) : NULL;
    if (session)
        CFRelease(session);
    if (!storage) {
        // -_initWithCFURLCredentialStorage: TRAPS on NULL (measured: SIGTRAP, exit 133), so a failure to
        // build the storage has to come back as nil -- the ordinary "this initializer failed" answer --
        // rather than as a dead NetworkProcess.
        [self release];
        return nil;
    }
    id result = ((id (*)(id, SEL, CFURLCredentialStorageRef))objc_msgSend)(self, initWithCFStorageSelector, storage);
    CFRelease(storage);
    return result;
}

WK_POLYFILL_ADD("NSURLCredentialStorage", "wk__initWithIdentifier:private:", wk_credentialStorage_initWithIdentifierPrivate, "@@:@c");

// +[NSHTTPCookieStorage _setSharedHTTPCookieStorage:] (10.10+): point the process at a cookie jar of its
// own. 10.9 has no way to replace the process's cookie store, and -- measured on this host -- it does not
// need one, because the storage WebKit passes here is already a HANDLE ON THAT STORE:
//
//   NetworkProcess::setSharedHTTPCookieStorage installs cookieStorageFromIdentifyingData(...), and the
//   identifying data 10.9 produces is an archive naming "com.apple.CFNetwork.defaultStorageSession".
//   Restoring it yields a different CFHTTPCookieStorageRef POINTER but the same store: same cookie count
//   (2148 == 2148), and a cookie set through the restored handle is immediately visible through
//   +sharedHTTPCookieStorage. Two handles, one jar.
//
// So accepting and discarding leaves every consumer -- WebKit's cookie API and the NSURLSession that
// performs the loads -- on that one jar. The rejected alternative was to keep an override that
// +sharedHTTPCookieStorage returned: because the selref rewrite only reaches WebKit-marked images, that
// would have redirected WebKit's reads while CFNetwork's own internal default went untouched, i.e. an
// illusion of a swap that is correct only for callers the rewrite happens to cover. No override is kept
// and +sharedHTTPCookieStorage is left alone, so there is exactly one jar and no way for the two to drift.
static void wk_httpCookieStorage_setSharedHTTPCookieStorage(id self, SEL _cmd, id storage)
{
    (void)self;
    (void)_cmd;
    (void)storage;
}

WK_POLYFILL_ADD_CLASS_METHOD("NSHTTPCookieStorage", "wk__setSharedHTTPCookieStorage:", wk_httpCookieStorage_setSharedHTTPCookieStorage, "v@:@");
WK_POLYFILL_SEL("_setSharedHTTPCookieStorage:", "wk__setSharedHTTPCookieStorage:");

// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionTask _pathToDownloadTaskFile] / -set_pathToDownloadTaskFile: (github #11 / resume).
//
// This is the property with which CFNetwork streams a download STRAIGHT INTO the file the client
// nominated, instead of into a private temp file it only reveals at completion. WebKit sets it in
// NetworkDataTaskCocoa::setPendingDownloadLocation and Download::resume; 10.9's NSURLSession has no
// such property, so the bytes went to /var/folders/.../CFNetworkDownload_XXXXXX.tmp and only arrived
// at the destination once the download finished.
//
// That is not cosmetic on this port, because Safari 7 requires the partial file to exist WHILE the
// download runs. It nominates <name>.download/<name> inside a bundle directory it creates itself
// (its persisted DownloadEntryPath, e.g. ~/Downloads/bigfile.bin.download/bigfile.bin), and
// -[DownloadProgressEntry resume] takes [[self downloadFile] path], requires -fileExistsAtPath: on
// it, and hands that same path to -[WebDownload _initWithResumeInformation:delegate:path:] so
// CFNetwork can append the rest. With the bytes in CFNetwork's temp file the bundle held nothing but
// Info.plist, so resume was never even offered and "Show in Finder" reported the file had moved.
//
// 10.9 has the pieces to do exactly what the property does, and CFNetwork's own NSURLSession resume
// path (-[__NSCFLocalDownloadTask initWithSession:resumeData:ident:bridge:]) uses them: a download
// task holds its output in a _downloadFile, and __NSCFLocalDownloadFile can be built around a file
// that already exists. -initWithExistingFile:expectedSize: open()s it O_WRONLY|O_APPEND (0x9, mode
// 0666) and does NOT pass O_CREAT, so the file must be created first; expectedSize is only logged.
// -[__NSCFLocalDownloadFile dealloc] unlink()s its path unless skipUnlink is set, which is what keeps
// a temp file invisible and would otherwise delete the client's file, so the replacement sets it.

static NSString *wk_downloadTaskFilePathKey = @"wk_pathToDownloadTaskFile";

#if __LP64__
#define WK_TASK_IDENTIFIER_TYPES "Q@:"
#else
#define WK_TASK_IDENTIFIER_TYPES "I@:"
#endif

// Marks the download files whose path belongs to a CLIENT rather than to CFNetwork, so that replacing one
// never unlinks the file the client is downloading into.
static const void *wk_downloadFileIsClientOwnedKey = &wk_downloadFileIsClientOwnedKey;

// Take a download file out of CFNetwork's ownership: its -dealloc unlinks its own path, which is what keeps
// a temp file invisible and would otherwise DELETE the file the client asked us to write. Measured: without
// this, a resumed download completed at full size and then vanished, unlinked from
// -[__NSCFLocalDownloadFile dealloc] as the last reference went away.
static void wk_claimDownloadFileForClient(id file)
{
    static SEL setSkipUnlinkSelector;
    if (!setSkipUnlinkSelector)
        setSkipUnlinkSelector = sel_registerName("setSkipUnlink:");
    void (*setSkipUnlink)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    setSkipUnlink(file, setSkipUnlinkSelector, YES);
    objc_setAssociatedObject(file, wk_downloadFileIsClientOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Build a __NSCFLocalDownloadFile that appends to a file the client owns.
//
// -initWithExistingFile:expectedSize: is open(path, 0x9 = O_WRONLY|O_APPEND, 0666) with no O_CREAT, so the
// file has to exist first; it close()s that descriptor again immediately (the writing channel is opened
// lazily by -ioChannel) and stores errno into _error whether or not the open succeeded, so errno is cleared
// beforehand to keep a stale value from reading as a failed destination. expectedSize is only logged.
//
// A destination that cannot be opened is REPORTED, not swallowed, and by CFNetwork's own mechanism: the
// object comes back with _path unset, -ioChannel then makes no channel ("Not creating a write channel
// because we don't have a path already set up"), and -writeBytes:completionQueue:completion: invokes its
// completion with _error, which -[__NSCFLocalDownloadTask checkWrite] turns into -_private_posixError:. So
// binding this object makes the download fail with the real errno instead of quietly diverting the bytes to
// a temp file the client never hears about -- which is what the real property does too.
static id wk_localDownloadFileForPath(NSString *path)
{
    // -initWithExistingFile: cannot create, and the client's directory may not hold the file yet. A failure
    // here needs no handling of its own: the init below opens the same path with the same flags, so it
    // records that errno itself.
    int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0)
        close(fd);

    errno = 0;
    static SEL initWithExistingFileSelector;
    if (!initWithExistingFileSelector)
        initWithExistingFileSelector = sel_registerName("initWithExistingFile:expectedSize:");
    id (*initWithExistingFile)(id, SEL, NSString *, long long) = (id (*)(id, SEL, NSString *, long long))objc_msgSend;
    id file = initWithExistingFile([objc_getClass("__NSCFLocalDownloadFile") alloc], initWithExistingFileSelector, path, 0);

    wk_claimDownloadFileForClient(file);
    return file;
}

// Close a download file's dispatch_io channel and WAIT for the close to complete, so that everything
// CFNetwork wrote through it is on disk and can be read back.
//
// -finishOnQueue:completion: is dispatch_io_close(channel, 0) followed by dispatch_io_barrier, and a barrier
// block runs only once the operations submitted before it have completed -- so the completion firing IS the
// ordering guarantee, and there is nothing left to race. The queue passed in is a concurrent global queue,
// so this cannot deadlock against it.
static void wk_finishDownloadFile(id file)
{
    static SEL finishOnQueueSelector;
    if (!finishOnQueueSelector)
        finishOnQueueSelector = sel_registerName("finishOnQueue:completion:");
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    void (*finishOnQueue)(id, SEL, dispatch_queue_t, void (^)(void)) = (void (*)(id, SEL, dispatch_queue_t, void (^)(void)))objc_msgSend;
    finishOnQueue(file, finishOnQueueSelector, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_semaphore_signal(finished);
    });
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    dispatch_release(finished);
}

// Append everything in `fromPath` to `toPath`. Returns 0, or the errno that stopped it -- every failure has
// one, which is why this reads and writes itself instead of going through -[NSData dataWithContentsOfFile:].
static int wk_appendFileContents(NSString *fromPath, NSString *toPath)
{
    int source = open([fromPath fileSystemRepresentation], O_RDONLY);
    if (source < 0)
        return errno;
    int destination = open([toPath fileSystemRepresentation], O_WRONLY | O_APPEND);
    if (destination < 0) {
        int failure = errno;
        close(source);
        return failure;
    }

    int failure = 0;
    uint8_t buffer[65536];
    for (;;) {
        ssize_t got = read(source, buffer, sizeof(buffer));
        if (!got)
            break;
        if (got < 0) {
            failure = errno;
            break;
        }
        const uint8_t *remaining = buffer;
        size_t left = (size_t)got;
        while (left) {
            ssize_t wrote = write(destination, remaining, left);
            if (wrote <= 0) {
                failure = errno ? errno : EIO;
                break;
            }
            remaining += wrote;
            left -= (size_t)wrote;
        }
        if (failure)
            break;
    }
    close(source);
    close(destination);
    return failure;
}

// Point a download task's output at `path`.
//
// The earliest a client can reach a download task is after its initializer has run, and by then CFNetwork
// has already replayed into its temp file whatever response body arrived while the destination was being
// decided (measured: one 32 KB chunk). Those bytes belong at the START of the client's file.
static void wk_bindDownloadTaskToFile(id task, NSString *path)
{
    if (![path length])
        return; // Setting the property to nil means "no destination override", so there is nothing to bind.

    // Only a download task keeps an output file. A data task that has not been converted yet has none, and
    // the path is re-applied from -URLSession:dataTask:didBecomeDownloadTask: once it has one. The ivar is
    // the discriminator because it exists on exactly the class that owns a download file
    // (__NSCFLocalDownloadTask, which also vends -downloadFile/-setDownloadFile:).
    if (!class_getInstanceVariable(object_getClass(task), "_downloadFile"))
        return;

    static SEL downloadFileSelector, setDownloadFileSelector, pathSelector, setPathSelector, setErrorSelector;
    static SEL originalResumeInfoSelector, initialResumeSizeSelector;
    if (!downloadFileSelector) {
        downloadFileSelector = sel_registerName("downloadFile");
        setDownloadFileSelector = sel_registerName("setDownloadFile:");
        pathSelector = sel_registerName("path");
        setPathSelector = sel_registerName("setPath:");
        setErrorSelector = sel_registerName("setError:");
        originalResumeInfoSelector = sel_registerName("originalResumeInfo");
        initialResumeSizeSelector = sel_registerName("initialResumeSize");
    }
    id (*getObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    void (*setObject)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    id previous = getObject(task, downloadFileSelector);
    if (!previous)
        return; // -setupForNewDownload has not made one yet; it will, and the path is re-applied then.
    // Retained for the whole function: -path hands back the _path ivar itself, with no retain or
    // autorelease (measured), and the branches below reassign that ivar (-setPath:) or release the object
    // holding it (-setDownloadFile:) while still needing the old path to unlink it.
    NSString *previousPath = [getObject(previous, pathSelector) retain];

    // stat() rather than -attributesOfItemAtPath:, which reported a non-empty destination on a path that
    // did not exist yet and sent this down the copy path (observed: link() never called, the file created
    // with O_CREAT by the fallback, and one chunk lost).
    struct stat previousInfo, destinationInfo;
    bool previousExists = [previousPath length] && !stat([previousPath fileSystemRepresentation], &previousInfo);
    bool destinationExists = !stat([path fileSystemRepresentation], &destinationInfo);

    // ALREADY writing into the client's file, so there is nothing to REBIND -- and rebinding would destroy
    // the download, because everything below treats the previous file as CFNetwork's disposable temp file.
    // Download::resume arrives here: -[__NSCFLocalDownloadTask createResumeInformation:] records
    // [[self downloadFile] path] as NSURLSessionResumeInfoLocalPath, which with this property in place IS
    // the client's path, and -initWithSession:resumeData:ident:bridge: hands that path straight back to
    // -initWithExistingFile:expectedSize:. Compared by identity rather than by string, since what must not
    // happen is unlinking the file that holds the partial download.
    //
    // The file still has to be CLAIMED, though: CFNetwork built it, so it would unlink the client's file
    // when it goes away (measured: the resumed download completed at the full size and then vanished).
    if (previousExists && destinationExists && previousInfo.st_dev == destinationInfo.st_dev
        && previousInfo.st_ino == destinationInfo.st_ino) {
        wk_claimDownloadFileForClient(previous);
        [previousPath release];
        return;
    }

    // Fresh download or resumed one? Ask the TASK, which knows: -initWithSession:resumeData:ident:bridge:
    // fills in _initialResumeSize and -setOriginalResumeInfo: before any client can set this property.
    // Inferring it from the destination's size instead would splice an existing file's contents in front of
    // a fresh download that happened to be pointed at a non-empty path.
    bool resuming = getObject(task, originalResumeInfoSelector)
        || ((long long (*)(id, SEL))objc_msgSend)(task, initialResumeSizeSelector) > 0;

    if (!resuming) {
        // A fresh download starts from an empty destination, whatever happened to be sitting there.
        unlink([path fileSystemRepresentation]);
        destinationExists = false;

        // Now the destination can simply become a second NAME for the file CFNetwork is already writing,
        // which is better than copying the replayed chunk across: that copy went through the temp file's
        // dispatch_io channel and is not necessarily on disk when we look, so reading it raced the flush and
        // silently dropped the chunk (measured: identical downloads landed either byte-exact or exactly
        // 32,768 bytes short, the short ones starting at absolute offset 32768, 6 of 10 bad). With a hard
        // link both names refer to the one growing file: the prefix is already there and CFNetwork keeps
        // writing through the channel it owns.
        if (previousExists && !link([previousPath fileSystemRepresentation], [path fileSystemRepresentation])) {
            // Exactly ONE name must survive, or the download would keep a second full-size link alive in
            // /var/folders for good: -createResumeInformation: sets skipUnlink, so after a stop CFNetwork
            // never unlinks its own name again, and deleting the download in the Finder would free nothing.
            // Hand the file over to the client's name instead -- the descriptor already open keeps writing to
            // the same inode, a channel not opened yet opens the client's path, and [downloadFile path] then
            // reports the client's file, which is what the resume information and -fileURL must name.
            setObject(previous, setPathSelector, path);
            wk_claimDownloadFileForClient(previous);
            unlink([previousPath fileSystemRepresentation]);
            [previousPath release];
            return;
        }
        // link() fails with EXDEV when the client's directory is on another volume, which Safari's "Save
        // downloaded files to" setting allows and which then applies to EVERY download there. Fall through
        // and bind a separate file object instead.
    }

    // Binding a replacement means reading the previous file back, so close its channel FIRST and wait for
    // the close: after that, every byte CFNetwork wrote through it is on disk (see wk_finishDownloadFile),
    // so the carry below is ordered after those writes rather than racing them.
    if (previousExists)
        wk_finishDownloadFile(previous);

    id replacement = wk_localDownloadFileForPath(path);

    // Carry over whatever the previous file holds. CFNetwork opens the replacement O_APPEND, which is right
    // in both directions: for a fresh download the replayed chunk lands at offset 0, and for a resume onto a
    // file that is not the one named in the resume data, anything already received lands after the bytes the
    // destination already holds.
    int carryFailure = previousExists ? wk_appendFileContents(previousPath, path) : 0;
    if (carryFailure) {
        // The destination is now missing bytes it must never be missing, so the download has to FAIL rather
        // than run to completion and be reported finished with a hole in it. Put the file into the same
        // state CFNetwork produces for a destination it cannot open -- no path, _error set: -ioChannel makes
        // no channel without a path, -writeBytes:completionQueue:completion: then completes with _error, and
        // -[__NSCFLocalDownloadTask writeAndResume]'s completion turns any non-zero into -posixError: ->
        // cancel_with_error:. The temp file is deliberately left where it is, since it holds the only copy
        // of the bytes that did not make it across.
        setObject(replacement, setPathSelector, nil);
        ((void (*)(id, SEL, int))objc_msgSend)(replacement, setErrorSelector, carryFailure);
    } else if (previousExists && !objc_getAssociatedObject(previous, wk_downloadFileIsClientOwnedKey)) {
        // Remove the temp file now that its contents are safely across: its channel is closed, and -dealloc
        // would unlink it anyway, but the object outlives this call whenever something else still retains
        // it. Never for a file this polyfill bound -- that path belongs to a client. Done before the swap,
        // because the swap releases `previous` and previousPath is its string.
        unlink([previousPath fileSystemRepresentation]);
    }

    // -setDownloadFile: is objc_setProperty, i.e. it retains the new file and releases the one it replaces,
    // so the ivar's reference is handed over correctly without touching it by hand. Then drop the +1 from
    // +alloc, leaving the task as the only owner.
    setObject(task, setDownloadFileSelector, replacement);
    [replacement release];
    [previousPath release];
}

static NSString *wk_urlSessionTask_pathToDownloadTaskFile(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, (const void *)&wk_downloadTaskFilePathKey);
}

static void wk_urlSessionTask_setPathToDownloadTaskFile(id self, SEL _cmd, NSString *path)
{
    (void)_cmd;
    objc_setAssociatedObject(self, (const void *)&wk_downloadTaskFilePathKey, path, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // A data task has no output file to bind; wk_bindDownloadTaskToFile returns without doing anything,
    // and the path is re-applied to the download task it becomes (see the comment on that call in
    // NetworkSessionCocoa's -URLSession:dataTask:didBecomeDownloadTask:).
    wk_bindDownloadTaskToFile(self, path);
}

// The property is declared on NSURLSessionTask (CFNetworkSPI.h) and WebKit sets it through that type,
// but 10.9 vends concrete subclasses that are NOT descendants of the public class
// (__NSCFLocalDataTask : __NSCFLocalSessionTask : __NSCFURLSessionTask : NSObject), so registering it
// only on NSURLSessionTask would reach no instance. Same reasoning as
// wk_cancelByProducingResumeData: above. Registered on the shared root of the concrete classes, so a
// data task can carry the path before it becomes a download task and a download task can bind it.
WK_POLYFILL_ADD("NSURLSessionTask", "wk__pathToDownloadTaskFile", wk_urlSessionTask_pathToDownloadTaskFile, "@@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_set_pathToDownloadTaskFile:", wk_urlSessionTask_setPathToDownloadTaskFile, "v@:@");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk__pathToDownloadTaskFile", wk_urlSessionTask_pathToDownloadTaskFile, "@@:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_set_pathToDownloadTaskFile:", wk_urlSessionTask_setPathToDownloadTaskFile, "v@:@");
WK_POLYFILL_SEL("_pathToDownloadTaskFile", "wk__pathToDownloadTaskFile");
WK_POLYFILL_SEL("set_pathToDownloadTaskFile:", "wk_set_pathToDownloadTaskFile:");

// ---------------------------------------------------------------------------------------------------
@interface CALayer (WKPolyfillScope)
// -[CALayer setCornerCurve:] (10.13+, a CACornerCurve) and -[CALayer setContentsFormat:] (10.12+, a
// CAContentsFormat NSString). 10.9's CALayer has neither. Corners on 10.9 are always the classic circular
// curve, which is exactly the value PlatformCALayerCocoa requests (kCACornerCurveCircular, supplied in
// constants.m), so honoring the curve is a no-op. The contents format selects a layer's backing pixel
// format (wide-gamut / 16-bit); 10.9's compositor has only the fixed sRGB 8-bit backing, so there is
// nothing to opt into and the set is a no-op. (Per-class GAP_FILLs: WebKit's own WebTiledBackingLayer
// -setContentsFormat:(ContentsFormat) keeps its real method via the patcher's class-correct aliasing;
// only a plain CALayer, which lacks the selector on 10.9, gets this body.)
- (void)wk_setCornerCurve:(NSString *)curve;
- (void)wk_setContentsFormat:(NSString *)format;
@end
@implementation CALayer (WKPolyfillScope)
- (void)wk_setCornerCurve:(NSString *)curve { (void)curve; }
- (void)wk_setContentsFormat:(NSString *)format { (void)format; }
@end
WK_POLYFILL_SEL("setCornerCurve:", "wk_setCornerCurve:");
WK_POLYFILL_SEL("setContentsFormat:", "wk_setContentsFormat:");

// ---------------------------------------------------------------------------------------------------
// -[NSPopover showRelativeToRect:ofView:preferredEdge:] and the anchor window's first responder.
//
// 10.9's NSPopover, as part of presenting, runs -[NSWindow _makeParentWindowHaveFirstResponder:] and
// forces the popover's content view to become the ANCHOR window's first responder. Modern NSPopover
// leaves the anchor window's responder state untouched — the contract every caller since 10.10 is
// written against. On 10.9 the forced change makes any focused control in the anchor window resign
// first responder, which drops that window's key-view focus and delivers a blur to the control. This
// polyfill restores the anchor window's first responder immediately after the popover is shown, so the
// modern no-change contract holds for any caller. The restore is synchronous within the same call, and
// the popover's own content (a label taking no key input, transient/ESC dismissal) does not depend on
// owning the anchor window's first responder.
@interface NSPopover (WKPolyfillScope)
- (void)wk_showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge;
@end
@implementation NSPopover (WKPolyfillScope)
- (void)wk_showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge
{
    NSWindow *window = [positioningView window];
    NSResponder *savedFirstResponder = [window firstResponder];

    // sel_registerName rather than @selector: this file is compiled into WebCore, whose __objc_selrefs
    // are rewritten, so a compiled `showRelativeToRect:ofView:preferredEdge:` selref arrives here as the
    // wk_ name and would recurse. The assignment is idempotent — sel_registerName answers the same SEL
    // on every thread and call.
    static SEL showRelativeToRectSelector;
    if (!showRelativeToRectSelector)
        showRelativeToRectSelector = sel_registerName("showRelativeToRect:ofView:preferredEdge:");
    void (*showRelativeToRect)(id, SEL, NSRect, NSView *, NSRectEdge) = (void (*)(id, SEL, NSRect, NSView *, NSRectEdge))objc_msgSend;
    showRelativeToRect(self, showRelativeToRectSelector, positioningRect, positioningView, preferredEdge);

    if (window && [window firstResponder] != savedFirstResponder)
        [window makeFirstResponder:savedFirstResponder];
}
@end
// 10.9 HAS -showRelativeToRect:ofView:preferredEdge:; it shows the popover correctly and additionally
// steals the anchor window's first responder, which is the behavior this replacement undoes.
WK_POLYFILL_SEL_REPLACES("showRelativeToRect:ofView:preferredEdge:", "wk_showRelativeToRect:ofView:preferredEdge:");

// ---------------------------------------------------------------------------------------------------
// +[CATransaction addCommitHandler:forPhase:] (10.10+, absent on 10.9's CATransaction — sending it
// throws NSInvalidArgumentException, which aborted Safari from TiledCoreAnimationDrawingAreaProxy::
// createFence and permanently wedged window-resize propagation).
//
// 10.9's CoreAnimation has NO hook inside a commit. Audited on 10.9.5 (13F34): CATransaction's whole
// method list is +begin/+commit/+flush/+synchronize/+activate/+lock/+setCompletionBlock: and friends —
// nothing phase-related — and QuartzCore exports no commit callback either; the commit itself is
// CA::Transaction::commit, an internal C++ entry point. What IS observable is WHERE that commit happens:
// it runs from CA's own run-loop observer (CA::Transaction::observer_callback,
// kCFRunLoopBeforeWaiting|kCFRunLoopExit, order 2000000 — read straight off the run loop on 10.9.5, and
// the same number upstream WebKit hardcodes as `coreAnimationCommit` in
// WebCore/platform/cf/RunLoopObserverCF.cpp). A commit therefore has a position in the run loop, and
// both sides of this polyfill are run-loop observers placed around it: the pre side one order below
// CA's, the post side one order above. Order, not the registrant's identity, is what puts each handler
// on its side of the commit.
//
// WHAT THIS GUARANTEES: a PreLayout/PreCommit handler runs at the end of the run-loop pass it is
// registered in, immediately before CA's commit observer — after everything its registrant does in that
// pass, and before the commit that carries those changes. A PostCommit handler runs once a commit has
// actually been observed to happen (see the commit-counter gate below), from an observer ordered above
// CA's. The bracket is never inverted, and neither side depends on HOW the commit is triggered: it holds
// for the run-loop drain, for an explicit [CATransaction flush] or [CATransaction commit], and for a
// commit some other framework performs.
//
// The residual differences, all in the "wider" direction:
//   - PreLayout and PreCommit run at the same point, and that point is immediately before the commit
//     rather than inside it, so neither observes the layout CA does while committing. This OS offers no
//     callout between the two, so one slot is what there is.
//   - A pre handler registered before this thread's observers can fire — the pass in which the thread's
//     first handler is registered, or a thread that never runs a run loop — runs at registration
//     instead. That is earlier than the commit, never after it (CFRunLoop collects the observers for an
//     activity ONCE, as that activity's callouts begin, so an observer created during them first fires
//     in the NEXT pass; measured on 10.9.5).
//   - A post handler on a thread that commits explicitly and then never returns to its run loop does not
//     run.
//   - A handler registered from inside another handler runs at the next commit rather than at the end of
//     the current one, which upstream CA prohibits outright.
static const CFIndex wk_coreAnimationCommitOrder = 2000000;

// THE COMMIT GATE. "After the commit" is only a bracket if a commit happened. A PostCommit handler is the
// tail of a pair whose head is some change the caller has just made and expects to be on screen; running it
// on a pass where nothing committed hands the caller a completion for work that has not happened, which is
// an inversion rather than a wider bracket. Nothing about registering a handler makes a transaction exist,
// so a pass with no commit is an ordinary case that has to be recognised, not assumed away.
//
// The signal is CA's own commit counter. 10.9's QuartzCore exports CAGetTransactionCounter(), which returns a
// process-global int that CA increments once per COMMITTED transaction. Measured on 10.9.5 (13F34): reading
// it creates no transaction; [CATransaction begin] and layer mutations leave it alone; each [CATransaction
// commit] and each [CATransaction flush] that had a transaction to flush adds one; a flush with nothing
// pending adds nothing. That is exactly "a commit happened", observed rather than predicted — which is why
// this is used in preference to probing +[CATransaction currentState] for a PENDING transaction: the counter
// also catches a commit performed explicitly during the pass, and it does not depend on where the probe sits
// relative to WebKit's own RenderingUpdate observer (which shares order 2000000-1 and is where the pending
// transaction is usually created).
//
// So each queued handler records the counter at registration, and a second per-thread observer records it
// again each time the thread WAKES (kCFRunLoopAfterWaiting). The drain observer, at CA's order + 1, runs a
// handler only when the counter has advanced past BOTH:
//   - the value at that handler's registration — the commit must have come after the handler was queued; and
//   - the value read when this thread last woke — the commit must have happened while this thread was
//     running, not while it slept.
// Everything else stays queued and is carried to the next pass. Nothing here enumerates callers.
//
// The second test is what keeps the counter's one weakness in check: it is a single QuartzCore global, not a
// per-thread count (10.9 has no per-thread one), so ANY thread's commit moves it. Commits by the other thread
// that registers handlers here — ScrollingThread, whose transactions land while the main thread is between
// passes — are therefore rejected outright. What remains is a commit on another thread landing while this
// thread happens to be awake, which opens the gate one pass early: the old unconditional behaviour for that
// one pass, not a systematic inversion.
//
// The wake reading, rather than one taken just below CA's commit observer, is what makes an EXPLICIT commit
// count: [CATransaction commit]/[CATransaction flush] happens in the middle of a pass, so a reading taken
// below CA's commit observer is already past it and the handler would sit queued until some later implicit
// commit. Both readings were built and run against this translation unit on 10.9.5: the below-CA reading
// strands a handler registered before an explicit commit, the wake reading releases it on the same pass.
// If a thread's run loop never sleeps, the wake reading simply goes stale and the gate falls back to the
// registration test alone — later than CA, never earlier.
WK_SYSTEM_FN("QuartzCore", unsigned int, CAGetTransactionCounter, (void));

static unsigned int wk_caTransactionCounter(void)
{
    return WK_SYSTEM(CAGetTransactionCounter) ? WK_SYSTEM(CAGetTransactionCounter)() : 0;
}

// The queues and their observers are per thread (CA transactions are per thread) and the observers are
// REPEATING and kept for the life of the thread. That is not an optimization: CFRunLoop collects the
// observers for an activity ONCE, when that activity's callouts begin, so an observer created from inside a
// BeforeWaiting callout does not fire until the NEXT pass (measured on 10.9.5). Handlers are routinely
// registered from exactly there — a run-loop observer one order below CA's commit is where a caller
// preparing a commit belongs — so a fresh observer per registration would run every handler a full
// run-loop cycle late. The one pass that still has no live observers is the one in which a thread's first
// handler is registered, and `observersAreLive` is what says so.
typedef struct {
    NSMutableArray *preHandlers;        // pending pre-commit blocks, in registration order
    NSMutableArray *postHandlers;       // pending PostCommit blocks, in registration order
    NSMutableArray *postRegisteredAt;   // CA commit counter when each post handler was queued, same order
    CFRunLoopObserverRef wakeObserver;  // AfterWaiting: samples the counter as the pass starts
    CFRunLoopObserverRef preObserver;   // below CA's commit observer: runs the pre handlers
    CFRunLoopObserverRef postObserver;  // above CA's commit observer: drains what a commit released
    unsigned int counterAtWake;
    bool observersAreLive;              // a pass has begun since the observers were created
} WKCommitHandlerQueue;

static pthread_key_t wk_commitHandlerQueueKey;
static pthread_once_t wk_commitHandlerQueueOnce = PTHREAD_ONCE_INIT;

static void wk_invalidateObserver(CFRunLoopObserverRef observer)
{
    if (!observer)
        return;
    CFRunLoopObserverInvalidate(observer);
    CFRelease(observer);
}

static void wk_commitHandlerQueueDestroy(void *value)
{
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)value;
    wk_invalidateObserver(queue->wakeObserver);
    wk_invalidateObserver(queue->preObserver);
    wk_invalidateObserver(queue->postObserver);
    [queue->preHandlers release];
    [queue->postHandlers release];
    [queue->postRegisteredAt release];
    free(queue);
}

static void wk_commitHandlerQueueKeyInit(void)
{
    pthread_key_create(&wk_commitHandlerQueueKey, wk_commitHandlerQueueDestroy);
}

// Runs as the thread wakes, before anything else the pass does. It records the commit count this pass
// starts from, so that the post drain can tell a commit made while this thread was running from one
// another thread made while it slept; it marks the observers live, since reaching here means a pass has
// begun with them already collected; and it re-inserts the pre observer.
//
// The re-insertion is what makes the pre observer's position independent of when it was created. CFRunLoop
// runs observers of EQUAL order in the order they were added (measured on 10.9.5), and CA's commit sits at
// the next integer up, so there is no order between the two: being last among the observers at CA's order
// minus one is the only way to run after every one of them and still before the commit. Removing and
// re-adding during AfterWaiting takes effect for this pass, because BeforeWaiting collects its observers
// later.
static void wk_beginRunLoopPass(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    queue->counterAtWake = wk_caTransactionCounter();
    queue->observersAreLive = true;
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopRemoveObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
}

// Immediately below CA's commit observer: everything the pass did has happened, and the commit that will
// carry it has not. Unlike the post side there is nothing to gate on — a handler that runs here runs before
// the next commit whether or not this pass has one.
static void wk_runPendingPreCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->preHandlers count])
        return;
    // Take the batch out first: a handler that registers another one queues it for the next commit instead
    // of extending this callout (upstream CA rejects that registration outright, so no caller can be
    // relying on either behaviour).
    NSArray *batch = [queue->preHandlers copy];
    [queue->preHandlers removeAllObjects];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static void wk_runPendingPostCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->postHandlers count])
        return;
    unsigned int now = wk_caTransactionCounter();
    if (now == queue->counterAtWake)
        return; // Nothing committed while this thread ran. Carry the queue to the next pass.
    // Drain the handlers registered before that commit — the leading run of the array, since the counters
    // are recorded in registration order. Anything registered at the current value was queued after the
    // commit (a CATransaction completion block can do that) and waits for the next one.
    NSUInteger drainCount = 0, queued = [queue->postHandlers count];
    while (drainCount < queued && [[queue->postRegisteredAt objectAtIndex:drainCount] unsignedIntValue] != now)
        drainCount++;
    if (!drainCount)
        return;
    NSRange range = NSMakeRange(0, drainCount);
    NSArray *batch = [[queue->postHandlers subarrayWithRange:range] copy];
    [queue->postHandlers removeObjectsInRange:range];
    [queue->postRegisteredAt removeObjectsInRange:range];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static WKCommitHandlerQueue *wk_commitHandlerQueueForCurrentThread(void)
{
    pthread_once(&wk_commitHandlerQueueOnce, wk_commitHandlerQueueKeyInit);
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)pthread_getspecific(wk_commitHandlerQueueKey);
    if (queue)
        return queue;
    queue = (WKCommitHandlerQueue *)calloc(1, sizeof(WKCommitHandlerQueue));
    queue->preHandlers = [[NSMutableArray alloc] init];
    queue->postHandlers = [[NSMutableArray alloc] init];
    queue->postRegisteredAt = [[NSMutableArray alloc] init];
    CFRunLoopObserverContext context = { 0, queue, NULL, NULL, NULL };
    // The wake sampler takes the lowest order there is, so that it reads the counter before anything else
    // the pass does. The two drain observers carry CA's own activities and sit one below and one above its
    // commit; one above is also where CA's own PostCommit handlers land relative to WebKit's
    // PostRenderingUpdate observer (2000002), so the post handler keeps running before it, as upstream.
    queue->wakeObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting,
                                                  true, LONG_MIN,
                                                  wk_beginRunLoopPass, &context);
    queue->preObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                 true, wk_coreAnimationCommitOrder - 1,
                                                 wk_runPendingPreCommitHandlers, &context);
    queue->postObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                  true, wk_coreAnimationCommitOrder + 1,
                                                  wk_runPendingPostCommitHandlers, &context);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->wakeObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->postObserver, kCFRunLoopCommonModes);
    pthread_setspecific(wk_commitHandlerQueueKey, queue);
    return queue;
}

@interface CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase;
@end
@implementation CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase
{
    if (!handler)
        return;
    // kCATransactionPhasePreLayout = 0, PreCommit = 1, PostCommit = 2.
    enum { wkPostCommitPhase = 2 };
    WKCommitHandlerQueue *queue = wk_commitHandlerQueueForCurrentThread();
    // With no observer that can fire before the next commit, the last moment this thread offers that is
    // still on the pre side of that commit is now.
    if (phase != wkPostCommitPhase && !queue->observersAreLive) {
        handler();
        return;
    }
    void (^copied)(void) = [handler copy];
    if (phase == wkPostCommitPhase) {
        [queue->postHandlers addObject:copied];
        [queue->postRegisteredAt addObject:[NSNumber numberWithUnsignedInt:wk_caTransactionCounter()]];
    } else
        [queue->preHandlers addObject:copied];
    [copied release];
}
@end
WK_POLYFILL_SEL("addCommitHandler:forPhase:", "wk_addCommitHandler:forPhase:");

// -[CASpringAnimation setInitialVelocity:] (the property is public 10.11+, absent on 10.9). 10.9 ships a
// fully-functional private CASpringAnimation (mass/stiffness/damping/velocity settable + the internal
// _copyRenderAnimationForLayer:/_timeFunction: spring machinery) whose pre-10.11 name for the same
// concept is -velocity/-setVelocity:. Forward the modern setter to it (via KVC on "velocity", verified
// settable on-host) so PlatformCAAnimation*'s upstream `.initialVelocity = ...` works and those sources
// revert to pristine.
@interface CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity;
@end
@implementation CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity
{
    [self setValue:@(velocity) forKey:@"velocity"];
}
@end
WK_POLYFILL_SEL("setInitialVelocity:", "wk_setInitialVelocity:");

// ---------------------------------------------------------------------------------------------------
// -[NSWorkspace URLsForApplicationsToOpenURL:] (12.0+). LSCopyApplicationURLsForURL is the same query
// under its pre-12.0 name (it is what the modern method wraps), present since 10.3.
@interface NSWorkspace (WKPolyfillScopeAppURLs)
- (NSArray *)wk_URLsForApplicationsToOpenURL:(NSURL *)url;
@end
@implementation NSWorkspace (WKPolyfillScopeAppURLs)
- (NSArray *)wk_URLsForApplicationsToOpenURL:(NSURL *)url
{
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end
WK_POLYFILL_SEL("URLsForApplicationsToOpenURL:", "wk_URLsForApplicationsToOpenURL:");

// ---------------------------------------------------------------------------------------------------
// MAVERICKS_BACKPORT (#68): +[NSLocale matchedLanguagesFromAvailableLanguages:forPreferredLanguages:] is
// 10.12+. WTF::indexOfBestMatchingLanguageInList (Source/WTF/wtf/cocoa/LanguageCocoa.mm) calls it
// UNCONDITIONALLY to pick the best caption/subtitle-track language, so on 10.9 the absent selector throws
// (unrecognized selector -> SIGILL) the instant any media element's caption menu is built
// (CaptionUserPreferencesMediaAF::sortedTrackListForMenu).
//
// We reproduce the 10.12+ contract faithfully: return the availableLanguages that GENUINELY match a
// preferred language (BCP-47 primary language subtag, canonicalized), in preference order, and an EMPTY
// array when none match. The empty-on-no-match behaviour is load-bearing: callers such as
// CaptionUserPreferencesMediaAF (matchesDefaultLanguage / sortedTrackListForMenu),
// AccessibilitySVGObject and WebExtension test `if (![matched count]) return notFound;` (or negate the
// index) and would otherwise treat a non-matching language as a match. +[NSBundle
// preferredLocalizationsFromArray:forPreferences:] (10.0+) does the same BCP-47 best-match and returns
// entries verbatim from availableLanguages, BUT it falls back to the development region (the first
// available language) when nothing matches, so its result must be filtered down to real language matches.
static NSString *wk_primaryLanguageSubtag(NSString *languageTag)
{
    if (![languageTag isKindOfClass:[NSString class]] || !languageTag.length)
        return nil;
    // Canonicalize (e.g. iw->he, EN-us->en-US) then take the primary subtag before the first "-"/"_".
    NSString *canonical = [NSLocale canonicalLanguageIdentifierFromString:languageTag];
    if (!canonical.length)
        canonical = languageTag;
    NSRange sep = [canonical rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    NSString *code = (sep.location == NSNotFound) ? canonical : [canonical substringToIndex:sep.location];
    return code.lowercaseString;
}
@interface NSLocale (WKPolyfillScopeLangMatch)
+ (NSArray *)wk_matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages;
@end
@implementation NSLocale (WKPolyfillScopeLangMatch)
+ (NSArray *)wk_matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages
{
    NSArray *ordered = [NSBundle preferredLocalizationsFromArray:availableLanguages forPreferences:preferredLanguages];
    if (!ordered.count)
        return @[];
    NSMutableSet *preferredCodes = [NSMutableSet set];
    for (NSString *preferred in preferredLanguages) {
        NSString *code = wk_primaryLanguageSubtag(preferred);
        if (code)
            [preferredCodes addObject:code];
    }
    // Keep only entries that are (a) genuine members of availableLanguages and (b) whose primary language
    // subtag is actually among the preferred languages. (a) drops the value preferredLocalizationsFromArray:
    // echoes back when availableLanguages is empty (it returns the preferred string itself, which is NOT a
    // member); (b) drops the development-region fallback it adds on a non-empty total no-match. Together they
    // reproduce +matchedLanguagesFromAvailableLanguages:'s empty-on-no-match result and guarantee every
    // returned entry is a member of availableLanguages (WTF::indexOfBestMatchingLanguageInList relies on
    // languageList.find(firstObject) resolving).
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *available in ordered) {
        NSString *code = wk_primaryLanguageSubtag(available);
        if (code && [preferredCodes containsObject:code] && [availableLanguages containsObject:available])
            [matched addObject:available];
    }
    return matched;
}
@end
WK_POLYFILL_SEL("matchedLanguagesFromAvailableLanguages:forPreferredLanguages:", "wk_matchedLanguagesFromAvailableLanguages:forPreferredLanguages:");

#pragma clang diagnostic pop

// -[NSProgress fileOperationKind]/-fileURL and their setters (10.13+) are thin wrappers over
// userInfo keys 10.9 already defines, so implement them that way. NSProgress itself ships in 10.9;
// only these convenience accessors postdate it. WKDownloadProgress sets both when publishing a
// download's progress to the Finder.
//
// fileURL/setFileURL: are generic names -- WebKit sends them to other classes too. That is handled:
// a class that implements the real method has wk_fileURL aliased to its own IMP when its image
// loads, so only NSProgress reaches this polyfill.
@interface NSProgress (WKPolyfillScopeFileProgress)
- (void)wk_setFileOperationKind:(NSString *)kind;
- (NSString *)wk_fileOperationKind;
- (void)wk_setFileURL:(NSURL *)url;
- (NSURL *)wk_fileURL;
@end
@implementation NSProgress (WKPolyfillScopeFileProgress)
- (void)wk_setFileOperationKind:(NSString *)kind { [self setUserInfoObject:kind forKey:NSProgressFileOperationKindKey]; }
- (NSString *)wk_fileOperationKind { return [[self userInfo] objectForKey:NSProgressFileOperationKindKey]; }
- (void)wk_setFileURL:(NSURL *)url { [self setUserInfoObject:url forKey:NSProgressFileURLKey]; }
- (NSURL *)wk_fileURL { return [[self userInfo] objectForKey:NSProgressFileURLKey]; }
@end
WK_POLYFILL_SEL("setFileOperationKind:", "wk_setFileOperationKind:");
WK_POLYFILL_SEL("fileOperationKind", "wk_fileOperationKind");
WK_POLYFILL_SEL("setFileURL:", "wk_setFileURL:");
WK_POLYFILL_SEL("fileURL", "wk_fileURL");

// -[AVCaptureDevice deviceType] (10.15+), -portraitEffectActive (12+) and +systemPreferredCamera
// (13+): three accessors added to a class 10.9 HAS, so they are method polyfills rather than a class
// stub. AVCaptureDALDevice, the concrete class 10.9's AVFoundation hands out, raises
// unrecognized-selector for all three.
//
// deviceType names the camera's hardware kind. 10.9 has no AVCaptureDeviceType vocabulary at all --
// neither the constants nor the property -- so the distinction it can still draw is the one
// -transportType draws: a camera wired into the machine ('bltn') versus anything attached to it. That
// is exactly the built-in-wide-angle / external split, which is what the two constants below name.
// Since 10.9 has no other producer OR consumer of an AVCaptureDeviceType, the constants and this
// method are a closed system: what matters is that they are the same objects on both sides, which
// polyfilling the constants (rather than returning a literal) is what guarantees -- WebKit compares
// device types by pointer. Their values are the constants' own spelling, so a log or a debugger
// shows something meaningful.
#import <AVFoundation/AVFoundation.h>

// These two live here rather than in constants.m, next to their only producer and because
// constants.m compiles against the 10.9 headers, which have no AVCaptureDeviceType to declare them
// with.
WK_POLYFILL_CONST("AVFoundation", AVCaptureDeviceType, AVCaptureDeviceTypeBuiltInWideAngleCamera,
                  @"AVCaptureDeviceTypeBuiltInWideAngleCamera");
WK_POLYFILL_CONST("AVFoundation", AVCaptureDeviceType, AVCaptureDeviceTypeExternalUnknown,
                  @"AVCaptureDeviceTypeExternalUnknown");

// kIOAudioDeviceTransportTypeBuiltIn, the transport a camera on the logic board reports.
enum { WKAVCaptureTransportTypeBuiltIn = 'bltn' };

@interface AVCaptureDevice (WKPolyfillScopeCaptureDevice)
- (AVCaptureDeviceType)wk_deviceType;
- (BOOL)wk_isPortraitEffectActive;
+ (AVCaptureDevice *)wk_systemPreferredCamera;
+ (AVAuthorizationStatus)wk_authorizationStatusForMediaType:(AVMediaType)mediaType;
+ (void)wk_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler;
@end

@implementation AVCaptureDevice (WKPolyfillScopeCaptureDevice)

- (AVCaptureDeviceType)wk_deviceType
{
    return [self transportType] == WKAVCaptureTransportTypeBuiltIn
        ? AVCaptureDeviceTypeBuiltInWideAngleCamera : AVCaptureDeviceTypeExternalUnknown;
}

// The portrait/background-blur effect is a macOS 12 Continuity Camera feature with no 10.9
// counterpart, so no device here has it active -- which is also what the real property reports on a
// modern machine whose camera does not support it.
- (BOOL)wk_isPortraitEffectActive
{
    return NO;
}

// systemPreferredCamera is "the camera the system would choose", which on 10.9 is precisely what
// +defaultDeviceWithMediaType: answers. The modern property additionally reflects a user override
// set through +setUserPreferredCamera:, which 10.9 has no store for; a machine where the user has
// never expressed a preference is the case the two definitions agree on.
+ (AVCaptureDevice *)wk_systemPreferredCamera
{
    return [self defaultDeviceWithMediaType:AVMediaTypeVideo];
}

// +authorizationStatusForMediaType: and +requestAccessForMediaType:completionHandler: are macOS 10.14,
// added with the TCC camera/microphone gating they report on. 10.9 predates that gating entirely: there
// is no per-app camera or microphone authorization on this OS, so there is no state for these to read
// and nothing for them to ask the user. Authorized is the answer for the same reason TCCAccessPreflight
// answers Granted for kTCCServiceCamera in constants.m -- not "permission was given", but "the question
// does not exist here". Denied would be wrong in a way that matters: UserMediaPermissionRequestManagerProxy
// ::requestSystemValidation treats it as a hard refusal and never reaches WebKit's own consent sheet, so
// getUserMedia would fail before ever asking the user.
//
// Absent BOTH selectors, the plain upstream call is worse than a wrong answer: AVCaptureDevice exists on
// 10.9 but does not respond, so +authorizationStatusForMediaType: raises unrecognized-selector. AppKit's
// run loop swallows that exception, requestSystemValidation's completion handler never runs, and the
// getUserMedia promise neither resolves nor rejects -- the request hangs with no prompt and no error.
+ (AVAuthorizationStatus)wk_authorizationStatusForMediaType:(AVMediaType)mediaType
{
    (void)mediaType;
    return AVAuthorizationStatusAuthorized;
}

// Unreachable while the status above reports Authorized (requestSystemValidation only requests access for
// a NotDetermined status), but it is the same absent 10.14 pair and callers may reach it by another route,
// so it answers consistently instead of leaving a second unrecognized selector behind. Answering
// synchronously is safe: upstream's requestAVCaptureAccessForType hops to the main run loop itself.
+ (void)wk_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler
{
    (void)mediaType;
    if (handler)
        handler(YES);
}

@end
WK_POLYFILL_SEL("deviceType", "wk_deviceType");
WK_POLYFILL_SEL("isPortraitEffectActive", "wk_isPortraitEffectActive");
WK_POLYFILL_SEL("systemPreferredCamera", "wk_systemPreferredCamera");
WK_POLYFILL_SEL("authorizationStatusForMediaType:", "wk_authorizationStatusForMediaType:");
WK_POLYFILL_SEL("requestAccessForMediaType:completionHandler:", "wk_requestAccessForMediaType:completionHandler:");

// +[NSSharingService getSharingServicesForItems:mask:completion:] — the asynchronous, mask-filtered SPI
// form, absent on 10.9 (probed on-host). The class is present, and so is the PUBLIC 10.8 API that answers
// the same question synchronously, +sharingServicesForItems:, so this is a translation rather than a stub.
//
// Getting this wrong is not a quiet degradation: ServicesController::hasCompatibleServicesForItems does
// dispatch_group_enter, calls this, and leaves the group in the completion. With the selector absent the
// completion never runs, the group is entered three times and never left, and destroying it aborts the
// process in _dispatch_semaphore_dispose (SIGILL) — which is exactly how Safari died once
// ENABLE(SERVICE_CONTROLS) was restored.
//
// The mask (viewer/editor) cannot be applied here: 10.8's API takes no mask and returns everything that
// can handle the items. Over-reporting is the safe direction — callers use the result to decide whether to
// OFFER a services menu, and the menu itself is built by NSSharingServicePicker, which does its own
// filtering. The completion is delivered asynchronously because that is the shape of the API being
// replaced; a caller that leaves a dispatch group in it must not be called back before it returns.
//
// The enumeration runs on a dedicated, persistent, OFF-MAIN thread that owns a CoreFoundation run loop —
// NOT a global dispatch worker, and NOT the main thread. +sharingServicesForItems: brings up a ShareKit
// helper over XPC (SHKHelperController), and on 10.9 that xpc_connection_resume requires the calling
// thread to have a run loop: on a runloop-less global worker it hits _xpc_api_misuse and SIGILLs the
// process. The main thread has a run loop, but the real 10.10 async SPI does not run its XPC round-trip on
// the caller's main thread, and neither should this — a main-queue hop would block the UI thread and be
// correct only for the current, happens-to-be-non-blocking caller. A dedicated run-loop thread meets both
// constraints for any caller.
static CFRunLoopRef wkSharingEnumerationRunLoopRef; // published by the thread once it is up
static dispatch_semaphore_t wkSharingEnumerationReady;

static void *wkSharingEnumerationThreadMain(void *unused)
{
    (void)unused;
    wkSharingEnumerationRunLoopRef = CFRunLoopGetCurrent();
    // A source that is never signaled keeps CFRunLoopRun() from returning while the thread is idle.
    CFRunLoopSourceContext context = { 0 };
    CFRunLoopSourceRef keepAlive = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(wkSharingEnumerationRunLoopRef, keepAlive, kCFRunLoopCommonModes);
    CFRelease(keepAlive);
    dispatch_semaphore_signal(wkSharingEnumerationReady);
    CFRunLoopRun();
    return NULL;
}

static CFRunLoopRef wkSharingEnumerationRunLoop(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wkSharingEnumerationReady = dispatch_semaphore_create(0);
        pthread_t thread;
        if (!pthread_create(&thread, NULL, wkSharingEnumerationThreadMain, NULL)) {
            pthread_detach(thread);
            dispatch_semaphore_wait(wkSharingEnumerationReady, DISPATCH_TIME_FOREVER);
        }
    });
    return wkSharingEnumerationRunLoopRef;
}

@interface NSSharingService (WKPolyfillScopeSharingServices)
+ (void)wk_getSharingServicesForItems:(NSArray *)items mask:(NSUInteger)mask completion:(void (^)(NSArray *))completion;
@end

@implementation NSSharingService (WKPolyfillScopeSharingServices)

+ (void)wk_getSharingServicesForItems:(NSArray *)items mask:(NSUInteger)mask completion:(void (^)(NSArray *))completion
{
    (void)mask;
    if (!completion)
        return;
    CFRunLoopRef runLoop = wkSharingEnumerationRunLoop();
    if (!runLoop) {
        // Thread could not be created; fail closed by reporting no services rather than never calling back.
        completion(@[]);
        return;
    }
    // items/completion are retained by the block copy CFRunLoopPerformBlock makes, and released after it runs.
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, ^{
        NSArray *services = [NSSharingService sharingServicesForItems:items];
        completion(services ?: @[]);
    });
    CFRunLoopWakeUp(runLoop);
}

@end
WK_POLYFILL_SEL("getSharingServicesForItems:mask:completion:", "wk_getSharingServicesForItems:mask:completion:");

// ---------------------------------------------------------------------------------------------
// AppKit pieces the Web Inspector's window/panel code needs, all absent on 10.9 (probed on-host).

// +[NSTextField labelWithString:] (10.12+) is a convenience constructor for a non-editable,
// non-bezeled, non-drawing label. That IS its implementation — the modern one configures exactly these
// properties on a plain NSTextField — so this is the real thing, not an approximation.
@interface NSTextField (WKPolyfillScopeLabel)
+ (NSTextField *)wk_labelWithString:(NSString *)stringValue;
@end
@implementation NSTextField (WKPolyfillScopeLabel)
+ (NSTextField *)wk_labelWithString:(NSString *)stringValue
{
    NSTextField *label = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [label setStringValue:stringValue ?: @""];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setLineBreakMode:NSLineBreakByClipping];
    [label sizeToFit];
    return label;
}
@end
WK_POLYFILL_SEL("labelWithString:", "wk_labelWithString:");

// -[NSView safeAreaInsets] (11.0+). A safe-area inset describes screen furniture (notch, home indicator)
// intruding on a view. 10.9 has none, and NSEdgeInsetsZero is exactly what modern AppKit returns for a
// view with nothing intruding — so this is the correct answer here, not a placeholder.
@interface NSView (WKPolyfillScopeSafeArea)
- (NSEdgeInsets)wk_safeAreaInsets;
@end
@implementation NSView (WKPolyfillScopeSafeArea)
- (NSEdgeInsets)wk_safeAreaInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
@end
WK_POLYFILL_SEL("safeAreaInsets", "wk_safeAreaInsets");

// -[NSWindow setMinFullScreenContentSize:] (10.11+) constrains a window's size in a tiled full-screen
// split. 10.9 has no tiling — NSWindowCollectionBehaviorFullScreenAllowsTiling is 10.11 too — so there is
// no split for a minimum to apply to, and storing nothing is the whole behaviour on this OS.
@interface NSWindow (WKPolyfillScopeFullScreenContentSize)
- (void)wk_setMinFullScreenContentSize:(NSSize)size;
@end
@implementation NSWindow (WKPolyfillScopeFullScreenContentSize)
- (void)wk_setMinFullScreenContentSize:(NSSize)size { (void)size; }
@end
WK_POLYFILL_SEL("setMinFullScreenContentSize:", "wk_setMinFullScreenContentSize:");

// -[NSKeyedUnarchiver _enableStrictSecureDecodingMode] (10.13+) opts an unarchiver into rejecting the
// looser decodes that older secure coding tolerated. 10.9 has no such mode to enable, so doing nothing
// IS this OS's behaviour -- the decode simply runs under the secure-coding rules 10.9 does implement.
@interface NSKeyedUnarchiver (WKPolyfillScopeStrictDecoding)
- (void)wk_enableStrictSecureDecodingMode;
@end
@implementation NSKeyedUnarchiver (WKPolyfillScopeStrictDecoding)
- (void)wk_enableStrictSecureDecodingMode { }
@end
WK_POLYFILL_SEL("_enableStrictSecureDecodingMode", "wk_enableStrictSecureDecodingMode");

// ---------------------------------------------------------------------------------------------------
// -[NSURLSession dataTaskWithRequest:] / -uploadTaskWithStreamedRequest: with a STREAM body.
//
// 10.9 CFNetwork sends every NSInputStream-bodied task with Transfer-Encoding: chunked and DISCARDS an
// explicitly-set Content-Length. Measured on the wire against a local server:
//   dataTaskWithRequest:        + stream + "Content-Length: N"  ->  Chunked, no Content-Length
//   uploadTaskWithStreamedRequest: + "Content-Length: N"        ->  Chunked, no Content-Length
//   uploadTaskWithRequest:fromFile:                             ->  Content-Length: N
// Modern CFNetwork honours the header; many endpoints reject a length-less chunked upload, which broke
// every <input type=file> upload. The contract being restored is therefore the modern one -- "a request
// whose caller set Content-Length on a stream body goes out with that Content-Length" -- and it is stated
// entirely in NSURLRequest terms, so it is correct for any caller, not only WebKit's. Upstream already
// sets that header on stream bodies (ResourceRequestCocoa: "For streams, provide a Content-Length to
// avoid using chunked encoding"), which is what makes the length known here without any WebCore type.
//
// Spool exactly Content-Length bytes, then hand the file to the one 10.9 body form that carries a length
// and also replays safely across redirects and auth retries. Anything unexpected -- no header, a short
// or unreadable stream, a write failure -- falls through to the real selector so upstream's own failure
// semantics survive rather than being replaced by ours.
@interface WKPolyfillScopeUploadSpoolOwner : NSObject {
@public
    NSString *m_path;
}
@end
@implementation WKPolyfillScopeUploadSpoolOwner
- (void)dealloc
{
    if (m_path)
        [[NSFileManager defaultManager] removeItemAtPath:m_path error:NULL];
    [m_path release];
    [super dealloc];
}
@end

// Spooling is decided BEFORE the caller's stream is touched, and the stream is consumed only once the
// substitution is committed to. Draining it and then "falling back" to the real selector would hand
// CFNetwork a closed, already-read stream -- a silently truncated body dressed up as a safety net. So a
// read or write failure here fails the spool outright and the task is created with no body substitution
// attempted on that stream again.
static NSURL *wk_spoolStreamBodyToFile(NSURLRequest *request, NSString **pathOut)
{
    NSInputStream *stream = [request HTTPBodyStream];
    NSString *lengthHeader = [request valueForHTTPHeaderField:@"Content-Length"];
    if (!stream || ![lengthHeader length])
        return nil;
    long long expected = [lengthHeader longLongValue];
    if (expected <= 0)
        return nil;

    // mkstemp, not pid+pointer: NSURLRequest addresses are recycled, so a name derived from one can
    // collide with a spool an in-flight upload is still streaming from -- truncating that body and, when
    // the first owner deallocs, unlinking the second task's file.
    NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wk-upload-XXXXXX"];
    char nameTemplate[PATH_MAX];
    if (![templatePath getFileSystemRepresentation:nameTemplate maxLength:sizeof(nameTemplate)])
        return nil;
    int fd = mkstemp(nameTemplate);
    if (fd < 0)
        return nil;
    NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:nameTemplate length:strlen(nameTemplate)];

    [stream open];
    long long written = 0;
    uint8_t buffer[64 * 1024];
    bool ok = true;
    while (written < expected) {
        NSInteger wanted = (NSInteger)MIN((long long)sizeof(buffer), expected - written);
        NSInteger got = [stream read:buffer maxLength:wanted];
        if (got <= 0) {
            ok = false;
            break;
        }
        // write(2) + errno rather than -[NSFileHandle writeData:] and an exception handler: this file
        // already reports IO this way (see wk_appendFileContents), and a short write is a value to check,
        // not a condition to catch.
        ssize_t offset = 0;
        while (offset < got) {
            ssize_t n = write(fd, buffer + offset, (size_t)(got - offset));
            if (n <= 0) {
                if (n < 0 && errno == EINTR)
                    continue;
                ok = false;
                break;
            }
            offset += n;
        }
        if (!ok)
            break;
        written += got;
    }
    [stream close];
    close(fd);

    // Only a byte-exact spool may be substituted: anything else would ship a different body.
    if (!ok || written != expected) {
        unlink(nameTemplate);
        return nil;
    }
    *pathOut = path;
    return [NSURL fileURLWithPath:path];
}

static const void *wkUploadSpoolOwnerKey = &wkUploadSpoolOwnerKey;

static id wk_urlSession_taskForStreamedRequest(id self, SEL realSelector, NSURLRequest *request)
{
    // Nothing to substitute (no stream body, or no caller-set length): the real selector gets the request
    // untouched, with its stream unread.
    NSInputStream *bodyStream = [request HTTPBodyStream];
    NSString *lengthHeader = [request valueForHTTPHeaderField:@"Content-Length"];
    if (!bodyStream || ![lengthHeader length] || [lengthHeader longLongValue] <= 0)
        return ((id (*)(id, SEL, id))objc_msgSend)(self, realSelector, request);

    NSString *path = nil;
    NSURL *fileURL = wk_spoolStreamBodyToFile(request, &path);
    if (!fileURL) {
        // The spool failed with the stream partially consumed. Handing that stream to the real selector
        // would upload a truncated body, so report the failure instead: nil is what NSURLSession's task
        // creators return when they cannot make a task, and the loader treats it as a failed load.
        return nil;
    }

    NSMutableURLRequest *uploadRequest = [[request mutableCopy] autorelease];
    [uploadRequest setHTTPBodyStream:nil];
    // Let CFNetwork recompute the length from the file it is about to send.
    [uploadRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

    id task = ((id (*)(id, SEL, id, id))objc_msgSend)(self, sel_registerName("uploadTaskWithRequest:fromFile:"), uploadRequest, fileURL);
    if (!task) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        return ((id (*)(id, SEL, id))objc_msgSend)(self, realSelector, request);
    }
    // The spool outlives this call and must die with the task that reads it.
    WKPolyfillScopeUploadSpoolOwner *owner = [[WKPolyfillScopeUploadSpoolOwner alloc] init];
    owner->m_path = [path retain];
    objc_setAssociatedObject(task, wkUploadSpoolOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [owner release];
    return task;
}

static id wk_urlSession_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request)
{
    (void)_cmd;
    return wk_urlSession_taskForStreamedRequest(self, sel_registerName("dataTaskWithRequest:"), request);
}

static id wk_urlSession_uploadTaskWithStreamedRequest(id self, SEL _cmd, NSURLRequest *request)
{
    (void)_cmd;
    return wk_urlSession_taskForStreamedRequest(self, sel_registerName("uploadTaskWithStreamedRequest:"), request);
}

// Registered on the public class AND on the concrete one: NSURLSession is a class cluster whose
// __NSCFURLSession is NOT a subclass of NSURLSession (measured: __NSCFURLSession -> NSObject), so a
// method added only to the public class reaches no instance.
WK_POLYFILL_ADD_REPLACES("NSURLSession", "wk_dataTaskWithRequest:", wk_urlSession_dataTaskWithRequest, "@@:@");
WK_POLYFILL_ADD_REPLACES("__NSCFURLSession", "wk_dataTaskWithRequest:", wk_urlSession_dataTaskWithRequest, "@@:@");
WK_POLYFILL_SEL_REPLACES("dataTaskWithRequest:", "wk_dataTaskWithRequest:");
WK_POLYFILL_ADD_REPLACES("NSURLSession", "wk_uploadTaskWithStreamedRequest:", wk_urlSession_uploadTaskWithStreamedRequest, "@@:@");
WK_POLYFILL_ADD_REPLACES("__NSCFURLSession", "wk_uploadTaskWithStreamedRequest:", wk_urlSession_uploadTaskWithStreamedRequest, "@@:@");
WK_POLYFILL_SEL_REPLACES("uploadTaskWithStreamedRequest:", "wk_uploadTaskWithStreamedRequest:");
