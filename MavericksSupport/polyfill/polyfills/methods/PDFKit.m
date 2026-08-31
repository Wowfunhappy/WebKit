// PDFKit: Objective-C methods on PDFKit classes that macOS 10.9 does not have, implemented with the
// APIs 10.9 does have.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// -[PDFPage drawWithBox:toContext:] (10.12+) via the classic -[PDFPage drawWithBox:] (10.4+), which
// renders into the CURRENT NSGraphicsContext. Wrap the passed CGContext as current for the duration of
// the draw, restoring the prior context after — the CTM the caller applied to `context` is honored.
WK_POLYFILL_ADD_METHODS(PDFPage)
- (void)drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context
{
    NSGraphicsContext *priorContext = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:NO]];
    [self drawWithBox:box];
    [NSGraphicsContext setCurrentContext:priorContext];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[PDFAnnotation URL] / -destination (10.13+): PDFKit's unification of the per-subclass annotation
// API — the base class answers with the link target for link annotations and nil for everything else.
// 10.9 keeps these on PDFAnnotationLink only, and the aliasing layer reproduces the unified shape by
// itself: a PDFAnnotationLink resolves to its own real -URL/-destination, every other annotation class
// falls to these base-class bodies, whose truthful answer is nil (a non-link annotation has no link
// target). WKPrintingView's printed-PDF link preservation walks annotations exactly this way.
WK_POLYFILL_ADD_METHODS(PDFAnnotation)
- (NSURL *)URL { return nil; }
- (PDFDestination *)destination { return nil; }
@end

// ---------------------------------------------------------------------------------------------------
// -[PDFAnnotation valueForAnnotationKey:] (10.13+): the other half of that same unification. Where
// 10.9 gives each annotation kind its own class with its own accessors, 10.13 gives every annotation
// one class, read by PDF dictionary key. That is not a new capability — it is a different way of
// spelling one this PDFKit already has, because an annotation here still carries the dictionary it
// was parsed from and hands it over through -sourceDictionary. So the whole API is answered from the
// dictionary, for any key, rather than special-casing the keys WebKit happens to ask for today.
//
// Two spellings differ between the raw dictionary and the modern API, and both are PDF name syntax:
// the API's keys and name-typed values carry the leading slash that the file's dictionary omits
// (/Subtype -> Subtype, /Widget <- Widget). 10.9's own -dictionaryRef, which reports the same
// annotation as { "/Subtype" = "/Widget"; "/FT" = "/Tx"; }, is where that convention is read off.
//
// Sources, in order of fidelity:
//  - -sourceDictionary, the annotation's dictionary as it appears in the file. Authoritative.
//  - -dictionaryRef, PDFKit's regenerated dictionary, already keyed the modern way. Consulted only
//    when there is no source dictionary, which happens for annotations PDFKit synthesizes rather
//    than parses (measured: a generated Popup). It is second because it is lossy — for a signature
//    widget it renames the subtype to /Stamp and drops /FT, and it is that regeneration, not the
//    file, that decides the answer.
//  - -type for /Subtype, the 10.4 accessor every annotation implements, if neither dictionary is
//    there at all.
//
// A signature widget is why the class of the object cannot stand in for the dictionary: this PDFKit
// instantiates /FT /Sig as PDFAnnotationStamp (measured), so reading the field type off the class
// answers "none" for a field whose dictionary plainly says Sig.
// Both are implemented by 10.9's PDFAnnotation but declared in none of its headers.
@interface PDFAnnotation (WKPolyfillPDFKitAnnotationDictionary)
- (CGPDFDictionaryRef)sourceDictionary;
- (CFDictionaryRef)dictionaryRef;
@end

// A PDF dictionary is a graph, not a tree — an annotation's /P reaches its page, whose /Annots reaches
// the annotation again — so conversion carries the set of dictionaries on the current path and stops
// where it would revisit one. Without that a single /P would recurse until the stack ran out.
struct wk_pdfConversion {
    NSMutableDictionary *result;
    CFMutableSetRef path;
};

static id wk_objectFromPDFObject(CGPDFObjectRef, CFMutableSetRef path);

static NSDictionary *wk_dictionaryFromPDFDictionary(CGPDFDictionaryRef, CFMutableSetRef path);

static void wk_addPDFDictionaryEntry(const char *key, CGPDFObjectRef value, void *context)
{
    struct wk_pdfConversion *conversion = (struct wk_pdfConversion *)context;
    NSString *name = key ? [NSString stringWithUTF8String:key] : nil;
    if (!name)
        return;
    id object = wk_objectFromPDFObject(value, conversion->path);
    if (object)
        [conversion->result setObject:object forKey:[@"/" stringByAppendingString:name]];
}

static NSDictionary *wk_dictionaryFromPDFDictionary(CGPDFDictionaryRef dictionary, CFMutableSetRef path)
{
    if (!dictionary || CFSetContainsValue(path, dictionary))
        return nil;

    CFSetAddValue(path, dictionary);
    struct wk_pdfConversion conversion = { [NSMutableDictionary dictionary], path };
    CGPDFDictionaryApplyFunction(dictionary, wk_addPDFDictionaryEntry, &conversion);
    CFSetRemoveValue(path, dictionary);
    return conversion.result;
}

