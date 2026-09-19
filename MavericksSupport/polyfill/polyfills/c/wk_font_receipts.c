// OS package receipts from the running machine, read on the first question about a font's provenance.
#include "wk_font_receipts.h"
#include "wk_polyfill.h"
#include "wk_symbols.h"
#include <CoreFoundation/CoreFoundation.h>
#include <fnmatch.h>
#include <glob.h>
#include <pthread.h>
#include <string.h>

#define WK_BOM "/System/Library/PrivateFrameworks/Bom.framework/Bom"
WK_SYSTEM_FN(WK_BOM, void *, BOMBomOpenWithSys, (const char *, int, void *));
WK_SYSTEM_FN(WK_BOM, void, BOMBomFree, (void *));
WK_SYSTEM_FN(WK_BOM, void *, BOMBomEnumeratorNewWithOptions, (void *, void *, unsigned));
WK_SYSTEM_FN(WK_BOM, void *, BOMBomEnumeratorNext, (void *));
WK_SYSTEM_FN(WK_BOM, void, BOMBomEnumeratorFree, (void *));
WK_SYSTEM_FN(WK_BOM, void, BOMBomEnumeratorSkip, (void *));
WK_SYSTEM_FN(WK_BOM, const char *, BOMFSObjectPathName, (void *));
WK_SYSTEM_FN(WK_BOM, uint64_t, BOMFSObjectSize, (void *));
WK_SYSTEM_FN(WK_BOM, unsigned, BOMFSObjectType, (void *));
WK_SYSTEM_FN(WK_BOM, void, BOMFSObjectFree, (void *));

static CFMutableDictionaryRef wk_fontReceipts;
static pthread_once_t wk_fontReceiptsOnce = PTHREAD_ONCE_INIT;

static bool wk_isOSReceipt(const char *path)
{
    const char *name = strrchr(path, '/') + 1;
    static const char *const patterns[] = {
        "com.apple.pkg.Essentials.bom", "com.apple.pkg.BaseSystem*.bom", "com.apple.pkg.Core.bom",
        "com.apple.pkg.update.os.*.bom", "com.apple.pkg.update.security.*.bom", "com.apple.pkg.SecurityUpdate*.bom"
    };
    for (unsigned i = 0; i < sizeof(patterns) / sizeof(patterns[0]); ++i) {
        if (!fnmatch(patterns[i], name, 0))
            return true;
    }
    return false;
}

static bool wk_isFontPath(const char *path)
{
    return !strncmp(path, "./Library/Fonts/", 16) || !strncmp(path, "./System/Library/Fonts/", 23);
}

static bool wk_isFontAncestor(const char *path)
{
    return !strcmp(path, ".") || !strcmp(path, "./Library") || !strcmp(path, "./Library/Fonts")
        || !strcmp(path, "./System") || !strcmp(path, "./System/Library") || !strcmp(path, "./System/Library/Fonts");
}

static void wk_readFontReceipts(void)
{
    if (!WK_SYSTEM(BOMBomOpenWithSys) || !WK_SYSTEM(BOMBomFree)
        || !WK_SYSTEM(BOMBomEnumeratorNewWithOptions) || !WK_SYSTEM(BOMBomEnumeratorNext)
        || !WK_SYSTEM(BOMBomEnumeratorFree) || !WK_SYSTEM(BOMBomEnumeratorSkip)
        || !WK_SYSTEM(BOMFSObjectPathName) || !WK_SYSTEM(BOMFSObjectSize)
        || !WK_SYSTEM(BOMFSObjectType) || !WK_SYSTEM(BOMFSObjectFree))
        wk_patch_fail("system font receipts", "native BOM API is incomplete");
    wk_fontReceipts = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    glob_t receipts = { 0 };
    glob("/private/var/db/receipts/com.apple.pkg.*.bom", 0, NULL, &receipts);
    for (size_t i = 0; i < receipts.gl_pathc; ++i) {
        if (!wk_isOSReceipt(receipts.gl_pathv[i]))
            continue;
        void *bom = WK_SYSTEM(BOMBomOpenWithSys)(receipts.gl_pathv[i], 0, NULL);
        if (!bom)
            continue;
        // Option 1 enumerates the paths in the package, as lsbom does.
        void *iterator = WK_SYSTEM(BOMBomEnumeratorNewWithOptions)(bom, NULL, 1);
        void *object;
        while (iterator && (object = WK_SYSTEM(BOMBomEnumeratorNext)(iterator))) {
            const char *path = WK_SYSTEM(BOMFSObjectPathName)(object);
            if (path && wk_isFontPath(path)) {
                CFStringRef key = CFStringCreateWithCString(NULL, path + 1, kCFStringEncodingUTF8);
                int64_t size = WK_SYSTEM(BOMFSObjectSize)(object);
                CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &size);
                CFMutableSetRef sizes = (CFMutableSetRef)CFDictionaryGetValue(wk_fontReceipts, key);
                if (!sizes) {
                    sizes = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
                    CFDictionarySetValue(wk_fontReceipts, key, sizes);
                    CFRelease(sizes);
                }
                CFSetAddValue(sizes, number);
                CFRelease(number);
                CFRelease(key);
            } else if (path && WK_SYSTEM(BOMFSObjectType)(object) == 2 && !wk_isFontAncestor(path))
                WK_SYSTEM(BOMBomEnumeratorSkip)(iterator);
            WK_SYSTEM(BOMFSObjectFree)(object);
        }
        if (iterator)
            WK_SYSTEM(BOMBomEnumeratorFree)(iterator);
        WK_SYSTEM(BOMBomFree)(bom);
    }
    globfree(&receipts);
}

bool wk_font_receipt_contains(const char *path, int64_t size)
{
    pthread_once(&wk_fontReceiptsOnce, wk_readFontReceipts);
    CFStringRef key = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFSetRef sizes = CFDictionaryGetValue(wk_fontReceipts, key);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &size);
    bool found = sizes && CFSetContainsValue(sizes, number);
    CFRelease(number);
    CFRelease(key);
    return found;
}
