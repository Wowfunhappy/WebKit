#import "WebClipper.h"

#import "WCClipperView.h"
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
    return _webClipperView;
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

- (void)loadWelcome
{
    NSString *welcomePath = [[NSBundle bundleForClass:[self class]] pathForResource:@"welcome" ofType:@"html"];
    NSString *URLString = [[NSURL fileURLWithPath:welcomePath] _web_originalDataAsString];
    NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
        URLString, @"URL",
        NSStringFromSize(NSMakeSize(366, 254)), @"PageSize",
        NSStringFromRect(NSMakeRect(0, 0, 366, 254)), @"ClipRect",
        [NSNumber numberWithInt:0], @"Theme",
        nil];
    [self loadFromSettings:settings displayLoadingText:NO resizeWidget:NO];
}

- (void)notifyTransitionIsComplete
{
    [_webClipperView notifyTransitionIsComplete];
}

- (void)fadeButtonWithOpacity:(float)opacity
{
    [_webClipperView fadeButtonWithOpacity:opacity];
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector
{
    return !(selector == @selector(cookiesAsString)
        || selector == @selector(clipRectString)
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
        || selector == @selector(playAudioOutOfDashboard)
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
    [_webClipperView prepareWidgetForSnapshot];
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
    id pageSize = [self _dashboardPreferenceForKey:@"PageSize"];
    if (![pageSize isKindOfClass:[NSString class]])
        return NO;
    [settings setObject:pageSize forKey:@"PageSize"];
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

// Safari passes the clip's settings as a property list serialized into the Parameters string.
- (BOOL)readSettingsFromSafari:(id)startupRequest
{
    NSString *errorDescription = nil;
    NSData *parameters = [[startupRequest valueForKey:@"Parameters"] propertyList];
    NSMutableDictionary *settings = [NSPropertyListSerialization propertyListFromData:parameters mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&errorDescription];
    if (errorDescription) {
        NSLog(@"%@", errorDescription);
        [self loadWelcome];
        return NO;
    }

    NSString *clipRectString = [settings _web_stringForKey:@"ClipRect"];
    if (!clipRectString)
        return NO;
    NSRect clipRect = NSRectFromString(clipRectString);
    Class themeClass = [WebClipper defaultThemeClass];
    clipRect.size.height += [themeClass borderTop] + [themeClass borderBottom];
    clipRect.size.width += [themeClass borderLeft] + [themeClass borderRight];
    [settings setObject:NSStringFromRect(clipRect) forKey:@"ClipRect"];
    [self loadFromSettings:settings displayLoadingText:YES resizeWidget:YES];
    return YES;
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
        [self loadWelcome];
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

