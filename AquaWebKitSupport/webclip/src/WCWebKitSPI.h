// WebKit SPI the plug-in uses beyond the SDK's public headers.

#import <JavaScriptCore/JavaScriptCore.h>
#import <WebKit/WebKit.h>

typedef const void *WKTypeRef;
typedef const struct OpaqueWKPage *WKPageRef;
typedef const struct OpaqueWKString *WKStringRef;
typedef const struct OpaqueWKContext *WKContextRef;
extern void WKPageSetCustomTextEncodingName(WKPageRef, WKStringRef);
extern WKStringRef WKStringCreateWithCFString(CFStringRef);
extern CFStringRef WKStringCopyCFString(CFAllocatorRef, WKStringRef);
extern unsigned WKGetTypeID(WKTypeRef);
extern unsigned WKStringGetTypeID(void);
extern WKTypeRef WKRetain(WKTypeRef);
extern void WKRelease(const void *);
extern void WKPagePostMessageToInjectedBundle(WKPageRef, WKStringRef, const void *messageBody);
typedef const struct OpaqueWKDictionary *WKDictionaryRef;
typedef struct OpaqueWKDictionary *WKMutableDictionaryRef;
extern unsigned WKDictionaryGetTypeID(void);
extern unsigned WKPageGetTypeID(void);
extern WKTypeRef WKDictionaryGetItemForKey(WKDictionaryRef, WKStringRef);
extern WKMutableDictionaryRef WKMutableDictionaryCreate(void);
extern bool WKDictionarySetItem(WKMutableDictionaryRef, WKStringRef, WKTypeRef);
typedef const struct OpaqueWKSerializedScriptValue *WKSerializedScriptValueRef;
extern unsigned WKSerializedScriptValueGetTypeID(void);
extern WKSerializedScriptValueRef WKSerializedScriptValueCreate(JSContextRef, JSValueRef, JSValueRef *exception);
extern JSValueRef WKSerializedScriptValueDeserialize(WKSerializedScriptValueRef, JSContextRef, JSValueRef *exception);

// A process pool's C API context is the pool itself.
typedef struct {
    int version;
    const void *clientInfo;
    void (*didReceiveMessageFromInjectedBundle)(WKContextRef, WKStringRef messageName, WKTypeRef messageBody, const void *clientInfo);
    void (*didReceiveSynchronousMessageFromInjectedBundle)(WKContextRef, WKStringRef messageName, WKTypeRef messageBody, WKTypeRef *returnData, const void *clientInfo);
} WKContextInjectedBundleClientV0;
extern void WKContextSetInjectedBundleClient(WKContextRef, const WKContextInjectedBundleClientV0 *);

// The WebKit 1 SPI Safari configures its extension pages' views with.
typedef NS_ENUM(NSUInteger, WebStorageBlockingPolicy) {
    WebAllowAllStorage = 0,
};

@interface WebPreferences (WCWebKitSPI)
@property (nonatomic) BOOL databasesEnabled;
@property (nonatomic) BOOL localStorageEnabled;
@property (nonatomic) BOOL notificationsEnabled;
@property (nonatomic) WebStorageBlockingPolicy storageBlockingPolicy;
@property (nonatomic, setter=_setLocalStorageDatabasePath:) NSString *_localStorageDatabasePath;
@end

@interface WebSecurityOrigin : NSObject
- (id)initWithURL:(NSURL *)url;
@end

@interface WebStorageManager : NSObject
+ (WebStorageManager *)sharedWebStorageManager;
+ (NSString *)_storageDirectoryPath;
- (void)deleteOrigin:(WebSecurityOrigin *)origin;
@end

@interface WebView (WCWebKitSPI)
+ (void)_addOriginAccessWhitelistEntryWithSourceOrigin:(NSString *)sourceOrigin destinationProtocol:(NSString *)destinationProtocol destinationHost:(NSString *)destinationHost allowDestinationSubdomains:(BOOL)allowDestinationSubdomains;
+ (void)_removeOriginAccessWhitelistEntryWithSourceOrigin:(NSString *)sourceOrigin destinationProtocol:(NSString *)destinationProtocol destinationHost:(NSString *)destinationHost allowDestinationSubdomains:(BOOL)allowDestinationSubdomains;
@end

