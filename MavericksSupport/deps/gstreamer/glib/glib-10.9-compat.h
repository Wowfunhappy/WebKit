/* Build-time shims so glib 2.74 parses + links against the macOS 26.1 SDK at deploy target 10.9.
 * Force-included (via glib-native.ini) into every glib TU. Pure compile-time: no-op the newer SDK's
 * bounds-safety annotation macros (so <malloc/_malloc_type.h> parses), weak-import the fortify FD_SET
 * check, and unlock the *at fcntl constants. Does NOT change glib's behavior — exactly the new-SDK /
 * old-deploy-target technique WebKit's own compat.h uses. See MavericksSupport/deps/gstreamer/glib/build-glib.sh. */
#pragma once
/* This header is force-included into every TU. Skip it for assembly (libffi's .S files) — C
 * declarations don't parse as assembly. */
#ifndef __ASSEMBLER__

/* -fbounds-safety annotation macros (macOS 14+ SDK) — expand to nothing at this deploy target. */
#ifndef __sized_by
#define __sized_by(...)
#endif
#ifndef __sized_by_or_null
#define __sized_by_or_null(...)
#endif
#ifndef __counted_by
#define __counted_by(...)
#endif
#ifndef __counted_by_or_null
#define __counted_by_or_null(...)
#endif
#ifndef __ended_by
#define __ended_by(...)
#endif

/* Fortified FD_SET bounds check (__darwin_check_fd_set_overflow) is macos(11.0)+, absent on 10.9.
 * The SDK's <sys/_types/_fd_def.h> already guards its use with `if (&__darwin_check_fd_set_overflow
 * != 0)` so it degrades gracefully when the symbol is absent — but only if the import is WEAK. Force
 * weak-import (ld64 otherwise hard-errors at deploy 10.9), so it links and resolves to 0 at runtime. */
extern int __darwin_check_fd_set_overflow(int, const void *, int) __attribute__((weak_import));

/* *at fcntl constants (10.10+); the SDK gates them out at deploy 10.9. glib's gio uses AT_FDCWD. */
#ifndef AT_FDCWD
#define AT_FDCWD -2
#endif
#ifndef AT_SYMLINK_NOFOLLOW
#define AT_SYMLINK_NOFOLLOW 0x0020
#endif

#endif /* !__ASSEMBLER__ */
