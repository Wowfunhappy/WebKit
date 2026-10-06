/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// The content decoding a Cocoa curl transfer applies to a response body. Under the default
// content-encoding sniffing policy a gzip archive arrives encoded, as CFNetwork delivers it, and a body
// whose codings include one the transfer does not know arrives as sent.
#include <WebCore/ResourceLoaderOptions.h>
#include <memory>
#include <optional>
#include <span>
#include <wtf/Vector.h>

namespace WebCore {

class ResourceResponse;

class CocoaCurlContentDecoder {
public:
    // Null when the body arrives as sent.
    static std::unique_ptr<CocoaCurlContentDecoder> create(const ResourceResponse&, ContentEncodingSniffingPolicy);
    virtual ~CocoaCurlContentDecoder() = default;

    // Takes received bytes, which read() decodes.
    virtual void append(std::span<const uint8_t>) = 0;
    // At most limit decoded bytes, none once the received bytes are used up, or nullopt when the body
    // cannot be decoded.
    virtual std::optional<Vector<uint8_t>> read(size_t limit) = 0;
    // False when the body ended partway through its coding.
    virtual bool isComplete() const = 0;
};

} // namespace WebCore
