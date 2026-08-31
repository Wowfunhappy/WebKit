/*
 * os/lock.h for the 10.9 host headers, which have none: the os_unfair_lock ABI of 10.12's
 * <os/lock.h> and the option/flag values of 10.15's os_unfair_lock_lock_with_options /
 * _with_flags. The implementation is ../../os_unfair_lock.c.
 */

#ifndef _MAVERICKS_OS_LOCK_H_
#define _MAVERICKS_OS_LOCK_H_

#include <stdbool.h>
#include <stdint.h>

#include "LegacySupport.h"

typedef struct os_unfair_lock_s {
	uint32_t _os_unfair_lock_opaque;
} os_unfair_lock, *os_unfair_lock_t;

#define OS_UNFAIR_LOCK_INIT ((os_unfair_lock){0})

typedef uint32_t os_unfair_lock_options_t;
#define OS_UNFAIR_LOCK_NONE                  0x00000000u
#define OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION  0x00010000u
#define OS_UNFAIR_LOCK_ADAPTIVE_SPIN         0x00040000u
#define OS_UNFAIR_LOCK_ALLOW_ANONYMOUS_OWNER 0x01000000u

typedef uint32_t os_unfair_lock_flags_t;
#define OS_UNFAIR_LOCK_FLAG_NONE                 0x00000000u
#define OS_UNFAIR_LOCK_FLAG_DATA_SYNCHRONIZATION 0x00010000u
#define OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN        0x00040000u

__MP__BEGIN_DECLS

void os_unfair_lock_lock(os_unfair_lock_t lock);
void os_unfair_lock_lock_with_options(os_unfair_lock_t lock, os_unfair_lock_options_t options);
void os_unfair_lock_lock_with_flags(os_unfair_lock_t lock, os_unfair_lock_flags_t flags);
bool os_unfair_lock_trylock(os_unfair_lock_t lock);
void os_unfair_lock_unlock(os_unfair_lock_t lock);
void os_unfair_lock_assert_owner(const os_unfair_lock *lock);
void os_unfair_lock_assert_not_owner(const os_unfair_lock *lock);

__MP__END_DECLS

#endif /* _MAVERICKS_OS_LOCK_H_ */
