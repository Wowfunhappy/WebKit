// WebKit SPI the plug-in uses beyond the SDK's public headers.

#import <WebKit/WebKit.h>

typedef const struct OpaqueWKPage *WKPageRef;
typedef const struct OpaqueWKString *WKStringRef;
extern void WKPageSetCustomTextEncodingName(WKPageRef, WKStringRef);
extern WKStringRef WKStringCreateWithCFString(CFStringRef);
extern void WKRelease(const void *);
extern void WKPagePostMessageToInjectedBundle(WKPageRef, WKStringRef, const void *messageBody);

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

@interface WKUserContentController (WCWebKitSPI)
- (void)_addUserStyleSheet:(_WKUserStyleSheet *)userStyleSheet;
@end

@interface _WKProcessPoolConfiguration : NSObject <NSCopying>
@property (nonatomic, copy) NSURL *injectedBundleURL;
@end

@interface WKProcessPool (WCWebKitSPI)
- (instancetype)_initWithConfiguration:(_WKProcessPoolConfiguration *)configuration __attribute__((objc_method_family(init)));
@end

@interface WKNavigationAction (WCWebKitSPI)
@property (nonatomic, readonly, getter=_isUserInitiated) BOOL _userInitiated;
@end

typedef NS_OPTIONS(NSUInteger, _WKRenderingProgressEvents) {
    _WKRenderingProgressEventFirstPaintWithSignificantArea = 1 << 2,
    _WKRenderingProgressEventFirstMeaningfulPaint = 1 << 8,
};

@protocol _WKFullscreenDelegate <NSObject>
@optional
- (void)_webViewWillEnterFullscreen:(NSView *)webView;
- (void)_webViewWillExitFullscreen:(NSView *)webView;
@end

@interface WKWebView (WCWebKitSPI)
@property (nonatomic, setter=_setFullscreenDelegate:) id <_WKFullscreenDelegate> _fullscreenDelegate;
@property (nonatomic, setter=_setObservedRenderingProgressEvents:) _WKRenderingProgressEvents _observedRenderingProgressEvents;
@property (nonatomic, setter=_setClipsToVisibleRect:) BOOL _clipsToVisibleRect;
@property (nonatomic, setter=_setViewportSizeForCSSViewportUnits:) CGSize _viewportSizeForCSSViewportUnits;
@property (nonatomic, setter=_setTextZoomFactor:) double _textZoomFactor;
@property (nonatomic, readonly, getter=_isPlayingAudio) BOOL _playingAudio;
- (WKPageRef)_pageRefForTransitionToWKWebView;
- (void)_close;
@end
