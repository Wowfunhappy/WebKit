// MAVERICKS_BACKPORT: this file exists in the backport as a neutralized placeholder. Upstream's
// NetworkRTCProvider.mm holds the Network.framework nw_* (10.14+) implementation of NetworkRTCProvider;
// that path is unavailable on 10.9, so the file is excluded from the build (commented out in
// PlatformMac.cmake) and the always-compiled portable implementation lives in NetworkRTCProvider.cpp
// under the WK_RTC_USE_NW == 0 branch. Kept as an empty translation unit so the path stays in the tree.
#include "config.h"
