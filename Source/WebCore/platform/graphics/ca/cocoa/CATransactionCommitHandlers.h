/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if PLATFORM(MAC)

#include <wtf/Function.h>

namespace WebCore {

// MAVERICKS_BACKPORT: 10.9-compatible equivalent of registering one-shot
// +[CATransaction addCommitHandler:forPhase:] handlers (10.10+) for the CURRENT thread's next
// implicit-transaction commit. On 10.10+ it uses the real API; on 10.9 it straddles
// CoreAnimation's commit run-loop observer (order 2000000) with one-shot observers at
// order 2000000 -/+ 1 on the current thread's run loop, which fire immediately before
// (PreLayout-equivalent) and after (PostCommit-equivalent) the commit.
WEBCORE_EXPORT void addCATransactionCommitHandlersForCurrentThread(Function<void()>&& preLayout, Function<void()>&& postCommit);

} // namespace WebCore

#endif // PLATFORM(MAC)
