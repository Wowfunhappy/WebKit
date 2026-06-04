/*
 *  Copyright 2016 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef SDK_OBJC_BASE_RTCMACROS_H_
#define SDK_OBJC_BASE_RTCMACROS_H_

// 10.9 backport: RTCMacros.h is the common base included first by all webkit_sdk ObjC headers.
// On iOS, Foundation arrives transitively via UIKit; on macOS several .mm files include
// NSString-using headers before Foundation, so import it here once for all ObjC TUs.
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#define RTC_OBJC_EXPORT __attribute__((visibility("default")))

#if defined(__cplusplus)
#define RTC_EXTERN extern "C" RTC_OBJC_EXPORT
#else
#define RTC_EXTERN extern RTC_OBJC_EXPORT
#endif

#ifdef __OBJC__
#define RTC_FWD_DECL_OBJC_CLASS(classname) @class classname
#else
#define RTC_FWD_DECL_OBJC_CLASS(classname) typedef struct objc_object classname
#endif

#endif  // SDK_OBJC_BASE_RTCMACROS_H_
