#include "config.h"
#include "LegacyExtensionViewStorage.h"

#include "Decoder.h"
#include "LegacyExtensionIDBConnection.h"
#include "LegacyExtensionStorageAreaMap.h"
#include "LegacyExtensionStorageNamespace.h"
#include "LegacyExtensionViewConnection.h"
#include "StorageAreaMapMessages.h"
#include "LegacyExtensionFileSystemStorageConnection.h"
#include "WebFileSystemStorageConnectionMessages.h"
#include "WebIDBConnectionToServerMessages.h"
#include "WebLegacyExtensionPageObserver.h"
#include <WebCore/DatabaseProvider.h>
#include <WebCore/StorageNamespaceProvider.h>
#include <wtf/NeverDestroyed.h>

namespace WebKit {

static HashMap<StorageAreaMapIdentifier, WeakPtr<LegacyExtensionStorageAreaMap>>& storageAreaMaps()
{
    static NeverDestroyed<HashMap<StorageAreaMapIdentifier, WeakPtr<LegacyExtensionStorageAreaMap>>> maps;
    return maps;
}

void registerLegacyExtensionStorageAreaMap(LegacyExtensionStorageAreaMap& map)
{
    storageAreaMaps().add(map.identifier(), map);
}

void unregisterLegacyExtensionStorageAreaMap(LegacyExtensionStorageAreaMap& map)
{
    storageAreaMaps().remove(map.identifier());
}

static RefPtr<LegacyExtensionIDBConnection>& databaseConnection()
{
    static NeverDestroyed<RefPtr<LegacyExtensionIDBConnection>> connection;
    return connection;
}

static RefPtr<LegacyExtensionFileSystemStorageConnection>& fileSystemConnection()
{
    static NeverDestroyed<RefPtr<LegacyExtensionFileSystemStorageConnection>> connection;
    return connection;
}

LegacyExtensionFileSystemStorageConnection& legacyExtensionFileSystemStorageConnection()
{
    if (!fileSystemConnection())
        fileSystemConnection() = LegacyExtensionFileSystemStorageConnection::create();
    return *fileSystemConnection();
}

class LegacyExtensionDatabaseProvider final : public WebCore::DatabaseProvider {
public:
    WebCore::IDBClient::IDBConnectionToServer& idbConnectionToServerForSession(PAL::SessionID sessionID) final
    {
        ASSERT(sessionID == PAL::SessionID::defaultSessionID());
        if (!databaseConnection())
            databaseConnection() = LegacyExtensionIDBConnection::create(sessionID);
        return databaseConnection()->coreConnectionToServer();
    }
};

class LegacyExtensionStorageProvider final : public WebCore::StorageNamespaceProvider {
private:
    Ref<WebCore::StorageNamespace> createLocalStorageNamespace(unsigned quota, PAL::SessionID sessionID) final
    {
        ASSERT_UNUSED(sessionID, sessionID == PAL::SessionID::defaultSessionID());
        return LegacyExtensionStorageNamespace::createLocalStorageNamespace(quota);
    }

    Ref<WebCore::StorageNamespace> createTransientLocalStorageNamespace(WebCore::SecurityOrigin& topOrigin, unsigned quota, PAL::SessionID sessionID) final
    {
        ASSERT_UNUSED(sessionID, sessionID == PAL::SessionID::defaultSessionID());
        return LegacyExtensionStorageNamespace::createTransientLocalStorageNamespace(topOrigin, quota);
    }

    RefPtr<WebCore::StorageNamespace> sessionStorageNamespace(const WebCore::SecurityOrigin&, WebCore::Page&, ShouldCreateNamespace) final
    {
        RELEASE_ASSERT_NOT_REACHED();
    }
};

void installLegacyExtensionViewStorage()
{
    static NeverDestroyed<Ref<LegacyExtensionDatabaseProvider>> databaseProvider = adoptRef(*new LegacyExtensionDatabaseProvider);
    static NeverDestroyed<Ref<LegacyExtensionStorageProvider>> storageProvider = adoptRef(*new LegacyExtensionStorageProvider);
    WebSetLegacyExtensionStorageProviders(databaseProvider.get(), storageProvider.get());
}

bool dispatchLegacyExtensionViewStorageMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageReceiverName() == Messages::StorageAreaMap::messageReceiverName()) {
        if (RefPtr map = storageAreaMaps().get(StorageAreaMapIdentifier { decoder.destinationID() }))
            map->didReceiveMessage(connection, decoder);
        return true;
    }
    if (decoder.messageReceiverName() == Messages::WebIDBConnectionToServer::messageReceiverName()) {
        if (RefPtr database = databaseConnection())
            database->didReceiveMessage(connection, decoder);
        return true;
    }
    if (decoder.messageReceiverName() == Messages::WebFileSystemStorageConnection::messageReceiverName()) {
        if (RefPtr fileSystem = fileSystemConnection())
            fileSystem->didReceiveMessage(connection, decoder);
        return true;
    }
    return false;
}

void legacyExtensionViewStorageConnectionClosed()
{
    for (auto key : copyToVector(storageAreaMaps().keys())) {
        if (RefPtr map = storageAreaMaps().get(key))
            map->connectionClosed();
    }
    if (RefPtr database = std::exchange(databaseConnection(), nullptr))
        database->connectionToServerLost();
    if (RefPtr fileSystem = std::exchange(fileSystemConnection(), nullptr))
        fileSystem->connectionClosed();
}

void reconnectLegacyExtensionViewStorage()
{
    for (auto key : copyToVector(storageAreaMaps().keys())) {
        if (RefPtr map = storageAreaMaps().get(key))
            map->connect();
    }
}

} // namespace WebKit
