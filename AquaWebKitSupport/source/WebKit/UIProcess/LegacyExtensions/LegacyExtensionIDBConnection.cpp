/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
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
#include "LegacyExtensionIDBConnection.h"

#include "HandleMessage.h"
#include "WebIDBConnectionToServerMessages.h"
#include "NetworkConnectionToWebProcessMessages.h"

#include "NetworkStorageManagerMessages.h"
#include "LegacyExtensionFileSystemStorageConnection.h"
#include "WebIDBResult.h"
#include "LegacyExtensionViewConnection.h"
#include "LegacyExtensionViewStorage.h"
#include <WebCore/FileSystemHandleStorageKeepAlive.h>
#include <WebCore/FileSystemHandleRecord.h>
#include <WebCore/BlobURL.h>
#include <wtf/FileSystem.h>
#include <WebCore/IDBConnectionToServer.h>
#include <WebCore/IDBCursorInfo.h>
#include <WebCore/IDBError.h>
#include <WebCore/IDBIndexInfo.h>
#include <WebCore/IDBIterateCursorData.h>
#include <WebCore/IDBKeyRangeData.h>
#include <WebCore/IDBObjectStoreInfo.h>
#include <WebCore/IDBOpenDBRequest.h>
#include <WebCore/IDBOpenRequestData.h>
#include <WebCore/IDBRequestData.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IDBResultData.h>
#include <WebCore/IDBTransactionInfo.h>
#include <WebCore/IDBValue.h>
#include <WebCore/ProcessIdentifier.h>

namespace WebKit {
using namespace WebCore;

Ref<LegacyExtensionIDBConnection> LegacyExtensionIDBConnection::create(PAL::SessionID sessionID)
{
    return adoptRef(*new LegacyExtensionIDBConnection(sessionID));
}

LegacyExtensionIDBConnection::LegacyExtensionIDBConnection(PAL::SessionID sessionID)
{
    relaxAdoptionRequirement();
    lazyInitialize(m_connectionToServer, IDBClient::IDBConnectionToServer::create(*this, sessionID));
}

LegacyExtensionIDBConnection::~LegacyExtensionIDBConnection() = default;

std::optional<IDBConnectionIdentifier> LegacyExtensionIDBConnection::identifier() const
{
    return Process::identifier();
}

IDBClient::IDBConnectionToServer& LegacyExtensionIDBConnection::coreConnectionToServer()
{
    return *m_connectionToServer;
}

void LegacyExtensionIDBConnection::deleteDatabase(const IDBOpenRequestData& requestData)
{
    LegacyExtensionViewConnection::singleton().sendForOrigin(Messages::NetworkStorageManager::DeleteDatabase(requestData), Site { requestData.databaseIdentifier().origin().topOrigin });
}

void LegacyExtensionIDBConnection::openDatabase(const IDBOpenRequestData& requestData)
{
    LegacyExtensionViewConnection::singleton().sendForOrigin(Messages::NetworkStorageManager::OpenDatabase(requestData), Site { requestData.databaseIdentifier().origin().topOrigin });
}

void LegacyExtensionIDBConnection::abortTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    send(Messages::NetworkStorageManager::AbortTransaction(transactionIdentifier));
}

void LegacyExtensionIDBConnection::commitTransaction(const IDBResourceIdentifier& transactionIdentifier, uint64_t handledRequestResultsCount)
{
    send(Messages::NetworkStorageManager::CommitTransaction(transactionIdentifier, handledRequestResultsCount));
}

void LegacyExtensionIDBConnection::didFinishHandlingVersionChangeTransaction(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBResourceIdentifier& transactionIdentifier)
{
    send(Messages::NetworkStorageManager::DidFinishHandlingVersionChangeTransaction(databaseConnectionIdentifier, transactionIdentifier));
}

void LegacyExtensionIDBConnection::createObjectStore(const IDBRequestData& requestData, const IDBObjectStoreInfo& info)
{
    send(Messages::NetworkStorageManager::CreateObjectStore(requestData, info));
}

