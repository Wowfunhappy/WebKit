// The install-timing guarantee for WK_POLYFILL_ADD: a class that arrives via dlopen — with NO
// subsequent image load — has its deferred entries installed by the time that dlopen returns.
//
// This is the DDActionsManager shape: PAL's soft-link dlopens DataDetectors and sends the rewritten
// selector in the same call stack. Inside the add-image callback the ObjC runtime cannot yet see the
// arriving image's classes (objc_getClass returns nil there — measured, see wk_selref_scope.m), so
// wk_install_added's retry from that callback resolves nothing for the new image; the drain in the
// dyld state-45 handler (wk_image_initializing) is what makes the guarantee hold.
//
// The probe target is a purpose-built fixture dylib (wk_selref_dlopen_fixture.m) whose only
// dependencies are libobjc/libSystem, so its dlopen is a genuinely single-image batch. That shape is
// the regression guard: against the pre-drain mechanism it FAILS "deferred instance ADD installed by
// dlopen return" (verified by compiling this test against the drainless wk_image_initializing),
// while a system framework such as AddressBook is useless here — its dlopen cascades further image
// loads whose add-image events rescue the old retry path, so every check passes vacuously.
#include "wk_selref_scope.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

static int wk_failures;
static void check(int ok, const char *what)
{
    printf("  %-58s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        wk_failures++;
}

static int wk_dlopenTestPing(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
    return 42;
}
static int wk_dlopenTestClassPing(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
    return 43;
}
WK_POLYFILL_ADD("WKDrainProbeFixture", "wk_selrefDlopenTestPing", wk_dlopenTestPing, "i@:");
WK_POLYFILL_ADD_CLASS_METHOD("WKDrainProbeFixture", "wk_selrefDlopenTestClassPing", wk_dlopenTestClassPing, "i@:");

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: wk_selref_dlopen <fixture-dylib-path>\n");
        return 2;
    }
    printf("wk_selref_dlopen: WK_POLYFILL_ADD install timing across dlopen\n");

    // If the fixture class were somehow already present, the entries would install in the
    // constructor's sweep and the test would assert nothing about the dlopen path — fail loudly
    // instead of passing vacuously.
    check(objc_getClass("WKDrainProbeFixture") == NULL, "test premise: fixture class not loaded at launch");

    void *handle = dlopen(argv[1], RTLD_LAZY);
    check(handle != NULL, "dlopen fixture dylib");
    if (!handle)
        return 1;

    // From here on, NO further image load happens before the assertions — that is the point.
    Class fixture = objc_getClass("WKDrainProbeFixture");
    check(fixture != NULL, "fixture class visible after dlopen");
    if (!fixture)
        return 1;

    Method m = class_getInstanceMethod(fixture, sel_registerName("wk_selrefDlopenTestPing"));
    check(m != NULL, "deferred instance ADD installed by dlopen return");
    check(m && method_getImplementation(m) == (IMP)wk_dlopenTestPing,
          "installed IMP is the polyfill body");

    Method cm = class_getClassMethod(fixture, sel_registerName("wk_selrefDlopenTestClassPing"));
    check(cm != NULL, "deferred CLASS-method ADD installed on the metaclass");
    if (cm) {
        int answer = ((int (*)(id, SEL))objc_msgSend)((id)fixture,
                                                      sel_registerName("wk_selrefDlopenTestClassPing"));
        check(answer == 43, "class-object send reaches the polyfill body");
    }

    if (wk_failures) {
        printf("wk_selref_dlopen: %d FAILURE(S)\n", wk_failures);
        return 1;
    }
    printf("wk_selref_dlopen: all checks passed\n");
    return 0;
}
