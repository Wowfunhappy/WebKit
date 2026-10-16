/*
 * The entry points Google's Widevine CDM imports from libSystem that 10.9 does not have.
 *
 * This one file is built into libwidevinegap.dylib, which is installed beside the module and
 * named by the load command WidevineCdmImage repoints; every import the host cannot resolve is
 * bound here instead. getentropy(), aligned_alloc(), the pthread QoS calls and os_log come from
 * their own sources in this layer and are linked into the same dylib, so what is below is the rest.
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

/* 10.10's os_release, over the os_object release 10.9's libdispatch already has. */
extern void _os_object_release(void *object);

EXPORT void os_release(void *object);

EXPORT void os_release(void *object)
{
	if (object)
		_os_object_release(object);
}
