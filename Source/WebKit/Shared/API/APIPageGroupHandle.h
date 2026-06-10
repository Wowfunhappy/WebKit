/*
 * 10.9 backport: carrier for page groups crossing the UI<->WebContent
 * boundary inside UserData. Safari 7 places its browsing WKPageGroup in the
 * injected-bundle initialization user data (and in bundle messages); the UI
 * process transforms the WebPageGroup into this handle before encoding
 * (WebProcessProxy::transformObjectsToHandles), and the WebContent process
 * resolves it to the WebPageGroupProxy on decode
 * (WebProcess::transformHandlesToObjects). Upstream removed this class along
 * with the rest of the page-group machinery; without the transform, the raw
 * UI-type object reached the API::Object encoder, which has no case for it
 * and silently encoded nothing — corrupting the IPC stream and crash-looping
 * every WebContent process at launch.
 */

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
