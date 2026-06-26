/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#pragma once

#include <dispatch/dispatch.h>

// MAVERICKS_BACKPORT: these shims supply the typed dispatch_queue_main_t (10.12 SDK)
// and dispatch_queue_create_with_target() (10.10 SDK) only when the SDK we build
// against does not declare them. Gate on the SDK version (__MAC_OS_X_VERSION_MAX_ALLOWED),
// NOT the deployment target — with the modern SDK both are declared, so redefining
// them would collide. The runtime implementation of dispatch_queue_create_with_target,
// absent on 10.9, is provided by the vendored MavericksSupport polyfill archive.
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101200
using dispatch_queue_main_t = dispatch_queue_t;
#endif

#if PLATFORM(MAC) && __MAC_OS_X_VERSION_MAX_ALLOWED < 101000
static inline dispatch_queue_t dispatch_queue_create_with_target(const char* label, dispatch_queue_attr_t attr, dispatch_queue_t target)
{
    dispatch_queue_t queue = dispatch_queue_create(label, attr);
    if (queue && target)
        dispatch_set_target_queue(queue, target);
    return queue;
}
#endif

namespace WTF {

inline dispatch_queue_t globalDispatchQueueSingleton(intptr_t identifier, uintptr_t flags)
{
    // MAVERICKS_BACKPORT: dispatch_get_global_queue with QOS class identifiers (10.10+)
    // returns NULL on 10.9. Map QOS classes to legacy dispatch priorities so the
    // call always returns a valid queue.
    if (identifier == 0x21 /*QOS_CLASS_USER_INTERACTIVE*/ || identifier == 0x19 /*QOS_CLASS_USER_INITIATED*/)
        return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, flags);
    if (identifier == 0x15 /*QOS_CLASS_DEFAULT*/)
        return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, flags);
    if (identifier == 0x11 /*QOS_CLASS_UTILITY*/ || identifier == 0x09 /*QOS_CLASS_BACKGROUND*/)
        return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, flags);
    return dispatch_get_global_queue(identifier, flags); // NOLINT
}

inline dispatch_queue_main_t mainDispatchQueueSingleton()
{
    return dispatch_get_main_queue(); // NOLINT
}

} // namespace WTF

using WTF::globalDispatchQueueSingleton;
using WTF::mainDispatchQueueSingleton;
