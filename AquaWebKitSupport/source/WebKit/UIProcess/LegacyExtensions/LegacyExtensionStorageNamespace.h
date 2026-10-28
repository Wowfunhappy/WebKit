/*
 * Copyright (C) 2013-2017 Apple Inc. All rights reserved.
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

#include "StorageNamespaceIdentifier.h"
#include <WebCore/SecurityOriginData.h>
#include <WebCore/SecurityOriginHash.h>
#include <WebCore/StorageArea.h>
#include <WebCore/StorageMap.h>
#include <WebCore/StorageNamespace.h>
#include <WebCore/StorageType.h>
#include <pal/SessionID.h>
#include <wtf/HashMap.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class LegacyExtensionStorageAreaMap;

class LegacyExtensionStorageNamespace final : public WebCore::StorageNamespace, public CanMakeWeakPtr<LegacyExtensionStorageNamespace> {
public:
    using Identifier = StorageNamespaceIdentifier;

    static Ref<LegacyExtensionStorageNamespace> createLocalStorageNamespace(unsigned quotaInBytes);
    static Ref<LegacyExtensionStorageNamespace> createTransientLocalStorageNamespace(WebCore::SecurityOrigin& topLevelOrigin, uint64_t quotaInBytes);

    virtual ~LegacyExtensionStorageNamespace();

    WebCore::StorageType storageType() const { return m_storageType; }
    std::optional<Identifier> storageNamespaceID() const { return std::nullopt; }
    const WebCore::SecurityOrigin* topLevelOrigin() const final { return m_topLevelOrigin.get(); }
    unsigned quotaInBytes() const { return m_quotaInBytes; }
    PAL::SessionID sessionID() const override;

    void destroyStorageAreaMap(LegacyExtensionStorageAreaMap&);

    void setSessionIDForTesting(PAL::SessionID) override;

private:
    LegacyExtensionStorageNamespace(WebCore::StorageType, const WebCore::SecurityOrigin* topLevelOrigin, unsigned quotaInBytes);

    Ref<WebCore::StorageArea> storageArea(const WebCore::SecurityOrigin&) final;
    uint64_t storageAreaMapCountForTesting() const final { return m_storageAreaMaps.size(); }

    Ref<WebCore::StorageNamespace> copy(WebCore::Page&) override;

    const WebCore::StorageType m_storageType;

    // The partition of transient local storage.
    const RefPtr<const WebCore::SecurityOrigin> m_topLevelOrigin;
    const unsigned m_quotaInBytes;

    HashMap<WebCore::SecurityOriginData, Ref<LegacyExtensionStorageAreaMap>> m_storageAreaMaps;
};

} // namespace WebKit
