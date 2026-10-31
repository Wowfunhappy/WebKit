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
#include "WKBundleBackForwardListItem.h"

#include "APIArray.h"
// AQUAWEBKIT: the bundle item API exposes retained HistoryItems.
#include "InjectedBundleBackForwardListItem.h"
#include "WKBundleAPICast.h"

// AQUAWEBKIT: bundle item casts use the WebKit API wrapper.
using namespace WebKit;

WKTypeID WKBundleBackForwardListItemGetTypeID()
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return WebKit::toAPI(API::Object::Type::Null);
    return toAPI(InjectedBundleBackForwardListItem::APIType);
}

bool WKBundleBackForwardListItemIsSame(WKBundleBackForwardListItemRef itemRef1, WKBundleBackForwardListItemRef itemRef2)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return false;
    return toImpl(itemRef1)->item() == toImpl(itemRef2)->item();
}

WKURLRef WKBundleBackForwardListItemCopyOriginalURL(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return nullptr;
    return toCopiedURLAPI(toImpl(itemRef)->originalURL());
}

WKURLRef WKBundleBackForwardListItemCopyURL(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return nullptr;
    return toCopiedURLAPI(toImpl(itemRef)->url());
}

WKStringRef WKBundleBackForwardListItemCopyTitle(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return nullptr;
    return toCopiedAPI(toImpl(itemRef)->title());
}

WKStringRef WKBundleBackForwardListItemCopyTarget(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return nullptr;
    return toCopiedAPI(toImpl(itemRef)->target().string());
}

bool WKBundleBackForwardListItemIsTargetItem(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return false;
    return toImpl(itemRef)->isTargetItem();
}

bool WKBundleBackForwardListItemIsInBackForwardCache(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return false;
    return toImpl(itemRef)->isInBackForwardCache();
}

// AQUAWEBKIT: Safari 7 queries the HistoryItem cache state through this entry point.
bool WKBundleBackForwardListItemIsInPageCache(WKBundleBackForwardListItemRef itemRef)
{
    return toImpl(itemRef)->isInBackForwardCache();
}

bool WKBundleBackForwardListItemHasCachedPageExpired(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return false;
    return toImpl(itemRef)->hasCachedPageExpired();
}

WKArrayRef WKBundleBackForwardListItemCopyChildren(WKBundleBackForwardListItemRef itemRef)
{
    // AQUAWEBKIT: the result comes from the wrapped HistoryItem.
    // return nullptr;
    return toAPI(toImpl(itemRef)->children().leakRef());
}

