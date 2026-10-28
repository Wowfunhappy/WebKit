/*
 * Copyright (C) 2013-2025 Apple Inc. All rights reserved.
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
#include "LegacyExtensionStorageAreaMap.h"

#include "Logging.h"

#include "NetworkStorageManagerMessages.h"
#include "LegacyExtensionStorageArea.h"
#include "StorageAreaMapMessages.h"
#include "HandleMessage.h"
#include "LegacyExtensionStorageNamespace.h"

#include "LegacyExtensionViewConnection.h"
#include "LegacyExtensionViewStorage.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/DOMWindow.h>
#include <WebCore/Document.h>
#include <WebCore/EventNames.h>
#include <WebCore/LocalDOMWindow.h>
#include <WebCore/LocalFrameInlines.h>
#include <WebCore/Page.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Storage.h>
#include <WebCore/StorageEventDispatcher.h>
#include <WebCore/StorageMap.h>
#include <WebCore/StorageType.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyExtensionStorageAreaMap);

LegacyExtensionStorageAreaMap::LegacyExtensionStorageAreaMap(LegacyExtensionStorageNamespace& storageNamespace, Ref<const WebCore::SecurityOrigin>&& securityOrigin)
    : m_namespace(storageNamespace)
    , m_securityOrigin(WTF::move(securityOrigin))
    , m_quotaInBytes(storageNamespace.quotaInBytes())
    , m_type(storageNamespace.storageType())
{
    registerLegacyExtensionStorageAreaMap(*this);
}

LegacyExtensionStorageAreaMap::~LegacyExtensionStorageAreaMap()
{
    disconnect();
    unregisterLegacyExtensionStorageAreaMap(*this);
}

unsigned LegacyExtensionStorageAreaMap::length()
{
    return ensureMap().length();
}

String LegacyExtensionStorageAreaMap::key(unsigned index)
{
    return ensureMap().key(index);
}

String LegacyExtensionStorageAreaMap::item(const String& key)
{
    return ensureMap().getItem(key);
}

void LegacyExtensionStorageAreaMap::setItem(LocalFrame& sourceFrame, LegacyExtensionStorageArea* sourceArea, const String& key, const String& value, bool& quotaException)
{
    auto& map = ensureMap();
    ASSERT(!map.isShared());

    String oldValue;
    quotaException = false;
    map.setItem(key, value, oldValue, quotaException);
    if (quotaException)
        return;

    if (oldValue == value)
        return;

    m_pendingValueChanges.add(key);

    if (!m_remoteAreaIdentifier) {
        RELEASE_LOG_ERROR(Storage, "LegacyExtensionStorageAreaMap::setItem failed because storage map ID is invalid");
        return;
    }

    auto callback = [weakThis = WeakPtr { *this }, seed = m_currentSeed, key](bool hasError, auto&& allItems) mutable {
        if (weakThis)
            weakThis->didSetItem(seed, key, hasError, WTF::move(allItems));
    };
    LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkStorageManager::SetItem(*m_remoteAreaIdentifier, sourceArea->identifier(), key, value, protect(sourceFrame.document())->url().string()), WTF::move(callback));
}

void LegacyExtensionStorageAreaMap::removeItem(WebCore::LocalFrame& sourceFrame, LegacyExtensionStorageArea* sourceArea, const String& key)
{
    auto& map = ensureMap();
    ASSERT(!map.isShared());

    String oldValue;
    map.removeItem(key, oldValue);

    if (oldValue.isNull())
        return;

    m_pendingValueChanges.add(key);

    if (!m_remoteAreaIdentifier) {
        RELEASE_LOG_ERROR(Storage, "LegacyExtensionStorageAreaMap::removeItem failed because storage map ID is invalid");
        return;
    }

    auto callback = [weakThis = WeakPtr { *this }, seed = m_currentSeed, key](bool hasError, HashMap<String, String>&& allItems) mutable {
        if (weakThis)
            weakThis->didRemoveItem(seed, key, hasError, WTF::move(allItems));
    };
    LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkStorageManager::RemoveItem(*m_remoteAreaIdentifier, sourceArea->identifier(), key, protect(sourceFrame.document())->url().string()), WTF::move(callback));
}

void LegacyExtensionStorageAreaMap::clear(WebCore::LocalFrame& sourceFrame, LegacyExtensionStorageArea* sourceArea)
{
    ensureMap().clear();
    m_pendingValueChanges.clear();
    ++m_currentSeed;
    m_hasPendingClear = true;

    if (!m_remoteAreaIdentifier) {
        RELEASE_LOG_ERROR(Storage, "LegacyExtensionStorageAreaMap::clear failed because storage map ID is invalid");
        return;
    }

    auto callback = [weakThis = WeakPtr { *this }, seed = m_currentSeed]() mutable {
        if (weakThis)
            weakThis->didClear(seed);
    };
    LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkStorageManager::Clear(*m_remoteAreaIdentifier, sourceArea->identifier(), protect(sourceFrame.document())->url().string()), WTF::move(callback));
}

bool LegacyExtensionStorageAreaMap::contains(const String& key)
{
    return ensureMap().contains(key);
}

StorageMap& LegacyExtensionStorageAreaMap::ensureMap()
{
    connectSync();
    if (!m_map)
        m_map = makeUnique<StorageMap>(m_quotaInBytes);

    return *m_map;
}

void LegacyExtensionStorageAreaMap::didSetItem(uint64_t mapSeed, const String& key, bool hasError, HashMap<String, String>&& remoteItems)
{
    if (m_currentSeed != mapSeed)
        return;

    ASSERT(m_pendingValueChanges.contains(key));
    m_pendingValueChanges.remove(key);

    if (hasError)
        syncItems(WTF::move(remoteItems));
}

void LegacyExtensionStorageAreaMap::didRemoveItem(uint64_t mapSeed, const String& key, bool hasError, HashMap<String, String>&& remoteItems)
{
    if (m_currentSeed != mapSeed)
        return;

    ASSERT(m_pendingValueChanges.contains(key));
    m_pendingValueChanges.remove(key);

    if (hasError)
        syncItems(WTF::move(remoteItems));
}

void LegacyExtensionStorageAreaMap::didClear(uint64_t mapSeed)
{
    if (m_currentSeed != mapSeed)
        return;

    ASSERT(m_hasPendingClear);
    m_hasPendingClear = false;
}

void LegacyExtensionStorageAreaMap::applyChange(const String& key, const String& newValue)
{
    ASSERT(!m_map || !m_map->isShared());

    // A null key means clear.
    if (!key) {
        syncItems(HashMap<String, String> { });
        return;
    }

    syncOneItem(key, newValue);
}

void LegacyExtensionStorageAreaMap::dispatchStorageEvent(const std::optional<StorageAreaImplIdentifier>& storageAreaImplID, const String& key, const String& oldValue, const String& newValue, const String& urlString, uint64_t messageIdentifier)
{
    if (messageIdentifier < m_lastHandledMessageIdentifier)
        return;

    m_lastHandledMessageIdentifier = messageIdentifier;
    if (!storageAreaImplID) {
        // This storage event originates from another process so we need to apply the change to our storage area map.
        applyChange(key, newValue);
    }

    dispatchLocalStorageEvent(storageAreaImplID, key, oldValue, newValue, urlString);
}

void LegacyExtensionStorageAreaMap::clearCache(uint64_t messageIdentifier)
{
    if (messageIdentifier < m_lastHandledMessageIdentifier)
        return;

    m_lastHandledMessageIdentifier = messageIdentifier;
    syncItems(HashMap<String, String> { });
}

void LegacyExtensionStorageAreaMap::dispatchLocalStorageEvent(const std::optional<StorageAreaImplIdentifier>& storageAreaImplID, const String& key, const String& oldValue, const String& newValue, const String& urlString)
{
    ASSERT(isLocalStorage(type()));

    StorageEventDispatcher::dispatchLocalStorageEvents(key, oldValue, newValue, nullptr, m_securityOrigin, urlString, [this, storageAreaImplID](auto& storage) {
        auto iterator = m_areas.find(&storage.area());
        return iterator == m_areas.end() || iterator->value == storageAreaImplID;
    });
}

StorageType LegacyExtensionStorageAreaMap::computeStorageType() const
{
    auto type = m_type;
    if ((type == StorageType::Local || type == StorageType::TransientLocal) && protect(m_namespace)->topLevelOrigin())
        type = StorageType::TransientLocal;

    return type;
}

WebCore::ClientOrigin LegacyExtensionStorageAreaMap::clientOrigin() const
{
    auto originData = m_securityOrigin->data();
    Ref protectedNamespace = m_namespace.get();
    auto topOriginData = protectedNamespace->topLevelOrigin() ? protectedNamespace->topLevelOrigin()->data() : originData;
    return WebCore::ClientOrigin { topOriginData, originData };
}

void LegacyExtensionStorageAreaMap::sendConnectMessage(SendMode mode)
{
    auto namespaceIdentifier = m_namespace->storageNamespaceID();
    auto origin = clientOrigin();
    auto type = computeStorageType();

    if (mode == SendMode::Sync) {
        RefPtr ipcConnection = LegacyExtensionViewConnection::singleton().connection(Site { origin.topOrigin });
        if (!ipcConnection) {
            didConnect(std::nullopt, { }, 0);
            return;
        }
        m_isWaitingForConnectReply = true;
        auto sendResult = ipcConnection->sendSync(Messages::NetworkStorageManager::ConnectToStorageAreaSync(type, identifier(), namespaceIdentifier, origin), 0);
        if (!sendResult.succeeded()) {
            didConnect(std::nullopt, { }, 0);
            return;
        }
        auto [remoteAreaIdentifier, items, messageIdentifier] = sendResult.takeReply();
        didConnect(remoteAreaIdentifier, WTF::move(items), messageIdentifier);
        return;
    }

    Site site { origin.topOrigin };
    LegacyExtensionViewConnection::singleton().whenFirstPartyAllowed(site, [weakThis = WeakPtr { *this }, origin = WTF::move(origin), namespaceIdentifier, type](bool allowed) {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        if (!allowed) {
            protectedThis->didConnect(std::nullopt, { }, 0);
            return;
        }
        protectedThis->m_isWaitingForConnectReply = true;
        auto completionHandler = [weakThis, seed = protectedThis->m_currentSeed](auto remoteAreaIdentifier, auto items, auto messageIdentifier) mutable {
            if (RefPtr map = weakThis.get(); map && seed == map->m_currentSeed)
                map->didConnect(remoteAreaIdentifier, WTF::move(items), messageIdentifier);
        };
        LegacyExtensionViewConnection::singleton().sendWithAsyncReply(Messages::NetworkStorageManager::ConnectToStorageArea(type, protectedThis->identifier(), namespaceIdentifier, origin), WTF::move(completionHandler));
    });
}

void LegacyExtensionStorageAreaMap::connectSync()
{
    if (m_remoteAreaIdentifier)
        return;

    sendConnectMessage(SendMode::Sync);
}

void LegacyExtensionStorageAreaMap::connect()
{
    if (m_remoteAreaIdentifier)
        return;

    sendConnectMessage(SendMode::Async);
}

void LegacyExtensionStorageAreaMap::didConnect(std::optional<StorageAreaIdentifier> remoteAreaIdentifier, HashMap<String, String>&& items, uint64_t messageIdentifier)
{
    m_isWaitingForConnectReply = false;
    if (messageIdentifier < m_lastHandledMessageIdentifier)
        return;

    m_lastHandledMessageIdentifier = messageIdentifier;
    if (!remoteAreaIdentifier)
        return;

    m_remoteAreaIdentifier = *remoteAreaIdentifier;
    m_map = makeUnique<StorageMap>(m_quotaInBytes);
    m_map->importItems(WTF::move(items));
}

void LegacyExtensionStorageAreaMap::disconnect()
{
    if (!m_remoteAreaIdentifier) {
        if (m_isWaitingForConnectReply)
            LegacyExtensionViewConnection::singleton().send(Messages::NetworkStorageManager::CancelConnectToStorageArea(computeStorageType(), m_namespace->storageNamespaceID(), clientOrigin()));

        return;
    }

    if (RefPtr networkProcessConnection = LegacyExtensionViewConnection::singleton().connection(Site { clientOrigin().topOrigin }))
        networkProcessConnection->send(Messages::NetworkStorageManager::DisconnectFromStorageArea(*m_remoteAreaIdentifier), 0);

    m_remoteAreaIdentifier = { };
    m_lastHandledMessageIdentifier = 0;
}

void LegacyExtensionStorageAreaMap::incrementUseCount()
{
    ++m_useCount;
}

void LegacyExtensionStorageAreaMap::decrementUseCount()
{
    if (!--m_useCount)
        protect(m_namespace)->destroyStorageAreaMap(*this);
}

void LegacyExtensionStorageAreaMap::syncOneItem(const String& key, const String& value)
{
    // Once the pending value change request is handled by remote area, this item will be changed.
    if (!m_map || m_pendingValueChanges.contains(key))
        return;

    if (!value) {
        String oldValue;
        m_map->removeItem(key, oldValue);
        return;
    }

    m_map->setItemIgnoringQuota(key, value);
}

void LegacyExtensionStorageAreaMap::syncItems(HashMap<String, String>&& items)
{
    // Once the pending clear request is handled by remote area, these items will be gone.
    if (!m_map || m_hasPendingClear)
        return;

    auto oldMap = std::exchange(m_map, makeUnique<StorageMap>(m_quotaInBytes));
    m_map->importItems(WTF::move(items));
    for (auto change : m_pendingValueChanges) {
        String value = oldMap->getItem(change.key);
        if (!value.isNull())
            m_map->setItemIgnoringQuota(change.key, value);
        else {
            String oldValue;
            m_map->removeItem(change.key, oldValue);
        }
    }
}

void LegacyExtensionStorageAreaMap::addArea(LegacyExtensionStorageArea& area)
{
    m_areas.add(&area, area.identifier());
}

void LegacyExtensionStorageAreaMap::removeArea(LegacyExtensionStorageArea& area)
{
    m_areas.remove(&area);
}

void LegacyExtensionStorageAreaMap::connectionClosed()
{
    m_remoteAreaIdentifier = std::nullopt;
    m_lastHandledMessageIdentifier = 0;
    m_isWaitingForConnectReply = false;
    ++m_currentSeed;
    m_pendingValueChanges.clear();
    m_hasPendingClear = false;
    m_map = nullptr;
}

void LegacyExtensionStorageAreaMap::didReceiveMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageName() == Messages::StorageAreaMap::DispatchStorageEvent::name())
        IPC::handleMessage<Messages::StorageAreaMap::DispatchStorageEvent>(connection, decoder, this, &LegacyExtensionStorageAreaMap::dispatchStorageEvent);
    else if (decoder.messageName() == Messages::StorageAreaMap::ClearCache::name())
        IPC::handleMessage<Messages::StorageAreaMap::ClearCache>(connection, decoder, this, &LegacyExtensionStorageAreaMap::clearCache);
}

} // namespace WebKit
