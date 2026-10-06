/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
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

#include "config.h"
#include "WKPageGroup.h"

#include "APIArray.h"
#include "APIContentWorld.h"
#include "APIUserScript.h"
#include "APIUserStyleSheet.h"
#include "InjectUserScriptImmediately.h"
#include "WKAPICast.h"
#include "WebPageGroup.h"
#include "WebPageProxy.h"
#include "WebPreferences.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include "WebUserContentControllerProxy.h"
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>

// AQUAWEBKIT: these were gutted to null upstream, but Safari 7 creates its
// browsing page group with WKPageGroupCreateWithIdentifier, attaches its
// WKPreferences to it, and passes the group to WKView — and the injected
// bundle later scopes extension content scripts by this group's identifier.

// AQUAWEBKIT: restored real body (was gutted to return 0 upstream).
WKTypeID WKPageGroupGetTypeID()
{
    return WebKit::toAPI(WebKit::WebPageGroup::APIType);
}

// AQUAWEBKIT: restored real body (was gutted to return nullptr upstream).
WKPageGroupRef WKPageGroupCreateWithIdentifier(WKStringRef identifierRef)
{
    return WebKit::toAPILeakingRef(WebKit::WebPageGroup::create(WebKit::toWTFString(identifierRef)));
}

// AQUAWEBKIT: restored real body (was gutted to an empty no-op upstream).
void WKPageGroupSetPreferences(WKPageGroupRef pageGroupRef, WKPreferencesRef preferencesRef)
{
    auto* pageGroup = WebKit::toImpl(pageGroupRef);
    auto* preferences = WebKit::toImpl(preferencesRef);
    if (!pageGroup || !preferences)
        return;
    pageGroup->setPreferences(*preferences);
    // AQUAWEBKIT: a page copies its group's preferences when it is created, and Safari 7 hands the group its
    // WKPreferences after the WKView exists, so the pages already in this group keep reading the
    // object the group no longer uses. Hand them the new one, which is what a page group meant when
    // WebPageProxy::preferences() still read straight through to it.
    for (Ref processPool : WebKit::WebProcessPool::allProcessPools()) {
        for (Ref webProcess : processPool->processes()) {
            for (Ref page : webProcess->pages()) {
                if (&page->pageGroup() == pageGroup)
                    page->setPreferences(*preferences);
            }
        }
    }
}

// AQUAWEBKIT: restored real body (was gutted to return nullptr upstream).
WKPreferencesRef WKPageGroupGetPreferences(WKPageGroupRef pageGroupRef)
{
    auto* pageGroup = WebKit::toImpl(pageGroupRef);
    if (!pageGroup)
        return nullptr;
    return WebKit::toAPI(&pageGroup->preferences());
}

WKUserContentControllerRef WKPageGroupGetUserContentController(WKPageGroupRef pageGroupRef)
{
// AQUAWEBKIT: restore the page-group user-content C SPI (gutted upstream with
// the page-group user-content model). The page group owns a WebUserContentControllerProxy
// (WebPageGroup::userContentController); pages created in the group share it (WKView seeds
// the page configuration with it), so scripts and style sheets added here are injected.
// Safari 7-era clients drive this through WKBrowsingContextGroup — e.g. Mail's
// -[MUIWebDocumentViewGroup _refreshUserStyleSheet]/_refreshUserScripts install the
// message-view style sheet and scripts. Faithful to the pre-removal implementation.
    // AQUAWEBKIT: restored real body (was gutted to return nullptr upstream).
    return WebKit::toAPI(&WebKit::toImpl(pageGroupRef)->userContentController());
}

// AQUAWEBKIT: restored page-group user-content SPI body (was gutted to a no-op upstream).
void WKPageGroupAddUserStyleSheet(WKPageGroupRef pageGroupRef, WKStringRef sourceRef, WKURLRef baseURLRef, WKArrayRef allowedURLPatterns, WKArrayRef blockedURLPatterns, WKUserContentInjectedFrames injectedFrames)
{
    // AQUAWEBKIT: restored implementation builds a real API::UserStyleSheet and injects it.
    auto source = WebKit::toWTFString(sourceRef);
    if (source.isEmpty())
        return;

    auto baseURLString = WebKit::toWTFString(baseURLRef);
    auto* allowlist = WebKit::toImpl(allowedURLPatterns);
    auto* blocklist = WebKit::toImpl(blockedURLPatterns);

    Ref<API::UserStyleSheet> userStyleSheet = API::UserStyleSheet::create(WebCore::UserStyleSheet {
        source,
        baseURLString.isEmpty() ? aboutBlankURL() : URL { baseURLString },
        allowlist ? allowlist->toStringVector() : Vector<String>(),
        blocklist ? blocklist->toStringVector() : Vector<String>(),
        WebKit::toUserContentInjectedFrames(injectedFrames)
    }, API::ContentWorld::pageContentWorldSingleton());

    WebKit::toImpl(pageGroupRef)->userContentController().addUserStyleSheet(userStyleSheet.get());
}

// AQUAWEBKIT: restored page-group user-content SPI body (was gutted to a no-op upstream).
void WKPageGroupRemoveAllUserStyleSheets(WKPageGroupRef pageGroupRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeAllUserStyleSheets();
}

// AQUAWEBKIT: restored page-group user-content SPI body (was gutted to a no-op upstream).
void WKPageGroupAddUserScript(WKPageGroupRef pageGroupRef, WKStringRef sourceRef, WKURLRef baseURLRef, WKArrayRef allowedURLPatterns, WKArrayRef blockedURLPatterns, WKUserContentInjectedFrames injectedFrames, _WKUserScriptInjectionTime injectionTime)
{
    // AQUAWEBKIT: restored implementation builds a real API::UserScript and injects it.
    auto source = WebKit::toWTFString(sourceRef);
    if (source.isEmpty())
        return;

    auto baseURLString = WebKit::toWTFString(baseURLRef);
    auto* allowlist = WebKit::toImpl(allowedURLPatterns);
    auto* blocklist = WebKit::toImpl(blockedURLPatterns);

    auto url = baseURLString.isEmpty() ? aboutBlankURL() : URL { baseURLString };
    Ref<API::UserScript> userScript = API::UserScript::create(WebCore::UserScript {
        WTF::move(source),
        WTF::move(url),
        allowlist ? allowlist->toStringVector() : Vector<String>(),
        blocklist ? blocklist->toStringVector() : Vector<String>(),
        WebKit::toUserScriptInjectionTime(injectionTime),
        WebKit::toUserContentInjectedFrames(injectedFrames)
    }, API::ContentWorld::pageContentWorldSingleton());

    WebKit::toImpl(pageGroupRef)->userContentController().addUserScript(userScript.get(), WebKit::InjectUserScriptImmediately::No);
}

// AQUAWEBKIT: restored page-group user-content SPI body (was gutted to a no-op upstream).
void WKPageGroupRemoveAllUserScripts(WKPageGroupRef pageGroupRef)
{
    WebKit::toImpl(pageGroupRef)->userContentController().removeAllUserScripts();
}
