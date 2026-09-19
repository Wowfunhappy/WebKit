#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

// Indexed domain existence, including path-restricted and expired native records.
bool wk_cookieStorageHasRecordsForURL(CFTypeRef storage, CFURLRef url);
