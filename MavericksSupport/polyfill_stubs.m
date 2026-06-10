/* polyfill_stubs.m - Polyfill stubs for macOS 10.9 Mavericks
 * Provides C function stubs, ObjC class stubs, and API polyfills
 * for symbols not available on 10.9 but needed by modern WebKit 615.1.1
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - C function stubs

int CCRandomGenerateBytes(void *bytes, size_t count) {
    arc4random_buf(bytes, count);
    return 0;
}

void abort_with_reason(uint32_t a, uint64_t b, const char *c, uint64_t d) { abort(); }
void os_fault_with_payload(uint32_t a, uint64_t b, const void *c, uint32_t d, const char *e, uint64_t f) { }

// dyld stubs
bool dyld_program_sdk_at_least(uint32_t v) { return false; }
bool dyld_program_minos_at_least(uint32_t v) { return false; }
bool dyld_sdk_at_least(const void *h, uint32_t v) { return false; }

// cache/simulator stubs
void cache_simulate_size_response(uint64_t a, uint64_t b, uint64_t c) { }

// os_variant stubs
bool os_variant_allows_internal_security_policies(const char *s) { return false; }
bool os_variant_has_internal_content(const char *s) { return false; }
bool os_variant_has_internal_diagnostics(const char *s) { return false; }

// pthread
bool pthread_self_is_exiting_np(void) { return false; }

#pragma mark - ObjC class stubs (proper metadata for 10.9 ObjC runtime)
// Defined ONLY in JavaScriptCore.framework (JSC loads first). WebCore and WebKit
// reference these via their JSC dylib dependency — otherwise duplicate class
// registrations overflow libobjc's _read_images limit on 10.9.
#ifndef POLYFILL_NO_OBJC_CLASSES

@interface LSDatabaseContext : NSObject @end
@implementation LSDatabaseContext @end

@interface NSPresentationIntent : NSObject @end
@implementation NSPresentationIntent @end

@interface SecKeyProxy : NSObject @end
@implementation SecKeyProxy @end

// UTType polyfill — provides class methods returning UTType instances whose
// .identifier matches the kUTType* CFString constant. This avoids the
// unrecognized-selector crash from `UTTypeFileURL.identifier` etc.
@interface UTType : NSObject {
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

@interface NSTouchBar : NSObject @end
@implementation NSTouchBar @end

@interface NSCandidateListTouchBarItem : NSObject @end
@implementation NSCandidateListTouchBarItem @end

@interface NSColorPickerTouchBarItem : NSObject @end
@implementation NSColorPickerTouchBarItem @end

@interface NSPopoverTouchBarItem : NSObject @end
@implementation NSPopoverTouchBarItem @end

@interface NSTextTouchBarItemController : NSObject @end
@implementation NSTextTouchBarItemController @end

@interface NSFilePromiseReceiver : NSObject @end
@implementation NSFilePromiseReceiver @end

@interface LSAppLink : NSObject @end
@implementation LSAppLink @end

@interface _LSOpenConfiguration : NSObject @end
@implementation _LSOpenConfiguration @end

@interface WebSpeechRecognizerTask : NSObject @end
@implementation WebSpeechRecognizerTask @end

@interface _NSScrollingMomentumCalculator : NSObject @end
@implementation _NSScrollingMomentumCalculator @end

@interface _NSScrollingPredominantAxisFilter : NSObject @end
@implementation _NSScrollingPredominantAxisFilter @end

@interface WebFullScreenController : NSObject @end
@implementation WebFullScreenController @end

// WebViewVisualIdentificationOverlay: the real Source/WebCore/testing/cocoa/
// WebViewVisualIdentificationOverlay.mm is excluded from the build (it would
// duplicate this stub, since libpolyfill links into every framework). Both
// WKWebView and (legacy) WebView call +installForWebViewIfNeeded:kind:deprecated:
// at creation time, so the stub MUST implement that class method (as a no-op)
// or every web-view creation throws unrecognized-selector. The overlay is a
// debug/visual-identification affordance, so a no-op is functionally complete.
@interface WebViewVisualIdentificationOverlay : NSObject @end
@implementation WebViewVisualIdentificationOverlay
+ (void)installForWebViewIfNeeded:(id)view kind:(NSString *)kind deprecated:(BOOL)isDeprecated { }
@end

// WKWebInspectorProxyObjCAdapter and WebKeyGenerator are defined in
// Source/WebKit/PolyfillClasses_109.mm so Safari finds them in WebKit.framework
// (where it expects them) without duplicating them in JSC too.

// Additional stub classes that the polyfill previously provided as 3-byte
// function stubs (libobjc would crash on those). Defining them here as proper
// @interface/@implementation gives them real ObjC class metadata.
// NOTE: CATransformLayer (QuartzCore), NSColorPopoverController (AppKit) and
// SFCertificatePanel (SecurityInterface) are REAL classes that DO exist on macOS
// 10.9 — they must NOT be stubbed here, or the empty stub can shadow the genuine
// system class (e.g. CATransformLayer backs 3D CSS transforms). They resolve from
// their system frameworks, which WebCore/WebKit already link.
@interface LSBundleProxy : NSObject @end
@implementation LSBundleProxy @end
@interface WKCaptionStyleMenuController : NSObject @end
@implementation WKCaptionStyleMenuController @end
@interface WKDownloadProgress : NSObject @end
@implementation WKDownloadProgress @end
// WKInspectorViewController is compiled from real source
// (Source/WebKit/UIProcess/Inspector/mac/WKInspectorViewController.mm) into
// WebKit.framework, so it must NOT be stubbed here — doing so duplicated the
// symbol in the WebKit framework link.
@interface WKTextExtractionContainerItem : NSObject @end
@implementation WKTextExtractionContainerItem @end
@interface WKTextExtractionContentEditableItem : NSObject @end
@implementation WKTextExtractionContentEditableItem @end
@interface WKTextExtractionEditable : NSObject @end
@implementation WKTextExtractionEditable @end
@interface WKTextExtractionFormItem : NSObject @end
@implementation WKTextExtractionFormItem @end
@interface WKTextExtractionIFrameItem : NSObject @end
@implementation WKTextExtractionIFrameItem @end
@interface WKTextExtractionImageItem : NSObject @end
@implementation WKTextExtractionImageItem @end
@interface WKTextExtractionLink : NSObject @end
@implementation WKTextExtractionLink @end
@interface WKTextExtractionLinkItem : NSObject @end
@implementation WKTextExtractionLinkItem @end
@interface WKTextExtractionScrollableItem : NSObject @end
@implementation WKTextExtractionScrollableItem @end
@interface WKTextExtractionSelectItem : NSObject @end
@implementation WKTextExtractionSelectItem @end
@interface WKTextExtractionTextFormControlItem : NSObject @end
@implementation WKTextExtractionTextFormControlItem @end
@interface WKTextExtractionTextItem : NSObject @end
@implementation WKTextExtractionTextItem @end
@interface WebAVPlayerLayer : NSObject @end
@implementation WebAVPlayerLayer @end
@interface _NSHSTSStorage : NSObject @end
@implementation _NSHSTSStorage @end
@interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
@interface _NSHTTPAlternativeServicesStorage : NSObject @end
@implementation _NSHTTPAlternativeServicesStorage @end
@interface _WKTextExtractionInteractionResult : NSObject @end
@implementation _WKTextExtractionInteractionResult @end
@interface _WKTextExtractionResult : NSObject @end
@implementation _WKTextExtractionResult @end
@interface _WKTextManipulationItem : NSObject @end
@implementation _WKTextManipulationItem @end
@interface _WKTextPreview : NSObject @end
@implementation _WKTextPreview @end
@interface _WKWarningView : NSObject @end
@implementation _WKWarningView @end
@interface _WKWebPushDaemonConnection : NSObject @end
@implementation _WKWebPushDaemonConnection @end
@interface _WKWebPushMessage : NSObject @end
@implementation _WKWebPushMessage @end
@interface _WKWebPushSubscriptionData : NSObject @end
@implementation _WKWebPushSubscriptionData @end

#endif  // POLYFILL_NO_OBJC_CLASSES

#pragma mark - NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonBounds = @"NSPopUpMenuPopupButtonBounds";
NSString * const NSPopUpMenuPopupButtonOrigin = @"NSPopUpMenuPopupButtonOrigin";

#pragma mark - NSTouchBar notifications
NSString * const NSTouchBarDidExitCustomization = @"NSTouchBarDidExitCustomization";
NSString * const NSTouchBarWillEnterCustomization = @"NSTouchBarWillEnterCustomization";

#pragma mark - NSWorkspace polyfill (10.15+)
@implementation NSWorkspace (Polyfill10_9)
- (NSArray *)URLsForApplicationsToOpenURL:(NSURL *)url {
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end

#pragma mark - CGColorSpace polyfills

/* CGColorSpaceGetName (10.12+) */
CFStringRef CGColorSpaceGetName(CGColorSpaceRef cs) {
    return NULL;
}

