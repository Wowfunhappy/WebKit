/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
#include "LegacyExtensionFileSystemStorageConnection.h"

#include "HandleMessage.h"
#include "NetworkStorageManagerMessages.h"
#include "WebFileSystemStorageConnectionMessages.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/FileSystemDirectoryHandle.h>
#include <WebCore/FileSystemFileHandle.h>
#include <WebCore/FileSystemHandleCloseScope.h>
#include <WebCore/ScriptExecutionContext.h>
#include <WebCore/WorkerFileSystemStorageConnection.h>
#include <WebCore/WorkerGlobalScope.h>

namespace WebKit {

Ref<LegacyExtensionFileSystemStorageConnection> LegacyExtensionFileSystemStorageConnection::create()
{
    return adoptRef(*new LegacyExtensionFileSystemStorageConnection);
}

LegacyExtensionFileSystemStorageConnection::LegacyExtensionFileSystemStorageConnection()
    : m_connection(LegacyExtensionViewConnection::singleton())
{
}

void LegacyExtensionFileSystemStorageConnection::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::WebFileSystemStorageConnection::InvalidateAccessHandle::name())
        IPC::handleMessage<Messages::WebFileSystemStorageConnection::InvalidateAccessHandle>(connection, decoder, this, &LegacyExtensionFileSystemStorageConnection::invalidateAccessHandle);
    else if (decoder.messageName() == Messages::WebFileSystemStorageConnection::InvalidateWritable::name())
        IPC::handleMessage<Messages::WebFileSystemStorageConnection::InvalidateWritable>(connection, decoder, this, &LegacyExtensionFileSystemStorageConnection::invalidateWritable);
}

void LegacyExtensionFileSystemStorageConnection::errorWritable(WebCore::ScriptExecutionContextIdentifier contextIdentifier, WebCore::FileSystemWritableFileStreamIdentifier writableIdentifier)
{
    if (errorFileSystemWritable(writableIdentifier))
        return;

    WebCore::ScriptExecutionContext::postTaskTo(contextIdentifier, [writableIdentifier, protectedThis = Ref { *this }](auto& context) mutable {
        RefPtr globalScope = dynamicDowncast<WebCore::WorkerGlobalScope>(context);
        RefPtr connection = globalScope ? globalScope->fileSystemStorageConnection() : nullptr;
        if (connection)
            connection->errorFileSystemWritable(writableIdentifier);
    });
}

void LegacyExtensionFileSystemStorageConnection::connectionClosed()
{
    m_connection = nullptr;

    for (auto identifier : m_syncAccessHandles.keys())
        invalidateAccessHandle(identifier);

    auto writableIdentifiers = std::exchange(m_writableIdentifiers, { });
    for (auto keyValue : writableIdentifiers)
        errorWritable(keyValue.value, keyValue.key);
}

void LegacyExtensionFileSystemStorageConnection::closeHandle(WebCore::FileSystemHandleIdentifier identifier)
{
    RefPtr connection = m_connection;
    if (!connection)
        return;

    connection->send(Messages::NetworkStorageManager::CloseHandle(identifier));
}

void LegacyExtensionFileSystemStorageConnection::isSameEntry(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemHandleIdentifier otherIdentifier, WebCore::FileSystemStorageConnection::SameEntryCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    if (identifier == otherIdentifier)
        return completionHandler(true);

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::IsSameEntry(identifier, otherIdentifier), WTF::move(completionHandler));
}

void LegacyExtensionFileSystemStorageConnection::getFileHandle(WebCore::FileSystemHandleIdentifier identifier, const String& name, bool createIfNecessary, WebCore::FileSystemStorageConnection::GetHandleCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::GetFileHandle(identifier, name, createIfNecessary), [this, protectedThis = Ref { *this }, name, completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        auto& [globalIdentifier, newIdentifier] = result.value();
        completionHandler(WebCore::FileSystemHandleCloseScope::create(globalIdentifier, newIdentifier, WebCore::FileSystemHandleKind::File, *this));
    });
}

