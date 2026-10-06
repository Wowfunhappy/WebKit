#import "WebClipper.h"

#import "WCClipperView.h"
#import "WCSafariExtensions.h"
#import "WCThemes.h"
#import <WebKit/WebKit.h>

@interface NSDictionary (WCWebKitExtras)
- (NSString *)_web_stringForKey:(id)key;
- (NSNumber *)_web_numberForKey:(id)key;
@end

@interface NSURL (WCWebKitExtras)
+ (NSURL *)_web_URLWithUserTypedString:(NSString *)string;
- (NSData *)_web_originalData;
- (NSString *)_web_originalDataAsString;
@end

@interface WebPreferences (WCWebKitExtras)
- (void)_setUseSiteSpecificSpoofing:(BOOL)flag;
@end

@implementation WebClipper {
    NSRect _clipRect;
    NSArray *_cookies;
    NSString *_URLString;
    NSSize _pageSize;
    NSSize _viewportSize;
    NSSize _visibleContentSize;
    NSPoint _pageScroll;
    NSArray<NSNumber *> *_safariBoxScrolls;
    float _textSizeMultiplier;
    BOOL _playAudioOutOfDashboard;
    BOOL _hasSettings;
    NSDictionary *_clipSignature;
    WCClipperView *_webClipperView;
    WebView *_dashboardWebView;
    WebPreferences *_webPreferences;
    NSString *_customTextEncodingName;
}

@synthesize clipRect = _clipRect;
@synthesize pageSize = _pageSize;
@synthesize viewportSize = _viewportSize;
@synthesize visibleContentSize = _visibleContentSize;
@synthesize pageScroll = _pageScroll;
@synthesize safariBoxScrolls = _safariBoxScrolls;
@synthesize clipSignature = _clipSignature;

+ (NSString *)bundleIdentifier
{
    return [[NSBundle bundleForClass:[WebClipper class]] bundleIdentifier];
}

+ (Class)defaultThemeClass
{
    return [WCGlassTheme class];
}

+ (float)backsideWidth
{
    return 366;
}

+ (float)backsideHeight
{
    return 254;
}

+ (NSString *)webClipVersion
{
    static NSString *version;
    if (!version)
        version = [[[NSBundle bundleWithIdentifier:[WebClipper bundleIdentifier]] infoDictionary] objectForKey:@"CFBundleVersion"];
    return version;
}

+ (NSString *)safariVersion
{
    static NSString *version;
    if (!version) {
        version = [[[NSBundle bundleWithPath:@"/Applications/Safari.app"] infoDictionary] objectForKey:@"CFBundleVersion"];
        if (!version)
            version = [self webClipVersion];
    }
    return version;
}

+ (NSString *)userAgent
{
    return [NSString stringWithFormat:@"%@/%@ %@/%@", @"WebClip", [WebClipper webClipVersion], @"Safari", [WebClipper safariVersion]];
}

+ (NSView *)plugInViewWithArguments:(NSDictionary *)arguments
{
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"WebIconDatabaseEnabled"];
    WebView *dashboardWebView = [[[arguments objectForKey:WebPlugInContainerKey] webFrame] webView];

    WebClipper *clipper = [[WebClipper alloc] init];
    [clipper setDashboardWebView:dashboardWebView];
    [[dashboardWebView windowScriptObject] setValue:clipper forKey:@"webClip"];
    [clipper setWebClipperView:[[WCClipperView alloc] initWithFrame:NSMakeRect(0, 0, 366, 254) dashboardWebView:dashboardWebView]];
    return [clipper view];
}

- (NSView *)view
{
    return [_webClipperView placeholderView];
}

- (WebView *)dashboardWebView
{
    return _dashboardWebView;
}

- (void)setDashboardWebView:(WebView *)webView
{
    _dashboardWebView = webView;
}

- (WCClipperView *)webClipperView
{
    return _webClipperView;
}

- (void)setWebClipperView:(WCClipperView *)view
{
    _webClipperView = view;
}

- (void)setTransitionInProgress
{
    [_webClipperView setTransitionInProgress];
}

- (BOOL)playAudioOutOfDashboard
{
    return _playAudioOutOfDashboard;
}

