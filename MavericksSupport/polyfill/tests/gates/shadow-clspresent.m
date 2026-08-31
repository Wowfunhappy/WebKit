// Shadow gate probe: which registered class stubs name a class this 10.9 already has. dlopens the class
// dylib (argv[1]) to read its __wk_clsmap but does NOT link libpolyfill.a, so objc_getClass gets 10.9's
// own answer; each entry's provider framework is loaded before asking, so a class cannot be reported
// absent merely because nothing had loaded its framework yet.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif

// Must match struct wk_polyfill_class_entry in mechanism/wk_polyfill.h.
struct entry { const char *name; const char *provider; void *cls; void *(*resolve)(void); };

int main(int argc, char **argv)
{
    if (argc < 2 || !dlopen(argv[1], RTLD_LAZY)) {
        fprintf(stderr, "cannot load %s: %s\n", argc > 1 ? argv[1] : "(none)", dlerror());
        return 2;
    }

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const wk_mach_header *header = (const wk_mach_header *)_dyld_get_image_header(i);
        unsigned long size = 0;
        uint8_t *section = header ? getsectiondata(header, "__DATA", "__wk_clsmap", &size) : NULL;
        if (!section)
            continue;
        struct entry *entries = (struct entry *)section;
        for (size_t j = 0; j < size / sizeof(*entries); j++) {
            char path[512];
            snprintf(path, sizeof path, "/System/Library/Frameworks/%s.framework/%s",
                     entries[j].provider, entries[j].provider);
            dlopen(path, RTLD_LAZY);
            Class cls = objc_getClass(entries[j].name);
            printf("%s\t%s\t%s\n", entries[j].name, entries[j].provider,
                   cls ? "PRESENT" : "absent");
        }
    }
    return 0;
}
