/* Exercises wk_polyfill.h + wk_polyfill_runtime.c against the real 10.9 runtime. Run by
 * build-polyfill.sh; a failure here means the layer's core promise is broken.
 *
 * The promise: a polyfill's body runs unconditionally -- the runtime does what you declared, with no
 * forwarding to 10.9 and no value-mirroring. A polyfill written for a symbol 10.9 actually has would
 * therefore shadow it; that is a mistake the build gate (the shadow gate in build-polyfill.sh) rejects. This test
 * deliberately declares two gap-fills over PRESENT symbols (CFNullGetTypeID, kCFRunLoopDefaultMode) --
 * something real code must not do -- purely to prove the body/value wins, i.e. that nothing forwards or
 * mirrors behind your back. Real system symbols throughout, not mocks: CFNullGetTypeID and
 * kCFRunLoopDefaultMode exist on 10.9; CGColorSpaceGetName (10.12+) and kCGColorSpaceExtendedRange
 * (10.12+) do not.
 */
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

void wk_polyfill_report_for_testing(void);

/* --- gap-fill for a function 10.9 LACKS (CGColorSpaceGetName is 10.12+): our body runs ----- */
extern CFStringRef CGColorSpaceCopyName(CGColorSpaceRef);
WK_POLYFILL_ABSENT("CoreGraphics", CFStringRef, CGColorSpaceGetName, (CGColorSpaceRef space))
{
    CFStringRef name = CGColorSpaceCopyName(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

/* --- gap-fill body runs even where 10.9 HAS the function: proves nothing forwards to 10.9.
 * A gap-fill over a present symbol is the mistake the gate rejects in real code; here it shows the
 * body -- not 10.9's CFNullGetTypeID -- is what runs. --------------------------------------- */
WK_POLYFILL_ABSENT("CoreFoundation", CFTypeID, CFNullGetTypeID, (void))
{
    return (CFTypeID)0xBEEF;
}

/* --- deliberate replacement of a function 10.9 HAS: body always runs, original reachable --- */
WK_POLYFILL_REPLACES("CoreFoundation", CFTypeID, CFDataGetTypeID, (void))
{
    CFTypeID original = WK_ORIGINAL(CFDataGetTypeID) ? WK_ORIGINAL(CFDataGetTypeID)() : 0;
    return original + 1000;
}

/* --- gap-fill constants: the declared value IS the value, no mirroring. kCFRunLoopDefaultMode (10.9
 * HAS it) carries a DISTINCT token to prove 10.9's value is not copied over ours. ------------ */
WK_POLYFILL_CONST("CoreFoundation", CFStringRef, kCFRunLoopDefaultMode, CFSTR("wk-distinct-token"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRange, CFSTR("kCGColorSpaceExtendedRange"));

static const char *utf8(CFStringRef s)
{
    static char buffer[128];
    return CFStringGetCString(s, buffer, sizeof buffer, kCFStringEncodingUTF8) ? buffer : "?";
}

static int failures;
#define CHECK(label, cond)                                        \
    do {                                                          \
        int passed = (cond) ? 1 : 0;                              \
        if (!passed)                                              \
            failures++;                                           \
        printf("  %-42s %s\n", label, passed ? "ok" : "FAIL");    \
    } while (0)

int main(void)
{
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    CHECK("absent function uses the polyfill", CGColorSpaceGetName(srgb) != NULL);
    CHECK("gap-fill body runs, no forward to 10.9", CFNullGetTypeID() == (CFTypeID)0xBEEF);
    CHECK("replacement always wins", CFDataGetTypeID() >= 1000);
    /* NB: dlsym cannot supply ground truth here -- the shim is registry-first by design, so it
     * hands back the polyfill for a registered name, exactly as the link-time reference does. */
    CHECK("replacement reaches the original",
          WK_ORIGINAL(CFDataGetTypeID) != NULL
              && (void *)WK_ORIGINAL(CFDataGetTypeID) != (void *)&CFDataGetTypeID
              && CFDataGetTypeID() > 1000);

    /* no mirroring: a gap-fill constant keeps its declared value, even where 10.9 exports the name */
    CHECK("constant keeps our value, not 10.9's",
          CFEqual(*(CFStringRef volatile *)&kCFRunLoopDefaultMode, CFSTR("wk-distinct-token")));
    CHECK("absent constant keeps ours",
          CFEqual(*(CFStringRef volatile *)&kCGColorSpaceExtendedRange, CFSTR("kCGColorSpaceExtendedRange")));

    /* soft-linking path: dlsym on a framework handle must see the polyfill */
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    CHECK("dlsym(handle) finds a polyfill", dlsym(cg, "kCGColorSpaceExtendedRange") != NULL);
    CHECK("dlsym passes non-polyfills through", dlsym(cg, "CGColorSpaceCreateDeviceRGB") != NULL);
    CHECK("dlsym still reports genuine misses", dlsym(cg, "CGNoSuchSymbolAtAll") == NULL);

    /* ...but only where a real dlsym could have answered. A handle that does not export the name and
     * has no relation to the polyfill's provider must miss, exactly as it would without this layer. */
    void *libz = dlopen("/usr/lib/libz.dylib", RTLD_LAZY);
    CHECK("dlsym on an unrelated handle declines",
          libz != NULL && dlsym(libz, "kCGColorSpaceExtendedRange") == NULL
              && dlsym(libz, "CGColorSpaceGetName") == NULL);

    /* RTLD_NEXT/RTLD_SELF ask about link ORDER relative to the caller, not about a library. This
     * layer cannot answer that and must not pretend to. */
    CHECK("dlsym declines RTLD_NEXT", dlsym(RTLD_NEXT, "kCGColorSpaceExtendedRange") == NULL);

    /* A process-wide search is the scope a link-time reference resolves in, so a polyfilled name
     * belongs there. */
    CHECK("dlsym(RTLD_DEFAULT) finds a polyfill",
          dlsym(RTLD_DEFAULT, "kCGColorSpaceExtendedRange")
              == (void *)&kCGColorSpaceExtendedRange);

    /* A registered name resolves to OURS -- the same definition the link-time reference binds under
     * force_load -- whether or not 10.9 also exports it, and for both gap-fill and replacement. There
     * is no runtime deferral to 10.9, so soft-linking and link-time can never disagree. */
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    CHECK("dlsym resolves a registered gap-fill to ours",
          dlsym(cf, "kCFRunLoopDefaultMode") == (void *)&kCFRunLoopDefaultMode
              && dlsym(cf, "CFNullGetTypeID") == (void *)&CFNullGetTypeID);
    CHECK("dlsym keeps a replacement resolving to ours",
          dlsym(cf, "CFDataGetTypeID") == (void *)&CFDataGetTypeID);

    /* A second image with its own copy of the same polyfill must not be mistaken for 10.9 having the
     * symbol: WK_ORIGINAL for a genuinely absent symbol stays NULL (resolveOriginal's addressIsOurs
     * guard), so a REPLACES that calls through never lands in a sibling's copy of itself. */
    void *sibling = dlopen(getenv("WK_POLYFILL_SIBLING"), RTLD_LAZY);
    int (*siblingThinksPresent)(void) = sibling
        ? (int (*)(void))dlsym(sibling, "wk_sibling_thinks_symbol_is_present") : NULL;
    CHECK("sibling image loaded", siblingThinksPresent != NULL);
    CHECK("a sibling's copy is not mistaken for 10.9",
          siblingThinksPresent && !siblingThinksPresent()
              && WK_ORIGINAL(CGColorSpaceGetName) == NULL);
    CHECK("polyfill still runs with a sibling loaded", CGColorSpaceGetName(srgb) != NULL);

    /* A diagnostic must not change behaviour: report() reads presence but must leave every value
     * exactly as declared. */
    setenv("WK_POLYFILL_REPORT", "1", 1);
    {
        void *quiet = freopen("/dev/null", "w", stderr);
        (void)quiet;
    }
    wk_polyfill_report_for_testing();
    CHECK("reporting leaves a constant untouched",
          CFEqual(*(CFStringRef volatile *)&kCFRunLoopDefaultMode, CFSTR("wk-distinct-token")));

    if (failures) {
        fprintf(stderr, "  %d polyfill mechanism check(s) FAILED"
                        " (kCFRunLoopDefaultMode resolved to \"%s\")\n",
                failures, utf8(*(CFStringRef volatile *)&kCFRunLoopDefaultMode));
        return 1;
    }
    return 0;
}
