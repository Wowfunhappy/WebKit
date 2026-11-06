/*
 * The libSystem entry points Google's Widevine CDM imports that neither c/libSystem.m nor shared/
 * provides. libwidevinegap.dylib links this file with both, compiled with their exports intact;
 * see the README.
 *
 * Plain C with no wk_polyfill.h: nothing here is loaded into a WebKit image, and the definitions
 * are exported on purpose -- they exist to be bound to from another image.
 */

#include <mach-o/loader.h>
#include <mach-o/swap.h>
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
