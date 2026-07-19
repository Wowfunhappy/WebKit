// polyfill_classes.m - ObjC class stubs for classes absent on macOS 10.9 (UTType, CABackdropLayer,
// NSVisualEffectView, LSDatabaseContext, the gutted WK* stubs, ...). Split out of polyfill_stubs.m so
// the class objects are compiled into exactly ONE archive (libpolyfill_classes.a, force-loaded into
// JavaScriptCore) and therefore defined in exactly ONE loaded framework. WebCore/WebKit2 resolve these
// classes from JavaScriptCore at load time. Previously polyfill_stubs.o (which held both the C stubs
// AND these classes) was pulled into JSC, WebCore AND WebKit2, so the ObjC runtime logged
// "Class X is implemented in both ... JavaScriptCore and ... WebKit2. One of the two will be used."
// for every class. The C function/constant stubs stay in polyfill_stubs.m -> libpolyfill.a.
//
// MAVERICKS_BACKPORT (WebKit-private polyfill classes): each stub is registered in the ObjC runtime
// under a PRIVATE name (WKMavPolyfillPriv_<Name>) via objc_runtime_name, and the real system symbol
// _OBJC_CLASS_$_<Name> is exported as an ALIAS to it (WK_PRIV_CLASS / WK_PRIV_ALIAS below). WebKit's
// compiled classrefs bind to the aliased symbol, so [<Name> ...] still resolves to the stub — but
// objc_getClass("<Name>") / NSClassFromString(@"<Name>") / objc_allocateClassPair(..., "<Name>", ...)
// see the system name as FREE. This keeps the stubs visible to WebKit while invisible to other apps
// in the same process: many 10.9-era apps polyfill these very classes themselves (e.g. Meta creates
// its own NSVisualEffectView via objc_allocateClassPair); without the private name our stub occupied
// the global name and objc_allocateClassPair returned nil -> objc_registerClassPair(nil) crashed the
// app at launch. For the three classes WebKit probes with NSClassFromString (NSVisualEffectView,
// CABackdropLayer, _NSScrollingMomentumCalculator) the nil result is the correct 10.9 answer: WebKit
// falls back to its pre-class code path instead of using a non-functional stub.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <dispatch/dispatch.h>
#include <mach/port.h>

// Place before an @interface to register the class under a private runtime name (the @interface name
// stays usable in code, so self-references like [UTType class] still compile).
#define WK_PRIV_CLASS(name) __attribute__((objc_runtime_name("WKMavPolyfillPriv_" #name)))
// Place after the matching @implementation to export the real _OBJC_CLASS_$_<name> (and metaclass)
// symbol as an alias of the privately-named class, so WebKit's classrefs bind to the stub.
#define WK_PRIV_ALIAS(name) __asm__( \
    ".globl _OBJC_CLASS_$_" #name "\n\t.set _OBJC_CLASS_$_" #name ", _OBJC_CLASS_$_WKMavPolyfillPriv_" #name "\n\t" \
    ".globl _OBJC_METACLASS_$_" #name "\n\t.set _OBJC_METACLASS_$_" #name ", _OBJC_METACLASS_$_WKMavPolyfillPriv_" #name)