- (void)setPlayAudioOutOfDashboard:(BOOL)play
{
    _playAudioOutOfDashboard = play;
}

- (BOOL)hasSettings
{
    return _hasSettings;
}

- (WebPreferences *)webPreferences
{
    if (!_webPreferences)
        [self setWebPreferences:[[WebPreferences alloc] init]];
    return _webPreferences;
}

- (void)setWebPreferences:(WebPreferences *)preferences
{
    _webPreferences = preferences;
}

- (void)savePreferencesToDisk
{
    [[self windowScriptObject] callWebScriptMethod:@"savePreferences" withArguments:[NSArray array]];
}

- (void)loadURLString:(NSString *)URLString pageSize:(NSSize)pageSize clipRect:(NSRect)clipRect clipSignature:(NSDictionary *)clipSignature cookieProperties:(NSArray *)cookieProperties displayLoadingText:(BOOL)displayLoadingText resizeWidget:(BOOL)resizeWidget
{
    [self setClipRect:clipRect];
    [self setPageSize:pageSize];
    [self setURLString:URLString];
    if (cookieProperties)
        [self setCookies:[self cookiesFromCookiesProperties:cookieProperties]];
    [_webClipperView loadURLString:URLString clipRect:clipRect clipSignature:clipSignature pageSize:pageSize displayLoadingText:displayLoadingText resizeWidget:resizeWidget];
    [self savePreferencesToDisk];
}

- (NSString *)fixedWidthFont
{
    return [[self webPreferences] fixedFontFamily];
}

- (int)fixedWidthFontSize
{
    return [[self webPreferences] defaultFixedFontSize];
}

- (int)minimumFontSize
{
    return [[self webPreferences] minimumFontSize];
}

- (NSString *)standardFont
{
    return [[self webPreferences] standardFontFamily];
}

- (int)standardFontSize
{
    return [[self webPreferences] defaultFontSize];
}

- (NSString *)userStyleSheetPath
{
    return [[[self webPreferences] userStyleSheetLocation] path];
}

- (void)setFixedWidthFont:(NSString *)font
{
    if (font)
        [[self webPreferences] setFixedFontFamily:font];
}

- (void)setFixedWidthFontSize:(NSNumber *)size
{
    int value = [size intValue];
    if (value)
        [[self webPreferences] setDefaultFixedFontSize:value];
}

- (void)setMinimumFontSize:(NSNumber *)size
{
    int value = [size intValue];
    if (value)
        [[self webPreferences] setMinimumFontSize:value];
}

- (void)setStandardFont:(NSString *)font
{
    if (font)
        [[self webPreferences] setStandardFontFamily:font];
}

- (void)setTextSizeMultiplier:(NSNumber *)multiplier
{
    _textSizeMultiplier = multiplier ? [multiplier floatValue] : 1;
}

- (void)setCustomTextEncodingName:(NSString *)name
{
    if (name)
        _customTextEncodingName = [name copy];
}

- (void)setDefaultTextEncodingName:(NSString *)name
{
    if (name)
        [[self webPreferences] setDefaultTextEncodingName:name];
}

- (NSString *)customTextEncodingName
{
    return _customTextEncodingName;
}

- (NSString *)defaultTextEncodingName
{
    return [[self webPreferences] defaultTextEncodingName];
}

- (float)textSizeMultiplier
{
    return _textSizeMultiplier;
}

- (void)setStandardFontSize:(NSNumber *)size
{
    int value = [size intValue];
    if (value)
        [[self webPreferences] setDefaultFontSize:value];
}

- (void)setUserStyleSheetPath:(NSString *)path
{
    WebPreferences *preferences = [self webPreferences];
    if (path)
        [preferences setUserStyleSheetLocation:[NSURL URLWithString:path]];
    [preferences setUserStyleSheetEnabled:path != nil];
}

