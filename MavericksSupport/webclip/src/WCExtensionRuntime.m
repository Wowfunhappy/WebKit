#import "WCExtensionRuntime.h"

#import "WCSafariContentLists.h"
#import "WCWebKitSPI.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <pthread.h>

static NSString * const extensionScheme = @"safari-extension";
// Messages between the plug-in and its injected bundle (WCPageExtensions.h).
static NSString * const messageFromContent = @"WebClipSafariMessage";
static NSString * const canLoadFromContent = @"WebClipSafariCanLoad";
static NSString * const messageToContent = @"WebClipSafariMessage";

// Each clip's runtime, on the main thread: the injected bundle's messages reach the one whose extension a
// message names.
static NSMutableArray<WCExtensionRuntime *> *runtimes(void)
{
    static NSMutableArray *runtimes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        runtimes = [NSMutableArray array];
    });
    return runtimes;
}

// The files of every running extension, which the protocol serves on loading threads: by the extension's key
// in its clip, the root of its URLs and the directory of its files.
static pthread_mutex_t servedFilesLock = PTHREAD_MUTEX_INITIALIZER;
static NSDictionary<NSString *, NSArray<NSString *> *> *servedFiles;

static void setServedFiles(NSString *key, NSArray<NSString *> *rootAndBundlePath)
{
    pthread_mutex_lock(&servedFilesLock);
    NSMutableDictionary *files = [servedFiles mutableCopy] ?: [NSMutableDictionary dictionary];
    if (rootAndBundlePath)
        files[key] = rootAndBundlePath;
    else
        [files removeObjectForKey:key];
    servedFiles = [files copy];
    pthread_mutex_unlock(&servedFilesLock);
}

static NSArray<NSString *> *servedFilesOfKey(NSString *key)
{
    pthread_mutex_lock(&servedFilesLock);
    NSArray *rootAndBundlePath = key ? servedFiles[key] : nil;
    pthread_mutex_unlock(&servedFilesLock);
    return rootAndBundlePath;
}

// The extension's file a safari-extension:// URL names; nil outside the extension's files.
static NSString *filePathForURL(NSURL *url, NSString *root, NSString *bundlePath)
{
    NSString *string = url.absoluteString;
    if (![string hasPrefix:root])
        return nil;
    NSString *relativePath = [string substringFromIndex:root.length];
    NSRange end = [relativePath rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    if (end.location != NSNotFound)
        relativePath = [relativePath substringToIndex:end.location];
    relativePath = [relativePath stringByRemovingPercentEncoding];
    if (!relativePath)
        return nil;
    NSString *path = [[bundlePath stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    if (![path hasPrefix:[[bundlePath stringByStandardizingPath] stringByAppendingString:@"/"]])
        return nil;
    return path;
}

@interface WCExtensionPopover : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) NSNumber *width;
@property (nonatomic, strong) NSNumber *height;
@property (nonatomic, strong) WebView *view;
@end

@implementation WCExtensionPopover
@end

// An extension of the copy as Safari loads it: its files at safari-extension://<key>/<token>/ with a token of
// this launch, its settings, its content scripts and style sheets -- Info.plist's first and then those its
// pages add -- and its pages.
@interface WCExtension : NSObject
// The extension's key in Safari, and its key in the clip: Safari's with the clip's identifier, so that each
// clip's copy has its own pages, content worlds and storage in the process all clips share.
@property (nonatomic, copy) NSString *safariKey;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *root;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, strong) NSDictionary *info;
@property (nonatomic, strong) NSMutableDictionary *settings;
@property (nonatomic, strong) NSMutableArray<NSArray *> *originAccessEntries;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *content;
@property (nonatomic) NSUInteger generatedContentCount;
@property (nonatomic, strong) WebView *globalPage;
@property (nonatomic, strong) NSMutableArray<WCExtensionPopover *> *popovers;
@end

@implementation WCExtension

- (NSDictionary *)chrome
{
    NSDictionary *chrome = self.info[@"Chrome"];
    return [chrome isKindOfClass:[NSDictionary class]] ? chrome : nil;
}

- (NSString *)globalPageURL
{
    NSString *globalPage = self.chrome[@"Global Page"];
    return [globalPage isKindOfClass:[NSString class]] ? [self.root stringByAppendingString:globalPage] : nil;
}

@end

@interface WCExtensionRuntime () <WebFrameLoadDelegate>
+ (WCExtensionRuntime *)runtimeOfExtensionKey:(NSString *)key;
- (void)didReceiveMessage:(NSDictionary *)description message:(WKSerializedScriptValueRef)message fromPage:(WKPageRef)page;
- (WKSerializedScriptValueRef)copyAnswerToCanLoadMessage:(NSDictionary *)description message:(WKSerializedScriptValueRef)message fromPage:(WKPageRef)page;
@end

// Serves safari-extension:// to the extensions' pages and, as WebKit's custom protocol, to the clip's pages,
// on the loading thread, which a synchronous load from the main thread waits on.
@interface WCExtensionURLProtocol : NSURLProtocol
@end

@implementation WCExtensionURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return [request.URL.scheme caseInsensitiveCompare:extensionScheme] == NSOrderedSame;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    NSURL *url = self.request.URL;
    NSArray *rootAndBundlePath = servedFilesOfKey(url.host);
    NSString *path = rootAndBundlePath ? filePathForURL(url, rootAndBundlePath[0], rootAndBundlePath[1]) : nil;
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSString *mimeType = data ? WCMIMETypeForPath(path) : nil;
    if (!data) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
        return;
    }
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:self.request.URL MIMEType:mimeType expectedContentLength:data.length textEncodingName:nil];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading
{
}

