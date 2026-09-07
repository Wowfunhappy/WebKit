/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

#include <WebCore/CurlMultipartHandle.h>
#include <WebCore/CurlMultipartHandleClient.h>

namespace WebCore {

class ResourceResponse;

// Cocoa response headers supply the boundary for the shared multipart parser.
WEBCORE_EXPORT std::unique_ptr<CurlMultipartHandle> createCocoaCurlMultipartHandle(CurlMultipartHandleClient&, const ResourceResponse&);

} // namespace WebCore
