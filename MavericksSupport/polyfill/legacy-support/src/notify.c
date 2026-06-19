/*
 * notify_is_valid_token (added macOS 10.10) --
 * custom polyfill (not from macports-legacy-support).
 */

#include <stdbool.h>
#include <errno.h>

bool notify_is_valid_token(int token) {
	(void)token;
	errno = ENOSYS;
	return false;
}
