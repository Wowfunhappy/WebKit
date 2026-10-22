#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

// Indexed domain existence, including path-restricted and expired native records.
bool wk_cookieStorageHasRecordsForURL(CFTypeRef storage, CFURLRef url);

// The caller supplies the canonical lowercase ASCII domain used by the native index.
bool wk_cookieStorageHasRecordsForDomain(CFTypeRef storage, const char *domain);

// Borrowed immutable native bytes, valid while the caller retains the cookie.
const void *wk_cookieCompactBytes(CFTypeRef cookie, size_t *length);
