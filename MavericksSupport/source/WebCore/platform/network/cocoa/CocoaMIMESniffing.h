/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

#include <span>
#include <wtf/Forward.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace MIMESniffer {

// HTTP transports use WebCore's MIME Sniffing Standard implementation.
// CFNetwork holds the response to a load that sniffs, for the Content-Types holdsResponseForSniffing names,
// until this many body bytes arrive or the body ends, and names the type from those bytes.
inline constexpr size_t sniffedPrefixLength = 512;
WEBCORE_EXPORT bool holdsResponseForSniffing(const String& contentType);
WEBCORE_EXPORT String computeHTTPMIMEType(std::span<const uint8_t>, const String& contentType, bool noSniff);

} // namespace MIMESniffer
} // namespace WebCore
