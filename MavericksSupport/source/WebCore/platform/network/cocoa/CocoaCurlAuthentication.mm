/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlAuthentication.h"
#include "HTTPParsers.h"
#include <Foundation/Foundation.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

// Cocoa protection spaces describe the authentication method selected by curl.
namespace WebCore {
long cocoaCurlAuthenticationMethod(long available)
{
    return available & CURLAUTH_NEGOTIATE ? CURLAUTH_NEGOTIATE : available & CURLAUTH_NTLM ? CURLAUTH_NTLM : available & CURLAUTH_DIGEST ? CURLAUTH_DIGEST : available & CURLAUTH_BASIC ? CURLAUTH_BASIC : CURLAUTH_NONE;
}

String cocoaCurlAuthenticationRealm(const String& fields, long method)
{
    ASCIILiteral selected = method == CURLAUTH_NEGOTIATE ? "Negotiate"_s : method == CURLAUTH_NTLM ? "NTLM"_s : method == CURLAUTH_DIGEST ? "Digest"_s : "Basic"_s;
    StringView input(fields);
    auto trim = [](StringView value) { return value.trim([](auto c) { return c == ' ' || c == '\t'; }); };
    bool matching = false;
    size_t offset = 0;
    while (offset < input.length()) {
        size_t end = offset;
        bool quoted = false;
        bool escaped = false;
        for (; end < input.length(); ++end) {
            auto c = input[end];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quoted && c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"')
                quoted = !quoted;
            if (c == ',' && !quoted)
                break;
        }
        auto part = trim(input.substring(offset, end - offset));
        offset = end + 1;
        size_t tokenEnd = 0;
        while (tokenEnd < part.length() && part[tokenEnd] != ' ' && part[tokenEnd] != '\t' && part[tokenEnd] != '=')
            ++tokenEnd;
        auto token = part.left(tokenEnd);
        auto rest = trim(part.substring(tokenEnd));
        if (!rest.startsWith('=')) {
            matching = equalIgnoringASCIICase(token, selected);
            part = rest;
        }
        if (!matching)
            continue;
        auto equals = part.find('=');
        if (equals == notFound || !equalLettersIgnoringASCIICase(trim(part.left(equals)), "realm"_s))
            continue;
        auto value = trim(part.substring(equals + 1));
        if (!value.startsWith('"'))
            return isValidHTTPToken(value) ? value.toString() : emptyString();
        StringBuilder realm;
        bool escape = false;
        for (size_t i = 1; i < value.length(); ++i) {
            if (!escape && value[i] == '"')
                return trim(value.substring(i + 1)).isEmpty() ? realm.toString() : emptyString();
            if (!escape && value[i] == '\\') {
                escape = true;
                continue;
            }
            realm.append(value[i]);
            escape = false;
        }
        return emptyString();
    }
    return emptyString();
}

ProtectionSpace cocoaCurlProtectionSpace(const URL& url, const String& proxyHost, int proxyPort, long method, const String& fields)
{
    NSString* nativeMethod = method == CURLAUTH_NEGOTIATE ? NSURLAuthenticationMethodNegotiate : method == CURLAUTH_NTLM ? NSURLAuthenticationMethodNTLM : method == CURLAUTH_DIGEST ? NSURLAuthenticationMethodHTTPDigest : NSURLAuthenticationMethodHTTPBasic;
    auto realm = cocoaCurlAuthenticationRealm(fields, method).createNSString();
    if (!proxyHost.isEmpty()) {
        auto space = adoptNS([[NSURLProtectionSpace alloc] initWithProxyHost:proxyHost.createNSString().get() port:proxyPort type:NSURLProtectionSpaceHTTPProxy realm:realm.get() authenticationMethod:nativeMethod]);
        return ProtectionSpace(space.get());
    }
    auto space = adoptNS([[NSURLProtectionSpace alloc] initWithHost:url.createNSURL().get().host port:url.port().value_or(url.protocolIs("https"_s) ? 443 : 80) protocol:url.protocol().toString().createNSString().get() realm:realm.get() authenticationMethod:nativeMethod]);
    return ProtectionSpace(space.get());
}
} // namespace WebCore

// Cocoa clients answer a real native challenge while curl owns the exchange.
#include "Credential.h"
#include "ResourceResponse.h"
#include "ResourceError.h"

@interface WebCoreCocoaCurlChallengeSender : NSObject <NSURLAuthenticationChallengeSender> {
    WebCore::CocoaCurlAuthenticationCompletion _completion;
}
- (instancetype)initWithCompletion:(WebCore::CocoaCurlAuthenticationCompletion&&)completion;
@end
@implementation WebCoreCocoaCurlChallengeSender
- (instancetype)initWithCompletion:(WebCore::CocoaCurlAuthenticationCompletion&&)completion
{
    if (!(self = [super init]))
        return nil;
    _completion = WTF::move(completion);
    return self;
}
- (void)dealloc
{
    if (_completion)
        std::exchange(_completion, nullptr)(WebCore::CocoaCurlAuthenticationDisposition::Cancel, nullptr);
    [super dealloc];
}
- (void)answer:(NSURLAuthenticationChallenge *)challenge disposition:(WebCore::CocoaCurlAuthenticationDisposition)disposition credential:(NSURLCredential *)credential
{
    if ([challenge sender] == self && _completion)
        std::exchange(_completion, nullptr)(disposition, retainPtr(credential));
}
- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:challenge disposition:WebCore::CocoaCurlAuthenticationDisposition::UseCredential credential:credential];
}
- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:challenge disposition:WebCore::CocoaCurlAuthenticationDisposition::ContinueWithoutCredential credential:nil];
}
- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:challenge disposition:WebCore::CocoaCurlAuthenticationDisposition::Cancel credential:nil];
}
- (void)performDefaultHandlingForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:challenge disposition:WebCore::CocoaCurlAuthenticationDisposition::PerformDefaultHandling credential:nil];
}
- (void)rejectProtectionSpaceAndContinueWithChallenge:(NSURLAuthenticationChallenge *)challenge
{
    [self answer:challenge disposition:WebCore::CocoaCurlAuthenticationDisposition::RejectProtectionSpace credential:nil];
}
@end
namespace WebCore {
RetainPtr<NSURLAuthenticationChallenge> cocoaCurlAuthenticationChallenge(const ProtectionSpace& space, const Credential& proposed, unsigned failures, const ResourceResponse& response, const ResourceError& error, CocoaCurlAuthenticationCompletion&& completion)
{
    auto sender = adoptNS([[WebCoreCocoaCurlChallengeSender alloc] initWithCompletion:WTF::move(completion)]);
    return adoptNS([[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space.nsSpace() proposedCredential:proposed.nsCredential() previousFailureCount:failures failureResponse:response.nsURLResponse() error:error.nsError() sender:sender.get()]);
}
}
