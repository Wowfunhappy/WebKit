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

#pragma once

#include "APIObject.h"
#include <WebCore/HistoryItem.h>

namespace API {
class Array;
}

namespace WebKit {

// AQUAWEBKIT: bundle history items retain the WebCore item and expose its cache state.
class InjectedBundleBackForwardListItem : public API::ObjectImpl<API::Object::Type::BundleBackForwardListItem> {
public:
    static Ref<InjectedBundleBackForwardListItem> create(Ref<WebCore::HistoryItem>&& item)
    {
        return adoptRef(*new InjectedBundleBackForwardListItem(WTF::move(item)));
    }

    WebCore::HistoryItem* item() const { return m_item.ptr(); }
    const String& originalURL() const { return m_item->originalURLString(); }
    const String& url() const { return m_item->urlString(); }
    const String& title() const { return m_item->title(); }
    const AtomString& target() const { return m_item->target(); }
    bool isTargetItem() const { return m_item->isTargetItem(); }
    bool isInBackForwardCache() const { return m_item->isInBackForwardCache(); }
    bool hasCachedPageExpired() const { return m_item->hasCachedPageExpired(); }
    Ref<API::Array> children() const;

private:
    explicit InjectedBundleBackForwardListItem(Ref<WebCore::HistoryItem>&& item)
        : m_item(WTF::move(item))
    {
    }

    Ref<WebCore::HistoryItem> m_item;
};

} // namespace WebKit

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::InjectedBundleBackForwardListItem)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::BundleBackForwardListItem; }
SPECIALIZE_TYPE_TRAITS_END()
