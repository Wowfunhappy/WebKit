#pragma once

#include "ResourceRequest.h"

namespace WebCore {

inline void removeCocoaCurlRequestHeader(ResourceRequest& request, HTTPHeaderName name)
{
    auto headers = request.httpHeaderFields();
    headers.remove(name);
    request.setHTTPHeaderFields(WTF::move(headers));
}

}
