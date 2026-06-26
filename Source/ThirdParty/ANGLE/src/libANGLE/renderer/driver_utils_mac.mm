//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

// driver_utils_mac.mm : provides mac-specific information about current driver.

#include "libANGLE/renderer/driver_utils.h"

#import <Foundation/Foundation.h>

// MAVERICKS_BACKPORT: NSOperatingSystemVersion is 10.10+; pull in CoreServices for Gestalt on 10.9.
#if !defined(MAC_OS_X_VERSION_10_10) || (defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED < 101000)
#    import <CoreServices/CoreServices.h>  // Gestalt (NSOperatingSystemVersion is 10.10+)
#endif

namespace rx
{

#if defined(ANGLE_PLATFORM_MACOS)
OSVersion GetMacOSVersion()
{
    OSVersion result;

#if !defined(MAC_OS_X_VERSION_10_10) || (defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED < 101000)
    // MAVERICKS_BACKPORT: -[NSProcessInfo operatingSystemVersion] / NSOperatingSystemVersion are 10.10+.
    SInt32 major = 10, minor = 0, bugfix = 0;
    Gestalt(gestaltSystemVersionMajor, &major);
    Gestalt(gestaltSystemVersionMinor, &minor);
    Gestalt(gestaltSystemVersionBugFix, &bugfix);
    result.majorVersion = static_cast<int>(major);
    result.minorVersion = static_cast<int>(minor);
    result.patchVersion = static_cast<int>(bugfix);
#else
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    result.majorVersion              = static_cast<int>(version.majorVersion);
    result.minorVersion              = static_cast<int>(version.minorVersion);
    result.patchVersion              = static_cast<int>(version.patchVersion);
// MAVERICKS_BACKPORT: end of the 10.10+ NSProcessInfo path; the Gestalt path above is used on 10.9.
#endif

    return result;
}
#endif
}
