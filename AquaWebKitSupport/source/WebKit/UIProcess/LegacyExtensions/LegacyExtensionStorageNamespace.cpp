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

#include "config.h"
#include "LegacyExtensionStorageNamespace.h"

#include "LegacyExtensionStorageArea.h"
#include "LegacyExtensionStorageAreaMap.h"
#include <WebCore/SecurityOrigin.h>

namespace WebKit {
using namespace WebCore;

Ref<LegacyExtensionStorageNamespace> LegacyExtensionStorageNamespace::createLocalStorageNamespace(unsigned quotaInBytes)
{
    return adoptRef(*new LegacyExtensionStorageNamespace(StorageType::Local, nullptr, quotaInBytes));
}

Ref<LegacyExtensionStorageNamespace> LegacyExtensionStorageNamespace::createTransientLocalStorageNamespace(WebCore::SecurityOrigin& topLevelOrigin, uint64_t quotaInBytes)
{
    return adoptRef(*new LegacyExtensionStorageNamespace(StorageType::TransientLocal, &topLevelOrigin, quotaInBytes));
}

LegacyExtensionStorageNamespace::LegacyExtensionStorageNamespace(WebCore::StorageType storageType, const WebCore::SecurityOrigin* topLevelOrigin, unsigned quotaInBytes)
    : m_storageType(storageType)
    , m_topLevelOrigin(topLevelOrigin)
    , m_quotaInBytes(quotaInBytes)
{
    ASSERT(isLocalStorage(storageType));
}

LegacyExtensionStorageNamespace::~LegacyExtensionStorageNamespace() = default;

PAL::SessionID LegacyExtensionStorageNamespace::sessionID() const
{
    return PAL::SessionID::defaultSessionID();
}

void LegacyExtensionStorageNamespace::destroyStorageAreaMap(LegacyExtensionStorageAreaMap& map)
{
    m_storageAreaMaps.remove(map.securityOrigin().data());
}

Ref<StorageArea> LegacyExtensionStorageNamespace::storageArea(const SecurityOrigin& securityOrigin)
{
    auto& map = m_storageAreaMaps.ensure(securityOrigin.data(), [&] {
        return LegacyExtensionStorageAreaMap::create(*this, securityOrigin);
    }).iterator->value;
    return LegacyExtensionStorageArea::create(map);
}

Ref<StorageNamespace> LegacyExtensionStorageNamespace::copy(Page&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

void LegacyExtensionStorageNamespace::setSessionIDForTesting(PAL::SessionID)
{
    ASSERT_NOT_REACHED();
}

} // namespace WebKit
