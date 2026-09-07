/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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
#import "Download.h"
// MAVERICKS_BACKPORT: resume request, cookie context and credential policy have one validated native/IPC representation.
#include "CocoaDownloadResumeData.h"

#import "DownloadProxyMessages.h"
#import "Logging.h"
// MAVERICKS_BACKPORT: resume enters the existing NetworkLoad client and destination policy.
#import "NetworkLoadParameters.h"
#import "PendingDownload.h"
#import "MessageSenderInlines.h"
#import <WebCore/ResourceError.h>
#import <WebCore/LocalFrameLoaderClient.h>
#import <wtf/text/MakeString.h>
#import "NetworkSessionCocoa.h"
#import "WKDownloadProgress.h"
#import <pal/spi/cf/CFNetworkSPI.h>
#import <pal/spi/cocoa/NSProgressSPI.h>
#import <wtf/BlockPtr.h>
// MAVERICKS_BACKPORT: failed resume validation releases the consumed destination authorization.
#import <wtf/Scope.h>
// MAVERICKS_BACKPORT: resume restores validated request headers and transport policy.
#import <WebCore/CocoaDownloadTransport.h>
#import <wtf/FileSystem.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>

#define DOWNLOAD_RELEASE_LOG(fmt, ...) RELEASE_LOG(Network, "[downloadID=%" PRIu64 "] Download::" fmt, m_downloadID.toUInt64(), ##__VA_ARGS__)
#define DOWNLOAD_RELEASE_LOG_ERROR(fmt, ...) RELEASE_LOG_ERROR(Network, "[downloadID=%" PRIu64 "] Download::" fmt, m_downloadID.toUInt64(), ##__VA_ARGS__)