@end

static NSString *stringFromWK(WKTypeRef value)
{
    if (!value || WKGetTypeID(value) != WKStringGetTypeID())
        return nil;
    return CFBridgingRelease(WKStringCopyCFString(kCFAllocatorDefault, (WKStringRef)value));
}

static WKStringRef createWKString(NSString *string)
{
    return WKStringCreateWithCFString((__bridge CFStringRef)string);
}

static id objectFromJSONText(NSString *text);
static NSString *jsonText(id object);

// A message crosses as a dictionary: its description, JSON text, and the extension's message, a structured
// clone as Safari's are. A content script's message also carries the page it comes from.
static NSString * const descriptionKey = @"description";
static NSString * const messageKey = @"message";
static NSString * const pageKey = @"page";

static WKTypeRef messageBodyItem(WKTypeRef body, NSString *key)
{
    if (!body || WKGetTypeID(body) != WKDictionaryGetTypeID())
        return NULL;
    WKStringRef wkKey = createWKString(key);
    WKTypeRef item = WKDictionaryGetItemForKey((WKDictionaryRef)body, wkKey);
    WKRelease(wkKey);
    return item;
}

static NSDictionary *descriptionOfMessageBody(WKTypeRef body)
{
    NSDictionary *description = objectFromJSONText(stringFromWK(messageBodyItem(body, descriptionKey)));
    return [description isKindOfClass:[NSDictionary class]] ? description : nil;
}

static WKSerializedScriptValueRef serializedValue(WKTypeRef value)
{
    return value && WKGetTypeID(value) == WKSerializedScriptValueGetTypeID() ? (WKSerializedScriptValueRef)value : NULL;
}

static WKPageRef pageOfMessageBody(WKTypeRef body)
{
    WKTypeRef page = messageBodyItem(body, pageKey);
    return page && WKGetTypeID(page) == WKPageGetTypeID() ? (WKPageRef)page : NULL;
}

static WKMutableDictionaryRef createMessageBody(NSDictionary *description, WKSerializedScriptValueRef message)
{
    WKMutableDictionaryRef body = WKMutableDictionaryCreate();
    WKStringRef key = createWKString(descriptionKey);
    WKStringRef text = createWKString(jsonText(description));
    WKDictionarySetItem(body, key, text);
    WKRelease(key);
    WKRelease(text);
    key = createWKString(messageKey);
    WKDictionarySetItem(body, key, message);
    WKRelease(key);
    return body;
}

// The message in a page of the extension; a message that cannot be read there is undefined.
static JSValue *deserialize(WKSerializedScriptValueRef message, JSContext *context)
{
    JSValueRef value = message ? WKSerializedScriptValueDeserialize(message, context.JSGlobalContextRef, NULL) : NULL;
    return value ? [JSValue valueWithJSValueRef:value inContext:context] : [JSValue valueWithUndefinedInContext:context];
}

// A content script's message names its extension by the root of the extension's files.
static WCExtensionRuntime *runtimeOfMessage(NSDictionary *description)
{
    NSString *root = description[@"root"];
    return [root isKindOfClass:[NSString class]] ? [WCExtensionRuntime runtimeOfExtensionKey:[NSURL URLWithString:root].host] : nil;
}

static void didReceiveMessageFromInjectedBundle(WKContextRef, WKStringRef name, WKTypeRef body, const void *)
{
    if (![stringFromWK(name) isEqualToString:messageFromContent])
        return;
    NSDictionary *description = descriptionOfMessageBody(body);
    [runtimeOfMessage(description) didReceiveMessage:description message:serializedValue(messageBodyItem(body, messageKey)) fromPage:pageOfMessageBody(body)];
}

static void didReceiveSynchronousMessageFromInjectedBundle(WKContextRef, WKStringRef name, WKTypeRef body, WKTypeRef *returnData, const void *)
{
    *returnData = NULL;
    if (![stringFromWK(name) isEqualToString:canLoadFromContent])
        return;
    NSDictionary *description = descriptionOfMessageBody(body);
    *returnData = [runtimeOfMessage(description) copyAnswerToCanLoadMessage:description message:serializedValue(messageBodyItem(body, messageKey)) fromPage:pageOfMessageBody(body)];
}

static NSString *jsonText(id object)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static id objectFromJSONText(NSString *text)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// Safari's name for itself in the user agent its extension pages load with.
static NSString *safariApplicationNameForUserAgent(void)
{
    NSString *safariPath = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:@"com.apple.Safari"];
    NSDictionary *info = safariPath ? [NSBundle bundleWithPath:safariPath].infoDictionary : nil;
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    if (![version isKindOfClass:[NSString class]] || ![build isKindOfClass:[NSString class]])
        return nil;
    return [NSString stringWithFormat:@"Version/%@ Safari/%@", version, build];
}

// A value of a Settings.plist default, as JSON text.
static NSString *jsonTextOfPlistValue(id value)
{
    if (!value)
        return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:nil];
    NSString *array = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return array.length >= 2 ? [array substringWithRange:NSMakeRange(1, array.length - 2)] : nil;
}

@implementation WCExtensionRuntime {
    NSString *_directory;
    NSString *_clipIdentifier;
    NSMutableArray<WCExtension *> *_extensions;
    // The receiver of each extension page's events from the runtime, by its view.
    NSMapTable<WebView *, JSValue *> *_receivers;
    // The clip's web views, the tabs of the clip's window, by the token each has as a tab, in the order the
    // clip made them; and the user content controllers of the clip's pages with the scripts and style sheets
    // the extensions' content became in each.
    NSMapTable<NSString *, WKWebView *> *_tabs;
    NSUInteger _tabCount;
    NSMapTable<WKUserContentController *, NSMutableDictionary<NSDictionary *, id> *> *_installedContent;
    NSString *_pageScript;
}

