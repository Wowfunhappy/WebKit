// 10.9 backport: UTType class accessors are 11.0+; provide helpers that fall
// back to legacy kUTType* CFString constants when the modern accessor isn't
// available. Without these guards, sending +PNG/+fileURL/etc to the polyfill
// UTType class throws unrecognized-selector and crashes the process.

#pragma once

#if PLATFORM(MAC)

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreServices/CoreServices.h>

namespace WebCore {

#define DEFINE_UT_HELPER(NAME, MODERN_SEL, MODERN_OBJ, LEGACY_KEY) \
    static inline NSString *NAME() \
    { \
        if ([UTType respondsToSelector:@selector(MODERN_SEL)]) \
            return MODERN_OBJ.identifier; \
        return (__bridge NSString *)LEGACY_KEY; \
    }

DEFINE_UT_HELPER(utTypePNGId,            PNG,            UTTypePNG,            kUTTypePNG)
DEFINE_UT_HELPER(utTypeJPEGId,           JPEG,           UTTypeJPEG,           kUTTypeJPEG)
DEFINE_UT_HELPER(utTypeTIFFId,           TIFF,           UTTypeTIFF,           kUTTypeTIFF)
DEFINE_UT_HELPER(utTypeURLId,            URL,            UTTypeURL,            kUTTypeURL)
DEFINE_UT_HELPER(utTypeFileURLId,        fileURL,        UTTypeFileURL,        kUTTypeFileURL)
DEFINE_UT_HELPER(utTypeHTMLId,           HTML,           UTTypeHTML,           kUTTypeHTML)
DEFINE_UT_HELPER(utTypePDFId,            PDF,            UTTypePDF,            kUTTypePDF)
DEFINE_UT_HELPER(utTypeRTFId,            RTF,            UTTypeRTF,            kUTTypeRTF)
DEFINE_UT_HELPER(utTypeFlatRTFDId,       flatRTFD,       UTTypeFlatRTFD,       kUTTypeFlatRTFD)
DEFINE_UT_HELPER(utTypeTextId,           text,           UTTypeText,           kUTTypeText)
DEFINE_UT_HELPER(utTypePlainTextId,      plainText,      UTTypePlainText,      kUTTypePlainText)
DEFINE_UT_HELPER(utTypeUTF8PlainTextId,  UTF8PlainText,  UTTypeUTF8PlainText,  kUTTypeUTF8PlainText)
DEFINE_UT_HELPER(utTypeContentId,        content,        UTTypeContent,        kUTTypeContent)
DEFINE_UT_HELPER(utTypeItemId,           item,           UTTypeItem,           kUTTypeItem)
DEFINE_UT_HELPER(utTypeDirectoryId,      directory,      UTTypeDirectory,      kUTTypeDirectory)
DEFINE_UT_HELPER(utTypeDataId,           data,           UTTypeData,           kUTTypeData)
// utTypeVCard helper removed: UTTypeVCard not declared in this SDK; use literal "public.vcard" instead.
static inline NSString *utTypeVCardId() { return @"public.vcard"; }

#undef DEFINE_UT_HELPER

// Web archive UTType has no documented kUTType constant; use the literal.
static inline NSString *utTypeWebArchiveId() { return @"com.apple.webarchive"; }

}

#endif // PLATFORM(MAC)
