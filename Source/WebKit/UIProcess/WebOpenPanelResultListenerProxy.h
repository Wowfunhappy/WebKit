/*
 * Copyright (C) 2010-2018 Apple Inc. All rights reserved.
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
#include <wtf/Forward.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h> // AQUAWEBKIT: m_allowedMIMETypes.

namespace API {
class Array;
class Data;
}

namespace WebKit {

class WebPageProxy;
class WebProcessProxy;

class WebOpenPanelResultListenerProxy : public API::ObjectImpl<API::Object::Type::FramePolicyListener> {
public:
    static Ref<WebOpenPanelResultListenerProxy> create(WebPageProxy* page, WebProcessProxy& process)
    {
        return adoptRef(*new WebOpenPanelResultListenerProxy(page, process));
    }

    virtual ~WebOpenPanelResultListenerProxy();

#if PLATFORM(IOS_FAMILY)
    void chooseFiles(const Vector<String>& filenames, const String& displayString, const API::Data* iconImageData);
#endif
    void chooseFiles(const Vector<String>& filenames, const Vector<String>& allowedMIMETypes = { });
    // AQUAWEBKIT: the open panel's allowed MIME types, which WKOpenPanelResultListenerChooseFiles passes on.
    void setAllowedMIMETypes(Vector<String>&& allowedMIMETypes) { m_allowedMIMETypes = WTF::move(allowedMIMETypes); }
    const Vector<String>& allowedMIMETypes() const { return m_allowedMIMETypes; }
    void cancel();

    void invalidate();

    WebProcessProxy* NODELETE process() const;

private:
    WebOpenPanelResultListenerProxy(WebPageProxy*, WebProcessProxy&);

    RefPtr<WebPageProxy> m_page;
    WeakPtr<WebProcessProxy> m_process;
    Vector<String> m_allowedMIMETypes; // AQUAWEBKIT: see setAllowedMIMETypes().
};

} // namespace WebKit

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebOpenPanelResultListenerProxy)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::FramePolicyListener; }
SPECIALIZE_TYPE_TRAITS_END()
