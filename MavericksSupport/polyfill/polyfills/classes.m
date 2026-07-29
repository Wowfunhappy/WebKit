// classes.m - Objective-C classes macOS 10.9 does not have at all (UTType, CABackdropLayer,
// NSVisualEffectView, LSDatabaseContext, ...). Each stub supplies as much of the class as WebKit's 10.9
// code paths actually use.
//
// ONLY absent SYSTEM classes belong here, with no exceptions. A class WebKit itself owns has its source
// in this tree; if it does not build on 10.9, fix that instead of stubbing it here — a stub of a WebKit
// class is a silent reimplementation with the wrong shape and no methods, so every message the real
// class would answer raises NSInvalidArgumentException instead.
//
// This file is the one polyfill unit built WITHOUT
// -fvisibility=hidden, and it is linked into every WebKit framework, so anything it defines is
// process-global in every app that embeds WebKit. A category adding a method to a class 10.9 DOES have
// would therefore be visible to the host app, whose version probes would then be answered wrongly —
// that is what mechanism/wk_selref_scope.m exists to prevent. Method polyfills go in methods.m.
//
// This file compiles against the 10.9 headers, so the modern SDK's @interface for a stubbed class is
// not in scope ("cannot find interface declaration") and a bare @implementation would produce a
// root class with no superclass. Declare a minimal @interface naming the correct superclass first, so
// the class gets real ObjC metadata.
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
// app at launch. For the two classes WebKit probes with NSClassFromString (NSVisualEffectView,
// _NSScrollingMomentumCalculator) the nil result is the correct 10.9 answer: WebKit falls back to its
// pre-class code path instead of using a non-functional stub. Every other stub (UTType, CABackdropLayer,
// NSPresentationIntent, ...) is reached through a compile-time [Name class] / _OBJC_CLASS_$_ classref,
// which binds to the alias, so those ARE used.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
// For CMSampleBufferRef in the AVCapturePhotoOutput stub's still-image callback. Header only: no
// CoreMedia symbol is referenced here, so this does not put CoreMedia on the dylib's load commands.
#import <CoreMedia/CMSampleBuffer.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <math.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <dispatch/dispatch.h>
#include <mach/port.h>

