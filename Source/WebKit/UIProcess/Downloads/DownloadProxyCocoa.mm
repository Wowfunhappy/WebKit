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

// MAVERICKS_BACKPORT: API::Data is used directly by legacyResumeDataForNSURLDownload() below.
#import "APIData.h"
#import "APIDownloadClient.h"
#import "NetworkProcessMessages.h"
#import "NetworkProcessProxy.h"
#import "WebsiteDataStore.h"

#import <wtf/cocoa/SpanCocoa.h>
// MAVERICKS_BACKPORT: dynamic_objc_cast<> for the resume-data translation below.
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>

#if HAVE(MODERN_DOWNLOADPROGRESS)
#import <BrowserEngineKit/BrowserEngineKit.h>
#endif

namespace WebKit {

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

// MAVERICKS_BACKPORT: translate NSURLSession resume data into the CFURLDownload resume dictionary that
// Safari 7's resume path consumes (github #11 / download resume).
//
// Safari 7 has NO WK2 resume API -- it imports WKDownloadGetResumeData and WKDownloadCancel and nothing
// else, and resumes with WebKitLegacy: -[DownloadProgressEntry resume] builds
// -[WebDownload _initWithResumeInformation:delegate:path:], i.e. Foundation's NSURLDownload, which
// hands the dictionary to CFURLDownloadCreateWithResumeInformation. In Safari 7's own era WK2 downloads
// WERE CFURLDownloads, so the blob it got back was already in that format; a modern WebKit produces
// NSURLSession resume data instead, whose keys that consumer does not read. It would find no URL and no
// byte count, fail, and Safari would silently restart the download from zero.
//
// The two formats carry the same facts under different names, so this is a rename, not an invention.
// Measured on 10.9.5 by cancelling a real NSURLSession download (keys and types both verified):
//   NSURLSessionDownloadURL              (string) -> NSURLDownloadURL
//   NSURLSessionResumeBytesReceived      (number) -> NSURLDownloadBytesReceived
//   NSURLSessionResumeEntityTag          (string) -> NSURLDownloadEntityTag
//   NSURLSessionResumeServerDownloadDate (string) -> NSURLDownloadServerModificationDate
// URLDownload::_internal_downloadFillInDownloadWithResumeInformation (CFNetwork 673.3) requires the
// first two, type-checks the URL/tag/date as CFString and the count as CFNumber, and uses the tag and
// date to make the range request conditional -- so a resume that would silently splice a changed file
// is refused by the server rather than by us. The remaining NSURLSession keys are meaningless here: the
// archived NSURLRequests are rebuilt from the URL by CFURLDownload, ResumeInfoVersion is NSURLSession's
// own, and ResumeInfoLocalPath named CFNetwork's temp file, which no longer exists because
// _pathToDownloadTaskFile now streams into the file Safari nominated (see the polyfill of that property
// in MavericksSupport/polyfill/polyfills/methods.m -- and Safari passes that same path to
// _initWithResumeInformation:delegate:path: itself, so it must not come from here).
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
    [downloadInfo setObject:url.get() forKey:@"NSURLDownloadURL"];
    [downloadInfo setObject:bytesReceived.get() forKey:@"NSURLDownloadBytesReceived"];
    if (RetainPtr entityTag = dynamic_objc_cast<NSString>([sessionInfo objectForKey:@"NSURLSessionResumeEntityTag"]))
        [downloadInfo setObject:entityTag.get() forKey:@"NSURLDownloadEntityTag"];
    if (RetainPtr modificationDate = dynamic_objc_cast<NSString>([sessionInfo objectForKey:@"NSURLSessionResumeServerDownloadDate"]))
        [downloadInfo setObject:modificationDate.get() forKey:@"NSURLDownloadServerModificationDate"];

    RetainPtr data = [NSPropertyListSerialization dataWithPropertyList:downloadInfo.get() format:NSPropertyListXMLFormat_v1_0 options:0 error:nullptr];
    if (!data)
        return nullptr;

    m_legacyResumeDataForNSURLDownload = API::Data::create(span(data.get()));
    return m_legacyResumeDataForNSURLDownload;
}

}
