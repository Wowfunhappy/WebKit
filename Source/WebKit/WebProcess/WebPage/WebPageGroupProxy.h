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
#include "StorageNamespaceIdentifier.h"
#include "WebPageGroupData.h"
#include <wtf/Ref.h>

namespace WebCore {
class PageGroup;
}

namespace WebKit {

class WebUserContentController;

// MAVERICKS_BACKPORT: API::ObjectImpl base restored (was RefCounted) so the page
// group can travel through the legacy C API again (WKBundlePageGetPageGroup /
// WKBundleAddUserScript — Safari 7 extension content-script injection).
class WebPageGroupProxy : public API::ObjectImpl<API::Object::Type::BundlePageGroup> {
public:
    static Ref<WebPageGroupProxy> create(WebPageGroupData&&);
    virtual ~WebPageGroupProxy();

    const String& identifier() const LIFETIME_BOUND { return m_data.identifier; }
    PageGroupIdentifier pageGroupID() const { return m_data.pageGroupID; }
    // MAVERICKS_BACKPORT: expose the underlying WebPageGroupData so the page group can be (re)wrapped
    // as an API::PageGroupHandle for legacy C API round-trips (Safari 7).
    const WebPageGroupData& data() const LIFETIME_BOUND { return m_data; }
    // Namespace IDs for local storage namespaces are currently equivalent to web page group IDs.
    WebCore::PageGroup* NODELETE corePageGroup() const;

    // MAVERICKS_BACKPORT: the controller the group's pages share, restored from upstream e05340a^.
    // The legacy WKBundleAddUserScript / WKBundleAddUserStyleSheet C API adds Safari 7 extension
    // content scripts and style sheets here.
    WebUserContentController& userContentController();

private:
    WebPageGroupProxy(WebPageGroupData&&);

    WebPageGroupData m_data;
    WeakPtr<WebCore::PageGroup> m_pageGroup;
    const Ref<WebUserContentController> m_userContentController; // MAVERICKS_BACKPORT: see userContentController() above.
};

} // namespace WebKit

// MAVERICKS_BACKPORT: type traits so downcast<WebPageGroupProxy>(API::Object&) works now that the
// proxy is an API::ObjectImpl again (legacy C API page-group plumbing, Safari 7).
SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebPageGroupProxy)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::BundlePageGroup; }
SPECIALIZE_TYPE_TRAITS_END()
