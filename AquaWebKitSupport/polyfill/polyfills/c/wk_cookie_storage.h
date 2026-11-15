#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

// Indexed domain existence, including path-restricted and expired native records. The caller supplies
// the lowercase domain key the native index uses.
bool wk_cookieStorageHasRecordsForDomain(CFTypeRef storage, const char *domain);

// Borrowed immutable native bytes, valid while the caller retains the cookie.
const void *wk_cookieCompactBytes(CFTypeRef cookie, size_t *length);