// For WK_POLYFILL_CLASS: a stub WebKit soft-links has to be findable by NAME, which the private
// runtime name below otherwise prevents. See the AVFoundation section at the end of this file.
#include "wk_polyfill.h"

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
// CABackdropLayer (absent on 10.9): a CALayer-backed backdrop/blur layer. 10.9 has no backdrop
// compositing, so this shadow is a plain CALayer subclass — visually identical to a bare CALayer — but a
// real distinct class, so PlatformCALayerCocoa / RemoteLayerTreeHost keep upstream's [CABackdropLayer class]
// and the isKindOfClass: / (CABackdropLayer *) casts behave as upstream. -setWindowServerAware: is the one
// method WebKit sends it (backdrop layers are marked not-window-server-aware); 10.9 has no such concept, so
// it is a faithful no-op.
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CALayer
- (void)setWindowServerAware:(BOOL)aware;
@end
@implementation CABackdropLayer
- (void)setWindowServerAware:(BOOL)aware { (void)aware; }
@end
WK_PRIV_ALIAS(CABackdropLayer);
WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
// NSPresentationIntent (Foundation, 12.0+): the semantic-structure metadata an attributed string
// carries alongside its visual attributes (this block is a quote / a header of level N / table cell
// (r,c) ...). It is a pure immutable data holder — Foundation attaches no behavior to it — so the
// class is reimplementable in full. WebKit's uses: HTMLConverter builds a blockquote intent chain
// (+blockQuoteIntentWithIdentity:nestedInsideIntent:, -parentIntent) and stores it under
// NSPresentationIntentAttributeName (see constants.m); WebKit IPC (CoreIPCPresentationIntent) reads
// every property below and rebuilds the intent on the other side through the same factory methods.
// The kind values mirror the modern SDK's NSPresentationIntentKind declaration order (this file
// compiles against the 10.9 headers, which lack the enum).
typedef NS_ENUM(NSInteger, WKPolyfillNSPresentationIntentKind) {
    WKPolyfillNSPresentationIntentKindParagraph,
    WKPolyfillNSPresentationIntentKindHeader,
    WKPolyfillNSPresentationIntentKindOrderedList,
    WKPolyfillNSPresentationIntentKindUnorderedList,
    WKPolyfillNSPresentationIntentKindListItem,
    WKPolyfillNSPresentationIntentKindCodeBlock,
    WKPolyfillNSPresentationIntentKindBlockQuote,
    WKPolyfillNSPresentationIntentKindThematicBreak,
    WKPolyfillNSPresentationIntentKindTable,
    WKPolyfillNSPresentationIntentKindTableHeaderRow,
    WKPolyfillNSPresentationIntentKindTableRow,
    WKPolyfillNSPresentationIntentKindTableCell,
};
WK_PRIV_CLASS(NSPresentationIntent) @interface NSPresentationIntent : NSObject <NSCopying, NSSecureCoding> {
    NSInteger _intentKind;
    NSInteger _identity;
    NSPresentationIntent *_parentIntent;
    NSInteger _headerLevel;
    NSInteger _ordinal;
    NSString *_languageHint;
    NSArray *_columnAlignments;
    NSInteger _columnCount;
    NSInteger _row;
    NSInteger _column;
}
@property (readonly) NSInteger intentKind;
@property (readonly) NSInteger identity;
@property (readonly, retain) NSPresentationIntent *parentIntent;
@property (readonly) NSInteger headerLevel;
@property (readonly) NSInteger ordinal;
@property (readonly, copy) NSString *languageHint;
@property (readonly, copy) NSArray *columnAlignments;
@property (readonly) NSInteger columnCount;
@property (readonly) NSInteger row;
@property (readonly) NSInteger column;
@end
@implementation NSPresentationIntent
@synthesize intentKind = _intentKind;
@synthesize identity = _identity;
@synthesize parentIntent = _parentIntent;
@synthesize headerLevel = _headerLevel;
@synthesize ordinal = _ordinal;
@synthesize languageHint = _languageHint;
@synthesize columnAlignments = _columnAlignments;
@synthesize columnCount = _columnCount;
@synthesize row = _row;
@synthesize column = _column;
- (instancetype)_initWithKind:(NSInteger)kind identity:(NSInteger)identity parent:(NSPresentationIntent *)parent
{
    if ((self = [super init])) {
        _intentKind = kind;
        _identity = identity;
        _parentIntent = [parent retain];
    }
    return self;
}
- (void)dealloc
{
    [_parentIntent release];
    [_languageHint release];
    [_columnAlignments release];
    [super dealloc];
}
+ (NSPresentationIntent *)paragraphIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindParagraph identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)headerIntentWithIdentity:(NSInteger)identity level:(NSInteger)level nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindHeader identity:identity parent:parent] autorelease];
    intent->_headerLevel = level;
    return intent;
}
+ (NSPresentationIntent *)codeBlockIntentWithIdentity:(NSInteger)identity languageHint:(NSString *)languageHint nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindCodeBlock identity:identity parent:parent] autorelease];
    intent->_languageHint = [languageHint copy];
    return intent;
}
+ (NSPresentationIntent *)thematicBreakIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindThematicBreak identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)orderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindOrderedList identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)unorderedListIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindUnorderedList identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)listItemIntentWithIdentity:(NSInteger)identity ordinal:(NSInteger)ordinal nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindListItem identity:identity parent:parent] autorelease];
    intent->_ordinal = ordinal;
    return intent;
}
+ (NSPresentationIntent *)blockQuoteIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindBlockQuote identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)tableIntentWithIdentity:(NSInteger)identity columnCount:(NSInteger)columnCount alignments:(NSArray *)alignments nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTable identity:identity parent:parent] autorelease];
    intent->_columnCount = columnCount;
    intent->_columnAlignments = [alignments copy];
    return intent;
}
+ (NSPresentationIntent *)tableHeaderRowIntentWithIdentity:(NSInteger)identity nestedInsideIntent:(NSPresentationIntent *)parent
{
    return [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableHeaderRow identity:identity parent:parent] autorelease];
}
+ (NSPresentationIntent *)tableRowIntentWithIdentity:(NSInteger)identity row:(NSInteger)row nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableRow identity:identity parent:parent] autorelease];
    intent->_row = row;
    return intent;
}
+ (NSPresentationIntent *)tableCellIntentWithIdentity:(NSInteger)identity column:(NSInteger)column nestedInsideIntent:(NSPresentationIntent *)parent
{
    NSPresentationIntent *intent = [[[self alloc] _initWithKind:WKPolyfillNSPresentationIntentKindTableCell identity:identity parent:parent] autorelease];
    intent->_column = column;
    return intent;
}
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return [self retain]; // Immutable.
}
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:_intentKind forKey:@"intentKind"];
    [coder encodeInteger:_identity forKey:@"identity"];
    [coder encodeObject:_parentIntent forKey:@"parentIntent"];
    [coder encodeInteger:_headerLevel forKey:@"headerLevel"];
    [coder encodeInteger:_ordinal forKey:@"ordinal"];
    [coder encodeObject:_languageHint forKey:@"languageHint"];
    [coder encodeObject:_columnAlignments forKey:@"columnAlignments"];
    [coder encodeInteger:_columnCount forKey:@"columnCount"];
    [coder encodeInteger:_row forKey:@"row"];
    [coder encodeInteger:_column forKey:@"column"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _intentKind = [coder decodeIntegerForKey:@"intentKind"];
        _identity = [coder decodeIntegerForKey:@"identity"];
        _parentIntent = [[coder decodeObjectOfClass:[NSPresentationIntent class] forKey:@"parentIntent"] retain];
        _headerLevel = [coder decodeIntegerForKey:@"headerLevel"];
        _ordinal = [coder decodeIntegerForKey:@"ordinal"];
        _languageHint = [[coder decodeObjectOfClass:[NSString class] forKey:@"languageHint"] copy];
        _columnAlignments = [[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSNumber class], nil] forKey:@"columnAlignments"] copy];
        _columnCount = [coder decodeIntegerForKey:@"columnCount"];
        _row = [coder decodeIntegerForKey:@"row"];
        _column = [coder decodeIntegerForKey:@"column"];
    }
    return self;
}
// requireIdentity distinguishes -isEqual: (identity counts, recursively) from
// -isEquivalentToPresentationIntent: ("the same as equality except that identity is not taken
// into account"); the parent chain is compared under the same rule as the receiver.
static BOOL wkPresentationIntentsEqual(NSPresentationIntent *a, NSPresentationIntent *b, BOOL requireIdentity)
{
    if (a == b)
        return YES;
    if (!a || !b)
        return NO;
    if (requireIdentity && a->_identity != b->_identity)
        return NO;
    return a->_intentKind == b->_intentKind
        && a->_headerLevel == b->_headerLevel
        && a->_ordinal == b->_ordinal
        && (a->_languageHint == b->_languageHint || [a->_languageHint isEqualToString:b->_languageHint])
        && (a->_columnAlignments == b->_columnAlignments || [a->_columnAlignments isEqualToArray:b->_columnAlignments])
        && a->_columnCount == b->_columnCount
        && a->_row == b->_row
        && a->_column == b->_column
        && wkPresentationIntentsEqual(a->_parentIntent, b->_parentIntent, requireIdentity);
}
- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSPresentationIntent class]])
        return NO;
    return wkPresentationIntentsEqual(self, other, YES);
}
- (BOOL)isEquivalentToPresentationIntent:(NSPresentationIntent *)other
{
    if (![other isKindOfClass:[NSPresentationIntent class]])
        return NO;
    return wkPresentationIntentsEqual(self, other, NO);
}
// "Each nested list increases the indentation level by one; all elements within the same list
// have the same indentation level. Text outside list intents has an indentation level of 0."
- (NSInteger)indentationLevel
{
    NSInteger level = 0;
    for (NSPresentationIntent *intent = self; intent; intent = intent->_parentIntent) {
        if (intent->_intentKind == WKPolyfillNSPresentationIntentKindOrderedList
            || intent->_intentKind == WKPolyfillNSPresentationIntentKindUnorderedList)
            level++;
    }
    return level;
}
- (NSUInteger)hash
{
    return (NSUInteger)_intentKind ^ ((NSUInteger)_identity << 4);
}
@end
WK_PRIV_ALIAS(NSPresentationIntent);
WK_PRIV_CLASS(SecKeyProxy) @interface SecKeyProxy : NSObject @end
@implementation SecKeyProxy @end
WK_PRIV_ALIAS(SecKeyProxy);
// AuthKit's AKAuthorizationController. This stub exists ONLY to satisfy a link-time reference, and
// its one method is not reachable on this OS.
//
// The link-time reference: PlatformMac.cmake drops upstream's -framework AuthKit (no AuthKit.framework
// on 10.9 and none in the build SDK), while SOAuthorizationCoordinator.mm still names the class as a
// literal, which emits _OBJC_CLASS_$_AKAuthorizationController. The alias below supplies it.
//
// Why the method cannot run: its sole call site (SOAuthorizationCoordinator::tryAuthorize, the
// subframe check) sits inside the canAuthorize completion after `if (!result) return;`, and
// canAuthorize completes false immediately whenever m_hasAppSSO is false. m_hasAppSSO is
// !!getSOAuthorizationClassSingleton(), soft-linked from AppSSO.framework — which does not exist on
// 10.9 either. Upstream handles exactly this case itself (its "base system, which doesn't have
// AppSSO.framework" early return), so no gate is being bent here; the whole feature is inert.
//
// The verdict is therefore unobservable, and it is also not computable: "Apple-owned domain" is a
// registry AuthKit ships, and nothing on 10.9 vends it (no framework in /System/Library exports any
// AppleOwnedDomain symbol). NO is what the absent framework's absence means — there is no
// Apple-first-party authorization on this OS — not a claim about any particular URL.
WK_PRIV_CLASS(AKAuthorizationController) @interface AKAuthorizationController : NSObject
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url;
@end
@implementation AKAuthorizationController
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url { (void)url; return NO; }
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
// 11.0+ instance methods used by WebCore::canWritePasteboardType during Cmd+C copy and by
// typeIdentifierForPasteboardType. Without them, Safari raises NSInvalidArgumentException on copy.
//
// These are the same two questions the C UTTypeIsDeclared/UTTypeIsDynamic answer, and they are
// implemented the same way here so this layer cannot disagree with itself — see the note there.
// "declared" is LaunchServices' answer (UTTypeCopyDeclaration, present on 10.9), not the "dyn."
// prefix: the prefix test called public.webp declared, and on this host it is not, which is exactly
// what canWritePasteboardType asks about.
- (BOOL)isDeclared
{
    if (!_identifier) return NO;
    CFDictionaryRef declaration = UTTypeCopyDeclaration((__bridge CFStringRef)_identifier);
    if (!declaration) return NO;
    CFRelease(declaration);
    return YES;
}
// A dynamic UTI is by construction one LaunchServices synthesised under the "dyn." prefix, so the
// prefix IS the test.
- (BOOL)isDynamic
{
    if (!_identifier) return NO;
    return [_identifier hasPrefix:@"dyn."];
}
// _parentTypes (11.0+ SPI, pal/spi/cocoa/UniformTypeIdentifiersSPI.h): the types this type directly
// conforms to. UTIUtilities' mimeTypeFromUTITree walks it when a type is neither declared nor dynamic.
// Answered from the LaunchServices declaration's kUTTypeConformsToKey (a single identifier or an array
// of them) — the same registry the modern framework reads. No declaration means no known parents, and
// nil is what the caller's walk expects then.
- (NSOrderedSet *)_parentTypes
{
    if (!_identifier) return nil;
    CFDictionaryRef declaration = UTTypeCopyDeclaration((__bridge CFStringRef)_identifier);
    if (!declaration) return nil;
    CFTypeRef conformsTo = CFDictionaryGetValue(declaration, kUTTypeConformsToKey);
    NSMutableOrderedSet *parents = [NSMutableOrderedSet orderedSet];
    NSArray *identifiers = nil;
    if (conformsTo && CFGetTypeID(conformsTo) == CFStringGetTypeID())
        identifiers = [NSArray arrayWithObject:(__bridge NSString *)conformsTo];
    else if (conformsTo && CFGetTypeID(conformsTo) == CFArrayGetTypeID())
        identifiers = (__bridge NSArray *)conformsTo;
    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:[NSString class]])
            continue;
        UTType *parent = [UTType typeWithIdentifier:identifier];
        if (parent)
            [parents addObject:parent];
    }
    CFRelease(declaration);
    return parents;
}
@end
WK_PRIV_ALIAS(UTType);
// UniformTypeIdentifiers (11.0+) also EXPORTS each standard type as an object constant (UTTypePNG,
// UTTypePackage, ...), which upstream references directly (`UTTypePNG.identifier`,
// `[uti conformsToType:UTTypePackage]`). The framework is absent on 10.9, so the data symbols are
// supplied here as retained instances of the class above, built from the classic CoreServices
// identifiers. Initialized in a C constructor: the ObjC runtime realizes this image's classes before
// its initializers run, and alloc/init avoids autorelease (no pool exists this early).
UTType *UTTypeItem;
UTType *UTTypeContent;
UTType *UTTypeCompositeContent;
UTType *UTTypeData;
UTType *UTTypeDirectory;
UTType *UTTypeFolder;
UTType *UTTypePackage;
UTType *UTTypeApplication;
UTType *UTTypeApplicationBundle;
UTType *UTTypeText;
UTType *UTTypePlainText;
UTType *UTTypeUTF8PlainText;
UTType *UTTypeUTF16PlainText;
UTType *UTTypeRTF;
UTType *UTTypeRTFD;
UTType *UTTypeFlatRTFD;
UTType *UTTypeHTML;
UTType *UTTypeXML;
UTType *UTTypeURL;
UTType *UTTypeFileURL;
UTType *UTTypeImage;
UTType *UTTypePNG;
UTType *UTTypeJPEG;
UTType *UTTypeTIFF;
UTType *UTTypeGIF;
UTType *UTTypeBMP;
UTType *UTTypeICO;
UTType *UTTypePDF;
UTType *UTTypeMovie;
UTType *UTTypeVideo;
UTType *UTTypeAudio;
UTType *UTTypeMP3;
UTType *UTTypeMPEG;
UTType *UTTypeMPEG4Movie;
UTType *UTTypeMPEG4Audio;
UTType *UTTypeQuickTimeMovie;
UTType *UTTypeVCard;
UTType *UTTypeWebArchive;
__attribute__((constructor)) static void wk_uttype_constants_init(void)
{
#define WK_UTTYPE_CONST(NAME, IDENTIFIER) NAME = [[UTType alloc] initWithIdentifier:(__bridge NSString *)(IDENTIFIER)]
    WK_UTTYPE_CONST(UTTypeItem, kUTTypeItem);
    WK_UTTYPE_CONST(UTTypeContent, kUTTypeContent);
    WK_UTTYPE_CONST(UTTypeCompositeContent, kUTTypeCompositeContent);
    WK_UTTYPE_CONST(UTTypeData, kUTTypeData);
    WK_UTTYPE_CONST(UTTypeDirectory, kUTTypeDirectory);
    WK_UTTYPE_CONST(UTTypeFolder, kUTTypeFolder);
    WK_UTTYPE_CONST(UTTypePackage, kUTTypePackage);
    WK_UTTYPE_CONST(UTTypeApplication, kUTTypeApplication);
    WK_UTTYPE_CONST(UTTypeApplicationBundle, kUTTypeApplicationBundle);
    WK_UTTYPE_CONST(UTTypeText, kUTTypeText);
    WK_UTTYPE_CONST(UTTypePlainText, kUTTypePlainText);
    WK_UTTYPE_CONST(UTTypeUTF8PlainText, kUTTypeUTF8PlainText);
    WK_UTTYPE_CONST(UTTypeUTF16PlainText, kUTTypeUTF16PlainText);
    WK_UTTYPE_CONST(UTTypeRTF, kUTTypeRTF);
    WK_UTTYPE_CONST(UTTypeRTFD, kUTTypeRTFD);
    WK_UTTYPE_CONST(UTTypeFlatRTFD, kUTTypeFlatRTFD);
    WK_UTTYPE_CONST(UTTypeHTML, kUTTypeHTML);
    WK_UTTYPE_CONST(UTTypeXML, kUTTypeXML);
    WK_UTTYPE_CONST(UTTypeURL, kUTTypeURL);
    WK_UTTYPE_CONST(UTTypeFileURL, kUTTypeFileURL);
    WK_UTTYPE_CONST(UTTypeImage, kUTTypeImage);
    WK_UTTYPE_CONST(UTTypePNG, kUTTypePNG);
    WK_UTTYPE_CONST(UTTypeJPEG, kUTTypeJPEG);
    WK_UTTYPE_CONST(UTTypeTIFF, kUTTypeTIFF);
    WK_UTTYPE_CONST(UTTypeGIF, kUTTypeGIF);
    WK_UTTYPE_CONST(UTTypeBMP, kUTTypeBMP);
    WK_UTTYPE_CONST(UTTypeICO, kUTTypeICO);
    WK_UTTYPE_CONST(UTTypePDF, kUTTypePDF);
    WK_UTTYPE_CONST(UTTypeMovie, kUTTypeMovie);
    WK_UTTYPE_CONST(UTTypeVideo, kUTTypeVideo);
    WK_UTTYPE_CONST(UTTypeAudio, kUTTypeAudio);
    WK_UTTYPE_CONST(UTTypeMP3, kUTTypeMP3);
    WK_UTTYPE_CONST(UTTypeMPEG, kUTTypeMPEG);
    WK_UTTYPE_CONST(UTTypeMPEG4Movie, kUTTypeMPEG4);
    WK_UTTYPE_CONST(UTTypeMPEG4Audio, kUTTypeMPEG4Audio);
    WK_UTTYPE_CONST(UTTypeQuickTimeMovie, kUTTypeQuickTimeMovie);
    WK_UTTYPE_CONST(UTTypeVCard, kUTTypeVCard);
    UTTypeWebArchive = [[UTType alloc] initWithIdentifier:@"com.apple.webarchive"];
#undef WK_UTTYPE_CONST
}
WK_PRIV_CLASS(NSFilePromiseReceiver) @interface NSFilePromiseReceiver : NSObject @end
@implementation NSFilePromiseReceiver @end
WK_PRIV_ALIAS(NSFilePromiseReceiver);
// NSFilePromiseProvider (10.12+): the modern promised-file drag source. WebViewImpl's attachment-element
// drag-out builds one and hands it to -[NSDraggingItem initWithPasteboardWriter:]; on 10.9 the class
// binds as a nil weak import. The initializer tolerates the nil writer and returns a real item, and the
// items array builds fine — the throw comes inside -[NSView beginDraggingSessionWithItems:event:source:],
// where AppKit inserts each item's pasteboard WRITER into an internal mutable array and the nil one
// raises (NSInvalidArgumentException, -[__NSArrayM insertObject:atIndex:]: object cannot be nil —
// isolated step-by-step on this host), killing the UI process mid-drag. This stub holds the
// fileType/delegate/userInfo it is given and satisfies
// NSPasteboardWriting by writing nothing: 10.9 drop destinations only understand the classic
// PasteboardRef promise protocol, which AppKit's modern promise machinery never engages here, so the
// drag proceeds with no promise payload instead of throwing. (A classic NSFilesPromisePboardType
// bridge is possible if a WKWebView-backed view ever hosts attachment drags on this system — the
// Safari-facing WKView has its own classic promised-file path.)
WK_PRIV_CLASS(NSFilePromiseProvider) @interface NSFilePromiseProvider : NSObject <NSPasteboardWriting>
{
    NSString *_wkFileType;
    id _wkDelegate;
    id _wkUserInfo;
}
- (instancetype)initWithFileType:(NSString *)fileType delegate:(id)delegate;
- (NSString *)fileType;
- (id)delegate;
- (id)userInfo;
- (void)setUserInfo:(id)userInfo;
@end
@implementation NSFilePromiseProvider
- (instancetype)initWithFileType:(NSString *)fileType delegate:(id)delegate
{
    if (!(self = [super init]))
        return nil;
    _wkFileType = [fileType copy];
    _wkDelegate = delegate;
    return self;
}
- (void)dealloc
{
    [_wkFileType release];
    [_wkUserInfo release];
    [super dealloc];
}
- (NSString *)fileType { return _wkFileType; }
- (id)delegate { return _wkDelegate; }
- (id)userInfo { return _wkUserInfo; }
- (void)setUserInfo:(id)userInfo
{
    if (_wkUserInfo == userInfo)
        return;
    [_wkUserInfo release];
    _wkUserInfo = [userInfo retain];
}
- (NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard
{
    (void)pasteboard;
    return [NSArray array];
}
- (id)pasteboardPropertyListForType:(NSString *)type
{
    (void)type;
    return nil;
}
@end
WK_PRIV_ALIAS(NSFilePromiseProvider);
WK_PRIV_CLASS(LSAppLink) @interface LSAppLink : NSObject @end
@implementation LSAppLink @end
WK_PRIV_ALIAS(LSAppLink);
WK_PRIV_CLASS(_LSOpenConfiguration) @interface _LSOpenConfiguration : NSObject @end
@implementation _LSOpenConfiguration @end
WK_PRIV_ALIAS(_LSOpenConfiguration);
WK_PRIV_CLASS(_NSScrollingMomentumCalculator) @interface _NSScrollingMomentumCalculator : NSObject @end
@implementation _NSScrollingMomentumCalculator @end
WK_PRIV_ALIAS(_NSScrollingMomentumCalculator);
WK_PRIV_CLASS(_NSScrollingPredominantAxisFilter) @interface _NSScrollingPredominantAxisFilter : NSObject @end
@implementation _NSScrollingPredominantAxisFilter @end
WK_PRIV_ALIAS(_NSScrollingPredominantAxisFilter);
// NSHapticFeedbackManager is 10.11+; on 10.9 the class is absent, so upstream's
// [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:performanceTime:] would fail to
// bind _OBJC_CLASS_$_NSHapticFeedbackManager. Provide a no-op stub: defaultPerformer returns a shared
// instance whose performFeedbackPattern:performanceTime: does nothing (10.9 has no haptic hardware).
WK_PRIV_CLASS(NSHapticFeedbackManager) @interface NSHapticFeedbackManager : NSObject
+ (id)defaultPerformer;
- (void)performFeedbackPattern:(NSInteger)pattern performanceTime:(NSInteger)performanceTime;
@end
@implementation NSHapticFeedbackManager
+ (id)defaultPerformer
{
    static NSHapticFeedbackManager *performer;
    if (!performer)
        performer = [[self alloc] init];
    return performer;
}
- (void)performFeedbackPattern:(NSInteger)pattern performanceTime:(NSInteger)performanceTime { }
@end
WK_PRIV_ALIAS(NSHapticFeedbackManager);
// NOTE: WebFullScreenController is intentionally NOT stubbed here — it is a REAL class implemented by
// WebKitLegacy (Source/WebKitLegacy/mac/WebView/WebFullScreenController.mm). No other framework references
// it, so a polyfill stub would only duplicate the real class. Leave it to WebKitLegacy.
WK_PRIV_CLASS(LSBundleProxy) @interface LSBundleProxy : NSObject @end
@implementation LSBundleProxy @end
WK_PRIV_ALIAS(LSBundleProxy);
// The store these two take is a persistent one. 10.9 has neither an HSTS store nor an alternative-service
// store to persist into, so the initializer accepts the URL and keeps nothing: the object is a working
// store that is simply always empty, which is what "no HSTS state" and "no alternative services known"
// mean. Nothing is dropped silently -- there is no state to drop.
WK_PRIV_CLASS(_NSHSTSStorage) @interface _NSHSTSStorage : NSObject
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
@end
@implementation _NSHSTSStorage
- (instancetype)initPersistentStoreWithURL:(NSURL *)url { (void)url; return [self init]; }
@end
WK_PRIV_ALIAS(_NSHSTSStorage);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesFilter) @interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesFilter);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesStorage) @interface _NSHTTPAlternativeServicesStorage : NSObject
- (instancetype)initPersistentStoreWithURL:(NSURL *)url;
- (void)setCanSuspendLocked:(BOOL)canSuspendLocked;
@end
@implementation _NSHTTPAlternativeServicesStorage
- (instancetype)initPersistentStoreWithURL:(NSURL *)url { (void)url; return [self init]; }
- (void)setCanSuspendLocked:(BOOL)canSuspendLocked { (void)canSuspendLocked; }
@end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesStorage);
WK_PRIV_CLASS(NSVisualEffectView) @interface NSVisualEffectView : NSView @end
@implementation NSVisualEffectView @end
WK_PRIV_ALIAS(NSVisualEffectView);
// NSDateComponentsFormatter formats a quantity of time in words -- "2 minutes, 5 seconds". WebCore
// builds the media controls' accessibility description of a track's duration with it
// (RenderThemeCocoa::mediaControlsFormattedStringForDuration): units style Full, allowed units
// hour/minute/second, standalone formatting context, at most two units. VoiceOver reads the result
// out, so the spelled-out localized wording IS the string's purpose.
//
// The unit names, their plural forms and the separator between them are CLDR data, and 10.9's ICU
// (51.1, /usr/lib/libicucore.A.dylib) carries all of it. Each locale bundle's "units" and
// "unitsShort" tables hold "{0} hour" / "{0} hours" keyed by that locale's own plural categories --
// ru has one/few/many/other, ja has only other -- and ICU's MessageFormat picks the category for a
// value under the locale's plural rules and formats the number in the locale's digits. So the words
// in the output are the system's own, in the user's language; none of them are written here.
//
// MAVERICKS divergence, the separator: CLDR's "unit" list style, which is what joins the units on
// 10.10+, postdates ICU 51 -- the only list style in this data is "standard", whose two-item pattern
// is "{0} and {1}". The standard style's non-final ("middle") pattern is what the unit style uses in
// nearly every locale ("{0}, {1}" for en/es/he, "{0}، {1}" for ar, "{0}、{1}" for ja), so the units
// are joined with that and English reads "1 hour, 2 minutes".
//
// maximumUnitCount truncates rather than rounds, which is what 10.10+ documents: "1h 10m 30s,
// maximumUnitCount set to 2: '1h 10m'". A zero-valued unit is dropped, the zero-formatting default
// for a style other than positional; an interval that leaves nothing to show formats as zero of the
// smallest allowed unit ("0 seconds"). formattingContext is stored and does not reach the output,
// which is what the property does on 10.10+ too -- Apple's header marks it "Not yet supported".
typedef NS_ENUM(NSInteger, NSDateComponentsFormatterUnitsStyle) {
    NSDateComponentsFormatterUnitsStylePositional = 0,   // "1:10"
    NSDateComponentsFormatterUnitsStyleAbbreviated = 1,  // "1h 10m"
    NSDateComponentsFormatterUnitsStyleShort = 2,        // "1 hr, 10 min"
    NSDateComponentsFormatterUnitsStyleFull = 3,         // "1 hour, 10 minutes"
    NSDateComponentsFormatterUnitsStyleSpellOut = 4,     // "One hour, ten minutes"
    NSDateComponentsFormatterUnitsStyleBrief = 5,        // "1hr 10min"
};
typedef NSInteger NSFormattingContext;

