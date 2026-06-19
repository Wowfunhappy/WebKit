/*
 * thread_get_register_pointer_values (added ~10.11) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Used by the .NET GC to scan thread registers for managed pointers.
 */

#include <stddef.h>
#include <stdint.h>

#include <mach/mach.h>
#include <mach/thread_act.h>

kern_return_t thread_get_register_pointer_values(
    thread_t thread, uintptr_t *sp, size_t *count,
    uintptr_t *register_values)
{
	x86_thread_state64_t state;
	mach_msg_type_number_t state_count = x86_THREAD_STATE64_COUNT;
	kern_return_t kr = thread_get_state(thread, x86_THREAD_STATE64,
	                                    (thread_state_t)&state, &state_count);
	if (kr != KERN_SUCCESS) return kr;

	if (sp) *sp = state.__rsp;

	if (register_values && count) {
		size_t i = 0;
		register_values[i++] = state.__rax;
		register_values[i++] = state.__rbx;
		register_values[i++] = state.__rcx;
		register_values[i++] = state.__rdx;
		register_values[i++] = state.__rdi;
		register_values[i++] = state.__rsi;
		register_values[i++] = state.__rbp;
		register_values[i++] = state.__r8;
		register_values[i++] = state.__r9;
		register_values[i++] = state.__r10;
		register_values[i++] = state.__r11;
		register_values[i++] = state.__r12;
		register_values[i++] = state.__r13;
		register_values[i++] = state.__r14;
		register_values[i++] = state.__r15;
		register_values[i++] = state.__rip;
		*count = i;
	}
	return KERN_SUCCESS;
}
