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
WK_PRIV_CLASS(_NSHSTSStorage) @interface _NSHSTSStorage : NSObject @end
@implementation _NSHSTSStorage @end
WK_PRIV_ALIAS(_NSHSTSStorage);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesFilter) @interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
WK_PRIV_ALIAS(_NSHTTPAlternativeServicesFilter);
WK_PRIV_CLASS(_NSHTTPAlternativeServicesStorage) @interface _NSHTTPAlternativeServicesStorage : NSObject @end
@implementation _NSHTTPAlternativeServicesStorage @end
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
