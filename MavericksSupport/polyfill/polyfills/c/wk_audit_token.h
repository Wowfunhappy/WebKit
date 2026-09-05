// The pid an audit token names, for the polyfills that translate a token-keyed API onto 10.9's
// pid-keyed one. Every function here has hidden visibility (the archive is built with
// -fvisibility=hidden) and one definition per image.

#ifndef WK_AUDIT_TOKEN_H
#define WK_AUDIT_TOKEN_H

#include "wk_polyfill.h"
#include <sys/types.h>

// audit_token_t is laid out identically, so a token is passed by value unchanged.
typedef struct { unsigned int val[8]; } mav_audit_token_t;

// audit_token_to_pid() is soft-linked rather than linked: it lives in libbsm, which this archive's
// consumers do not otherwise pull in, and a link-time reference would make every small host tool
// that force-loads libpolyfill (LLIntSettingsExtractor and friends) need -lbsm.
WK_SYSTEM_FN("/usr/lib/libbsm.dylib", pid_t, audit_token_to_pid, (mav_audit_token_t));

#endif