+ (void)serveProcessPool:(WKProcessPool *)processPool
{
    static WKContextInjectedBundleClientV0 client = {
        0,
        NULL,
        didReceiveMessageFromInjectedBundle,
        didReceiveSynchronousMessageFromInjectedBundle,
    };
    WKContextSetInjectedBundleClient((__bridge WKContextRef)processPool, &client);
    [NSURLProtocol registerClass:[WCExtensionURLProtocol class]];
    [WKBrowsingContextController registerSchemeForCustomProtocol:extensionScheme];
}

// WebKit 1's directories for the process's local storage (WebStorageManager's) and indexed databases
// (WebDatabaseProvider::indexedDatabaseDirectoryPath).
+ (NSString *)localStorageDirectory
{
    return [WebStorageManager _storageDirectoryPath];
}

+ (NSString *)indexedDatabaseDirectory
{
    NSString *databases = [[NSUserDefaults standardUserDefaults] stringForKey:@"WebDatabaseDirectory"];
    if (databases)
        return [[databases stringByAppendingPathComponent:@"___IndexedDB"] stringByStandardizingPath];
    return [[@"~/Library/WebKit/Databases/___IndexedDB" stringByAppendingPathComponent:[NSBundle mainBundle].bundleIdentifier] stringByStandardizingPath];
}

+ (NSString *)extensionKey:(NSString *)key ofClip:(NSString *)clipIdentifier
{
    return [NSString stringWithFormat:@"%@.%@", key, clipIdentifier];
}

+ (instancetype)runtimeOfClip:(NSString *)clipIdentifier directory:(NSString *)directory
{
    for (WCExtensionRuntime *runtime in runtimes()) {
        if ([runtime->_clipIdentifier isEqualToString:clipIdentifier])
            return runtime;
    }
    WCExtensionRuntime *runtime = [[self alloc] initWithClip:clipIdentifier directory:directory];
    [runtimes() addObject:runtime];
    [runtime start];
    return runtime;
}

- (void)invalidate
{
    [runtimes() removeObject:self];
    for (WCExtension *extension in _extensions) {
        setServedFiles(extension.key, nil);
        for (NSArray *entry in extension.originAccessEntries)
            [WebView _removeOriginAccessWhitelistEntryWithSourceOrigin:entry[0] destinationProtocol:entry[1] destinationHost:entry[2] allowDestinationSubdomains:[entry[3] boolValue]];
        [extension.globalPage close];
        extension.globalPage = nil;
        for (WCExtensionPopover *popover in extension.popovers)
            [popover.view close];
        [extension.popovers removeAllObjects];
        [extension.content removeAllObjects];
    }
    [_receivers removeAllObjects];
    [self publishContent];
    [_extensions removeAllObjects];
}

+ (WCExtensionRuntime *)runtimeOfExtensionKey:(NSString *)key
{
    for (WCExtensionRuntime *runtime in runtimes()) {
        if ([runtime extensionWithKey:key])
            return runtime;
    }
    return nil;
}

- (instancetype)initWithClip:(NSString *)clipIdentifier directory:(NSString *)directory
{
    if (!(self = [super init]))
        return nil;
    _clipIdentifier = [clipIdentifier copy];
    _directory = [directory copy];
    _extensions = [NSMutableArray array];
    _receivers = [NSMapTable strongToStrongObjectsMapTable];
    _tabs = [NSMapTable strongToWeakObjectsMapTable];
    _installedContent = [NSMapTable weakToStrongObjectsMapTable];
    NSString *pageScriptPath = [[NSBundle bundleForClass:[WCExtensionRuntime class]] pathForResource:@"WCSafariExtensionPage" ofType:@"js"];
    _pageScript = [NSString stringWithContentsOfFile:pageScriptPath encoding:NSUTF8StringEncoding error:nil];
    return self;
}

- (void)start
{
    [self loadExtensions];
    for (WCExtension *extension in _extensions)
        [self loadPagesOfExtension:extension];
}

#pragma mark The copy

- (NSString *)pathInCopy:(NSString *)component
{
    return [_directory stringByAppendingPathComponent:component];
}

- (WCExtension *)extensionWithRoot:(id)root
{
    for (WCExtension *extension in _extensions) {
        if ([extension.root isEqual:root])
            return extension;
    }
    return nil;
}

- (WCExtension *)extensionWithKey:(NSString *)key
{
    for (WCExtension *extension in _extensions) {
        if ([extension.key isEqualToString:key])
            return extension;
    }
    return nil;
}