WK_PRIV_CLASS(LSDatabaseContext) @interface LSDatabaseContext : NSObject @end
@implementation LSDatabaseContext @end
WK_PRIV_ALIAS(LSDatabaseContext);
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CALayer @end
@implementation CABackdropLayer @end
WK_PRIV_ALIAS(CABackdropLayer);
WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
WK_PRIV_CLASS(NSPresentationIntent) @interface NSPresentationIntent : NSObject @end
@implementation NSPresentationIntent @end
WK_PRIV_ALIAS(NSPresentationIntent);
WK_PRIV_CLASS(SecKeyProxy) @interface SecKeyProxy : NSObject @end
@implementation SecKeyProxy @end
WK_PRIV_ALIAS(SecKeyProxy);
// AuthKit's AKAuthorizationController is absent on 10.9. WebKit's SOAuthorizationCoordinator uses it
// as a class literal (to gate Apple-first-party subframe AppSSO), so supply _OBJC_CLASS_$_ via the
// alias. isURLFromAppleOwnedDomain: answers NO — the conservative 10.9 answer (the AppSSO path is
// itself inert here, since AppSSO.framework is absent), matching WebKit's own no-Apple-domain branch.
WK_PRIV_CLASS(AKAuthorizationController) @interface AKAuthorizationController : NSObject
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url;
@end
@implementation AKAuthorizationController
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url { return NO; }
@end
WK_PRIV_ALIAS(AKAuthorizationController);
WK_PRIV_CLASS(UTType) @interface UTType : NSObject {
    NSString *_identifier;
}
@property (nullable, copy, readonly) NSString *identifier;
@end
@implementation UTType
@synthesize identifier = _identifier;
- (instancetype)initWithIdentifier:(NSString *)ident
{
    if ((self = [super init]))
        _identifier = [ident copy];
    return self;
}
- (void)dealloc { [_identifier release]; [super dealloc]; }
+ (instancetype)_polyfillTypeWith:(CFStringRef)ident
{
    if (!ident) return nil;
    return [[[self alloc] initWithIdentifier:(__bridge NSString *)ident] autorelease];
}
+ (instancetype)png       { return [self _polyfillTypeWith:kUTTypePNG]; }
+ (instancetype)jpeg      { return [self _polyfillTypeWith:kUTTypeJPEG]; }
+ (instancetype)tiff      { return [self _polyfillTypeWith:kUTTypeTIFF]; }
+ (instancetype)gif       { return [self _polyfillTypeWith:kUTTypeGIF]; }
+ (instancetype)bmp       { return [self _polyfillTypeWith:kUTTypeBMP]; }
+ (instancetype)pdf       { return [self _polyfillTypeWith:kUTTypePDF]; }
+ (instancetype)rtf       { return [self _polyfillTypeWith:kUTTypeRTF]; }
+ (instancetype)rtfd      { return [self _polyfillTypeWith:kUTTypeRTFD]; }
+ (instancetype)flatRTFD  { return [self _polyfillTypeWith:kUTTypeFlatRTFD]; }
+ (instancetype)html      { return [self _polyfillTypeWith:kUTTypeHTML]; }
+ (instancetype)xml       { return [self _polyfillTypeWith:kUTTypeXML]; }
+ (instancetype)text      { return [self _polyfillTypeWith:kUTTypeText]; }
+ (instancetype)plainText { return [self _polyfillTypeWith:kUTTypePlainText]; }
+ (instancetype)utf8PlainText { return [self _polyfillTypeWith:kUTTypeUTF8PlainText]; }
+ (instancetype)url       { return [self _polyfillTypeWith:kUTTypeURL]; }
+ (instancetype)fileURL   { return [self _polyfillTypeWith:kUTTypeFileURL]; }
+ (instancetype)image     { return [self _polyfillTypeWith:kUTTypeImage]; }
+ (instancetype)movie     { return [self _polyfillTypeWith:kUTTypeMovie]; }
+ (instancetype)audio     { return [self _polyfillTypeWith:kUTTypeAudio]; }
+ (instancetype)video     { return [self _polyfillTypeWith:kUTTypeVideo]; }
+ (instancetype)data      { return [self _polyfillTypeWith:kUTTypeData]; }
+ (instancetype)content   { return [self _polyfillTypeWith:kUTTypeContent]; }
+ (instancetype)item      { return [self _polyfillTypeWith:kUTTypeItem]; }
+ (instancetype)directory { return [self _polyfillTypeWith:kUTTypeDirectory]; }
+ (instancetype)folder    { return [self _polyfillTypeWith:kUTTypeFolder]; }
+ (instancetype)vCard     { return [self _polyfillTypeWith:kUTTypeVCard]; }
+ (instancetype)webArchive { return [[[self alloc] initWithIdentifier:@"com.apple.webarchive"] autorelease]; }
+ (instancetype)mp3       { return [self _polyfillTypeWith:kUTTypeMP3]; }
+ (instancetype)mpeg      { return [self _polyfillTypeWith:kUTTypeMPEG]; }
+ (instancetype)mpeg4Movie { return [self _polyfillTypeWith:kUTTypeMPEG4]; }
+ (instancetype)mpeg4Audio { return [self _polyfillTypeWith:kUTTypeMPEG4Audio]; }
+ (instancetype)quickTimeMovie { return [self _polyfillTypeWith:kUTTypeQuickTimeMovie]; }
+ (instancetype)application { return [self _polyfillTypeWith:kUTTypeApplication]; }
+ (instancetype)applicationBundle { return [self _polyfillTypeWith:kUTTypeApplicationBundle]; }
+ (instancetype)compositeContent { return [self _polyfillTypeWith:kUTTypeCompositeContent]; }
+ (instancetype)sourceCode { return [self _polyfillTypeWith:kUTTypeSourceCode]; }
+ (instancetype)icns      { return [self _polyfillTypeWith:kUTTypeAppleICNS]; }
+ (instancetype)ico       { return [self _polyfillTypeWith:kUTTypeICO]; }
+ (instancetype)utf16PlainText { return [self _polyfillTypeWith:kUTTypeUTF16PlainText]; }
+ (instancetype)webP      { return [[[self alloc] initWithIdentifier:@"public.webp"] autorelease]; }
+ (instancetype)heic      { return [[[self alloc] initWithIdentifier:@"public.heic"] autorelease]; }
+ (instancetype)svg       { return [[[self alloc] initWithIdentifier:@"public.svg-image"] autorelease]; }
// Aliases to handle both lowercase (real UTType API) and uppercase (some WebKit code) selectors.
+ (instancetype)PNG       { return [self png]; }
+ (instancetype)JPEG      { return [self jpeg]; }
+ (instancetype)TIFF      { return [self tiff]; }
+ (instancetype)GIF       { return [self gif]; }
+ (instancetype)BMP       { return [self bmp]; }
+ (instancetype)PDF       { return [self pdf]; }
+ (instancetype)RTF       { return [self rtf]; }
+ (instancetype)RTFD      { return [self rtfd]; }
+ (instancetype)HTML      { return [self html]; }
+ (instancetype)XML       { return [self xml]; }
+ (instancetype)URL       { return [self url]; }
+ (instancetype)UTF8PlainText { return [self utf8PlainText]; }
+ (nullable instancetype)typeWithIdentifier:(NSString *)ident
{
    if (!ident) return nil;
    return [[[self alloc] initWithIdentifier:ident] autorelease];
}
+ (nullable instancetype)typeWithFilenameExtension:(NSString *)ext
{
    if (!ext) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)ext, NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