- (void)loadFromSettings:(NSDictionary *)settings displayLoadingText:(BOOL)displayLoadingText resizeWidget:(BOOL)resizeWidget
{
    WebPreferences *preferences = [self webPreferences];
    [preferences setJavaEnabled:YES];
    [preferences _setUseSiteSpecificSpoofing:YES];

    NSString *URLString = [settings _web_stringForKey:@"URL"];
    if (!URLString)
        return;

    [self setCustomTextEncodingName:[settings _web_stringForKey:@"CustomTextEncoding"]];
    [self setDefaultTextEncodingName:[settings _web_stringForKey:@"DefaultTextEncoding"]];
    [self setFixedWidthFont:[settings _web_stringForKey:@"FixedWidthFont"]];
    [self setFixedWidthFontSize:[settings _web_numberForKey:@"FixedWidthFontSize"]];
    [self setMinimumFontSize:[settings _web_numberForKey:@"MinimumFontSize"]];
    [self setStandardFont:[settings _web_stringForKey:@"StandardFont"]];
    [self setTextSizeMultiplier:[settings _web_numberForKey:@"TextSizeMultiplier"]];
    [self setStandardFontSize:[settings _web_numberForKey:@"StandardFontSize"]];
    [self setUserStyleSheetPath:[settings _web_stringForKey:@"UserStyleSheetPath"]];

    NSSize pageSize = NSMakeSize(800, 540);
    NSString *pageSizeString = [settings _web_stringForKey:@"PageSize"];
    if (pageSizeString) {
        pageSize = NSSizeFromString(pageSizeString);
        if (pageSize.width == 0)
            pageSize.width = 800;
        if (pageSize.height == 0)
            pageSize.height = 540;
    }

    NSRect clipRect = NSMakeRect(0, 0, 366, 254);
    NSString *clipRectString = [settings _web_stringForKey:@"ClipRect"];
    if (clipRectString)
        clipRect = NSRectFromString(clipRectString);

    [self setViewportSize:NSSizeFromString([settings _web_stringForKey:@"ViewportSize"])];
    [self setVisibleContentSize:NSSizeFromString([settings _web_stringForKey:@"VisibleContentSize"])];
    [self setPageScroll:NSPointFromString([settings _web_stringForKey:@"PageScroll"])];
    id safariBoxScrolls = [settings objectForKey:@"SafariBoxScrolls"];
    [self setSafariBoxScrolls:[safariBoxScrolls isKindOfClass:[NSArray class]] ? safariBoxScrolls : nil];

    id signature = [settings objectForKey:@"ClipSignature"];
    NSDictionary *clipSignature = [signature isKindOfClass:[NSDictionary class]] ? signature : nil;

    [self setPlayAudioOutOfDashboard:[[settings _web_numberForKey:@"PlayAudioOutOfDashboard"] boolValue]];
    NSArray *cookieProperties = [settings objectForKey:@"CookieProperties"];
    [_webClipperView setTheme:[[settings _web_numberForKey:@"Theme"] intValue]];

    [self loadURLString:URLString pageSize:pageSize clipRect:clipRect clipSignature:clipSignature cookieProperties:cookieProperties displayLoadingText:displayLoadingText resizeWidget:resizeWidget];
}

- (void)switchToThemeAtIndex:(NSNumber *)index
{
    [_webClipperView switchToThemeAtIndex:[index intValue]];
}

- (void)editCameraPosition
{
    [_webClipperView editCameraPosition];
}

// The welcome page shows at its own size, to which a clip that was waiting for Safari resizes the widget.
- (void)loadWelcomeResizingWidget:(BOOL)resizeWidget
{
    NSString *welcomePath = [[NSBundle bundleForClass:[self class]] pathForResource:@"welcome" ofType:@"html"];
    NSString *URLString = [[NSURL fileURLWithPath:welcomePath] _web_originalDataAsString];
    NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
        URLString, @"URL",
        NSStringFromSize(NSMakeSize(366, 254)), @"PageSize",
        NSStringFromRect(NSMakeRect(0, 0, 366, 254)), @"ClipRect",
        NSStringFromSize(NSMakeSize(366, 254)), @"ViewportSize",
        NSStringFromSize(NSMakeSize(366, 254)), @"VisibleContentSize",
        NSStringFromPoint(NSZeroPoint), @"PageScroll",
        [NSNumber numberWithInt:0], @"Theme",
        nil];
    [self loadFromSettings:settings displayLoadingText:NO resizeWidget:resizeWidget];
}

- (void)notifyTransitionIsComplete
{
    [_webClipperView notifyTransitionIsComplete];
}