- (void)loadExtensions
{
    NSArray *manifest = [NSArray arrayWithContentsOfFile:[self pathInCopy:@"Extensions.plist"]];
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[self pathInCopy:@"Settings.plist"]];
    for (NSDictionary *entry in manifest) {
        NSString *key = [entry isKindOfClass:[NSDictionary class]] ? entry[@"Key"] : nil;
        if (![key isKindOfClass:[NSString class]] || [self extensionWithKey:[WCExtensionRuntime extensionKey:key ofClip:_clipIdentifier]])
            continue;
        NSString *bundlePath = [[self pathInCopy:@"Extensions"] stringByAppendingPathComponent:key];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (!info)
            continue;
        WCExtension *extension = [[WCExtension alloc] init];
        extension.safariKey = key;
        extension.key = [WCExtensionRuntime extensionKey:key ofClip:_clipIdentifier];
        extension.token = [NSString stringWithFormat:@"%08x", arc4random()];
        extension.root = [NSString stringWithFormat:@"%@://%@/%@/", extensionScheme, extension.key, extension.token];
        extension.bundlePath = bundlePath;
        extension.info = info;
        NSDictionary *extensionSettings = [settings[key] isKindOfClass:[NSDictionary class]] ? settings[key] : nil;
        id storedSettings = extensionSettings[@"Settings"];
        extension.settings = [[storedSettings isKindOfClass:[NSDictionary class]] ? storedSettings : @{ } mutableCopy];
        extension.content = [NSMutableArray array];
        extension.popovers = [NSMutableArray array];
        extension.originAccessEntries = [NSMutableArray array];
        [self loadInfoPlistContentOfExtension:extension];
        [_extensions addObject:extension];
        setServedFiles(extension.key, @[ extension.root, extension.bundlePath ]);
    }
}

#pragma mark Content scripts and style sheets

- (NSDictionary *)contentItemOfExtension:(WCExtension *)extension script:(BOOL)isScript source:(NSString *)source url:(NSString *)url whitelist:(NSArray *)whitelist blacklist:(NSArray *)blacklist runsAtStart:(BOOL)runsAtStart
{
    NSArray *allow = nil;
    NSArray *block = nil;
    WCSanitizeContentLists(whitelist, blacklist, extension.info[@"Permissions"], &allow, &block);
    return @{
        @"key": extension.key,
        @"root": extension.root,
        @"kind": isScript ? @"script" : @"sheet",
        @"source": source,
        @"url": url,
        @"allow": allow,
        @"block": block,
        @"start": @(runsAtStart),
    };
}

- (NSString *)sourceOfURL:(NSString *)url ofExtension:(WCExtension *)extension
{
    NSString *path = filePathForURL([NSURL URLWithString:url], extension.root, extension.bundlePath);
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

// Info.plist's content: its start scripts, end scripts and style sheets, over its whitelist and blacklist.
- (void)loadInfoPlistContentOfExtension:(WCExtension *)extension
{
    NSDictionary *content = extension.info[@"Content"];
    if (![content isKindOfClass:[NSDictionary class]])
        return;
    void (^add)(id, BOOL, BOOL) = ^(id paths, BOOL isScript, BOOL runsAtStart) {
        for (NSString *path in [paths isKindOfClass:[NSArray class]] ? paths : @[ ]) {
            if (![path isKindOfClass:[NSString class]])
                continue;
            NSString *url = [extension.root stringByAppendingString:path];
            NSString *source = [self sourceOfURL:url ofExtension:extension];
            if (source)
                [extension.content addObject:[self contentItemOfExtension:extension script:isScript source:source url:url whitelist:content[@"Whitelist"] blacklist:content[@"Blacklist"] runsAtStart:runsAtStart]];
        }
    };
    NSDictionary *scripts = content[@"Scripts"];
    if ([scripts isKindOfClass:[NSDictionary class]]) {
        add(scripts[@"Start"], YES, YES);
        add(scripts[@"End"], YES, NO);
    }
    add(content[@"Stylesheets"], NO, NO);
}

// A content item as Safari's bundle injects it: in all frames, in the extension's content world, which the
// injected bundle gives Safari 7's content API (WCPageExtensions.h).
- (id)userContentOfItem:(NSDictionary *)item
{
    WKContentWorld *world = [WKContentWorld worldWithName:item[@"root"]];
    NSURL *url = [NSURL URLWithString:item[@"url"]];
    if ([item[@"kind"] isEqualToString:@"script"])
        return [[WKUserScript alloc] _initWithSource:item[@"source"] injectionTime:[item[@"start"] boolValue] ? WKUserScriptInjectionTimeAtDocumentStart : WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO includeMatchPatternStrings:item[@"allow"] excludeMatchPatternStrings:item[@"block"] associatedURL:url contentWorld:world];
    return [[_WKUserStyleSheet alloc] initWithSource:item[@"source"] forWKWebView:nil forMainFrameOnly:NO includeMatchPatternStrings:item[@"allow"] excludeMatchPatternStrings:item[@"block"] baseURL:url level:_WKUserStyleUserLevel contentWorld:world];
}

// As in Safari, a change adds and removes single scripts and style sheets, which leaves an extension's world,
// and its contexts in loaded pages, alive.
- (void)updateContentOfController:(WKUserContentController *)controller
{
    NSMutableDictionary<NSDictionary *, id> *installed = [_installedContent objectForKey:controller];
    if (!installed) {
        installed = [NSMutableDictionary dictionary];
        [_installedContent setObject:installed forKey:controller];
    }
    NSMutableArray<NSDictionary *> *content = [NSMutableArray array];
    for (WCExtension *extension in _extensions)
        [content addObjectsFromArray:extension.content];
    for (NSDictionary *item in installed.allKeys) {
        if ([content containsObject:item])
            continue;
        id userContent = installed[item];
        if ([userContent isKindOfClass:[WKUserScript class]])
            [controller _removeUserScript:userContent];
        else
            [controller _removeUserStyleSheet:userContent];
        [installed removeObjectForKey:item];
    }
    for (NSDictionary *item in content) {
        if (installed[item])
            continue;
        id userContent = [self userContentOfItem:item];
        if ([userContent isKindOfClass:[WKUserScript class]])
            [controller addUserScript:userContent];
        else
            [controller _addUserStyleSheet:userContent];
        installed[item] = userContent;
    }
}

- (void)publishContent
{
    for (WKUserContentController *controller in _installedContent.keyEnumerator.allObjects)
        [self updateContentOfController:controller];
}

- (NSString *)addContentOfExtension:(WCExtension *)extension kind:(NSString *)kind source:(NSString *)source url:(NSString *)url whitelist:(NSArray *)whitelist blacklist:(NSArray *)blacklist runAtEnd:(BOOL)runAtEnd
{
    BOOL isScript = [kind isEqualToString:@"script"];
    if (!url.length) {
        extension.generatedContentCount++;
        url = [NSString stringWithFormat:@"%@safari-generated-%lu.%@", extension.root, (unsigned long)extension.generatedContentCount, isScript ? @"js" : @"css"];
    } else {
        source = [self sourceOfURL:url ofExtension:extension];
        if (!source)
            return nil;
    }
    [extension.content addObject:[self contentItemOfExtension:extension script:isScript source:source url:url whitelist:whitelist blacklist:blacklist runsAtStart:!runAtEnd]];
    [self publishContent];
    return url;
}

- (void)removeContentOfExtension:(WCExtension *)extension kind:(NSString *)kind url:(NSString *)url
{
    NSIndexSet *removed = [extension.content indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger, BOOL *) {
        return [item[@"kind"] isEqualToString:kind] && (!url.length || [item[@"url"] isEqualToString:url]);
    }];
    if (!removed.count)
        return;
    [extension.content removeObjectsAtIndexes:removed];
    [self publishContent];
}

