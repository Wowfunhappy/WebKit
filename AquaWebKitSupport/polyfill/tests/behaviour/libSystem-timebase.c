// The mach_timebase_info override (polyfills/shared/mach_timebase_info.c): the shipped archive's
// definition must answer what 10.9's own trap answers, on the first call and on every later one, and
// must be the definition this program's link-time reference binds (the probe links libpolyfill.a the
// way WebKit does).
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

int main(void)
{
    void *kernel = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY | RTLD_NOLOAD);
    kern_return_t (*systemTimebase)(mach_timebase_info_t) = kernel ? dlsym(kernel, "mach_timebase_info") : NULL;
    check(systemTimebase != NULL, "10.9's mach_timebase_info is reachable for comparison");
    check(systemTimebase != (void *)mach_timebase_info, "the linked mach_timebase_info is the archive's, not 10.9's");

    mach_timebase_info_data_t system = { 0, 0 };
    if (systemTimebase)
        systemTimebase(&system);

    mach_timebase_info_data_t first = { 0, 0 }, second = { 0, 0 };
    check(mach_timebase_info(&first) == KERN_SUCCESS, "first call succeeds");
    check(mach_timebase_info(&second) == KERN_SUCCESS, "second (cached) call succeeds");
    check(first.numer == system.numer && first.denom == system.denom, "first call answers the system timebase");
    check(second.numer == system.numer && second.denom == system.denom, "cached call answers the system timebase");
    check(first.denom != 0, "the timebase is a real ratio");

    if (failures)
        printf("mach_timebase_info probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
