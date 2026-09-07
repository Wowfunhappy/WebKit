/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once
// resume IPC carries the request and file/validator fields explicitly; native plist bytes remain an API-boundary representation.
#include <WebCore/ResourceRequest.h>
#include <WebCore/StoredCredentialsPolicy.h>
#include <pal/SessionID.h>
namespace WebKit {
class CocoaDownloadResumeData {
public:
    static std::optional<CocoaDownloadResumeData> fromData(std::span<const uint8_t>);
    Vector<uint8_t> serializedData() const;
    WebCore::ResourceRequest request;
    PAL::SessionID sessionID;
    WebCore::StoredCredentialsPolicy storedCredentialsPolicy;
    uint64_t bytesReceived;
    String destination;
    String entityTag;
    String lastModified;
};
}
