/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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

#import "config.h"
#import "DownloadProxy.h"
// MAVERICKS_BACKPORT: native cancellation releases the same typed proxy registration as asynchronous cancellation.
#import "DownloadProxyMap.h"

// MAVERICKS_BACKPORT: API::Data is used directly by legacyResumeDataForNSURLDownload() below.
#import "APIData.h"
#import "APIDownloadClient.h"
#import "NetworkProcessMessages.h"
#import "NetworkProcessProxy.h"
#import "CocoaDownloadResumeData.h" // MAVERICKS_BACKPORT: rebuild the native API representation from a typed IPC result.
#import "WebsiteDataStore.h"

#import <wtf/cocoa/SpanCocoa.h>
// MAVERICKS_BACKPORT: dynamic_objc_cast<> for the resume-data translation below.
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>

#if HAVE(MODERN_DOWNLOADPROGRESS)
#import <BrowserEngineKit/BrowserEngineKit.h>
#endif

namespace WebKit {

// MAVERICKS_BACKPORT: preserve NSURLDownload's synchronous cancellation contract without running the UI run loop.
void DownloadProxy::didResumeWithResponse(const WebCore::ResourceResponse& response, uint64_t offset)
{
    protect(client())->didResumeWithResponse(*this, response, offset);
}

// MAVERICKS_BACKPORT: close the remote download before exposing native resume information.
RefPtr<API::Data> DownloadProxy::cancelForLegacyResume()
{
    Ref protectedThis { *this };
    m_downloadIsCancelled = true;
    if (!m_dataStore)
        return nullptr;
    auto result = m_dataStore->networkProcess().sendSync(Messages::NetworkProcess::CancelDownloadForLegacyResume(m_downloadID), 0, IPC::Timeout::infinity());
    if (!result.succeeded())
        return nullptr;
    auto [data] = result.takeReply();
    // MAVERICKS_BACKPORT: the optional typed reply owns nullable API data at the legacy boundary.
    m_legacyResumeData = data ? RefPtr<API::Data>(API::Data::create(data->serializedData().span())) : nullptr;
    auto legacy = legacyResumeDataForNSURLDownload();
    if (RefPtr map = m_downloadProxyMap.get())
        map->downloadFinished(*this);
    return legacy;
}

void DownloadProxy::publishProgress(const URL& url)
{
    if (!m_dataStore)
        return;

#if HAVE(MODERN_DOWNLOADPROGRESS)
    RetainPtr localURL = adoptNS([[NSURL alloc] initFileURLWithPath:url.fileSystemPath().createNSString().get() relativeToURL:nil]);
    NSError *error = nil;
    RetainPtr bookmark = [localURL bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    m_dataStore->networkProcess().send(Messages::NetworkProcess::PublishDownloadProgress(m_downloadID, url, span(bookmark.get()), UseDownloadPlaceholder::No, activityAccessToken().span()), 0);
#else
    auto handle = SandboxExtension::createHandle(url.fileSystemPath(), SandboxExtension::Type::ReadWrite);
    ASSERT(handle);
    if (!handle)
        return;

    protect(protect(m_dataStore)->networkProcess())->send(Messages::NetworkProcess::PublishDownloadProgress(m_downloadID, url, WTF::move(*handle)), 0);
#endif
}

#if HAVE(MODERN_DOWNLOADPROGRESS)
void DownloadProxy::didReceivePlaceholderURL(const URL& placeholderURL, std::span<const uint8_t> bookmarkData, WebKit::SandboxExtensionHandle&& handle, CompletionHandler<void()>&& completionHandler)
{
    if (auto placeholderFileExtension = SandboxExtension::create(WTF::move(handle))) {
        bool ok = placeholderFileExtension->consume();
        ASSERT_UNUSED(ok, ok);
    }
    m_client->didReceivePlaceholderURL(*this, placeholderURL, bookmarkData, WTF::move(completionHandler));
}

void DownloadProxy::didReceiveFinalURL(const URL& finalURL, std::span<const uint8_t> bookmarkData, WebKit::SandboxExtensionHandle&& handle)
{
    if (auto completedFileExtension = SandboxExtension::create(WTF::move(handle))) {
        bool ok = completedFileExtension->consume();
        ASSERT_UNUSED(ok, ok);
    }
    m_client->didReceiveFinalURL(*this, finalURL, bookmarkData);
}

void DownloadProxy::didStartUpdatingProgress()
{
    m_assertion = nullptr;
}

Vector<uint8_t> DownloadProxy::bookmarkDataForURL(const URL& url)
{
    RetainPtr localURL = adoptNS([[NSURL alloc] initFileURLWithPath:url.fileSystemPath().createNSString().get() relativeToURL:nil]);
    NSError *error = nil;
    RetainPtr bookmark = [localURL bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    return span(bookmark.get());
}

Vector<uint8_t> DownloadProxy::activityAccessToken()
{
    return makeVector([BEDownloadMonitor createAccessToken]);
}

#endif

// MAVERICKS_BACKPORT: WebKitNetworkProcessResumeData retains the curl request and its NetworkProcess owner.
// Safari 7 passes this dictionary to WebKitLegacy's -[WebDownload _initWithResumeInformation:delegate:path:].
// The URL, byte count and validators use the NSURLDownload keys consumed by that API; its destination
// comes from Safari's path argument. The NetworkProcess session owns the cookies and transport state.
RefPtr<API::Data> DownloadProxy::legacyResumeDataForNSURLDownload() const
{
    RefPtr resumeData = m_legacyResumeData;
    if (!resumeData)
        return nullptr;

    RetainPtr sessionInfo = dynamic_objc_cast<NSDictionary>([NSPropertyListSerialization propertyListWithData:toNSData(resumeData->span()).get() options:NSPropertyListImmutable format:nullptr error:nullptr]);
    if (!sessionInfo)
        return nullptr;

    RetainPtr url = dynamic_objc_cast<NSString>([sessionInfo objectForKey:@"NSURLSessionDownloadURL"]);
    RetainPtr bytesReceived = dynamic_objc_cast<NSNumber>([sessionInfo objectForKey:@"NSURLSessionResumeBytesReceived"]);
    if (!url || !bytesReceived)
        return nullptr;

    RetainPtr downloadInfo = adoptNS([[NSMutableDictionary alloc] init]);
    // MAVERICKS_BACKPORT: resume through the original NetworkProcess session and its cookie storage.
    [downloadInfo setObject:toNSData(resumeData->span()).get() forKey:@"WebKitNetworkProcessResumeData"];
    [downloadInfo setObject:url.get() forKey:@"NSURLDownloadURL"];
    [downloadInfo setObject:bytesReceived.get() forKey:@"NSURLDownloadBytesReceived"];
    if (RetainPtr entityTag = dynamic_objc_cast<NSString>([sessionInfo objectForKey:@"NSURLSessionResumeEntityTag"]))
        [downloadInfo setObject:entityTag.get() forKey:@"NSURLDownloadEntityTag"];
    if (RetainPtr modificationDate = dynamic_objc_cast<NSString>([sessionInfo objectForKey:@"NSURLSessionResumeServerDownloadDate"]))
        [downloadInfo setObject:modificationDate.get() forKey:@"NSURLDownloadServerModificationDate"];

    // MAVERICKS_BACKPORT: the curl resume contract retains the originating jar and request's SameSite context.
    for (NSString* key in @[@"WebKitRequest", @"WebKitStorageSessionIdentifier", @"WebKitStoredCredentialsPolicy", @"WebKitFirstPartyForCookies", @"WebKitIsTopSite", @"WebKitSameSiteDisposition"]) {
        if (id value = [sessionInfo objectForKey:key])
            [downloadInfo setObject:value forKey:key];
    }

    RetainPtr data = [NSPropertyListSerialization dataWithPropertyList:downloadInfo.get() format:NSPropertyListXMLFormat_v1_0 options:0 error:nullptr];
    if (!data)
        return nullptr;

    m_legacyResumeDataForNSURLDownload = API::Data::create(span(data.get()));
    return m_legacyResumeDataForNSURLDownload;
}

}