#pragma mark Settings

- (BOOL)storeSettings
{
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (WCExtension *extension in _extensions)
        settings[extension.safariKey] = @{ @"Settings": extension.settings };
    return [settings writeToFile:[self pathInCopy:@"Settings.plist"] atomically:YES];
}

// Sets a setting's JSON text, or removes the setting for nil; each page of the extension hears of a change.
- (BOOL)setSetting:(NSString *)name json:(NSString *)json ofExtension:(WCExtension *)extension
{
    NSString *oldValue = [self settingOfExtension:extension name:name];
    if (json)
        extension.settings[name] = json;
    else
        [extension.settings removeObjectForKey:name];
    if (![self storeSettings])
        return NO;
    NSString *newValue = [self settingOfExtension:extension name:name];
    if (oldValue == newValue || [oldValue isEqualToString:newValue])
        return YES;
    for (JSValue *receiver in [self receiversOfExtension:extension])
        [receiver invokeMethod:@"settingChanged" withArguments:@[ name, oldValue ?: [NSNull null], newValue ?: [NSNull null] ]];
    return YES;
}

// Settings.plist's entries for settings; those it marks secure are secure settings.
- (NSArray<NSDictionary *> *)settingsDefinitionsOfExtension:(WCExtension *)extension
{
    NSMutableArray *definitions = [NSMutableArray array];
    NSArray *settings = [NSArray arrayWithContentsOfFile:[extension.bundlePath stringByAppendingPathComponent:@"Settings.plist"]];
    for (NSDictionary *definition in settings) {
        if (![definition isKindOfClass:[NSDictionary class]] || ![definition[@"Key"] isKindOfClass:[NSString class]])
            continue;
        id isSecure = definition[@"Secure"];
        if (!([isSecure isKindOfClass:[NSNumber class]] && [isSecure boolValue]))
            [definitions addObject:definition];
    }
    return definitions;
}

// A setting's JSON text; a value never set is Settings.plist's default, and a setting with neither has none.
- (NSString *)settingOfExtension:(WCExtension *)extension name:(NSString *)name
{
    id value = extension.settings[name];
    if ([value isKindOfClass:[NSString class]])
        return value;
    for (NSDictionary *definition in [self settingsDefinitionsOfExtension:extension]) {
        if ([definition[@"Key"] isEqualToString:name])
            return jsonTextOfPlistValue(definition[@"DefaultValue"]);
    }
    return nil;
}

- (NSArray<NSString *> *)settingNamesOfExtension:(WCExtension *)extension
{
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSetWithArray:extension.settings.allKeys];
    for (NSDictionary *definition in [self settingsDefinitionsOfExtension:extension]) {
        if (definition[@"DefaultValue"])
            [names addObject:definition[@"Key"]];
    }
    return names.array;
}

#pragma mark Pages

// The group of the extensions' pages, whose local storage is in WebKit 1's directory for the process. WebKit 1
// gives a group the local storage directory of the preferences of the view that makes it, and a view's page
// keeps the local storage of the group the view was made in: a view made to make the group gives the group
// its directory.
static NSString *extensionPageGroup(void)
{
    static NSString * const groupName = @"WebClip Safari extensions";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WebPreferences *preferences = [[WebPreferences alloc] initWithIdentifier:groupName];
        preferences.autosaves = NO;
        preferences._localStorageDatabasePath = [WCExtensionRuntime localStorageDirectory];
        WebView *view = [[WebView alloc] initWithFrame:NSZeroRect frameName:nil groupName:nil];
        view.preferences = preferences;
        view.groupName = groupName;
        [view close];
    });
    return groupName;
}

