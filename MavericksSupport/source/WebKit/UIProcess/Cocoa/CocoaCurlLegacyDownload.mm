/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import "config.h"
#import "APIData.h"
#import "APIDownloadClient.h"
#import "AuthenticationChallengeProxy.h"
#import "AuthenticationDecisionListener.h"
#import "DownloadManager.h"
#import <wtf/WeakObjCPtr.h>
#import "DownloadProxy.h"
#import "WebsiteDataStore.h"
#import <WebCore/CocoaDownloadTransport.h>
#import <WebCore/CocoaCurlAuthentication.h>
#import <WebCore/ResourceError.h>
#import <WebCore/ResourceResponse.h>
#import <wtf/FileSystem.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

// Safari 7's WebDownload facade resumes WK2 transfers through the original NetworkProcess owner and native challenge/delegate contract.
namespace WebKit { class CocoaCurlLegacyDownloadClient; }
@interface WKCocoaCurlLegacyDownload : NSObject <WebCoreCocoaDownloadTransport> {
@public
    RefPtr<WebKit::WebsiteDataStore> _store;
    RefPtr<WebKit::DownloadProxy> _proxy;
    RetainPtr<NSURLDownload> _download;
    RetainPtr<id<NSURLDownloadDelegate>> _delegate;
    RetainPtr<NSDictionary> _information;
    RetainPtr<NSString> _path;
    RetainPtr<NSString> _directory; // native directory configuration is distinct from the resumed file destination.
    RetainPtr<NSURLRequest> _request;
    RetainPtr<NSURLAuthenticationChallenge> _challenge;
    bool _started;
    bool _finished;
    bool _deleteOnFailure;
    bool _ownsDestination;
}
- (void)finish:(NSError*)error cancelled:(BOOL)cancelled;
@end

