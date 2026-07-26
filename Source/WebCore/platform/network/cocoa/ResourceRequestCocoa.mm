/*
 * Copyright (C) 2014-2022 Apple, Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "ResourceRequest.h"

#if PLATFORM(COCOA)

#import "FormDataStreamMac.h"
#import "HTTPHeaderNames.h"
#import "RegistrableDomain.h"
#import "ResourceRequestCFNet.h"
#import <Foundation/Foundation.h>
#import <Foundation/NSURLRequest.h>
#import <pal/spi/cf/CFNetworkSPI.h>
#import <wtf/FileSystem.h>
#import <wtf/RuntimeApplicationChecks.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/CString.h>

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/ResourceRequestCocoaAdditions.mm>)
#import <WebKitAdditions/ResourceRequestCocoaAdditions.mm>
#endif

namespace WebCore {

ResourceRequest::ResourceRequest(NSURLRequest *nsRequest)
    : m_nsRequest(nsRequest)
{
#if ENABLE(APP_PRIVACY_REPORT)
    setIsAppInitiated(nsRequest.attribution == NSURLRequestAttributionDeveloper);
#endif
    // MAVERICKS_BACKPORT: _privacyProxyFailClosedForUnreachableNonMainHosts is 10.10+ private API.
    if ([nsRequest respondsToSelector:@selector(_privacyProxyFailClosedForUnreachableNonMainHosts)])
        setPrivacyProxyFailClosedForUnreachableNonMainHosts(nsRequest._privacyProxyFailClosedForUnreachableNonMainHosts);
#if HAVE(SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS)
    setUseAdvancedPrivacyProtections(nsRequest._useEnhancedPrivacyMode);
#endif
}

ResourceRequest::ResourceRequest(ResourceRequestPlatformData&& platformData, const String& cachePartition, bool hiddenFromInspector)
{
    if (platformData.m_urlRequest) {
        if (platformData.m_requester)
            setRequester(*platformData.m_requester);
        m_nsRequest = platformData.m_urlRequest;
#if !HAVE(WK_SECURE_CODING_NSURLREQUEST)
        // MAVERICKS_BACKPORT: restore the byte-exact URL that the 10.9 NSKeyedArchiver escaped in
        // transit (see ResourceRequest.h). setURL() marks the platform request dirty, so the
        // NSURLRequest regenerates from the exact URL on next use, keeping its other fields.
        if (!platformData.m_exactURL.isNull() && platformData.m_exactURL != URL { [m_nsRequest URL] })
            setURL(URL { platformData.m_exactURL });
        // MAVERICKS_BACKPORT: re-apply the HTTPShouldHandleCookies rider dropped by 10.9's archiver
        // (see getResourceRequestPlatformData() and ResourceRequest.h). Without this every POST — which
        // serializes via this platform path — decodes with allowCookies=false and loses its cookies.
        setAllowCookies(platformData.m_shouldHandleCookies);
#endif
        if (platformData.m_isAppInitiated)
            setIsAppInitiated(*platformData.m_isAppInitiated);
        setPrivacyProxyFailClosedForUnreachableNonMainHosts(platformData.m_privacyProxyFailClosedForUnreachableNonMainHosts);
        setUseAdvancedPrivacyProtections(platformData.m_useAdvancedPrivacyProtections);
        setDidFilterLinkDecoration(platformData.m_didFilterLinkDecoration);
        setIsPrivateTokenUsageByThirdPartyAllowed(platformData.m_isPrivateTokenUsageByThirdPartyAllowed);
        setWasSchemeOptimisticallyUpgraded(platformData.m_wasSchemeOptimisticallyUpgraded);
    }

    setCachePartition(cachePartition);
    setHiddenFromInspector(hiddenFromInspector);
}

ResourceRequestData ResourceRequest::getRequestDataToSerialize() const
{
    if (encodingRequiresPlatformData())
        return getResourceRequestPlatformData();
    return m_requestData;
}

ResourceRequest ResourceRequest::fromResourceRequestData(ResourceRequestData&& requestData, String&& cachePartition, bool hiddenFromInspector)
{
    if (std::holds_alternative<RequestData>(requestData))
        return ResourceRequest(WTF::move(std::get<RequestData>(requestData)), WTF::move(cachePartition), hiddenFromInspector);
    return ResourceRequest(WTF::move(std::get<ResourceRequestPlatformData>(requestData)), WTF::move(cachePartition), hiddenFromInspector);
}

NSURLRequest *ResourceRequest::nsURLRequest(HTTPBodyUpdatePolicy bodyPolicy) const
{
    updatePlatformRequest(bodyPolicy);
    return m_nsRequest.get();
}

ResourceRequestPlatformData ResourceRequest::getResourceRequestPlatformData() const
{
    RELEASE_ASSERT(m_httpBody || m_nsRequest);
    
    RetainPtr requestToSerialize = nsURLRequest(WebCore::HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);

    if (Class requestClass = [requestToSerialize class]; requestClass != [NSURLRequest class] && requestClass != [NSMutableURLRequest class]) [[unlikely]] {
        WebCore::ResourceRequest request(requestToSerialize.get());
        request.replacePlatformRequest(WebCore::HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);
        requestToSerialize = request.nsURLRequest(WebCore::HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);
    }
    ASSERT([requestToSerialize class] == [NSURLRequest class] || [requestToSerialize class] == [NSMutableURLRequest class]);

    // MAVERICKS_BACKPORT: 10.9's ResourceRequestPlatformData carries extra byte-exact URL and
    // HTTPShouldHandleCookies rider fields (see ResourceRequest.h), so the null-request early return
    // fills them under !HAVE(WK_SECURE_CODING_NSURLREQUEST).
    if (!requestToSerialize) {
#if !HAVE(WK_SECURE_CODING_NSURLREQUEST)
        return ResourceRequestPlatformData { NULL, { }, true, std::nullopt, std::nullopt };
#else
        return ResourceRequestPlatformData { NULL, std::nullopt, std::nullopt };
    // MAVERICKS_BACKPORT: closes the !HAVE(WK_SECURE_CODING_NSURLREQUEST) split and the null-request early-return block above.
#endif
    }

    // We don't send HTTP body over IPC for better performance.
    // Also, it's not always possible to do, as streams can only be created in process that does networking.
    if ([requestToSerialize HTTPBody] || [requestToSerialize HTTPBodyStream]) {
        auto mutableRequest = adoptNS([requestToSerialize mutableCopy]);
        [mutableRequest setHTTPBody:nil];
        [mutableRequest setHTTPBodyStream:nil];
        requestToSerialize = WTF::move(mutableRequest);
    }
    return {
        WTF::move(requestToSerialize),
#if !HAVE(WK_SECURE_CODING_NSURLREQUEST)
        // MAVERICKS_BACKPORT: byte-exact URL rider for the escaping 10.9 archiver (see ResourceRequest.h).
        url(),
        // MAVERICKS_BACKPORT: HTTPShouldHandleCookies rider — 10.9's NSURLRequest NSSecureCoding does
        // not round-trip that flag (it decodes as NO), so carry it alongside the archived request and
        // re-apply it on decode (see the decode ctor + ResourceRequest.h). This platform path is taken
        // for every body-bearing request (all POSTs), so without the rider every POST reached the
        // NetworkProcess with allowCookies=false and had its cookies stripped by the injection gate.
        allowCookies(),
#endif
        isAppInitiated(),
        requester(),
        privacyProxyFailClosedForUnreachableNonMainHosts(),
        useAdvancedPrivacyProtections(),
        didFilterLinkDecoration(),
        isPrivateTokenUsageByThirdPartyAllowed(),
        wasSchemeOptimisticallyUpgraded()
    };
}

CFURLRequestRef ResourceRequest::cfURLRequest(HTTPBodyUpdatePolicy bodyPolicy) const
{
    return [protect(nsURLRequest(bodyPolicy)) _CFURLRequest];
}

static inline ResourceRequestCachePolicy NODELETE fromPlatformRequestCachePolicy(NSURLRequestCachePolicy policy)
{
    switch (policy) {
    case NSURLRequestUseProtocolCachePolicy:
        return ResourceRequestCachePolicy::UseProtocolCachePolicy;
    case NSURLRequestReturnCacheDataElseLoad:
        return ResourceRequestCachePolicy::ReturnCacheDataElseLoad;
    case NSURLRequestReturnCacheDataDontLoad:
        return ResourceRequestCachePolicy::ReturnCacheDataDontLoad;
    default:
        return ResourceRequestCachePolicy::ReloadIgnoringCacheData;
    }
}

static inline NSURLRequestCachePolicy NODELETE toPlatformRequestCachePolicy(ResourceRequestCachePolicy policy)
{
    switch (policy) {
    case ResourceRequestCachePolicy::UseProtocolCachePolicy:
        return NSURLRequestUseProtocolCachePolicy;
    case ResourceRequestCachePolicy::ReturnCacheDataElseLoad:
        return NSURLRequestReturnCacheDataElseLoad;
    case ResourceRequestCachePolicy::ReturnCacheDataDontLoad:
        return NSURLRequestReturnCacheDataDontLoad;
    default:
        return NSURLRequestReloadIgnoringLocalCacheData;
    }
}

void ResourceRequest::doUpdateResourceRequest()
{
    m_requestData.m_url = [m_nsRequest URL];

    if (m_requestData.m_cachePolicy == ResourceRequestCachePolicy::UseProtocolCachePolicy)
        m_requestData.m_cachePolicy = fromPlatformRequestCachePolicy([m_nsRequest cachePolicy]);
    m_requestData.m_timeoutInterval = [m_nsRequest timeoutInterval];
    m_requestData.m_firstPartyForCookies = [m_nsRequest mainDocumentURL];

    URL siteForCookies { [m_nsRequest _propertyForKey:@"_kCFHTTPCookiePolicyPropertySiteForCookies"] };
    m_requestData.m_sameSiteDisposition = siteForCookies.isNull() ? SameSiteDisposition::Unspecified : (areRegistrableDomainsEqual(siteForCookies, m_requestData.m_url) ? SameSiteDisposition::SameSite : SameSiteDisposition::CrossSite);

    m_requestData.m_isTopSite = static_cast<NSNumber*>([m_nsRequest _propertyForKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation"]).boolValue;

    if (RetainPtr method = [m_nsRequest HTTPMethod])
        m_requestData.m_httpMethod = method.get();
    m_requestData.m_allowCookies = [m_nsRequest HTTPShouldHandleCookies];

    if (resourcePrioritiesEnabled())
        m_requestData.m_priority = toResourceLoadPriority(m_nsRequest ? CFURLRequestGetRequestPriority([m_nsRequest _CFURLRequest]) : 0);

    m_requestData.m_httpHeaderFields.clear();
    [retainPtr([m_nsRequest allHTTPHeaderFields]) enumerateKeysAndObjectsUsingBlock: ^(NSString *name, NSString *value, BOOL *) {
        m_requestData.m_httpHeaderFields.set(name, value);
    }];

    m_requestData.m_responseContentDispositionEncodingFallbackArray.clear();
    RetainPtr<NSArray> encodingFallbacks = [m_nsRequest contentDispositionEncodingFallbackArray];
    m_requestData.m_responseContentDispositionEncodingFallbackArray.reserveCapacity([encodingFallbacks count]);
    for (NSNumber *encodingFallback in [m_nsRequest contentDispositionEncodingFallbackArray]) {
        CFStringEncoding encoding = CFStringConvertNSStringEncodingToEncoding([encodingFallback unsignedLongValue]);
        if (encoding != kCFStringEncodingInvalidId)
            m_requestData.m_responseContentDispositionEncodingFallbackArray.append(CFStringConvertEncodingToIANACharSetName(encoding));
    }

    if (m_nsRequest) {
        RetainPtr<NSString> cachePartition = [NSURLProtocol propertyForKey:bridge_cast(_kCFURLCachePartitionKey) inRequest:m_nsRequest.get()];
        if (cachePartition)
            m_cachePartition = cachePartition.get();
    }
}

void ResourceRequest::doUpdateResourceHTTPBody()
{
    if (RetainPtr bodyData = [m_nsRequest HTTPBody])
        m_httpBody = FormData::create(span(bodyData.get()));
    else if (RetainPtr bodyStream = [m_nsRequest HTTPBodyStream]) {
        RefPtr formData = httpBodyFromStream(bodyStream.get());
        // There is no FormData object if a client provided a custom data stream.
        // We shouldn't be looking at http body after client callbacks.
        ASSERT(formData);
        if (formData)
            m_httpBody = WTF::move(formData);
    }
}

static NSURL *siteForCookies(ResourceRequest::SameSiteDisposition disposition, NSURL *url)
{
    switch (disposition) {
    case ResourceRequest::SameSiteDisposition::Unspecified:
        return { };
    case ResourceRequest::SameSiteDisposition::SameSite:
        return url;
    case ResourceRequest::SameSiteDisposition::CrossSite:
        return URL::emptyNSURL();
    }
}

void ResourceRequest::replacePlatformRequest(HTTPBodyUpdatePolicy policy)
{
    updateResourceRequest();
    m_nsRequest = nil;
    m_platformRequestUpdated = false;
    updatePlatformRequest(policy);
}

static void configureRequestWithData(NSMutableURLRequest *request, const ResourceRequestBase::RequestData& data)
{
#if ENABLE(APP_PRIVACY_REPORT)
    request.attribution = data.m_isAppInitiated ? NSURLRequestAttributionDeveloper : NSURLRequestAttributionUser;
#else
    UNUSED_PARAM(request);
    UNUSED_PARAM(data);
#endif

    // MAVERICKS_BACKPORT: _privacyProxyFailClosedForUnreachableNonMainHosts is 10.16+
    if ([request respondsToSelector:@selector(_setPrivacyProxyFailClosedForUnreachableNonMainHosts:)])
        request._privacyProxyFailClosedForUnreachableNonMainHosts = data.m_privacyProxyFailClosedForUnreachableNonMainHosts;

#if HAVE(SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS)
    request._useEnhancedPrivacyMode = data.m_useAdvancedPrivacyProtections;
#endif
}

void ResourceRequest::doUpdatePlatformRequest()
{
    if (isNull()) {
        m_nsRequest = nil;
        return;
    }

    auto nsRequest = adoptNS<NSMutableURLRequest *>([m_nsRequest mutableCopy]);

    if (nsRequest)
        [nsRequest setURL:url().createNSURL().get()];
    else
        nsRequest = adoptNS([[NSMutableURLRequest alloc] initWithURL:url().createNSURL().get()]);

    configureRequestWithData(nsRequest.get(), m_requestData);

/* MAVERICKS_BACKPORT: upstream's version of the lines below, kept commented rather than deleted so the divergence stays visible in place. Reason: see the note just below the block.
    if (ResourceRequest::httpPipeliningEnabled())
        CFURLRequestSetShouldPipelineHTTP([nsRequest _CFURLRequest], true, true);

    if (ResourceRequest::resourcePrioritiesEnabled()) {
        CFURLRequestSetRequestPriority([nsRequest _CFURLRequest], toPlatformRequestPriority(priority()));

        // Used by PLT to ignore very low priority beacon and ping loads.
        if (priority() == ResourceLoadPriority::VeryLow)
            _CFURLRequestSetProtocolProperty([nsRequest _CFURLRequest], CFSTR("WKVeryLowLoadPriority"), kCFBooleanTrue);
    }

MAVERICKS_BACKPORT */
    [nsRequest setCachePolicy:toPlatformRequestCachePolicy(cachePolicy())];
