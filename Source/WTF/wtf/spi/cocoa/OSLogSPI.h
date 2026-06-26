/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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

#include <wtf/Compiler.h>

DECLARE_SYSTEM_HEADER

#include <os/log.h>
#include <wtf/Platform.h>

#if USE(APPLE_INTERNAL_SDK)

#include <os/log_private.h>

#else

typedef uint32_t os_trace_mode_t;

// MAVERICKS_BACKPORT: defined as a plain enum because the OS_ENUM() macro (and the os_trace tracing infrastructure it belongs to) does not exist in the 10.9 <os/trace.h>.
enum {
    OS_TRACE_MODE_INFO                          = 0x01,
    OS_TRACE_MODE_DEBUG                         = 0x02,
    OS_TRACE_MODE_BACKTRACE                     = 0x04,
    OS_TRACE_MODE_STREAM_LIVE                   = 0x08,
    OS_TRACE_MODE_DISABLE                       = 0x0100,
    OS_TRACE_MODE_OFF                           = 0x0400,
}; // MAVERICKS_BACKPORT: plain enum, OS_ENUM()/os_trace absent on 10.9 (see above).

typedef struct os_log_message_s {
    uint64_t trace_id;
    char padding[80];
    const char *format;
    const uint8_t *buffer;
    size_t buffer_sz;
    const uint8_t *privdata;
    size_t privdata_sz;
    const char *subsystem;
    const char *category;
} *os_log_message_t;

#endif

WTF_EXTERN_C_BEGIN

// MAVERICKS_BACKPORT: these os_log/os_trace SPI functions are provided as no-op inline stubs because the underlying symbols do not exist in the macOS 10.9 libsystem; upstream declares them as external OS_EXPORT functions, which would fail to link here.
static inline void os_log_with_args(os_log_t oslog, os_log_type_t type, const char *format, va_list args, void *ret_addr) {
    (void)oslog; (void)type; (void)format; (void)args; (void)ret_addr;
}

// MAVERICKS_BACKPORT: no-op inline stubs; os_trace mode SPI does not exist in 10.9 libsystem.
static inline void os_trace_set_mode(os_trace_mode_t mode) { (void)mode; }
static inline os_trace_mode_t os_trace_get_mode(void) { return 0; }

typedef void (^os_log_hook_t)(os_log_type_t type, os_log_message_t msg);

// MAVERICKS_BACKPORT: no-op inline stubs; these os_log SPI symbols do not exist in 10.9 libsystem.
static inline os_log_hook_t os_log_set_hook(os_log_type_t level, os_log_hook_t hook) { (void)level; return hook; }
static inline char* os_log_copy_message_string(os_log_message_t msg) { (void)msg; return 0; }

WTF_EXTERN_C_END
