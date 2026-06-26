/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
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

#include "config.h"
#include "AuxiliaryProcess.h"

#include <pthread.h>
#include "AuxiliaryProcessCreationParameters.h"
#include "Connection.h"
#include "ContentWorldShared.h"
#include "LogInitialization.h"
#include "Logging.h"
#include "SandboxInitializationParameters.h"
#include "StreamClientConnection.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/LogInitialization.h>
#include <pal/SessionID.h>
#include <wtf/LogInitialization.h>
#include <wtf/SetForScope.h>
#include <wtf/WTFProcess.h>

#if !OS(WINDOWS)
#include <unistd.h>
#endif

#if OS(LINUX)
#include <wtf/MemoryPressureHandler.h>
#if USE(GLIB)
#include <wtf/glib/Sandbox.h>
#endif
#endif

#if PLATFORM(COCOA)
#include "CoreIPCSecureCoding.h"
#endif

namespace WebKit {
using namespace WebCore;

AuxiliaryProcess::AuxiliaryProcess()
    : m_terminationCounter(0)
    // 10.9: m_processSuppressionDisabled (UserActivity) crashes during construction
    // in HashTable<TimerBase*>::add. Leave nullopt; we don't need it for the basic test.
{
}

AuxiliaryProcess::~AuxiliaryProcess()
{
    if (RefPtr connection = m_connection)
        connection->invalidate();
}

void AuxiliaryProcess::didClose(IPC::Connection&)
{
// Stop the run loop for GTK and WPE to ensure a normal exit, since we need
// atexit handlers to be called to cleanup resources like EGL displays.
#if PLATFORM(GTK) || PLATFORM(WPE)
    stopRunLoop();
#else
    terminateProcess(EXIT_SUCCESS);
#endif
}


void AuxiliaryProcess::initialize(AuxiliaryProcessInitializationParameters&& parameters)
{
    // Minimal init for 10.9: skip everything except essential IPC setup

    // 10.9 backport: Safari sends a second XPC bootstrap message after the first
    // initialize completes. Calling initialize twice would re-lazyInitialize the
    // already-set m_connection (RELEASE_ASSERT — SIGTRAP). Skip via m_connection check
    // (function-local static was firing too early in Safari's case).
    if (m_connection) {
        return;
    }

#if PLATFORM(COCOA)
    ASSERT(processType() == parameters.processType);
#endif

    if (parameters.processIdentifier)
        Process::setIdentifier(*parameters.processIdentifier);

    // Skip platformInitialize, sandbox, and most of initializeProcess.
    // Just set the process type:
    initializeProcess(parameters);

    // The critical part: establish the IPC connection back to the UI process.
    Ref connection = IPC::Connection::createClientConnection(WTF::move(parameters.connectionIdentifier));
    lazyInitialize(m_connection, connection.copyRef());
    initializeConnection(connection.ptr());
    // 10.9: AuxiliaryProcess::initialize runs on a dispatch worker thread, so the
    // default Connection::open(Client&) — which uses RunLoop::currentSingleton() as
    // dispatcher — would bind dispatch to a worker-thread RunLoop nobody pumps.
    // Force the main RunLoop so message dispatch reaches WebPage etc.
    connection->open(*this, RunLoop::mainSingleton());
}

void AuxiliaryProcess::setProcessSuppressionEnabled(bool enabled)
{
    if (!m_processSuppressionDisabled)
        return;
    if (enabled)
        m_processSuppressionDisabled->stop();
    else
        m_processSuppressionDisabled->start();
}

void AuxiliaryProcess::initializeProcess(const AuxiliaryProcessInitializationParameters&)
{
}

void AuxiliaryProcess::initializeProcessName(const AuxiliaryProcessInitializationParameters&)
{
}

void AuxiliaryProcess::initializeConnection(IPC::Connection* connection)
{
#if OS(LINUX) && USE(GLIB)
    // When bubblewrap sandbox is used isInsideFlatpak() also returns true in the web process.
    if (isInsideFlatpak())
        connection->sendCredentials();
#else
    UNUSED_PARAM(connection);
#endif
}

bool AuxiliaryProcess::dispatchMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (m_messageReceiverMap.dispatchMessage(connection, decoder))
        return true;
    // Note: because WebProcess receives messages to non-existing IDs, we have to filter the messages there to avoid asserts.
    // Once these stop, this should be removed.
    return filterUnhandledMessage(connection, decoder);
}

bool AuxiliaryProcess::filterUnhandledMessage(IPC::Connection&, IPC::Decoder&)
{
    return false;
}

bool AuxiliaryProcess::dispatchSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
    return m_messageReceiverMap.dispatchSyncMessage(connection, decoder, replyEncoder);
}

