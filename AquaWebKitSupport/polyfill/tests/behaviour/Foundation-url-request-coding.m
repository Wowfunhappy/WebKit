// -[NSURLRequest _webKitPropertyListData] / -_initWithWebKitPropertyListData: (methods/Foundation.m),
// which WebKit's CoreIPCNSURLRequest reads and writes. A request comes back from its dictionary with
// every field a 10.9 request carries: URL, method, header fields (a repeated field keeps each value),
// cache policy, timeout, main document URL, cookie handling, cellular and idle-sleep flags, network
// service type, priority, content-disposition fallback encodings and NSURLProtocol properties. The
// body data and file parts retain their contents, and an immutable request retains its class.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdlib.h>

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

static NSURLRequest *fromPropertyList(NSDictionary *dictionary)
{
    return ((id (*)(id, SEL, NSDictionary *))objc_msgSend)([NSURLRequest alloc], sel_getUid("wk__initWithWebKitPropertyListData:"), dictionary);
}

typedef const struct _CFURLRequest *CFURLRequestRef;
extern CFIndex CFURLRequestGetRequestPriority(CFURLRequestRef);
extern CFURLRequestRef CFURLRequestCreateMutableCopy(CFAllocatorRef, CFURLRequestRef);
static void *allocateRequest(CFIndex size, CFOptionFlags hint, void *info)
{
    (void)hint; (void)info;
    return malloc((size_t)size);
}
static void deallocateRequest(void *pointer, void *info)
{
    (void)info;
    free(pointer);
}
static CFIndex priority(NSURLRequest *request)
{
    return CFURLRequestGetRequestPriority(((CFURLRequestRef (*)(id, SEL))objc_msgSend)(request, sel_getUid("_CFURLRequest")));
}

static NSString * const siteForCookiesKey = @"_kCFHTTPCookiePolicyPropertySiteForCookies";

static id nativeSiteForCookies(NSURLRequest *request)
{
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(request, sel_getUid("_propertyForKey:"), siteForCookiesKey);
}