// An extension page, in a WebKit 1 view configured as Safari's ExtensionViewController configures one, in the
// extensions' pages' group.
- (WebView *)loadPage:(NSString *)url ofExtension:(WCExtension *)extension preferencesIdentifier:(NSString *)identifier
{
    WebPreferences *preferences = [[WebPreferences alloc] initWithIdentifier:identifier];
    preferences.autosaves = NO;
    preferences.databasesEnabled = YES;
    preferences.javaEnabled = YES;
    preferences.javaScriptEnabled = YES;
    preferences.loadsImagesAutomatically = YES;
    preferences.localStorageEnabled = YES;
    preferences.plugInsEnabled = YES;
    preferences.userStyleSheetEnabled = NO;
    preferences.minimumFontSize = 1;
    preferences.storageBlockingPolicy = WebAllowAllStorage;
    preferences.notificationsEnabled = YES;

    WebView *view = [[WebView alloc] initWithFrame:NSZeroRect frameName:nil groupName:extensionPageGroup()];
    view.applicationNameForUserAgent = safariApplicationNameForUserAgent();
    view.preferences = preferences;
    view.drawsBackground = NO;
    view.frameLoadDelegate = self;
    [view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    return view;
}

// The global page, whose cross-origin loads reach the sites the extension's website access names, and the
// popovers Info.plist declares.
- (void)loadPagesOfExtension:(WCExtension *)extension
{
    NSString *origin = [extension.root substringToIndex:extension.root.length - 1];
    NSDictionary *permissions = extension.info[@"Permissions"];
    NSDictionary *websiteAccess = [permissions isKindOfClass:[NSDictionary class]] ? permissions[@"Website Access"] : nil;
    NSString *level = [websiteAccess isKindOfClass:[NSDictionary class]] ? websiteAccess[@"Level"] : nil;
    BOOL includesSecurePages = [websiteAccess[@"Include Secure Pages"] isKindOfClass:[NSNumber class]] && [websiteAccess[@"Include Secure Pages"] boolValue];
    void (^allow)(NSString *, BOOL) = ^(NSString *host, BOOL includesSubdomains) {
        for (NSString *protocol in includesSecurePages ? @[ @"http", @"https" ] : @[ @"http" ]) {
            [WebView _addOriginAccessWhitelistEntryWithSourceOrigin:origin destinationProtocol:protocol destinationHost:host allowDestinationSubdomains:includesSubdomains];
            [extension.originAccessEntries addObject:@[ origin, protocol, host, @(includesSubdomains) ]];
        }
    };
    if ([level isEqual:@"All"])
        allow(@"", YES);
    else if ([level isEqual:@"Some"]) {
        NSArray *domains = websiteAccess[@"Allowed Domains"];
        for (NSString *domain in [domains isKindOfClass:[NSArray class]] ? domains : @[ ]) {
            if (![domain isKindOfClass:[NSString class]])
                continue;
            BOOL includesSubdomains = [domain hasPrefix:@"*."];
            allow(includesSubdomains ? [domain substringFromIndex:2] : domain, includesSubdomains);
        }
    }

    NSString *globalPageURL = extension.globalPageURL;
    if (globalPageURL)
        extension.globalPage = [self loadPage:globalPageURL ofExtension:extension preferencesIdentifier:@"ExtensionGlobalPage"];
    NSArray *popovers = extension.chrome[@"Popovers"];
    for (NSDictionary *description in [popovers isKindOfClass:[NSArray class]] ? popovers : @[ ]) {
        if (![description isKindOfClass:[NSDictionary class]] || ![description[@"Identifier"] isKindOfClass:[NSString class]] || ![description[@"Filename"] isKindOfClass:[NSString class]])
            continue;
        NSNumber *width = [description[@"Width"] isKindOfClass:[NSNumber class]] ? description[@"Width"] : nil;
        NSNumber *height = [description[@"Height"] isKindOfClass:[NSNumber class]] ? description[@"Height"] : nil;
        [self createPopover:description[@"Identifier"] url:[extension.root stringByAppendingString:description[@"Filename"]] width:width height:height ofExtension:extension];
    }
}

- (void)createPopover:(NSString *)identifier url:(NSString *)url width:(NSNumber *)width height:(NSNumber *)height ofExtension:(WCExtension *)extension
{
    [self removePopover:identifier ofExtension:extension];
    WCExtensionPopover *popover = [[WCExtensionPopover alloc] init];
    popover.identifier = identifier;
    popover.url = url;
    popover.width = width;
    popover.height = height;
    popover.view = [self loadPage:url ofExtension:extension preferencesIdentifier:@"ExtensionPopover"];
    [extension.popovers addObject:popover];
}

- (void)removePopover:(NSString *)identifier ofExtension:(WCExtension *)extension
{
    for (WCExtensionPopover *popover in [extension.popovers copy]) {
        if (![popover.identifier isEqualToString:identifier])
            continue;
        [_receivers removeObjectForKey:popover.view];
        [popover.view close];
        [extension.popovers removeObject:popover];
    }
}

- (WCExtension *)extensionOfView:(WebView *)view
{
    for (WCExtension *extension in _extensions) {
        if (extension.globalPage == view)
            return extension;
        for (WCExtensionPopover *popover in extension.popovers) {
            if (popover.view == view)
                return extension;
        }
    }
    return nil;
}

- (NSString *)popoverOfView:(WebView *)view extension:(WCExtension *)extension
{
    for (WCExtensionPopover *popover in extension.popovers) {
        if (popover.view == view)
            return popover.identifier;
    }
    return nil;
}

static JSValue *windowOfView(WebView *view, JSContext *context)
{
    JSGlobalContextRef viewContext = view.mainFrame.globalContext;
    if (!view || !viewContext)
        return [JSValue valueWithNullInContext:context];
    return [JSValue valueWithJSValueRef:JSContextGetGlobalObject(viewContext) inContext:context];
}

// Safari 7's API in an extension page: Safari gives it once WebKit has given the page its window.
- (void)webView:(WebView *)webView didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame
{
    if (frame != webView.mainFrame)
        return;
    WCExtension *extension = [self extensionOfView:webView];
    if (!extension || !_pageScript)
        return;
    JSContext *context = [JSContext contextWithJSGlobalContextRef:frame.globalContext];
    JSValue *factory = [context evaluateScript:_pageScript withSourceURL:[NSURL URLWithString:@"webclip://WCSafariExtensionPage.js"]];
    NSString *popover = [self popoverOfView:webView extension:extension];
    NSMutableDictionary *options = [@{
        @"baseURI": extension.root,
        @"bundleVersion": [extension.info[@"CFBundleVersion"] isKindOfClass:[NSString class]] ? extension.info[@"CFBundleVersion"] : @"",
        @"displayVersion": [extension.info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? extension.info[@"CFBundleShortVersionString"] : @"",
        @"hasGlobalPage": @(extension.globalPageURL != nil),
        @"isGlobalPage": @(webView == extension.globalPage),
    } mutableCopy];
    if (popover)
        options[@"popover"] = popover;
    JSValue *receiver = [factory callWithArguments:@[ [self nativeOfExtension:extension context:context], options ]];
    if (receiver.isObject)
        [_receivers setObject:receiver forKey:webView];
}

- (NSDictionary *)nativeOfExtension:(WCExtension *)extension context:(JSContext *)context
{
    __weak WCExtensionRuntime *weakSelf = self;
    return @{
        @"setting": ^id(NSString *name) {
            return [weakSelf settingOfExtension:extension name:name];
        },
        @"setSetting": ^BOOL(NSString *name, NSString *json) {
            if (![name isKindOfClass:[NSString class]] || ![json isKindOfClass:[NSString class]])
                return NO;
            return [weakSelf setSetting:name json:json ofExtension:extension];
        },
        @"removeSetting": ^BOOL(NSString *name) {
            if (![name isKindOfClass:[NSString class]])
                return NO;
            return [weakSelf setSetting:name json:nil ofExtension:extension];
        },
        @"settingNames": ^NSArray *(void) {
            return [weakSelf settingNamesOfExtension:extension];
        },
        @"addContent": ^id(NSString *kind, NSString *source, NSString *url, NSArray *whitelist, NSArray *blacklist, BOOL runAtEnd) {
            return [weakSelf addContentOfExtension:extension kind:kind source:source url:url whitelist:whitelist blacklist:blacklist runAtEnd:runAtEnd];
        },
        @"removeContent": ^(NSString *kind, NSString *url) {
            [weakSelf removeContentOfExtension:extension kind:kind url:url];
        },
        @"popovers": ^NSArray *(void) {
            NSMutableArray *descriptions = [NSMutableArray array];
            for (WCExtensionPopover *popover in extension.popovers) {
                NSMutableDictionary *description = [@{ @"identifier": popover.identifier, @"url": popover.url } mutableCopy];
                if (popover.width)
                    description[@"width"] = popover.width;
                if (popover.height)
                    description[@"height"] = popover.height;
                [descriptions addObject:description];
            }
            return descriptions;
        },
        @"createPopover": ^(NSString *identifier, NSString *url, JSValue *width, JSValue *height) {
            [weakSelf createPopover:identifier url:url width:width.isNumber ? width.toNumber : nil height:height.isNumber ? height.toNumber : nil ofExtension:extension];
        },
        @"removePopover": ^(NSString *identifier) {
            [weakSelf removePopover:identifier ofExtension:extension];
        },
        @"popoverWindow": ^JSValue *(NSString *identifier) {
            for (WCExtensionPopover *popover in extension.popovers) {
                if ([popover.identifier isEqualToString:identifier])
                    return windowOfView(popover.view, [JSContext currentContext]);
            }
            return [JSValue valueWithNullInContext:[JSContext currentContext]];
        },
        @"globalPageWindow": ^JSValue *(void) {
            return windowOfView(extension.globalPage, [JSContext currentContext]);
        },
        @"tabs": ^NSArray *(void) {
            return [weakSelf tabTokens];
        },
        @"tabURL": ^id(NSString *page) {
            return [weakSelf webViewOfPage:page].URL.absoluteString;
        },
        @"setTabURL": ^(NSString *page, NSString *url) {
            NSURL *nsURL = [NSURL URLWithString:url];
            if (nsURL)
                [[weakSelf webViewOfPage:page] loadRequest:[NSURLRequest requestWithURL:nsURL]];
        },
        @"tabTitle": ^id(NSString *page) {
            return [weakSelf webViewOfPage:page].title;
        },
        @"dispatchMessageToTab": ^(NSString *page, NSString *name, JSValue *message) {
            JSContext *context = [JSContext currentContext];
            JSValueRef exception = NULL;
            WKSerializedScriptValueRef serialized = WKSerializedScriptValueCreate(context.JSGlobalContextRef, message.JSValueRef, &exception);
            if (!serialized) {
                context.exception = exception ? [JSValue valueWithJSValueRef:exception inContext:context] : nil;
                return;
            }
            [weakSelf dispatchMessage:name message:serialized ofExtension:extension toPage:page];
            WKRelease(serialized);
        },
        @"visibleContentsOfTab": ^(NSString *page, JSValue *callback) {
            WKWebView *webView = [weakSelf webViewOfPage:page];
            if (!webView) {
                [callback callWithArguments:@[ [NSNull null] ]];
                return;
            }
            [webView takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *) {
                NSBitmapImageRep *bitmap = image ? [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation] : nil;
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{ }];
                [callback callWithArguments:@[ png ? [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]] : [NSNull null] ]];
            }];
        },
    };
}

