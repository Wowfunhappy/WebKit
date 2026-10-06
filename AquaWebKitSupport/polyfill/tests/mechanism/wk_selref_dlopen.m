// The install-timing guarantee for a block naming a class by string: a class that arrives via dlopen —
// with NO subsequent image load — has its bodies installed by the time that dlopen returns.
//
// This is the DDActionsManager shape: PAL's soft-link dlopens DataDetectors and sends the rewritten
// selector in the same call stack. Inside the add-image callback the ObjC runtime cannot yet see the
// arriving image's classes (objc_getClass returns nil there — measured, see wk_selref_scope.m), so
// the deferred retry from that callback resolves nothing for the new image; the drain in the dyld
// state-45 handler (wk_image_initializing) is what makes the guarantee hold.
//
// The probe target is a purpose-built fixture dylib (wk_selref_dlopen_fixture.m) whose only
// dependencies are libobjc/libSystem, so its dlopen is a genuinely single-image batch. That shape is
// the regression guard: against a drainless mechanism it FAILS "deferred instance body installed by
// dlopen return", while a system framework such as AddressBook is useless here — its dlopen cascades
// further image loads whose add-image events rescue the old retry path, so every check passes
// vacuously.
#include "wk_selref_scope.h"
#import <Foundation/Foundation.h>
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

WK_POLYFILL_ADD_METHODS_ON(NSObject, "WKDrainProbeFixture")
- (int)selrefDlopenTestPing { return 42; }
+ (int)selrefDlopenTestClassPing { return 43; }
@end

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: wk_selref_dlopen <fixture-dylib-path>\n");
        return 2;
    }
    printf("wk_selref_dlopen: block install timing across dlopen\n");

    // If the fixture class were somehow already present, the block would install in the
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

    SEL ping = sel_registerName("wk_selrefDlopenTestPing");
    Method m = class_getInstanceMethod(fixture, ping);
    check(m != NULL, "deferred instance body installed by dlopen return");
    check(class_getInstanceMethod(fixture, sel_registerName("selrefDlopenTestPing")) == NULL,
          "public selector stays absent on the class");
    if (m) {
        id instance = [[fixture alloc] init];
        int answer = ((int (*)(id, SEL))objc_msgSend)(instance, ping);
        check(answer == 42, "instance send reaches the polyfill body");
        [instance release];
    }

    SEL classPing = sel_registerName("wk_selrefDlopenTestClassPing");
    Method cm = class_getClassMethod(fixture, classPing);
    check(cm != NULL, "deferred CLASS-method body installed on the metaclass");
    if (cm) {
        int answer = ((int (*)(id, SEL))objc_msgSend)((id)fixture, classPing);
        check(answer == 43, "class-object send reaches the polyfill body");
    }

    if (wk_failures) {
        printf("wk_selref_dlopen: %d FAILURE(S)\n", wk_failures);
        return 1;
    }
    printf("wk_selref_dlopen: all checks passed\n");
    return 0;
}