void LegacyExtensionIDBConnection::deleteObjectStore(const IDBRequestData& requestData, const String& objectStoreName)
{
    send(Messages::NetworkStorageManager::DeleteObjectStore(requestData, objectStoreName));
}

void LegacyExtensionIDBConnection::renameObjectStore(const IDBRequestData& requestData, WebCore::IDBObjectStoreIdentifier objectStoreIdentifier, const String& newName)
{
    send(Messages::NetworkStorageManager::RenameObjectStore(requestData, objectStoreIdentifier, newName));
}

void LegacyExtensionIDBConnection::clearObjectStore(const IDBRequestData& requestData, WebCore::IDBObjectStoreIdentifier objectStoreIdentifier)
{
    send(Messages::NetworkStorageManager::ClearObjectStore(requestData, objectStoreIdentifier));
}

void LegacyExtensionIDBConnection::createIndex(const IDBRequestData& requestData, const IDBIndexInfo& info)
{
    send(Messages::NetworkStorageManager::CreateIndex(requestData, info));
}

void LegacyExtensionIDBConnection::deleteIndex(const IDBRequestData& requestData, WebCore::IDBObjectStoreIdentifier objectStoreIdentifier, const String& indexName)
{
    send(Messages::NetworkStorageManager::DeleteIndex(requestData, objectStoreIdentifier, indexName));
}

void LegacyExtensionIDBConnection::renameIndex(const IDBRequestData& requestData, WebCore::IDBObjectStoreIdentifier objectStoreIdentifier, WebCore::IDBIndexIdentifier indexIdentifier, const String& newName)
{
    send(Messages::NetworkStorageManager::RenameIndex(requestData, objectStoreIdentifier, indexIdentifier, newName));
}

void LegacyExtensionIDBConnection::putOrAdd(const IDBRequestData& requestData, const IDBKeyData& keyData, const IDBValue& value, const IndexIDToIndexKeyMap& indexKeys, const IndexedDB::ObjectStoreOverwriteMode mode)
{
    if (value.blobFilePaths().isEmpty()) {
        send(Messages::NetworkStorageManager::PutOrAdd(requestData, keyData, value, indexKeys, mode));
        return;
    }
    enqueue([this, requestData = requestData.isolatedCopy(), keyData = keyData.isolatedCopy(), value = value.isolatedCopy(), indexKeys = indexKeys, mode]() mutable {
        prepareBlobFiles(WTF::move(requestData), WTF::move(keyData), WTF::move(value), WTF::move(indexKeys), mode);
    });
}

void LegacyExtensionIDBConnection::getRecord(const IDBRequestData& requestData, const IDBGetRecordData& getRecordData)
{
    send(Messages::NetworkStorageManager::GetRecord(requestData, getRecordData));
}

void LegacyExtensionIDBConnection::getAllRecords(const IDBRequestData& requestData, const IDBGetAllRecordsData& getAllRecordsData)
{
    send(Messages::NetworkStorageManager::GetAllRecords(requestData, getAllRecordsData));
}

void LegacyExtensionIDBConnection::getCount(const IDBRequestData& requestData, const IDBKeyRangeData& range)
{
    send(Messages::NetworkStorageManager::GetCount(requestData, range));
}

void LegacyExtensionIDBConnection::deleteRecord(const IDBRequestData& requestData, const IDBKeyRangeData& range)
{
    send(Messages::NetworkStorageManager::DeleteRecord(requestData, range));
}

void LegacyExtensionIDBConnection::openCursor(const IDBRequestData& requestData, const IDBCursorInfo& info)
{
    send(Messages::NetworkStorageManager::OpenCursor(requestData, info));
}

void LegacyExtensionIDBConnection::iterateCursor(const IDBRequestData& requestData, const IDBIterateCursorData& data)
{
    send(Messages::NetworkStorageManager::IterateCursor(requestData, data));
}

void LegacyExtensionIDBConnection::establishTransaction(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBTransactionInfo& info)
{
    send(Messages::NetworkStorageManager::EstablishTransaction(databaseConnectionIdentifier, info));
}

