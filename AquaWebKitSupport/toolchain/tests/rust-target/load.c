#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 2)
        return 1;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "target dlopen: %s\n", dlerror());
        return 1;
    }
    int (*probe)(void) = (int (*)(void))dlsym(library, "target_runtime_smoke");
    if (!probe || probe() != 42)
        return 1;
    for (unsigned i = 0; i < _dyld_image_count(); ++i) {
        const char *path = _dyld_get_image_name(i);
        const char *basename = strrchr(path, '/');
        if (strstr(path, "libSystemRust") || strstr(path, "libRustHostSupport") || (basename && !strcmp(basename, "/libSystem"))
            || (strstr(path, "libunwind") && strcmp(path, "/usr/lib/system/libunwind.dylib"))) {
            fprintf(stderr, "target loaded host or nonnative unwind runtime: %s\n", path);
            return 1;
        }
    }
    puts("PASS: Rust target unwind/drop, native unwinder, threads, entropy, time and file-copy fallback");
    /* GStreamer keeps initialized plugin modules resident through TLS teardown. */
    return 0;
}