// The Dock animates a flip, and afterwards reports it complete, only when the window server can make
// the transition: every active display OpenGL-accelerated and at least 32 bits deep.
- (BOOL)dashboardAnimatesFlips
{
    CGDirectDisplayID displays[32];
    uint32_t count = 0;
    CGGetActiveDisplayList(32, displays, &count);
    for (uint32_t i = 0; i < count; ++i) {
        if (!CGDisplayUsesOpenGLAcceleration(displays[i]))
            return NO;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displays[i]);
        CFStringRef encoding = CGDisplayModeCopyPixelEncoding(mode);
        CGDisplayModeRelease(mode);
        CFIndex depth = CFStringGetLength(encoding);
        CFRelease(encoding);
        if (depth < 32)
            return NO;
    }
    return YES;
}

- (void)fadeButtonWithOpacity:(float)opacity
{
    [_webClipperView fadeButtonWithOpacity:opacity];
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector
{
    return !(selector == @selector(cookiesAsString)
        || selector == @selector(clipRectString)
        || selector == @selector(dashboardAnimatesFlips)
        || selector == @selector(customTextEncodingName)
        || selector == @selector(defaultTextEncodingName)
        || selector == @selector(didFlipWidget:)
        || selector == @selector(didHideWidget)
        || selector == @selector(didShowWidget)
        || selector == @selector(editCameraPosition)
        || selector == @selector(fadeButtonWithOpacity:)
        || selector == @selector(fixedWidthFont)
        || selector == @selector(fixedWidthFontSize)
        || selector == @selector(minimumFontSize)
        || selector == @selector(notifyTransitionIsComplete)
        || selector == @selector(pageSizeString)
        || selector == @selector(viewportSizeString)
        || selector == @selector(visibleContentSizeString)
        || selector == @selector(pageScrollString)
        || selector == @selector(playAudioOutOfDashboard)
        || selector == @selector(removeClipData)
        || selector == @selector(setPlayAudioOutOfDashboard:)
        || selector == @selector(setTransitionInProgress)
        || selector == @selector(signatureAsString)
        || selector == @selector(standardFont)
        || selector == @selector(standardFontSize)
        || selector == @selector(switchToThemeAtIndex:)
        || selector == @selector(textSizeMultiplier)
        || selector == @selector(themeID)
        || selector == @selector(URLString)
        || selector == @selector(userStyleSheetPath));
}

+ (BOOL)isKeyExcludedFromWebScript:(const char *)name
{
    return YES;
}

+ (NSString *)webScriptNameForSelector:(SEL)selector
{
    NSString *name = NSStringFromSelector(selector);
    NSUInteger colon = [name rangeOfString:@":"].location;
    if (colon && colon == [name length] - 1)
        return [name substringToIndex:colon];
    return name;
}

- (WebScriptObject *)windowScriptObject
{
    return [_dashboardWebView windowScriptObject];
}

- (void)setThumbnailAndFlipToBack:(NSImage *)thumbnail
{
    NSString *thumbnailData = [[thumbnail TIFFRepresentation] base64EncodedStringWithOptions:0];
    NSImage *tornEdge = [NSImage wc_PNGNamed:@"tornedge"];
    NSImage *tornEdgeThumbnail = [thumbnail copy];
    [tornEdgeThumbnail lockFocus];
    [tornEdge drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeDestinationIn fraction:1];
    [tornEdgeThumbnail unlockFocus];
    [[self windowScriptObject] callWebScriptMethod:@"setThumbnailAndFlipToBack" withArguments:[NSArray arrayWithObjects:thumbnailData, [[tornEdgeThumbnail TIFFRepresentation] base64EncodedStringWithOptions:0], nil]];
}

- (void)didShowWidget
{
    [_webClipperView didShowWidget];
}

- (void)didHideWidget
{
    [self savePreferencesToDisk];
    [_webClipperView didHideWidget];
}

- (void)didFlipWidget:(BOOL)toFront
{
    [_webClipperView didFlipWidget:toFront];
}

- (NSArray *)cookiePropertiesFromCookies:(NSArray *)cookies
{
    NSMutableArray *properties = [NSMutableArray arrayWithCapacity:[cookies count]];
    for (NSHTTPCookie *cookie in cookies)
        [properties addObject:[cookie properties]];
    return properties;
}

- (void)setCookies:(NSArray *)cookies
{
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in _cookies)
        [storage deleteCookie:cookie];
    for (NSHTTPCookie *cookie in cookies)
        [storage setCookie:cookie];
    _cookies = cookies;
}

