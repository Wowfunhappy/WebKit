// Shadow gate probe.
// What the ObjC half of the layer declares, and where each polyfill lands. Reads the __wk_methods
// section this binary carries because it force-loaded the method polyfill objects -- the same section
// wk_selref_scope.m reads at startup, so "declared" means what the loader will see -- and enumerates
// each block's methods through the runtime, so a body counts exactly when the loader would install it.
//
// One row per (method, target):  pub  priv  intent  class  side  image  block
// The image is the one defining the class, so the presence probe can load exactly what it needs to see
// that class rather than guessing at a framework list; "-" when this process cannot load the class.
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

// Every REPLACE (selector, side, class) seen, for the chain-ambiguity check: WK_ORIGINAL_METHOD takes
// the first REPLACE body up the receiver's chain as the running one, which needs there to be one per
// chain. Reported as "AMBIGUOUS pub side classA classB" for the classes this process can load.
struct replaced { const char *pub; const char *side; Class cls; const char *name; };
static struct replaced replaced[1024];
static int replacedCount;

static int inherits(Class sub, Class super)
{
    for (Class c = class_getSuperclass(sub); c; c = class_getSuperclass(c))
        if (c == super)
            return 1;
    return 0;
}

static void noteReplaced(const char *pub, const char *side, Class cls, const char *name)
{
    for (int i = 0; i < replacedCount; i++) {
        struct replaced *r = &replaced[i];
        if (strcmp(r->pub, pub) || strcmp(r->side, side) || r->cls == cls)
            continue;
        if (inherits(cls, r->cls) || inherits(r->cls, cls))
            printf("AMBIGUOUS\t%s\t%s\t%s\t%s\n", pub, side, r->name, name);
    }
    if (replacedCount < (int)(sizeof replaced / sizeof *replaced)) {
        struct replaced r = { pub, side, cls, name };
        replaced[replacedCount++] = r;
    }
}

static void emitSide(const struct wk_methods_entry *entry, Class side, const char *sideName)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(side, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *pub = sel_getName(method_getName(methods[i]));
        for (const char *const *target = entry->targets; *target; target++) {
            Class cls = objc_getClass(*target);
            const char *image = cls ? class_getImageName(cls) : NULL;
            printf("%s\twk_%s\t%s\t%s\t%s\t%s\t%s\n", pub, pub,
                   entry->intent == WK_METHODS_REPLACE ? "REPLACES" : "GAP_FILL",
                   *target, sideName, image ? image : "-", entry->placeholder);
            if (cls && entry->intent == WK_METHODS_REPLACE)
                noteReplaced(pub, sideName, cls, *target);
        }
    }
    free(methods);
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
    const struct wk_methods_entry *entries =
        (const struct wk_methods_entry *)getsectiondata(header, "__DATA", "__wk_methods", &size);
    if (!entries) {
        fprintf(stderr, "no __DATA,__wk_methods in the force-loaded method polyfills\n");
        return 2;
    }
    size_t count = size / sizeof(*entries);
    for (size_t i = 0; i < count; i++) {
        Class placeholder = objc_getClass(entries[i].placeholder);
        if (!placeholder) {
            fprintf(stderr, "polyfill block %s is not a class in this process\n", entries[i].placeholder);
            return 2;
        }
        emitSide(&entries[i], placeholder, "instance");
        emitSide(&entries[i], object_getClass(placeholder), "class");
    }
    return 0;
}
