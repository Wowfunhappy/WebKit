/*
 * Mavericks reports the default 512 KiB for the main pthread, regardless of its
 * actual process stack limit. Return that native limit for the main thread,
 * including when another thread queries it. Rust uses this value to install a
 * guard page, so the incorrect size can protect a page inside the real stack.
 */
#include <mach-o/dyld.h>
#include <pthread.h>
#include <sys/resource.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

pthread_t pthread_main_thread_np(void);
typedef size_t (*stacksize_function)(pthread_t);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static stacksize_function native_stacksize(void)
{
    static stacksize_function cached;
    stacksize_function result = __atomic_load_n(&cached, __ATOMIC_ACQUIRE);
    if (!result) {
        const struct mach_header *image = NSAddImage("/usr/lib/system/libsystem_pthread.dylib", NSADDIMAGE_OPTION_RETURN_ONLY_IF_LOADED | NSADDIMAGE_OPTION_RETURN_ON_ERROR);
        NSSymbol symbol = image ? NSLookupSymbolInImage(image, "_pthread_get_stacksize_np", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : NULL;
        if (symbol) {
            result = (stacksize_function)NSAddressOfSymbol(symbol);
            __atomic_store_n(&cached, result, __ATOMIC_RELEASE);
        }
    }
    return result;
}
#pragma clang diagnostic pop

size_t pthread_get_stacksize_np(pthread_t thread)
{
    if (pthread_equal(thread, pthread_main_thread_np())) {
        struct rlimit limit;
        if (!getrlimit(RLIMIT_STACK, &limit)) {
            const rlim_t maximum = 0x40000000; /* Darwin's 1 GiB stack mapping limit. */
            return (size_t)(limit.rlim_cur < maximum ? limit.rlim_cur : maximum);
        }
    }
    stacksize_function original = native_stacksize();
    return original ? original(thread) : 0;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(pthread_get_stacksize_np, NULL, &pthread_get_stacksize_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