// ICU's C resource-bundle and message-format entry points. libicucore is built with symbol renaming
// disabled, so these bare names are its real exports, and 10.9 ships no <unicode/*.h> for them --
// hence the declarations here. build-polyfill.sh links this dylib against libicucore.
typedef int32_t WKICUErrorCode;    // UErrorCode; > 0 is a failure, < 0 a warning
typedef uint16_t WKICUChar;        // UChar
typedef struct UResourceBundle UResourceBundle;
extern UResourceBundle *ures_open(const char *packageName, const char *locale, WKICUErrorCode *status);
extern UResourceBundle *ures_getByKeyWithFallback(const UResourceBundle *bundle, const char *keyPath, UResourceBundle *fillIn, WKICUErrorCode *status);
extern UResourceBundle *ures_getByIndex(const UResourceBundle *bundle, int32_t index, UResourceBundle *fillIn, WKICUErrorCode *status);
extern const WKICUChar *ures_getString(const UResourceBundle *bundle, int32_t *length, WKICUErrorCode *status);
extern int32_t ures_getSize(const UResourceBundle *bundle);
extern const char *ures_getKey(const UResourceBundle *bundle);
extern void ures_close(UResourceBundle *bundle);
extern int32_t u_formatMessage(const char *locale, const WKICUChar *pattern, int32_t patternLength, WKICUChar *result, int32_t resultLength, WKICUErrorCode *status, ...);

