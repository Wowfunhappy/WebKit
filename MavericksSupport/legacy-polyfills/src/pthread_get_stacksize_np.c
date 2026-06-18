/* MP support header */
#include "LegacySupport.h"

#include <pthread.h>
#include <sys/resource.h>
#include <stdlib.h>

#include "util.h"

/* private system call available on OS X Mavericks (version 10.9) and later */
/* see https://github.com/apple-oss-distributions/libpthread/blob/ba8e1488a0e6848b710c5daad2e226f66cfed656/private/pthread/private.h#L34 */
pthread_t pthread_main_thread_np(void);

#define kMaxThreadStackSize 0x40000000 /* from LLVM: 1 << 30 or 1Gb */

size_t pthread_get_stacksize_np(pthread_t t) {
     int is_main_thread = pthread_equal(t, pthread_main_thread_np());
    if ( is_main_thread ) {
        /* use LLVM workaround */
        /* see https://github.com/llvm/llvm-project/blob/617a15a9eac96088ae5e9134248d8236e34b91b1/compiler-rt/lib/sanitizer_common/sanitizer_mac.cpp#L414 */
       /* OpenJDK also has a workaround */
       /* see https://github.com/openjdk/jdk/blob/e833bfc8ac6104522d037e7eb300f5aa112688bb/src/hotspot/os_cpu/bsd_x86/os_bsd_x86.cpp#L715 */
        struct rlimit limit;
        if( getrlimit(RLIMIT_STACK, &limit) ) {
             exit(EXIT_FAILURE);
        }
        if( limit.rlim_cur < kMaxThreadStackSize ) {
             return limit.rlim_cur;
        } else {
             return kMaxThreadStackSize;
        }
    } else {
        /* bug only affects main thread */
        GET_OS_FUNC(pthread_get_stacksize_np)
        return (*os_pthread_get_stacksize_np)(t);
    }
}

