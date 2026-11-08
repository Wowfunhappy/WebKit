// Aliasing for categories that arrive with a dlopen'd image and attach to classes of an image swept
// earlier (here the probe itself). A category giving such a class a registered selector it lacked gets
// the private alias, and a category overriding a method the class already had moves the alias to the
// override, so the rewritten selector and the public one keep answering alike.
//
// The fixture (wk_selref_dlopen_category_fixture.m) is a bundle loaded against this executable whose
// only content is the two categories.
#include "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>

static int wk_failures;
static void check(int ok, const char *what)
{
    printf("  %-66s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        wk_failures++;
}

// Registers -selrefCategoryProbeValue; the target class never exists, so only aliasing is exercised.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "WKCategoryProbeAbsentTarget")
- (int)selrefCategoryProbeValue { return -1; }
@end

@interface WKCategoryProbePlain : NSObject
@end
@implementation WKCategoryProbePlain
@end

@interface WKCategoryProbeOverridden : NSObject
- (int)selrefCategoryProbeValue;
@end
@implementation WKCategoryProbeOverridden
- (int)selrefCategoryProbeValue { return 1; }
@end

static int sendPrivate(Class cls)
{
    SEL privateSelector = sel_registerName("wk_selrefCategoryProbeValue");
    if (!class_getInstanceMethod(cls, privateSelector))
        return 0;
    id instance = [[cls alloc] init];
    int answer = ((int (*)(id, SEL))objc_msgSend)(instance, privateSelector);
    [instance release];
    return answer;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: wk_selref_dlopen_category <fixture-bundle-path>\n");
        return 2;
    }
    printf("wk_selref_dlopen_category: aliasing for categories of a dlopen'd image\n");

    Class plain = objc_getClass("WKCategoryProbePlain");
    Class overridden = objc_getClass("WKCategoryProbeOverridden");
    check(sendPrivate(plain) == 0, "test premise: the plain class has no alias before the dlopen");
    check(sendPrivate(overridden) == 1, "test premise: the overridden class is aliased to its own method");

    void *handle = dlopen(argv[1], RTLD_NOW);
    check(handle != NULL, "dlopen fixture bundle");
    if (!handle)
        return 1;

    check(sendPrivate(plain) == 7, "a category's new method is aliased on a class swept earlier");
    check(sendPrivate(overridden) == 8, "a category's override moves the existing alias to the override");

    if (wk_failures) {
        printf("wk_selref_dlopen_category: %d FAILURE(S)\n", wk_failures);
        return 1;
    }
    printf("wk_selref_dlopen_category: all checks passed\n");
    return 0;
}