// The units a plain time interval decomposes into, largest first, each with the key CLDR stores it
// under. These are the fixed-length ones; a month and a year are as long as the calendar says, so a
// caller that allows them gets the units below that instead.
static const struct { NSUInteger calendarUnit; const char *dataKey; } wkDurationUnits[] = {
    { NSCalendarUnitDay,    "day"    },
    { NSCalendarUnitHour,   "hour"   },
    { NSCalendarUnitMinute, "minute" },
    { NSCalendarUnitSecond, "second" },
};
#define WK_DURATION_UNIT_COUNT ((NSInteger)(sizeof(wkDurationUnits) / sizeof(wkDurationUnits[0])))

static NSInteger wkDurationComponentValue(NSDateComponents *components, NSUInteger calendarUnit)
{
    switch (calendarUnit) {
    case NSCalendarUnitDay:    return components.day;
    case NSCalendarUnitHour:   return components.hour;
    case NSCalendarUnitMinute: return components.minute;
    default:                   return components.second;
    }
}

// A CLDR unit pattern ("{0} hours") as a MessageFormat plural submessage: the placeholder becomes the
// plural argument's own number placeholder, and each character MessageFormat reads as syntax is
// quoted so a locale's literal text arrives intact.
static void wkAppendPluralSubmessage(NSMutableString *out, NSString *pattern)
{
    NSUInteger length = pattern.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [pattern characterAtIndex:i];
        if (c == '{' && i + 2 < length && [pattern characterAtIndex:i + 1] == '0' && [pattern characterAtIndex:i + 2] == '}') {
            [out appendString:@"#"];
            i += 2;
        } else if (c == '\'')
            [out appendString:@"''"];
        else if (c == '{' || c == '}' || c == '#')
            [out appendFormat:@"'%C'", c];
        else
            [out appendFormat:@"%C", c];
    }
}

// "{0} hour" / "{0} hours" / ... for one unit, as the locale's plural rules apply them to value.
static NSString *wkSpelledOutUnit(const char *table, const char *unitKey, NSInteger value, const char *localeID)
{
    WKICUErrorCode status = 0;
    UResourceBundle *localeBundle = ures_open(NULL, localeID, &status);
    UResourceBundle *unitTable = NULL;
    NSString *result = nil;
    if (status <= 0 && localeBundle) {
        char keyPath[64];
        snprintf(keyPath, sizeof(keyPath), "%s/%s", table, unitKey);
        unitTable = ures_getByKeyWithFallback(localeBundle, keyPath, NULL, &status);
    }
    if (status <= 0 && unitTable) {
        NSMutableString *pattern = [NSMutableString stringWithString:@"{0,plural,"];
        int32_t categories = ures_getSize(unitTable);
        for (int32_t i = 0; i < categories; i++) {
            WKICUErrorCode itemStatus = 0;
            UResourceBundle *item = ures_getByIndex(unitTable, i, NULL, &itemStatus);
            int32_t textLength = 0;
            const WKICUChar *text = (item && itemStatus <= 0) ? ures_getString(item, &textLength, &itemStatus) : NULL;
            const char *category = item ? ures_getKey(item) : NULL;
            if (text && category && itemStatus <= 0) {
                [pattern appendFormat:@"%s{", category];
                wkAppendPluralSubmessage(pattern, [NSString stringWithCharacters:(const unichar *)text length:(NSUInteger)textLength]);
                [pattern appendString:@"}"];
            }
            ures_close(item);
        }
        [pattern appendString:@"}"];

        unichar patternBuffer[512];
        WKICUChar formatted[512];
        NSUInteger patternLength = pattern.length;
        if (patternLength && patternLength <= sizeof(patternBuffer) / sizeof(patternBuffer[0])) {
            [pattern getCharacters:patternBuffer range:NSMakeRange(0, patternLength)];
            WKICUErrorCode formatStatus = 0;
            int32_t formattedLength = u_formatMessage(localeID, (const WKICUChar *)patternBuffer, (int32_t)patternLength,
                formatted, (int32_t)(sizeof(formatted) / sizeof(formatted[0])), &formatStatus, (double)value);
            if (formatStatus <= 0 && formattedLength > 0 && formattedLength <= (int32_t)(sizeof(formatted) / sizeof(formatted[0])))
                result = [NSString stringWithCharacters:(const unichar *)formatted length:(NSUInteger)formattedLength];
        }
    }
    ures_close(unitTable);
    ures_close(localeBundle);
    return result;
}

// The locale's pattern for a list item that is not the last one -- "{0}, {1}" in English.
static NSString *wkDurationListPattern(const char *localeID)
{
    WKICUErrorCode status = 0;
    UResourceBundle *localeBundle = ures_open(NULL, localeID, &status);
    UResourceBundle *item = (status <= 0 && localeBundle) ? ures_getByKeyWithFallback(localeBundle, "listPattern/standard/middle", NULL, &status) : NULL;
    NSString *pattern = nil;
    if (status <= 0 && item) {
        int32_t textLength = 0;
        const WKICUChar *text = ures_getString(item, &textLength, &status);
        if (text && status <= 0)
            pattern = [NSString stringWithCharacters:(const unichar *)text length:(NSUInteger)textLength];
    }
    ures_close(item);
    ures_close(localeBundle);
    return pattern ?: @"{0}, {1}";
}

static NSString *wkApplyListPattern(NSString *pattern, NSString *first, NSString *second)
{
    NSMutableString *result = [NSMutableString string];
    NSUInteger length = pattern.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [pattern characterAtIndex:i];
        unichar placeholder = (c == '{' && i + 2 < length && [pattern characterAtIndex:i + 2] == '}') ? [pattern characterAtIndex:i + 1] : 0;
        if (placeholder == '0' || placeholder == '1') {
            [result appendString:placeholder == '0' ? first : second];
            i += 2;
        } else
            [result appendFormat:@"%C", c];
    }
    return result;
}

// The digit form, "1:02:05": the largest shown unit as it stands, each smaller one padded to two
// digits. It is what the positional style asks for, and what stands in should a locale's unit data
// be unreachable.
static NSString *wkPositionalDuration(const NSInteger *values, const NSInteger *shown, NSInteger shownCount)
{
    NSMutableString *result = [NSMutableString string];
    for (NSInteger i = 0; i < shownCount; i++)
        [result appendFormat:(i ? @":%02ld" : @"%ld"), (long)values[shown[i]]];
    return result;
}