void LegacyExtensionIDBConnection::databaseConnectionPendingClose(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier)
{
    send(Messages::NetworkStorageManager::DatabaseConnectionPendingClose(databaseConnectionIdentifier));
}

void LegacyExtensionIDBConnection::databaseConnectionClosed(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier)
{
    send(Messages::NetworkStorageManager::DatabaseConnectionClosed(databaseConnectionIdentifier));
}

void LegacyExtensionIDBConnection::abortOpenAndUpgradeNeeded(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const std::optional<IDBResourceIdentifier>& transactionIdentifier)
{
    send(Messages::NetworkStorageManager::AbortOpenAndUpgradeNeeded(databaseConnectionIdentifier, transactionIdentifier));
}

void LegacyExtensionIDBConnection::didFireVersionChangeEvent(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBResourceIdentifier& requestIdentifier, const IndexedDB::ConnectionClosedOnBehalfOfServer connectionClosed)
{
    send(Messages::NetworkStorageManager::DidFireVersionChangeEvent(databaseConnectionIdentifier, requestIdentifier, connectionClosed));
}

void LegacyExtensionIDBConnection::didGenerateIndexKeyForRecord(const WebCore::IDBResourceIdentifier& transactionIdentifier, const WebCore::IDBResourceIdentifier& requestIdentifier, const WebCore::IDBIndexInfo& indexInfo, const WebCore::IDBKeyData& key, const WebCore::IndexKey& indexKey, std::optional<int64_t> recordID)
{
    send(Messages::NetworkStorageManager::DidGenerateIndexKeyForRecord(transactionIdentifier, requestIdentifier, indexInfo, key, indexKey, recordID));
}

void LegacyExtensionIDBConnection::openDBRequestCancelled(const IDBOpenRequestData& requestData)
{
    LegacyExtensionViewConnection::singleton().sendForOrigin(Messages::NetworkStorageManager::OpenDBRequestCancelled(requestData), Site { requestData.databaseIdentifier().origin().topOrigin });
}

void LegacyExtensionIDBConnection::getAllDatabaseNamesAndVersions(const IDBResourceIdentifier& requestIdentifier, const ClientOrigin& origin)
{
    LegacyExtensionViewConnection::singleton().sendForOrigin(Messages::NetworkStorageManager::GetAllDatabaseNamesAndVersions(requestIdentifier, origin), Site { origin.topOrigin });
}

void LegacyExtensionIDBConnection::didDeleteDatabase(const IDBResultData& result)
{
    m_connectionToServer->didDeleteDatabase(result);
}

void LegacyExtensionIDBConnection::didOpenDatabase(const IDBResultData& result)
{
    m_connectionToServer->didOpenDatabase(result);
}

void LegacyExtensionIDBConnection::didAbortTransaction(const IDBResourceIdentifier& transactionIdentifier, const IDBError& error)
{
    m_connectionToServer->didAbortTransaction(transactionIdentifier, error);
}

void LegacyExtensionIDBConnection::didCommitTransaction(const IDBResourceIdentifier& transactionIdentifier, const IDBError& error)
{
    m_connectionToServer->didCommitTransaction(transactionIdentifier, error);
}

void LegacyExtensionIDBConnection::didCreateObjectStore(const IDBResultData& result)
{
    m_connectionToServer->didCreateObjectStore(result);
}

void LegacyExtensionIDBConnection::didDeleteObjectStore(const IDBResultData& result)
{
    m_connectionToServer->didDeleteObjectStore(result);
}

void LegacyExtensionIDBConnection::didRenameObjectStore(const IDBResultData& result)
{
    m_connectionToServer->didRenameObjectStore(result);
}

void LegacyExtensionIDBConnection::didClearObjectStore(const IDBResultData& result)
{
    m_connectionToServer->didClearObjectStore(result);
}

void LegacyExtensionIDBConnection::didCreateIndex(const IDBResultData& result)
{
    m_connectionToServer->didCreateIndex(result);
}

void LegacyExtensionIDBConnection::didDeleteIndex(const IDBResultData& result)
{
    m_connectionToServer->didDeleteIndex(result);
}

