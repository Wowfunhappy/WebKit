// Shadow gate probe: does this machine's 10.9 runtime export the names on stdin? Ground truth for the
// gate: the build SDK is 26.1 and its stubs say nothing about what shipped in 2013. The images a WebKit
// binary's references can bind against are the arguments.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv)
{
    // Per-handle dlsym, NOT RTLD_DEFAULT: a flat global search also finds PRIVATE exports of
    // transitively loaded frameworks that no two-level-namespace bind against these libraries could
    // ever reach -- false positives. dlsym(handle) searches that library and its dependencies, which
    // is the scope a real link-time bind sees.
    void *handles[64]; const char *names[64];
    int count = 0;
    for (int i = 1; i < argc && count < 64; i++) {
        void *handle = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        if (handle) { handles[count] = handle; names[count] = argv[i]; count++; }
    }
    char line[512];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0])
            continue;
        for (int i = 0; i < count; i++) {
            void *address = dlsym(handles[i], line);
            if (!address)
                continue;
            // Report the image that actually defines it, not the handle it was reached through: a
            // libSystem symbol answers on every framework handle, and "CoreGraphics has strlen" is
            // no help to whoever has to fix it.
            Dl_info info;
            printf("%s\t%s\n", line,
                   dladdr(address, &info) && info.dli_fname ? info.dli_fname : names[i]);
            break;
        }
    }
    return 0;
}