- (NSArray *)cookies
{
    return _cookies;
}

- (NSArray *)cookiesFromCookiesProperties:(NSArray *)properties
{
    NSMutableArray *cookies = [NSMutableArray arrayWithCapacity:[properties count]];
    for (NSDictionary *cookieProperties in properties) {
        NSHTTPCookie *cookie = [[NSHTTPCookie alloc] initWithProperties:cookieProperties];
        if (cookie)
            [cookies addObject:cookie];
    }
    return cookies;
}

static NSString *xmlPropertyListString(id propertyList)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:propertyList format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (NSString *)cookiesAsString
{
    return xmlPropertyListString([self cookiePropertiesFromCookies:_cookies]);
}

- (NSString *)signatureAsString
{
    return _clipSignature ? xmlPropertyListString(_clipSignature) : nil;
}

- (void)setURLString:(NSString *)URLString
{
    _URLString = URLString;
}

- (NSString *)URLString
{
    return _URLString;
}

- (NSString *)clipRectString
{
    return NSStringFromRect(_clipRect);
}

- (NSString *)pageSizeString
{
    return NSStringFromSize([self pageSize]);
}

- (NSString *)viewportSizeString
{
    return NSStringFromSize([self viewportSize]);
}

- (NSString *)visibleContentSizeString
{
    return NSStringFromSize([self visibleContentSize]);
}

- (NSString *)pageScrollString
{
    return NSStringFromPoint([self pageScroll]);
}

- (void)exitEditingCameraPosition
{
    [[self windowScriptObject] callWebScriptMethod:@"exitPanAndCrop" withArguments:nil];
}

- (int)themeID
{
    return [_webClipperView currentThemeID];
}

- (id)_dashboardPreferenceForKey:(NSString *)key
{
    NSArray *arguments = [[NSArray alloc] initWithObjects:key, nil];
    return [[self windowScriptObject] callWebScriptMethod:@"preferenceForKey" withArguments:arguments];
}

static id propertyListFromXMLString(NSString *string)
{
    return [NSPropertyListSerialization propertyListWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:NSPropertyListImmutable format:NULL error:nil];
}

- (BOOL)readSettingsFromDashboard
{
    if ([[self _dashboardPreferenceForKey:@"URL"] isKindOfClass:[WebUndefined class]])
        return NO;

    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"ClipRect", @"DefaultTextEncoding", @"FixedWidthFont" ]) {
        id value = [self _dashboardPreferenceForKey:key];
        if (![value isKindOfClass:[NSString class]])
            return NO;
        [settings setObject:value forKey:key];
    }
    for (NSString *key in @[ @"FixedWidthFontSize", @"MinimumFontSize" ]) {
        id value = [self _dashboardPreferenceForKey:key];
        if (![value isKindOfClass:[NSNumber class]])
            return NO;
        [settings setObject:value forKey:key];
    }
    for (NSString *key in @[ @"PageSize", @"ViewportSize", @"VisibleContentSize", @"PageScroll" ]) {
        id value = [self _dashboardPreferenceForKey:key];
        if (![value isKindOfClass:[NSString class]])
            return NO;
        [settings setObject:value forKey:key];
    }
    id playAudio = [self _dashboardPreferenceForKey:@"PlayAudioOutOfDashboard"];
    if (![playAudio isKindOfClass:[NSNumber class]])
        return NO;
    [settings setObject:playAudio forKey:@"PlayAudioOutOfDashboard"];
    id standardFont = [self _dashboardPreferenceForKey:@"StandardFont"];
    if (![standardFont isKindOfClass:[NSString class]])
        return NO;
    [settings setObject:standardFont forKey:@"StandardFont"];
    for (NSString *key in @[ @"StandardFontSize", @"TextSizeMultiplier", @"Theme" ]) {
        id value = [self _dashboardPreferenceForKey:key];
        if (![value isKindOfClass:[NSNumber class]])
            return NO;
        [settings setObject:value forKey:key];
    }
    id URL = [self _dashboardPreferenceForKey:@"URL"];
    if (![URL isKindOfClass:[NSString class]])
        return NO;
    [settings setObject:URL forKey:@"URL"];

    id customTextEncoding = [self _dashboardPreferenceForKey:@"CustomTextEncoding"];
    if ([customTextEncoding isKindOfClass:[NSString class]])
        [settings setObject:customTextEncoding forKey:@"CustomTextEncoding"];
    id userStyleSheetPath = [self _dashboardPreferenceForKey:@"UserStyleSheetPath"];
    if ([userStyleSheetPath isKindOfClass:[NSString class]])
        [settings setObject:userStyleSheetPath forKey:@"UserStyleSheetPath"];
    id cookieProperties = [self _dashboardPreferenceForKey:@"CookieProperties"];
    if ([cookieProperties isKindOfClass:[NSString class]]) {
        id list = propertyListFromXMLString(cookieProperties);
        if (list)
            [settings setObject:list forKey:@"CookieProperties"];
    }
    id clipSignature = [self _dashboardPreferenceForKey:@"ClipSignature"];
    if ([clipSignature isKindOfClass:[NSString class]]) {
        id signature = propertyListFromXMLString(clipSignature);
        if (signature)
            [settings setObject:signature forKey:@"ClipSignature"];
    }

    [self loadFromSettings:settings displayLoadingText:YES resizeWidget:YES];
    return YES;
}

