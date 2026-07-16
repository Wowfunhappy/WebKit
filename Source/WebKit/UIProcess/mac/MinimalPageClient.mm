// MinimalPageClient — PageClient backing WKView on the MAVERICKS_BACKPORT.
//
// Safari 7 drives WebKit2 through WKView (an NSView), not WKWebView. WKView
// creates its WebPageProxy with this lightweight PageClient instead of the
// upstream WKWebView + WebViewImpl + PageClientImpl stack (PageClientImpl is
// `final` and tightly coupled to WebViewImpl). It inherits the Cocoa-common
// behavior from PageClientImplCocoa and implements the view-geometry, layer
// hosting (TiledCoreAnimation), and coordinate-transform pieces directly
// against the backing NSView; the remaining PageClient surface is stubbed.
//
// WKView.mm forward-declares createMinimalPageClient()/setMinimalPageClientPage();
// they are defined at the bottom of this file.
//
// (The original MinimalPageClient.mm was written during the Safari-9 effort but
// was never committed and was lost in the VM reset; this is a clean rewrite.)

#import "config.h"

#if PLATFORM(MAC)

#import "DrawingAreaProxy.h"
#import "LayerTreeContext.h"
#import "NativeWebKeyboardEvent.h"
#import "PageClientImplCocoa.h"
#import "RemoteLayerTreeNode.h"
#import "TiledCoreAnimationDrawingAreaProxy.h"
#import "ViewSnapshotStore.h"
#import "WebColorPickerMac.h"
#import "WebContextMenuProxyMac.h"
#import "WebPageProxy.h"
#import "WebPopupMenuProxyMac.h"
#import "WebProcessProxy.h"
#import "WebEditCommandProxy.h"
#import "UndoOrRedo.h"
#import "EditorState.h"
#import "WKEditCommand.h"
#import <WebCore/CGWindowUtilities.h>
#import <WebCore/DictionaryPopupInfo.h>
// MAVERICKS_BACKPORT: WebCore::ScrollbarStyle, consumed by recommendedScrollbarStyleDidChange.
#import <WebCore/ScrollTypes.h>
#import <WebCore/TextUndoInsertionMarkupMac.h>
#import <WebCore/Cursor.h>
#import <WebCore/IOSurface.h>
#if ENABLE(DRAG_SUPPORT)
#import <WebCore/ShareableBitmap.h>
#import <WebCore/DragItem.h>
#endif
#if ENABLE(FULLSCREEN_API)
#import "WebFullScreenManagerProxy.h"
#endif
#import <WebCore/DestinationColorSpace.h>
#import <WebCore/FloatRect.h>
#import <WebCore/FloatSize.h>
#import <WebCore/IntPoint.h>
#import <WebCore/IntRect.h>
#import <WebCore/IntSize.h>
#import <WebCore/Region.h>
#import <WebCore/ValidationBubble.h>
#import <WebCore/WebCoreCALayerExtras.h>
#import <WebCore/WebMediaSessionManager.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <wtf/RetainPtr.h>
#import <wtf/SortedArrayMap.h>

// MAVERICKS_BACKPORT: layer-HOSTING subview for the WebContent render layer (the Safari-537
// WKView "_layerHostingView"/WKFlippedView design; see the m_layerHostingView member comment).
// Flipped to match WKView's coordinate system. Event-transparent: hit-testing returns nil so
// mouse events keep landing on the WKView itself, exactly as before this subview existed.
@interface WKMinimalLayerHostingView : NSView
@end

@implementation WKMinimalLayerHostingView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

#if ENABLE(FULLSCREEN_API)
// MAVERICKS_BACKPORT: a borderless content window must opt in to becoming key
// and main, otherwise the web view it hosts never receives keyboard events
// (notably Escape, which WebCore's EventHandler uses to exit fullscreen).
@interface WKMinimalFullScreenWindow : NSWindow
@end

@implementation WKMinimalFullScreenWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
#endif

#if ENABLE(DRAG_SUPPORT)
// MAVERICKS_BACKPORT: WKView (in WKView.mm) implements this to start the OS drag
// session once startDrag has built the drag image. Declared here so the page
// client can invoke it on its NSView.
@interface NSView (WKViewDragSource)
- (void)_wk_beginDragWithImage:(NSImage *)image atWindowPoint:(NSPoint)windowPoint;
@end
#endif

// MAVERICKS_BACKPORT: WKView's auto-layout intrinsic-content-size setter, invoked from
// intrinsicContentSizeDidChange so Mail's message view sizes to its content.
@interface NSView (WKViewAutoLayout)
- (void)_setIntrinsicContentSize:(NSSize)intrinsicContentSize;
@end

// MAVERICKS_BACKPORT: WKView's unhandled-key-down re-dispatch (the WebViewImpl::doneWithKeyEvent
// m_keyDownEventBeingResent re-send), invoked from doneWithKeyEvent so menu key equivalents fire
// after the page declines a key-down it got first crack at via -[WKView performKeyEquivalent:].
@interface NSView (WKViewKeyResend)
- (void)_mavericksResendUnhandledKeyDownEvent:(NSEvent *)event;
@end

// MAVERICKS_BACKPORT: WKView's title-attribute tooltip setter (classic -addToolTipRect:/
// -view:stringForToolTip: mechanism), invoked from toolTipChanged so hover tooltips appear.
@interface NSView (WKViewToolTip)
- (void)_wkSetToolTip:(NSString *)string;
@end

namespace WebKit {

#if ENABLE(FULLSCREEN_API)
// MAVERICKS_BACKPORT: element/video fullscreen for the WKView client. (Held as a
// member rather than via multiple inheritance, which collides with
// PageClientImplCocoa's allocator/destructor.) The full upstream
// WKFullScreenWindowController depends on VideoPresentationManagerProxy and a
// number of 10.10+ AppKit/animation APIs, so this implements the handshake
// directly. The WebProcess renders the :fullscreen element against a black
// backdrop at viewport size, so the UIProcess side only needs to host the
// existing web view at screen size in a black borderless window for the duration
// of the session, and return it to its original place on exit. Escape exits
// because WebCore's EventHandler (web process) calls fullyExitFullscreen() when
// the focused web content receives the keydown.
class MinimalFullScreenManagerProxyClient final : public WebFullScreenManagerProxyClient {
public:
    void closeFullScreenManager() final
    {
        if (m_isFullScreen)
            restoreView();
    }

    bool isFullScreen() final { return m_isFullScreen; }

