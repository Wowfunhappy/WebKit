// DataDetectorsCore: entry points modern WebKit calls that 10.9's DataDetectorsCore does not export,
// or exports with behaviour that has to be replaced.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------------------------------
// DataDetectorsCore — 10.9 has the DDResult CF type, just no accessor for its type id; and it can build
// a scanner but not the phone-number DFA the telephone-number detector asks for.
// ---------------------------------------------------------------------------------------------------

#define MAV_DATA_DETECTORS_CORE \
    "/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore"

// WTF::CFTypeTrait<DDResultRef>::typeID() (WebCore/editing/cocoa/DataDetection.mm) is this function, so
// it is what every checked_cf_cast<DDResultRef> on a scanner result compares against. 10.9's
// DataDetectorsCore exports DDResultCreateEmpty, so the real id is obtainable: mint one result and read
// its CFGetTypeID. Measured on this host that is 256, CFCopyTypeIDDescription "DDResult", and stable
// across calls. Reporting a sentinel instead made every cast fail and the whole feature look empty.
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDResultCreateEmpty, (void));

WK_POLYFILL_ABSENT(MAV_DATA_DETECTORS_CORE, CFTypeID, DDResultGetCFTypeID, (void))
{
    static CFTypeID typeID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!WK_SYSTEM(DDResultCreateEmpty))
            return;
        CFTypeRef empty = WK_SYSTEM(DDResultCreateEmpty)();
        if (!empty)
            return;
        typeID = CFGetTypeID(empty);
        CFRelease(empty);
    });
    return typeID;
}

// The phone-number DFA scanner, the three entry points WebCore/platform/cocoa/TelephoneNumberDetectorCocoa.cpp
// is written against: DDDFACacheCreateFromFramework() loads a phone-number DFA out of DataDetectorsCore's
// own bundle, DDDFAScannerCreateFromCache() wraps it in a scanner, and DDDFAScannerFirstResultInUnicharArray()
// reports the first phone number in a UTF-16 buffer. TelephoneNumberDetector::isSupported() is "did the
// cache load", and on this platform it gates Editor::scanSelectionForTelephoneNumbers, which marks the
// phone numbers in a selection (the parser's tel:-link creation, the other caller, is iOS-only);
// ProcessWarming::prewarmGlobally builds the scanner in every WebContent process.
//
// 10.9's DataDetectorsCore (354.5) builds that cache from a CFPlugIn bundle — PlugIns/PhoneNumbers.plugin
// inside its own framework — which this OS does not ship: there is no PlugIns directory, and the
// framework's code signature lists Resources/ only, so it never shipped one. DDDFACacheCreateFromFramework
// therefore CANNOT succeed here. It CFBundleCreates the missing plugin, logs
//   Could not load the plugin PlugIns/PhoneNumbers.plugin/ -- file:///System/.../DataDetectorsCore.framework/
// once per WebContent launch, and returns NULL — leaving phone-number detection off altogether.
//
// Only that one packaging of the capability is missing. The scanner API is complete and works: a plain
// DDScannerCreate(DDScannerTypeStandard) built from the DFA caches in the framework's Resources returns
// PhoneNumber results with correct UTF-16 ranges (measured on this host: "415-555-1234", "(212) 555-0199",
// "+1 (800) 275-2273", "1-800-FLOWERS" are all found, in text that also holds URLs, dates and addresses).
// So the DFA trio is re-implemented on top of it, keeping the contract WebKit expects: a cache handle that
// is non-NULL exactly when detection works, and a first-match-in-buffer query in buffer-relative offsets.
// Results are stricter than a raw DFA's, since a full scan validates and binds what it matches — a
// telephone-number marker over a real phone number is what the caller wants.
//
// A scanner is not documented as thread-safe and this one is a process-wide singleton (WebKit builds it
// under call_once and calls find() from wherever a selection or a parse happens), so scans are serialised.

WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDScannerCreate, (CFIndex type, CFIndex options, CFErrorRef *error));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, void, DDScannerReset, (CFTypeRef scanner));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeRef, DDScanQueryCreateFromString, (CFAllocatorRef allocator, CFStringRef string, CFRange range));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, Boolean, DDScannerScanQuery, (CFTypeRef scanner, CFTypeRef query));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFArrayRef, DDScannerCopyResultsWithOptions, (CFTypeRef scanner, CFIndex options));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFStringRef, DDResultGetType, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFRange, DDResultGetRange, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFArrayRef, DDResultGetSubResults, (CFTypeRef result));
WK_SYSTEM_FN(MAV_DATA_DETECTORS_CORE, CFTypeID, DDDFAScannerGetCFTypeID, (void));

// The cache handle WebKit adopts and hands back to DDDFAScannerCreateFromCache. There is no DFA to
// carry — the scanner below holds all the state — so it is an identity, not a structure: a constant
// CFString, which retains and releases like the CF object WebKit's RetainPtr expects.
static CFTypeRef mav_phoneNumberCacheSentinel(void)
{
    return CFSTR("com.apple.WebKit.mavericks.PhoneNumberDFACache");
}

// A DDC phone-number result always covers ASCII digits: on this host CALL-NOW, ONE-EIGHT-HUNDRED-FLOWERS
// and ABC-DEFG produce nothing, while 1-800-FLOWERS is found through its "1" and "800". Any non-ASCII
// character ends the question rather than answering it, so other digit forms are never assumed away.
static bool mav_mayHoldPhoneNumber(const UniChar *characters, unsigned length)
{
    for (unsigned i = 0; i < length; i++) {
        if (characters[i] > 0x7F || (characters[i] >= '0' && characters[i] <= '9'))
            return true;
    }
    return false;
}