namespace WebKit {

// MAVERICKS_BACKPORT: retain upstream NSURLSession implementation beside the curl resume owner.
#if 0
void Download::resume(std::span<const uint8_t> resumeData, const String& path, SandboxExtension::Handle&& sandboxExtensionHandle, std::span<const uint8_t> activityAccessToken)
{
    m_sandboxExtension = SandboxExtension::create(WTF::move(sandboxExtensionHandle));
    if (RefPtr extension = m_sandboxExtension)
        extension->consume();

    CheckedPtr networkSession = m_downloadManager->client().networkSession(m_sessionID);
    if (!networkSession) {
        DOWNLOAD_RELEASE_LOG("resume: Could not find network session with given session ID");
        return;
    }
    CheckedRef cocoaSession = downcast<NetworkSessionCocoa>(*networkSession);
    RetainPtr nsData = toNSData(resumeData);

    RetainPtr dictionary = [NSPropertyListSerialization propertyListWithData:nsData.get() options:NSPropertyListMutableContainersAndLeaves format:0 error:nullptr];
    [dictionary setObject:path.createNSString().get() forKey:@"NSURLSessionResumeInfoLocalPath"];
    RetainPtr updatedData = [NSPropertyListSerialization dataWithPropertyList:dictionary.get() format:NSPropertyListXMLFormat_v1_0 options:0 error:nullptr];

    // FIXME: Use nsData instead of updatedData once we've migrated from _WKDownload to WKDownload
    // because there's no reason to set the local path we got from the data back into the data.
    m_downloadTask = [cocoaSession->sessionWrapperForDownloadResume().session downloadTaskWithResumeData:updatedData.get()];
    if (!m_downloadTask) {
        DOWNLOAD_RELEASE_LOG_ERROR("resume: Could not create download task from resume data");
        return;
    }
    auto taskIdentifier = [m_downloadTask taskIdentifier];
    if (!taskIdentifier) {
        DOWNLOAD_RELEASE_LOG_ERROR("resume: Could not resume download, since task identifier is 0");
        return;
    }
    ASSERT(!cocoaSession->sessionWrapperForDownloadResume().downloadMap.contains(taskIdentifier));
    cocoaSession->sessionWrapperForDownloadResume().downloadMap.add(taskIdentifier, m_downloadID);
    m_downloadTask.get()._pathToDownloadTaskFile = path.createNSString().get();

    [m_downloadTask resume];

#if HAVE(MODERN_DOWNLOADPROGRESS)
    if (RetainPtr<NSData> placeholderURLBookmark = [dictionary objectForKey:@"ResumePlaceholderURLBookmarkData"]) {
        RetainPtr nsActivityAccessToken = toNSData(activityAccessToken);
        RetainPtr pathString  = adoptNS([[NSString alloc] initWithUTF8String:WTF::FileSystemImpl::fileSystemRepresentation(path).data()]);
        RetainPtr destinationURL = adoptNS([[NSURL alloc] initFileURLWithPath:pathString.get() isDirectory:NO]);

        BOOL bookmarkDataIsStale = NO;
        NSError *bookmarkResolvingError = nil;
        RetainPtr placeholderURL = adoptNS([[NSURL alloc] initByResolvingBookmarkData:placeholderURLBookmark.get() options:0 relativeToURL:nil bookmarkDataIsStale:&bookmarkDataIsStale error:&bookmarkResolvingError]);
        BOOL usingSecurityScopedURL = [placeholderURL startAccessingSecurityScopedResource];

        if (placeholderURL) {
            m_progress = adoptNS([[WKModernDownloadProgress alloc] initWithDownloadTask:m_downloadTask.get() download:*this URL:destinationURL.get() useDownloadPlaceholder:YES resumePlaceholderURL:placeholderURL.get() liveActivityAccessToken:nsActivityAccessToken.get()]);
            startUpdatingProgress();
        } else
            DOWNLOAD_RELEASE_LOG_ERROR("resume: unable to create resume placeholder URL, error = %@", bookmarkResolvingError);

        if (usingSecurityScopedURL)
            [placeholderURL stopAccessingSecurityScopedResource];

        m_placeholderURL = placeholderURL;
    }
#else
    UNUSED_PARAM(activityAccessToken);
#endif
}
    
#endif // MAVERICKS_BACKPORT: resumed HTTP requests use the same transport as initial requests.

// MAVERICKS_BACKPORT: NSURLSession's public resume fields remain the Safari API serialization format.
void DownloadManager::resumeDownload(PAL::SessionID sessionID, DownloadID downloadID, std::span<const uint8_t> resumeData, const String& path, SandboxExtension::Handle&& sandboxExtensionHandle, CallDownloadDidStart callDownloadDidStart, std::span<const uint8_t> activityAccessToken)
{
    UNUSED_PARAM(activityAccessToken);
    CheckedPtr session = m_client->networkSession(sessionID);
    if (!session)
        return;
    auto fail = [&](NSInteger code, NSString *description) {
        if (RefPtr connection = downloadProxyConnection())
            connection->send(Messages::DownloadProxy::DidFail(WebCore::ResourceError([NSError errorWithDomain:NSURLErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: description }]), { }), downloadID);
    };
    auto information = CocoaDownloadResumeData::fromData(resumeData);
    if (!information || path.isEmpty()) {
        fail(NSURLErrorCannotDecodeContentData, @"Invalid download resume information");
        return;
    }
    if (information->sessionID != sessionID) {
        fail(NSURLErrorCancelled, @"The resume information belongs to a different storage session");
        return;
    }
    DownloadResumeParameters resume;
    resume.destination = path;
    resume.offset = information->bytesReceived;
    resume.entityTag = information->entityTag;
    resume.lastModified = information->lastModified;
    resume.callDidStart = callDownloadDidStart == CallDownloadDidStart::Yes;
    resume.sandboxExtension = SandboxExtension::create(WTF::move(sandboxExtensionHandle));
    auto revokeExtension = makeScopeExit([&] {
        if (resume.sandboxExtension)
            resume.sandboxExtension->revoke();
    });
    if (resume.sandboxExtension && !resume.sandboxExtension->consume()) {
        fail(NSURLErrorNoPermissionsToReadFile, @"The partial download could not be authorized");
        return;
    }
    if (FileSystem::fileSize(path) != resume.offset) {
        fail(NSURLErrorCannotOpenFile, @"The partial download does not match its resume information");
        return;
    }
    NetworkLoadParameters parameters;
    // MAVERICKS_BACKPORT: preserve the original validated request and credential policy across both native resume APIs.
    parameters.request = WTF::move(information->request);
    parameters.request.setHTTPHeaderField(WebCore::HTTPHeaderName::Range, makeString("bytes="_s, resume.offset, '-'));
    auto validator = !resume.entityTag.isEmpty() && !resume.entityTag.startsWith("W/"_s) ? resume.entityTag : resume.lastModified;
    if (validator.isEmpty()) {
        fail(NSURLErrorCannotDecodeContentData, @"The partial download has no representation validator");
        return;
    }
    parameters.request.setHTTPHeaderField(WebCore::HTTPHeaderName::IfRange, validator);
    parameters.storedCredentialsPolicy = information->storedCredentialsPolicy;
    parameters.clientCredentialPolicy = WebCore::ClientCredentialPolicy::MayAskClientForCredentials;
    parameters.contentSniffingPolicy = WebCore::ContentSniffingPolicy::DoNotSniffContent;
    parameters.downloadResume = WTF::move(resume);
    ASSERT(!m_pendingDownloads.contains(downloadID) && !m_downloads.contains(downloadID));
    m_pendingDownloads.add(downloadID, PendingDownload::create(protect(m_client->parentProcessConnectionForDownloads()).get(), WTF::move(parameters), downloadID, *session, { }, WebCore::FromDownloadAttribute::No, std::nullopt));
}

