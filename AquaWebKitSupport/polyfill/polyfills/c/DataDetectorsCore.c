// DataDetectorsCore: entry points modern WebKit calls that 10.9's DataDetectorsCore does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

#define DATA_DETECTORS_CORE_PROVIDER \
    "/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore"

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
