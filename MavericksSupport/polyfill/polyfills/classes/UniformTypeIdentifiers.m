// UniformTypeIdentifiers: the UTType class and its object constants, from a framework 10.9 does not
// ship at all, built over the classic CoreServices UTType C API.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

// This OS's LaunchServices carries the tag-listing entry point only under its pre-10.10 private
// spelling _UTTypeCopyAllTagsWithClass (Mach-O __UTTypeCopyAllTagsWithClass; the public name shipped
// in 10.10). Used by -[UTType tags] below.
extern CFArrayRef _UTTypeCopyAllTagsWithClass(CFStringRef inUTI, CFStringRef inTagClass);
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
    return [self typeWithMIMEType:mimeType conformingToType:nil];
}
// The supertype constrains the search exactly as the classic API's third argument does: asking for
// image/png conformingToType:UTTypeImage resolves through the image branch of the registry rather
// than whatever type happens to claim the MIME tag first. CocoaImage's transcode path relies on it.
+ (nullable instancetype)typeWithMIMEType:(NSString *)mimeType conformingToType:(UTType *)supertype
{
    if (!mimeType) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)mimeType,
        supertype ? (__bridge CFStringRef)supertype->_identifier : NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
// The general tag lookup the two conveniences above special-case. The UTTagClass* object constants
// (c/UniformTypeIdentifiers.m) carry the same string values the classic kUTTagClass* CFStringRefs have, so the tag
// class passes straight through to LaunchServices. WebCoreURLResponse's
// preferredMIMETypeForFileExtensionFromUTType passes conformingToType:nil; a non-nil supertype
// constrains the search the same way the classic API's third argument does.
+ (nullable instancetype)typeWithTag:(NSString *)tag tagClass:(NSString *)tagClass conformingToType:(UTType *)supertype
{
    if (!tag || !tagClass) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag((__bridge CFStringRef)tagClass, (__bridge CFStringRef)tag,
        supertype ? (__bridge CFStringRef)supertype->_identifier : NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
// -tags (11.0+): the type's known tags, keyed by tag class. MIMETypeRegistry::preferredExtensionForMIMEType
// indexes it with UTTagClassFilenameExtension. Built from the same LaunchServices registry the modern
// framework reads (_UTTypeCopyAllTagsWithClass, declared above), for the two tag classes WebKit and
// the modern framework both know.
- (NSDictionary *)tags
{
    if (!_identifier) return [NSDictionary dictionary];
    NSMutableDictionary *tags = [NSMutableDictionary dictionary];
    CFArrayRef extensions = _UTTypeCopyAllTagsWithClass((__bridge CFStringRef)_identifier, kUTTagClassFilenameExtension);
    if (extensions) {
        if (CFArrayGetCount(extensions))
            [tags setObject:(__bridge NSArray *)extensions forKey:@"public.filename-extension"];
        CFRelease(extensions);
    }
    CFArrayRef mimeTypes = _UTTypeCopyAllTagsWithClass((__bridge CFStringRef)_identifier, kUTTagClassMIMEType);
    if (mimeTypes) {
        if (CFArrayGetCount(mimeTypes))
            [tags setObject:(__bridge NSArray *)mimeTypes forKey:@"public.mime-type"];
        CFRelease(mimeTypes);
    }
    return tags;
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