void Download::platformCancelNetworkLoad(CompletionHandler<void(std::span<const uint8_t>)>&& completionHandler)
{
    ASSERT(isMainRunLoop());
    ASSERT(m_downloadTask);
    [m_downloadTask cancelByProducingResumeData:makeBlockPtr([completionHandler = WTF::move(completionHandler), placeholderURL = m_placeholderURL] (NSData *resumeData) mutable {
        ensureOnMainRunLoop([resumeData = retainPtr(resumeData), completionHandler = WTF::move(completionHandler), placeholderURL = WTF::move(placeholderURL)] () mutable  {
#if HAVE(MODERN_DOWNLOADPROGRESS)
            auto resumeDataWithPlaceholder = updateResumeDataWithPlaceholderURL(placeholderURL.get(), span(resumeData.get()));
            completionHandler(resumeDataWithPlaceholder.span());
#else
            completionHandler(span(resumeData.get()));
#endif
        });
    }).get()];
}

void Download::platformDestroyDownload()
{
#if HAVE(MODERN_DOWNLOADPROGRESS)
    if (enableModernDownloadProgress()) {
        m_bookmarkURL = nil;
        [m_progress cancel];
        return;
    }
#endif
    if (m_progress)
#if HAVE(NSPROGRESS_PUBLISHING_SPI)
        [m_progress _unpublish];
#else
        [m_progress unpublish];
#endif // HAVE(NSPROGRESS_PUBLISHING_SPI)
}