// Safari places the clip relative to the scroll offset document.body reports, which is zero for a
// standards-mode page, so its rectangles are in the viewport's coordinates there. The tab that made the
// clip still shows the page as it was clipped, and reports its scroll offset and the viewport it was laid
// out in, and how far it has scrolled each box that scrolls vertically under the middle of the selection:
// the boxes holding the topmost element there that lies in any, below whatever overlays the selection.
// Safari runs the script in the page's own world, the only one its scripting reaches; the script is one
// expression that only reads. Safari answers the event once the page runs the script, so the event waits
// off the main thread.
static NSString * const WCSafariPageStateScriptFormat = @"(function (x, y) {"
    "var body = document.body;"
    "var boxScrolls = [];"
    "var stack = document.elementsFromPoint(x + (body ? body.scrollLeft : 0) - scrollX, y + (body ? body.scrollTop : 0) - scrollY);"
    "for (var i = 0; i < stack.length && !boxScrolls.length; ++i) {"
        "for (var element = stack[i].parentElement; element && element !== body && element !== document.documentElement; element = element.parentElement) {"
            "if (element.scrollHeight > element.clientHeight && /^(auto|scroll)$/.test(getComputedStyle(element).overflowY))"
                "boxScrolls.unshift(element.scrollTop);"
        "}"
    "}"
    "return JSON.stringify([scrollX, scrollY, body ? body.scrollLeft : 0, body ? body.scrollTop : 0, innerWidth, innerHeight, document.documentElement.clientWidth, document.documentElement.clientHeight, location.href, boxScrolls]);"
"})(%f, %f)";

static NSAppleEventDescriptor *safariFrontTabSpecifier(void)
{
    NSAppleEventDescriptor *window = [NSAppleEventDescriptor recordDescriptor];
    [window setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'cwin'] forKeyword:keyAEDesiredClass];
    [window setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:formAbsolutePosition] forKeyword:keyAEKeyForm];
    [window setDescriptor:[NSAppleEventDescriptor descriptorWithInt32:1] forKeyword:keyAEKeyData];
    [window setDescriptor:[NSAppleEventDescriptor nullDescriptor] forKeyword:keyAEContainer];
    NSAppleEventDescriptor *tab = [NSAppleEventDescriptor recordDescriptor];
    [tab setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:cProperty] forKeyword:keyAEDesiredClass];
    [tab setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:formPropertyID] forKeyword:keyAEKeyForm];
    [tab setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'cTab'] forKeyword:keyAEKeyData];
    [tab setDescriptor:[window coerceToDescriptorType:typeObjectSpecifier] forKeyword:keyAEContainer];
    return [tab coerceToDescriptorType:typeObjectSpecifier];
}