// MAVERICKS_BACKPORT: upstream's version of the lines below, kept commented rather than deleted so the divergence stays visible in place. Reason: see the note directly above.
//     _CFURLRequestSetProtocolProperty([nsRequest _CFURLRequest], kCFURLRequestAllowAllPOSTCaching, kCFBooleanTrue);
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: 10.9's NSURLSession gives a request-level timeoutInterval precedence over
    // NSURLSessionConfiguration.timeoutIntervalForRequest, while modern CFNetwork enforces the
    // config-level 60s idle backstop regardless. Upstream deliberately ships effectively-infinite
    // request timeouts relying on that backstop (Safari seeds the process-wide default with INT_MAX
    // via WKURLRequestSetDefaultTimeoutInterval, and XMLHttpRequest uses infinity when no XHR timeout
    // is set), so on 10.9 every load would run with no timeout at all and a response that never
    // arrives (e.g. a proxied keepalive-reuse race dropping a request) hangs its load forever.
    // Restore the modern contract by mapping the infinite sentinels to the platform default idle
    // timeout (60s, NSURLRequest's documented default, which WebKit's session config leaves untouched).
    // Finite page-specified timeouts (e.g. XHR's timeout attribute) pass through unchanged.
    auto clampInfiniteTimeoutInterval = [](double interval) {
        return interval >= INT_MAX ? 60.0 : interval;
    };
    if (double newTimeoutInterval = timeoutInterval())
        // MAVERICKS_BACKPORT: clamp the infinite timeout sentinel to the 60s idle backstop (see above).
        [nsRequest setTimeoutInterval:clampInfiniteTimeoutInterval(newTimeoutInterval)];
    else
        // MAVERICKS_BACKPORT: clamp the infinite default-timeout sentinel to the 60s idle backstop (see above).
        [nsRequest setTimeoutInterval:clampInfiniteTimeoutInterval(defaultTimeoutInterval())];

    [nsRequest setMainDocumentURL:firstPartyForCookies().createNSURL().get()];
    if (!httpMethod().isEmpty())
        [nsRequest setHTTPMethod:httpMethod().createNSString().get()];
    [nsRequest setHTTPShouldHandleCookies:allowCookies()];

