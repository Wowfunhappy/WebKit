// libpthread's private thread-specific-data interface: the static keys libpthread reserves for
// JavaScriptCore and direct access to a thread's TSD slots. 10.9's libpthread reserves keys 0-256
// (pthread_key_create starts at 257), accepts these keys in pthread_key_init_np, and runs their
// destructors at thread exit, re-running one that re-sets its slot. Slot N is the pointer at
// %gs:N*sizeof(void*), the storage pthread_getspecific reads.

#pragma once

#include <pthread.h>

#if !defined(__x86_64__) && !defined(__i386__)
#error "Direct thread-specific data access is defined for x86 only."
#endif

#define __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY0 90
#define __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY1 91
#define __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY2 92
#define __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY3 93
#define __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY4 94

#ifdef __cplusplus
extern "C" {
#endif

extern int pthread_key_init_np(int, void (*)(void*));

#ifdef __cplusplus
}
#endif

__attribute__((always_inline)) static __inline__ int _pthread_has_direct_tsd(void)
{
    return 1;
}

__attribute__((always_inline)) static __inline__ void* _pthread_getspecific_direct(unsigned long slot)
{
    void* value;
    __asm__("mov %%gs:%1, %0" : "=r"(value) : "m"(*(void**)(slot * sizeof(void*))));
    return value;
}

__attribute__((always_inline)) static __inline__ int _pthread_setspecific_direct(unsigned long slot, void* value)
{
    __asm__("mov %1, %%gs:%0" : "=m"(*(void**)(slot * sizeof(void*))) : "r"(value));
    return 0;
}
