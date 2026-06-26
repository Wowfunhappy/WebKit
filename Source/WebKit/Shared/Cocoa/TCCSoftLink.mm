/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"

#import <pal/spi/cocoa/TCCSPI.h>

#import <wtf/SoftLinking.h>

#if __MAC_OS_X_VERSION_MIN_REQUIRED < 101400
#import <dlfcn.h>
// MAVERICKS_BACKPORT: macOS before 10.14 has no camera/microphone TCC services — the system TCC
// framework lacks the kTCCServiceCamera/kTCCServiceMicrophone identifiers, so the soft-links below
// would hand TCCAccessPreflight a NULL service (CFStringGetLength(NULL) crash at startup), and it
// fails closed (Denied) for those services, silently disabling getUserMedia. Load the libtcc_polyfill
// shim (grants the ungated-on-10.9 media services, forwards everything else to the real TCC, and
// supplies the missing constants) in place of the system framework, so the soft-links resolve their
// symbols from it. The shim ships beside the WebKit2 binary under Frameworks/.
namespace WebKit {
void* TCCLibrary(bool isOptional = false);
void* TCCLibrary(bool isOptional)
{
    static void* frameworkLibrary;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        frameworkLibrary = dlopen("@loader_path/Frameworks/libtcc_polyfill.dylib", RTLD_NOW);
        if (!frameworkLibrary)
            frameworkLibrary = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW);
        if (!isOptional)
            RELEASE_ASSERT_WITH_MESSAGE(frameworkLibrary, "%s", dlerror());
    });
    return frameworkLibrary;
}
}
#else
SOFT_LINK_PRIVATE_FRAMEWORK_FOR_SOURCE(WebKit, TCC)
// MAVERICKS_BACKPORT: 10.14+ uses the real TCC framework directly; the libtcc_polyfill path above is only for <10.14.
#endif

SOFT_LINK_CONSTANT_FOR_SOURCE(WebKit, TCC, kTCCServiceAccessibility, CFStringRef)
SOFT_LINK_CONSTANT_FOR_SOURCE(WebKit, TCC, kTCCServiceCamera, CFStringRef)
SOFT_LINK_CONSTANT_FOR_SOURCE(WebKit, TCC, kTCCServiceMicrophone, CFStringRef)
SOFT_LINK_CONSTANT_FOR_SOURCE(WebKit, TCC, kTCCServicePhotos, CFStringRef)
SOFT_LINK_CONSTANT_FOR_SOURCE(WebKit, TCC, kTCCServiceWebKitIntelligentTrackingPrevention, CFStringRef)

SOFT_LINK_FUNCTION_FOR_SOURCE(WebKit, TCC, TCCAccessCheckAuditToken, Boolean, (CFStringRef service, audit_token_t auditToken, CFDictionaryRef options), (service, auditToken, options))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebKit, TCC, TCCAccessPreflight, TCCAccessPreflightResult, (CFStringRef service, CFDictionaryRef options), (service, options))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebKit, TCC, TCCAccessPreflightWithAuditToken, TCCAccessPreflightResult, (CFStringRef service, audit_token_t token, CFDictionaryRef options), (service, token, options))
#if HAVE(TCC_IOS_14_BIG_SUR_SPI)
SOFT_LINK_FUNCTION_FOR_SOURCE(WebKit, TCC, tcc_identity_create, tcc_identity_t, (tcc_identity_type_t type, const char * identifier), (type, identifier));
#endif // HAVE(TCC_IOS_14_BIG_SUR_SPI)
