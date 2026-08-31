/*
 * The entry points Google's Widevine CDM imports from libSystem that 10.9 does not have.
 *
 * This one file is built into libwidevinegap.dylib, which is installed beside the module and
 * named by the load command WidevineCdmImage repoints; every import the host cannot resolve is
 * bound here instead. getentropy() and aligned_alloc() come from their own sources in this layer
 * and are linked into the same dylib, so what is below is the rest.
 *
 * Plain C with no wk_polyfill.h: nothing here is loaded into a WebKit image, and the definitions
 * are exported on purpose -- they exist to be bound to from another image.
 */

#include <errno.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <mach-o/swap.h>
#include <stddef.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

/*
 * 10.10's per-thread QoS, over the thread scheduling 10.9 expresses it with. A QoS class is a band
 * of scheduling priority plus, at the bottom, the throttled background state; 10.9 has both, as
 * SCHED_OTHER priority and PRIO_DARWIN_BG. The bands below are the ones libdispatch's own classes
 * mapped onto before QoS existed, and the relative priority offsets within a band exactly as the
 * documented API says (0 to -15, anything else EINVAL).
 */
EXPORT int pthread_set_qos_class_self_np(int qos_class, int relative_priority);

EXPORT int pthread_set_qos_class_self_np(int qos_class, int relative_priority)
{
	int priority;
	switch (qos_class) {
	case 0x21: priority = 47; break;            /* QOS_CLASS_USER_INTERACTIVE */
	case 0x19: priority = 37; break;            /* QOS_CLASS_USER_INITIATED */
	case 0x15: case 0x00: priority = 31; break; /* QOS_CLASS_DEFAULT, QOS_CLASS_UNSPECIFIED */
	case 0x11: priority = 27; break;            /* QOS_CLASS_UTILITY */
	case 0x09: priority = 15; break;            /* QOS_CLASS_BACKGROUND */
	default:
		errno = EINVAL;
		return -1;
	}
	if (relative_priority > 0 || relative_priority < -15) {
		errno = EINVAL;
		return -1;
	}

	/* The background class is the throttled one; every other class leaves that state. */
	if (setpriority(PRIO_DARWIN_THREAD, 0, qos_class == 0x09 ? PRIO_DARWIN_BG : 0) && errno != EPERM)
		return -1;

	int lowest = sched_get_priority_min(SCHED_OTHER);
	int highest = sched_get_priority_max(SCHED_OTHER);
	priority += relative_priority;
	if (priority < lowest)
		priority = lowest;
	if (priority > highest)
		priority = highest;

	struct sched_param parameters;
	int policy;
	if (pthread_getschedparam(pthread_self(), &policy, &parameters))
		return -1;
	parameters.sched_priority = priority;
	int error = pthread_setschedparam(pthread_self(), SCHED_OTHER, &parameters);
	if (error) {
		errno = error;
		return -1;
	}
	return 0;
}

/* The byte-swapping counterpart 10.9's <mach-o/swap.h> declares for every other load command but
 * this one. Same shape as its siblings: swap the four 32-bit fields in place. */
EXPORT void swap_linkedit_data_command(struct linkedit_data_command *ld, enum NXByteOrder target_byte_order);

EXPORT void swap_linkedit_data_command(struct linkedit_data_command *ld, enum NXByteOrder target_byte_order)
{
	(void)target_byte_order;
	ld->cmd = OSSwapInt32(ld->cmd);
	ld->cmdsize = OSSwapInt32(ld->cmdsize);
	ld->dataoff = OSSwapInt32(ld->dataoff);
	ld->datasize = OSSwapInt32(ld->datasize);
}

/*
 * os_log, 10.12's unified logging. There is no log to write to on 10.9, which is a state the API
 * itself has a name for: os_log_create() hands back the disabled log, every type is disabled on
 * it, and _os_log_impl() is only ever reached through a type the caller was told is enabled.
 */
struct widevine_gap_os_log { long reserved; };
EXPORT struct widevine_gap_os_log _os_log_default = { 0 };

EXPORT void *os_log_create(const char *subsystem, const char *category);
EXPORT int os_log_type_enabled(void *log, unsigned char type);
EXPORT void _os_log_impl(void *dso, void *log, unsigned char type, const char *format, uint8_t *buffer, uint32_t size);
EXPORT void os_release(void *object);

EXPORT void *os_log_create(const char *subsystem, const char *category)
{
	(void)subsystem;
	(void)category;
	return &_os_log_default;
}

EXPORT int os_log_type_enabled(void *log, unsigned char type)
{
	(void)log;
	(void)type;
	return 0;
}

EXPORT void _os_log_impl(void *dso, void *log, unsigned char type, const char *format, uint8_t *buffer, uint32_t size)
{
	(void)dso;
	(void)log;
	(void)type;
	(void)format;
	(void)buffer;
	(void)size;
}

/* 10.10's os_release, over the os_object release 10.9's libdispatch already has. The disabled log
 * above is a global, and a global os_object is exactly what retain and release do nothing to. */
extern void _os_object_release(void *object);

EXPORT void os_release(void *object)
{
	if (!object || object == &_os_log_default)
		return;
	_os_object_release(object);
}
