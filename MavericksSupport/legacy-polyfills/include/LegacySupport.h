/*
 * Minimal support header for the Mavericks-only legacy-support library.
 *
 * Upstream MacPorts macports-legacy-support must detect the SDK and target OS
 * at compile time and gate every feature behind a pair of version flags
 * (__MPLS_SDK_* / __MPLS_LIB_*).  Since this library targets exactly one OS
 * (OS X 10.9 Mavericks), all of that collapses to constants -- which is all
 * this header provides.  The polyfill sources and wrapper headers were copied
 * from MacPorts with their version gating stripped out (see README).
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted.  The software is provided
 * "as is" without warranty of any kind.
 */

#ifndef _MAVERICKS_LEGACY_SUPPORT_H_
#define _MAVERICKS_LEGACY_SUPPORT_H_

/* C++ declaration wrappers, spelled as upstream spells them. */
#if defined(__cplusplus)
#define __MP__BEGIN_DECLS extern "C" {
#define __MP__END_DECLS   }
#else
#define __MP__BEGIN_DECLS
#define __MP__END_DECLS
#endif

/*
 * Fixed target / SDK: OS X 10.9.  A handful of wrapper conditions reference
 * these where a version test is combined with a POSIX-level test and so could
 * not be stripped mechanically; they evaluate to the 10.9 result here.
 */
#define __MPLS_TARGET_OSVER 1090
#define __MPLS_SDK_MAJOR    1090

/* 64-bit (x86_64) vs 32-bit (i386) -- the only architecture split on 10.9. */
#if defined(__LP64__) && __LP64__
#define __MPLS_64BIT 1
#else
#define __MPLS_64BIT 0
#endif

#endif /* _MAVERICKS_LEGACY_SUPPORT_H_ */
