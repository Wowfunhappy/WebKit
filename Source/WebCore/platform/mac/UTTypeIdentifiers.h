// MAVERICKS_BACKPORT: UniformTypeIdentifiers (the UTType class and the UTType* constants) is macOS
// 11.0+ and absent at runtime on 10.9. These helpers return the legacy CoreServices kUTType* CFString
// constants (present on 10.9 and still declared, deprecated, by the build SDK). The value is returned
// UNCONDITIONALLY: referencing a modern UTType* object — even behind a respondsToSelector guard —
// emits an undefined UTType* data symbol, which cannot be satisfied when linking a 10.9 target
// against the modern SDK (the modern symbol lives only in the absent UniformTypeIdentifiers).

#pragma once

#if PLATFORM(MAC)

#import <CoreServices/CoreServices.h>

namespace WebCore {

#define DEFINE_UT_HELPER(NAME, LEGACY_KEY) \
    static inline NSString *NAME() \
    { \
        return (__bridge NSString *)LEGACY_KEY; \
    }

DEFINE_UT_HELPER(utTypePNGId,            kUTTypePNG)
DEFINE_UT_HELPER(utTypeJPEGId,           kUTTypeJPEG)
DEFINE_UT_HELPER(utTypeTIFFId,           kUTTypeTIFF)
DEFINE_UT_HELPER(utTypeURLId,            kUTTypeURL)
DEFINE_UT_HELPER(utTypeFileURLId,        kUTTypeFileURL)
DEFINE_UT_HELPER(utTypeHTMLId,           kUTTypeHTML)
DEFINE_UT_HELPER(utTypePDFId,            kUTTypePDF)
DEFINE_UT_HELPER(utTypeRTFId,            kUTTypeRTF)
DEFINE_UT_HELPER(utTypeFlatRTFDId,       kUTTypeFlatRTFD)
DEFINE_UT_HELPER(utTypeTextId,           kUTTypeText)
DEFINE_UT_HELPER(utTypePlainTextId,      kUTTypePlainText)
DEFINE_UT_HELPER(utTypeUTF8PlainTextId,  kUTTypeUTF8PlainText)
DEFINE_UT_HELPER(utTypeContentId,        kUTTypeContent)
DEFINE_UT_HELPER(utTypeItemId,           kUTTypeItem)
DEFINE_UT_HELPER(utTypeDirectoryId,      kUTTypeDirectory)
DEFINE_UT_HELPER(utTypeDataId,           kUTTypeData)
DEFINE_UT_HELPER(utTypeGIFId,            kUTTypeGIF)
DEFINE_UT_HELPER(utTypePackageId,        kUTTypePackage)
DEFINE_UT_HELPER(utTypeFolderId,         kUTTypeFolder)

// kUTTypeVCard / kUTTypeWebArchive exist in CoreServices (deprecated; macos(10.4, 12.0)).
static inline NSString *utTypeVCardId() { return (__bridge NSString *)kUTTypeVCard; }
static inline NSString *utTypeWebArchiveId() { return (__bridge NSString *)kUTTypeWebArchive; }

#undef DEFINE_UT_HELPER

}

#endif // PLATFORM(MAC)
