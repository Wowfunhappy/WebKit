// The two libSystem replacements this layer installs for memory reporting: task_info(TASK_VM_INFO)
// must answer with phys_footprint filled and the count that includes it, the way a kernel that
// implements REV1 replies, while every other flavor passes through untouched; and a memorypressure
// dispatch source must survive a mask carrying the 10.10+ PROC_LIMIT bits, which 10.9's own
// libdispatch answers with NULL. The probe links the shipped archive the way WebKit does, so it
// exercises the definitions WebKit will bind.
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

int main(void)
{
    // 1. TASK_VM_INFO gains phys_footprint and the REV1 count.
    task_vm_info_data_t info;
    memset(&info, 0xAA, sizeof(info));
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    check(kr == KERN_SUCCESS, "task_info(TASK_VM_INFO) succeeds");
    check(count == TASK_VM_INFO_REV1_COUNT, "the reply length reaches phys_footprint");
    check(info.internal > 0, "internal is filled by the kernel");
    check(info.phys_footprint == info.internal + info.compressed, "phys_footprint is internal + compressed");

    // 2. A caller that asks only for the pre-REV1 count gets the kernel's own reply untouched.
    task_vm_info_data_t rev0;
    memset(&rev0, 0xAA, sizeof(rev0));
    mach_msg_type_number_t rev0Count = TASK_VM_INFO_REV0_COUNT;
    kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&rev0, &rev0Count);
    check(kr == KERN_SUCCESS && rev0Count == TASK_VM_INFO_REV0_COUNT, "a REV0-sized request is answered REV0");

    // 3. Another flavor passes through: TASK_BASIC_INFO still answers a plausible resident size.
    task_basic_info_data_t basic;
    mach_msg_type_number_t basicCount = TASK_BASIC_INFO_COUNT;
    kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&basic, &basicCount);
    check(kr == KERN_SUCCESS && basic.resident_size > 0, "TASK_BASIC_INFO passes through");

    // 4. The memorypressure mask 10.9 rejects is accepted through the replacement.
    void *libdispatch = dlopen("/usr/lib/system/libdispatch.dylib", RTLD_LAZY | RTLD_NOLOAD);
    dispatch_source_t (*systemCreate)(dispatch_source_type_t, uintptr_t, uintptr_t, dispatch_queue_t) =
        libdispatch ? dlsym(libdispatch, "dispatch_source_create") : NULL;
    check(systemCreate != NULL, "10.9's dispatch_source_create is reachable for comparison");
    check(systemCreate != (void *)dispatch_source_create, "the linked dispatch_source_create is the archive's");

    const uintptr_t fullMask = 0x01 | 0x02 | 0x04 | 0x10 | 0x20; // NORMAL|WARN|CRITICAL|PROC_LIMIT_WARN|PROC_LIMIT_CRITICAL
    dispatch_queue_t queue = dispatch_queue_create("wk.probe.memorypressure", NULL);
    if (systemCreate) {
        dispatch_source_t bare = systemCreate(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, fullMask, queue);
        check(bare == NULL, "10.9's own dispatch_source_create rejects the full mask");
    }
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, fullMask, queue);
    check(source != NULL, "the archive's dispatch_source_create accepts the full mask");

    // 5. A source type that is not memorypressure keeps its mask.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    check(timer != NULL, "another source type is forwarded unchanged");

    if (failures)
        printf("task_info / dispatch_source_create probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