/* CGColorSpaceEqualToColorSpace (10.12+) */
CG_EXTERN CFPropertyListRef CGColorSpaceCopyPropertyList(CGColorSpaceRef) __attribute__((weak_import));

bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef cs1, CGColorSpaceRef cs2) {
    if (cs1 == cs2) return true;
    if (!cs1 || !cs2) return false;
    if (CGColorSpaceGetModel(cs1) != CGColorSpaceGetModel(cs2)) return false;
    if (CGColorSpaceGetNumberOfComponents(cs1) != CGColorSpaceGetNumberOfComponents(cs2)) return false;
    if (CGColorSpaceCopyPropertyList) {
        CFPropertyListRef plist1 = CGColorSpaceCopyPropertyList(cs1);
        CFPropertyListRef plist2 = CGColorSpaceCopyPropertyList(cs2);
        bool equal = false;
        if (plist1 && plist2) equal = CFEqual(plist1, plist2);
        if (plist1) CFRelease(plist1);
        if (plist2) CFRelease(plist2);
        return equal;
    }
    return false;
}

#pragma mark - CGColorSpace name constants (10.11.2+)
CFStringRef const kCGColorSpaceDisplayP3 = CFSTR("kCGColorSpaceDisplayP3");
CFStringRef const kCGColorSpaceExtendedSRGB = CFSTR("kCGColorSpaceExtendedSRGB");
CFStringRef const kCGColorSpaceLinearSRGB = CFSTR("kCGColorSpaceLinearSRGB");
CFStringRef const kCGColorSpaceExtendedLinearSRGB = CFSTR("kCGColorSpaceExtendedLinearSRGB");
CFStringRef const kCGColorSpaceExtendedDisplayP3 = CFSTR("kCGColorSpaceExtendedDisplayP3");
CFStringRef const kCGColorSpaceLinearDisplayP3 = CFSTR("kCGColorSpaceLinearDisplayP3");
CFStringRef const kCGColorSpaceExtendedLinearDisplayP3 = CFSTR("kCGColorSpaceExtendedLinearDisplayP3");
CFStringRef const kCGColorSpaceITUR_2020 = CFSTR("kCGColorSpaceITUR_2020");
CFStringRef const kCGColorSpaceExtendedITUR_2020 = CFSTR("kCGColorSpaceExtendedITUR_2020");
CFStringRef const kCGColorSpaceROMMRGB = CFSTR("kCGColorSpaceROMMRGB");

