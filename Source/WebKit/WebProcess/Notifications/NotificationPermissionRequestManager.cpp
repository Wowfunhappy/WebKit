/*
 * Copyright (C) 2011, 2012 Apple Inc. All rights reserved.
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
#include "NotificationPermissionRequestManager.h"

#include "MessageSenderInlines.h"
#include "NotificationManagerMessageHandlerMessages.h"
#include "WebPage.h"
#include "WebPageProxyMessages.h"
#include "WebProcess.h"
#include <WebCore/Notification.h>
#include <WebCore/Page.h>
#include <WebCore/ScriptExecutionContext.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/Settings.h>

#if ENABLE(NOTIFICATIONS)
#include "WebNotificationManager.h"
#endif

#if ENABLE(WEB_PUSH_NOTIFICATIONS)
#include "NetworkProcessConnection.h"
#include <WebCore/DeprecatedGlobalSettings.h>
#endif

namespace WebKit {
using namespace WebCore;

Ref<NotificationPermissionRequestManager> NotificationPermissionRequestManager::create(WebPage* page)
{
    return adoptRef(*new NotificationPermissionRequestManager(page));
}

#if ENABLE(NOTIFICATIONS)
NotificationPermissionRequestManager::NotificationPermissionRequestManager(WebPage* page)
    : m_page(page)
{
}
#else
NotificationPermissionRequestManager::NotificationPermissionRequestManager(WebPage*)
{
}
#endif

NotificationPermissionRequestManager::~NotificationPermissionRequestManager()
{
#if ENABLE(NOTIFICATIONS)
    auto requestsPerOrigin = std::exchange(m_requestsPerOrigin, { });
    for (auto& permissionHandlers : requestsPerOrigin.values())
        callPermissionHandlersWith(permissionHandlers, Permission::Denied);
#endif
}

#if ENABLE(NOTIFICATIONS)
void NotificationPermissionRequestManager::startRequest(const SecurityOriginData& securityOrigin, PermissionHandler&& permissionHandler)
{
    // MAVERICKS_BACKPORT: answer from the map the client seeded through WKNotificationProvider's
    // notificationPermissions and updates through WKNotificationManagerProviderDidUpdateNotificationPolicy.
    // Safari 7 publishes its file:// and extension-origin decisions only there, so those origins
    // are decided here rather than sent back to a client that keeps no record of them.
    auto permission = permissionLevel(securityOrigin);
    if (permission != Permission::Default)
        return permissionHandler(permission);

    auto addResult = m_requestsPerOrigin.add(securityOrigin, PermissionHandlers { });
    addResult.iterator->value.append(WTF::move(permissionHandler));
    if (!addResult.isNewEntry)
        return;

    m_page->sendWithAsyncReply(Messages::WebPageProxy::RequestNotificationPermission(securityOrigin.toString()), [this, protectedThis = Ref { *this }, securityOrigin, permissionHandler = WTF::move(permissionHandler)](bool allowed) mutable {

        auto innerPermissionHandler = [this, protectedThis = Ref { *this }, securityOrigin, permissionHandler = WTF::move(permissionHandler)] (bool allowed) mutable {
            protect(WebProcess::singleton().notificationManager())->didUpdateNotificationDecision(securityOrigin.toString(), allowed);

            auto permissionHandlers = m_requestsPerOrigin.take(securityOrigin);
            callPermissionHandlersWith(permissionHandlers, allowed ? Permission::Granted : Permission::Denied);
        };

        innerPermissionHandler(allowed);
    });
}

void NotificationPermissionRequestManager::callPermissionHandlersWith(PermissionHandlers& permissionHandlers, Permission permission)
{
    for (auto& permissionHandler : permissionHandlers)
        permissionHandler(permission);
}
#endif

auto NotificationPermissionRequestManager::permissionLevel(const SecurityOriginData& securityOrigin) -> Permission
{
#if ENABLE(NOTIFICATIONS)
    if (!m_page->corePage()->settings().notificationsEnabled())
        return Permission::Denied;

    // MAVERICKS_BACKPORT: names the page, so a granted origin still reports
    // PageWasNotifiedOfNotificationPermission and keeps its background-run activity when startRequest
    // answers without asking the client.
    return protect(WebProcess::singleton().notificationManager())->policyForOrigin(securityOrigin.toString(), m_page.get());
#else
    UNUSED_PARAM(securityOrigin);
    return Permission::Denied;
#endif
}

void NotificationPermissionRequestManager::setPermissionLevelForTesting(const String& originString, bool allowed)
{
#if ENABLE(NOTIFICATIONS)
    protect(WebProcess::singleton().notificationManager())->didUpdateNotificationDecision(originString, allowed);
#else
    UNUSED_PARAM(originString);
    UNUSED_PARAM(allowed);
#endif
}

void NotificationPermissionRequestManager::removeAllPermissionsForTesting()
{
#if ENABLE(NOTIFICATIONS)
    protect(WebProcess::singleton().notificationManager())->removeAllPermissionsForTesting();
#endif
}

} // namespace WebKit
