/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if PLATFORM(COCOA) && !PLATFORM(WATCHOS) && !PLATFORM(APPLETV)

#import <WebCore/OrganizationStorageAccessPromptQuirk.h> // MAVERICKS_BACKPORT: carried by the entry point below.
#import <optional> // MAVERICKS_BACKPORT: ditto.
#import <wtf/CompletionHandler.h>

// MAVERICKS_BACKPORT: the alert is raised for the page rather than for a WKWebView, so that a page
// hosted in a WKView reaches it too, and so that a plain C++ translation unit can call these.
// @class WKWebView;

namespace WTF {
class String;
}

namespace WebCore {
class RegistrableDomain;
}

namespace WebKit {

class WebPageProxy; // MAVERICKS_BACKPORT: the alert's host, in place of the WKWebView above.

// MAVERICKS_BACKPORT: the whole quirk-first fallback, so the legacy C UI client and the Cocoa UI
// delegate reach the same sheet in the same order from one place.
void presentStorageAccessAlert(WebPageProxy&, const WebCore::RegistrableDomain& requestingDomain, const WebCore::RegistrableDomain& currentDomain, std::optional<WebCore::OrganizationStorageAccessPromptQuirk>&&, CompletionHandler<void(bool)>&&);

void presentStorageAccessAlert(WebPageProxy&, const WebCore::RegistrableDomain& requestingDomain, const WebCore::RegistrableDomain& currentDomain, CompletionHandler<void(bool)>&&); // MAVERICKS_BACKPORT: takes the page.
void presentStorageAccessAlertQuirk(WebPageProxy&, const WebCore::RegistrableDomain& firstRequestingDomain, const WebCore::RegistrableDomain& secondRequestingDomain, const WebCore::RegistrableDomain& current, CompletionHandler<void(bool)>&&); // MAVERICKS_BACKPORT: takes the page.
void presentStorageAccessAlertSSOQuirk(WebPageProxy&, const String& organizationName, const HashMap<WebCore::RegistrableDomain, Vector<WebCore::RegistrableDomain>>&, CompletionHandler<void(bool)>&&); // MAVERICKS_BACKPORT: takes the page.
// MAVERICKS_BACKPORT: displayStorageAccessAlert is declared in the implementation instead, so that
// this header carries no ObjC types and a plain C++ translation unit can include it.
// void displayStorageAccessAlert(WKWebView *, NSString *, NSString *, NSString *, NSArray<NSString *> *, CompletionHandler<void(bool)>&&);

}

#endif // PLATFORM(COCOA) && !PLATFORM(WATCHOS) && !PLATFORM(APPLETV)