// MAVERICKS_BACKPORT: upstream's SameSite cookie-policy request properties. Kept commented, not deleted: _kCFHTTPCookiePolicyPropertySiteForCookies and _kCFHTTPCookiePolicyPropertyIsTopLevelNavigation do not exist in 10.9's CFNetwork, which has no SameSite notion at all.
//     [nsRequest _setProperty:RetainPtr { siteForCookies(m_requestData.m_sameSiteDisposition, retainPtr([nsRequest URL]).get()) }.get() forKey:@"_kCFHTTPCookiePolicyPropertySiteForCookies"];
//     // FIXME: This is a safer cpp false positive (rdar://160851489).
//     SUPPRESS_UNRETAINED_ARG [nsRequest _setProperty:m_requestData.m_isTopSite ? @YES : @NO forKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation"];
//
// (end MAVERICKS_BACKPORT restored block)
    // Cannot just use setAllHTTPHeaderFields here, because it does not remove headers.
    for (NSString *oldHeaderName in [nsRequest allHTTPHeaderFields])
        [nsRequest setValue:nil forHTTPHeaderField:oldHeaderName];
    for (const auto& header : httpHeaderFields()) {
        RetainPtr encodedValue = httpHeaderValueUsingSuitableEncoding(header);
        [nsRequest setValue:bridge_cast(encodedValue.get()) forHTTPHeaderField:header.key.createNSString().get()];
    }

    [nsRequest setContentDispositionEncodingFallbackArray:createNSArray(m_requestData.m_responseContentDispositionEncodingFallbackArray, [] (auto& name) -> NSNumber * {
        auto encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name.createCFString().get()));
        if (encoding == kCFStringEncodingInvalidId)
            return nil;
        return @(encoding);
    }).get()];

    String partition = cachePartition();
    if (!partition.isNull() && !partition.isEmpty()) {
        RetainPtr partitionValue = adoptNS([[NSString alloc] initWithUTF8String:partition.utf8().data()]);
        [NSURLProtocol setProperty:partitionValue.get() forKey:bridge_cast(_kCFURLCachePartitionKey) inRequest:nsRequest.get()];
    }

