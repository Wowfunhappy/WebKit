/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

#include <span>
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace MIMESniffer {

// HTTP transports use WebCore's MIME Sniffing Standard implementation.
inline constexpr size_t resourceHeaderSize = 1445; // https://mimesniff.spec.whatwg.org/#reading-the-resource-header
WEBCORE_EXPORT bool needsHTTPContentSniffing(const String& contentType, bool noSniff);
WEBCORE_EXPORT String computeHTTPMIMEType(std::span<const uint8_t>, const String& contentType, bool noSniff);

} // namespace MIMESniffer
} // namespace WebCore
