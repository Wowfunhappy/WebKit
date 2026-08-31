/*
 * Wrapper for <sys/_types/_mbstate_t.h>. The 10.9 version uses __darwin_mbstate_t
 * without including the header that defines it (it is not self-contained like
 * newer SDKs). libc++ 22 includes it directly, so pull in <sys/_types.h> first.
 */
#ifndef _MAVERICKS_SYS__TYPES__MBSTATE_T_H_
#define _MAVERICKS_SYS__TYPES__MBSTATE_T_H_
#include <sys/_types.h>            /* defines __darwin_mbstate_t (via machine/_types.h) */
#include_next <sys/_types/_mbstate_t.h>
#endif
