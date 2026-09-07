/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlMultipartHandle.h"

#include "ParsedContentType.h"
#include "ResourceResponse.h"
#include <wtf/StdLibExtras.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

// share the boundary parser while retaining Cocoa ResourceResponse storage.
std::unique_ptr<CurlMultipartHandle> createCocoaCurlMultipartHandle(CurlMultipartHandleClient& client, const ResourceResponse& response)
{
    auto contentType = ParsedContentType::create(response.httpHeaderField(HTTPHeaderName::ContentType));
    if (!contentType || !equalLettersIgnoringASCIICase(contentType->mimeType(), "multipart/x-mixed-replace"_s))
        return nullptr;
    auto boundary = contentType->parameterValueForName("boundary"_s);
    if (boundary.isEmpty())
        return nullptr;
    return makeUnique<CurlMultipartHandle>(client, makeString("--"_s, boundary).latin1());
}

} // namespace WebCore
