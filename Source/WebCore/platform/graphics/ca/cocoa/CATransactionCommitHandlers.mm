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

#include "config.h"
#include "CATransactionCommitHandlers.h"

#if PLATFORM(MAC)

#import <QuartzCore/QuartzCore.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#include <wtf/BlockPtr.h>

namespace WebCore {

void addCATransactionCommitHandlersForCurrentThread(Function<void()>&& preLayout, Function<void()>&& postCommit)
{
    if ([CATransaction respondsToSelector:@selector(addCommitHandler:forPhase:)]) {
        [CATransaction addCommitHandler:makeBlockPtr([preLayout = WTF::move(preLayout)] {
            preLayout();
        }).get() forPhase:kCATransactionPhasePreLayout];
        [CATransaction addCommitHandler:makeBlockPtr([postCommit = WTF::move(postCommit)] {
            postCommit();
        }).get() forPhase:kCATransactionPhasePostCommit];
        return;
    }

    // MAVERICKS_BACKPORT: CoreAnimation flushes the current thread's implicit transaction from a
    // run-loop observer at kCFRunLoopBeforeWaiting/kCFRunLoopExit with order 2000000. One-shot
    // observers ordered just below and just above straddle that commit: the lower-ordered one
    // runs immediately before it (PreLayout-equivalent), the higher-ordered one immediately
    // after (PostCommit-equivalent). If the drain happens with no pending transaction the pair
    // still fires back-to-back, which is a balanced no-op for callers.
    //
    // One-shot lifetime: CF itself invalidates a non-repeating observer immediately AFTER the
    // callout returns. The handler must NOT call CFRunLoopObserverInvalidate on itself: at fire
    // time the observer holds the only reference to the handler block, and invalidate
    // synchronously releases it (context.release == _Block_release), freeing the executing
    // block and its captured Function mid-callout.
    static const CFIndex caCommitOrder = 2000000;
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    auto preHandler = makeBlockPtr([preLayout = WTF::move(preLayout)](CFRunLoopObserverRef, CFRunLoopActivity) mutable {
        preLayout();
    });
    RetainPtr<CFRunLoopObserverRef> preObserver = adoptCF(CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, caCommitOrder - 1, preHandler.get()));
    CFRunLoopAddObserver(runLoop, preObserver.get(), kCFRunLoopCommonModes);

    auto postHandler = makeBlockPtr([postCommit = WTF::move(postCommit)](CFRunLoopObserverRef, CFRunLoopActivity) mutable {
        postCommit();
    });
    RetainPtr<CFRunLoopObserverRef> postObserver = adoptCF(CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, caCommitOrder + 1, postHandler.get()));
    CFRunLoopAddObserver(runLoop, postObserver.get(), kCFRunLoopCommonModes);
}

} // namespace WebCore

#endif // PLATFORM(MAC)
