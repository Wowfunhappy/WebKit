/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The WebKitSystemInterface function WebKeyGenerator calls, with the contract 10.9's WebKit
// framework gives it: WebKitSystemInterface is a static library linked into that framework, and
// this function is not among the framework's exports.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    WKCertificateParseResultSucceeded = 0,
    WKCertificateParseResultFailed = 1,
    WKCertificateParseResultPKCS7 = 2,
} WKCertificateParseResult;

__attribute__((visibility("hidden"))) WKCertificateParseResult WKAddCertificatesToKeychainFromData(const void* bytes, unsigned length);

#ifdef __cplusplus
}
#endif