#if PLATFORM(MAC)
    if (m_requestData.m_url.protocolIsFile()) {
        auto filePath = m_requestData.m_url.fileSystemPath();
        if (!filePath.isNull()) {
            auto fileDevice = FileSystem::getFileDeviceId(filePath);
            if (fileDevice && fileDevice.value())
                [nsRequest _setProperty:[NSNumber numberWithInteger:fileDevice.value()] forKey:@"NSURLRequestFileProtocolExpectedDevice"];
        }
    }
#endif

    m_nsRequest = WTF::move(nsRequest);
}

void ResourceRequest::doUpdatePlatformHTTPBody()
{
    if (isNull()) {
        m_nsRequest = nil;
        return;
    }

    auto nsRequest = adoptNS<NSMutableURLRequest *>([m_nsRequest mutableCopy]);

    if (nsRequest)
        [nsRequest setURL:url().createNSURL().get()];
    else
        nsRequest = adoptNS([[NSMutableURLRequest alloc] initWithURL:url().createNSURL().get()]);

    configureRequestWithData(nsRequest.get(), m_requestData);

    RefPtr formData = httpBody();
    if (formData && !formData->isEmpty())
        WebCore::setHTTPBody(nsRequest.get(), WTF::move(formData));

    if (RetainPtr bodyStream = [nsRequest HTTPBodyStream]) {
        // For streams, provide a Content-Length to avoid using chunked encoding, and to get accurate total length in callbacks.
        RetainPtr<NSString> lengthString = [bodyStream propertyForKey:RetainPtr { bridge_cast(formDataStreamLengthPropertyNameSingleton()) }.get()];
        if (lengthString) {
            [nsRequest setValue:lengthString.get() forHTTPHeaderField:@"Content-Length"];
            // Since resource request is already marked updated, we need to keep it up to date too.
            ASSERT(m_resourceRequestUpdated);
            m_requestData.m_httpHeaderFields.set(HTTPHeaderName::ContentLength, lengthString.get());
        }
    }

    m_nsRequest = WTF::move(nsRequest);
}