@interface WKPreferences (WCWebKitSPI)
@property (nonatomic, setter=_setStandardFontFamily:) NSString *_standardFontFamily;
@property (nonatomic, copy, setter=_setFixedPitchFontFamily:) NSString *_fixedPitchFontFamily;
@property (nonatomic, setter=_setDefaultFontSize:) NSUInteger _defaultFontSize;
@property (nonatomic, setter=_setDefaultFixedPitchFontSize:) NSUInteger _defaultFixedPitchFontSize;
@property (nonatomic, setter=_setDefaultTextEncodingName:) NSString *_defaultTextEncodingName;
@end

@interface _WKUserStyleSheet : NSObject <NSCopying>
- (instancetype)initWithSource:(NSString *)source forMainFrameOnly:(BOOL)forMainFrameOnly;
@end

typedef NS_ENUM(NSInteger, _WKUserStyleLevel) {
    _WKUserStyleUserLevel,
    _WKUserStyleAuthorLevel,
};

@interface _WKUserStyleSheet (WCWebKitSPI)
- (instancetype)initWithSource:(NSString *)source forWKWebView:(WKWebView *)webView forMainFrameOnly:(BOOL)forMainFrameOnly includeMatchPatternStrings:(NSArray<NSString *> *)includeMatchPatternStrings excludeMatchPatternStrings:(NSArray<NSString *> *)excludeMatchPatternStrings baseURL:(NSURL *)baseURL level:(_WKUserStyleLevel)level contentWorld:(WKContentWorld *)contentWorld;
@end

@interface WKUserScript (WCWebKitSPI)
- (instancetype)_initWithSource:(NSString *)source injectionTime:(WKUserScriptInjectionTime)injectionTime forMainFrameOnly:(BOOL)forMainFrameOnly includeMatchPatternStrings:(NSArray<NSString *> *)includeMatchPatternStrings excludeMatchPatternStrings:(NSArray<NSString *> *)excludeMatchPatternStrings associatedURL:(NSURL *)associatedURL contentWorld:(WKContentWorld *)contentWorld;
@end

@interface WKUserContentController (WCWebKitSPI)
- (void)_addUserStyleSheet:(_WKUserStyleSheet *)userStyleSheet;
- (void)_removeUserStyleSheet:(_WKUserStyleSheet *)userStyleSheet;
- (void)_removeUserScript:(WKUserScript *)userScript;
- (void)_removeAllUserScriptsAssociatedWithContentWorld:(WKContentWorld *)contentWorld;
@end

@interface _WKProcessPoolConfiguration : NSObject <NSCopying>
@property (nonatomic, copy) NSURL *injectedBundleURL;
@end

@interface WKProcessPool (WCWebKitSPI)
- (instancetype)_initWithConfiguration:(_WKProcessPoolConfiguration *)configuration __attribute__((objc_method_family(init)));
@end

@interface WKBrowsingContextController : NSObject
+ (void)registerSchemeForCustomProtocol:(NSString *)scheme;
@end

@interface WKNavigationAction (WCWebKitSPI)
@property (nonatomic, readonly, getter=_isUserInitiated) BOOL _userInitiated;
@end

typedef NS_OPTIONS(NSUInteger, _WKRenderingProgressEvents) {
    _WKRenderingProgressEventFirstPaintWithSignificantArea = 1 << 2,
    _WKRenderingProgressEventFirstMeaningfulPaint = 1 << 8,
};

@interface WKWebView (WCWebKitSPI)
@property (nonatomic, setter=_setObservedRenderingProgressEvents:) _WKRenderingProgressEvents _observedRenderingProgressEvents;
@property (nonatomic, setter=_setClipsToVisibleRect:) BOOL _clipsToVisibleRect;
@property (nonatomic, setter=_setViewportSizeForCSSViewportUnits:) CGSize _viewportSizeForCSSViewportUnits;
@property (nonatomic, readonly) NSEdgeInsets _obscuredContentInsets;
@property (nonatomic, setter=_setAutomaticallyAdjustsContentInsets:) BOOL _automaticallyAdjustsContentInsets;
- (void)_setObscuredContentInsets:(NSEdgeInsets)insets immediate:(BOOL)immediate;
@property (nonatomic, setter=_setTextZoomFactor:) double _textZoomFactor;
- (void)_doAfterNextPresentationUpdate:(void (^)(void))updateBlock;
@property (nonatomic, readonly, getter=_isPlayingAudio) BOOL _playingAudio;
- (WKPageRef)_pageRefForTransitionToWKWebView;
- (void)_close;
@end
