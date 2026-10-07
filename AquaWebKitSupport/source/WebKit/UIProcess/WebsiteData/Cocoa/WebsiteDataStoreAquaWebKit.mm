/* Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The parts of WebsiteDataStore that run this port's webpushd for a host that drives none of it
// itself: the daemon's launchd job, the drain of the messages it queues, and the clients.openWindow
// fallback. Safari 7 predates the SPI through which a modern host does each of these.

#import "config.h"
#import "WebsiteDataStore.h"

#if USE(MOZILLA_PUSH_SERVICE)

#import "Logging.h"
#import "NetworkProcessProxy.h"
#import "WebPushMessage.h"
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

namespace WebKit {

// The launchd job for the webpushd this framework carries, submitted to the login session's launchd,
// which starts the daemon when the network process looks its Mach service up and reaps it once it
// holds no transaction. The job is upstream's webpushd/com.apple.webkit.webpushd.relocatable.mac.plist
// with ${INSTALL_PATH} resolved against the loaded framework, minus the incoming-push service apsd owns.
void WebsiteDataStore::registerWebPushDaemonWithLaunchd()
{
    static NSString * const jobLabel = @"com.apple.webkit.webpushd.relocatable";
    static NSString * const machServiceName = @"com.apple.webkit.webpushd.relocatable.service";

    RetainPtr executablePath = [[NSBundle bundleForClass:NSClassFromString(@"WKWebView")].executablePath stringByResolvingSymlinksInPath];
    RetainPtr daemonPath = [[executablePath.get() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Daemons/webpushd"];

    // A job registered for another copy of the framework would answer this one's Mach lookup with
    // that copy's daemon, over this one's database, so the label is re-registered unless it already
    // names the daemon beside this framework.
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    RetainPtr registeredJob = adoptCF(SMJobCopyDictionary(kSMDomainUserLaunchd, (__bridge CFStringRef)jobLabel));
    if (registeredJob) {
        RetainPtr registeredArguments = dynamic_objc_cast<NSArray>([(__bridge NSDictionary *)registeredJob.get() objectForKey:@"ProgramArguments"]);
        if ([[registeredArguments.get() firstObject] isEqual:daemonPath.get()])
            return;
        SMJobRemove(kSMDomainUserLaunchd, (__bridge CFStringRef)jobLabel, nullptr, true, nullptr);
    }
    ALLOW_DEPRECATED_DECLARATIONS_END

    RetainPtr job = @{
        @"Label": jobLabel,
        @"ProgramArguments": @[daemonPath.get(), @"--machServiceName", machServiceName],
        @"MachServices": @{ machServiceName: @YES },
        @"ProcessType": @"Adaptive",
        @"EnableTransactions": @YES,
        @"StandardErrorPath": @"/dev/null",
    };

    CFErrorRef error = nullptr;
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    bool submitted = SMJobSubmit(kSMDomainUserLaunchd, (__bridge CFDictionaryRef)job.get(), nullptr, &error);
    ALLOW_DEPRECATED_DECLARATIONS_END
    // Push is dead without the daemon, and RELEASE_LOG reaches no log on 10.9, so say so on stderr.
    if (!submitted)
        WTFLogAlways("Could not register %s with launchd: CFError %ld", [daemonPath.get() UTF8String], error ? static_cast<long>(CFErrorGetCode(error)) : 0L);
    if (error)
        CFRelease(error);
}

// WebKit-driven twin of the modern host's -[WKWebsiteDataStore _handleNextPushMessageWithCompletionHandler:]
// drain loop, run whenever webpushd signals pending messages or a session starts. Uses the plural
// GetPendingPushMessages fetch: the singular one arms the daemon's 30-second showNotification watchdog,
// which only the macOS 14+ builtin-notification path can cancel; with UI-process display, silent-push
// accounting instead happens in NetworkProcess::processPushMessage.
void WebsiteDataStore::pumpPendingWebPushMessages()
{
    if (!isPersistent())
        return;
    if (m_pumpingWebPushMessages) {
        // A signal arrived mid-drain; run once more afterwards so a message that landed
        // behind the in-flight fetch is not stranded until the next signal.
        m_repumpWebPushMessages = true;
        return;
    }
    m_pumpingWebPushMessages = true;
    RELEASE_LOG(Push, "Fetching pending push messages from webpushd");
    protect(networkProcess())->getPendingPushMessages(sessionID(), [this, protectedThis = Ref { *this }](const Vector<WebPushMessage>& messages) {
        RELEASE_LOG(Push, "Processing %zu pending push messages", messages.size());
        for (auto& message : messages)
            m_queuedWebPushMessages.append(message);
        processNextQueuedWebPushMessage();
    });
}

void WebsiteDataStore::processNextQueuedWebPushMessage()
{
    if (m_queuedWebPushMessages.isEmpty()) {
        m_pumpingWebPushMessages = false;
        if (std::exchange(m_repumpWebPushMessages, false))
            pumpPendingWebPushMessages();
        return;
    }

    auto message = m_queuedWebPushMessages.takeFirst();
    processPushMessage(WTF::move(message), [this, protectedThis = Ref { *this }](bool) {
        processNextQueuedWebPushMessage();
    });
}

// The clients.openWindow fallback: hand the URL to the host app's ordinary URL handling, since Safari 7
// implements no data-store client that could create a page. HTTP(S) only: a service worker must not be
// able to launch arbitrary URL schemes.
void WebsiteDataStore::openURLThroughHostApplication(const URL& url)
{
    if (!url.protocolIsInHTTPFamily()) {
        RELEASE_LOG_ERROR(Push, "Refusing to open non-HTTP URL from a service worker");
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:url.createNSURL().get()];
}

} // namespace WebKit

#endif // USE(MOZILLA_PUSH_SERVICE)