    void enterFullScreen(WebCore::FloatSize, CompletionHandler<void(bool)>&& completionHandler) final
    {
        if (m_isFullScreen || !m_view) {
            completionHandler(false);
            return;
        }

        NSView *view = m_view;
        m_savedSuperview = [view superview];
        m_savedWindow = [view window];
        m_savedFrame = [view frame];
        m_savedAutoresizingMask = [view autoresizingMask];

        NSScreen *screen = [m_savedWindow screen];
        if (!screen)
            screen = [NSScreen mainScreen];

        m_fullScreenWindow = adoptNS([[WKMinimalFullScreenWindow alloc] initWithContentRect:[screen frame] styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]);
        [m_fullScreenWindow setBackgroundColor:[NSColor blackColor]];
        [m_fullScreenWindow setOpaque:YES];
        [m_fullScreenWindow setHasShadow:NO];
        [m_fullScreenWindow setLevel:NSMainMenuWindowLevel + 1];
        [m_fullScreenWindow setReleasedWhenClosed:NO];

        NSView *contentView = [m_fullScreenWindow contentView];
        [view removeFromSuperview];
        [view setFrame:[contentView bounds]];
        [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [contentView addSubview:view];

        [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
        [m_fullScreenWindow makeKeyAndOrderFront:nil];
        [m_fullScreenWindow makeFirstResponder:view];

        m_isFullScreen = true;
        completionHandler(true);
    }

#if ENABLE(QUICKLOOK_FULLSCREEN)
    void updateImageSource() final { }
#endif

    void exitFullScreen(CompletionHandler<void()>&& completionHandler) final
    {
        // Signal readiness to exit; the actual view restore happens in
        // beganExitFullScreen, after the web process has re-laid-out the element
        // back to its normal size.
        completionHandler();
    }

    void beganEnterFullScreen(const WebCore::IntRect&, const WebCore::IntRect&, CompletionHandler<void(bool)>&& completionHandler) final
    {
        completionHandler(m_isFullScreen);
    }

    void beganExitFullScreen(const WebCore::IntRect&, const WebCore::IntRect&, CompletionHandler<void()>&& completionHandler) final
    {
        restoreView();
        completionHandler();
    }

    NSView *m_view { nullptr };

private:
    void restoreView()
    {
        if (!m_isFullScreen)
            return;
        m_isFullScreen = false;

        NSView *view = m_view;
        if (view && m_savedSuperview) {
            [view removeFromSuperview];
            [view setFrame:m_savedFrame];
            [view setAutoresizingMask:m_savedAutoresizingMask];
            [m_savedSuperview addSubview:view];
        }

        [NSApp setPresentationOptions:NSApplicationPresentationDefault];

        [m_fullScreenWindow orderOut:nil];
        [m_fullScreenWindow close];
        m_fullScreenWindow = nil;

        if (m_savedWindow) {
            [m_savedWindow makeKeyAndOrderFront:nil];
            if (view)
                [m_savedWindow makeFirstResponder:view];
        }

        m_savedSuperview = nil;
        m_savedWindow = nil;
    }

    bool m_isFullScreen { false };
    RetainPtr<NSWindow> m_fullScreenWindow;
    RetainPtr<NSView> m_savedSuperview;
    RetainPtr<NSWindow> m_savedWindow;
    NSRect m_savedFrame { };
    NSAutoresizingMaskOptions m_savedAutoresizingMask { NSViewNotSizable };
};
#endif

class MinimalPageClient final : public PageClientImplCocoa {
public:
    explicit MinimalPageClient(NSView *view)
        : PageClientImplCocoa(nil)
        , m_view(view)
        , m_undoTarget(adoptNS([[WKEditorUndoTarget alloc] init]))
    {
#if ENABLE(FULLSCREEN_API)
        m_fullScreenClient.m_view = view;
#endif
    }

    void setPage(WebPageProxy* page) { m_page = page; }
    void viewDidMoveToWindow(); // MAVERICKS_BACKPORT: re-mint the CALayerHost on window attach (see impl).
    // MAVERICKS_BACKPORT: when true, a view with no NSWindow still reports itself
    // visible/in-window/active. Set for offscreen render views (Safari's Top Sites
    // snapshot fetcher allocs a WKView at the snapshot size and never adds it to a
    // window) so their WebContent takes a foreground assertion and actually loads,
    // lays out, and paints — otherwise the page is treated as a hidden background
    // tab and never renders, so no snapshot is ever produced. See WKView.mm.
    void setForceVisibleWhenWindowless(bool f) { m_forceVisibleWhenWindowless = f; }

private:
    Ref<DrawingAreaProxy> createDrawingAreaProxy(WebProcessProxy&) final;
    void setViewNeedsDisplay(const WebCore::Region&) final;
    void requestScroll(const WebCore::FloatPoint& scrollPosition, const WebCore::IntPoint& scrollOrigin, WebCore::ScrollIsAnimated, WebCore::InterruptScrollAnimation) final;
    WebCore::FloatPoint viewScrollPosition() final;
    WebCore::IntSize viewSize() final;
    bool isViewWindowActive() final;
    bool isViewFocused() final;
    bool isActiveViewVisible() final;
    // MAVERICKS_BACKPORT: PageClientImplCocoa::platformWindow() returns [webView() window], but this
    // client has no WKWebView (constructed with nil), so surface the WKView's window — used by
    // MediaPermissionUtilities::alertForPermission to host the getUserMedia consent sheet.
    CocoaWindow *platformWindow() const final;
#if PLATFORM(COCOA)
    bool canTakeForegroundAssertions() final;
#endif
    bool isViewInWindow() final;
    bool isOffscreenRenderClient() const final { return m_forceVisibleWhenWindowless; }
    bool isMainViewVisible() final;
    bool isViewVisibleOrOccluded() final;
    bool isVisuallyIdle() final;
    void didFirstLayerFlush(const LayerTreeContext&) final;
    void installRenderLayer(CALayer *); // MAVERICKS_BACKPORT: see the m_layerHostingView member comment.
    void processDidExit() final;
    void didRelaunchProcess() final;
    void preferencesDidChange() final;
    void toolTipChanged(const String&, const String&) final;
#if PLATFORM(IOS_FAMILY)
    void decidePolicyForGeolocationPermissionRequest(WebFrameProxy&, const FrameInfoData&, Function<void(bool)>&) final;
#endif
    void didCommitLoadForMainFrame(const String& mimeType, bool useCustomContentProvider) final;
#if ENABLE(PDF_HUD)
    void createPDFHUD(PDFPluginIdentifier, WebCore::FrameIdentifier, const WebCore::IntRect&) final;
#endif
#if ENABLE(PDF_HUD)
    void updatePDFHUDLocation(PDFPluginIdentifier, const WebCore::IntRect&) final;
#endif
#if ENABLE(PDF_HUD)
    void removePDFHUD(PDFPluginIdentifier) final;
#endif
#if ENABLE(PDF_HUD)
    void removeAllPDFHUDs() final;
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void createPDFPageNumberIndicator(PDFPluginIdentifier, const WebCore::IntRect&, size_t pageCount) final;
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void updatePDFPageNumberIndicatorLocation(PDFPluginIdentifier, const WebCore::IntRect&) final;
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void updatePDFPageNumberIndicatorCurrentPage(PDFPluginIdentifier, size_t pageIndex) final;
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void removePDFPageNumberIndicator(PDFPluginIdentifier) final;
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void removeAnyPDFPageNumberIndicator() final;
#endif
    void didChangeContentSize(const WebCore::IntSize&) final;
#if ENABLE(DRAG_SUPPORT)
#if PLATFORM(GTK)
    void startDrag(WebCore::SelectionData&&, OptionSet<WebCore::DragOperation>, RefPtr<WebCore::ShareableBitmap>&& dragImage, WebCore::IntPoint&& dragImageHotspot) final;
#endif
    void startDrag(const WebCore::DragItem&, WebCore::ShareableBitmap::Handle&&, const std::optional<WebCore::NodeIdentifier>&, const std::optional<WebCore::FrameIdentifier>&) final;
#endif
    void setCursor(const WebCore::Cursor&) final;
    void setCursorHiddenUntilMouseMoves(bool) final;
    void registerEditCommand(Ref<WebEditCommandProxy>&&, UndoOrRedo) final;
    void clearAllEditCommands() final;
    bool canUndoRedo(UndoOrRedo) final;
    void executeUndoRedo(UndoOrRedo) final;
    void wheelEventWasNotHandledByWebCore(const NativeWebWheelEvent&) final;
#if PLATFORM(COCOA)
    void accessibilityWebProcessTokenReceived(std::span<const uint8_t>, pid_t) final;
#endif
#if PLATFORM(COCOA)
    bool executeSavedCommandBySelector(const String& selector) final;
#endif
#if PLATFORM(COCOA)
    void updateSecureInputState() final;
#endif
#if PLATFORM(COCOA)
    void resetSecureInputState() final;
#endif
#if PLATFORM(COCOA)
    void notifyInputContextAboutDiscardedComposition() final;
#endif
#if PLATFORM(COCOA)
    void makeFirstResponder() final;
#endif
#if PLATFORM(COCOA)
    void assistiveTechnologyMakeFirstResponder() final;
#endif
#if PLATFORM(COCOA)
    void setRemoteLayerTreeRootNode(RemoteLayerTreeNode*) final;
#endif
#if PLATFORM(COCOA)
    CALayer *acceleratedCompositingRootLayer() const final;
#endif
#if PLATFORM(COCOA)
#if ENABLE(MAC_GESTURE_EVENTS)
    void gestureEventWasNotHandledByWebCore(const NativeWebGestureEvent&) final;
#endif
#endif
#if PLATFORM(MAC)
    CALayer *headerBannerLayer() const final;
#endif
#if PLATFORM(MAC)
    CALayer *footerBannerLayer() const final;
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
    void selectionDidChange() final;
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
    RefPtr<ViewSnapshot> takeViewSnapshot(std::optional<WebCore::IntRect>&&) final;
#endif
#if PLATFORM(MAC)
    RefPtr<ViewSnapshot> takeViewSnapshot(std::optional<WebCore::IntRect>&&, ForceSoftwareCapturingViewportSnapshot) final;
#endif
#if USE(APPKIT)
    void setPromisedDataForImage(const String& pasteboardName, Ref<WebCore::FragmentedSharedBuffer>&& imageBuffer, const String& filename, const String& extension, const String& title, const String& url, const String& visibleURL, RefPtr<WebCore::FragmentedSharedBuffer>&& archiveBuffer, const String& originIdentifier) final;
#endif
    WebCore::FloatRect convertToDeviceSpace(const WebCore::FloatRect&) final;
    WebCore::FloatRect convertToUserSpace(const WebCore::FloatRect&) final;
    WebCore::IntPoint screenToRootView(const WebCore::IntPoint&) final;
    WebCore::IntPoint rootViewToScreen(const WebCore::IntPoint&) final;
    WebCore::IntRect rootViewToScreen(const WebCore::IntRect&) final;
    WebCore::IntPoint accessibilityScreenToRootView(const WebCore::IntPoint&) final;
    WebCore::IntRect rootViewToAccessibilityScreen(const WebCore::IntRect&) final;
#if PLATFORM(IOS_FAMILY)
    void relayAccessibilityNotification(String&&, RetainPtr<NSData>&&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void relayAriaNotifyNotification(const WebCore::AriaNotifyData&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void relayLiveRegionNotification(const WebCore::LiveRegionAnnouncementData&) final;
#endif
#if PLATFORM(MAC)
    WebCore::IntRect rootViewToWindow(const WebCore::IntRect&) final;
#endif
#if ENABLE(TWO_PHASE_CLICKS)
    void didNotHandleTapAsClick(const WebCore::IntPoint&) final;
#endif
    void doneWithKeyEvent(const NativeWebKeyboardEvent&, bool wasEventHandled) final;
#if ENABLE(TOUCH_EVENTS)
    void doneWithTouchEvent(const WebTouchEvent&, bool wasEventHandled) final;
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
    void doneDeferringTouchStart(bool preventNativeGestures) final;
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
    void doneDeferringTouchMove(bool preventNativeGestures) final;
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
    void doneDeferringTouchEnd(bool preventNativeGestures) final;
#endif
    RefPtr<WebPopupMenuProxy> createPopupMenuProxy(WebPageProxy&) final;
#if ENABLE(CONTEXT_MENUS)
    Ref<WebContextMenuProxy> createContextMenuProxy(WebPageProxy&, FrameInfoData&&, ContextMenuContextData&&, const UserData&) final;
#endif
    RefPtr<WebColorPicker> createColorPicker(WebPageProxy&, const WebCore::Color& initialColor, const WebCore::IntRect&, ColorControlSupportsAlpha, Vector<WebCore::Color>&&, std::optional<WebCore::FrameIdentifier>) final;
    RefPtr<WebDataListSuggestionsDropdown> createDataListSuggestionsDropdown(WebPageProxy&) final;
    RefPtr<WebDateTimePicker> createDateTimePicker(WebPageProxy&) final;
#if PLATFORM(COCOA) || PLATFORM(GTK)
    Ref<WebCore::ValidationBubble> createValidationBubble(String&& message, const WebCore::ValidationBubble::Settings&) final;
#endif
#if PLATFORM(COCOA)
    CALayer *textIndicatorInstallationLayer() final;
#endif
#if PLATFORM(COCOA)
    void didPerformDictionaryLookup(const WebCore::DictionaryPopupInfo&) final;
#endif
#if HAVE(APP_ACCENT_COLORS)
    WebCore::Color accentColor() final;
#endif
#if HAVE(APP_ACCENT_COLORS)
#if PLATFORM(MAC)
    bool appUsesCustomAccentColor() final;
#endif
#endif
    void enterAcceleratedCompositingMode(const LayerTreeContext&) final;
    void exitAcceleratedCompositingMode() final;
    void updateAcceleratedCompositingMode(const LayerTreeContext&) final;
#if USE(DICTATION_ALTERNATIVES)
    void showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext) final;
#endif
#if PLATFORM(MAC)
    void showCorrectionPanel(WebCore::AlternativeTextType, const WebCore::FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings) final;
#endif
#if PLATFORM(MAC)
    void dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText) final;
#endif
#if PLATFORM(MAC)
    String dismissCorrectionPanelSoon(WebCore::ReasonForDismissingAlternativeText) final;
#endif
#if PLATFORM(MAC)
    void recordAutocorrectionResponse(WebCore::AutocorrectionResponse, const String& replacedString, const String& replacementString) final;
#endif
#if PLATFORM(MAC)
    void recommendedScrollbarStyleDidChange(WebCore::ScrollbarStyle) final;
#endif
#if PLATFORM(MAC)
    void handleControlledElementIDResponse(const String&) final;
#endif
#if PLATFORM(MAC)
    CGRect boundsOfLayerInLayerBackedWindowCoordinates(CALayer *) const final;
#endif
#if PLATFORM(MAC)
    bool useFormSemanticContext() const final;
#endif
#if PLATFORM(MAC)
    NSView *viewForPresentingRevealPopover() const final;
#endif
#if PLATFORM(MAC)
    void showPlatformContextMenu(NSMenu *, WebCore::IntPoint) final;
#endif
#if PLATFORM(MAC)
    void startWindowDrag() final;
#endif
#if PLATFORM(MAC)
    void setShouldSuppressFirstResponderChanges(bool) final;
#endif
#if PLATFORM(MAC)
    RetainPtr<NSView> inspectorAttachmentView() final;
#endif
#if PLATFORM(MAC)
    _WKRemoteObjectRegistry *remoteObjectRegistry() final;
#endif
#if PLATFORM(MAC)
    void intrinsicContentSizeDidChange(const WebCore::IntSize& intrinsicContentSize) final;
#endif
#if PLATFORM(MAC)
    void registerInsertionUndoGrouping() final;
#endif
#if PLATFORM(MAC)
    void setEditableElementIsFocused(bool) final;
#endif
#if PLATFORM(COCOA)
    void scrollingNodeScrollViewDidScroll(WebCore::ScrollingNodeID) final;
#endif
#if PLATFORM(COCOA)
    WebCore::DestinationColorSpace colorSpace() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void couldNotRestorePageState() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void restorePageState(std::optional<WebCore::FloatPoint> scrollPosition, const WebCore::FloatPoint& scrollOrigin, const WebCore::FloatBoxExtent& obscuredInsetsOnSave, double scale) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void restorePageCenterAndScale(std::optional<WebCore::FloatPoint> center, double scale) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void elementDidFocus(const FocusedElementInformation&, bool userIsInteracting, bool blurPreviousNode, OptionSet<WebCore::ActivityState> activityStateChanges, API::Object* userData) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void updateInputContextAfterBlurringAndRefocusingElement() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void didProgrammaticallyClearFocusedElement(WebCore::ElementContext&&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void updateFocusedElementInformation(const FocusedElementInformation&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void elementDidBlur() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void focusedElementDidChangeInputMode(WebCore::InputMode) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void didUpdateEditorState() final;
#endif
#if PLATFORM(IOS_FAMILY)
    bool isFocusingElement() final;
#endif
#if PLATFORM(IOS_FAMILY)
    bool interpretKeyEvent(const NativeWebKeyboardEvent&, KeyEventInterpretationContext&&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void saveImageToLibrary(Ref<WebCore::SharedBuffer>&&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void showPlaybackTargetPicker(bool hasVideo, const WebCore::IntRect& elementRect, WebCore::RouteSharingPolicy, const String&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void showDataDetectorsUIForPositionInformation(const InteractionInformationAtPosition&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    double minimumZoomScale() const final;
#endif
#if PLATFORM(IOS_FAMILY)
    WebCore::FloatRect documentRect() const final;
#endif
#if PLATFORM(IOS_FAMILY)
    void scrollingNodeScrollViewWillStartPanGesture(WebCore::ScrollingNodeID) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void scrollingNodeScrollWillStartScroll(std::optional<WebCore::ScrollingNodeID>) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void scrollingNodeScrollDidEndScroll(std::optional<WebCore::ScrollingNodeID>) final;
#endif
#if PLATFORM(IOS_FAMILY)
    Vector<String> mimeTypesWithCustomContentProviders() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void hardwareKeyboardAvailabilityChanged() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void showInspectorHighlight(const WebCore::InspectorOverlay::Highlight&) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void hideInspectorHighlight() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void showInspectorIndication() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void hideInspectorIndication() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void enableInspectorNodeSearch() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void disableInspectorNodeSearch() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void handleAutocorrectionContext(const WebAutocorrectionContext&) final;
#endif
#if PLATFORM(IOS_FAMILY)
#if HAVE(UISCROLLVIEW_ASYNCHRONOUS_SCROLL_EVENT_HANDLING)
    void handleAsynchronousCancelableScrollEvent(WKBaseScrollView *, WKBEScrollViewScrollUpdate *, void (^completion)(BOOL handled)) final;
#endif
#endif
#if PLATFORM(IOS_FAMILY)
    bool isSimulatingCompatibilityPointerTouches() const final;
#endif
#if PLATFORM(IOS_FAMILY)
    WebCore::FloatBoxExtent computedObscuredInset() const final;
#endif
#if PLATFORM(IOS_FAMILY)
    WebCore::Color contentViewBackgroundColor() final;
#endif
#if PLATFORM(IOS_FAMILY)
    WebCore::Color insertionPointColor() final;
#endif
#if PLATFORM(IOS_FAMILY)
    bool isScreenBeingCaptured() final;
#endif
#if PLATFORM(IOS_FAMILY)
    String sceneID() final;
#endif
#if PLATFORM(IOS_FAMILY)
    UIScreen *screen() final;
#endif
#if PLATFORM(IOS_FAMILY)
    void beginTextRecognitionForFullscreenVideo(WebCore::ShareableBitmap::Handle&&, AVPlayerViewController *) final;
#endif
#if PLATFORM(IOS_FAMILY)
    void cancelTextRecognitionForFullscreenVideo(AVPlayerViewController *) final;
#endif
#if PLATFORM(COCOA)
    void positionInformationDidChange(const InteractionInformationAtPosition&) final;
#endif
#if ENABLE(FULLSCREEN_API)
    WebFullScreenManagerProxyClient& fullScreenManagerProxyClient() final;
#endif
// setFullScreenClientForTesting is final in a base class; inherited, not overridden.
    void didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>) final;
    void navigationGestureDidBegin() final;
    void navigationGestureWillEnd(bool willNavigate, WebBackForwardListItem&) final;
    void navigationGestureDidEnd(bool willNavigate, WebBackForwardListItem&) final;
    void navigationGestureDidEnd() final;
    void willRecordNavigationSnapshot(WebBackForwardListItem&) final;
    void didRemoveNavigationGestureSnapshot() final;
    void didFirstVisuallyNonEmptyLayoutForMainFrame() final;
    void didFinishNavigation(API::Navigation*) final;
    void didFailNavigation(API::Navigation*) final;
    void didSameDocumentNavigationForMainFrame(SameDocumentNavigationType) final;
    void didChangeBackgroundColor() final;
#if PLATFORM(MAC)
    void didPerformImmediateActionHitTest(const WebHitTestResultData&, bool contentPreventsDefault, API::Object*) final;
#endif
#if PLATFORM(MAC)
    NSObject *immediateActionAnimationControllerForHitTestResult(RefPtr<API::HitTestResult>, uint64_t, RefPtr<API::Object>) final;
#endif
#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)
    WebCore::WebMediaSessionManager& mediaSessionManager() final;
#endif
    void refView() final;
    void derefView() final;
    void didRestoreScrollPosition() final;
    WebCore::UserInterfaceLayoutDirection userInterfaceLayoutDirection() final;
#if USE(QUICK_LOOK)
    void requestPasswordForQuickLookDocument(const String& fileName, WTF::Function<void(const String&)>&&) final;
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
    void willReceiveEditDragSnapshot() final;
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
    void didReceiveEditDragSnapshot(RefPtr<WebCore::TextIndicator>&&) final;
#endif
#if ENABLE(MODEL_PROCESS)
    void didReceiveInteractiveModelElement(std::optional<WebCore::NodeIdentifier>) final;
#endif
    void requestDOMPasteAccess(WebCore::DOMPasteAccessCategory, WebCore::DOMPasteRequiresInteraction, const WebCore::IntRect& elementRect, const String& originIdentifier, CompletionHandler<void(WebCore::DOMPasteAccessResponse)>&&) final;
// storeAppHighlight is final in a base class; inherited, not overridden.
#if USE(WPE_RENDERER)
    UnixFileDescriptor hostFileDescriptor() final;
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
    bool canHandleContextMenuTranslation() const final;
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
    void handleContextMenuTranslation(const WebCore::TranslationContextMenuInfo&) final;
#endif
#if ENABLE(WRITING_TOOLS) && ENABLE(CONTEXT_MENUS)
    bool canHandleContextMenuWritingTools() const final;
#endif
#if ENABLE(WRITING_TOOLS)
    void proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(const WebCore::WritingTools::TextSuggestionID&, WebCore::IntRect selectionBoundsInRootView) final;
#endif
#if USE(GRAPHICS_LAYER_WC)
    bool usesOffscreenRendering() const final;
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
    void didEnterFullscreen() final;
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
    void didExitFullscreen() final;
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
    void didCleanupFullscreen() final;
#endif
#if PLATFORM(GTK) || PLATFORM(WPE)
    WebKitWebResourceLoadManager* webResourceLoadManager() final;
#endif
#if PLATFORM(IOS_FAMILY)
    UIViewController *presentingViewController() const final;
#endif
#if HAVE(SPATIAL_TRACKING_LABEL)
    String spatialTrackingLabel() const final;
#endif

    NSView *m_view { nullptr };
    WebPageProxy *m_page { nullptr };
    bool m_forceVisibleWhenWindowless { false };
    RetainPtr<CALayer> m_rootLayer;
    // MAVERICKS_BACKPORT: dedicated layer-HOSTING subview carrying the WebContent render layer
    // (the Safari-537 WKView _layerHostingView design). The render layer must NOT live in the
    // WKView's own layer-BACKED backing layer: AppKit owns that layer and recreates it when the
    // view moves into a window, orphaning any manually-added sublayer — iBooks composites its
    // reader views before attaching them to the reader window, so its pages stayed blank. A
    // -setLayer:-hosted layer is owned by the view and survives window moves.
    RetainPtr<NSView> m_layerHostingView;
    // MAVERICKS_BACKPORT: last context received in enterAcceleratedCompositingMode, so the
    // CALayerHost can be re-minted when the view moves into a window (see viewDidMoveToWindow()).
    LayerTreeContext m_layerTreeContext;
    RetainPtr<WKEditorUndoTarget> m_undoTarget;
    bool m_inSecureInputState { false };
#if ENABLE(FULLSCREEN_API)
    MinimalFullScreenManagerProxyClient m_fullScreenClient;
#endif
};

// ===== Hand-written implementations =====

Ref<DrawingAreaProxy> MinimalPageClient::createDrawingAreaProxy(WebProcessProxy& process)
{
    return TiledCoreAnimationDrawingAreaProxy::create(*m_page, process);
}

WebCore::IntSize MinimalPageClient::viewSize()
{
    return WebCore::IntSize([m_view bounds].size);
}

bool MinimalPageClient::isViewWindowActive()
{
    NSWindow *window = [m_view window];
    if (window)
        return [window isKeyWindow] || [window isMainWindow];
    return m_forceVisibleWhenWindowless;
}

bool MinimalPageClient::isViewFocused()
{
    NSWindow *window = [m_view window];
    if (window)
        return [window firstResponder] == m_view;
    return m_forceVisibleWhenWindowless;
}

// MAVERICKS_BACKPORT: see the declaration comment; the WKView's window hosts permission sheets.
CocoaWindow *MinimalPageClient::platformWindow() const
{
    return [m_view window];
}

bool MinimalPageClient::isActiveViewVisible()
{
    // Window-level visibility, exactly like isVisuallyIdle() below (and for the same reason): the
    // BrowserWKView's own isHidden flag toggles spuriously while content composites through its
    // layer-hosting sublayer, so consulting the view's flag latches IsVisible=0 at whichever
    // recompute happens to run while it flickers — Safari's typed-URL navigation then leaves the
    // page in prerender mode forever (blank tab). A hidden ANCESTOR (an unselected tab's
    // container) and window-level state are the reliable signals.
    if (!m_view)
        return false;
    NSWindow *window = [m_view window];
    // MAVERICKS_BACKPORT DIAGNOSTIC (sentinel-gated): record what each visibility recompute saw.
    // Armed for the intermittent reader first-activation stall (events flow but timers throttle
    // and paint freezes = the page latched IsVisible=0 at dispatch time); the suspected culprit
    // is a transiently hidden ancestor during Safari's reader activation animation.
    if (!access("/tmp/wk-debug-on", F_OK)) {
        fprintf(stderr, "[VIS-UI] view=%p window=%p winVisible=%d ancestorHidden=%d forceWindowless=%d\n",
            (void*)m_view, (void*)window, window ? (int)[window isVisible] : -1,
            (int)[[m_view superview] isHiddenOrHasHiddenAncestor], (int)m_forceVisibleWhenWindowless);
        fflush(stderr);
    }
    if (!window)
        return m_forceVisibleWhenWindowless;
    if (![window isVisible])
        return false;
    if ([[m_view superview] isHiddenOrHasHiddenAncestor])
        return false;
    return true;
}

bool MinimalPageClient::isMainViewVisible()
{
    return isActiveViewVisible();
}

bool MinimalPageClient::isViewVisibleOrOccluded()
{
    return isActiveViewVisible();
}

bool MinimalPageClient::isViewInWindow()
{
    return m_view && ([m_view window] || m_forceVisibleWhenWindowless);
}

bool MinimalPageClient::isVisuallyIdle()
{
    // The page is "visually idle" (eligible for DOM-timer throttling) only when the user genuinely
    // can't see it. Determine that from window-level state, NOT from the WKView's own isHidden flag:
    // on this backport the BrowserWKView's isHidden toggles spuriously while content composites through
    // its layer-hosting sublayer (and WKView never forwards -viewDidHide, so the activity state would go
    // stale), so keying visual-idle off it pinned EVERY page's DOM timers to the 1s hidden-page alignment.
    // A genuinely-not-on-screen window (miniaturized/ordered-out) or a hidden ANCESTOR (an unselected
    // tab's container) are reliable signals; the per-view isHidden flag is not.
    if (!m_view)
        return true;
    NSWindow *window = [m_view window];
    if (!window)
        return !m_forceVisibleWhenWindowless;
    // Deliberately NOT consulting window.occlusionState: on 10.9 its Visible bit lags (0x2000 -> 0x2002)
    // and the change does not reliably post NSWindowDidChangeOcclusionStateNotification, so an early
    // "occluded" reading gets latched and never recomputed — re-pinning timers to the 1s alignment
    // forever. window.isVisible is stable and is YES at every activity-state recompute for a shown window.
    if (![window isVisible])
        return true;
    if ([[m_view superview] isHiddenOrHasHiddenAncestor])
        return true;
    return false;
}

bool MinimalPageClient::canTakeForegroundAssertions()
{
    return true;
}

WebCore::DestinationColorSpace MinimalPageClient::colorSpace()
{
    return WebCore::DestinationColorSpace::SRGB();
}

WebCore::FloatRect MinimalPageClient::convertToDeviceSpace(const WebCore::FloatRect& rect)
{
    return rect;
}

WebCore::FloatRect MinimalPageClient::convertToUserSpace(const WebCore::FloatRect& rect)
{
    return rect;
}

WebCore::IntPoint MinimalPageClient::screenToRootView(const WebCore::IntPoint& point)
{
    NSWindow *window = [m_view window];
    if (!window)
        return point;
    NSPoint windowPoint = [window convertRectFromScreen:NSMakeRect(point.x(), point.y(), 0, 0)].origin;
    NSPoint viewPoint = [m_view convertPoint:windowPoint fromView:nil];
    return WebCore::IntPoint(static_cast<int>(viewPoint.x), static_cast<int>(viewPoint.y));
}

WebCore::IntPoint MinimalPageClient::rootViewToScreen(const WebCore::IntPoint& point)
{
    NSWindow *window = [m_view window];
    if (!window)
        return point;
    NSPoint windowPoint = [m_view convertPoint:NSMakePoint(point.x(), point.y()) toView:nil];
    NSRect screenRect = [window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 0, 0)];
    return WebCore::IntPoint(static_cast<int>(screenRect.origin.x), static_cast<int>(screenRect.origin.y));
}

WebCore::IntRect MinimalPageClient::rootViewToScreen(const WebCore::IntRect& rect)
{
    NSWindow *window = [m_view window];
    NSRect viewRect = [m_view convertRect:NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height()) toView:nil];
    if (!window)
        return rect;
    NSRect screenRect = [window convertRectToScreen:viewRect];
    return WebCore::IntRect(static_cast<int>(screenRect.origin.x), static_cast<int>(screenRect.origin.y), static_cast<int>(screenRect.size.width), static_cast<int>(screenRect.size.height));
}

WebCore::IntRect MinimalPageClient::rootViewToWindow(const WebCore::IntRect& rect)
{
    NSRect windowRect = [m_view convertRect:NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height()) toView:nil];
    return WebCore::IntRect(static_cast<int>(windowRect.origin.x), static_cast<int>(windowRect.origin.y), static_cast<int>(windowRect.size.width), static_cast<int>(windowRect.size.height));
}

void MinimalPageClient::makeFirstResponder()
{
    [[m_view window] makeFirstResponder:m_view];
}

void MinimalPageClient::refView()
{
    [m_view retain];
}

void MinimalPageClient::derefView()
{
    [m_view release];
}

// MAVERICKS_BACKPORT: install `renderLayer` as the sole sublayer of a dedicated layer-HOSTING
// subview of the WKView (the Safari-537 _layerHostingView design). The subview owns its layer
// via -setLayer:, so the hosted content survives the view moving into a window — attaching to
// the WKView's AppKit-owned backing layer does not (AppKit recreates that layer at window
// attach, orphaning the sublayer; iBooks composites its reader views pre-window and showed
// blank pages). Like 537, the render layer gets no frame: its (0,0) anchors the remote layer
// tree to the hosting view's top-left, and the web-process side sizes the content.
void MinimalPageClient::installRenderLayer(CALayer *renderLayer)
{
    if (m_rootLayer)
        [m_rootLayer removeFromSuperlayer];
    m_rootLayer = renderLayer;

    if (!m_view || !renderLayer) {
        if (m_layerHostingView) {
            [m_layerHostingView removeFromSuperview];
            [m_layerHostingView setLayer:nil];
            [m_layerHostingView setWantsLayer:NO];
            m_layerHostingView = nullptr;
        }
        return;
    }

    if (!m_layerHostingView) {
        m_layerHostingView = adoptNS([[WKMinimalLayerHostingView alloc] initWithFrame:[m_view bounds]]);
        [m_layerHostingView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        RetainPtr<CALayer> hostingRootLayer = adoptNS([[CALayer alloc] init]);
        [m_layerHostingView setLayer:hostingRootLayer.get()];
        [m_layerHostingView setWantsLayer:YES];
        [m_view addSubview:m_layerHostingView.get() positioned:NSWindowBelow relativeTo:nil];
    }
    [m_layerHostingView layer].sublayers = @[ renderLayer ];
}

void MinimalPageClient::enterAcceleratedCompositingMode(const LayerTreeContext& context)
{
    m_layerTreeContext = context;
    RetainPtr<CALayer> renderLayer = [CALayer _web_renderLayerWithContextID:context.contextID shouldPreserveFlip:NO];
    installRenderLayer(renderLayer.get());
    // MAVERICKS_BACKPORT DIAGNOSTIC (sentinel-gated): trace hosted-layer attach while debugging.
    if (!access("/tmp/wk-debug-on", F_OK)) {
        fprintf(stderr, "[EACM] view=%p ctxID=%u layer=%p hostingView=%p bounds=%.0fx%.0f window=%p\n", (void*)m_view, context.contextID, (void*)renderLayer.get(), (void*)m_layerHostingView.get(), [m_view bounds].size.width, [m_view bounds].size.height, (void*)[m_view window]);
        fflush(stderr);
    }
}

void MinimalPageClient::updateAcceleratedCompositingMode(const LayerTreeContext& context)
{
    enterAcceleratedCompositingMode(context);
}

void MinimalPageClient::exitAcceleratedCompositingMode()
{
    m_layerTreeContext = LayerTreeContext();
    installRenderLayer(nil);
}

// MAVERICKS_BACKPORT: a CALayerHost minted while its view is OUTSIDE any window never connects
// to the remote CAContext when the view later joins one — the hosted content stays permanently
// empty even though the web process flushes (iBooks composites its reader views pre-window;
// their pages showed the hosting layer but no content). Re-mint the CALayerHost from the stored
// LayerTreeContext when the view enters a window. Called from -[WKView viewDidMoveToWindow].
void MinimalPageClient::viewDidMoveToWindow()
{
    if (!m_view || ![m_view window])
        return;
    if (m_layerTreeContext.isEmpty())
        return;
    RetainPtr<CALayer> renderLayer = [CALayer _web_renderLayerWithContextID:m_layerTreeContext.contextID shouldPreserveFlip:NO];
    installRenderLayer(renderLayer.get());
}

void MinimalPageClient::didFirstLayerFlush(const LayerTreeContext& context)
{
    if (!context.isEmpty())
        enterAcceleratedCompositingMode(context);
}

void MinimalPageClient::setRemoteLayerTreeRootNode(RemoteLayerTreeNode* rootNode)
{
    installRenderLayer(rootNode ? rootNode->layer() : nil);
}

CALayer *MinimalPageClient::acceleratedCompositingRootLayer() const
{
    return m_rootLayer.get();
}

// ===== Generated minimal stubs for the remaining PageClient surface =====

void MinimalPageClient::setViewNeedsDisplay(const WebCore::Region&)
{ }
void MinimalPageClient::requestScroll(const WebCore::FloatPoint& scrollPosition, const WebCore::IntPoint& scrollOrigin, WebCore::ScrollIsAnimated, WebCore::InterruptScrollAnimation)
{ }
WebCore::FloatPoint MinimalPageClient::viewScrollPosition()
{ return { }; }
void MinimalPageClient::processDidExit()
{ }
void MinimalPageClient::didRelaunchProcess()
{
    // MAVERICKS_BACKPORT: hasRunningProcess() returns false after Safari closes the XPC
    // bootstrap, so WebPageProxy::loadRequest() relaunches the process on essentially
    // every load. launchProcess() -> finishAttachingToWebProcess() -> initializeWebPage()
    // installs a FRESH drawing area sized 0x0. Visible WKViews recover because Safari
    // later sends -setFrameSize: (which sizes the drawing area), but a windowless
    // offscreen render view (Top Sites snapshot fetcher) never gets that call, so its
    // page would stay 0x0 and never lay out or paint. Re-apply the view's own size to
    // the new drawing area here so the page renders across relaunches regardless of the
    // external resize lifecycle.
    if (!m_page || !m_view)
        return;
    if (RefPtr drawingArea = m_page->drawingArea()) {
        WebCore::IntSize size([m_view bounds].size);
        if (!size.isEmpty())
            drawingArea->setSize(size);
    }
}
void MinimalPageClient::preferencesDidChange()
{ }
void MinimalPageClient::toolTipChanged(const String&, const String& newToolTip)
{
    // MAVERICKS_BACKPORT: wire the title-attribute tooltip to WKView's classic -addToolTipRect:/
    // -view:stringForToolTip: mechanism (see -[WKView _wkSetToolTip:]). WebViewImpl's NSToolTipManager
    // path is not used by the reimplemented WKView.
    if (m_view)
        [m_view _wkSetToolTip:newToolTip.createNSString().get()];
}
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::decidePolicyForGeolocationPermissionRequest(WebFrameProxy&, const FrameInfoData&, Function<void(bool)>&)
{ }
#endif
void MinimalPageClient::didCommitLoadForMainFrame(const String& mimeType, bool useCustomContentProvider)
{ }
#if ENABLE(PDF_HUD)
void MinimalPageClient::createPDFHUD(PDFPluginIdentifier, WebCore::FrameIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_HUD)
void MinimalPageClient::updatePDFHUDLocation(PDFPluginIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_HUD)
void MinimalPageClient::removePDFHUD(PDFPluginIdentifier)
{ }
#endif
#if ENABLE(PDF_HUD)
void MinimalPageClient::removeAllPDFHUDs()
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MinimalPageClient::createPDFPageNumberIndicator(PDFPluginIdentifier, const WebCore::IntRect&, size_t pageCount)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MinimalPageClient::updatePDFPageNumberIndicatorLocation(PDFPluginIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MinimalPageClient::updatePDFPageNumberIndicatorCurrentPage(PDFPluginIdentifier, size_t pageIndex)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MinimalPageClient::removePDFPageNumberIndicator(PDFPluginIdentifier)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MinimalPageClient::removeAnyPDFPageNumberIndicator()
{ }
#endif
void MinimalPageClient::didChangeContentSize(const WebCore::IntSize&)
{ }
#if ENABLE(DRAG_SUPPORT)
#if PLATFORM(GTK)
void MinimalPageClient::startDrag(WebCore::SelectionData&&, OptionSet<WebCore::DragOperation>, RefPtr<WebCore::ShareableBitmap>&& dragImage, WebCore::IntPoint&& dragImageHotspot)
{ }
#endif
// MAVERICKS_BACKPORT: hand the OS drag session off to the WKView. Mirrors
// WebViewImpl::startDrag (already 10.9-adapted: NSFilePromiseProvider drag is
// 10.12+, so a promised-attachment drag is cancelled rather than attempted).
void MinimalPageClient::startDrag(const WebCore::DragItem& item, WebCore::ShareableBitmap::Handle&& dragImageHandle, const std::optional<WebCore::NodeIdentifier>&, const std::optional<WebCore::FrameIdentifier>&)
{
    auto bitmap = WebCore::ShareableBitmap::create(WTF::move(dragImageHandle));
    if (!bitmap || !m_view || !m_page) {
        if (m_page)
            m_page->dragCancelled();
        return;
    }

    if (item.promisedAttachmentInfo) {
        m_page->dragCancelled();
        return;
    }

    RetainPtr dragCGImage = bitmap->createPlatformImage(WebCore::DontCopyBackingStore);
    auto dragNSImage = adoptNS([[NSImage alloc] initWithCGImage:dragCGImage.get() size:bitmap->size()]);
    WebCore::IntSize size([dragNSImage size]);
    size.scale(1.0 / m_page->deviceScaleFactor());
    [dragNSImage setSize:size];

    m_page->didStartDrag();
    [m_view _wk_beginDragWithImage:dragNSImage.get() atWindowPoint:NSMakePoint(item.dragLocationInWindowCoordinates.x(), item.dragLocationInWindowCoordinates.y())];
}
#endif
void MinimalPageClient::setCursor(const WebCore::Cursor& cursor)
{
    // MAVERICKS_BACKPORT: WebCore asks the page client to change the cursor (hand over links, I-beam over
    // text, etc.). The previous empty stub meant the cursor never updated under WKView. Mirror
    // PageClientImpl (minus the WebViewImpl-only image-analysis overlay check).
    if (!isViewWindowActive())
        return;
    if (!m_view)
        return;
    NSWindow *window = [m_view window];
    if (!window)
        return;

    // Don't fight AppKit if the pointer is actually over a different window.
    NSPoint mouseLocationInScreen = [NSEvent mouseLocation];
    if (window.windowNumber != [NSWindow windowNumberAtPoint:mouseLocationInScreen belowWindowWithWindowNumber:0])
        return;

    RetainPtr<NSCursor> platformCursor = cursor.platformCursor();
    if ([NSCursor currentCursor] == platformCursor.get())
        return;

    [platformCursor.get() set];

    if (cursor.type() == WebCore::Cursor::Type::None) {
        if ([NSCursor respondsToSelector:@selector(hideUntilChanged)])
            [NSCursor hideUntilChanged];
    }
}
void MinimalPageClient::setCursorHiddenUntilMouseMoves(bool hiddenUntilMouseMoves)
{
    [NSCursor setHiddenUntilMouseMoves:hiddenUntilMouseMoves];
}
// MAVERICKS_BACKPORT: implement the WKView undo surface (these were empty stubs, so Cmd+Z no-op'd
// in every web text field). The WebProcess sends RegisterEditCommandForUndo and WebPageProxy routes
// it here; register the command with the view's NSUndoManager so the standard undo:/redo: actions
// drive WebEditCommandProxy::unapply()/reapply(). Mirrors WebViewImpl/PageClientImplMac.
void MinimalPageClient::registerEditCommand(Ref<WebEditCommandProxy>&& command, UndoOrRedo undoOrRedo)
{
    auto actionName = command->label();
    auto commandObjC = adoptNS([[WKEditCommand alloc] initWithWebEditCommandProxy:WTF::move(command)]);

    RetainPtr undoManager = [m_view undoManager];
    [undoManager registerUndoWithTarget:m_undoTarget.get() selector:((undoOrRedo == UndoOrRedo::Undo) ? @selector(undoEditing:) : @selector(redoEditing:)) object:commandObjC.get()];
    if (!actionName.isEmpty())
        [undoManager setActionName:actionName.createNSString().get()];
}
void MinimalPageClient::clearAllEditCommands()
{
    [[m_view undoManager] removeAllActionsWithTarget:m_undoTarget.get()];
}
bool MinimalPageClient::canUndoRedo(UndoOrRedo undoOrRedo)
{
    RetainPtr undoManager = [m_view undoManager];
    return undoOrRedo == UndoOrRedo::Undo ? [undoManager canUndo] : [undoManager canRedo];
}
void MinimalPageClient::executeUndoRedo(UndoOrRedo undoOrRedo)
{
    RetainPtr undoManager = [m_view undoManager];
    undoOrRedo == UndoOrRedo::Undo ? [undoManager undo] : [undoManager redo];
}
void MinimalPageClient::wheelEventWasNotHandledByWebCore(const NativeWebWheelEvent&)
{ }
#if PLATFORM(COCOA)
void MinimalPageClient::accessibilityWebProcessTokenReceived(std::span<const uint8_t>, pid_t)
{ }
#endif
#if PLATFORM(COCOA)
// MAVERICKS_BACKPORT: map an AppKit responder scroll selector to its WebCore Editor command.
// These are the always-enabled (non-editable) scrolling commands that the WebContent-side
// keypress path (WebPage::executeKeypressCommandsInternal) deliberately does NOT handle and
// instead forwards to the UIProcess responder fallback. Upstream WKWebView implements these
// as NSResponder action methods that route through WebViewImpl::commandNameForSelector; the
// scrollPageDown:/scrollPageUp: pair needs the same name-exception WebViewImpl uses, while the
// rest equal the command name minus the trailing colon (Editor command names are case-insensitive).
static String scrollCommandNameForSavedSelector(const String& selector)
{
    static constexpr SortedArrayMap map { std::to_array<std::pair<ComparableASCIILiteral, ASCIILiteral>>({
        { "scrollLineDown:"_s, "ScrollLineDown"_s },
        { "scrollLineUp:"_s, "ScrollLineUp"_s },
        { "scrollPageDown:"_s, "ScrollPageForward"_s },
        { "scrollPageUp:"_s, "ScrollPageBackward"_s },
        { "scrollToBeginningOfDocument:"_s, "ScrollToBeginningOfDocument"_s },
        { "scrollToEndOfDocument:"_s, "ScrollToEndOfDocument"_s },
    }) };
    if (auto commandName = map.tryGet(selector))
        return *commandName;
    return String();
}

bool MinimalPageClient::executeSavedCommandBySelector(const String& selector)
{
    // MAVERICKS_BACKPORT: upstream WKWebView implements scrollPageDown:/scrollPageUp:/etc. as
    // NSResponder action methods, so when the WebContent Editor doesn't handle a keypress
    // command (e.g. PageDown over non-editable content), the IPC fallback
    // (WebPageProxy::executeSavedCommandBySelector -> _web_superDoCommandBySelector:) lands on
    // those methods, which call WebViewImpl::executeEditCommandForSelector ->
    // WebPageProxy::executeEditCommand. Safari's WKView has no such action methods and this
    // page client previously stubbed this hop out, so PageDown/PageUp (and the other document
    // scroll selectors) silently did nothing. Restore the upstream behavior by resolving the
    // scroll selector to its Editor command and executing it on the page, exactly as the
    // WKWebView action methods would have. Selectors we don't recognize are returned as
    // unhandled (false) so they still bubble to Safari's own responder handling.
    if (!m_page)
        return false;
    String commandName = scrollCommandNameForSavedSelector(selector);
    if (commandName.isEmpty())
        return false;
    m_page->executeEditCommand(commandName, String());
    return true;
}
#endif
// MAVERICKS_BACKPORT: HIToolbox secure-event-input (declared in <Carbon/Carbon.h>, forward-declared
// here to avoid pulling all of Carbon — which pollutes the namespace — into this file).
extern "C" OSStatus EnableSecureEventInput(void);
extern "C" OSStatus DisableSecureEventInput(void);

#if PLATFORM(COCOA)
// MAVERICKS_BACKPORT: enable secure event input while a web password field is focused (was an empty
// stub, so web passwords typed in Safari lacked the keylogger protection stock Safari provides).
// Mirrors WebViewImpl::updateSecureInputState; editorState().isInPasswordField is populated by
// WebPage.cpp from input->isPasswordField().
void MinimalPageClient::updateSecureInputState()
{
    if (![[m_view window] isKeyWindow] || !isViewFocused()) {
        if (m_inSecureInputState) {
            DisableSecureEventInput();
            m_inSecureInputState = false;
        }
        return;
    }
    bool isInPasswordField = m_page && m_page->editorState().isInPasswordField;
    if (isInPasswordField) {
        if (!m_inSecureInputState)
            EnableSecureEventInput();
    } else if (m_inSecureInputState)
        DisableSecureEventInput();
    m_inSecureInputState = isInPasswordField;
}
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::resetSecureInputState()
{
    if (m_inSecureInputState) {
        DisableSecureEventInput();
        m_inSecureInputState = false;
    }
}
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::notifyInputContextAboutDiscardedComposition()
{ }
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::assistiveTechnologyMakeFirstResponder()
{ }
#endif
#if PLATFORM(COCOA)
#if ENABLE(MAC_GESTURE_EVENTS)
void MinimalPageClient::gestureEventWasNotHandledByWebCore(const NativeWebGestureEvent&)
{ }
#endif
#endif
#if PLATFORM(MAC)
CALayer *MinimalPageClient::headerBannerLayer() const
{ return { }; }
#endif
#if PLATFORM(MAC)
CALayer *MinimalPageClient::footerBannerLayer() const
{ return { }; }
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
void MinimalPageClient::selectionDidChange()
{ }
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
// Capture the on-screen window content cropped to the WKView and wrap it in a ViewSnapshot.
// ViewSnapshotStore feeds both back/forward swipe snapshots and Safari's Top Sites thumbnails,
// so the previous {} stub left every Top Sites tile blank. Ported from WebViewImpl::takeViewSnapshot
// (MinimalPageClient has no WebViewImpl); uses CGWindowListCreateImage + AppKit coordinates instead
// of the private CGS hardware-capture path.
static RefPtr<ViewSnapshot> captureMinimalViewSnapshot(NSView *view)
{
    if (!view)
        return nullptr;
    NSWindow *window = [view window];
    CGWindowID windowID = (CGWindowID)window.windowNumber;
    if (!windowID || !window.isVisible)
        return nullptr;

    CGWindowImageOption imageOptions = kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque;
    RetainPtr<CGImageRef> windowSnapshotImage = WebCore::cgWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, windowID, imageOptions);
    if (!windowSnapshotImage)
        return nullptr;

    CGFloat scale = window.backingScaleFactor ?: 1;
    NSRect viewRectInScreen = [window convertRectToScreen:[view convertRect:[view bounds] toView:nil]];
    NSRect windowFrame = [window frame];

    // The captured image is top-left origin in backing pixels; map the (bottom-left origin,
    // points) view rect into it relative to the window frame.
    CGRect cropRectPx;
    cropRectPx.origin.x = (NSMinX(viewRectInScreen) - NSMinX(windowFrame)) * scale;
    cropRectPx.origin.y = (NSMaxY(windowFrame) - NSMaxY(viewRectInScreen)) * scale;
    cropRectPx.size.width = NSWidth(viewRectInScreen) * scale;
    cropRectPx.size.height = NSHeight(viewRectInScreen) * scale;
    if (cropRectPx.size.width < 1 || cropRectPx.size.height < 1)
        return nullptr;

    RetainPtr<CGImageRef> croppedSnapshotImage = adoptCF(CGImageCreateWithImageInRect(windowSnapshotImage.get(), cropRectPx));
    if (!croppedSnapshotImage)
        return nullptr;

    auto surface = WebCore::IOSurface::createFromImage(nullptr, croppedSnapshotImage.get());
    if (!surface)
        return nullptr;

    return ViewSnapshot::create(WTF::move(surface));
}

RefPtr<ViewSnapshot> MinimalPageClient::takeViewSnapshot(std::optional<WebCore::IntRect>&&)
{ return captureMinimalViewSnapshot(m_view); }
#endif
#if PLATFORM(MAC)
RefPtr<ViewSnapshot> MinimalPageClient::takeViewSnapshot(std::optional<WebCore::IntRect>&&, ForceSoftwareCapturingViewportSnapshot)
{ return captureMinimalViewSnapshot(m_view); }
#endif
#if USE(APPKIT)
void MinimalPageClient::setPromisedDataForImage(const String& pasteboardName, Ref<WebCore::FragmentedSharedBuffer>&& imageBuffer, const String& filename, const String& extension, const String& title, const String& url, const String& visibleURL, RefPtr<WebCore::FragmentedSharedBuffer>&& archiveBuffer, const String& originIdentifier)
{ }
#endif
WebCore::IntPoint MinimalPageClient::accessibilityScreenToRootView(const WebCore::IntPoint&)
{ return { }; }
WebCore::IntRect MinimalPageClient::rootViewToAccessibilityScreen(const WebCore::IntRect&)
{ return { }; }
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::relayAccessibilityNotification(String&&, RetainPtr<NSData>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::relayAriaNotifyNotification(const WebCore::AriaNotifyData&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::relayLiveRegionNotification(const WebCore::LiveRegionAnnouncementData&)
{ }
#endif
#if ENABLE(TWO_PHASE_CLICKS)
void MinimalPageClient::didNotHandleTapAsClick(const WebCore::IntPoint&)
{ }
#endif
void MinimalPageClient::doneWithKeyEvent(const NativeWebKeyboardEvent& event, bool wasEventHandled)
{
    // MAVERICKS_BACKPORT: mirror WebViewImpl::doneWithKeyEvent — hide the cursor while typing,
    // and re-dispatch unhandled key-downs to AppKit so Safari's menu key equivalents still fire
    // after the page declined them in -[WKView performKeyEquivalent:].
    NSEvent *nativeEvent = event.nativeEvent();
    if (!nativeEvent || [nativeEvent type] != NSEventTypeKeyDown)
        return;
    if (wasEventHandled) {
        [NSCursor setHiddenUntilMouseMoves:YES];
        return;
    }
    if ([m_view respondsToSelector:@selector(_mavericksResendUnhandledKeyDownEvent:)])
        [m_view _mavericksResendUnhandledKeyDownEvent:nativeEvent];
}
#if ENABLE(TOUCH_EVENTS)
void MinimalPageClient::doneWithTouchEvent(const WebTouchEvent&, bool wasEventHandled)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MinimalPageClient::doneDeferringTouchStart(bool preventNativeGestures)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MinimalPageClient::doneDeferringTouchMove(bool preventNativeGestures)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MinimalPageClient::doneDeferringTouchEnd(bool preventNativeGestures)
{ }
#endif
RefPtr<WebPopupMenuProxy> MinimalPageClient::createPopupMenuProxy(WebPageProxy& page)
{
    // Back the WKView path's <select> dropdowns with the standard AppKit popup proxy
    // (PageClientImpl does the same); the previous {} stub left native popups blank.
    return WebPopupMenuProxyMac::create(m_view, protect(page.popupMenuClient()));
}
#if ENABLE(CONTEXT_MENUS)
Ref<WebContextMenuProxy> MinimalPageClient::createContextMenuProxy(WebPageProxy& page, FrameInfoData&& frameInfo, ContextMenuContextData&& context, const UserData& userData)
{
    // Back right-click / control-click menus with the standard AppKit context-menu proxy.
    // The previous RELEASE_ASSERT_NOT_REACHED() stub trapped (SIGILL) the UIProcess on
    // every context-menu request, since WKView's page client is MinimalPageClient.
    return WebContextMenuProxyMac::create(m_view, page, WTF::move(frameInfo), WTF::move(context), userData);
}
#endif
RefPtr<WebColorPicker> MinimalPageClient::createColorPicker(WebPageProxy& page, const WebCore::Color& initialColor, const WebCore::IntRect& rect, ColorControlSupportsAlpha supportsAlpha, Vector<WebCore::Color>&& suggestions, std::optional<WebCore::FrameIdentifier>)
{
    // MAVERICKS_BACKPORT: was a `{ return { }; }` stub, so clicking an <input type=color> produced
    // no picker. WKView's page client is MinimalPageClient; mirror PageClientImplMac and vend a real
    // NSColorPanel-backed WebColorPickerMac so the native color picker opens.
    return WebColorPickerMac::create(protect(page.colorPickerClient()).ptr(), initialColor, rect, supportsAlpha, WTF::move(suggestions), m_view);
}
RefPtr<WebDataListSuggestionsDropdown> MinimalPageClient::createDataListSuggestionsDropdown(WebPageProxy&)
{ return { }; }
RefPtr<WebDateTimePicker> MinimalPageClient::createDateTimePicker(WebPageProxy&)
{ return { }; }
#if PLATFORM(COCOA) || PLATFORM(GTK)
Ref<WebCore::ValidationBubble> MinimalPageClient::createValidationBubble(String&& message, const WebCore::ValidationBubble::Settings& settings)
{
    // HTML form-validation bubbles (e.g. a required field left empty on submit) reach here.
    // The previous RELEASE_ASSERT_NOT_REACHED() stub would have trapped the UIProcess.
    return WebCore::ValidationBubble::create(m_view, WTF::move(message), settings);
}
#endif
#if PLATFORM(COCOA)
CALayer *MinimalPageClient::textIndicatorInstallationLayer()
{ return { }; }
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::didPerformDictionaryLookup(const WebCore::DictionaryPopupInfo& info)
{
    // MAVERICKS_BACKPORT: the modern "Look Up" popover uses the Reveal framework, which does not
    // exist on 10.9 (ENABLE(REVEAL)=0, so WebCore's DictionaryLookup::showPopup is a no-op).
    // WebViewImpl is also absent on the standalone WKView. Present the classic definition panel
    // instead via -[NSView showDefinitionForAttributedString:atPoint:] (AppKit, 10.6+) — the same
    // panel stock Safari 7 used for the Look Up context-menu item. info.origin is the text baseline
    // origin in the view's (flipped) coordinate space.
    if (!m_view || info.text.isEmpty())
        return;
    // Prefer the font-scaled attributed string (carried for this panel — see DictionaryPopupInfo.h)
    // so the panel's text overlay matches the page text's size and baseline; the plain-text
    // fallback would render at the default font and misalign.
    RetainPtr<NSAttributedString> string = info.attributedString.nsAttributedString();
    if (!string)
        string = adoptNS([[NSAttributedString alloc] initWithString:info.text.createNSString().get()]);
    [m_view showDefinitionForAttributedString:string.get() atPoint:NSMakePoint(info.origin.x(), info.origin.y())];
}
#endif
#if HAVE(APP_ACCENT_COLORS)
WebCore::Color MinimalPageClient::accentColor()
{ return { }; }
#endif
#if HAVE(APP_ACCENT_COLORS)
#if PLATFORM(MAC)
bool MinimalPageClient::appUsesCustomAccentColor()
{ return { }; }
#endif
#endif
#if USE(DICTATION_ALTERNATIVES)
void MinimalPageClient::showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext)
{ }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::showCorrectionPanel(WebCore::AlternativeTextType, const WebCore::FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings)
{ }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText)
{ }
#endif
#if PLATFORM(MAC)
String MinimalPageClient::dismissCorrectionPanelSoon(WebCore::ReasonForDismissingAlternativeText)
{ return { }; }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::recordAutocorrectionResponse(WebCore::AutocorrectionResponse, const String& replacedString, const String& replacementString)
{ }
#endif
#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: recreate the WKView's mouse-tracking area with options matching the new
// scrollbar style (legacy scrollbars rely on tracking the mouse all the time, overlay scrollbars
// only need tracking while the window is key), mirroring PageClientImpl::
// recommendedScrollbarStyleDidChange. The tracking area — installed by the WKView designated
// initializer — is what delivers mouseMoved: to the view when it is not the window's first
// responder, which keeps cursor changes and CSS :hover working.
void MinimalPageClient::recommendedScrollbarStyleDidChange(WebCore::ScrollbarStyle newStyle)
{
    if (!m_view)
        return;
    NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect;
    options |= newStyle == WebCore::ScrollbarStyle::AlwaysVisible ? NSTrackingActiveAlways : NSTrackingActiveInKeyWindow;
    RetainPtr<NSArray> existingAreas = adoptNS([[m_view trackingAreas] copy]);
    for (NSTrackingArea *area in existingAreas.get())
        [m_view removeTrackingArea:area];
    RetainPtr<NSTrackingArea> trackingArea = adoptNS([[NSTrackingArea alloc] initWithRect:[m_view frame] options:options owner:m_view userInfo:nil]);
    [m_view addTrackingArea:trackingArea.get()];
}
#endif
#if PLATFORM(MAC)
void MinimalPageClient::handleControlledElementIDResponse(const String&)
{ }
#endif
#if PLATFORM(MAC)
CGRect MinimalPageClient::boundsOfLayerInLayerBackedWindowCoordinates(CALayer *) const
{ return { }; }
#endif
#if PLATFORM(MAC)
bool MinimalPageClient::useFormSemanticContext() const
{ return { }; }
#endif
#if PLATFORM(MAC)
NSView *MinimalPageClient::viewForPresentingRevealPopover() const
{ return { }; }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::showPlatformContextMenu(NSMenu *, WebCore::IntPoint)
{ }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::startWindowDrag()
{ }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::setShouldSuppressFirstResponderChanges(bool)
{ }
#endif
#if PLATFORM(MAC)
RetainPtr<NSView> MinimalPageClient::inspectorAttachmentView()
{ return { }; }
#endif
#if PLATFORM(MAC)
_WKRemoteObjectRegistry *MinimalPageClient::remoteObjectRegistry()
{ return { }; }
#endif
#if PLATFORM(MAC)
void MinimalPageClient::intrinsicContentSizeDidChange(const WebCore::IntSize& intrinsicContentSize)
{
    // MAVERICKS_BACKPORT: forward the web process's laid-out content size to the WKView's
    // auto-layout SPI so self-sizing embedders (Mail's message viewer) size to fit.
    [m_view _setIntrinsicContentSize:NSMakeSize(intrinsicContentSize.width(), intrinsicContentSize.height())];
}
#endif
#if PLATFORM(MAC)
void MinimalPageClient::registerInsertionUndoGrouping()
{
    // MAVERICKS_BACKPORT: coalesce typed-character insertions into proper undo groups
    // (so Cmd+Z removes a typing run, matching AppKit text fields) instead of no-op.
    WebCore::registerInsertionUndoGroupingWithUndoManager([m_view undoManager]);
}
#endif
#if PLATFORM(MAC)
void MinimalPageClient::setEditableElementIsFocused(bool)
{ }
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::scrollingNodeScrollViewDidScroll(WebCore::ScrollingNodeID)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::couldNotRestorePageState()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::restorePageState(std::optional<WebCore::FloatPoint> scrollPosition, const WebCore::FloatPoint& scrollOrigin, const WebCore::FloatBoxExtent& obscuredInsetsOnSave, double scale)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::restorePageCenterAndScale(std::optional<WebCore::FloatPoint> center, double scale)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::elementDidFocus(const FocusedElementInformation&, bool userIsInteracting, bool blurPreviousNode, OptionSet<WebCore::ActivityState> activityStateChanges, API::Object* userData)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::updateInputContextAfterBlurringAndRefocusingElement()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::didProgrammaticallyClearFocusedElement(WebCore::ElementContext&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::updateFocusedElementInformation(const FocusedElementInformation&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::elementDidBlur()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::focusedElementDidChangeInputMode(WebCore::InputMode)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::didUpdateEditorState()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
bool MinimalPageClient::isFocusingElement()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
bool MinimalPageClient::interpretKeyEvent(const NativeWebKeyboardEvent&, KeyEventInterpretationContext&&)
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::saveImageToLibrary(Ref<WebCore::SharedBuffer>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::showPlaybackTargetPicker(bool hasVideo, const WebCore::IntRect& elementRect, WebCore::RouteSharingPolicy, const String&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::showDataDetectorsUIForPositionInformation(const InteractionInformationAtPosition&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
double MinimalPageClient::minimumZoomScale() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::FloatRect MinimalPageClient::documentRect() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::scrollingNodeScrollViewWillStartPanGesture(WebCore::ScrollingNodeID)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::scrollingNodeScrollWillStartScroll(std::optional<WebCore::ScrollingNodeID>)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::scrollingNodeScrollDidEndScroll(std::optional<WebCore::ScrollingNodeID>)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
Vector<String> MinimalPageClient::mimeTypesWithCustomContentProviders()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::hardwareKeyboardAvailabilityChanged()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::showInspectorHighlight(const WebCore::InspectorOverlay::Highlight&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::hideInspectorHighlight()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::showInspectorIndication()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::hideInspectorIndication()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::enableInspectorNodeSearch()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::disableInspectorNodeSearch()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::handleAutocorrectionContext(const WebAutocorrectionContext&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
#if HAVE(UISCROLLVIEW_ASYNCHRONOUS_SCROLL_EVENT_HANDLING)
void MinimalPageClient::handleAsynchronousCancelableScrollEvent(WKBaseScrollView *, WKBEScrollViewScrollUpdate *, void (^completion)(BOOL handled))
{ }
#endif
#endif
#if PLATFORM(IOS_FAMILY)
bool MinimalPageClient::isSimulatingCompatibilityPointerTouches() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::FloatBoxExtent MinimalPageClient::computedObscuredInset() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::Color MinimalPageClient::contentViewBackgroundColor()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::Color MinimalPageClient::insertionPointColor()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
bool MinimalPageClient::isScreenBeingCaptured()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
String MinimalPageClient::sceneID()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
UIScreen *MinimalPageClient::screen()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::beginTextRecognitionForFullscreenVideo(WebCore::ShareableBitmap::Handle&&, AVPlayerViewController *)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MinimalPageClient::cancelTextRecognitionForFullscreenVideo(AVPlayerViewController *)
{ }
#endif
#if PLATFORM(COCOA)
void MinimalPageClient::positionInformationDidChange(const InteractionInformationAtPosition&)
{ }
#endif
#if ENABLE(FULLSCREEN_API)
WebFullScreenManagerProxyClient& MinimalPageClient::fullScreenManagerProxyClient()
{
    return m_fullScreenClient;
}
#endif
void MinimalPageClient::didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>)
{ }
void MinimalPageClient::navigationGestureDidBegin()
{ }
void MinimalPageClient::navigationGestureWillEnd(bool willNavigate, WebBackForwardListItem&)
{ }
void MinimalPageClient::navigationGestureDidEnd(bool willNavigate, WebBackForwardListItem&)
{ }
void MinimalPageClient::navigationGestureDidEnd()
{ }
void MinimalPageClient::willRecordNavigationSnapshot(WebBackForwardListItem&)
{ }
void MinimalPageClient::didRemoveNavigationGestureSnapshot()
{ }
void MinimalPageClient::didFirstVisuallyNonEmptyLayoutForMainFrame()
{ }
void MinimalPageClient::didFinishNavigation(API::Navigation*)
{ }
void MinimalPageClient::didFailNavigation(API::Navigation*)
{ }
void MinimalPageClient::didSameDocumentNavigationForMainFrame(SameDocumentNavigationType)
{ }
void MinimalPageClient::didChangeBackgroundColor()
{ }
#if PLATFORM(MAC)
void MinimalPageClient::didPerformImmediateActionHitTest(const WebHitTestResultData&, bool contentPreventsDefault, API::Object*)
{ }
#endif
#if PLATFORM(MAC)
NSObject *MinimalPageClient::immediateActionAnimationControllerForHitTestResult(RefPtr<API::HitTestResult>, uint64_t, RefPtr<API::Object>)
{ return { }; }
#endif
#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)
WebCore::WebMediaSessionManager& MinimalPageClient::mediaSessionManager()
{ return WebCore::WebMediaSessionManager::singleton(); }
#endif
void MinimalPageClient::didRestoreScrollPosition()
{ }
WebCore::UserInterfaceLayoutDirection MinimalPageClient::userInterfaceLayoutDirection()
{ return { }; }
#if USE(QUICK_LOOK)
void MinimalPageClient::requestPasswordForQuickLookDocument(const String& fileName, WTF::Function<void(const String&)>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
void MinimalPageClient::willReceiveEditDragSnapshot()
{ }
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
void MinimalPageClient::didReceiveEditDragSnapshot(RefPtr<WebCore::TextIndicator>&&)
{ }
#endif
#if ENABLE(MODEL_PROCESS)
void MinimalPageClient::didReceiveInteractiveModelElement(std::optional<WebCore::NodeIdentifier>)
{ }
#endif
void MinimalPageClient::requestDOMPasteAccess(WebCore::DOMPasteAccessCategory, WebCore::DOMPasteRequiresInteraction, const WebCore::IntRect& elementRect, const String& originIdentifier, CompletionHandler<void(WebCore::DOMPasteAccessResponse)>&&)
{ }
#if USE(WPE_RENDERER)
UnixFileDescriptor MinimalPageClient::hostFileDescriptor()
{ return { }; }
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
bool MinimalPageClient::canHandleContextMenuTranslation() const
{ return { }; }
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
void MinimalPageClient::handleContextMenuTranslation(const WebCore::TranslationContextMenuInfo&)
{ }
#endif
#if ENABLE(WRITING_TOOLS) && ENABLE(CONTEXT_MENUS)
bool MinimalPageClient::canHandleContextMenuWritingTools() const
{ return { }; }
#endif
#if ENABLE(WRITING_TOOLS)
void MinimalPageClient::proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(const WebCore::WritingTools::TextSuggestionID&, WebCore::IntRect selectionBoundsInRootView)
{ }
#endif
#if USE(GRAPHICS_LAYER_WC)
bool MinimalPageClient::usesOffscreenRendering() const
{ return { }; }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MinimalPageClient::didEnterFullscreen()
{ }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MinimalPageClient::didExitFullscreen()
{ }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MinimalPageClient::didCleanupFullscreen()
{ }
#endif
#if PLATFORM(GTK) || PLATFORM(WPE)
WebKitWebResourceLoadManager* MinimalPageClient::webResourceLoadManager()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
UIViewController *MinimalPageClient::presentingViewController() const
{ return { }; }
#endif
#if HAVE(SPATIAL_TRACKING_LABEL)
String MinimalPageClient::spatialTrackingLabel() const
{ return { }; }
#endif

// ===== Free functions used by WKView =====

std::unique_ptr<PageClient> createMinimalPageClient(NSView *view)
{
    return std::unique_ptr<PageClient>(new MinimalPageClient(view));
}

void setMinimalPageClientPage(PageClient& client, WebPageProxy* page)
{
    static_cast<MinimalPageClient&>(client).setPage(page);
}

void setMinimalPageClientForceVisibleWhenWindowless(PageClient& client, bool force)
{
    static_cast<MinimalPageClient&>(client).setForceVisibleWhenWindowless(force);
}

void minimalPageClientViewDidMoveToWindow(PageClient& client)
{
    static_cast<MinimalPageClient&>(client).viewDidMoveToWindow();
}

} // namespace WebKit

#endif // PLATFORM(MAC)
