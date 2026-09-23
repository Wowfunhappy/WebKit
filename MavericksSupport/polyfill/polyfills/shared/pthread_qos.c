/*
 * Apple's libpthread-105.10.1/src/qos.c returns ENOTSUP before inspecting
 * arguments when PTHREAD_FEATURE_BSDTHREADCTL is absent. Mavericks has no
 * bsdthread_ctl syscall and cannot store or inherit a pthread QoS request.
 * Preserve that unsupported-kernel branch, including errno and output storage.
 */
#include <errno.h>
#include <pthread/qos.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

int pthread_set_qos_class_self_np(qos_class_t qos, int priority)
{
    (void)qos;
    (void)priority;
    return ENOTSUP;
}

int pthread_get_qos_class_np(pthread_t thread, qos_class_t *qos, int *priority)
{
    (void)thread;
    (void)qos;
    (void)priority;
    return ENOTSUP;
}

int pthread_attr_set_qos_class_np(pthread_attr_t *attr, qos_class_t qos, int priority)
{
    (void)attr;
    (void)qos;
    (void)priority;
    return ENOTSUP;
}

int pthread_attr_get_qos_class_np(pthread_attr_t *attr, qos_class_t *qos, int *priority)
{
    (void)attr;
    (void)qos;
    (void)priority;
    return ENOTSUP;
}

pthread_override_t pthread_override_qos_class_start_np(pthread_t thread, qos_class_t qos, int priority)
{
    (void)thread;
    (void)qos;
    (void)priority;
    /* Apple's override operation invokes bsdthread_ctl. This syscall is
     * absent on 10.9; no override token or scheduling change can be made. */
    errno = ENOSYS;
    return NULL;
}

int pthread_override_qos_class_end_np(pthread_override_t override)
{
    (void)override;
    /* No successful start can produce a live token on this kernel. */
    return EINVAL;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(pthread_set_qos_class_self_np, NULL, &pthread_set_qos_class_self_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_get_qos_class_np, NULL, &pthread_get_qos_class_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_attr_set_qos_class_np, NULL, &pthread_attr_set_qos_class_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_attr_get_qos_class_np, NULL, &pthread_attr_get_qos_class_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_override_qos_class_start_np, NULL, &pthread_override_qos_class_start_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(pthread_override_qos_class_end_np, NULL, &pthread_override_qos_class_end_np, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
