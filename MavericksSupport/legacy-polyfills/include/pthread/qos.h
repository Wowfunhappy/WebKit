/*
 * Wrapper/replacement for <pthread/qos.h> (the pthread QoS API, macOS 10.10+),
 * which is absent from the 10.9 SDK. Companion header to src/qos.c, whose no-op
 * implementations back these declarations (10.9 has no QoS scheduling classes;
 * LLVM/Rust/etc. call these only as scheduling hints, safely ignored).
 *
 * QOS_CLASS_* values are Apple's standard constants. Custom (non-MacPorts)
 * polyfill, matching the existing src/qos.c.
 */
#ifndef _MAVERICKS_PTHREAD_QOS_H_
#define _MAVERICKS_PTHREAD_QOS_H_

#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    QOS_CLASS_USER_INTERACTIVE = 0x21,
    QOS_CLASS_USER_INITIATED   = 0x19,
    QOS_CLASS_DEFAULT          = 0x15,
    QOS_CLASS_UTILITY          = 0x11,
    QOS_CLASS_BACKGROUND       = 0x09,
    QOS_CLASS_UNSPECIFIED      = 0x00,
} qos_class_t;

typedef struct pthread_override_s *pthread_override_t;

int  pthread_set_qos_class_self_np(qos_class_t __qos_class, int __relative_priority);
int  pthread_get_qos_class_np(pthread_t __pthread, qos_class_t *__qos_class, int *__relative_priority);
int  pthread_attr_set_qos_class_np(pthread_attr_t *__attr, qos_class_t __qos_class, int __relative_priority);
int  pthread_attr_get_qos_class_np(pthread_attr_t *__attr, qos_class_t *__qos_class, int *__relative_priority);
pthread_override_t pthread_override_qos_class_start_np(pthread_t __pthread, qos_class_t __qos_class, int __relative_priority);
int  pthread_override_qos_class_end_np(pthread_override_t __override);

#ifdef __cplusplus
}
#endif

#endif /* _MAVERICKS_PTHREAD_QOS_H_ */
