/*
 * Copyright (C) 2010-2025 Apple Inc. All rights reserved.
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
#include "IdentifierTypes.h"
#include "WebPageGroupData.h"
#include "WebProcessProxy.h"
#include <WebCore/UserStyleSheetTypes.h>
#include <wtf/CheckedRef.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class WebPreferences;
class WebPageProxy;
class WebUserContentControllerProxy;

class WebPageGroup : public API::ObjectImpl<API::Object::Type::PageGroup>, public CanMakeWeakPtr<WebPageGroup> {
public:
    explicit WebPageGroup(const String& identifier = { });
    static Ref<WebPageGroup> create(const String& identifier = { });
    // 10.9 backport: lookup for PageGroupHandle resolution.
    static RefPtr<WebPageGroup> get(PageGroupIdentifier);

    virtual ~WebPageGroup();

    PageGroupIdentifier pageGroupID() const { return m_data.pageGroupID; }

    const WebPageGroupData& data() const LIFETIME_BOUND { return m_data; }

    WebPreferences& preferences() const { return m_preferences; }
    // 10.9 backport: Safari 7 attaches its own WKPreferences to the page
    // group via WKPageGroupSetPreferences.
    void setPreferences(WebPreferences& preferences) { m_preferences = preferences; }

    // 10.9 backport: the page group's identifier, needed by WKView to scope
    // bundle-injected user content (data().identifier).
    const String& identifier() const LIFETIME_BOUND { return m_data.identifier; }

    // 10.9 backport: restore the page group's user content controller, removed
    // upstream with the page-group user-content model. The legacy WKPageGroup C SPI
    // (WKPageGroupAddUserScript / AddUserStyleSheet / RemoveAll*) and Safari 7-era
    // clients (Mail's MUIWebDocumentViewGroup, QuickLook's Web2.qldisplay) add user
    // scripts and style sheets here; pages created in the group share this controller
    // (WKView seeds the page configuration with it) so the content is injected.
    WebUserContentControllerProxy& userContentController() { return m_userContentController; }

private:
    WebPageGroupData m_data;
    Ref<WebPreferences> m_preferences;
    Ref<WebUserContentControllerProxy> m_userContentController;
};

} // namespace WebKit

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebPageGroup)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::PageGroup; }
SPECIALIZE_TYPE_TRAITS_END()