#if HAVE(MODERN_DOWNLOADPROGRESS)
void Download::publishProgress(const URL& url, std::span<const uint8_t> bookmarkData, UseDownloadPlaceholder useDownloadPlaceholder, std::span<const uint8_t> activityAccessToken)
{
    DOWNLOAD_RELEASE_LOG("publishProgress: isUsingPlaceholder=%d", useDownloadPlaceholder == WebKit::UseDownloadPlaceholder::Yes);

    if (m_progress) {
        DOWNLOAD_RELEASE_LOG("publishProgress: Progress is already being published for download.");
        return;
    }

    RetainPtr bookmark = toNSData(bookmarkData);
    m_bookmarkData = bookmark;

    RetainPtr accessToken = toNSData(activityAccessToken);

    BOOL bookmarkIsStale = NO;
    NSError* error = nil;
    m_bookmarkURL = [NSURL URLByResolvingBookmarkData:m_bookmarkData.get() options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&bookmarkIsStale error:&error];
    ASSERT(m_bookmarkURL);
    if (!m_bookmarkURL)
        DOWNLOAD_RELEASE_LOG("publishProgress: Unable to create bookmark URL, error = %@", error);

    if (enableModernDownloadProgress()) {
        RetainPtr publishURL = url.createNSURL();
        if (!publishURL) {
            DOWNLOAD_RELEASE_LOG("publishProgress: Invalid publish URL");
            return;
        }

        bool isUsingPlaceholder = useDownloadPlaceholder == WebKit::UseDownloadPlaceholder::Yes;

        m_progress = adoptNS([[WKModernDownloadProgress alloc] initWithDownloadTask:m_downloadTask.get() download:*this URL:publishURL.get() useDownloadPlaceholder:isUsingPlaceholder resumePlaceholderURL:nil liveActivityAccessToken:accessToken.get()]);

        // If we are using a placeholder, we will delay updating progress until the client has received the placeholder URL.
        // This is to make sure the placeholder has not been moved to the final download URL before the client received the placeholder URL.
        if (!isUsingPlaceholder)
            startUpdatingProgress();
    } else {
        m_progress = adoptNS([[WKDownloadProgress alloc] initWithDownloadTask:m_downloadTask.get() download:*this URL:url.createNSURL().get() sandboxExtension:nullptr]);
#if HAVE(NSPROGRESS_PUBLISHING_SPI)
        [m_progress _publish];
#else
        [m_progress publish];
#endif
    }
}

void Download::setPlaceholderURL(NSURL *placeholderURL, NSData *bookmarkData)
{
    DOWNLOAD_RELEASE_LOG("setPlaceholderURL");

    if (!placeholderURL)
        return;

    m_placeholderURL = placeholderURL;

    BOOL usingSecurityScopedURL = [placeholderURL startAccessingSecurityScopedResource];

    SandboxExtension::Handle sandboxExtensionHandle;
    if (auto handle = SandboxExtension::createHandleWithoutResolvingPath(String::fromUTF8(placeholderURL.fileSystemRepresentation), SandboxExtension::Type::ReadOnly))
        sandboxExtensionHandle = WTF::move(*handle);

    if (usingSecurityScopedURL)
        [placeholderURL stopAccessingSecurityScopedResource];

    CompletionHandler<void()> completionHandler = [weakThis = WeakPtr { *this }, this] {
        if (!weakThis)
            return;
        // Start updating download progress when the client has received the placeholder URL.
        // Otherwise, the placeholder might have been deleted by the time the client receives it.
        startUpdatingProgress();
    };

    sendWithAsyncReply(Messages::DownloadProxy::DidReceivePlaceholderURL(placeholderURL, span(bookmarkData), WTF::move(sandboxExtensionHandle)), WTF::move(completionHandler));
}

void Download::setFinalURL(NSURL *finalURL, NSData *bookmarkData)
{
    DOWNLOAD_RELEASE_LOG("setFinalURL");

    if (!finalURL)
        return;

    BOOL usingSecurityScopedURL = [finalURL startAccessingSecurityScopedResource];

    SandboxExtension::Handle sandboxExtensionHandle;
    if (auto handle = SandboxExtension::createHandleWithoutResolvingPath(String::fromUTF8(finalURL.fileSystemRepresentation), SandboxExtension::Type::ReadOnly))
        sandboxExtensionHandle = WTF::move(*handle);

    if (usingSecurityScopedURL)
        [finalURL stopAccessingSecurityScopedResource];

    send(Messages::DownloadProxy::DidReceiveFinalURL(finalURL, span(bookmarkData), WTF::move(sandboxExtensionHandle)));
}

