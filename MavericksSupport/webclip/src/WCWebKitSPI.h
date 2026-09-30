// WebKit SPI the plug-in uses beyond the SDK's public headers.

#import <WebKit/WebKit.h>

typedef const struct OpaqueWKPage *WKPageRef;
typedef const struct OpaqueWKString *WKStringRef;
extern void WKPageSetCustomTextEncodingName(WKPageRef, WKStringRef);
extern WKStringRef WKStringCreateWithCFString(CFStringRef);
extern void WKRelease(const void *);

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
@property (nonatomic, setter=_setTextZoomFactor:) double _textZoomFactor;
- (WKPageRef)_pageRefForTransitionToWKWebView;
- (void)_close;
@end
