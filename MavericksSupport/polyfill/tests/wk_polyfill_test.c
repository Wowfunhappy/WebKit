/* Exercises wk_polyfill.h + wk_polyfill_runtime.c against the real 10.9 runtime. Run by
 * build-polyfill.sh; a failure here means the layer's core promise is broken.
 *
 * The promise: a polyfill may be declared without knowing whether 10.9 has the symbol. So every
 * case is covered twice, once on each side of the present/absent line, using real system symbols
 * rather than mocks -- CFNullGetTypeID/kCFRunLoopDefaultMode exist on 10.9, CGColorSpaceGetName
 * (10.12+) and kCGColorSpaceExtendedRange (10.12+) do not.
 *
 * kCFRunLoopDefaultMode is deliberately declared with a WRONG token value: it stands in for the
 * bug class that used to require a build-time shadow gate (a name-string copy silently replacing a
 * key the system actually interprets, as happened to the EXIF and proxy-stream keys). The mirror
 * step must overwrite it with CoreFoundation's real value.
 */
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

void wk_polyfill_report_for_testing(void);

/* --- gap-fill for a function 10.9 HAS: must forward, our body must not run ---------------- */
WK_POLYFILL_ABSENT("CoreFoundation", CFTypeID, CFNullGetTypeID, (void), ())
{
    return (CFTypeID)0xBEEF;
}