// The earliest-starting phone number in a result tree. A phone number can arrive as a result in its own
// right or as a sub-result of a larger one (a contact block, say), and the DFA this stands in for would
// have matched it either way. The depth cap is a guard on recursion, not a property of the data.
static void mav_notePhoneNumber(CFTypeRef result, CFRange *earliest, unsigned depth)
{
    if (!result)
        return;

    CFStringRef type = WK_SYSTEM(DDResultGetType)(result);
    if (type && CFEqual(type, CFSTR("PhoneNumber"))) {
        CFRange range = WK_SYSTEM(DDResultGetRange)(result);
        if (range.length > 0 && (earliest->location == kCFNotFound || range.location < earliest->location))
            *earliest = range;
        return;
    }

    if (depth >= 4 || !WK_SYSTEM(DDResultGetSubResults))
        return;
    CFArrayRef subResults = WK_SYSTEM(DDResultGetSubResults)(result);
    for (CFIndex i = 0, count = subResults ? CFArrayGetCount(subResults) : 0; i < count; i++)
        mav_notePhoneNumber(CFArrayGetValueAtIndex(subResults, i), earliest, depth + 1);
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, void *, DDDFACacheCreateFromFramework, (void))
{
    // Non-NULL is what makes TelephoneNumberDetector::isSupported() true, so it is claimed only when the
    // scanner API this is implemented on is actually reachable.
    if (!WK_SYSTEM(DDScannerCreate) || !WK_SYSTEM(DDScanQueryCreateFromString) || !WK_SYSTEM(DDScannerScanQuery)
        || !WK_SYSTEM(DDScannerCopyResultsWithOptions) || !WK_SYSTEM(DDResultGetType) || !WK_SYSTEM(DDResultGetRange))
        return NULL;
    return (void *)CFRetain(mav_phoneNumberCacheSentinel());
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, void *, DDDFAScannerCreateFromCache, (void *cache))
{
    if ((CFTypeRef)cache != mav_phoneNumberCacheSentinel())
        return WK_ORIGINAL(DDDFAScannerCreateFromCache) ? WK_ORIGINAL(DDDFAScannerCreateFromCache)(cache) : NULL;
    return (void *)WK_SYSTEM(DDScannerCreate)(0 /* DDScannerTypeStandard */, 0, NULL);
}

WK_POLYFILL_REPLACES(MAV_DATA_DETECTORS_CORE, Boolean, DDDFAScannerFirstResultInUnicharArray,
                     (void *scanner, const UniChar *characters, unsigned length, int *startPosition, int *endPosition))
{
    if (!scanner || !characters || !length || !startPosition || !endPosition)
        return false;

    // A real DFA scanner — one this process got from DataDetectorsCore rather than from the polyfill
    // above — is answered by DataDetectorsCore.
    if (WK_SYSTEM(DDDFAScannerGetCFTypeID) && CFGetTypeID((CFTypeRef)scanner) == WK_SYSTEM(DDDFAScannerGetCFTypeID)())
        return WK_ORIGINAL(DDDFAScannerFirstResultInUnicharArray)
            ? WK_ORIGINAL(DDDFAScannerFirstResultInUnicharArray)(scanner, characters, length, startPosition, endPosition)
            : false;

    // The scanner came from the polyfill above, which builds one only when all of these resolve; the
    // check is here so that this never becomes an indirect call through NULL.
    if (!WK_SYSTEM(DDScanQueryCreateFromString) || !WK_SYSTEM(DDScannerScanQuery) || !WK_SYSTEM(DDScannerCopyResultsWithOptions)
        || !WK_SYSTEM(DDResultGetType) || !WK_SYSTEM(DDResultGetRange))
        return false;

    if (!mav_mayHoldPhoneNumber(characters, length))
        return false;

    // The caller's buffer outlives this call and nothing here keeps the string, so the characters are
    // scanned in place rather than copied — Editor hands over a whole selection.
    CFStringRef text = CFStringCreateWithCharactersNoCopy(kCFAllocatorDefault, characters, length, kCFAllocatorNull);
    if (!text)
        return false;

    CFRange earliest = { kCFNotFound, 0 };
    static pthread_mutex_t scanLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&scanLock);

    if (WK_SYSTEM(DDScannerReset))
        WK_SYSTEM(DDScannerReset)((CFTypeRef)scanner);

    CFTypeRef query = WK_SYSTEM(DDScanQueryCreateFromString)(kCFAllocatorDefault, text, CFRangeMake(0, length));
    if (query) {
        if (WK_SYSTEM(DDScannerScanQuery)((CFTypeRef)scanner, query)) {
            CFArrayRef results = WK_SYSTEM(DDScannerCopyResultsWithOptions)((CFTypeRef)scanner, 1 /* DDScannerCopyResultsOptionsNoOverlap */);
            for (CFIndex i = 0, count = results ? CFArrayGetCount(results) : 0; i < count; i++)
                mav_notePhoneNumber(CFArrayGetValueAtIndex(results, i), &earliest, 0);
            if (results)
                CFRelease(results);
        }
        CFRelease(query);
    }

    pthread_mutex_unlock(&scanLock);
    CFRelease(text);

    if (earliest.location == kCFNotFound)
        return false;
    *startPosition = (int)earliest.location;
    *endPosition = (int)(earliest.location + earliest.length);
    return true;
}
