/* Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaDownloadResumeData.h"
#include <WebCore/CocoaDownloadTransport.h>
#include <wtf/cocoa/SpanCocoa.h>
#include <wtf/cocoa/TypeCastsCocoa.h>
#include <wtf/cocoa/VectorCocoa.h>
#include <Foundation/Foundation.h>
// validate native resume property lists before producing the typed cross-process record.
namespace WebKit {
std::optional<CocoaDownloadResumeData> CocoaDownloadResumeData::fromData(std::span<const uint8_t> data)
{
    RetainPtr values = dynamic_objc_cast<NSDictionary>([NSPropertyListSerialization propertyListWithData:toNSData(data).get() options:NSPropertyListImmutable format:nil error:nil]);
    RetainPtr url = dynamic_objc_cast<NSString>([values objectForKey:@"NSURLSessionDownloadURL"]);
    RetainPtr offset = dynamic_objc_cast<NSNumber>([values objectForKey:@"NSURLSessionResumeBytesReceived"]);
    RetainPtr owner = dynamic_objc_cast<NSNumber>([values objectForKey:@"WebKitStorageSessionIdentifier"]);
    RetainPtr path = dynamic_objc_cast<NSString>([values objectForKey:@"NSURLSessionResumeInfoLocalPath"]);
    RetainPtr etag = dynamic_objc_cast<NSString>([values objectForKey:@"NSURLSessionResumeEntityTag"]);
    RetainPtr modified = dynamic_objc_cast<NSString>([values objectForKey:@"NSURLSessionResumeServerDownloadDate"]);
    RetainPtr firstParty = dynamic_objc_cast<NSString>([values objectForKey:@"WebKitFirstPartyForCookies"]);
    RetainPtr topSite = dynamic_objc_cast<NSNumber>([values objectForKey:@"WebKitIsTopSite"]);
    RetainPtr sameSite = dynamic_objc_cast<NSString>([values objectForKey:@"WebKitSameSiteDisposition"]);
    if (!url || !offset || [offset longLongValue] < 0 || !owner || !PAL::SessionID::isValidSessionIDValue([owner unsignedLongLongValue]) || ![path length] || !etag || !modified || !firstParty || !topSite || !sameSite)
        return std::nullopt;
    RetainPtr policy = dynamic_objc_cast<NSString>([values objectForKey:@"WebKitStoredCredentialsPolicy"]);
    WebCore::StoredCredentialsPolicy credentials;
    if ([policy isEqualToString:@"use"])
        credentials = WebCore::StoredCredentialsPolicy::Use;
    else if ([policy isEqualToString:@"do-not-use"])
        credentials = WebCore::StoredCredentialsPolicy::DoNotUse;
    else if ([policy isEqualToString:@"ephemeral-stateless"])
        credentials = WebCore::StoredCredentialsPolicy::EphemeralStateless;
    else
        return std::nullopt;
    WebCore::ResourceRequest request(URL { String(url.get()) });
    if (!request.url().isValid() || !request.url().protocolIsInHTTPFamily() || !WebCore::restoreCocoaDownloadRequestInformation(request, [values objectForKey:@"WebKitRequest"]))
        return std::nullopt;
    request.setFirstPartyForCookies(URL { String(firstParty.get()) });
    request.setIsTopSite([topSite boolValue]);
    if ([sameSite isEqualToString:@"same-site"])
        request.setIsSameSite(true);
    else if ([sameSite isEqualToString:@"cross-site"])
        request.setIsSameSite(false);
    else if (![sameSite isEqualToString:@"unspecified"])
        return std::nullopt;
    return CocoaDownloadResumeData { WTF::move(request), PAL::SessionID([owner unsignedLongLongValue]), credentials, [offset unsignedLongLongValue], String(path.get()), String(etag.get()), String(modified.get()) };
}
Vector<uint8_t> CocoaDownloadResumeData::serializedData() const
{
    NSDictionary* values = @{
        @"NSURLSessionResumeInfoVersion": @1,
        @"WebKitRequest": WebCore::cocoaDownloadRequestInformation(request, false).get(),
        @"WebKitStorageSessionIdentifier": @(sessionID.toUInt64()),
        @"WebKitStoredCredentialsPolicy": storedCredentialsPolicy == WebCore::StoredCredentialsPolicy::Use ? @"use" : storedCredentialsPolicy == WebCore::StoredCredentialsPolicy::DoNotUse ? @"do-not-use" : @"ephemeral-stateless",
        @"WebKitFirstPartyForCookies": request.firstPartyForCookies().string().createNSString().get(),
        @"WebKitIsTopSite": @(request.isTopSite()),
        @"WebKitSameSiteDisposition": request.sameSiteDisposition() == WebCore::ResourceRequest::SameSiteDisposition::SameSite ? @"same-site" : request.sameSiteDisposition() == WebCore::ResourceRequest::SameSiteDisposition::CrossSite ? @"cross-site" : @"unspecified",
        @"NSURLSessionDownloadURL": request.url().string().createNSString().get(),
        @"NSURLSessionResumeBytesReceived": @(bytesReceived),
        @"NSURLSessionResumeInfoLocalPath": destination.createNSString().get(),
        @"NSURLSessionResumeEntityTag": entityTag.createNSString().get(),
        @"NSURLSessionResumeServerDownloadDate": lastModified.createNSString().get()
    };
    return makeVector([NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
}
}
