/*
 * Copyright (C) 2013-2024 Apple Inc. All rights reserved.
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

#import "AuxiliaryProcess.h"
#import "WebKit2Initialize.h"
#import <JavaScriptCore/ExecutableAllocator.h>
#import <wtf/CompletionHandler.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/RunLoop.h>
#import <wtf/WTFProcess.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

#if !USE(RUNNINGBOARD)
#import <wtf/darwin/XPCExtras.h>
#endif

// FIXME: This should be moved to an SPI header.
#if USE(APPLE_INTERNAL_SDK)
#include <os/voucher_private.h>
#else
extern "C" OS_NOTHROW void voucher_replace_default_voucher(void);
#endif

#define WEBCONTENT_SERVICE_INITIALIZER WebContentServiceInitializer
#define NETWORK_SERVICE_INITIALIZER NetworkServiceInitializer
#define GPU_SERVICE_INITIALIZER GPUServiceInitializer
#define MODEL_SERVICE_INITIALIZER ModelServiceInitializer

namespace WebKit {

class XPCServiceInitializerDelegate {
public:
    XPCServiceInitializerDelegate(OSObjectPtr<xpc_connection_t>, xpc_object_t initializerMessage);

    virtual ~XPCServiceInitializerDelegate();

    virtual bool checkEntitlements();

    virtual bool getConnectionIdentifier(IPC::Connection::Identifier& identifier);
    virtual bool getProcessIdentifier(std::optional<WebCore::ProcessIdentifier>&);
    virtual bool getClientIdentifier(String& clientIdentifier);
    virtual bool getClientBundleIdentifier(String& clientBundleIdentifier);
    virtual bool getClientProcessName(String& clientProcessName);
    virtual bool getClientSDKAlignedBehaviors(SDKAlignedBehaviors&);
    virtual bool getExtraInitializationData(HashMap<String, String>& extraInitializationData);

protected:
    bool hasEntitlement(ASCIILiteral entitlement);
    bool isClientSandboxed();

    OSObjectPtr<xpc_connection_t> m_connection;
    OSObjectPtr<xpc_object_t> m_initializerMessage;
};

template<typename XPCServiceType>
void initializeAuxiliaryProcess(AuxiliaryProcessInitializationParameters&& parameters)
{
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] initializeAuxiliaryProcess about to call singleton().initialize\n", getpid()); fclose(_d);}}
    XPCServiceType::singleton().initialize(WTF::move(parameters));
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] initializeAuxiliaryProcess returned from initialize\n", getpid()); fclose(_d);}}
}

#if !USE(RUNNINGBOARD)
void setOSTransaction(OSObjectPtr<os_transaction_t>&&);
#endif

enum class EnableLockdownMode: bool { No, Yes };
enum class EnableEnhancedSecurity: bool { No, Yes };

void setJSCOptions(xpc_object_t initializerMessage, EnableLockdownMode, EnableEnhancedSecurity, bool isWebContentProcess);
void disableJSC(NOESCAPE WTF::CompletionHandler<void(void)>&& beforeFinalizeHandler);

template<typename XPCServiceType, typename XPCServiceInitializerDelegateType, bool isWebContentProcess = false>
void XPCServiceInitializer(OSObjectPtr<xpc_connection_t> connection, xpc_object_t initializerMessage)
{
    XPCServiceInitializerDelegateType delegate(WTF::move(connection), initializerMessage);

    // Keep the XPC service alive by starting a transaction.
    // os_transaction_create is 10.10+, use xpc_transaction_begin on 10.9.
    xpc_transaction_begin();

    AuxiliaryProcessInitializationParameters parameters;

    if (!delegate.getExtraInitializationData(parameters.extraInitializationData))
        exitProcess(EXIT_FAILURE);

    if (isWebContentProcess)
        JSC::Options::machExceptionHandlerSandboxPolicy = JSC::Options::SandboxPolicy::Allow;
    if (initializerMessage) {
        bool enableLockdownMode = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-lockdown-mode"_s) == "1"_s;
        bool enableEnhancedSecurity = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-enhanced-security"_s) == "1"_s;
        setJSCOptions(initializerMessage, enableLockdownMode ? EnableLockdownMode::Yes : EnableLockdownMode::No, enableEnhancedSecurity ? EnableEnhancedSecurity::Yes : EnableEnhancedSecurity::No, isWebContentProcess);
    }

    // InitializeWebKit2() calls linkedOnOrAfterSDKWithBehavior(), so SDK-aligned behaviors must be
    // configured beforehand.
    SDKAlignedBehaviors clientSDKAlignedBehaviors;
    delegate.getClientSDKAlignedBehaviors(clientSDKAlignedBehaviors);
    setSDKAlignedBehaviors(clientSDKAlignedBehaviors);

    // computeSDKAlignedBehaviors() asserts that it is not called in an auxiliary process, so
    // setAuxiliaryProcessType() should be called before the first call to
    // linkedOnOrAfterSDKWithBehavior() to ensure the assertion will catch bugs where
    // setSDKAlignedBehaviors() isn't called at the right time.
    parameters.processType = XPCServiceType::processType;
    setAuxiliaryProcessType(parameters.processType);

    InitializeWebKit2();
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] post-InitializeWebKit2 — checking entitlements\n", getpid()); fclose(_d);}}

    if (!delegate.checkEntitlements()) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] FAIL: checkEntitlements\n", getpid()); fclose(_d);}}
        exitProcess(EXIT_FAILURE);
    }

    if (!delegate.getConnectionIdentifier(parameters.connectionIdentifier)) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] FAIL: getConnectionIdentifier\n", getpid()); fclose(_d);}}
        exitProcess(EXIT_FAILURE);
    }

    if (!delegate.getClientIdentifier(parameters.clientIdentifier)) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] FAIL: getClientIdentifier\n", getpid()); fclose(_d);}}
        exitProcess(EXIT_FAILURE);
    }

    // The host process may not have a bundle identifier (e.g. a command line app), so don't require one.
    delegate.getClientBundleIdentifier(parameters.clientBundleIdentifier);

    std::optional<WebCore::ProcessIdentifier> processIdentifier;
    if (!delegate.getProcessIdentifier(processIdentifier)) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] FAIL: getProcessIdentifier\n", getpid()); fclose(_d);}}
        exitProcess(EXIT_FAILURE);
    }
    parameters.processIdentifier = *processIdentifier;

    if (!delegate.getClientProcessName(parameters.uiProcessName)) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] FAIL: getClientProcessName\n", getpid()); fclose(_d);}}
        exitProcess(EXIT_FAILURE);
    }
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] all delegate checks passed\n", getpid()); fclose(_d);}}

    // Set the task default voucher to the current value (as propagated by XPC).
    // voucher_replace_default_voucher is 10.10+.

#if HAVE(QOS_CLASSES)
    if (parameters.extraInitializationData.contains("always-runs-at-background-priority"_s))
        Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY);
#endif

    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[PID %d] about to call initializeAuxiliaryProcess<XPCServiceType>\n", getpid()); fclose(_d);}}
    initializeAuxiliaryProcess<XPCServiceType>(WTF::move(parameters));
}

int XPCServiceMain(int, const char**);
void XPCServiceEventHandler(xpc_connection_t peer);
void XPCServiceExit();

} // namespace WebKit