void Download::startUpdatingProgress()
{
    DOWNLOAD_RELEASE_LOG("startUpdatingProgress");

    m_canUpdateProgress = true;

    if (![m_progress isKindOfClass:WKModernDownloadProgress.class])
        return;

    auto *progress = (WKModernDownloadProgress *)m_progress;
    [progress startUpdatingDownloadProgress];

    send(Messages::DownloadProxy::DidStartUpdatingProgress());

    // If we have a download task, progress is updated by observing this task. See startUpdatingDownloadProgress method.
    if (m_downloadTask)
        return;

    if (!m_totalBytesWritten || !m_totalBytesExpectedToWrite)
        return;

    DOWNLOAD_RELEASE_LOG("startUpdatingProgress: m_totalBytesWritten=%llu, m_totalBytesExpectedToWrite=%llu", *m_totalBytesWritten, *m_totalBytesExpectedToWrite);

    // It's important to update totalUnitCount first, otherwise NSProgress may consider the download finished.
    progress.totalUnitCount = *m_totalBytesExpectedToWrite;
    progress.completedUnitCount = *m_totalBytesWritten;
}

void Download::updateProgress(uint64_t totalBytesWritten, uint64_t totalBytesExpectedToWrite)
{
    m_totalBytesWritten = totalBytesWritten;
    m_totalBytesExpectedToWrite = totalBytesExpectedToWrite;

    if (!m_canUpdateProgress || ![m_progress isKindOfClass:WKModernDownloadProgress.class])
        return;

    // If we have a download task, progress is updated by observing this task. See startUpdatingDownloadProgress method.
    if (m_downloadTask)
        return;

    auto *progress = (WKModernDownloadProgress *)m_progress;
    progress.totalUnitCount = totalBytesExpectedToWrite;
    progress.completedUnitCount = totalBytesWritten;
}

Vector<uint8_t> Download::updateResumeDataWithPlaceholderURL(NSURL *placeholderURL, std::span<const uint8_t> resumeData)
{
    if (!placeholderURL) {
        RELEASE_LOG_ERROR(Network, "Download::updateResumeDataWithPlaceholderURL: placeholderURL equals nil.");
        return resumeData;
    }

    BOOL usingSecurityScopedURL = [placeholderURL startAccessingSecurityScopedResource];

    NSError *bookmarkError = nil;
    RetainPtr bookmarkData = [placeholderURL bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];

    if (!bookmarkData) {
        RELEASE_LOG_ERROR(Network, "Download::updateResumeDataWithPlaceholderURL: could not create bookmark data from placeholderURL.");
        return resumeData;
    }

    RetainPtr data = toNSData(resumeData);
    RetainPtr dictionary = [NSPropertyListSerialization propertyListWithData:data.get() options:NSPropertyListMutableContainersAndLeaves format:0 error:nullptr];
    [dictionary setObject:bookmarkData.get() forKey:@"ResumePlaceholderURLBookmarkData"];
    NSError *error = nil;
    RetainPtr updatedData = [NSPropertyListSerialization dataWithPropertyList:dictionary.get() format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];

    if (usingSecurityScopedURL)
        [placeholderURL stopAccessingSecurityScopedResource];

    return makeVector(updatedData.get());
}
#else
void Download::publishProgress(const URL& url, SandboxExtension::Handle&& sandboxExtensionHandle)
{
    ASSERT(!m_progress);
    ASSERT(url.isValid());

    auto sandboxExtension = SandboxExtension::create(WTF::move(sandboxExtensionHandle));

    ASSERT(sandboxExtension);
    if (!sandboxExtension)
        return;

    m_progress = adoptNS([[WKDownloadProgress alloc] initWithDownloadTask:m_downloadTask.get() download:*this URL:url.createNSURL().get() sandboxExtension:sandboxExtension]);
#if HAVE(NSPROGRESS_PUBLISHING_SPI)
    [m_progress _publish];
#else
    [m_progress publish];
#endif
}
#endif

void Download::platformDidFinish(CompletionHandler<void()>&& completionHandler)
{
#if HAVE(MODERN_DOWNLOADPROGRESS)
    if (m_progress && [m_progress isKindOfClass:WKModernDownloadProgress.class]) {
        auto *progress = (WKModernDownloadProgress *)m_progress;
        [progress didFinish:makeBlockPtr(WTF::move(completionHandler)).get()];
        return;
    }
#endif
    completionHandler();
}

}