void AuxiliaryProcess::addMessageReceiver(IPC::ReceiverName messageReceiverName, IPC::MessageReceiver& messageReceiver)
{
    m_messageReceiverMap.addMessageReceiver(messageReceiverName, messageReceiver);
}

void AuxiliaryProcess::addMessageReceiver(IPC::ReceiverName messageReceiverName, uint64_t destinationID, IPC::MessageReceiver& messageReceiver)
{
    m_messageReceiverMap.addMessageReceiver(messageReceiverName, destinationID, messageReceiver);
}

void AuxiliaryProcess::removeMessageReceiver(IPC::ReceiverName messageReceiverName, uint64_t destinationID)
{
    m_messageReceiverMap.removeMessageReceiver(messageReceiverName, destinationID);
}

void AuxiliaryProcess::removeMessageReceiver(IPC::ReceiverName messageReceiverName)
{
    m_messageReceiverMap.removeMessageReceiver(messageReceiverName);
}

void AuxiliaryProcess::removeMessageReceiver(IPC::MessageReceiver& messageReceiver)
{
    m_messageReceiverMap.removeMessageReceiver(messageReceiver);
}

void AuxiliaryProcess::disableTermination()
{
    m_terminationCounter++;
}

void AuxiliaryProcess::enableTermination()
{
    ASSERT(m_terminationCounter > 0);
    m_terminationCounter--;

    if (m_terminationCounter || m_isInShutDown)
        return;

    if (shouldTerminate())
        terminate();
}

void AuxiliaryProcess::mainThreadPing(CompletionHandler<void()>&& completionHandler)
{
    completionHandler();
}

IPC::Connection* AuxiliaryProcess::messageSenderConnection() const
{
    return m_connection.get();
}

uint64_t AuxiliaryProcess::messageSenderDestinationID() const
{
    return 0;
}

void AuxiliaryProcess::stopRunLoop()
{
    platformStopRunLoop();
}

#if !PLATFORM(COCOA)
void AuxiliaryProcess::platformStopRunLoop()
{
    RunLoop::mainSingleton().stop();
}
#endif

void AuxiliaryProcess::terminate()
{
    protect(parentProcessConnection())->invalidate();

    stopRunLoop();
}

void AuxiliaryProcess::shutDown()
{
    SetForScope<bool> isInShutDown(m_isInShutDown, true);
    terminate();
}

void AuxiliaryProcess::applyProcessCreationParameters(AuxiliaryProcessCreationParameters&& parameters)
{
#if !LOG_DISABLED || !RELEASE_LOG_DISABLED
    WTF::logChannels().initializeLogChannelsIfNecessary(parameters.wtfLoggingChannels);
    WebCore::logChannels().initializeLogChannelsIfNecessary(parameters.webCoreLoggingChannels);
    WebKit::logChannels().initializeLogChannelsIfNecessary(parameters.webKitLoggingChannels);
#endif
#if PLATFORM(COCOA)
    SecureCoding::applyProcessCreationParameters(WTF::move(parameters));
#endif
#if ENABLE(CORE_IPC_SIGNPOSTS)
    if (parameters.shouldEnableIPCSignposts)
        IPC::Connection::forceEnableSignposts();
    if (parameters.shouldEnableStreamingIPCSignposts)
        IPC::StreamClientConnection::forceEnableSignposts();
#endif
}

void AuxiliaryProcess::grantAccessToContainerTempDirectory(const SandboxExtension::Handle& handle)
{
    SandboxExtension::consumePermanently(handle);
#if ENABLE(LLVM_PROFILE_GENERATION) && PLATFORM(IOS_FAMILY)
    WebKit::initializeLLVMProfiling();
    WebCore::initializeLLVMProfiling();
    JSC::initializeLLVMProfiling();
#endif // ENABLE(LLVM_PROFILE_GENERATION) && PLATFORM(IOS_FAMILY)
}

#if !PLATFORM(IOS_FAMILY) || PLATFORM(MACCATALYST)
void AuxiliaryProcess::populateMobileGestaltCache(std::optional<SandboxExtension::Handle>&&)
{
}
#endif

#if !PLATFORM(COCOA)

void AuxiliaryProcess::initializeSandbox(const AuxiliaryProcessInitializationParameters&, SandboxInitializationParameters&)
{
}

void AuxiliaryProcess::didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName messageName, const Vector<uint32_t>&)
{
    WTFLogAlways("Received invalid message: '%s'", description(messageName).characters());
    CRASH();
}

#if OS(LINUX)
void AuxiliaryProcess::didReceiveMemoryPressureEvent(bool isCritical)
{
    MemoryPressureHandler::singleton().triggerMemoryPressureEvent(isCritical);
}
#endif

#endif // !PLATFORM(COCOA)

} // namespace WebKit