namespace WebKit {
using namespace WebCore;
class CocoaCurlLegacyDownloadClient final : public API::DownloadClient {
public:
    static Ref<CocoaCurlLegacyDownloadClient> create(WKCocoaCurlLegacyDownload* owner) { return adoptRef(*new CocoaCurlLegacyDownloadClient(owner)); }
private:
    explicit CocoaCurlLegacyDownloadClient(WKCocoaCurlLegacyDownload* owner) : m_owner(owner) { }
    void legacyDidStart(DownloadProxy& proxy) final
    {
        RetainPtr owner = m_owner.get();
        if (owner && !owner->_finished)
            owner->_request = proxy.request().nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody);
    }
    void didReceiveData(DownloadProxy&, uint64_t written, uint64_t, uint64_t) final
    {
        RetainPtr owner = m_owner.get();
        if (owner && !owner->_finished && [owner->_delegate respondsToSelector:@selector(download:didReceiveDataOfLength:)])
            [owner->_delegate download:owner->_download.get() didReceiveDataOfLength:written];
    }
    void didResumeWithResponse(DownloadProxy&, const ResourceResponse& response, uint64_t offset) final
    {
        RetainPtr owner = m_owner.get();
        if (!owner || owner->_finished)
            return;
        if ([owner->_delegate respondsToSelector:@selector(download:didReceiveResponse:)])
            [owner->_delegate download:owner->_download.get() didReceiveResponse:response.nsURLResponse()];
        if (!owner->_finished && [owner->_delegate respondsToSelector:@selector(download:willResumeWithResponse:fromByte:)])
            [owner->_delegate download:owner->_download.get() willResumeWithResponse:response.nsURLResponse() fromByte:offset];
    }
    void didCreateDestination(DownloadProxy&, const String& path) final
    {
        RetainPtr owner = m_owner.get();
        if (owner && !owner->_finished) {
            owner->_ownsDestination = true;
            if ([owner->_delegate respondsToSelector:@selector(download:didCreateDestination:)])
                [owner->_delegate download:owner->_download.get() didCreateDestination:path.createNSString().get()];
        }
    }
    void didFinish(DownloadProxy&) final
    {
        RetainPtr owner = m_owner.get();
        [owner finish:nil cancelled:NO];
    }
    void didFail(DownloadProxy& proxy, const ResourceError& error, API::Data*) final
    {
        RetainPtr owner = m_owner.get();
        if (!owner || owner->_finished)
            return;
        if (auto resume = proxy.legacyResumeDataForNSURLDownload())
            owner->_information = dynamic_objc_cast<NSDictionary>([NSPropertyListSerialization propertyListWithData:toNSData(resume->span()).get() options:NSPropertyListImmutable format:nil error:nil]);
        [owner finish:error.nsError() cancelled:NO];
    }
    void processDidCrash(DownloadProxy&) final
    {
        RetainPtr owner = m_owner.get();
        [owner finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:@{ NSLocalizedDescriptionKey: @"The download's network process exited" }] cancelled:NO];
    }
    void willSendRequest(DownloadProxy&, ResourceRequest&& request, const ResourceResponse& response, CompletionHandler<void(ResourceRequest&&)>&& completion) final
    {
        RetainPtr owner = m_owner.get();
        if (!owner || owner->_finished) {
            completion({ });
            return;
        }
        RetainPtr approved = request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody);
        if ([owner->_delegate respondsToSelector:@selector(download:willSendRequest:redirectResponse:)])
            approved = [owner->_delegate download:owner->_download.get() willSendRequest:approved.get() redirectResponse:response.isNull() ? nil : response.nsURLResponse()];
        owner->_request = approved;
        completion(owner->_finished || !approved ? ResourceRequest() : ResourceRequest(approved.get()));
    }
    void didReceiveAuthenticationChallenge(DownloadProxy&, AuthenticationChallengeProxy& proxyChallenge) final
    {
        RetainPtr owner = m_owner.get();
        if (!owner || owner->_finished) {
            proxyChallenge.listener().completeChallenge(AuthenticationChallengeDisposition::Cancel);
            return;
        }
        auto& core = proxyChallenge.core();
        owner->_challenge = cocoaCurlAuthenticationChallenge(core.protectionSpace(), core.proposedCredential(), core.previousFailureCount(), core.failureResponse(), core.error(), [challenge = Ref { proxyChallenge }](CocoaCurlAuthenticationDisposition disposition, RetainPtr<NSURLCredential>&& credential) {
            AuthenticationChallengeDisposition decision;
            switch (disposition) {
            case CocoaCurlAuthenticationDisposition::UseCredential: decision = AuthenticationChallengeDisposition::UseCredential; break;
            case CocoaCurlAuthenticationDisposition::ContinueWithoutCredential: decision = AuthenticationChallengeDisposition::UseCredential; break;
            case CocoaCurlAuthenticationDisposition::Cancel: decision = AuthenticationChallengeDisposition::Cancel; break;
            case CocoaCurlAuthenticationDisposition::PerformDefaultHandling: decision = AuthenticationChallengeDisposition::PerformDefaultHandling; break;
            case CocoaCurlAuthenticationDisposition::RejectProtectionSpace: decision = AuthenticationChallengeDisposition::RejectProtectionSpaceAndContinue; break;
            }
            challenge->listener().completeChallenge(decision, Credential(credential.get()));
        });
        if ([owner->_delegate respondsToSelector:@selector(download:didReceiveAuthenticationChallenge:)])
            [owner->_delegate download:owner->_download.get() didReceiveAuthenticationChallenge:owner->_challenge.get()];
        else
            [owner->_challenge.get().sender performDefaultHandlingForAuthenticationChallenge:owner->_challenge.get()];
    }
    WeakObjCPtr<WKCocoaCurlLegacyDownload> m_owner;
};

static RetainPtr<id<WebCoreCocoaDownloadTransport>> createLegacyResume(NSURLDownload* download, id<NSURLDownloadDelegate> delegate, NSDictionary* information, NSString* path)
{
    auto owner = adoptNS([[WKCocoaCurlLegacyDownload alloc] init]);
    owner->_download = download;
    owner->_delegate = delegate;
    owner->_information = information;
    owner->_path = path;
    owner->_deleteOnFailure = true;
    return owner;
}
}