#pragma mark - Additional dyld/cache stubs (10.10+)
const void *_dyld_get_dlopen_image_header(void *handle) { return NULL; }
const void *_dyld_get_image_uuid(const void *header) { return NULL; }
const void *_dyld_get_shared_cache_uuid(void) { return NULL; }
void cache_simulate_memory_warning_event(uint64_t a) { }
const char *dyld_shared_cache_file_path(void) { return NULL; }
const void *dyld_image_header_containing_address(const void *addr) { return NULL; }

#pragma mark - NSText constants (10.12+)
NSString * const NSTextCheckingInsertionPointKey = @"NSTextCheckingInsertionPointKey";
NSString * const NSTextInsertionUndoableAttributeName = @"NSTextInsertionUndoableAttributeName";

#pragma mark - Additional NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonLabelOffset = @"NSPopUpMenuPopupButtonLabelOffset";
NSString * const NSPopUpMenuPopupButtonSize = @"NSPopUpMenuPopupButtonSize";
NSString * const NSPopUpMenuPopupButtonWidget = @"NSPopUpMenuPopupButtonWidget";

#pragma mark - NSURLProtocol private methods (10.10+) used by Safari 9.x
// Safari 9.x calls +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] which is a 10.10+
// private API. On 10.9 this throws "doesNotRecognizeSelector". Provide a category that
// implements it by falling back to the public +[NSURLProtocol classForRequest:] equivalent
// (which doesn't exist publicly either, but the underlying lookup table does).
@interface NSURLProtocol (Polyfill_10_10)
+ (Class)_protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skip;
@end

@implementation NSURLProtocol (Polyfill_10_10)
+ (Class)_protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skip {
    // Safari uses this to find a URL protocol handler for AppSSO (Single Sign-On).
    // On 10.9 we don't have AppSSO, so just return nil — Safari will fall back to its
    // standard URL loading.
    (void)request; (void)skip;
    return Nil;
}
@end

#pragma mark - NSView beginDeferringViewInWindowChanges (10.11+)

// Safari 9's BrowserWindowControllerMac _selectTabAtIndex: calls
// -[NSView beginDeferringViewInWindowChanges] / endDeferringViewInWindowChanges
// before/after swapping the active tab's view (10.11+ NSView API).
// On 10.9 the call throws "unrecognized selector" and aborts Safari's tab
// transition — without this polyfill, Cmd+T leaves Safari with no visible tab
// bar and a blank content area. With the polyfill (no-op), Safari's transition
// completes: tab bar becomes visible, new tab shows its top-sites/favorites
// page. NOTE: the previous tab's WKView content is still lost on switch-back —
// that is a separate deeper bug being worked on independently.
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
