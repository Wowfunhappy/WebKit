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

#include "config.h"
#include "WKIconDatabase.h"

#include "APIData.h"
#include "WKAPICast.h"
#include "WebIconDatabase.h"
#include "WebIconDatabaseClient.h"

using namespace WebKit;

WKTypeID WKIconDatabaseGetTypeID()
{
    return toAPI(WebIconDatabase::APIType);
}

// MAVERICKS_BACKPORT: attach Safari 7's legacy C icon-database client so favicon change
// notifications are delivered again (#49).
void WKIconDatabaseSetIconDatabaseClient(WKIconDatabaseRef iconDatabaseRef, const WKIconDatabaseClientBase* client)
{
    toImpl(iconDatabaseRef)->setClient(client ? makeUnique<WebIconDatabaseClient>(client) : nullptr);
}

// MAVERICKS_BACKPORT: intentionally inert. Safari 7 calls these on the legacy icon database,
// but the revived in-memory store is populated by the icon-loading client and needs no
// explicit retain/release/eviction bookkeeping (#49).
void WKIconDatabaseRetainIconForURL(WKIconDatabaseRef, WKURLRef)
{
}

void WKIconDatabaseReleaseIconForURL(WKIconDatabaseRef, WKURLRef)
{
}

void WKIconDatabaseSetIconDataForIconURL(WKIconDatabaseRef, WKDataRef, WKURLRef)
{
}

void WKIconDatabaseSetIconURLForPageURL(WKIconDatabaseRef, WKURLRef, WKURLRef)
{
}

// MAVERICKS_BACKPORT: answer favicon URL/data queries from the revived in-memory store (#49).
WKURLRef WKIconDatabaseCopyIconURLForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    String iconURL = toImpl(iconDatabaseRef)->iconURLForPageURL(toWTFString(pageURL));
    if (iconURL.isEmpty())
        return nullptr;
    return toCopiedURLAPI(iconURL);
}

WKDataRef WKIconDatabaseCopyIconDataForPageURL(WKIconDatabaseRef iconDatabaseRef, WKURLRef pageURL)
{
    RefPtr data = toImpl(iconDatabaseRef)->iconDataForPageURL(toWTFString(pageURL));
    if (!data)
        return nullptr;
    return toAPILeakingRef(data.releaseNonNull());
}

void WKIconDatabaseEnableDatabaseCleanup(WKIconDatabaseRef)
{
}

// MAVERICKS_BACKPORT: clear the revived in-memory store (#49).
void WKIconDatabaseRemoveAllIcons(WKIconDatabaseRef iconDatabaseRef)
{
    toImpl(iconDatabaseRef)->removeAllIcons();
}

void WKIconDatabaseCheckIntegrityBeforeOpening(WKIconDatabaseRef)
{
}

void WKIconDatabaseClose(WKIconDatabaseRef)
{
}
