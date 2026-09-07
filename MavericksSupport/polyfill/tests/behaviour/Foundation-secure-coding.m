// The property-list coders (methods/Foundation.m): -[NSURLProtectionSpace _webKitPropertyListData] /
// -_initWithWebKitPropertyListData: and the NSURLCredential pair, which WebKit's
// CoreIPCNSURLProtectionSpace and CoreIPCNSURLCredential read and write. A protection space comes
// back with every field, and its trust asks the question the sender's trust asked -- the server
// question, for the sender's hostname, with the sender's anchors -- rather than the client question
// with no hostname that CFNetwork's own archive rebuilds.
//
// The private selectors are the layer's own (wk_selref_scope.h): Foundation.o carries the bodies and
// wk_selref_scope.o installs them.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <stdio.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static NSDictionary *propertyList(id object)
{
    return ((NSDictionary *(*)(id, SEL))objc_msgSend)(object, sel_getUid("wk__webKitPropertyListData"));
}

static id fromPropertyList(Class cls, NSDictionary *dictionary)
{
    return ((id (*)(id, SEL, NSDictionary *))objc_msgSend)([cls alloc], sel_getUid("wk__initWithWebKitPropertyListData:"), dictionary);
}

static NSDictionary *policyProperties(SecTrustRef trust)
{
    CFArrayRef policies = NULL;
    if (!trust || SecTrustCopyPolicies(trust, &policies) != errSecSuccess || !policies || CFArrayGetCount(policies) != 1)
        return nil;
    return [(NSDictionary *)SecPolicyCopyProperties((SecPolicyRef)CFArrayGetValueAtIndex(policies, 0)) autorelease];
}

