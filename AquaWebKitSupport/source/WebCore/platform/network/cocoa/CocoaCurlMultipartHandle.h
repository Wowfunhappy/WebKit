/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

#include <WebCore/CurlMultipartHandle.h>
#include <WebCore/CurlMultipartHandleClient.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class ResourceResponse;

// Cocoa response headers supply the boundary for the shared multipart parser.
WEBCORE_EXPORT std::unique_ptr<CurlMultipartHandle> createCocoaCurlMultipartHandle(CurlMultipartHandleClient&, const ResourceResponse&);

// A part's response, as CFNetwork makes one: the multipart response's fields, with the fields of the header lines
// the parser read for the part over them. A line with no colon is skipped.
WEBCORE_EXPORT ResourceResponse cocoaCurlMultipartPartResponse(const ResourceResponse&, const Vector<String>& headerLines);

} // namespace WebCore
