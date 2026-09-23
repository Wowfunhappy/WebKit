/* Filesystem cloning declarations absent from the Mavericks SDK. */
#ifndef _MAVERICKS_SYS_CLONEFILE_H_
#define _MAVERICKS_SYS_CLONEFILE_H_

#include <stdint.h>
#include <sys/cdefs.h>

#define CLONE_NOFOLLOW 0x0001
#define CLONE_NOOWNERCOPY 0x0002
#define CLONE_ACL 0x0004
#define CLONE_NOFOLLOW_ANY 0x0008
#define CLONE_RESOLVE_BENEATH 0x0010

__BEGIN_DECLS
int clonefile(const char *, const char *, uint32_t);
int clonefileat(int, const char *, int, const char *, uint32_t);
int fclonefileat(int, int, const char *, uint32_t);
__END_DECLS

#endif