void LegacyExtensionFileSystemStorageConnection::getDirectoryHandle(WebCore::FileSystemHandleIdentifier identifier, const String& name, bool createIfNecessary, WebCore::FileSystemStorageConnection::GetHandleCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::GetDirectoryHandle(identifier, name, createIfNecessary), [this, protectedThis = Ref { *this }, name, completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        auto& [globalIdentifier, newIdentifier] = result.value();
        completionHandler(WebCore::FileSystemHandleCloseScope::create(globalIdentifier, newIdentifier, WebCore::FileSystemHandleKind::Directory, *this));
    });
}

void LegacyExtensionFileSystemStorageConnection::removeEntry(WebCore::FileSystemHandleIdentifier identifier, const String& name, bool deleteRecursively, WebCore::FileSystemStorageConnection::VoidCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::RemoveEntry(identifier, name, deleteRecursively), [completionHandler = WTF::move(completionHandler)](auto error) mutable {
        return completionHandler(convertToExceptionOr(error));
    });
}

void LegacyExtensionFileSystemStorageConnection::resolve(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemHandleIdentifier otherIdentifier, WebCore::FileSystemStorageConnection::ResolveCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::Resolve(identifier, otherIdentifier), [completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        completionHandler(WTF::move(result.value()));
    });
}

void LegacyExtensionFileSystemStorageConnection::getFile(WebCore::FileSystemHandleIdentifier identifier, StringCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::GetFile(identifier), [completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        completionHandler(WTF::move(result.value()));
    });
}

void LegacyExtensionFileSystemStorageConnection::createSyncAccessHandle(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemStorageConnection::GetAccessHandleCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::CreateSyncAccessHandle(identifier), [completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        completionHandler(WebCore::FileSystemStorageConnection::SyncAccessHandleInfo { *result->identifier, result->handle.release(), result->capacity });
    });
}

void LegacyExtensionFileSystemStorageConnection::closeSyncAccessHandle(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemSyncAccessHandleIdentifier accessHandleIdentifier, FileSystemStorageConnection::EmptyCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler();

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::CloseSyncAccessHandle(identifier, accessHandleIdentifier), WTF::move(completionHandler));
}

void LegacyExtensionFileSystemStorageConnection::getHandleNames(WebCore::FileSystemHandleIdentifier identifier, FileSystemStorageConnection::GetHandleNamesCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::GetHandleNames(identifier), [completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        completionHandler(WTF::move(result.value()));
    });
}

void LegacyExtensionFileSystemStorageConnection::getHandle(WebCore::FileSystemHandleIdentifier identifier, const String& name, FileSystemStorageConnection::GetHandleCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::GetHandle(identifier, name), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        auto& info = *result.value();
        completionHandler(WebCore::FileSystemHandleCloseScope::create(info.globalIdentifier, info.identifier, info.kind, *this));
    });
}

void LegacyExtensionFileSystemStorageConnection::addGlobalIdentifierReference(WebCore::ClientOrigin&& origin, WebCore::FileSystemHandleGlobalIdentifier globalIdentifier)
{
    if (RefPtr connection = m_connection)
        connection->send(Messages::NetworkStorageManager::AddGlobalIdentifierReference(origin, globalIdentifier));
}

void LegacyExtensionFileSystemStorageConnection::removeGlobalIdentifierReferences(WebCore::ClientOrigin&& origin, Vector<WebCore::FileSystemHandleGlobalIdentifier>&& globalIdentifiers)
{
    if (globalIdentifiers.isEmpty())
        return;
    if (RefPtr connection = m_connection)
        connection->send(Messages::NetworkStorageManager::RemoveGlobalIdentifierReferences(WTF::move(origin), WTF::move(globalIdentifiers)));
}

void LegacyExtensionFileSystemStorageConnection::resolveGlobalIdentifier(WebCore::ClientOrigin&& origin, WebCore::FileSystemHandleGlobalIdentifier globalIdentifier, ResolveGlobalIdentifierCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::ResolveGlobalIdentifier(origin, globalIdentifier), [completionHandler = WTF::move(completionHandler)](auto result) mutable {
        if (!result)
            return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Failed to resolve handle's global identifier"_s });

        completionHandler(WTF::move(result.value()));
    });
}