static void siteForCookiesRoundTrip(NSURL *site, BOOL mutableRequest)
{
    NSURLRequest *back = nil;
    NSDictionary *snapshot = nil;
    NSString *expectedAddress = [site.absoluteString copy];
    @autoreleasepool {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://cookies.example/request"]];
        if (site)
            [NSURLProtocol setProperty:site forKey:siteForCookiesKey inRequest:request];
        NSURL *unrelatedURL = [NSURL URLWithString:@"https://other.example/property"];
        [NSURLProtocol setProperty:unrelatedURL forKey:@"UnrelatedURL" inRequest:request];
        [NSURLProtocol setProperty:@YES forKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation" inRequest:request];
        CFURLRequestRef nativeRequest = ((CFURLRequestRef (*)(id, SEL))objc_msgSend)(request, sel_getUid("_CFURLRequest"));
        NSURLRequest *source = mutableRequest ? [request retain]
            : ((id (*)(id, SEL, CFURLRequestRef))objc_msgSend)([NSURLRequest alloc], sel_getUid("_initWithCFURLRequest:"), nativeRequest);
        check([source isKindOfClass:[NSMutableURLRequest class]] == mutableRequest, "cookie-site source has the requested mutable or immutable class");
        snapshot = [propertyList(source) retain];
        NSDictionary *properties = snapshot[@"protocolProperties"];
        id encoded = properties[siteForCookiesKey];
        check(site ? [encoded isKindOfClass:[NSString class]] && [encoded isEqual:expectedAddress] : !encoded,
            "cookie-site schema distinguishes absolute string, empty string and absence");
        check(site ? [nativeSiteForCookies(source) isKindOfClass:[NSURL class]] && [nativeSiteForCookies(source) isEqual:site] : !nativeSiteForCookies(source),
            "serializing a cookie site does not change the native source property");
        check([properties[@"UnrelatedURL"] isEqual:unrelatedURL], "one-key normalization preserves unrelated URL-valued properties");
        check([[NSURLProtocol propertyForKey:@"UnrelatedURL" inRequest:source] isEqual:unrelatedURL], "serialization preserves the source's unrelated protocol property");
        back = fromPropertyList(snapshot);
        NSURL *changedURL = [NSURL URLWithString:@"https://changed.example/"];
        [NSURLProtocol setProperty:changedURL forKey:siteForCookiesKey inRequest:request];
        [NSURLProtocol setProperty:changedURL forKey:@"UnrelatedURL" inRequest:request];
        check((site ? [properties[siteForCookiesKey] isEqual:expectedAddress] : !properties[siteForCookiesKey])
            && [properties[@"UnrelatedURL"] isEqual:unrelatedURL],
            "encoded properties remain isolated from subsequent source mutations");
        [source release];
    }
    id restored = nativeSiteForCookies(back);
    check(site ? [restored isKindOfClass:[NSURL class]] && [[restored absoluteString] isEqual:expectedAddress] : !restored,
        "native cookie-site URL, empty URL or absence survives the autorelease-pool drain");
    check([back isKindOfClass:[NSMutableURLRequest class]] == mutableRequest, "cookie-site reconstruction preserves immutable and mutable request classes");
    check([[NSURLProtocol propertyForKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation" inRequest:back] isEqual:@YES],
        "cookie-site normalization preserves top-level-navigation metadata");
    check([propertyList(back) isEqual:snapshot], "cookie-site protocol-property schema has a stable round trip");
    [back release];
    [snapshot release];
    [expectedAddress release];
}

static void siteForCookiesCoding()
{
    NSURL *sameSite = [NSURL URLWithString:@"https://cookies.example/path?q=1"];
    NSURL *crossSite = [NSURL URLWithString:@""];
    NSURL *escaped = [NSURL URLWithString:@"https://cookies.example/caf%C3%A9/%2F?q=%E2%98%83&literal=%25"];
    NSURL *relative = [NSURL URLWithString:@"../caf%C3%A9?q=%2F" relativeToURL:[NSURL URLWithString:@"https://cookies.example/base/child/"]];
    check(crossSite && !crossSite.absoluteString.length, "the cross-site sentinel is a nonnil empty NSURL");
    check([escaped.absoluteString isEqual:@"https://cookies.example/caf%C3%A9/%2F?q=%E2%98%83&literal=%25"],
        "escaped UTF-8 and reserved URL bytes retain their original escaping");
    check([relative.absoluteString isEqual:@"https://cookies.example/base/caf%C3%A9?q=%2F"], "relative cookie-site fixture has an independently specified absolute URL");
    for (unsigned mutableRequest = 0; mutableRequest < 2; ++mutableRequest) {
        siteForCookiesRoundTrip(sameSite, mutableRequest);
        siteForCookiesRoundTrip(crossSite, mutableRequest);
        siteForCookiesRoundTrip(nil, mutableRequest);
        siteForCookiesRoundTrip(escaped, mutableRequest);
        siteForCookiesRoundTrip(relative, mutableRequest);
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:sameSite];
    [NSURLProtocol setProperty:@"https://cookies.example/already-encoded" forKey:siteForCookiesKey inRequest:request];
    NSDictionary *alreadyEncoded = propertyList(request);
    check([alreadyEncoded[@"protocolProperties"][siteForCookiesKey] isEqual:@"https://cookies.example/already-encoded"],
        "an already schema-typed NSString is preserved on serialization");
    NSURLRequest *back = fromPropertyList(alreadyEncoded);
    check([nativeSiteForCookies(back) isKindOfClass:[NSURL class]] && [[nativeSiteForCookies(back) absoluteString] isEqual:@"https://cookies.example/already-encoded"],
        "a schema-typed cookie-site string reconstructs as a native URL");
    [back release];

    for (id wrongType in @[ @42, [NSData dataWithBytes:"x" length:1], [NSNull null] ]) {
        [NSURLProtocol setProperty:wrongType forKey:siteForCookiesKey inRequest:request];
        [NSURLProtocol setProperty:wrongType forKey:@"UnrelatedValue" inRequest:request];
        NSDictionary *encoded = propertyList(request);
        check(!encoded[@"protocolProperties"][siteForCookiesKey] && [nativeSiteForCookies(request) isEqual:wrongType],
            "wrong native cookie-site classes are omitted without mutating the source");
        check([encoded[@"protocolProperties"][@"UnrelatedValue"] isEqual:wrongType], "wrong-type handling does not filter unrelated protocol properties");
    }
    for (id wrongType in @[ @42, sameSite, [NSData dataWithBytes:"x" length:1], [NSNull null] ]) {
        NSMutableDictionary *encoded = [[alreadyEncoded mutableCopy] autorelease];
        encoded[@"protocolProperties"] = @{ siteForCookiesKey: wrongType, @"UnrelatedValue": wrongType };
        NSURLRequest *decoded = fromPropertyList(encoded);
        check(!nativeSiteForCookies(decoded), "reconstruction rejects non-string values for the cookie-site schema key");
        check([[NSURLProtocol propertyForKey:@"UnrelatedValue" inRequest:decoded] isEqual:wrongType], "reconstruction leaves unrelated property classes unchanged");
        [decoded release];
    }
}

int main(void)
{
    @autoreleasepool {
        siteForCookiesCoding();
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://a.example/path?q=1"]
            cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:17];
        request.HTTPMethod = @"POST";
        [request addValue:@"one" forHTTPHeaderField:@"X-Multi"];
        [request addValue:@"two" forHTTPHeaderField:@"X-Multi"];
        [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [@"body" dataUsingEncoding:NSUTF8StringEncoding];
        request.mainDocumentURL = [NSURL URLWithString:@"https://top.example/"];
        request.HTTPShouldHandleCookies = NO;
        request.allowsCellularAccess = NO;
        request.networkServiceType = NSURLNetworkServiceTypeBackground;
        ((void (*)(id, SEL, long))objc_msgSend)(request, sel_getUid("setRequestPriority:"), 3);
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(request, sel_getUid("setContentDispositionEncodingFallbackArray:"), @[ @(NSWindowsCP1252StringEncoding) ]);
        [NSURLProtocol setProperty:@"partition.example" forKey:@"_kCFURLCachePartitionKey" inRequest:request];
        [NSURLProtocol setProperty:@YES forKey:@"appFlag" inRequest:request];

        NSDictionary *dictionary = propertyList(request);
        check(dictionary != nil, "a request answers a property list");
        check([dictionary[@"isHTTP"] boolValue], "an https request is an HTTP request");
        check([dictionary[@"headerFields"][@"X-Multi"] isEqual:@[ @"one,two" ]], "a repeated header field travels as its combined value");
        check([dictionary[@"body"] isEqual:request.HTTPBody], "body data enters the dictionary");

        NSURLRequest *back = fromPropertyList(dictionary);
        check([back isKindOfClass:[NSMutableURLRequest class]], "a mutable request comes back mutable");
        check([back.URL isEqual:request.URL], "URL");
        check([back.HTTPMethod isEqualToString:@"POST"], "HTTP method");
        check([[back valueForHTTPHeaderField:@"X-Multi"] isEqualToString:@"one,two"], "repeated header field");
        check([[back valueForHTTPHeaderField:@"Content-Type"] isEqualToString:@"text/plain"], "header field");
        check([back.HTTPBody isEqual:request.HTTPBody], "body data survives the round trip");
        check(back.cachePolicy == NSURLRequestReturnCacheDataElseLoad, "cache policy");
        check(back.timeoutInterval == 17, "timeout");
        check([back.mainDocumentURL isEqual:request.mainDocumentURL], "main document URL");
        check(!back.HTTPShouldHandleCookies, "cookie handling");
        check(!back.allowsCellularAccess, "cellular access");
        check(back.networkServiceType == NSURLNetworkServiceTypeBackground, "network service type");
        check(priority(back) == 3, "priority");
        NSArray *encodings = ((NSArray *(*)(id, SEL))objc_msgSend)(back, sel_getUid("contentDispositionEncodingFallbackArray"));
        check([encodings isEqual:@[ @(NSWindowsCP1252StringEncoding) ]], "content-disposition fallback encodings");
        check([[NSURLProtocol propertyForKey:@"_kCFURLCachePartitionKey" inRequest:back] isEqual:@"partition.example"], "cache partition protocol property");
        check([[NSURLProtocol propertyForKey:@"appFlag" inRequest:back] isEqual:@YES], "app protocol property");
        check([propertyList(back) isEqual:dictionary], "the round trip is stable");

        NSMutableURLRequest *flagsRequest = [NSMutableURLRequest requestWithURL:request.URL];
        unsigned baselineFlags = [propertyList(flagsRequest)[@"explicitFlags"] unsignedIntValue];
        flagsRequest.HTTPShouldHandleCookies = YES;
        check([propertyList(flagsRequest)[@"explicitFlags"] unsignedIntValue] == (baselineFlags | (1u << 1)), "assigning the default cookie value marks it explicit");
        flagsRequest.HTTPShouldUsePipelining = NO;
        check([propertyList(flagsRequest)[@"explicitFlags"] unsignedIntValue] == (baselineFlags | (1u << 1) | (1u << 6)), "assigning false pipelining marks it explicit");
        NSMutableDictionary *implicitDictionary = [[propertyList(flagsRequest) mutableCopy] autorelease];
        implicitDictionary[@"explicitFlags"] = @0;
        NSURLRequest *implicitBack = fromPropertyList(implicitDictionary);
        check([propertyList(implicitBack)[@"explicitFlags"] unsignedIntValue] == 0, "zero explicit flags survive native property setters");
        check(implicitBack.HTTPShouldHandleCookies && !implicitBack.HTTPShouldUsePipelining, "explicit flags are separate from property values");

        CFAllocatorContext allocatorContext = { 0, NULL, NULL, NULL, NULL, allocateRequest, NULL, deallocateRequest, NULL };
        CFAllocatorRef allocator = CFAllocatorCreate(NULL, &allocatorContext);
        CFURLRequestRef nativeRequest = ((CFURLRequestRef (*)(id, SEL))objc_msgSend)(request, sel_getUid("_CFURLRequest"));
        CFURLRequestRef customRequest = CFURLRequestCreateMutableCopy(allocator, nativeRequest);
        NSURLRequest *customBacked = ((id (*)(id, SEL, CFURLRequestRef))objc_msgSend)([NSURLRequest alloc], sel_getUid("_initWithCFURLRequest:"), customRequest);
        check(((CFURLRequestRef (*)(id, SEL))objc_msgSend)(customBacked, sel_getUid("_CFURLRequest")) == customRequest, "request retains its custom CFAllocator backing");
        check([propertyList(fromPropertyList(propertyList(customBacked))) isEqual:propertyList(customBacked)], "custom-allocator request preserves all dictionary fields");
        [customBacked release];
        CFRelease(customRequest);
        CFRelease(allocator);

        NSMutableDictionary *immutableAsked = [[dictionary mutableCopy] autorelease];
        immutableAsked[@"isMutable"] = @NO;
        NSURLRequest *immutable = fromPropertyList(immutableAsked);
        check([immutable.URL isEqual:request.URL] && [[immutable valueForHTTPHeaderField:@"X-Multi"] isEqualToString:@"one,two"], "an immutable request carries the same fields");
        check(![immutable isKindOfClass:[NSMutableURLRequest class]], "a dictionary that asks for an immutable request gets one");
        check(![propertyList(immutable)[@"isMutable"] boolValue], "and it writes itself back as immutable");
        check([immutable.HTTPBody isEqual:request.HTTPBody], "an immutable request retains its body");

        NSString *bodyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSData *fileData = [@"file body" dataUsingEncoding:NSUTF8StringEncoding];
        check([fileData writeToFile:bodyPath atomically:YES], "create a body-part file");
        NSArray *parts = @[ [@"before:" dataUsingEncoding:NSUTF8StringEncoding], bodyPath,
            [@":after" dataUsingEncoding:NSUTF8StringEncoding] ];
        NSMutableDictionary *partsDictionary = [[dictionary mutableCopy] autorelease];
        [partsDictionary removeObjectForKey:@"body"];
        partsDictionary[@"bodyParts"] = parts;
        NSURLRequest *partsRequest = fromPropertyList(partsDictionary);
        check([propertyList(partsRequest)[@"bodyParts"] isEqual:parts], "data and file body parts enter the dictionary");
        NSURLRequest *partsBack = fromPropertyList(propertyList(partsRequest));
        NSInputStream *stream = partsBack.HTTPBodyStream;
        [stream open];
        NSMutableData *streamData = [NSMutableData data];
        uint8_t buffer[64];
        NSInteger count;
        while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
            [streamData appendBytes:buffer length:(NSUInteger)count];
        check(stream && count == 0 && !stream.streamError, "body-part stream finishes without error");
        check([streamData isEqual:[@"before:file body:after" dataUsingEncoding:NSUTF8StringEncoding]], "body-part stream preserves bytes and order");
        [stream close];
        [[NSFileManager defaultManager] removeItemAtPath:bodyPath error:NULL];

        NSURLRequest *file = [NSURLRequest requestWithURL:[NSURL fileURLWithPath:@"/tmp/x"]];
        NSDictionary *fileDictionary = propertyList(file);
        check(![fileDictionary[@"isHTTP"] boolValue] && !fileDictionary[@"headerFields"], "a file request is not an HTTP request");
        NSURLRequest *fileBack = fromPropertyList(fileDictionary);
        check([fileBack.URL isEqual:file.URL], "a file request round-trips its URL");
        NSDictionary *fileBackDictionary = propertyList(fileBack);
        if (![fileBackDictionary isEqual:fileDictionary])
            NSLog(@"file request before=%@ after=%@", fileDictionary, fileBackDictionary);
        check([fileBackDictionary isEqual:fileDictionary], "file request preserves every field and its non-HTTP state");
        check([propertyList(file) isEqual:fileDictionary], "serializing a file request preserves its native state");

        for (NSString *address in @[@"http://host/path", @"file:///tmp/materialized", @"custom-scheme://host/path"]) {
            NSMutableURLRequest *materialized = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
            NSDictionary *untouched = propertyList(materialized);
            check(![untouched[@"isHTTP"] boolValue] && [propertyList(fromPropertyList(untouched)) isEqual:untouched],
                "untouched request preserves absent HTTP metadata independently of its URL scheme");
            ((void (*)(id, SEL, long))objc_msgSend)(materialized, sel_getUid("setRequestPriority:"), -1);
            NSDictionary *materializedDictionary = propertyList(materialized);
            check([materializedDictionary[@"isHTTP"] boolValue], "explicit default priority materializes native HTTP metadata");
            check([propertyList(fromPropertyList(materializedDictionary)) isEqual:materializedDictionary],
                "request with materialized HTTP metadata preserves every field");
        }

        check(fromPropertyList(@{ }) != nil, "an empty dictionary gives a request, as the coder's defaults do");
    }
    printf("Foundation-url-request-coding: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
