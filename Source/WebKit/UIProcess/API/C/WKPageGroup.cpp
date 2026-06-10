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

#include "WKAPICast.h"
#include "WebPageGroup.h"
#include "WebPreferences.h"

// 10.9 backport: these were gutted to null upstream, but Safari 7 creates its
// browsing page group with WKPageGroupCreateWithIdentifier, attaches its
// WKPreferences to it, and passes the group to WKView — and the injected
// bundle later scopes extension content scripts by this group's identifier.

WKTypeID WKPageGroupGetTypeID()
{
    return WebKit::toAPI(WebKit::WebPageGroup::APIType);
}

WKPageGroupRef WKPageGroupCreateWithIdentifier(WKStringRef identifierRef)
{
    return WebKit::toAPILeakingRef(WebKit::WebPageGroup::create(WebKit::toWTFString(identifierRef)));
}

void WKPageGroupSetPreferences(WKPageGroupRef pageGroupRef, WKPreferencesRef preferencesRef)
{
    auto* pageGroup = WebKit::toImpl(pageGroupRef);
    auto* preferences = WebKit::toImpl(preferencesRef);
    if (!pageGroup || !preferences)
        return;
    pageGroup->setPreferences(*preferences);
}

WKPreferencesRef WKPageGroupGetPreferences(WKPageGroupRef pageGroupRef)
{
    auto* pageGroup = WebKit::toImpl(pageGroupRef);
    if (!pageGroup)
        return nullptr;
    return WebKit::toAPI(&pageGroup->preferences());
}

WKUserContentControllerRef WKPageGroupGetUserContentController(WKPageGroupRef pageGroupRef)
{
    return nullptr;
}

void WKPageGroupAddUserStyleSheet(WKPageGroupRef, WKStringRef, WKURLRef, WKArrayRef, WKArrayRef, WKUserContentInjectedFrames)
{
}

void WKPageGroupRemoveAllUserStyleSheets(WKPageGroupRef)
{
}

void WKPageGroupAddUserScript(WKPageGroupRef, WKStringRef, WKURLRef, WKArrayRef, WKArrayRef, WKUserContentInjectedFrames, _WKUserScriptInjectionTime)
{
}

void WKPageGroupRemoveAllUserScripts(WKPageGroupRef)
{
}
