// Initializes vImage in every process that loads WebCore.
#include "wk_symbols.h"

__attribute__((constructor)) static void wk_initializeVImage(void)
{
    wk_image vimage, kernel;
    if (!wk_find_image("/vImage.framework/Versions/A/vImage", &vimage)
        || !wk_find_image("/libsystem_kernel.dylib", &kernel))
        wk_patch_fail("vImage", "required system images are not loaded");
    void (*setVectorAvailable)(uint32_t) = wk_symbol_in_image(&vimage, "_SetvImageVectorAvailable");
    uint64_t (*getCapabilities)(void) = wk_symbol_in_image(&kernel, "__get_cpu_capabilities");
    if (!setVectorAvailable || !getCapabilities)
        wk_patch_fail("vImage", "required system entry points are absent");

    // Mavericks' packed-color AVX2 conversion corrupts columns. This changes only vImage's
    // dispatch mask; kHasAVX2_0 is Darwin's capability bit, not the CPUID leaf-7 bit.
    setVectorAvailable((uint32_t)getCapabilities() & ~UINT32_C(0x20000000));
}