int main(void)
{
    @autoreleasepool {
        CFArrayRef anchors = NULL;
        SecTrustCopyAnchorCertificates(&anchors);
        if (!anchors || CFArrayGetCount(anchors) < 3) {
            printf("Foundation-secure-coding: fewer than three system anchors\n");
            return 1;
        }
        const void *chain[3] = { CFArrayGetValueAtIndex(anchors, 0), CFArrayGetValueAtIndex(anchors, 1), CFArrayGetValueAtIndex(anchors, 2) };
        CFArrayRef certificates = CFArrayCreate(NULL, chain, 3, &kCFTypeArrayCallBacks);
        SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("example.org"));
        SecTrustRef trust = NULL;
        SecTrustCreateWithCertificates(certificates, policy, &trust);
        const void *customAnchor[1] = { chain[2] };
        CFArrayRef customAnchors = CFArrayCreate(NULL, customAnchor, 1, &kCFTypeArrayCallBacks);
        SecTrustSetAnchorCertificates(trust, customAnchors);
        CFDateRef verifyDate = CFDateCreate(NULL, 700000000);
        SecTrustSetVerifyDate(trust, verifyDate);
        NSData *name = [NSData dataWithBytes:"\x30\x03\x02\x01\x07" length:5];

        // A protection space with a trust and a distinguished name, from the dictionary the coder writes.
        NSDictionary *spaceList = @{
            @"host": @"example.org", @"port": @443, @"type": @2 /* HTTPS */, @"realm": @"a realm",
            @"scheme": @8 /* server trust */, @"trust": (id)trust, @"distnames": @[ name ],
        };
        NSURLProtectionSpace *space = fromPropertyList([NSURLProtectionSpace class], spaceList);
        check(space != nil, "a protection space initializes from its property list");
        check([space.host isEqualToString:@"example.org"] && space.port == 443, "host and port arrive");
        check([space.protocol isEqualToString:@"https"], "the server type arrives");
        check([space.realm isEqualToString:@"a realm"], "the realm arrives");
        check([space.authenticationMethod isEqualToString:@"NSURLAuthenticationMethodServerTrust"], "the authentication scheme arrives");
        check(space.distinguishedNames.count == 1 && [space.distinguishedNames[0] isEqual:name], "the distinguished name arrives");
        SecTrustRef attached = space.serverTrust;
        check(attached != NULL, "the space carries a trust");
        NSDictionary *properties = policyProperties(attached);
        check([properties[(id)kSecPolicyName] isEqualToString:@"example.org"], "that trust asks about the sender's hostname");
        check(![properties[(id)kSecPolicyClient] boolValue], "and asks the server question");
        CFArrayRef attachedAnchors = NULL;
        check(SecTrustCopyCustomAnchorCertificates(attached, &attachedAnchors) == errSecSuccess && attachedAnchors
            && CFArrayGetCount(attachedAnchors) == 1 && CFEqual(CFArrayGetValueAtIndex(attachedAnchors, 0), chain[2]),
            "with the sender's custom anchor");
        check(SecTrustGetVerifyTime(attached) == 700000000, "and the sender's verify date");
        check(SecTrustGetCertificateAtIndex(attached, 0) && CFEqual(SecTrustGetCertificateAtIndex(attached, 0), chain[0]),
            "and the sender's leaf");

        // The dictionary the space writes back.
        NSDictionary *written = propertyList(space);
        check([written[@"host"] isEqualToString:@"example.org"] && [written[@"port"] intValue] == 443
            && [written[@"type"] intValue] == 2 && [written[@"realm"] isEqualToString:@"a realm"] && [written[@"scheme"] intValue] == 8,
            "the space writes its five fields back");
        check(written[@"trust"] == (id)attached, "and its trust");
        check([written[@"distnames"] isEqual:@[ name ]], "and its distinguished names");

        // A space without a trust or names, both ways. NSURLAuthenticationMethodHTTPBasic carries the
        // value every macOS from 10.10 on gives it (polyfills/c/Foundation.m), and the initializers and
        // -authenticationMethod in methods/Foundation.m carry that value to and from the CF scheme
        // CFNetwork numbers Basic 2 and Default 1 -- the distinction 10.9's own constant cannot make.
        NSURLProtectionSpace *basic = [[NSURLProtectionSpace alloc] initWithHost:@"example.org" port:80 protocol:@"http" realm:@"r" authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
        NSDictionary *basicList = propertyList(basic);
        check([basicList[@"type"] intValue] == 1 && [basicList[@"scheme"] intValue] == 2 && !basicList[@"trust"] && !basicList[@"distnames"],
            "a basic space writes HTTP, HTTPBasic, and no trust or names");
        check([basic.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic], "and names Basic as its method");
        NSURLProtectionSpace *defaulted = [[NSURLProtectionSpace alloc] initWithHost:@"example.org" port:80 protocol:@"http" realm:@"r" authenticationMethod:NSURLAuthenticationMethodDefault];
        check([propertyList(defaulted)[@"scheme"] intValue] == 1
            && [defaulted.authenticationMethod isEqualToString:NSURLAuthenticationMethodDefault],
            "a default space stays Default, so the two are distinguishable");
        NSURLProtectionSpace *proxyBasic = [[NSURLProtectionSpace alloc] initWithProxyHost:@"example.org" port:80 type:NSURLProtectionSpaceHTTPProxy realm:@"r" authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
        check([propertyList(proxyBasic)[@"type"] intValue] == 5 && [propertyList(proxyBasic)[@"scheme"] intValue] == 2,
            "a basic proxy space keeps its proxy type and Basic");
        NSURLProtectionSpace *digest = [[NSURLProtectionSpace alloc] initWithHost:@"example.org" port:80 protocol:@"http" realm:@"r" authenticationMethod:NSURLAuthenticationMethodHTTPDigest];
        check([propertyList(digest)[@"scheme"] intValue] == 3
            && [digest.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest],
            "a scheme 10.9 names for itself is untouched");
        NSURLProtectionSpace *basicBack = fromPropertyList([NSURLProtectionSpace class], basicList);
        check([basicBack isEqual:basic] && [propertyList(basicBack)[@"scheme"] intValue] == 2
            && [basicBack.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic],
            "and reads back equal, still Basic");
        check(fromPropertyList([NSURLProtectionSpace class], @{ @"host": @"h" }) == nil, "a property list without its numbers answers nil");

        // Credentials: a password credential, both ways.
        NSURLCredential *password = [NSURLCredential credentialWithUser:@"alice" password:@"secret" persistence:NSURLCredentialPersistenceForSession];
        NSDictionary *passwordList = propertyList(password);
        check([passwordList[@"type"] intValue] == 0 && [passwordList[@"persistence"] intValue] == 2
            && [passwordList[@"user"] isEqualToString:@"alice"] && [passwordList[@"password"] isEqualToString:@"secret"],
            "a password credential writes its kind, persistence, user and password");
        NSURLCredential *passwordBack = fromPropertyList([NSURLCredential class], passwordList);
        check([passwordBack.user isEqualToString:@"alice"] && [passwordBack.password isEqualToString:@"secret"]
            && passwordBack.persistence == NSURLCredentialPersistenceForSession, "and reads back whole");

        // A server-trust credential carries its trust, as itself.
        NSURLCredential *trustCredential = [NSURLCredential credentialForTrust:trust];
        NSDictionary *trustList = propertyList(trustCredential);
        check([trustList[@"type"] intValue] == 1 && trustList[@"trust"] == (id)trust, "a server-trust credential writes its kind and its trust");
        NSURLCredential *trustBack = fromPropertyList([NSURLCredential class], trustList);
        check(trustBack != nil && propertyList(trustBack)[@"trust"] == (id)trust, "and reads back holding that trust");

        // A client-certificate credential crosses as its kind alone; 10.9 has no such credential to make.
        check(fromPropertyList([NSURLCredential class], @{ @"type": @3, @"persistence": @1 }) == nil,
            "a client-certificate kind without an identity answers nil");
        check(fromPropertyList([NSURLCredential class], @{ @"type": @2, @"persistence": @1 }) == nil,
            "a kind 10.9 cannot construct answers nil");

        if (failures) {
            printf("Foundation-secure-coding: %d check(s) FAILED\n", failures);
            return 1;
        }
        printf("Foundation-secure-coding: all checks passed\n");
    }
    return 0;
}