WK_PRIV_CLASS(NSDateComponentsFormatter) @interface NSDateComponentsFormatter : NSFormatter
@property NSDateComponentsFormatterUnitsStyle unitsStyle;
@property NSUInteger allowedUnits;
@property NSInteger maximumUnitCount;
@property NSFormattingContext formattingContext;
- (NSString *)stringFromTimeInterval:(NSTimeInterval)interval;
@end
@implementation NSDateComponentsFormatter
- (NSString *)stringFromTimeInterval:(NSTimeInterval)interval
{
    if (!isfinite(interval))
        return nil;

    NSUInteger allowed = _allowedUnits ?: (NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond);
    NSInteger units[WK_DURATION_UNIT_COUNT];
    NSInteger unitCount = 0;
    NSUInteger mask = 0;
    for (NSInteger i = 0; i < WK_DURATION_UNIT_COUNT; i++) {
        if (allowed & wkDurationUnits[i].calendarUnit) {
            units[unitCount++] = i;
            mask |= wkDurationUnits[i].calendarUnit;
        }
    }
    if (!unitCount) {
        units[unitCount++] = WK_DURATION_UNIT_COUNT - 1;
        mask = NSCalendarUnitSecond;
    }

    // The calendar decomposes the interval: the largest requested unit absorbs everything above it,
    // and each unit truncates. A UTC Gregorian calendar keeps every unit in the table the length its
    // table entry says, whatever the current time zone does about daylight saving.
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *start = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    NSDate *end = [NSDate dateWithTimeIntervalSinceReferenceDate:fabs(interval)];
    NSDateComponents *components = [calendar components:mask fromDate:start toDate:end options:0];

    NSInteger values[WK_DURATION_UNIT_COUNT];
    for (NSInteger i = 0; i < unitCount; i++)
        values[i] = wkDurationComponentValue(components, wkDurationUnits[units[i]].calendarUnit);

    BOOL positional = _unitsStyle == NSDateComponentsFormatterUnitsStylePositional;
    NSInteger shown[WK_DURATION_UNIT_COUNT];
    NSInteger shownCount = 0;
    NSInteger largest = 0;
    while (largest + 1 < unitCount && !values[largest])
        largest++;
    for (NSInteger i = largest; i < unitCount; i++) {
        if (positional || values[i])
            shown[shownCount++] = i;
    }
    if (!shownCount)
        shown[shownCount++] = unitCount - 1;
    if (_maximumUnitCount > 0 && shownCount > _maximumUnitCount)
        shownCount = _maximumUnitCount;

    if (positional)
        return wkPositionalDuration(values, shown, shownCount);

    // Full and SpellOut read the whole unit names, the shorter styles the abbreviated ones. ICU 51
    // has the two tables; the narrow forms Abbreviated and Brief draw on from 10.12 arrived later,
    // so those styles read the abbreviated names as Short does.
    const char *table = (_unitsStyle == NSDateComponentsFormatterUnitsStyleFull || _unitsStyle == NSDateComponentsFormatterUnitsStyleSpellOut) ? "units" : "unitsShort";
    const char *localeID = [[NSLocale currentLocale] localeIdentifier].UTF8String;
    NSString *listPattern = wkDurationListPattern(localeID);
    NSString *result = nil;
    for (NSInteger i = 0; i < shownCount; i++) {
        NSInteger index = shown[i];
        NSString *piece = wkSpelledOutUnit(table, wkDurationUnits[units[index]].dataKey, values[index], localeID);
        if (!piece)
            return wkPositionalDuration(values, shown, shownCount);
        result = result ? wkApplyListPattern(listPattern, result, piece) : piece;
    }
    return result;
}
@end
WK_PRIV_ALIAS(NSDateComponentsFormatter);

// ==============================================================================================
// AVFoundation
//
// Unlike the stubs above, every class in this section is reached by NAME: PAL soft-links each one,
// and SOFT_LINK_CLASS_FOR_SOURCE resolves a class with objc_getClass(), which the private runtime
// name deliberately hides from. So each one is registered with WK_POLYFILL_CLASS (mechanism/
// wk_polyfill.h), and the objc_getClass override in wk_polyfill_runtime.c answers WebKit's lookup
// out of that registry. The private name still keeps them invisible to the host app.
//
// These are also the only stubs here that need 10.9 classes of their own (AVCaptureDevice,
// AVCaptureStillImageOutput) to do the work. Those are reached through NSClassFromString and a
// protocol-typed cast rather than a compile-time classref, because a classref would put
// AVFoundation on this dylib's load commands -- and this dylib is linked into every WebKit
// framework, so AVFoundation would then be loaded into JavaScriptCore, the NetworkProcess and every
// host app that embeds WebKit, none of which have any reason to load it.

// AVMediaTypeVideo and AVCaptureDevicePositionUnspecified, spelled out for the same reason: reading
// them from AVFoundation would mean linking it. Both values are API contract, not implementation.
#define WK_AV_MEDIA_TYPE_VIDEO @"vide"
enum { WKAVCaptureDevicePositionUnspecified = 0 };

@protocol WKPolyfillAVCaptureDevice <NSObject>
+ (NSArray *)devicesWithMediaType:(NSString *)mediaType;
+ (NSArray *)devices;
- (NSInteger)position;
@end

// AVCaptureDeviceDiscoverySession (10.10+): enumerates capture devices, narrowed by device type,
// media type and position. 10.9 has no device *types* -- the whole AVCaptureDeviceType vocabulary
// arrived with 10.15 -- so the type list cannot narrow anything here and the two filters 10.9 can
// apply are the media type and the position, which is what +devicesWithMediaType: and -position
// give. That is the same set of devices the real class would return on a machine whose cameras all
// predate the type vocabulary, so the answer is right for any caller and not just WebKit's.
WK_PRIV_CLASS(AVCaptureDeviceDiscoverySession) @interface AVCaptureDeviceDiscoverySession : NSObject
+ (instancetype)discoverySessionWithDeviceTypes:(NSArray *)deviceTypes mediaType:(NSString *)mediaType position:(NSInteger)position;
@property (nonatomic, readonly) NSArray *devices;
@end

@implementation AVCaptureDeviceDiscoverySession {
    NSString *_mediaType;
    NSInteger _position;
}

+ (instancetype)discoverySessionWithDeviceTypes:(NSArray *)deviceTypes mediaType:(NSString *)mediaType position:(NSInteger)position
{
    (void)deviceTypes;
    AVCaptureDeviceDiscoverySession *session = [[[self alloc] init] autorelease];
    if (!session)
        return nil;
    session->_mediaType = [mediaType copy];
    session->_position = position;
    return session;
}

- (void)dealloc
{
    [_mediaType release];
    [super dealloc];
}

- (NSArray *)devices
{
    Class<WKPolyfillAVCaptureDevice> captureDevice = (Class<WKPolyfillAVCaptureDevice>)NSClassFromString(@"AVCaptureDevice");
    if (!captureDevice)
        return @[];

    NSArray *devices = _mediaType ? [captureDevice devicesWithMediaType:_mediaType] : [captureDevice devices];
    if (!devices)
        return @[];
    if (_position == WKAVCaptureDevicePositionUnspecified)
        return devices;

    NSMutableArray *matching = [NSMutableArray array];
    for (id<WKPolyfillAVCaptureDevice> device in devices) {
        if ([device position] == _position)
            [matching addObject:device];
    }
    return matching;
}

@end
WK_PRIV_ALIAS(AVCaptureDeviceDiscoverySession);
WK_POLYFILL_CLASS("AVFoundation", AVCaptureDeviceDiscoverySession);

// AVAudioRoutingArbiter (10.15+): asks the system to arbitrate which app owns the audio route
// before a capture/playback session starts, and reports back whether the default device changed.
// 10.9 has no routing-arbitration service at all -- an app simply takes the device -- so the
// faithful implementation of "begin arbitration" on this OS is to grant it: no error, and no
// default-device change, since nothing was rearranged. The completion handler is delivered
// asynchronously because that is the shape of the real API, not because anything here is slow;
// a caller that assumed synchronous delivery would break on a modern OS too.
WK_PRIV_CLASS(AVAudioRoutingArbiter) @interface AVAudioRoutingArbiter : NSObject
+ (instancetype)sharedRoutingArbiter;
- (void)beginArbitrationWithCategory:(NSInteger)category completionHandler:(void (^)(BOOL defaultDeviceChanged, NSError *error))handler;
- (void)leaveArbitration;
@end

@implementation AVAudioRoutingArbiter

+ (instancetype)sharedRoutingArbiter
{
    static AVAudioRoutingArbiter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[AVAudioRoutingArbiter alloc] init];
    });
    return shared;
}

- (void)beginArbitrationWithCategory:(NSInteger)category completionHandler:(void (^)(BOOL, NSError *))handler
{
    (void)category;
    if (!handler)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(NO, nil);
    });
}

- (void)leaveArbitration
{
}

@end
WK_PRIV_ALIAS(AVAudioRoutingArbiter);
WK_POLYFILL_CLASS("AVFoundation", AVAudioRoutingArbiter);

// AVCapturePhotoSettings (10.13+): the per-shot settings object handed to
// -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]. It is a plain value object -- the
// capture work is the output's -- so this is the whole class as of 10.13, backed by nothing.
//
// -maxPhotoDimensions is deliberately NOT implemented: it is a macOS 13 addition, and its
// counterpart -[AVCaptureDeviceFormat supportedMaxPhotoDimensions] (macOS 14) has no 10.9 equivalent
// to read the supported sizes from. Callers gate it on respondsToSelector: precisely so an older
// OS can decline, so declining is the correct answer rather than a shortfall; a stub that claimed it
// would send the caller on to ask the device format a question this OS cannot answer.
WK_PRIV_CLASS(AVCapturePhotoSettings) @interface AVCapturePhotoSettings : NSObject
+ (instancetype)photoSettings;
+ (instancetype)photoSettingsWithFormat:(NSDictionary *)format;
@property (nonatomic, readonly) NSDictionary *format;
@property (nonatomic) NSInteger flashMode;
@property (nonatomic, getter=isAutoRedEyeReductionEnabled) BOOL autoRedEyeReductionEnabled;
@end

@implementation AVCapturePhotoSettings {
    NSDictionary *_format;
    NSInteger _flashMode;
    BOOL _autoRedEyeReductionEnabled;
}

