/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
 * Portions Copyright (c) 2010 Motorola Mobility, Inc. All rights reserved.
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

#if defined(HAVE_CONFIG_H) && HAVE_CONFIG_H && defined(BUILDING_WITH_CMAKE)
#include "cmakeconfig.h"
#endif

#include <wtf/Platform.h>

#if PLATFORM(COCOA)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __OBJC__
#if !USE(APPLE_INTERNAL_SDK)
/* SecTask.h declares SecTaskGetCodeSignStatus(...) to
 * be unavailable on macOS, so do not include that header. */
#define _SECURITY_SECTASK_H_
#endif
#import <Foundation/Foundation.h>
#if USE(APPKIT)
#import <Cocoa/Cocoa.h>
#endif
#endif // __OBJC__

#endif // PLATFORM(COCOA)

/* When C++ exceptions are disabled, the C++ library defines |try| and |catch|
* to allow C++ code that expects exceptions to build. These definitions
* interfere with Objective-C++ uses of Objective-C exception handlers, which
* use |@try| and |@catch|. As a workaround, undefine these macros. */

#ifdef __cplusplus
#include <algorithm> // needed for exception_defines.h
#include <chrono>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <wtf/TZoneMalloc.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Variant.h>
#endif

// MAVERICKS_BACKPORT: modern Foundation annotation macros absent on the 10.9 SDK. Without
// them WebKit's own ObjC API headers fail to parse — e.g. NS_SWIFT_UI_ACTOR and
// NS_HEADER_AUDIT_BEGIN(nullability, sendability) leak their tokens as unknown type names.
#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
#ifndef NS_HEADER_AUDIT_BEGIN
#define NS_HEADER_AUDIT_BEGIN(...)
#endif
#ifndef NS_HEADER_AUDIT_END
#define NS_HEADER_AUDIT_END(...)
#endif
#ifndef OS_NOTHROW
#define OS_NOTHROW
#endif

#ifdef __OBJC__
#undef try
#undef catch
#endif

#ifdef __cplusplus
#define new ("if you use new/delete make sure to include config.h at the top of the file"()) 
#define delete ("if you use new/delete make sure to include config.h at the top of the file"()) 
#endif

#if USE(OS_LOG)
#include <os/log.h>
#endif