void LegacyExtensionIDBConnection::didRenameIndex(const IDBResultData& result)
{
    m_connectionToServer->didRenameIndex(result);
}

void LegacyExtensionIDBConnection::didPutOrAdd(const IDBResultData& result)
{
    m_connectionToServer->didPutOrAdd(result);
}

void LegacyExtensionIDBConnection::didGetRecord(const WebIDBResult& result)
{
    if (result.clientOrigin())
        attachStorageKeepAliveIfNeeded(result, result.resultData().getResult().value());
    m_connectionToServer->didGetRecord(result.resultData());
}

void LegacyExtensionIDBConnection::didGetAllRecords(const WebIDBResult& result)
{
    if (result.clientOrigin()) {
        for (auto& value : result.resultData().getAllResult().values())
            attachStorageKeepAliveIfNeeded(result, value);
    }
    m_connectionToServer->didGetAllRecords(result.resultData());
}

void LegacyExtensionIDBConnection::didGetCount(const IDBResultData& result)
{
    m_connectionToServer->didGetCount(result);
}

void LegacyExtensionIDBConnection::didDeleteRecord(const IDBResultData& result)
{
    m_connectionToServer->didDeleteRecord(result);
}

void LegacyExtensionIDBConnection::didOpenCursor(const WebIDBResult& result)
{
    if (result.clientOrigin()) {
        attachStorageKeepAliveIfNeeded(result, result.resultData().getResult().value());
        for (auto& cursorRecord : result.resultData().getResult().prefetchedRecords())
            attachStorageKeepAliveIfNeeded(result, cursorRecord.value);
    }
    m_connectionToServer->didOpenCursor(result.resultData());
}

void LegacyExtensionIDBConnection::didIterateCursor(const WebIDBResult& result)
{
    if (result.clientOrigin()) {
        attachStorageKeepAliveIfNeeded(result, result.resultData().getResult().value());
        for (auto& cursorRecord : result.resultData().getResult().prefetchedRecords())
            attachStorageKeepAliveIfNeeded(result, cursorRecord.value);
    }
    m_connectionToServer->didIterateCursor(result.resultData());
}

void LegacyExtensionIDBConnection::attachStorageKeepAliveIfNeeded(const WebIDBResult& result, const IDBValue& value)
{
    if (value.fileSystemHandleGlobalIdentifiers().isEmpty() || !result.clientOrigin())
        return;
    value.attachStorageKeepAlive(FileSystemHandleStorageKeepAlive::create(
        ClientOrigin { *result.clientOrigin() },
        Vector { value.fileSystemHandleGlobalIdentifiers() },
        Ref { legacyExtensionFileSystemStorageConnection() }));
}

void LegacyExtensionIDBConnection::fireVersionChangeEvent(IDBDatabaseConnectionIdentifier uniqueDatabaseConnectionIdentifier, const IDBResourceIdentifier& requestIdentifier, uint64_t requestedVersion)
{
    m_connectionToServer->fireVersionChangeEvent(uniqueDatabaseConnectionIdentifier, requestIdentifier, requestedVersion);
}

void LegacyExtensionIDBConnection::generateIndexKeyForRecord(const WebCore::IDBResourceIdentifier& requestIdentifier, const WebCore::IDBIndexInfo& indexInfo, const std::optional<WebCore::IDBKeyPath>& keyPath, const WebCore::IDBKeyData& key, const WebCore::IDBValue& value, std::optional<int64_t> recordID)
{
    m_connectionToServer->generateIndexKeyForRecord(requestIdentifier, indexInfo, keyPath, key, value, recordID);
}

void LegacyExtensionIDBConnection::didStartTransaction(const IDBResourceIdentifier& transactionIdentifier, const IDBError& error)
{
    m_connectionToServer->didStartTransaction(transactionIdentifier, error);
}

void LegacyExtensionIDBConnection::didCloseFromServer(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBError& error)
{
    m_connectionToServer->didCloseFromServer(databaseConnectionIdentifier, error);
}