@synthesize flashMode = _flashMode;
@synthesize autoRedEyeReductionEnabled = _autoRedEyeReductionEnabled;

+ (instancetype)photoSettings
{
    return [self photoSettingsWithFormat:nil];
}

+ (instancetype)photoSettingsWithFormat:(NSDictionary *)format
{
    AVCapturePhotoSettings *settings = [[[self alloc] init] autorelease];
    if (settings)
        settings->_format = [format copy];
    return settings;
}

- (void)dealloc
{
    [_format release];
    [super dealloc];
}

- (NSDictionary *)format
{
    return _format;
}

@end
WK_PRIV_ALIAS(AVCapturePhotoSettings);
WK_POLYFILL_CLASS("AVFoundation", AVCapturePhotoSettings);

// The object handed to -captureOutput:didFinishProcessingPhoto:error:. AVCapturePhoto is absent on
// 10.9 as well, but nothing ever looks it up by name -- a caller only receives one and reads the
// encoded photo off it -- so it needs no public name and no registry entry, and stays private here.
@interface WKPolyfillCapturedPhoto : NSObject
@property (nonatomic, copy) NSData *fileDataRepresentation;
@end

@implementation WKPolyfillCapturedPhoto {
    NSData *_fileDataRepresentation;
}
@synthesize fileDataRepresentation = _fileDataRepresentation;
- (void)dealloc
{
    [_fileDataRepresentation release];
    [super dealloc];
}
@end

@protocol WKPolyfillAVCaptureStillImageOutput <NSObject>
- (id)connectionWithMediaType:(NSString *)mediaType;
- (void)captureStillImageAsynchronouslyFromConnection:(id)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler;
@end

@protocol WKPolyfillAVCaptureStillImageOutputClass <NSObject>
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)imageDataSampleBuffer;
@end

@protocol WKPolyfillAVCapturePhotoCaptureDelegate <NSObject>
- (void)captureOutput:(id)output didFinishProcessingPhoto:(id)photo error:(NSError *)error;
@end

// -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:], implemented on 10.9's
// AVCaptureStillImageOutput -- the same still-capture facility under its pre-10.15 name, which is
// why this class can subclass it and inherit -connectionWithMediaType:, session membership, and
// everything else AVCaptureOutput provides. The settings object carries the requested container
// format; JPEG is the only one 10.9's still-image path produces, and
// +jpegStillImageNSDataRepresentation: is how it hands the encoded bytes back, so the photo's
// -fileDataRepresentation is that JPEG.
static void wkCapturePhotoWithSettings(id self, SEL cmd, id settings, id delegate)
{
    (void)cmd;

    id<WKPolyfillAVCaptureStillImageOutput> output = (id<WKPolyfillAVCaptureStillImageOutput>)self;
    id<WKPolyfillAVCapturePhotoCaptureDelegate> photoDelegate = (id<WKPolyfillAVCapturePhotoCaptureDelegate>)delegate;
    Class<WKPolyfillAVCaptureStillImageOutputClass> outputClass = (Class<WKPolyfillAVCaptureStillImageOutputClass>)[self class];

    // AVVideoCodecKey, and AVVideoCodecTypeJPEG's value. Spelled out rather than read from
    // AVFoundation, for the same reason as AVMediaTypeVideo above.
    NSString *requestedCodec = [[(AVCapturePhotoSettings *)settings format] objectForKey:@"AVVideoCodecKey"];
    id connection = (!requestedCodec || [requestedCodec isEqualToString:@"jpeg"])
        ? [output connectionWithMediaType:WK_AV_MEDIA_TYPE_VIDEO] : nil;

    if (!connection) {
        // Either there is no video connection, or the caller asked for a container 10.9's
        // still-image path cannot produce (it encodes JPEG and nothing else). The real API reports a
        // capture it cannot start through the delegate's error argument rather than by doing nothing
        // -- and rather than by quietly substituting a different format -- so the caller's pending
        // request always completes, and completes truthfully.
        [photoDelegate captureOutput:self didFinishProcessingPhoto:nil
                               error:[NSError errorWithDomain:NSOSStatusErrorDomain code:-11800 userInfo:nil]];
        return;
    }

    [output captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        NSData *data = (!error && imageDataSampleBuffer) ? [outputClass jpegStillImageNSDataRepresentation:imageDataSampleBuffer] : nil;
        if (!data && !error)
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-11800 userInfo:nil];

        WKPolyfillCapturedPhoto *photo = nil;
        if (data) {
            photo = [[[WKPolyfillCapturedPhoto alloc] init] autorelease];
            photo.fileDataRepresentation = data;
        }
        [photoDelegate captureOutput:self didFinishProcessingPhoto:photo error:error];
    }];
}

WK_POLYFILL_CLASS_RESOLVED("AVFoundation", AVCapturePhotoOutput, wkResolveAVCapturePhotoOutput);
static void *wkResolveAVCapturePhotoOutput(void)
{
    static Class photoOutput;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class stillImageOutput = NSClassFromString(@"AVCaptureStillImageOutput");
        if (!stillImageOutput)
            return;     // AVFoundation is not in this process, so nothing can be asking for a capture
        Class cls = objc_allocateClassPair(stillImageOutput, "WKMavPolyfillPriv_AVCapturePhotoOutput", 0);
        if (!cls)
            return;
        class_addMethod(cls, sel_registerName("capturePhotoWithSettings:delegate:"),
                        (IMP)wkCapturePhotoWithSettings, "v@:@@");
        objc_registerClassPair(cls);
        photoOutput = cls;
    });
    return photoOutput;
}

// AVSpeechSynthesizer / AVSpeechUtterance / AVSpeechSynthesisVoice (10.14+), backed by
// NSSpeechSynthesizer, which 10.9 has had since 10.3. This is the Web Speech API's synthesis engine:
// PlatformSpeechSynthesizerCocoa drives these three classes and PAL soft-links all three by name.
//
// The mapping between the two APIs is total, so the stub is a translation rather than an
// approximation: an utterance's rate, volume, pitch and voice all have NSSpeechSynthesizer
// equivalents, and its delegate callbacks (start / finish / pause / continue / cancel / word range)
// are the ones NSSpeechSynthesizerDelegate reports. AVSpeechSynthesizer speaks a queue of utterances
// where NSSpeechSynthesizer speaks one string, so the queue is kept here and drained in
// -startNext.

// The AVSpeechBoundary values the pause/stop calls take.
typedef NS_ENUM(NSInteger, WKPolyfillAVSpeechBoundary) {
    WKPolyfillAVSpeechBoundaryImmediate = 0,
    WKPolyfillAVSpeechBoundaryWord = 1,
};

@class AVSpeechSynthesisVoice;
@class AVSpeechUtterance;
@class AVSpeechSynthesizer;

// The AVSpeechSynthesizerDelegate callbacks sent to the caller's delegate. Declared informally
// because the delegate is the caller's object, conforming to the SDK's protocol, not ours.
@interface NSObject (WKPolyfillAVSpeechSynthesizerDelegate)
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didStartSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didPauseSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didContinueSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance;
@end

WK_PRIV_CLASS(AVSpeechSynthesisVoice) @interface AVSpeechSynthesisVoice : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, readonly) BOOL isSystemVoice;
+ (NSArray *)speechVoices;
+ (NSArray *)speechVoicesIncludingSuperCompact;
+ (NSString *)currentLanguageCode;
+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language;
+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier;
// The backing NSSpeechSynthesizer voice name. Not part of AVSpeechSynthesisVoice; the synthesizer
// stub below reads it to select the voice.
@property (nonatomic, copy) NSString *nsVoiceName;
@end

// NSVoiceLocaleIdentifier is e.g. "en_US"; AVSpeechSynthesisVoice.language is BCP 47, "en-US".
static NSString *wkNormalizedSpeechLanguage(NSString *locale)
{
    return [locale stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

@implementation AVSpeechSynthesisVoice {
    NSString *_identifier;
    NSString *_name;
    NSString *_language;
    NSString *_nsVoiceName;
}

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize language = _language;
@synthesize nsVoiceName = _nsVoiceName;

- (void)dealloc
{
    [_identifier release];
    [_name release];
    [_language release];
    [_nsVoiceName release];
    [super dealloc];
}

- (BOOL)isSystemVoice
{
    return YES;
}

+ (AVSpeechSynthesisVoice *)voiceForNSVoiceName:(NSString *)nsVoiceName
{
    if (!nsVoiceName)
        return nil;
    NSDictionary *attributes = [NSSpeechSynthesizer attributesForVoice:nsVoiceName];
    if (!attributes)
        return nil;
    AVSpeechSynthesisVoice *voice = [[[AVSpeechSynthesisVoice alloc] init] autorelease];
    voice.nsVoiceName = nsVoiceName;
    voice.identifier = nsVoiceName;
    voice.name = attributes[NSVoiceName] ?: nsVoiceName;
    NSString *locale = attributes[NSVoiceLocaleIdentifier];
    voice.language = locale ? wkNormalizedSpeechLanguage(locale) : @"en-US";
    return voice;
}

+ (NSArray *)speechVoices
{
    NSMutableArray *voices = [NSMutableArray array];
    for (NSString *nsVoiceName in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoiceName];
        if (voice)
            [voices addObject:voice];
    }
    return voices;
}

// The "super compact" tier is an iOS voice-asset distinction; 10.9 ships one tier, so the two lists
// are the same list.
+ (NSArray *)speechVoicesIncludingSuperCompact
{
    return [self speechVoices];
}

+ (NSString *)currentLanguageCode
{
    AVSpeechSynthesisVoice *defaultVoice = [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
    if (defaultVoice.language.length)
        return defaultVoice.language;
    NSString *language = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode];
    return language.length ? language : @"en-US";
}

+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language
{
    if (!language.length)
        return [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];

    NSString *target = [wkNormalizedSpeechLanguage(language) lowercaseString];
    NSString *targetPrefix = [[target componentsSeparatedByString:@"-"] firstObject];
    AVSpeechSynthesisVoice *prefixMatch = nil;
    for (NSString *nsVoiceName in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoiceName];
        NSString *voiceLanguage = [voice.language lowercaseString];
        if ([voiceLanguage isEqualToString:target])
            return voice;
        if (!prefixMatch && [[[voiceLanguage componentsSeparatedByString:@"-"] firstObject] isEqualToString:targetPrefix])
            prefixMatch = voice;
    }
    if (prefixMatch)
        return prefixMatch;
    return [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
}

+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier
{
    if (!identifier.length)
        return nil;
    return [self voiceForNSVoiceName:identifier];
}

@end
WK_PRIV_ALIAS(AVSpeechSynthesisVoice);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechSynthesisVoice);

