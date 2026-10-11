#include <assert.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    assert(argc == 3);
    void *module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void *gap = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    assert(module && gap);
    int (*configure)(const char *, const char *, const void *, const void *) = dlsym(gap, "WidevineSetHostPaths");
    int (*mapped_dladdr)(const void *, Dl_info *) = dlsym(gap, "dladdr");
    int (*mapped_pidpath)(int, void *, uint32_t) = dlsym(gap, "proc_pidpath");
    void *cdm = dlsym(module, "CreateCdmInstance");
    assert(configure && mapped_dladdr && mapped_pidpath && cdm);
    const char *original = "/test/original/libwidevinecdm.dylib";
    const char *helper = "/test/Firefox Media Plugin Helper";
    assert(configure(original, helper, cdm, (void *)&main));
    Dl_info real, mapped;
    assert(dladdr(cdm, &real) && mapped_dladdr(cdm, &mapped));
    assert(!strcmp(mapped.dli_fname, original));
    assert(mapped.dli_fbase == real.dli_fbase && mapped.dli_saddr == real.dli_saddr && mapped.dli_sname == real.dli_sname);
    assert(dladdr((void *)&main, &real) && mapped_dladdr((void *)&main, &mapped));
    assert(strcmp(real.dli_fname, helper) && !strcmp(mapped.dli_fname, helper));
    assert(mapped.dli_fbase == real.dli_fbase && mapped.dli_saddr == real.dli_saddr && mapped.dli_sname == real.dli_sname);
    assert(dladdr((void *)&malloc, &real) && mapped_dladdr((void *)&malloc, &mapped));
    assert(!strcmp(real.dli_fname, mapped.dli_fname));
    assert(!mapped_dladdr(NULL, &mapped));
    char real_path[PROC_PIDPATHINFO_MAXSIZE], mapped_path[PROC_PIDPATHINFO_MAXSIZE];
    assert(proc_pidpath(getpid(), real_path, sizeof(real_path)) > 0);
    assert(mapped_pidpath(getpid(), mapped_path, sizeof(mapped_path)) == (int)strlen(helper));
    assert(strcmp(real_path, helper) && !strcmp(mapped_path, helper));
    int actual = proc_pidpath(getppid(), real_path, sizeof(real_path));
    assert(mapped_pidpath(getppid(), mapped_path, sizeof(mapped_path)) == actual);
    if (actual)
        assert(!strcmp(real_path, mapped_path));
    assert(!mapped_pidpath(-1, mapped_path, sizeof(mapped_path)));
    puts("scoped host paths: PASS (system functions, other images/PIDs and Dl_info preserved)");
    return 0;
}
