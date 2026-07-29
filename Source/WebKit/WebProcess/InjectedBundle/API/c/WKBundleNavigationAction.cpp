/*
 * Copyright (C) 2011 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: restored verbatim from upstream 8ee28eb^ ("Remove InjectedBundleNavigationAction",
// bug 247819). Safari 7 imports WKBundleNavigationActionCopyHitTestResult / GetNavigationType /
// CopyFormElement and calls them from its injected-bundle policy client; the return-0 stubs upstream
// left behind made that client build an empty userData dictionary.

#include "config.h"
#include "WKBundleNavigationAction.h"
#include "WKBundleNavigationActionPrivate.h"

// MAVERICKS_BACKPORT: includes for the restored real implementations below.
#include "InjectedBundleHitTestResult.h"
#include "InjectedBundleNavigationAction.h"
#include "InjectedBundleNodeHandle.h"
#include "WKAPICast.h"
#include "WKBundleAPICast.h"

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKTypeID WKBundleNavigationActionGetTypeID()
{
    return WebKit::toAPI(WebKit::InjectedBundleNavigationAction::APIType);
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKFrameNavigationType WKBundleNavigationActionGetNavigationType(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->navigationType());
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKEventModifiers WKBundleNavigationActionGetEventModifiers(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->modifiers());
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKEventMouseButton WKBundleNavigationActionGetEventMouseButton(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->mouseButton());
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKBundleHitTestResultRef WKBundleNavigationActionCopyHitTestResult(WKBundleNavigationActionRef navigationActionRef)
{
    RefPtr<WebKit::InjectedBundleHitTestResult> hitTestResult = WebKit::toImpl(navigationActionRef)->hitTestResult();
    return toAPI(hitTestResult.leakRef());
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKBundleNodeHandleRef WKBundleNavigationActionCopyFormElement(WKBundleNavigationActionRef navigationActionRef)
{
    RefPtr<WebKit::InjectedBundleNodeHandle> formElement = WebKit::toImpl(navigationActionRef)->formElement();
    return toAPI(formElement.leakRef());
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
bool WKBundleNavigationActionGetShouldOpenExternalURLs(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toImpl(navigationActionRef)->shouldOpenExternalURLs();
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
bool WKBundleNavigationActionGetShouldTryAppLinks(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toImpl(navigationActionRef)->shouldTryAppLinks();
}

// MAVERICKS_BACKPORT: real implementation restored from 8ee28eb^ (upstream stubbed this SPI out; Safari 7 injected-bundle policy clients call it).
WKStringRef WKBundleNavigationActionCopyDownloadAttribute(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toCopiedAPI(WebKit::toImpl(navigationActionRef)->downloadAttribute());
}