WK_PRIV_CLASS(AVSpeechUtterance) @interface AVSpeechUtterance : NSObject
@property (nonatomic, copy) NSString *speechString;
@property (nonatomic) float rate;
@property (nonatomic) float volume;
@property (nonatomic) float pitchMultiplier;
@property (nonatomic, retain) AVSpeechSynthesisVoice *voice;
+ (instancetype)speechUtteranceWithString:(NSString *)string;
@end

@implementation AVSpeechUtterance {
    NSString *_speechString;
    float _rate;
    float _volume;
    float _pitchMultiplier;
    AVSpeechSynthesisVoice *_voice;
}

@synthesize speechString = _speechString;
@synthesize rate = _rate;
@synthesize volume = _volume;
@synthesize pitchMultiplier = _pitchMultiplier;
@synthesize voice = _voice;

+ (instancetype)speechUtteranceWithString:(NSString *)string
{
    AVSpeechUtterance *utterance = [[[self alloc] init] autorelease];
    if (!utterance)
        return nil;
    utterance.speechString = string;
    utterance.rate = 0.5;           // AVSpeechUtteranceDefaultSpeechRate
    utterance.volume = 1.0;
    utterance.pitchMultiplier = 1.0;
    return utterance;
}

- (void)dealloc
{
    [_speechString release];
    [_voice release];
    [super dealloc];
}

@end
WK_PRIV_ALIAS(AVSpeechUtterance);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechUtterance);

WK_PRIV_CLASS(AVSpeechSynthesizer) @interface AVSpeechSynthesizer : NSObject
@property (nonatomic, assign) id delegate;
- (void)speakUtterance:(AVSpeechUtterance *)utterance;
- (void)pauseSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary;
- (void)continueSpeaking;
- (void)stopSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary;
@end

// AVSpeechUtterance.rate is 0..1 with 0.5 the default; NSSpeechSynthesizer.rate is words per minute,
// where ~175 is the default. Map linearly onto 0..350 wpm so 0.5 lands on the NSSpeechSynthesizer
// default, and clamp to the range the engine stays intelligible over.
static float wkNSSpeechRateForAVRate(float avRate)
{
    float wordsPerMinute = avRate * 350.0f;
    if (wordsPerMinute < 80.0f)
        wordsPerMinute = 80.0f;
    if (wordsPerMinute > 400.0f)
        wordsPerMinute = 400.0f;
    return wordsPerMinute;
}

@implementation AVSpeechSynthesizer {
    NSSpeechSynthesizer *_nsSynthesizer;
    NSMutableArray *_queue;
    AVSpeechUtterance *_current;
    BOOL _stopping;
    id _delegate;
}

@synthesize delegate = _delegate;

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _nsSynthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
    _nsSynthesizer.delegate = (id)self;
    _queue = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    _nsSynthesizer.delegate = nil;
    [_nsSynthesizer release];
    [_queue release];
    [_current release];
    [super dealloc];
}

// AVSpeechUtterance.pitchMultiplier scales the voice's natural pitch (0.5 = half, 2.0 = double,
// 1.0 = unchanged). NSSpeechPitchBaseProperty is that pitch in hertz and is voice-specific, so the
// multiplier is applied to whatever the currently selected voice reports as its base -- which is why
// this runs after -setVoice:, when the property already holds the new voice's own base.
- (void)applyPitchMultiplier:(float)multiplier
{
    if (multiplier == 1.0)
        return;
    NSNumber *basePitch = [_nsSynthesizer objectForProperty:NSSpeechPitchBaseProperty error:NULL];
    if (!basePitch)
        return;
    [_nsSynthesizer setObject:@(basePitch.floatValue * multiplier) forProperty:NSSpeechPitchBaseProperty error:NULL];
}

- (void)startNext
{
    if (_current || !_queue.count)
        return;
    _current = [_queue.firstObject retain];

    if (_current.voice.nsVoiceName)
        [_nsSynthesizer setVoice:_current.voice.nsVoiceName];
    _nsSynthesizer.rate = wkNSSpeechRateForAVRate(_current.rate);
    _nsSynthesizer.volume = _current.volume;
    [self applyPitchMultiplier:_current.pitchMultiplier];

    _stopping = NO;
    if (![_nsSynthesizer startSpeakingString:_current.speechString ?: @""]) {
        // The engine declined the string. AVSpeechSynthesizer never leaves an utterance pending, so
        // report it cancelled and move on, which also drains the rest of the queue.
        AVSpeechUtterance *utterance = [_current autorelease];
        _current = nil;
        [_queue removeObject:utterance];
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];
        [self startNext];
        return;
    }

    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didStartSpeechUtterance:)])
        [_delegate speechSynthesizer:self didStartSpeechUtterance:_current];
}

- (void)speakUtterance:(AVSpeechUtterance *)utterance
{
    if (!utterance)
        return;
    [_queue addObject:utterance];
    [self startNext];
}

- (void)pauseSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary
{
    if (!_current)
        return;
    [_nsSynthesizer pauseSpeakingAtBoundary:(boundary == WKPolyfillAVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didPauseSpeechUtterance:)])
        [_delegate speechSynthesizer:self didPauseSpeechUtterance:_current];
}

- (void)continueSpeaking
{
    if (!_current)
        return;
    [_nsSynthesizer continueSpeaking];
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didContinueSpeechUtterance:)])
        [_delegate speechSynthesizer:self didContinueSpeechUtterance:_current];
}

- (void)stopSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary
{
    _stopping = YES;
    [_queue removeAllObjects];
    [_nsSynthesizer stopSpeakingAtBoundary:(boundary == WKPolyfillAVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    // A stop while speaking arrives as -didFinishSpeaking:NO, which delivers the cancel callback.
    // A stop while idle does not, so deliver it here.
    if (!_nsSynthesizer.isSpeaking && _current) {
        AVSpeechUtterance *utterance = [_current autorelease];
        _current = nil;
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];
    }
}

#pragma mark NSSpeechSynthesizerDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
    (void)sender;
    if (!_current)
        return;
    AVSpeechUtterance *utterance = [_current autorelease];
    _current = nil;
    [_queue removeObject:utterance];

    if (finishedSpeaking && !_stopping) {
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didFinishSpeechUtterance:)])
            [_delegate speechSynthesizer:self didFinishSpeechUtterance:utterance];
    } else if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
        [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];

    _stopping = NO;
    [self startNext];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakWord:(NSRange)characterRange ofString:(NSString *)string
{
    (void)sender;
    (void)string;
    if (!_current)
        return;
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:willSpeakRangeOfSpeechString:utterance:)])
        [_delegate speechSynthesizer:self willSpeakRangeOfSpeechString:characterRange utterance:_current];
}

@end
WK_PRIV_ALIAS(AVSpeechSynthesizer);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechSynthesizer);

// NSColorSampler (10.14+): the screen colour-picker the Web Inspector's colour swatch opens ("pick colour
// from screen"). Implemented for real, not stubbed: every primitive it needs is present on 10.9 —
// CGDisplayCreateImageForRect, CGMainDisplayID, +[NSEvent addGlobalMonitorForEventsMatchingMask:handler:]
// (10.6) and -[NSBitmapImageRep colorAtX:y:] — verified by sampling a live pixel under the cursor on this
// host. What 10.9 lacks is only the magnifier loupe's *presentation*, not the ability to sample.
//
// Behaviour matches the real sampler's contract: the pointer becomes a crosshair, a click commits the colour
// under the cursor, Escape or a right-click cancels, and the handler is invoked exactly once — with the
// sampled NSColor on commit, or nil on cancel. Callers already handle nil, because cancelling is an ordinary
// outcome of the real API.
WK_PRIV_CLASS(NSColorSampler) @interface NSColorSampler : NSObject
- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *selectedColor))selectionHandler;
@end

@implementation NSColorSampler {
    id _mouseMonitor;
    id _keyMonitor;
    id _localMonitor;
    NSCursor *_previousCursor;
    void (^_handler)(NSColor *);
}

// The pixel under the cursor, sampled straight off the display.
static NSColor *wkColorUnderCursor(void)
{
    CGEventRef event = CGEventCreate(NULL);
    if (!event)
        return nil;
    CGPoint location = CGEventGetLocation(event);
    CFRelease(event);

    CGImageRef image = CGDisplayCreateImageForRect(CGMainDisplayID(), CGRectMake(location.x, location.y, 1, 1));
    if (!image)
        return nil;
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
    CGImageRelease(image);
    return [bitmap colorAtX:0 y:0];
}

- (void)wkFinishWithColor:(NSColor *)color
{
    if (!_handler)
        return;   // already finished; the handler must run exactly once

    if (_mouseMonitor) { [NSEvent removeMonitor:_mouseMonitor]; _mouseMonitor = nil; }
    if (_keyMonitor) { [NSEvent removeMonitor:_keyMonitor]; _keyMonitor = nil; }
    if (_localMonitor) { [NSEvent removeMonitor:_localMonitor]; _localMonitor = nil; }
    [NSCursor unhide];
    [_previousCursor set];
    [_previousCursor release];
    _previousCursor = nil;

    void (^handler)(NSColor *) = _handler;
    _handler = nil;
    handler(color);
    [handler release];
    [self autorelease];   // balances the retain taken in -showSamplerWithSelectionHandler:
}

