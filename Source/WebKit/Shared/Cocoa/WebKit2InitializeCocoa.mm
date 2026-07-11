/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#import "WebKit2Initialize.h"

#import <JavaScriptCore/InitializeThreading.h>
#import <WebCore/CommonAtomStrings.h>
#import <WebCore/WebCoreJITOperations.h>
// MAVERICKS_BACKPORT: dlopen/dlsym used below to reconcile the JSC and WebKit WTF copies.
#import <dlfcn.h>
#import <mutex>
#import <wtf/MainThread.h>
#import <wtf/RefCounted.h>
#import <wtf/WorkQueue.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

#if PLATFORM(IOS_FAMILY)
#import <WebCore/WebCoreThreadSystemInterface.h>
#endif

#if ENABLE(LLVM_PROFILE_GENERATION)
#if PLATFORM(IOS_FAMILY)
#import <wtf/LLVMProfilingUtils.h>
extern "C" char __llvm_profile_filename[] = "%t/WebKitPGO/WebKit_%m_pid%p%c.profraw";
#else
extern "C" char __llvm_profile_filename[] = "/private/tmp/WebKitPGO/WebKit_%m_pid%p%c.profraw";
#endif
#endif

// MAVERICKS_BACKPORT: libgcrypt-backed crypto initialization (CryptoKit path unavailable on 10.9).
#if USE(GCRYPT)
#include <pal/crypto/gcrypt/Initialization.h>
#endif

namespace WebKit {

static std::once_flag flag;

enum class WebKitProfileTag { };

static void runInitializationCode(void* = nullptr)
{
    RELEASE_ASSERT_WITH_MESSAGE([NSThread isMainThread], "InitializeWebKit2 should be called on the main thread");

    WTF::initializeMainThread();

    // MAVERICKS_BACKPORT: reconcile the two statically-linked WTF copies (WebKit's and JSC's) so both
    // RunLoop::s_mainRunLoop singletons are initialized.
    // WebKit and JavaScriptCore each have their own statically-linked copy of WTF.
    // The local WTF::initializeMainThread() above only initialises WebKit's copy
    // (sets WebKit's RunLoop::s_mainRunLoop). But many WebKit call sites
    // resolve WTF::RunLoop::mainSingleton() through the dyld stub to the
    // exported JavaScriptCore copy, whose s_mainRunLoop would otherwise stay
    // null. Look up the JSC copy by symbol and call it explicitly so both
    // copies of the global state are in a consistent state.
    {
        if (void* jsc = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore", RTLD_NOLOAD | RTLD_LAZY)) {
            using InitFn = void (*)();
            if (auto fn = reinterpret_cast<InitFn>(dlsym(jsc, "_ZN3WTF20initializeMainThreadEv"))) {
                if (reinterpret_cast<void*>(fn) != reinterpret_cast<void*>(&WTF::initializeMainThread))
                    fn();
            }
        }
    }

    JSC::initialize();
    WebCore::initializeCommonAtomStrings();
#if PLATFORM(IOS_FAMILY)
    InitWebCoreThreadSystemInterface();
#endif

    WTF::RefCountDebuggerBase::enableThreadingChecksGlobally();

    WebCore::populateJITOperations();

#if USE(GCRYPT)
    // MAVERICKS_BACKPORT: UIProcess calls wrapSerializedCryptoKey through the
    // libgcrypt path too (see WebPageProxy.cpp / WebProcessProxy.cpp).
    // gcry_check_version must run before any other libgcrypt call.
    PAL::GCrypt::initialize();
#endif

}

void InitializeWebKit2()
{
    // Make sure the initialization code is run only once and on the main thread since things like initializeMainThread()
    // are only safe to call on the main thread.
    std::call_once(flag, [] {
        if ([NSThread isMainThread] || linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::InitializeWebKit2MainThreadAssertion))
            runInitializationCode();
        else
            WorkQueue::mainSingleton().dispatchSync([] { runInitializationCode(); });
    });
}

}
