/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// authentication field parsing preserves each challenge's scheme and realm.
#include <WebCore/ProtectionSpace.h>
#include <curl/curl.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
WEBCORE_EXPORT long cocoaCurlAuthenticationMethod(long available);
WEBCORE_EXPORT String cocoaCurlAuthenticationRealm(const String& fields, long method);
WEBCORE_EXPORT ProtectionSpace cocoaCurlProtectionSpace(const URL&, const String& proxyHost, int proxyPort, long method, const String& fields);
} // namespace WebCore

// native authentication challenges preserve NSURLAuthenticationChallengeSender for legacy Cocoa clients.
#include <wtf/CompletionHandler.h>
OBJC_CLASS NSURLAuthenticationChallenge;
OBJC_CLASS NSURLCredential;
namespace WebCore {
class Credential;
class ResourceResponse;
class ResourceError;
enum class CocoaCurlAuthenticationDisposition : uint8_t { UseCredential, ContinueWithoutCredential, Cancel, PerformDefaultHandling, RejectProtectionSpace };
using CocoaCurlAuthenticationCompletion = CompletionHandler<void(CocoaCurlAuthenticationDisposition, RetainPtr<NSURLCredential>&&)>;
WEBCORE_EXPORT RetainPtr<NSURLAuthenticationChallenge> cocoaCurlAuthenticationChallenge(const ProtectionSpace&, const Credential&, unsigned failures, const ResourceResponse&, const ResourceError&, CocoaCurlAuthenticationCompletion&&);
}
