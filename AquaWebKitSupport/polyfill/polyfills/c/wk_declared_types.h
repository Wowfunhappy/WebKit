// Types the modern system declares that 10.9's LaunchServices has never heard of, with the filename
// extension and MIME type each is declared with: the HEIF family as the macOS SDK's UTCoreTypes.h names
// it -- public.heif, public.heic and public.heics conforming to public.heif-standard, which conforms to
// public.image -- and the AVIF and WebP image formats, each conforming to public.image.
//
// classes/UniformTypeIdentifiers.m (UTType), methods/Foundation.m (NSURLFileTypeMappings, and the MIME
// type of a file URL's NSURLResponse) and c/CFNetwork.c (the same, for CFURLResponse) answer these types
// from this table and every other type from LaunchServices.
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>

typedef struct {
    CFStringRef identifier;
    CFStringRef conformsTo;
    CFStringRef filenameExtension;
    CFStringRef mimeType;
} WKDeclaredType;

static const WKDeclaredType wkDeclaredTypes[] = {
    { CFSTR("public.heif-standard"), CFSTR("public.image"), NULL, NULL },
    { CFSTR("public.heif"), CFSTR("public.heif-standard"), CFSTR("heif"), CFSTR("image/heif") },
    { CFSTR("public.heic"), CFSTR("public.heif-standard"), CFSTR("heic"), CFSTR("image/heic") },
    { CFSTR("public.heics"), CFSTR("public.heif-standard"), CFSTR("heics"), CFSTR("image/heic-sequence") },
    { CFSTR("public.avif"), CFSTR("public.image"), CFSTR("avif"), CFSTR("image/avif") },
    { CFSTR("org.webmproject.webp"), CFSTR("public.image"), CFSTR("webp"), CFSTR("image/webp") },
};

#define WK_DECLARED_TYPE_COUNT (sizeof(wkDeclaredTypes) / sizeof(wkDeclaredTypes[0]))

// Identifiers, extensions and MIME types all compare case-insensitively.
static inline int wkDeclaredTypeStringsEqual(CFStringRef a, CFStringRef b)
{
    return a && b && CFStringCompare(a, b, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

static inline const WKDeclaredType *wkDeclaredTypeForIdentifier(CFStringRef identifier)
{
    for (size_t i = 0; i < WK_DECLARED_TYPE_COUNT; ++i) {
        if (wkDeclaredTypeStringsEqual(wkDeclaredTypes[i].identifier, identifier))
            return &wkDeclaredTypes[i];
    }
    return NULL;
}

static inline const WKDeclaredType *wkDeclaredTypeForFilenameExtension(CFStringRef extension)
{
    for (size_t i = 0; i < WK_DECLARED_TYPE_COUNT; ++i) {
        if (wkDeclaredTypeStringsEqual(wkDeclaredTypes[i].filenameExtension, extension))
            return &wkDeclaredTypes[i];
    }
    return NULL;
}

static inline const WKDeclaredType *wkDeclaredTypeForMIMEType(CFStringRef mimeType)
{
    for (size_t i = 0; i < WK_DECLARED_TYPE_COUNT; ++i) {
        if (wkDeclaredTypeStringsEqual(wkDeclaredTypes[i].mimeType, mimeType))
            return &wkDeclaredTypes[i];
    }
    return NULL;
}

// The declared type, with a MIME type, that a file URL's filename extension names.
static inline const WKDeclaredType *wkDeclaredTypeForFileURL(CFURLRef url)
{
    if (!url)
        return NULL;
    CFStringRef scheme = CFURLCopyScheme(url);
    Boolean isFile = scheme && CFStringCompare(scheme, CFSTR("file"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (scheme)
        CFRelease(scheme);
    if (!isFile)
        return NULL;
    CFStringRef extension = CFURLCopyPathExtension(url);
    if (!extension)
        return NULL;
    const WKDeclaredType *declared = wkDeclaredTypeForFilenameExtension(extension);
    CFRelease(extension);
    return declared && declared->mimeType ? declared : NULL;
}

// A URL response's MIME type is either derived by the loader from what it loaded or given by whoever
// built or retyped the response. A file URL's loader derives it from the filename extension, so a
// derived MIME type for a declared type's extension is that type's. Responses given a MIME type carry
// a mark on the CFURLResponse, under a selector key every image's copy of this header shares.
static inline const void *wkGivenMIMETypeKey(void)
{
    return (const void *)sel_registerName("wk_givenMIMEType");
}

static inline void wkMarkGivenMIMEType(CFTypeRef response)
{
    if (response)
        objc_setAssociatedObject((id)response, wkGivenMIMETypeKey(), (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The declared MIME type a response's loader derives, or NULL when LaunchServices answers for it.
static inline CFStringRef wkDerivedDeclaredMIMEType(CFTypeRef response, CFURLRef url)
{
    if (!response || objc_getAssociatedObject((id)response, wkGivenMIMETypeKey()))
        return NULL;
    const WKDeclaredType *declared = wkDeclaredTypeForFileURL(url);
    return declared ? declared->mimeType : NULL;
}