- (void)showSamplerWithSelectionHandler:(void (^)(NSColor *))selectionHandler
{
    if (!selectionHandler)
        return;
    if (_handler) {       // already sampling; the real API ignores a second request
        selectionHandler(nil);
        return;
    }

    _handler = [selectionHandler copy];
    [self retain];        // stay alive until the handler runs, as the real sampler does
    _previousCursor = [[NSCursor currentCursor] retain];
    [[NSCursor crosshairCursor] set];

    // Global monitors see events destined for other applications, which is the point: the user is
    // sampling anywhere on screen, usually outside this app. The local monitor covers our own windows,
    // which global monitors deliberately skip.
    _mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSLeftMouseDownMask | NSRightMouseDownMask)
        handler:^(NSEvent *event) {
            [self wkFinishWithColor:([event type] == NSRightMouseDown) ? nil : wkColorUnderCursor()];
        }];
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSLeftMouseDownMask | NSRightMouseDownMask | NSKeyDownMask)
        handler:^NSEvent *(NSEvent *event) {
            if ([event type] == NSKeyDown) {
                if ([event keyCode] != 53)   // Escape
                    return event;
                [self wkFinishWithColor:nil];
                return nil;
            }
            [self wkFinishWithColor:([event type] == NSRightMouseDown) ? nil : wkColorUnderCursor()];
            return nil;                       // swallow the click that committed the sample
        }];
    _keyMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSKeyDownMask
        handler:^(NSEvent *event) {
            if ([event keyCode] == 53)
                [self wkFinishWithColor:nil];
        }];
}

- (void)dealloc
{
    if (_mouseMonitor) [NSEvent removeMonitor:_mouseMonitor];
    if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    if (_localMonitor) [NSEvent removeMonitor:_localMonitor];
    [_previousCursor release];
    [_handler release];
    [super dealloc];
}

@end
WK_PRIV_ALIAS(NSColorSampler);

// NSServicesRolloverButtonCell (AppKit SPI, absent on 10.9): the little rollover button WebKit draws on
// an image when ENABLE(SERVICE_CONTROLS) is on, which opens the sharing-services menu. It is an
// NSButtonCell subclass, and NSButtonCell is 10.0 API, so the inherited half — sizing (-cellSize),
// bezel style, and all the drawing WebKit does through -drawWithFrame:inView: — is the real AppKit
// implementation, not a stand-in. Only the two SPI additions need supplying:
//
//   +serviceRolloverButtonCellForStyle: is a convenience constructor; the caller immediately sets the
//   bezel style it wants (ControlFactoryMac sets NSBezelStyleRoundedDisclosure), so a plain instance is
//   what the real one hands back for WebKit's purposes.
//
//   -rectForBounds:preferredEdge: reports where the services menu should be anchored. With no system
//   sharing-menu geometry to consult on 10.9, the cell's own bounds is the honest answer: the menu is
//   anchored on the button itself.
//
// WebKit reaches this one by CLASSREF (`[NSServicesRolloverButtonCell serviceRolloverButtonCellForStyle:]`),
// and the classref binds two-level to AppKit, which is where the build SDK declares the class. That is why
// libpolyfill_classes.dylib REEXPORTS AppKit and stage-frameworks.sh repoints each WebKit binary's AppKit
// load command at it — the same capture the four other reexported frameworks already use. Without that the
// alias below is never consulted and dyld fails the whole process at load with
// "Symbol not found: _OBJC_CLASS_$_NSServicesRolloverButtonCell".
WK_PRIV_CLASS(NSServicesRolloverButtonCell) @interface NSServicesRolloverButtonCell : NSButtonCell
+ (NSServicesRolloverButtonCell *)serviceRolloverButtonCellForStyle:(NSInteger)style;
- (NSRect)rectForBounds:(NSRect)bounds preferredEdge:(NSRectEdge)preferredEdge;
@end

@implementation NSServicesRolloverButtonCell

+ (NSServicesRolloverButtonCell *)serviceRolloverButtonCellForStyle:(NSInteger)style
{
    (void)style;
    return [[[self alloc] init] autorelease];
}

- (NSRect)rectForBounds:(NSRect)bounds preferredEdge:(NSRectEdge)preferredEdge
{
    (void)preferredEdge;
    return bounds;
}

@end
WK_PRIV_ALIAS(NSServicesRolloverButtonCell);

// NSExtension (private Foundation, 10.10+): the app-extension registry. 10.9 predates app extensions
// entirely — Services on this OS come from service bundles reached through NSSharingService, which is
// present and which WebKit's ServicesController goes on using — so there is no extension registry here
// to look anything up in, and no extension set that can change.
//
// That makes every honest answer an empty one, and each is what the real API returns when nothing
// matches: +beginMatchingExtensionsWithAttributes:completion: hands back nil (no watcher token, because
// there is nothing to watch), and +extensionWithIdentifier:error: hands back nil (no such extension).
// ServicesController keeps its watcher in a RetainPtr and only releases it, so nil is handled; the
// consequence is simply that the services list is not refreshed when extensions change, which on an OS
// with no extensions is not a change that can occur.
//
// The instance methods exist so a caller that somehow obtains one gets the documented shape rather than
// an unrecognized selector; they cannot be reached, since no instance can be created.
WK_PRIV_CLASS(NSExtension) @interface NSExtension : NSObject
+ (id)beginMatchingExtensionsWithAttributes:(NSDictionary *)attributes completion:(void (^)(NSArray *, NSError *))completion;
+ (void)cancelMatchingExtensions:(id)token;
+ (NSExtension *)extensionWithIdentifier:(NSString *)bundleIdentifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(id<NSCopying>, NSError *))handler;
- (void)cancelExtensionRequestWithIdentifier:(id<NSCopying>)requestIdentifier;
@end

@implementation NSExtension

+ (id)beginMatchingExtensionsWithAttributes:(NSDictionary *)attributes completion:(void (^)(NSArray *, NSError *))completion
{
    (void)attributes;
    // Report the empty match once, so a caller waiting on the completion is not left hanging, then
    // hand back no watcher token: nothing on this OS can change the (empty) extension set later.
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@[], nil);
        });
    }
    return nil;
}

+ (void)cancelMatchingExtensions:(id)token
{
    (void)token;
}

+ (NSExtension *)extensionWithIdentifier:(NSString *)bundleIdentifier error:(NSError **)error
{
    (void)bundleIdentifier;
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
    return nil;
}

- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(id<NSCopying>, NSError *))handler
{
    (void)inputItems;
    if (handler)
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}

- (void)cancelExtensionRequestWithIdentifier:(id<NSCopying>)requestIdentifier
{
    (void)requestIdentifier;
}

@end
WK_PRIV_ALIAS(NSExtension);

// AVOutputContext / AVOutputDevice (AVFoundation SPI, 10.11+): the wireless-playback-target ("AirPlay to
// this device") routing surface. 10.9 has no such facility at all — no route discovery, no output-device
// registry — so the honest answer to every query is the empty one, and that is exactly what these return.
//
// An empty output-device list is not a placeholder: it is what the real API reports on a machine with no
// AirPlay receivers in range, which is the permanent condition here. WebCore's wireless-playback code is
// written for that answer — it simply never offers a route picker target.
//
// These exist so ENABLE(WIRELESS_PLAYBACK_TARGET) can stay at upstream's ON, which keeps
// Source/cmake/OptionsMac.cmake and PAL/pal/PlatformMac.cmake byte-upstream. Supplying two stub classes in
// this layer is the cheaper trade: a divergence in Source/ is paid at every upstream merge, a stub here is
// paid once and is confined to WebKit's own images.
WK_PRIV_CLASS(AVOutputDevice) @interface AVOutputDevice : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *deviceName;
@property (nonatomic, readonly) NSUInteger deviceFeatures;
@end

@implementation AVOutputDevice
- (NSString *)name { return @""; }
- (NSString *)deviceName { return @""; }
// No features: this device can carry neither audio, video nor a screen, because it cannot exist.
- (NSUInteger)deviceFeatures { return 0; }
@end
WK_PRIV_ALIAS(AVOutputDevice);

WK_PRIV_CLASS(AVOutputContext) @interface AVOutputContext : NSObject <NSSecureCoding>
+ (instancetype)outputContext;
+ (instancetype)iTunesAudioContext;
+ (AVOutputContext *)sharedAudioPresentationOutputContext;
+ (AVOutputContext *)sharedSystemAudioContext;
+ (AVOutputContext *)outputContextForID:(NSString *)ID;
@property (nonatomic, readonly) NSString *deviceName;
@property (readonly) BOOL supportsMultipleOutputDevices;
@property (readonly) NSArray *outputDevices;
@property (nonatomic, readonly) AVOutputDevice *outputDevice;
@end

@implementation AVOutputContext

// The real API vends a shared context per audio presentation; with no routing service there is one
// context and it routes nowhere, so a single shared instance is the faithful shape.
+ (instancetype)outputContext { return [self sharedAudioPresentationOutputContext]; }
+ (instancetype)iTunesAudioContext { return [self sharedAudioPresentationOutputContext]; }
+ (AVOutputContext *)sharedSystemAudioContext { return [self sharedAudioPresentationOutputContext]; }

+ (AVOutputContext *)sharedAudioPresentationOutputContext
{
    static AVOutputContext *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[AVOutputContext alloc] init]; });
    return shared;
}

// No context can be looked up by ID because none is ever published.
+ (AVOutputContext *)outputContextForID:(NSString *)ID { (void)ID; return nil; }

- (NSString *)deviceName { return @""; }
- (BOOL)supportsMultipleOutputDevices { return NO; }
- (NSArray *)outputDevices { return @[]; }
- (AVOutputDevice *)outputDevice { return nil; }

// NSSecureCoding: CoreIPCAVOutputContext serialises one across the IPC boundary. A context that names no
// device carries no state, so encoding writes nothing and decoding yields the shared context.
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    (void)coder;
    [self release];
    return [[AVOutputContext sharedAudioPresentationOutputContext] retain];
}

@end
WK_PRIV_ALIAS(AVOutputContext);
