/*
 * Copyright (C) 2015-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// FIXME: Remove the `__has_feature(modules)` condition when possible.
#if !__has_feature(modules)

#include <wtf/Compiler.h>
#include <wtf/Platform.h>

DECLARE_SYSTEM_HEADER

#include <CoreMedia/CoreMedia.h>

#if PLATFORM(MAC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnon-modular-include-in-module"
#include <webrtc/webkit_sdk/WebKit/CMBaseObjectSPI.h>
#pragma clang diagnostic pop
#endif

#if PLATFORM(COCOA)

#if USE(APPLE_INTERNAL_SDK)
#include <CoreMedia/FigThreadPlatform.h>
#else
typedef void (*FigThreadAbortAction)(void* refcon);
typedef struct OpaqueFigThreadAbortActionToken* FigThreadAbortActionToken;
#endif

// 10.9 backport: CMTaggedBufferGroup is macOS 14+. Forward-declare the opaque
// types so PAL/cf/CoreMediaSoftLink.h's soft-link declarations parse on the 10.9
// SDK. The functions are soft-linked and never resolve at runtime on 10.9
// (callers nil-check), so the concrete layout is irrelevant.
#ifndef CMTAGGEDBUFFERGROUP_H // header guard of the real CoreMedia type, if present
typedef struct opaqueCMTaggedBufferGroup* CMTaggedBufferGroupRef;
typedef struct opaqueCMTaggedBufferGroupFormatDescription* CMTaggedBufferGroupFormatDescriptionRef;
#endif

WTF_EXTERN_C_BEGIN
OSStatus FigThreadRegisterAbortAction(FigThreadAbortAction, void* refcon, FigThreadAbortActionToken*);
void FigThreadUnregisterAbortAction(FigThreadAbortActionToken);
WTF_EXTERN_C_END

#endif // PLATFORM(COCOA)

#endif // !__has_feature(modules)
