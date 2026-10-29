#include "config.h"
#include <WebCore/CocoaCookie.h>
#include <WebCore/CookieJar.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityPolicy.h>
#include <pal/SessionID.h>
#include <pal/spi/cf/CFNetworkSPI.h>
#include <wtf/MainThread.h>
#include <wtf/ProcessPrivilege.h>
#include <Foundation/Foundation.h>
#include <cstdio>
#include <dlfcn.h>

using namespace WebCore;
static unsigned failures;
static unsigned checks;
static void check(bool result, const char* name)
{
    ++checks;
    printf("%s %s\n", result ? "PASS" : "FAIL", name);
    failures += !result;
}

int main()
{
    @autoreleasepool {
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies });
        NetworkStorageSession::permitProcessToUseCookieAPI(true);
        NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        auto createStorage = reinterpret_cast<CFHTTPCookieStorageRef (*)(CFAllocatorRef, CFURLRef, CFHTTPCookieStorageRef)>(dlsym(RTLD_DEFAULT, "CFHTTPCookieStorageCreateFromFile"));
        NetworkStorageSession session(PAL::SessionID::generateEphemeralSessionID(), nullptr, adoptCF(createStorage(kCFAllocatorDefault, (__bridge CFURLRef)file, nullptr)));
        auto storage = session.nsCookieStorage();
        [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
        URL extension { "safari-extension://cookie-fixture/token/page.html"_s };
        URL target { "https://allowed.test/"_s };
        URL second { "https://second.test/"_s };
        URL denied { "https://denied.test/"_s };
        Ref origin = SecurityOrigin::create(extension);
        Ref targetOrigin = SecurityOrigin::create(target);
        Ref secondOrigin = SecurityOrigin::create(second);
        Ref deniedOrigin = SecurityOrigin::create(denied);
        for (auto host : { "allowed.test"_s, "second.test"_s })
            SecurityPolicy::addOriginAccessAllowlistEntry(origin, "https"_s, host, false);
        for (auto field : { "none=1; Path=/; Secure; SameSite=None; Max-Age=3600"_s, "lax=1; Path=/; Secure; SameSite=Lax; Max-Age=3600"_s, "strict=1; Path=/; Secure; SameSite=Strict; HttpOnly; Max-Age=3600"_s })
            session.setCookie(*parseHTTPSetCookie(field, target), target, target);
        ResourceRequest request { URL { target } };
        request.setFirstPartyForCookies(extension);
        request.setIsSameSite(false);
        auto header = [&](const ResourceRequest& value, const SecurityOrigin* sourceOrigin) {
            return session.cookieRequestHeaderFieldValue(value.firstPartyForCookies(), cookieRequestSameSiteInfo(value, sourceOrigin), value.url(), std::nullopt, std::nullopt, IncludeSecureCookies::Yes, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
        };
        for (unsigned policy : { 0, 1, 2, 3 }) {
            [storage setCookieAcceptPolicy:static_cast<NSHTTPCookieAcceptPolicy>(policy)];
            printf("native-policy=%u\n", policy);
            check(static_cast<unsigned>([storage cookieAcceptPolicy]) == policy, "isolated jar uses the selected native policy");
            check(header(request, origin.ptr()).contains("strict=1"_s) && header(request, origin.ptr()).contains("lax=1"_s), "permitted extension sends Lax and HttpOnly Strict through native acceptance");
            auto web = request;
            web.setFirstPartyForCookies(denied);
            auto value = header(web, deniedOrigin.ptr());
            check(!value.contains("strict=1"_s) && !value.contains("lax=1"_s) && (policy == 3 ? value.isEmpty() : value.contains("none=1"_s)), "ordinary cross-site read retains native and SameSite policy");
        }
        [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
        session.setTrackingPreventionEnabled(true);
        session.setThirdPartyCookieBlockingMode(ThirdPartyCookieBlockingMode::All);
        check(header(request, origin.ptr()).contains("strict=1"_s), "permission relaxes explicit all-third-party blocking");
        check(!cookieRequestSameSiteInfo(request, nullptr).isSameSite, "an absent source origin supplies no SameSite exception");
        auto embeddedExtension = request;
        embeddedExtension.setFirstPartyForCookies(denied);
        check(header(embeddedExtension, origin.ptr()).isEmpty(), "extension iframe in web top retains third-party blocking");
        session.setTrackingPreventionEnabled(false);
        check(header(embeddedExtension, origin.ptr()).contains("strict=1"_s), "extension initiator's SameSite exception is independent of top-level third-party permission");
        auto embeddedWeb = request;
        check(header(embeddedWeb, targetOrigin.ptr()).contains("strict=1"_s), "permitted embedded web initiator sends its same-site Strict cookie");
        check(!header(embeddedWeb, secondOrigin.ptr()).contains("strict=1"_s), "embedded web initiator cannot borrow another permitted site's SameSite exception");
        auto redirect = [](ResourceRequest& value, const URL& target) {
            value.appendCookieRequestRedirectURL(value.url());
            value.setURL(URL { target });
        };
        auto redirects = request;
        redirect(redirects, second);
        redirect(redirects, target);
        check(header(redirects, origin.ptr()).contains("strict=1"_s), "one permission path covers cross-site allowed redirects");
        auto embeddedRedirects = redirects;
        check(!header(embeddedRedirects, targetOrigin.ptr()).contains("strict=1"_s), "identical redirect chain and top level retain distinct extension and embedded-web initiator policy");
        redirect(redirects, denied);
        redirect(redirects, target);
        check(!header(redirects, origin.ptr()).contains("strict=1"_s), "return to permitted host retains denied-hop SameSite taint");
        check(!header(redirects.isolatedCopy(), origin.ptr()).contains("strict=1"_s), "worker request copy retains denied-hop taint");
        redirects.nsURLRequest(HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);
        auto copied = ResourceRequest::fromResourceRequestData(redirects.getRequestDataToSerialize(), false, false);
        check(!header(copied, origin.ptr()).contains("strict=1"_s) && copied.cookieRequestRedirectChain() == redirects.cookieRequestRedirectChain(), "platform request round trip retains redirect taint");
        auto socket = request;
        socket.setURL(URL { "wss://allowed.test/"_s });
        check(cookieRequestSameSiteInfo(socket, origin.ptr()).isSameSite, "WSS checks HTTPS Website Access");
        socket.setURL(URL { "https://allowed.test/"_s });
        check(socket.cookieRequestRedirectChain().isEmpty(), "WebSocket cookie URL normalization preserves the redirect chain");
        socket.setURL(URL { "ws://allowed.test/"_s });
        check(!cookieRequestSameSiteInfo(socket, origin.ptr()).isSameSite, "WS needs HTTP Website Access");
        session.setOptInCookiePartitioningEnabled(true);
        auto partition = cookiePartitionForTopLevelURL(extension);
        session.setCookie(*parseHTTPSetCookie("chips=extension; Path=/; Secure; SameSite=None; Partitioned; Max-Age=3600"_s, target, partition), target, target);
        session.setCookie(*parseHTTPSetCookie("chips=target; Path=/; Secure; SameSite=None; Partitioned; Max-Age=3600"_s, target, cookiePartitionForTopLevelURL(target)), target, target);
        auto value = header(request, origin.ptr());
        check(value.contains("chips=extension"_s) && !value.contains("chips=target"_s), "native first-party relaxation retains real extension CHIPS partition");
        [storage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyNever];
        session.setCookie(*parseHTTPSetCookie("never=1; Path=/; Secure; SameSite=None"_s, target), target, target);
        check(!header(request, origin.ptr()).contains("never=1"_s), "native Never still rejects new extension cookies");
        for (auto host : { "allowed.test"_s, "second.test"_s })
            SecurityPolicy::removeOriginAccessAllowlistEntry(origin, "https"_s, host, false);
        check(!header(request, origin.ptr()).contains("strict=1"_s), "revocation removes the exception from an existing request");
        session.deleteAllCookies([] { });
        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
        printf("Extension cookies: %u checks, FAILED=%u\n", checks, failures);
    }
    return failures ? 1 : 0;
}
