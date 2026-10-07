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

// AQUAWEBKIT: the InjectedBundleNavigationAction accessors. Safari 7 imports
// WKBundleNavigationActionCopyHitTestResult / GetNavigationType / CopyFormElement and calls them from
// its injected-bundle policy client to build its userData dictionary.

#include "config.h"
#include "WKBundleNavigationAction.h"
#include "WKBundleNavigationActionPrivate.h"

// AQUAWEBKIT: includes for the implementations below.
#include "InjectedBundleHitTestResult.h"
#include "InjectedBundleNavigationAction.h"
#include "InjectedBundleNodeHandle.h"
#include "WKAPICast.h"
#include "WKBundleAPICast.h"

WKTypeID WKBundleNavigationActionGetTypeID()
{
    return WebKit::toAPI(WebKit::InjectedBundleNavigationAction::APIType); // AQUAWEBKIT: upstream: return 0;
}

WKFrameNavigationType WKBundleNavigationActionGetNavigationType(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->navigationType()); // AQUAWEBKIT: upstream: return 0;
}

WKEventModifiers WKBundleNavigationActionGetEventModifiers(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->modifiers()); // AQUAWEBKIT: upstream: return 0;
}

WKEventMouseButton WKBundleNavigationActionGetEventMouseButton(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toAPI(WebKit::toImpl(navigationActionRef)->mouseButton()); // AQUAWEBKIT: upstream: return 0;
}

WKBundleHitTestResultRef WKBundleNavigationActionCopyHitTestResult(WKBundleNavigationActionRef navigationActionRef)
{
    RefPtr<WebKit::InjectedBundleHitTestResult> hitTestResult = WebKit::toImpl(navigationActionRef)->hitTestResult();
    return toAPI(hitTestResult.leakRef()); // AQUAWEBKIT: upstream: return 0;
}

WKBundleNodeHandleRef WKBundleNavigationActionCopyFormElement(WKBundleNavigationActionRef navigationActionRef)
{
    RefPtr<WebKit::InjectedBundleNodeHandle> formElement = WebKit::toImpl(navigationActionRef)->formElement();
    return toAPI(formElement.leakRef()); // AQUAWEBKIT: upstream: return 0;
}

bool WKBundleNavigationActionGetShouldOpenExternalURLs(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toImpl(navigationActionRef)->shouldOpenExternalURLs(); // AQUAWEBKIT: upstream: return 0;
}

bool WKBundleNavigationActionGetShouldTryAppLinks(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toImpl(navigationActionRef)->shouldTryAppLinks(); // AQUAWEBKIT: upstream: return 0;
}

WKStringRef WKBundleNavigationActionCopyDownloadAttribute(WKBundleNavigationActionRef navigationActionRef)
{
    return WebKit::toCopiedAPI(WebKit::toImpl(navigationActionRef)->downloadAttribute()); // AQUAWEBKIT: upstream: return 0;
}