void ResourceRequest::setStorageSession(CFURLStorageSessionRef storageSession)
{
    updatePlatformRequest();
    m_nsRequest = copyRequestWithStorageSession(storageSession, m_nsRequest.get());
}

RetainPtr<NSURLRequest> copyRequestWithStorageSession(CFURLStorageSessionRef storageSession, NSURLRequest *request)
{
    if (!storageSession || !request)
        return adoptNS([request copy]);

    auto cfRequest = adoptCF(CFURLRequestCreateMutableCopy(kCFAllocatorDefault, [request _CFURLRequest]));
    _CFURLRequestSetStorageSession(cfRequest.get(), storageSession);
    auto nsRequest = adoptNS([[NSMutableURLRequest alloc] _initWithCFURLRequest:cfRequest.get()]);
#if ENABLE(APP_PRIVACY_REPORT)
    nsRequest.get().attribution = request.attribution;
#endif
    return nsRequest;
}

NSCachedURLResponse *cachedResponseForRequest(CFURLStorageSessionRef storageSession, NSURLRequest *request)
{
    if (!storageSession)
        return [[NSURLCache sharedURLCache] cachedResponseForRequest:request];

    auto cache = adoptCF(_CFURLStorageSessionCopyCache(kCFAllocatorDefault, storageSession));
    auto cachedResponse = adoptCF(CFURLCacheCopyResponseForRequest(cache.get(), [request _CFURLRequest]));
    if (!cachedResponse)
        return nil;

    return adoptNS([[NSCachedURLResponse alloc] _initWithCFCachedURLResponse:cachedResponse.get()]).autorelease();
}

} // namespace WebCore

#endif // PLATFORM(COCOA)