#pragma mark The clip's pages

- (void)addWebView:(WKWebView *)webView
{
    if ([self tokenOfWebView:webView])
        return;
    [_tabs setObject:webView forKey:[NSString stringWithFormat:@"%lu", (unsigned long)++_tabCount]];
    [self updateContentOfController:webView.configuration.userContentController];
}

// The tokens of the clip's live web views, the newest, the one the clip shows, last.
- (NSArray<NSString *> *)tabTokens
{
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in _tabs.keyEnumerator.allObjects) {
        if ([_tabs objectForKey:token])
            [tokens addObject:token];
    }
    [tokens sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(a.integerValue) compare:@(b.integerValue)];
    }];
    return tokens;
}

- (NSString *)tokenOfWebView:(WKWebView *)webView
{
    for (NSString *token in _tabs.keyEnumerator.allObjects) {
        if ([_tabs objectForKey:token] == webView)
            return token;
    }
    return nil;
}

- (NSString *)tokenOfPage:(WKPageRef)page
{
    for (NSString *token in _tabs.keyEnumerator.allObjects) {
        if (page && [[_tabs objectForKey:token] _pageRefForTransitionToWKWebView] == page)
            return token;
    }
    return nil;
}

- (WKWebView *)webViewOfPage:(NSString *)page
{
    return [page isKindOfClass:[NSString class]] ? [_tabs objectForKey:page] : nil;
}

