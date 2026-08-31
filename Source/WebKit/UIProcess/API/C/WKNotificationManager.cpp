/*
 * Copyright (C) 2011-2025 Apple Inc. All rights reserved.
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
#include "WKNotificationManager.h"

#include "APIArray.h"
#include "APIData.h"
#include "WKAPICast.h"
#include "WebNotification.h"
#include "WebNotificationManagerProxy.h"
#include "WebNotificationProvider.h"

using namespace WebKit;

WKTypeID WKNotificationManagerGetTypeID()
{
    return toAPI(WebNotificationManagerProxy::APIType);
}

void WKNotificationManagerSetProvider(WKNotificationManagerRef managerRef, const WKNotificationProviderBase* wkProvider)
{
    protect(toImpl(managerRef))->setProvider(makeUnique<WebNotificationProvider>(wkProvider));

#if USE(MOZILLA_PUSH_SERVICE)
    // MAVERICKS_BACKPORT: service-worker (persistent) notifications display through
    // WebNotificationManagerProxy::serviceWorkerManagerSingleton(), which modern hosts
    // configure via WKNotificationManagerGetSharedServiceWorkerNotificationManager.
    // Safari 7 predates that call and only ever configures the pool manager, leaving the
    // singleton with the no-op default provider — showPersistent would display nothing
    // and, worse, the singleton's empty permission map would resolve every incoming push
    // to Prompt and unsubscribe the site (NetworkProcessProxy::processPushMessage).
    // Mirror the host's provider onto the singleton, the same pairing the GTK port sets
    // up in webkitWebContextConstructed.
    // Installed without addNotificationManager: the client reports notification events
    // to every manager it has been introduced to, so introducing this one too would
    // double-dispatch each event once here and once via the pool manager's
    // miss-forwarding (providerDidShowNotification et al.).
    Ref serviceWorkerManager = WebNotificationManagerProxy::serviceWorkerManagerSingleton();
    if (toImpl(managerRef) != serviceWorkerManager.ptr())
        serviceWorkerManager->setProvider(makeUnique<WebNotificationProvider>(wkProvider), WebNotificationManagerProxy::ShouldNotifyProviderOfManager::No);
#endif
}

void WKNotificationManagerProviderDidShowNotification(WKNotificationManagerRef managerRef, uint64_t notificationID)
{
    protect(toImpl(managerRef))->providerDidShowNotification(WebNotificationIdentifier { notificationID });
}

void WKNotificationManagerProviderDidClickNotification(WKNotificationManagerRef managerRef, uint64_t notificationID)
{
    protect(toImpl(managerRef))->providerDidClickNotification(WebNotificationIdentifier { notificationID });
}

void WKNotificationManagerProviderDidClickNotification_b(WKNotificationManagerRef managerRef, WKDataRef identifier)
{
    auto span = toImpl(identifier)->span();
    if (span.size() != 16)
        return;

    protect(toImpl(managerRef))->providerDidClickNotification(WTF::UUID { std::span<const uint8_t, 16> { span } });
}

void WKNotificationManagerProviderDidCloseNotifications(WKNotificationManagerRef managerRef, WKArrayRef notificationIDs)
{
    protect(toImpl(managerRef))->providerDidCloseNotifications(protect(toImpl(notificationIDs)).get());
}

void WKNotificationManagerProviderDidUpdateNotificationPolicy(WKNotificationManagerRef managerRef, WKSecurityOriginRef origin, bool allowed)
{
    protect(toImpl(managerRef))->providerDidUpdateNotificationPolicy(protect(toImpl(origin)).get(), allowed);
}

void WKNotificationManagerProviderDidRemoveNotificationPolicies(WKNotificationManagerRef managerRef, WKArrayRef origins)
{
    protect(toImpl(managerRef))->providerDidRemoveNotificationPolicies(protect(toImpl(origins)).get());
}

WKNotificationManagerRef WKNotificationManagerGetSharedServiceWorkerNotificationManager()
{
    return toAPI(&WebNotificationManagerProxy::serviceWorkerManagerSingleton());
}