void LegacyExtensionIDBConnection::notifyOpenDBRequestBlocked(const IDBResourceIdentifier& requestIdentifier, uint64_t oldVersion, uint64_t newVersion)
{
    m_connectionToServer->notifyOpenDBRequestBlocked(requestIdentifier, oldVersion, newVersion);
}

void LegacyExtensionIDBConnection::didGetAllDatabaseNamesAndVersions(const IDBResourceIdentifier& requestIdentifier, Vector<IDBDatabaseNameAndVersion>&& databases)
{
    m_connectionToServer->didGetAllDatabaseNamesAndVersions(requestIdentifier, WTF::move(databases));
}

void LegacyExtensionIDBConnection::connectionToServerLost()
{
    m_connectionToServer->connectionToServerLost(IDBError { ExceptionCode::UnknownError, "An internal error was encountered in the Indexed Database server"_s });
}

void LegacyExtensionIDBConnection::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidDeleteDatabase::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidDeleteDatabase>(connection, decoder, this, &LegacyExtensionIDBConnection::didDeleteDatabase);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidOpenDatabase::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidOpenDatabase>(connection, decoder, this, &LegacyExtensionIDBConnection::didOpenDatabase);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidAbortTransaction::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidAbortTransaction>(connection, decoder, this, &LegacyExtensionIDBConnection::didAbortTransaction);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidCommitTransaction::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidCommitTransaction>(connection, decoder, this, &LegacyExtensionIDBConnection::didCommitTransaction);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidCreateObjectStore::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidCreateObjectStore>(connection, decoder, this, &LegacyExtensionIDBConnection::didCreateObjectStore);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidDeleteObjectStore::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidDeleteObjectStore>(connection, decoder, this, &LegacyExtensionIDBConnection::didDeleteObjectStore);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidRenameObjectStore::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidRenameObjectStore>(connection, decoder, this, &LegacyExtensionIDBConnection::didRenameObjectStore);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidClearObjectStore::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidClearObjectStore>(connection, decoder, this, &LegacyExtensionIDBConnection::didClearObjectStore);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidCreateIndex::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidCreateIndex>(connection, decoder, this, &LegacyExtensionIDBConnection::didCreateIndex);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidDeleteIndex::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidDeleteIndex>(connection, decoder, this, &LegacyExtensionIDBConnection::didDeleteIndex);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidRenameIndex::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidRenameIndex>(connection, decoder, this, &LegacyExtensionIDBConnection::didRenameIndex);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidPutOrAdd::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidPutOrAdd>(connection, decoder, this, &LegacyExtensionIDBConnection::didPutOrAdd);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidGetRecord::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidGetRecord>(connection, decoder, this, &LegacyExtensionIDBConnection::didGetRecord);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidGetAllRecords::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidGetAllRecords>(connection, decoder, this, &LegacyExtensionIDBConnection::didGetAllRecords);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidGetCount::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidGetCount>(connection, decoder, this, &LegacyExtensionIDBConnection::didGetCount);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidDeleteRecord::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidDeleteRecord>(connection, decoder, this, &LegacyExtensionIDBConnection::didDeleteRecord);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidOpenCursor::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidOpenCursor>(connection, decoder, this, &LegacyExtensionIDBConnection::didOpenCursor);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidIterateCursor::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidIterateCursor>(connection, decoder, this, &LegacyExtensionIDBConnection::didIterateCursor);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::FireVersionChangeEvent::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::FireVersionChangeEvent>(connection, decoder, this, &LegacyExtensionIDBConnection::fireVersionChangeEvent);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::GenerateIndexKeyForRecord::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::GenerateIndexKeyForRecord>(connection, decoder, this, &LegacyExtensionIDBConnection::generateIndexKeyForRecord);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidStartTransaction::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidStartTransaction>(connection, decoder, this, &LegacyExtensionIDBConnection::didStartTransaction);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidCloseFromServer::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidCloseFromServer>(connection, decoder, this, &LegacyExtensionIDBConnection::didCloseFromServer);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::NotifyOpenDBRequestBlocked::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::NotifyOpenDBRequestBlocked>(connection, decoder, this, &LegacyExtensionIDBConnection::notifyOpenDBRequestBlocked);
    else if (decoder.messageName() == Messages::WebIDBConnectionToServer::DidGetAllDatabaseNamesAndVersions::name())
        IPC::handleMessage<Messages::WebIDBConnectionToServer::DidGetAllDatabaseNamesAndVersions>(connection, decoder, this, &LegacyExtensionIDBConnection::didGetAllDatabaseNamesAndVersions);
}