@implementation WKCocoaCurlLegacyDownload
+ (void)load
{
    WebCore::setCocoaRemoteDownloadFactory(WebKit::createLegacyResume);
}
- (void)start
{
    if (_started || _finished)
        return;
    _started = true;
    if ([_delegate respondsToSelector:@selector(downloadDidBegin:)])
        [_delegate downloadDidBegin:_download.get()];
    if (_finished)
        return;
    RetainPtr identifier = dynamic_objc_cast<NSNumber>([_information objectForKey:@"WebKitStorageSessionIdentifier"]);
    RetainPtr data = dynamic_objc_cast<NSData>([_information objectForKey:@"WebKitNetworkProcessResumeData"]);
    RetainPtr url = dynamic_objc_cast<NSString>([_information objectForKey:@"NSURLDownloadURL"]);
    if (!identifier || !PAL::SessionID::isValidSessionIDValue([identifier unsignedLongLongValue]) || !data || !url || ![_path length]) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:@{ NSLocalizedDescriptionKey: @"Invalid download resume information" }] cancelled:NO];
        return;
    }
    auto sessionID = PAL::SessionID([identifier unsignedLongLongValue]);
    if (sessionID == PAL::SessionID::defaultSessionID())
        _store = WebKit::WebsiteDataStore::defaultDataStore();
    else
        _store = WebKit::WebsiteDataStore::existingDataStoreForSessionID(sessionID);
    if (!_store) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:@{ NSLocalizedDescriptionKey: @"The download's private storage session has closed" }] cancelled:NO];
        return;
    }
    WebCore::ResourceRequest request(WTF::URL { String(url.get()) });
    _request = request.nsURLRequest(WebCore::HTTPBodyUpdatePolicy::UpdateHTTPBody);
    _proxy = _store->createDownloadProxy(WebKit::CocoaCurlLegacyDownloadClient::create(self), request, nullptr, std::nullopt);
    auto resume = API::Data::create(span(data.get()));
    _store->resumeDownload(*_proxy, resume.get(), String(_path.get()), WebKit::CallDownloadDidStart::Yes);
}
- (void)cancel
{
    if (_finished)
        return;
    if (_proxy) {
        if (auto resume = _proxy->cancelForLegacyResume())
            _information = dynamic_objc_cast<NSDictionary>([NSPropertyListSerialization propertyListWithData:toNSData(resume->span()).get() options:NSPropertyListImmutable format:nil error:nil]);
        else
            _information = nullptr;
    }
    [self finish:nil cancelled:YES];
}
- (void)finish:(NSError*)error cancelled:(BOOL)cancelled
{
    auto protectedSelf = retainPtr(self);
    if (std::exchange(_finished, true))
        return;
    if (_challenge)
        [_challenge.get().sender cancelAuthenticationChallenge:_challenge.get()];
    _challenge = nullptr;
    if ((error || cancelled) && _deleteOnFailure && _ownsDestination && _path)
        FileSystem::deleteFile(String(_path.get()));
    if (!cancelled) {
        if (error && [_delegate respondsToSelector:@selector(download:didFailWithError:)])
            [_delegate download:_download.get() didFailWithError:error];
        else if (!error && [_delegate respondsToSelector:@selector(downloadDidFinish:)])
            [_delegate downloadDidFinish:_download.get()];
    }
    _proxy = nullptr;
    _store = nullptr;
    _delegate = nullptr;
    _download = nullptr;
}
- (void)setDestination:(NSString*)path allowOverwrite:(BOOL)allowOverwrite
{
    // A native resumed download already owns its destination. Before starting it can still be changed through the public API.
    if (!_started)
        _path = path;
    UNUSED_PARAM(allowOverwrite);
}
// resume initializes no default directory; explicit directory changes retain their native getter/setter state.
- (NSString*)directoryPath { return _directory.get(); }
- (void)setDirectoryPath:(NSString*)path { _directory = path; }
- (NSURLRequest*)request { return _request.get(); }
- (NSDictionary*)resumeInformation { return _information.get(); }
- (NSData*)resumeData { return _information ? [NSPropertyListSerialization dataWithPropertyList:_information.get() format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] : nil; }
- (BOOL)deletesFileUponFailure { return _deleteOnFailure; }
- (void)setDeletesFileUponFailure:(BOOL)value { _deleteOnFailure = value; }
@end