/* --- gap-fill for a function 10.9 LACKS (CGColorSpaceGetName is 10.12+): our body runs ----- */
extern CFStringRef CGColorSpaceCopyName(CGColorSpaceRef);
WK_POLYFILL_ABSENT("CoreGraphics", CFStringRef, CGColorSpaceGetName, (CGColorSpaceRef space), (space))
{
    CFStringRef name = CGColorSpaceCopyName(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

/* --- deliberate replacement of a function 10.9 HAS: body always runs, original reachable --- */
WK_POLYFILL_REPLACES("CoreFoundation", CFTypeID, CFDataGetTypeID, (void))
{
    CFTypeID original = WK_ORIGINAL(CFDataGetTypeID) ? WK_ORIGINAL(CFDataGetTypeID)() : 0;
    return original + 1000;
}

/* --- gap-fill constants, one 10.9 HAS and one it LACKS ------------------------------------ */
WK_POLYFILL_CONST("CoreFoundation", CFStringRef, kCFRunLoopDefaultMode, CFSTR("WRONG-token-value"));
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

    CHECK("present function forwards to 10.9", CFNullGetTypeID() != (CFTypeID)0xBEEF);
    CHECK("absent function uses the polyfill", CGColorSpaceGetName(srgb) != NULL);
    CHECK("replacement always wins", CFDataGetTypeID() >= 1000);
    /* NB: dlsym cannot supply ground truth here -- the shim is registry-first by design, so it
     * hands back the polyfill for a registered name, exactly as the link-time reference does. */
    CHECK("replacement reaches the original",
          WK_ORIGINAL(CFDataGetTypeID) != NULL
              && (void *)WK_ORIGINAL(CFDataGetTypeID) != (void *)&CFDataGetTypeID
              && CFDataGetTypeID() > 1000);

    /* the bug class this exists to kill: a token-valued gap-fill must not shadow a real key */
    CHECK("present constant mirrors 10.9's value",
          CFEqual(*(CFStringRef volatile *)&kCFRunLoopDefaultMode, CFSTR("kCFRunLoopDefaultMode")));
    CHECK("absent constant keeps ours",
          CFEqual(*(CFStringRef volatile *)&kCGColorSpaceExtendedRange, CFSTR("kCGColorSpaceExtendedRange")));

    /* soft-linking path: dlsym on a framework handle must see the polyfill */
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    CHECK("dlsym(handle) finds a polyfill", dlsym(cg, "kCGColorSpaceExtendedRange") != NULL);
    CHECK("dlsym passes non-polyfills through", dlsym(cg, "CGColorSpaceCreateDeviceRGB") != NULL);
    CHECK("dlsym still reports genuine misses", dlsym(cg, "CGNoSuchSymbolAtAll") == NULL);

    /* ...but only where a real dlsym could have answered. A handle that does not export the name and
     * has no relation to the polyfill's provider must miss, exactly as it would without this layer;
     * answering it would make the shim correct only by accident of who happens to call it. */
    void *libz = dlopen("/usr/lib/libz.dylib", RTLD_LAZY);
    CHECK("dlsym on an unrelated handle declines",
          libz != NULL && dlsym(libz, "kCGColorSpaceExtendedRange") == NULL
              && dlsym(libz, "CGColorSpaceGetName") == NULL);

    /* RTLD_NEXT/RTLD_SELF ask about link ORDER relative to the caller, not about a library. This
     * layer cannot answer that and must not pretend to. (RTLD_NEXT from inside the shim means "after
     * the main executable", where nothing on 10.9 defines these.) */
    CHECK("dlsym declines RTLD_NEXT", dlsym(RTLD_NEXT, "kCGColorSpaceExtendedRange") == NULL);

    /* A process-wide search is the scope a link-time reference resolves in, so a polyfilled name
     * 10.9 lacks belongs there. */
    CHECK("dlsym(RTLD_DEFAULT) finds a polyfill",
          dlsym(RTLD_DEFAULT, "kCGColorSpaceExtendedRange")
              == (void *)&kCGColorSpaceExtendedRange);

    /* And where 10.9 DOES export the name, 10.9's definition is the answer -- the same one the
     * link-time reference ends up using, since the gap-fill forwards to it (functions) or is
     * overwritten by it (constants). Ours must not shadow it just because it is in the registry. */
    void *cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    CHECK("dlsym prefers 10.9's export over ours",
          dlsym(cf, "kCFRunLoopDefaultMode") != NULL
              && dlsym(cf, "kCFRunLoopDefaultMode") != (void *)&kCFRunLoopDefaultMode
              && dlsym(cf, "CFNullGetTypeID") != (void *)&CFNullGetTypeID);

    /* The exception is a deliberate replacement, whose premise is that 10.9's version exists and is
     * wrong. Deferring there would resolve one name two ways: ours when linked, 10.9's when
     * soft-linked. */
    CHECK("dlsym keeps a replacement winning",
          dlsym(cf, "CFDataGetTypeID") == (void *)&CFDataGetTypeID);

    /* A second image with its own copy of the same polyfill must not be mistaken for 10.9 having the
     * symbol -- in a real process every framework carries a copy, and if each defers to another's
     * the polyfill never runs. */
    void *sibling = dlopen(getenv("WK_POLYFILL_SIBLING"), RTLD_LAZY);
    int (*siblingThinksPresent)(void) = sibling
        ? (int (*)(void))dlsym(sibling, "wk_sibling_thinks_symbol_is_present") : NULL;
    CHECK("sibling image loaded", siblingThinksPresent != NULL);
    CHECK("a sibling's copy is not mistaken for 10.9",
          siblingThinksPresent && !siblingThinksPresent()
              && WK_ORIGINAL(CGColorSpaceGetName) == NULL);
    CHECK("polyfill still runs with a sibling loaded", CGColorSpaceGetName(srgb) != NULL);

    /* A diagnostic must not change behaviour. report() used to mark constants resolved without
     * mirroring them, so with WK_POLYFILL_REPORT set every gap-fill constant kept its placeholder
     * for the life of the process -- the exact shadowing this layer exists to prevent, and it is
     * forwarded to every XPC child. Re-check the mirrored value after forcing a report. */
    setenv("WK_POLYFILL_REPORT", "1", 1);
    {
        void *quiet = freopen("/dev/null", "w", stderr);
        (void)quiet;
    }
    wk_polyfill_report_for_testing();
    CHECK("reporting does not defeat constant mirroring",
          CFEqual(*(CFStringRef volatile *)&kCFRunLoopDefaultMode, CFSTR("kCFRunLoopDefaultMode")));

    if (failures) {
        fprintf(stderr, "  %d polyfill mechanism check(s) FAILED"
                        " (kCFRunLoopDefaultMode resolved to \"%s\")\n",
                failures, utf8(*(CFStringRef volatile *)&kCFRunLoopDefaultMode));
        return 1;
    }
    return 0;
}
