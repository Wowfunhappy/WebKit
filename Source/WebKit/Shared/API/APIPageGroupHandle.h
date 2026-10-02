/*
 * Copyright (C) 2014 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
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

// MAVERICKS_BACKPORT: the handle a page group crosses the UI<->WebContent boundary as, inside
// UserData. Safari 7 places its browsing WKPageGroup in the injected-bundle initialization user
// data and in bundle messages; WebProcessProxy::transformObjectsToHandles turns the WebPageGroup
// into this handle before encoding, and WebProcess::transformHandlesToObjects resolves it to the
// WebPageGroupProxy on decode. The base has no such class.

#pragma once

#include "APIObject.h"
#include "WebPageGroupData.h"

namespace API {

class PageGroupHandle final : public ObjectImpl<Object::Type::PageGroupHandle> {
public:
    static Ref<PageGroupHandle> create(WebKit::WebPageGroupData&& data)
    {
        return adoptRef(*new PageGroupHandle(WTF::move(data)));
    }

    const WebKit::WebPageGroupData& pageGroupData() const LIFETIME_BOUND { return m_data; }

private:
    explicit PageGroupHandle(WebKit::WebPageGroupData&& data)
        : m_data(WTF::move(data))
    {
    }

    WebKit::WebPageGroupData m_data;
};

} // namespace API

SPECIALIZE_TYPE_TRAITS_API_OBJECT(PageGroupHandle);
