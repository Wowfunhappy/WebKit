/*
 * __darwin_check_fd_set_overflow, the bounds check the FD_SET/FD_CLR/FD_ISSET macros call when the
 * deployment target is 11.0 or later; 10.9's libc predates it. A descriptor passes if it is
 * non-negative and, unless the caller uses unlimited select, below FD_SETSIZE.
 *
 * Plain C: Apple's libxml2 in the deps build, compiled for its 14.0 target, calls it.
 */

#include <sys/select.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

int __darwin_check_fd_set_overflow(int n, const void *fdset, int unlimited)
{
    (void)fdset;
    return (n >= 0 && (unlimited || n < FD_SETSIZE)) ? 1 : 0;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(__darwin_check_fd_set_overflow, NULL, &__darwin_check_fd_set_overflow, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