static void requestPageStateOfSafariTab(NSString *URLString, NSRect clipRect, void (^completionHandler)(NSDictionary *pageState))
{
    NSString *script = [NSString stringWithFormat:WCSafariPageStateScriptFormat, NSMidX(clipRect), NSMidY(clipRect)];
    NSData *safari = [@"com.apple.Safari" dataUsingEncoding:NSUTF8StringEncoding];
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeApplicationBundleID data:safari];
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:'sfri' eventID:'dojs' targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:script] forKeyword:keyDirectObject];
    [event setParamDescriptor:safariFrontTabSpecifier() forKeyword:'dcnm'];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AppleEvent replyEvent;
        OSStatus status = AESendMessage([event aeDesc], &replyEvent, kAEWaitReply | kAENeverInteract, kAEDefaultTimeout);
        NSString *result = nil;
        if (status == noErr) {
            NSAppleEventDescriptor *reply = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&replyEvent];
            result = [[reply paramDescriptorForKeyword:keyDirectObject] stringValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *values = result ? [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
            if (![values isKindOfClass:[NSArray class]] || [values count] != 10 || ![[values objectAtIndex:9] isKindOfClass:[NSArray class]]) {
                NSLog(@"Web Clip: Safari did not report the clipped page (%d)", (int)status);
                completionHandler(nil);
                return;
            }
            NSString *pageURLString = [values objectAtIndex:8];
            if (![[[NSURL URLWithString:pageURLString] absoluteString] isEqualToString:[[NSURL URLWithString:URLString] absoluteString]]) {
                NSLog(@"Web Clip: Safari's tab shows %@, not the clipped %@", pageURLString, URLString);
                completionHandler(nil);
                return;
            }
            double scrollX = [[values objectAtIndex:0] doubleValue];
            double scrollY = [[values objectAtIndex:1] doubleValue];
            completionHandler(@{
                @"Offset": [NSValue valueWithPoint:NSMakePoint(scrollX - [[values objectAtIndex:2] doubleValue], scrollY - [[values objectAtIndex:3] doubleValue])],
                @"ViewportSize": NSStringFromSize(NSMakeSize([[values objectAtIndex:4] doubleValue], [[values objectAtIndex:5] doubleValue])),
                @"VisibleContentSize": NSStringFromSize(NSMakeSize([[values objectAtIndex:6] doubleValue], [[values objectAtIndex:7] doubleValue])),
                @"PageScroll": NSStringFromPoint(NSMakePoint(scrollX, scrollY)),
                @"SafariBoxScrolls": [values objectAtIndex:9],
            });
        });
    });
}

