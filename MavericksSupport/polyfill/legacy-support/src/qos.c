/*
 * pthread QoS (Quality of Service) API (macOS 10.10+) --
 * custom polyfill (not from macports-legacy-support).
 *
 * 10.9 has no QoS scheduling classes; LLVM, Rust, and friends call these to
 * set worker-thread scheduling hints, which we can safely ignore (no-ops).
 */

#include <pthread.h>

int pthread_set_qos_class_self_np(int qos_class, int relative_priority) {
	(void)qos_class; (void)relative_priority;
	return 0;
}

int pthread_get_qos_class_np(pthread_t pthread, int *qos_class, int *relative_priority) {
	(void)pthread;
	if (qos_class) *qos_class = 0; /* QOS_CLASS_UNSPECIFIED */
	if (relative_priority) *relative_priority = 0;
	return 0;
}

int pthread_attr_set_qos_class_np(pthread_attr_t *attr, int qos_class, int relative_priority) {
	(void)attr; (void)qos_class; (void)relative_priority;
	return 0;
}

int pthread_attr_get_qos_class_np(pthread_attr_t *attr, int *qos_class, int *relative_priority) {
	(void)attr;
	if (qos_class) *qos_class = 0;
	if (relative_priority) *relative_priority = 0;
	return 0;
}

void *pthread_override_qos_class_start_np(pthread_t pthread, int qos_class, int relative_priority) {
	(void)pthread; (void)qos_class; (void)relative_priority;
	return (void*)1;
}

int pthread_override_qos_class_end_np(void *override) {
	(void)override;
	return 0;
}
