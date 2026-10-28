#pragma once

namespace IPC {
class Connection;
class Decoder;
}

namespace WebKit {
class LegacyExtensionStorageAreaMap;
class LegacyExtensionFileSystemStorageConnection;
void registerLegacyExtensionStorageAreaMap(LegacyExtensionStorageAreaMap&);
void unregisterLegacyExtensionStorageAreaMap(LegacyExtensionStorageAreaMap&);
LegacyExtensionFileSystemStorageConnection& legacyExtensionFileSystemStorageConnection();
void installLegacyExtensionViewStorage();
bool dispatchLegacyExtensionViewStorageMessage(IPC::Connection&, IPC::Decoder&);
void legacyExtensionViewStorageConnectionClosed();
void reconnectLegacyExtensionViewStorage();
}