void LegacyExtensionFileSystemStorageConnection::move(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemHandleIdentifier destinationIdentifier, const String& newName, VoidCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::Move(identifier, destinationIdentifier, newName), [completionHandler = WTF::move(completionHandler)](auto error) mutable {
        completionHandler(convertToExceptionOr(error));
    });
}

void LegacyExtensionFileSystemStorageConnection::registerSyncAccessHandle(WebCore::FileSystemSyncAccessHandleIdentifier identifier, WebCore::ScriptExecutionContextIdentifier contextIdentifier)
{
    m_syncAccessHandles.add(identifier, contextIdentifier);
}

void LegacyExtensionFileSystemStorageConnection::unregisterSyncAccessHandle(WebCore::FileSystemSyncAccessHandleIdentifier identifier)
{
    m_syncAccessHandles.remove(identifier);
}

void LegacyExtensionFileSystemStorageConnection::invalidateAccessHandle(WebCore::FileSystemSyncAccessHandleIdentifier identifier)
{
    if (auto contextIdentifier = m_syncAccessHandles.get(identifier)) {
        WebCore::ScriptExecutionContext::postTaskTo(contextIdentifier, [identifier](auto& context) mutable {
            // FIXME: We should not have to list FileSystemStorageConnection here.
            if (RefPtr<FileSystemStorageConnection> connection = downcast<WebCore::WorkerGlobalScope>(context).fileSystemStorageConnection())
                connection->invalidateAccessHandle(identifier);
        });
    }
}

void LegacyExtensionFileSystemStorageConnection::createWritable(WebCore::ScriptExecutionContextIdentifier contextIdentifier, WebCore::FileSystemHandleIdentifier identifier, bool keepExistingData, StreamCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::CreateWritable(identifier, keepExistingData), [protectedThis = Ref { *this }, contextIdentifier, completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
        if (!result)
            return completionHandler(convertToException(result.error()));

        ASSERT(!protectedThis->m_writableIdentifiers.contains(result.value()));
        protectedThis->m_writableIdentifiers.add(result.value(), contextIdentifier);
        completionHandler(WTF::move(result.value()));
    });
}

void LegacyExtensionFileSystemStorageConnection::invalidateWritable(WebCore::FileSystemWritableFileStreamIdentifier identifier)
{
    if (auto contextIdentifier = m_writableIdentifiers.take(identifier))
        errorWritable(contextIdentifier, identifier);
}

void LegacyExtensionFileSystemStorageConnection::closeWritable(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemWritableFileStreamIdentifier streamIdentifier, WebCore::FileSystemWriteCloseReason reason, VoidCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    m_writableIdentifiers.remove(streamIdentifier);
    connection->sendWithAsyncReply(Messages::NetworkStorageManager::CloseWritable(identifier, streamIdentifier, reason), [completionHandler = WTF::move(completionHandler)](auto error) mutable {
        completionHandler(convertToExceptionOr(error));
    });
}

void LegacyExtensionFileSystemStorageConnection::executeCommandForWritable(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemWritableFileStreamIdentifier streamIdentifier, WebCore::FileSystemWriteCommandType type, std::optional<uint64_t> position, std::optional<uint64_t> size, std::span<const uint8_t> dataBytes, bool hasDataError, VoidCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(WebCore::Exception { WebCore::ExceptionCode::UnknownError, "Connection is lost"_s });

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::ExecuteCommandForWritable(identifier, streamIdentifier, type, position, size, dataBytes, hasDataError), [completionHandler = WTF::move(completionHandler)](auto error) mutable {
        completionHandler(convertToExceptionOr(error));
    });
}

void LegacyExtensionFileSystemStorageConnection::requestNewCapacityForSyncAccessHandle(WebCore::FileSystemHandleIdentifier identifier, WebCore::FileSystemSyncAccessHandleIdentifier accessHandleIdentifier, uint64_t newCapacity, RequestCapacityCallback&& completionHandler)
{
    RefPtr connection = m_connection;
    if (!connection)
        return completionHandler(std::nullopt);

    connection->sendWithAsyncReply(Messages::NetworkStorageManager::RequestNewCapacityForSyncAccessHandle(identifier, accessHandleIdentifier, newCapacity), WTF::move(completionHandler));
}

} // namespace WebKit