+ (nullable instancetype)typeWithMIMEType:(NSString *)mimeType
{
    if (!mimeType) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)mimeType, NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
- (BOOL)conformsToType:(UTType *)other
{
    if (!other || !_identifier || !other->_identifier) return NO;
    return UTTypeConformsTo((__bridge CFStringRef)_identifier, (__bridge CFStringRef)other->_identifier);
}
- (NSString *)preferredMIMEType
{
    if (!_identifier) return nil;
    CFStringRef mime = UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)_identifier, kUTTagClassMIMEType);
    if (!mime) return nil;
    return [(__bridge NSString *)mime autorelease];
}
- (NSString *)preferredFilenameExtension
{
    if (!_identifier) return nil;
    CFStringRef ext = UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)_identifier, kUTTagClassFilenameExtension);
    if (!ext) return nil;
    return [(__bridge NSString *)ext autorelease];
}
- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[UTType class]]) return NO;
    NSString *otherId = ((UTType *)other)->_identifier;
    if (!_identifier) return !otherId;
    return [_identifier isEqualToString:otherId];
}
- (NSUInteger)hash { return _identifier.hash; }
// 11.0+ instance method used by WebCore::canWritePasteboardType during Cmd+C copy.
// Without this, Safari crashes on every copy operation with NSInvalidArgumentException.
// UTTypeIsDeclared isn't exported from CoreServices on 10.9, so use the convention
// that "dyn." prefixed UTIs are dynamic / not-declared, and everything else is
// treated as declared (matches LaunchServices semantics for the common cases).
- (BOOL)isDeclared
{
    if (!_identifier) return NO;
    return ![_identifier hasPrefix:@"dyn."];
}
- (BOOL)isDynamic
{
    if (!_identifier) return NO;
    return [_identifier hasPrefix:@"dyn."];
}
@end
WK_PRIV_ALIAS(UTType);
WK_PRIV_CLASS(NSFilePromiseReceiver) @interface NSFilePromiseReceiver : NSObject @end
@implementation NSFilePromiseReceiver @end
WK_PRIV_ALIAS(NSFilePromiseReceiver);
WK_PRIV_CLASS(LSAppLink) @interface LSAppLink : NSObject @end
@implementation LSAppLink @end
WK_PRIV_ALIAS(LSAppLink);
WK_PRIV_CLASS(_LSOpenConfiguration) @interface _LSOpenConfiguration : NSObject @end
@implementation _LSOpenConfiguration @end
WK_PRIV_ALIAS(_LSOpenConfiguration);
WK_PRIV_CLASS(WebSpeechRecognizerTask) @interface WebSpeechRecognizerTask : NSObject @end
@implementation WebSpeechRecognizerTask @end
WK_PRIV_ALIAS(WebSpeechRecognizerTask);
WK_PRIV_CLASS(_NSScrollingMomentumCalculator) @interface _NSScrollingMomentumCalculator : NSObject @end
@implementation _NSScrollingMomentumCalculator @end
WK_PRIV_ALIAS(_NSScrollingMomentumCalculator);
WK_PRIV_CLASS(_NSScrollingPredominantAxisFilter) @interface _NSScrollingPredominantAxisFilter : NSObject @end
@implementation _NSScrollingPredominantAxisFilter @end
WK_PRIV_ALIAS(_NSScrollingPredominantAxisFilter);
// NOTE: WebFullScreenController is intentionally NOT stubbed here — it is a REAL class implemented by
// WebKitLegacy (Source/WebKitLegacy/mac/WebView/WebFullScreenController.mm). No other framework references
// it, so a polyfill stub only produces a duplicate "Class WebFullScreenController is implemented in both
// libpolyfill_classes.dylib and WebKit.framework" warning. Leave it to WebKitLegacy.
WK_PRIV_CLASS(WebViewVisualIdentificationOverlay) @interface WebViewVisualIdentificationOverlay : NSObject @end
@implementation WebViewVisualIdentificationOverlay
+ (void)installForWebViewIfNeeded:(id)view kind:(NSString *)kind deprecated:(BOOL)isDeprecated { }
@end
WK_PRIV_ALIAS(WebViewVisualIdentificationOverlay);
WK_PRIV_CLASS(LSBundleProxy) @interface LSBundleProxy : NSObject @end
@implementation LSBundleProxy @end
WK_PRIV_ALIAS(LSBundleProxy);
WK_PRIV_CLASS(WKCaptionStyleMenuController) @interface WKCaptionStyleMenuController : NSObject @end
@implementation WKCaptionStyleMenuController @end
WK_PRIV_ALIAS(WKCaptionStyleMenuController);
WK_PRIV_CLASS(WKDownloadProgress) @interface WKDownloadProgress : NSObject @end
@implementation WKDownloadProgress @end
WK_PRIV_ALIAS(WKDownloadProgress);
WK_PRIV_CLASS(WKTextExtractionContainerItem) @interface WKTextExtractionContainerItem : NSObject @end
@implementation WKTextExtractionContainerItem @end
WK_PRIV_ALIAS(WKTextExtractionContainerItem);
WK_PRIV_CLASS(WKTextExtractionContentEditableItem) @interface WKTextExtractionContentEditableItem : NSObject @end
@implementation WKTextExtractionContentEditableItem @end
WK_PRIV_ALIAS(WKTextExtractionContentEditableItem);
WK_PRIV_CLASS(WKTextExtractionEditable) @interface WKTextExtractionEditable : NSObject @end
@implementation WKTextExtractionEditable @end
WK_PRIV_ALIAS(WKTextExtractionEditable);
WK_PRIV_CLASS(WKTextExtractionFormItem) @interface WKTextExtractionFormItem : NSObject @end
@implementation WKTextExtractionFormItem @end
WK_PRIV_ALIAS(WKTextExtractionFormItem);
WK_PRIV_CLASS(WKTextExtractionIFrameItem) @interface WKTextExtractionIFrameItem : NSObject @end
@implementation WKTextExtractionIFrameItem @end
WK_PRIV_ALIAS(WKTextExtractionIFrameItem);
WK_PRIV_CLASS(WKTextExtractionImageItem) @interface WKTextExtractionImageItem : NSObject @end
@implementation WKTextExtractionImageItem @end
WK_PRIV_ALIAS(WKTextExtractionImageItem);
WK_PRIV_CLASS(WKTextExtractionLink) @interface WKTextExtractionLink : NSObject @end
@implementation WKTextExtractionLink @end
WK_PRIV_ALIAS(WKTextExtractionLink);
WK_PRIV_CLASS(WKTextExtractionLinkItem) @interface WKTextExtractionLinkItem : NSObject @end
@implementation WKTextExtractionLinkItem @end
WK_PRIV_ALIAS(WKTextExtractionLinkItem);
WK_PRIV_CLASS(WKTextExtractionScrollableItem) @interface WKTextExtractionScrollableItem : NSObject @end
@implementation WKTextExtractionScrollableItem @end
WK_PRIV_ALIAS(WKTextExtractionScrollableItem);
WK_PRIV_CLASS(WKTextExtractionSelectItem) @interface WKTextExtractionSelectItem : NSObject @end
@implementation WKTextExtractionSelectItem @end
WK_PRIV_ALIAS(WKTextExtractionSelectItem);
WK_PRIV_CLASS(WKTextExtractionTextFormControlItem) @interface WKTextExtractionTextFormControlItem : NSObject @end
@implementation WKTextExtractionTextFormControlItem @end
WK_PRIV_ALIAS(WKTextExtractionTextFormControlItem);
WK_PRIV_CLASS(WKTextExtractionTextItem) @interface WKTextExtractionTextItem : NSObject @end
@implementation WKTextExtractionTextItem @end
WK_PRIV_ALIAS(WKTextExtractionTextItem);
WK_PRIV_CLASS(WebAVPlayerLayer) @interface WebAVPlayerLayer : NSObject @end
@implementation WebAVPlayerLayer @end
WK_PRIV_ALIAS(WebAVPlayerLayer);
WK_PRIV_CLASS(_NSHSTSStorage) @interface _NSHSTSStorage : NSObject @end
@implementation _NSHSTSStorage @end
WK_PRIV_ALIAS(_NSHSTSStorage);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesFilter) @interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesFilter);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesStorage) @interface _NSHTTPAlternativeServicesStorage : NSObject @end
@implementation _NSHTTPAlternativeServicesStorage @end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesStorage);
WK_PRIV_CLASS(_WKTextExtractionInteractionResult) @interface _WKTextExtractionInteractionResult : NSObject @end
@implementation _WKTextExtractionInteractionResult @end
WK_PRIV_ALIAS(_WKTextExtractionInteractionResult);
WK_PRIV_CLASS(_WKTextExtractionResult) @interface _WKTextExtractionResult : NSObject @end
@implementation _WKTextExtractionResult @end
WK_PRIV_ALIAS(_WKTextExtractionResult);
WK_PRIV_CLASS(_WKTextPreview) @interface _WKTextPreview : NSObject @end
@implementation _WKTextPreview @end
WK_PRIV_ALIAS(_WKTextPreview);
WK_PRIV_CLASS(_WKWarningView) @interface _WKWarningView : NSObject @end
@implementation _WKWarningView @end
WK_PRIV_ALIAS(_WKWarningView);
WK_PRIV_CLASS(_WKWebPushDaemonConnection) @interface _WKWebPushDaemonConnection : NSObject @end
@implementation _WKWebPushDaemonConnection @end
WK_PRIV_ALIAS(_WKWebPushDaemonConnection);
WK_PRIV_CLASS(_WKWebPushMessage) @interface _WKWebPushMessage : NSObject @end
@implementation _WKWebPushMessage @end
WK_PRIV_ALIAS(_WKWebPushMessage);
WK_PRIV_CLASS(_WKWebPushSubscriptionData) @interface _WKWebPushSubscriptionData : NSObject @end
@implementation _WKWebPushSubscriptionData @end
WK_PRIV_ALIAS(_WKWebPushSubscriptionData);
@implementation NSWorkspace (Polyfill10_9)
- (NSArray *)URLsForApplicationsToOpenURL:(NSURL *)url {
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end
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
@interface NSLocale (Polyfill10_9)
+ (NSArray *)matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages;
@end
static NSString *wk_primaryLanguageSubtag(NSString *languageTag) {
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
@implementation NSLocale (Polyfill10_9)
+ (NSArray *)matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages {
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
@interface NSView (Polyfill_10_11_DeferViewInWindow)
- (void)beginDeferringViewInWindowChanges;
- (void)endDeferringViewInWindowChanges;
- (void)endDeferringViewInWindowChangesSync;
@end
@implementation NSView (Polyfill_10_11_DeferViewInWindow)
- (void)beginDeferringViewInWindowChanges { /* 10.9 no-op */ }
- (void)endDeferringViewInWindowChanges { /* 10.9 no-op */ }
- (void)endDeferringViewInWindowChangesSync { /* 10.9 no-op */ }
@end
WK_PRIV_CLASS(NSVisualEffectView) @interface NSVisualEffectView : NSView @end
@implementation NSVisualEffectView @end
WK_PRIV_ALIAS(NSVisualEffectView);
WK_PRIV_CLASS(NSDateComponentsFormatter) @interface NSDateComponentsFormatter : NSFormatter @end
@implementation NSDateComponentsFormatter @end
WK_PRIV_ALIAS(NSDateComponentsFormatter);