// A navigation of a clip's page, as Safari's tab events: beforeNavigate, which a listener may cancel, before
// it starts, and navigate once its page has loaded. Returns whether the navigation goes ahead.
- (BOOL)webView:(WKWebView *)webView navigates:(NSString *)type toURL:(NSURL *)url
{
    NSString *token = [self tokenOfWebView:webView];
    if (!token)
        return YES;
    BOOL proceeds = YES;
    for (WCExtension *extension in [_extensions copy]) {
        for (JSValue *receiver in [self receiversOfExtension:extension]) {
            if ([[receiver invokeMethod:@"navigation" withArguments:@[ token, type, url.absoluteString ?: [NSNull null] ]] toBool])
                proceeds = NO;
        }
    }
    return proceeds;
}

- (BOOL)webView:(WKWebView *)webView shouldNavigateToURL:(NSURL *)url
{
    return [self webView:webView navigates:@"beforeNavigate" toURL:url];
}

- (void)webViewDidNavigate:(WKWebView *)webView
{
    [self webView:webView navigates:@"navigate" toURL:webView.URL];
}

- (void)dispatchMessage:(NSString *)name message:(WKSerializedScriptValueRef)message ofExtension:(WCExtension *)extension toPage:(NSString *)page
{
    WKWebView *webView = [self webViewOfPage:page];
    if (!webView || ![name isKindOfClass:[NSString class]])
        return;
    WKStringRef messageName = createWKString(messageToContent);
    WKMutableDictionaryRef body = createMessageBody(@{ @"root": extension.root, @"name": name }, message);
    WKPagePostMessageToInjectedBundle([webView _pageRefForTransitionToWKWebView], messageName, body);
    WKRelease(messageName);
    WKRelease(body);
}

// The extension's pages that receive a content script's messages: its global page, then its popovers.
- (NSArray<JSValue *> *)receiversOfExtension:(WCExtension *)extension
{
    NSMutableArray *receivers = [NSMutableArray array];
    NSMutableArray *views = [NSMutableArray array];
    if (extension.globalPage)
        [views addObject:extension.globalPage];
    for (WCExtensionPopover *popover in extension.popovers)
        [views addObject:popover.view];
    for (WebView *view in views) {
        JSValue *receiver = [_receivers objectForKey:view];
        if (receiver)
            [receivers addObject:receiver];
    }
    return receivers;
}

- (void)didReceiveMessage:(NSDictionary *)description message:(WKSerializedScriptValueRef)message fromPage:(WKPageRef)page
{
    WCExtension *extension = [self extensionWithRoot:description[@"root"]];
    NSString *token = [self tokenOfPage:page];
    if (!extension || !message || !token || ![description[@"name"] isKindOfClass:[NSString class]])
        return;
    for (JSValue *receiver in [self receiversOfExtension:extension])
        [receiver invokeMethod:@"message" withArguments:@[ token, description[@"name"], deserialize(message, receiver.context) ]];
}

// canLoad waits in the content script while its message event goes, as Safari dispatches one event, through
// the extension's pages: each sees the message the one before left on the event, until one stops its
// propagation. The answer is the message the event ends with.
- (WKSerializedScriptValueRef)copyAnswerToCanLoadMessage:(NSDictionary *)description message:(WKSerializedScriptValueRef)message fromPage:(WKPageRef)page
{
    if (!message)
        return NULL;
    WKRetain(message);
    WCExtension *extension = [self extensionWithRoot:description[@"root"]];
    NSString *token = [self tokenOfPage:page];
    if (!extension || !token || ![description[@"name"] isKindOfClass:[NSString class]])
        return message;
    for (JSValue *receiver in [self receiversOfExtension:extension]) {
        JSValue *result = [receiver invokeMethod:@"message" withArguments:@[ token, description[@"name"], deserialize(message, receiver.context) ]];
        JSValue *eventMessage = result[0];
        WKSerializedScriptValueRef nextMessage = eventMessage ? WKSerializedScriptValueCreate(receiver.context.JSGlobalContextRef, eventMessage.JSValueRef, NULL) : NULL;
        if (nextMessage) {
            WKRelease(message);
            message = nextMessage;
        }
        if ([result[1] toBool])
            break;
    }
    return message;
}

@end
