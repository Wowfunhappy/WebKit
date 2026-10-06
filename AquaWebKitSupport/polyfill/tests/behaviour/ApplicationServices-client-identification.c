// The AX client-identification override is one value per process. libpolyfill.a is force-loaded into
// every WebKit image, so the setter WebKitTestRunner's injected bundle calls and the getter WebCore's
// AXObjectCache::clientIsInTestMode calls are different copies of the archive's two functions; the
// probe builds that topology -- two dylibs, each carrying its own copy, one exporting the set and the
// other the get -- and checks the value set through one is what the other answers.
//
// Built three ways by build-polyfill.sh: -DWK_PROBE_SIDE_A and -DWK_PROBE_SIDE_B each make a dylib
// wrapping one of the two entry points, and the plain build is the program that loads both.
#include <dlfcn.h>
#include <stdio.h>

#if defined(WK_PROBE_SIDE_A)
extern void _AXSetClientIdentificationOverride(int clientType);
__attribute__((visibility("default"))) void wk_probe_set(int clientType)
{
    _AXSetClientIdentificationOverride(clientType);
}
#elif defined(WK_PROBE_SIDE_B)
extern int _AXGetClientForCurrentRequestUntrusted(void);
__attribute__((visibility("default"))) int wk_probe_get(void)
{
    return _AXGetClientForCurrentRequestUntrusted();
}
#else
static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <side-a.dylib> <side-b.dylib>\n", argv[0]);
        return 2;
    }
    void *sideA = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void *sideB = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    check(sideA && sideB, "both images load");
    void (*set)(int) = sideA ? dlsym(sideA, "wk_probe_set") : NULL;
    int (*get)(void) = sideB ? dlsym(sideB, "wk_probe_get") : NULL;
    check(set && get, "each image exports its wrapper");
    if (!set || !get)
        return 1;

    check(get() == 0, "no override reads kAXClientTypeNoActiveRequestFound");
    set(999999); // kAXClientTypeWebKitTesting
    check(get() == 999999, "the override set in one image is what the other answers");
    set(7); // kAXClientTypeVoiceOver
    check(get() == 7, "a later override replaces the earlier one");
    set(0);
    check(get() == 0, "kAXClientTypeNoActiveRequestFound clears the override");

    return failures ? 1 : 0;
}
#endif
