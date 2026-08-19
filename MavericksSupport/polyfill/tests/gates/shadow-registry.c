// Shadow gate probe: what the C registry declares. Linked with libpolyfill.a force-loaded, it walks the
// __DATA,__wk_pfmap section this binary then carries -- the same walk wk_polyfill_runtime.c does at
// startup, so "declared" means what the loader will see. Prints "<name>\t<REPLACES|GAP_FILL>".
#include "wk_polyfill.h"
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <stdio.h>
#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif
int main(void)
{
    Dl_info info;
    if (!dladdr((void *)&main, &info) || !info.dli_fbase) {
        fprintf(stderr, "cannot locate own image\n");
        return 2;
    }
    unsigned long size = 0;
    uint8_t *section = getsectiondata((const wk_mach_header *)info.dli_fbase,
                                      "__DATA", "__wk_pfmap", &size);
    if (!section) {
        fprintf(stderr, "no __DATA,__wk_pfmap in the force-loaded archive\n");
        return 2;
    }
    struct wk_polyfill_entry *entries = (struct wk_polyfill_entry *)section;
    for (size_t i = 0, n = size / sizeof(*entries); i < n; i++)
        printf("%s\t%s\n", entries[i].name,
               entries[i].intent == WK_POLYFILL_REPLACES ? "REPLACES" : "GAP_FILL");
    return 0;
}
