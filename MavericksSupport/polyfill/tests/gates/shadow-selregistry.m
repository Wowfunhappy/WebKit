// Shadow gate probe.
// What the ObjC half of the layer declares, and where each polyfill actually lands. Reads the
// __wk_selmap/__wk_addmap sections this binary carries because it force-loaded the method polyfill objects -- the same
// sections wk_selref_scope.m reads at startup, so "declared" means what the loader will see.
#include "wk_selref_scope.h"
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif

// pub, priv, intent, class, side, and the image that defines the class -- the last so the presence
// probe can load exactly what it needs to see that class, rather than guessing at a framework list.
static void emit(const struct wk_selmap_entry *entry, const char *className, const char *side)
{
    Class cls = className ? objc_getClass(className) : NULL;
    const char *image = cls ? class_getImageName(cls) : NULL;
    printf("%s\t%s\t%s\t%s\t%s\t%s\n", entry->pub, entry->priv,
           entry->intent == WK_SELMAP_REPLACES ? "REPLACES" : "GAP_FILL",
           className ? className : "-", side, image ? image : "-");
}

// The classes a category gave the private selector to. class_copyMethodList reports what the class
// defines ITSELF, which is where a category's method lands, and never an inherited one.
static int scanClass(Class where, const char *ownerName, const char *side,
                     const struct wk_selmap_entry *entries, size_t count, char *found)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(where, &n);
    if (!methods)
        return 0;
    int hits = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        for (size_t j = 0; j < count; j++) {
            if (strcmp(name, entries[j].priv))
                continue;
            emit(&entries[j], ownerName, side);
            found[j] = 1;
            hits++;
        }
    }
    free(methods);
    return hits;
}

int main(void)
{
    Dl_info info;
    if (!dladdr((void *)&main, &info) || !info.dli_fbase) {
        fprintf(stderr, "cannot locate own image\n");
        return 2;
    }
    const wk_mach_header *header = (const wk_mach_header *)info.dli_fbase;

    unsigned long size = 0;
    const struct wk_selmap_entry *entries =
        (const struct wk_selmap_entry *)getsectiondata(header, "__DATA", "__wk_selmap", &size);
    if (!entries) {
        fprintf(stderr, "no __DATA,__wk_selmap in the force-loaded method polyfills\n");
        return 2;
    }
    size_t count = size / sizeof(*entries);
    char *found = calloc(count, 1);

    // WK_POLYFILL_ADD names its class outright, and installs an INSTANCE method (class_addMethod on the
    // class itself). Taken from the section rather than from a class scan because the mechanism that
    // installs those methods is deliberately not loaded here.
    unsigned long addSize = 0;
    const struct wk_addmap_entry *added =
        (const struct wk_addmap_entry *)getsectiondata(header, "__DATA", "__wk_addmap", &addSize);
    for (size_t a = 0; added && a < addSize / sizeof(*added); a++) {
        // The raw record with the ADD's OWN intent, for the dead-gap-fill check: the selmap's intent
        // says what the rewrite means, but whether the body actually installs is decided by the ADD's
        // (class_addMethod vs class_replaceMethod -- see wk_install_add_entry).
        printf("ADDMAP\t%s\t%s\t%s\n", added[a].cls, added[a].sel,
               added[a].intent == WK_SELMAP_REPLACES ? "REPLACES" : "GAP_FILL");
        // A leading '+' on the class name marks a CLASS-method entry (WK_POLYFILL_ADD_CLASS_METHOD);
        // the presence probe must then ask the metaclass, so emit the bare name with side "class".
        for (size_t j = 0; j < count; j++)
            if (!strcmp(added[a].sel, entries[j].priv)) {
                int isClassMethod = added[a].cls[0] == '+';
                emit(&entries[j], isClassMethod ? added[a].cls + 1 : added[a].cls,
                     isClassMethod ? "class" : "instance");
                found[j] = 1;
            }
    }

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        scanClass(classes[i], name, "instance", entries, count, found);
        // A class method lives on the metaclass; it is still reported against the class's own name.
        scanClass(object_getClass(classes[i]), name, "class", entries, count, found);
    }
    free(classes);

    // A registration whose private selector exists on no class is dead: WebKit's `foo` is rewritten to
    // a `wk_foo` nothing implements. Reported with no class so the gate can say so.
    for (size_t j = 0; j < count; j++)
        if (!found[j])
            emit(&entries[j], NULL, "-");
    return 0;
}
