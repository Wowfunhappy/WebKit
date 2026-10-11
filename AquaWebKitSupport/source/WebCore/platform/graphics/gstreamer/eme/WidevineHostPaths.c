/* Private CDM adapter: path queries identify the signed files supplied to host verification. */
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

static int (*system_dladdr)(const void *, Dl_info *);
static int (*system_proc_pidpath)(int, void *, uint32_t);
static pthread_once_t system_once = PTHREAD_ONCE_INIT;
static char *cdm_path;
static char *host_path;
static void *cdm_base;
static void *host_base;

static void resolve_system_functions(void)
{
    void *library = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL);
    if (library) {
        system_dladdr = dlsym(library, "dladdr");
        system_proc_pidpath = dlsym(library, "proc_pidpath");
    }
}

/* Called once, before VerifyCdmHost_0 starts its worker. These strings live with the module. */
EXPORT int WidevineSetHostPaths(const char *, const char *, const void *, const void *);
EXPORT int WidevineSetHostPaths(const char *original, const char *helper, const void *cdm, const void *host)
{
    pthread_once(&system_once, resolve_system_functions);
    Dl_info cdm_info, host_info;
    if (cdm_path || !system_dladdr || !system_proc_pidpath
        || !system_dladdr(cdm, &cdm_info) || !system_dladdr(host, &host_info))
        return 0;
    char *original_copy = strdup(original);
    char *helper_copy = strdup(helper);
    if (!original_copy || !helper_copy) {
        free(original_copy);
        free(helper_copy);
        return 0;
    }
    cdm_base = cdm_info.dli_fbase;
    host_base = host_info.dli_fbase;
    cdm_path = original_copy;
    host_path = helper_copy;
    return 1;
}

/* Only the CDM's two-level imports bind here; other images retain libSystem's functions. */
EXPORT int dladdr(const void *address, Dl_info *info)
{
    pthread_once(&system_once, resolve_system_functions);
    int result = system_dladdr ? system_dladdr(address, info) : 0;
    if (!result || !info->dli_fname || !cdm_path)
        return result;
    if (info->dli_fbase == cdm_base)
        info->dli_fname = cdm_path;
    else if (info->dli_fbase == host_base || info->dli_fbase == (void *)_dyld_get_image_header(0))
        info->dli_fname = host_path;
    return result;
}

EXPORT int proc_pidpath(int pid, void *buffer, uint32_t size)
{
    pthread_once(&system_once, resolve_system_functions);
    int result = system_proc_pidpath ? system_proc_pidpath(pid, buffer, size) : 0;
    if (!result || pid != getpid() || !host_path)
        return result;
    size_t length = strlen(host_path);
    if (size <= length) {
        errno = ENOSPC;
        return 0;
    }
    memcpy(buffer, host_path, length + 1);
    return (int)length;
}
