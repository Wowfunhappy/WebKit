// DataDetectorsCore: modern result types and categories on 10.9.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

#define DATA_DETECTORS_CORE_PROVIDER \
    "/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore"

WK_POLYFILL_CONST(DATA_DETECTORS_CORE_PROVIDER, CFStringRef, DDBinderParsecSourceKey, CFSTR("Parsec"));

WK_SYSTEM_FN(DATA_DETECTORS_CORE_PROVIDER, CFStringRef, DDResultGetType, (CFTypeRef));
WK_SYSTEM_CONST(DATA_DETECTORS_CORE_PROVIDER, CFStringRef, DDBinderMoneyKey);

// 10.9's scanner emits Money results with category Unknown; the modern category is 6.
WK_POLYFILL_REPLACES(DATA_DETECTORS_CORE_PROVIDER, int, DDResultGetCategory, (CFTypeRef result))
{
    enum { unknownCategory = 0, moneyCategory = 6 };
    int category = WK_ORIGINAL(DDResultGetCategory)(result);
    if (category != unknownCategory || !result)
        return category;
    if (CFEqual(WK_SYSTEM(DDResultGetType)(result), WK_SYSTEM(DDBinderMoneyKey)))
        return moneyCategory;
    return category;
}

// WTF::CFTypeTrait<DDResultRef>::typeID() (WebCore/editing/cocoa/DataDetection.mm) is this function, so
// it is what every checked_cf_cast<DDResultRef> on a scanner result compares against. 10.9 has the
// DDResult CF type and exports DDResultCreateEmpty, so the real id is obtainable: mint one result and
// read its CFGetTypeID. Measured on this host that is 256, CFCopyTypeIDDescription "DDResult", and
// stable across calls.
WK_SYSTEM_FN(DATA_DETECTORS_CORE_PROVIDER, CFTypeRef, DDResultCreateEmpty, (void));

WK_POLYFILL_ABSENT(DATA_DETECTORS_CORE_PROVIDER, CFTypeID, DDResultGetCFTypeID, (void))
{
    static CFTypeID typeID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFTypeRef empty = WK_SYSTEM(DDResultCreateEmpty)();
        if (!empty)
            return;
        typeID = CFGetTypeID(empty);
        CFRelease(empty);
    });
    return typeID;
}
