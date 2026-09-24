/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include "ResourceRequest.h"

namespace WebCore {

// Any image in the process may define
//
//     extern "C" CFURLRef WKExternalURLRewrite(CFURLRef url, CFMutableDictionaryRef headers);
//
// It runs for each request an HTTP(S) load sends, the first and every redirect it follows, on the thread
// sending it. headers holds the request's header fields, names comparing ignoring ASCII case; the request
// sends the fields the function leaves there, so it may add, change or remove any of them. It returns a new
// URL (which the caller releases) for the request to connect to and ask for in place of url, or NULL to
// keep url.
//
// Only the connection changes: its host, TLS, HSTS and proxy are the new URL's, and so is the request line.
// Everything else stays the requested URL's, as if its server were at the new address: the first party,
// cookies, credentials, the cache, redirect targets, and every response, redirect and error the load
// reports.
//
// Applies the function's header edits to request, and answers the URL to connect to, or null for the
// request's own.
WEBCORE_EXPORT URL applyExternalURLRewrite(ResourceRequest&);

} // namespace WebCore