static id wk_objectFromPDFObject(CGPDFObjectRef object, CFMutableSetRef path)
{
    switch (CGPDFObjectGetType(object)) {
    case kCGPDFObjectTypeBoolean: {
        CGPDFBoolean value = 0;
        if (CGPDFObjectGetValue(object, kCGPDFObjectTypeBoolean, &value))
            return [NSNumber numberWithBool:value ? YES : NO];
        return nil;
    }
    case kCGPDFObjectTypeInteger: {
        CGPDFInteger value = 0;
        if (CGPDFObjectGetValue(object, kCGPDFObjectTypeInteger, &value))
            return [NSNumber numberWithLong:(long)value];
        return nil;
    }
    case kCGPDFObjectTypeReal: {
        CGPDFReal value = 0;
        if (CGPDFObjectGetValue(object, kCGPDFObjectTypeReal, &value))
            return [NSNumber numberWithDouble:(double)value];
        return nil;
    }
    case kCGPDFObjectTypeName: {
        const char *value = NULL;
        if (!CGPDFObjectGetValue(object, kCGPDFObjectTypeName, &value) || !value)
            return nil;
        NSString *name = [NSString stringWithUTF8String:value];
        return name ? [@"/" stringByAppendingString:name] : nil;
    }
    case kCGPDFObjectTypeString: {
        CGPDFStringRef value = NULL;
        if (!CGPDFObjectGetValue(object, kCGPDFObjectTypeString, &value) || !value)
            return nil;
        // A PDF text string is not necessarily UTF-8; CGPDFStringCopyTextString decodes the
        // PDFDocEncoding / UTF-16 forms the specification allows.
        return [(NSString *)CGPDFStringCopyTextString(value) autorelease];
    }
    case kCGPDFObjectTypeArray: {
        CGPDFArrayRef value = NULL;
        if (!CGPDFObjectGetValue(object, kCGPDFObjectTypeArray, &value) || !value)
            return nil;
        size_t count = CGPDFArrayGetCount(value);
        NSMutableArray *elements = [NSMutableArray arrayWithCapacity:count];
        for (size_t i = 0; i < count; i++) {
            CGPDFObjectRef element = NULL;
            id converted = CGPDFArrayGetObject(value, i, &element) ? wk_objectFromPDFObject(element, path) : nil;
            // NSNull rather than a shorter array: an entry that cannot be represented must not shift
            // the indices of the ones after it, which a PDF array's meaning depends on (/Rect).
            [elements addObject:converted ?: (id)[NSNull null]];
        }
        return elements;
    }
    case kCGPDFObjectTypeDictionary: {
        CGPDFDictionaryRef value = NULL;
        if (!CGPDFObjectGetValue(object, kCGPDFObjectTypeDictionary, &value))
            return nil;
        return wk_dictionaryFromPDFDictionary(value, path);
    }
    case kCGPDFObjectTypeStream: {
        // A stream's value in this API is its dictionary: /AP is documented as a Dictionary, and its
        // appearance streams are what that dictionary holds.
        CGPDFStreamRef value = NULL;
        if (!CGPDFObjectGetValue(object, kCGPDFObjectTypeStream, &value) || !value)
            return nil;
        return wk_dictionaryFromPDFDictionary(CGPDFStreamGetDictionary(value), path);
    }
    case kCGPDFObjectTypeNull:
        break;
    }
    return nil;
}

WK_POLYFILL_ADD_METHODS(PDFAnnotation)
- (id)valueForAnnotationKey:(PDFAnnotationKey)key
{
    if (![key length])
        return nil;

    // The API's key is PDF name syntax; the file's dictionary is keyed by the bare name.
    NSString *bareKey = [key hasPrefix:@"/"] ? [key substringFromIndex:1] : key;

    if ([self respondsToSelector:@selector(sourceDictionary)]) {
        CGPDFDictionaryRef dictionary = [self sourceDictionary];
        CGPDFObjectRef object = NULL;
        if (dictionary && CGPDFDictionaryGetObject(dictionary, [bareKey UTF8String], &object)) {
            CFMutableSetRef path = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
            id value = wk_objectFromPDFObject(object, path);
            CFRelease(path);
            if (value)
                return value;
        }
    }

    if ([self respondsToSelector:@selector(dictionaryRef)]) {
        NSDictionary *dictionary = (NSDictionary *)[self dictionaryRef];
        if ([dictionary isKindOfClass:[NSDictionary class]]) {
            id value = [dictionary objectForKey:key];
            if (value)
                return value;
        }
    }

    if ([bareKey isEqualToString:@"Subtype"]) {
        NSString *type = [self type];
        return type ? [@"/" stringByAppendingString:type] : nil;
    }

    return nil;
}
@end

#pragma clang diagnostic pop