// Safari passes the clip's settings as a property list serialized into the Parameters string.
- (BOOL)readSettingsFromSafari:(id)startupRequest
{
    NSString *errorDescription = nil;
    NSData *parameters = [[startupRequest valueForKey:@"Parameters"] propertyList];
    NSMutableDictionary *settings = [NSPropertyListSerialization propertyListFromData:parameters mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&errorDescription];
    if (errorDescription) {
        NSLog(@"%@", errorDescription);
        [self loadWelcomeResizingWidget:NO];
        return NO;
    }

    NSString *clipRectString = [settings _web_stringForKey:@"ClipRect"];
    if (!clipRectString)
        return NO;
    NSRect clipRect = NSRectFromString(clipRectString);
    Class themeClass = [WebClipper defaultThemeClass];
    clipRect.size.height += [themeClass borderTop] + [themeClass borderBottom];
    clipRect.size.width += [themeClass borderLeft] + [themeClass borderRight];
    [_webClipperView showLoadingClipWithTheme:[[settings _web_numberForKey:@"Theme"] intValue] size:clipRect.size];
    // The clip copies Safari's extensions while Safari reports the page, and loads once it has both.
    dispatch_group_t copyingExtensions = dispatch_group_create();
    NSString *extensionsDirectory = [self safariExtensionsDirectory];
    if (extensionsDirectory) {
        NSString *clipIdentifier = [self clipIdentifier];
        dispatch_group_async(copyingExtensions, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (!WCCopySafariExtensions(extensionsDirectory, clipIdentifier))
                NSLog(@"Web Clip: Safari's extensions could not be copied for the clip");
        });
    }
    requestPageStateOfSafariTab([settings _web_stringForKey:@"URL"], NSRectFromString(clipRectString), ^(NSDictionary *pageState) {
      dispatch_group_notify(copyingExtensions, dispatch_get_main_queue(), ^{
        if (!_webClipperView)
            return;
        if (!pageState) {
            _hasSettings = NO;
            [self loadWelcomeResizingWidget:YES];
            return;
        }
        NSPoint offset = [[pageState objectForKey:@"Offset"] pointValue];
        [settings setObject:[pageState objectForKey:@"ViewportSize"] forKey:@"ViewportSize"];
        [settings setObject:[pageState objectForKey:@"VisibleContentSize"] forKey:@"VisibleContentSize"];
        [settings setObject:[pageState objectForKey:@"PageScroll"] forKey:@"PageScroll"];
        [settings setObject:[pageState objectForKey:@"SafariBoxScrolls"] forKey:@"SafariBoxScrolls"];
        NSMutableDictionary *signature = [settings objectForKey:@"ClipSignature"];
        NSString *originalBorderRect = [signature isKindOfClass:[NSMutableDictionary class]] ? [signature _web_stringForKey:@"ClipSignatureOriginalBorderRect"] : nil;
        if (originalBorderRect)
            [signature setObject:NSStringFromRect(NSOffsetRect(NSRectFromString(originalBorderRect), offset.x, offset.y)) forKey:@"ClipSignatureOriginalBorderRect"];

        [settings setObject:NSStringFromRect(NSOffsetRect(clipRect, offset.x, offset.y)) forKey:@"ClipRect"];
        [self loadFromSettings:settings displayLoadingText:YES resizeWidget:YES];
      });
    });
    return YES;
}

// The widget's identifier for the clip, which names its preferences.
- (NSString *)clipIdentifier
{
    id identifier = [[self windowScriptObject] evaluateWebScript:@"widget.identifier"];
    return [identifier isKindOfClass:[NSString class]] && [identifier length] ? identifier : nil;
}

// The clip's own copy of Safari's extensions (WCSafariExtensions.h), in the clip's folder of the plug-in's
// application support.
- (NSString *)safariExtensionsDirectory
{
    NSString *identifier = [self clipIdentifier];
    if (!identifier)
        return nil;
    return [NSString pathWithComponents:@[ NSHomeDirectory(), @"Library", @"Application Support", [WebClipper bundleIdentifier], identifier, @"Safari Extensions" ]];
}

// The widget removes a clip from Dashboard: its extensions stop, and the clip's folder goes with it, and its
// copy's databases.
- (void)removeClipData
{
    [_webClipperView stopExtensions];
    NSString *extensionsDirectory = [self safariExtensionsDirectory];
    if (!extensionsDirectory)
        return;
    WCRemoveSafariExtensions(extensionsDirectory, [self clipIdentifier]);
    [[NSFileManager defaultManager] removeItemAtPath:[extensionsDirectory stringByDeletingLastPathComponent] error:nil];
}

- (void)readSettings
{
    id startupRequest = [[_webClipperView widgetScriptObject] valueForKey:@"startupRequest"];
    if (startupRequest && ![startupRequest isKindOfClass:NSClassFromString(@"WebUndefined")]) {
        if ([[startupRequest valueForKey:@"Parameters"] isKindOfClass:[NSString class]]) {
            _hasSettings = [self readSettingsFromSafari:startupRequest];
            return;
        }
    }
    _hasSettings = [self readSettingsFromDashboard];
    if (!_hasSettings)
        [self loadWelcomeResizingWidget:NO];
}

- (void)draggableControlRegions:(void (^)(NSArray *rects))completionHandler
{
    [_webClipperView pageDraggableRects:^(NSArray *documentRects) {
        NSMutableArray *regions = [[NSMutableArray alloc] init];
        for (NSValue *rect in documentRects)
            [regions addObject:[NSValue valueWithRect:[_webClipperView convertDOMRectToDashboardControlRegion:[rect rectValue]]]];
        completionHandler(regions);
    }];
}

@end