void LegacyExtensionIDBConnection::enqueue(Function<void()>&& message)
{
    m_pendingMessages.append(WTF::move(message));
    dispatchPendingMessages();
}

void LegacyExtensionIDBConnection::dispatchPendingMessages()
{
    while (!m_isPreparingBlobs && !m_pendingMessages.isEmpty())
        m_pendingMessages.takeFirst()();
}

// WK1's BlobRegistry prepares local temporary files. The network BlobRegistry creates and registers
// the files owned by this IDB connection, using the same handoff as BlobRegistryProxy.
void LegacyExtensionIDBConnection::prepareBlobFiles(IDBRequestData&& requestData, IDBKeyData&& keyData, IDBValue&& value, IndexIDToIndexKeyMap&& indexKeys, IndexedDB::ObjectStoreOverwriteMode mode)
{
    if (!m_connectionToServer->isValid()) {
        for (auto& path : value.blobFilePaths())
            FileSystem::deleteFile(path);
        return;
    }
    m_isPreparingBlobs = true;
    auto paths = value.blobFilePaths();
    LegacyExtensionViewConnection::singleton().allowFilesAccess(paths, [this, protectedThis = Ref { *this }, requestData = WTF::move(requestData), keyData = WTF::move(keyData), value = WTF::move(value), indexKeys = WTF::move(indexKeys), mode]() mutable {
        if (!m_connectionToServer->isValid()) {
            for (auto& path : value.blobFilePaths())
                FileSystem::deleteFile(path);
            m_isPreparingBlobs = false;
            dispatchPendingMessages();
            return;
        }
        Vector<String> urls;
        for (auto& path : value.blobFilePaths()) {
            auto url = BlobURL::createInternalURL();
            urls.append(url.string());
            auto handle = SandboxExtension::createHandle(path, SandboxExtension::Type::ReadOnly);
            LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::RegisterInternalFileBlobURL(url, path, nullString(), handle ? WTF::move(*handle) : SandboxExtension::Handle { }, emptyString()));
        }
        auto registeredURLs = urls;
        LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkConnectionToWebProcess::WriteBlobsToTemporaryFilesForIndexedDB(urls), [this, protectedThis = WTF::move(protectedThis), urls = WTF::move(registeredURLs), requestData = WTF::move(requestData), keyData = WTF::move(keyData), value = WTF::move(value), indexKeys = WTF::move(indexKeys), mode](Vector<String>&& paths) mutable {
            if (m_connectionToServer->isValid()) {
                for (auto& url : urls)
                    LegacyExtensionViewConnection::singleton().send(Messages::NetworkConnectionToWebProcess::UnregisterBlobURL(URL { url }, std::nullopt));
            }
            for (auto& path : value.blobFilePaths())
                FileSystem::deleteFile(path);
            if (m_connectionToServer->isValid()) {
                if (paths.size() == value.blobURLs().size()) {
                    IDBValue networkValue { value.data(), Vector { value.blobURLs() }, WTF::move(paths), Vector { value.fileSystemHandleGlobalIdentifiers() } };
                    networkValue.setFileSystemHandleRecords(Vector { value.fileSystemHandleRecords() });
                    LegacyExtensionViewConnection::singleton().send(Messages::NetworkStorageManager::PutOrAdd(requestData, keyData, networkValue, indexKeys, mode));
                } else
                    m_connectionToServer->didPutOrAdd(IDBResultData::error(requestData.requestIdentifier(), IDBError { ExceptionCode::UnknownError, "Error preparing Blob/File data to be stored in object store"_s }));
            }
            m_isPreparingBlobs = false;
            dispatchPendingMessages();
        });
    });
}

} // namespace WebKit
