// ICC lutAToB/lutBToA parametric curves store their function type at byte eight.
#include "wk_symbols.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <objc/objc-sync.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

static void wk_fixEmbeddedICCCurves(const struct mach_header *header, intptr_t slide)
{
    (void)slide;
    wk_image image;
    if (!wk_find_image("/ColorSync.framework/Versions/A/ColorSync", &image)
        && !wk_find_image("/ColorSync.framework/ColorSync", &image))
        return;
    if (_dyld_get_image_header(image.index) != header)
        return;
    const char *symbol = "__ZN9CMMLutTag20InitializeCurveTableERNS_13CMMCurveTableER9CMMMemMgrjjP16CMMTagDataAccessPj";
    uint8_t *function = wk_symbol_in_image(&image, symbol);
    if (!function)
        wk_patch_fail(symbol, "native ICC curve parser is absent");
    id lock = (id)objc_getClass("NSObject");
    if (!lock)
        wk_patch_fail(symbol, "process-wide initialization lock is absent");
    objc_sync_enter(lock);
    // cmp eax,'para'; jne curv; mov ax,[r12+offset]; rol ax,8; cmp ax,4; ja invalid.
    static const uint8_t before[] = { 0x3d, 0x61, 0x72, 0x61, 0x70, 0x75, 0x35, 0x66, 0x41, 0x8b, 0x44, 0x24 };
    static const uint8_t after[] = { 0x66, 0xc1, 0xc0, 0x08, 0x66, 0x83, 0xf8, 0x04, 0x0f, 0x87, 0x0d, 0x01, 0x00, 0x00 };
    if (memcmp(function + 0x92, before, sizeof(before)) || memcmp(function + 0x9f, after, sizeof(after))
        || (function[0x9e] != 2 && function[0x9e] != 8))
        wk_patch_fail(symbol, "native ICC curve parser encoding differs");
    if (function[0x9e] == 2) {
        mach_vm_address_t address = (mach_vm_address_t)(uintptr_t)(function + 0x9e);
        mach_vm_address_t region = address;
        mach_vm_size_t regionSize = 0;
        vm_region_submap_info_data_64_t info;
        natural_t depth = 0;
        kern_return_t result;
        do {
            region = address;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            result = mach_vm_region_recurse(mach_task_self(), &region, &regionSize, &depth, (vm_region_recurse_info_t)&info, &count);
            if (result != KERN_SUCCESS || !info.is_submap)
                break;
            ++depth;
        } while (true);
        if (result != KERN_SUCCESS || address < region || address - region >= regionSize)
            wk_patch_fail(symbol, "native ICC curve parser page did not resolve");
        mach_vm_size_t pageSize = (mach_vm_size_t)getpagesize();
        mach_vm_address_t page = address & ~(pageSize - 1);
        if (mach_vm_protect(mach_task_self(), page, pageSize, false, info.protection | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
            wk_patch_fail(symbol, "native ICC curve parser page is not writable");
        __atomic_store_n(function + 0x9e, 8, __ATOMIC_RELEASE);
        __builtin___clear_cache((char*)function + 0x99, (char*)function + 0x9f);
        if (mach_vm_protect(mach_task_self(), page, pageSize, false, info.protection) != KERN_SUCCESS)
            wk_patch_fail(symbol, "native ICC curve parser page protections did not restore");
    }
    objc_sync_exit(lock);
}

static void wk_registerICCCurveRepair(void)
{
    _dyld_register_func_for_add_image(wk_fixEmbeddedICCCurves);
}

void wk_initializeICCParser(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_registerICCCurveRepair);
}

__attribute__((constructor)) static void wk_initializeColorSyncCompatibility(void)
{
    wk_initializeICCParser();
}
