// MavericksPageClient — PageClient backing WKView on the MAVERICKS_BACKPORT.
//
// Safari 7 drives WebKit2 through WKView (an NSView), not WKWebView, so WKView creates its
// WebPageProxy with this PageClient in place of the upstream WKWebView + WebViewImpl +
// PageClientImpl stack (PageClientImpl is `final` and tightly coupled to WebViewImpl). It inherits
// the Cocoa-common behavior from PageClientImplCocoa and implements the view-geometry, layer
// hosting (TiledCoreAnimation), and coordinate-transform pieces directly against the backing
// NSView; the remaining PageClient surface is stubbed.
//
// The free functions at the bottom of this file are WKViewMavericks.mm's entry points into it.

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
#import "WebDataListSuggestionsDropdownMac.h"
#import "WebDateTimePickerMac.h"
#import "WebContextMenuProxyMac.h"
#import "WebPageProxy.h"
#import "WindowServerConnection.h"
#import "WebPopupMenuProxyMac.h"
#import "WebProcessProxy.h"
#import "WebEditCommandProxy.h"
#import "UndoOrRedo.h"
#import "EditorState.h"
#import "WKEditCommand.h"

// MAVERICKS_BACKPORT: WKView's promised-file drag entry point, implemented in WKViewMavericks.mm.
// An internal bridge between this page client and its view, not Safari-7-facing SPI, so it is
// declared here. setPromisedDataForImage below is the only caller.
@interface NSView (WKViewPromisedImageData)
- (void)_wkSetPromisedImageData:(NSData *)imageData uti:(NSString *)uti filename:(NSString *)filename url:(NSString *)url archiveBuffer:(NSData *)archiveData pasteboardName:(NSString *)pasteboardName;
@end
#import <WebCore/CGWindowUtilities.h>
#import <WebCore/ColorCocoa.h> // MAVERICKS_BACKPORT: colorFromCocoaColor, for accentColor() below.
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
#if USE(AUTOCORRECTION_PANEL)
// MAVERICKS_BACKPORT: the autocorrection bubble, held as a member below.
#import "CorrectionPanel.h"
#endif
// MAVERICKS_BACKPORT: the WKView full-screen path drives this upstream controller (see the
// MavericksFullScreenManagerProxyClient comment), the same one the WKWebView path uses.
#import "WKFullScreenWindowController.h"
// MAVERICKS_BACKPORT: declares -[WKView createFullScreenWindow], sent below to the NSView-typed view.
#import "WKViewPrivate.h"
// MAVERICKS_BACKPORT: the swipe/magnification controller the WKView owns, forwarded to below.
#import "ViewGestureController.h"
// MAVERICKS_BACKPORT: the content-relative child windows dismissed on navigation and swipe-back.
#import <WebCore/TextIndicator.h>
#import <pal/mac/DataDetectorsSoftLink.h>
#import <pal/spi/cocoa/NSAccessibilitySPI.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

// MAVERICKS_BACKPORT: -[WKView _wkExistingGestureController] (WKViewMavericks.mm) reports the
// controller without creating one, as WebViewImpl::gestureController() does.
@interface NSView (WKViewMavericksGestureController)
- (WebKit::ViewGestureController *)_wkExistingGestureController;
- (void)_wkClearPromisedDragImage;
@end
#endif
// MAVERICKS_BACKPORT: the pieces navigator.clipboard's permission menu needs (see requestDOMPasteAccess).
#import <WebCore/LocalizedStrings.h>
#import <WebCore/PasteboardCustomData.h>
#import <WebCore/SharedBuffer.h>
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
#import <pal/spi/mac/NSApplicationSPI.h> // MAVERICKS_BACKPORT: -[NSApplication _effectiveAccentColor], for accentColor() below.
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <wtf/RetainPtr.h>
#import <wtf/SortedArrayMap.h>
// MAVERICKS_BACKPORT: BEGIN/END_BLOCK_OBJC_EXCEPTIONS around the constraint re-activation the
// full-screen client performs, and objc_getClass for the autoresizing-constraint test it filters
// with (both mirroring WKFullScreenWindowController).
#import <objc/runtime.h>
#import <wtf/BlockObjCExceptions.h>

// MAVERICKS_BACKPORT: layer-HOSTING subview for the WebContent render layer (the Safari-537
// WKView "_layerHostingView"/WKFlippedView design; see the m_layerHostingView member comment).
// Flipped to match WKView's coordinate system. Event-transparent: hit-testing returns nil so
// mouse events land on the WKView itself.
@interface WKMavericksLayerHostingView : NSView
@end

@implementation WKMavericksLayerHostingView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end


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

// MAVERICKS_BACKPORT: WKView's half of the WK2 remote-accessibility bridge, invoked from
// accessibilityWebProcessTokenReceived — it turns the WebContent process's token into the
// NSAccessibilityRemoteUIElement the view vends as its accessibility child.
@interface NSView (WKViewRemoteAccessibility)
- (void)_mavericksSetAccessibilityWebProcessToken:(NSData *)token processIdentifier:(pid_t)pid;
- (void)_mavericksUpdateRemoteAccessibilityRegistration:(BOOL)registerProcess;
- (void)_mavericksRegisterUIProcessAccessibilityTokens;
@end

// MAVERICKS_BACKPORT: 10.9 AppKit SPI consulted by viewLayerHostingMode() — whether the window's
// layer tree is composited by the WindowServer (every normal window) or in-process (iBooks'
// reader window returns NO).
@interface NSWindow (WKHostsLayersInWindowServer)
- (BOOL)_hostsLayersInWindowServer;
@end

namespace WebKit {

// MAVERICKS_BACKPORT: capture the on-screen window content, cropped to a view, for the ViewSnapshot
// capture below (back/forward swipe snapshots and Safari's Top Sites thumbnails). The same capture
// WebViewImpl::takeViewSnapshot performs, via CGWindowListCreateImage + AppKit coordinates instead of
// the private CGS hardware-capture path.
static RetainPtr<CGImageRef> cropWindowCaptureToView(NSView *view)
{
    if (!view)
        return nullptr;
    NSWindow *window = [view window];
    if (!window || ![window isVisible])
        return nullptr;
    CGWindowID windowID = (CGWindowID)[window windowNumber];
    if (!windowID)
        return nullptr;

    CGWindowImageOption imageOptions = kCGWindowImageBoundsIgnoreFraming | kCGWindowImageShouldBeOpaque;
    RetainPtr<CGImageRef> windowSnapshotImage = WebCore::cgWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, windowID, imageOptions);
    if (!windowSnapshotImage)
        return nullptr;

    CGFloat scale = [window backingScaleFactor] ?: 1;
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

    return adoptCF(CGImageCreateWithImageInRect(windowSnapshotImage.get(), cropRectPx));
}

#if ENABLE(FULLSCREEN_API)
// MAVERICKS_BACKPORT: element/video full screen for the WKView client, held as a member of the page
// client. It forwards to this tree's WKFullScreenWindowController — the same controller the WKWebView
// path uses — method for method, as PageClientImpl does.
//
// The controller gives the full-screen window a SPACE of its own, which keeps the browser window and
// its other tabs reachable one space over so a page cannot strand the user; see
// github.com/Wowfunhappy/WebKit/issues/48, and mavericksLionStyleFullScreenEnabled() in
// WKFullScreenWindowController.mm for that issue's opt-out.
//
// The host window comes from -[WKView createFullScreenWindow], the Safari 7 SPI that lets the host
// post-process it: Safari overrides that method, calls super, and applies its own layer backing
// properties to whatever comes back.
class MavericksFullScreenManagerProxyClient final : public WebFullScreenManagerProxyClient {
public:
    ~MavericksFullScreenManagerProxyClient() { closeController(); }

    void closeFullScreenManager() final { closeController(); }

    bool isFullScreen() final { return m_controller && [m_controller isFullScreen]; }

    void enterFullScreen(WebCore::FloatSize, CompletionHandler<void(bool)>&& completionHandler) final
    {
        if (RetainPtr controller = ensureController())
            [controller enterFullScreen:WTF::move(completionHandler)];
        else
            completionHandler(false);
    }

#if ENABLE(QUICKLOOK_FULLSCREEN)
    void updateImageSource() final { }
#endif

    void exitFullScreen(CompletionHandler<void()>&& completionHandler) final
    {
        if (RetainPtr controller = ensureController())
            [controller exitFullScreen:WTF::move(completionHandler)];
        else
            completionHandler();
    }

    void beganEnterFullScreen(const WebCore::IntRect& initialFrame, const WebCore::IntRect& finalFrame, CompletionHandler<void(bool)>&& completionHandler) final
    {
        if (RetainPtr controller = ensureController())
            [controller beganEnterFullScreenWithInitialFrame:initialFrame finalFrame:finalFrame completionHandler:WTF::move(completionHandler)];
        else
            completionHandler(false);
    }

    void beganExitFullScreen(const WebCore::IntRect& initialFrame, const WebCore::IntRect& finalFrame, CompletionHandler<void()>&& completionHandler) final
    {
        if (RetainPtr controller = ensureController())
            [controller beganExitFullScreenWithInitialFrame:initialFrame finalFrame:finalFrame completionHandler:WTF::move(completionHandler)];
        else
            completionHandler();
    }

    // The view Safari 7 asks for through -[WKView fullScreenPlaceholderView], which it installs in the
    // tab's content container in the web view's place for the duration of the session.
    NSView *placeholderView() const
    {
        if (!m_controller || ![m_controller isFullScreen])
            return nil;
        // WebCoreFullScreenPlaceholderView is only forward-declared here; it is an NSView subclass.
        return (NSView *)[m_controller webViewPlaceholder];
    }

    NSView *m_view { nullptr };
    WeakPtr<WebPageProxy> m_page;

private:
    WKFullScreenWindowController *ensureController()
    {
        if (m_controller)
            return m_controller.get();
        RefPtr page = m_page.get();
        if (!page || !m_view)
            return nil;
        // MAVERICKS_BACKPORT: -createFullScreenWindow is WKView's SPI and m_view is typed NSView, so
        // name the real receiver here. The view is always the WKView that createMavericksPageClient()
        // was handed, which checked_objc_cast asserts.
        RetainPtr<NSWindow> window = [checked_objc_cast<WKView>(m_view) createFullScreenWindow];
        if (!window)
            return nil;
        m_controller = adoptNS([[WKFullScreenWindowController alloc] initWithWindow:window.get() webView:m_view page:*page]);
        return m_controller.get();
    }

    void closeController()
    {
        if (!m_controller)
            return;
        [m_controller close];
        m_controller = nil;
    }

    RetainPtr<WKFullScreenWindowController> m_controller;
};
#endif

class MavericksPageClient final : public PageClientImplCocoa {
public:
    explicit MavericksPageClient(NSView *view)
        : PageClientImplCocoa(nil)
        , m_view(view)
        , m_undoTarget(adoptNS([[WKEditorUndoTarget alloc] init]))
    {
#if ENABLE(FULLSCREEN_API)
        m_fullScreenClient.m_view = view;
#endif
    }

    // MAVERICKS_BACKPORT: the popovers and panels anchored to page content, dismissed together when
    // the content under them goes away (WebViewImpl::dismissContentRelativeChildWindowsFromViewOnly).
    void dismissContentRelativeChildWindows();

    // MAVERICKS_BACKPORT: the paste menu's delegate calls these back (see requestDOMPasteAccess).
    void handleDOMPasteRequestForCategoryWithResult(WebCore::DOMPasteAccessCategory, WebCore::DOMPasteAccessResponse);
    void hideDOMPasteMenuWithResult(WebCore::DOMPasteAccessResponse);

    void setPage(WebPageProxy* page)
    {
        m_page = page;
#if ENABLE(FULLSCREEN_API)
        // MAVERICKS_BACKPORT: the full-screen client needs the page to ask the web process to
        // leave full screen when the user leaves the space behind WebKit's back.
        m_fullScreenClient.m_page = page;
#endif
    }
#if ENABLE(FULLSCREEN_API)
    NSView *fullScreenPlaceholderView() const { return m_fullScreenClient.placeholderView(); }
#endif
    void viewDidChangeBackingProperties();
    void setWindowOcclusionDetectionEnabled(bool enabled) { m_windowOcclusionDetectionEnabled = enabled; }
    bool windowOcclusionDetectionEnabled() const { return m_windowOcclusionDetectionEnabled; }
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
    bool isMainViewVisible() final;
    bool isViewVisibleOrOccluded() final;
    bool isVisuallyIdle() final;
    void didFirstLayerFlush(const LayerTreeContext&) final;
    void installRenderLayer(CALayer *); // MAVERICKS_BACKPORT: see the m_layerHostingView member comment.
#if ENABLE(TILED_CA_DRAWING_AREA)
    // MAVERICKS_BACKPORT: WebKit-537 parity — report which hosted-context flavor the view's
    // current window can display (see the implementation comment).
    LayerHostingMode viewLayerHostingMode() final;
#endif
    void processDidExit() final;
    // MAVERICKS_BACKPORT: give the WebContent pid's remote-UI registration back when the page closes,
    // as WebViewImpl does from the same hook — otherwise a closed page whose view outlives it leaks it.
    void pageClosed() final;
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
    void didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>) final;
    void navigationGestureDidBegin() final;
    void navigationGestureWillEnd(bool willNavigate, WebBackForwardListItem&) final;
    void navigationGestureDidEnd(bool willNavigate, WebBackForwardListItem&) final;
    void navigationGestureDidEnd() final;
    void willRecordNavigationSnapshot(WebBackForwardListItem&) final;
    void didRemoveNavigationGestureSnapshot() final;
    // MAVERICKS_BACKPORT: PageClient's default body is empty; the swipe snapshot needs this event.
    void didStartProvisionalLoadForMainFrame() final;
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
#if USE(AUTOCORRECTION_PANEL)
    // MAVERICKS_BACKPORT: the autocorrection bubble, as PageClientImplMac holds it.
    CorrectionPanel m_correctionPanel;
#endif
    // MAVERICKS_BACKPORT: the navigator.clipboard paste-permission menu and the reply it owes the
    // web process, as WebViewImpl holds them.
    RetainPtr<NSMenu> m_domPasteMenu;
    RetainPtr<NSObject<NSMenuDelegate>> m_domPasteMenuDelegate;
    CompletionHandler<void(WebCore::DOMPasteAccessResponse)> m_domPasteRequestHandler;
    RetainPtr<NSColorSpace> m_colorSpace;
    // Upstream's WebViewImpl default; -[WKView setWindowOcclusionDetectionEnabled:] carries the
    // embedder's choice through to isActiveViewVisible.
    bool m_windowOcclusionDetectionEnabled { true };
    RetainPtr<CALayer> m_rootLayer;
    // MAVERICKS_BACKPORT: dedicated layer-HOSTING subview carrying the WebContent render layer
    // (the Safari-537 WKView _layerHostingView design). The subview owns its layer via -setLayer:,
    // so the hosted content is independent of the WKView's own AppKit-owned backing layer.
    RetainPtr<NSView> m_layerHostingView;
    RetainPtr<WKEditorUndoTarget> m_undoTarget;
    bool m_inSecureInputState { false };
#if ENABLE(FULLSCREEN_API)
    MavericksFullScreenManagerProxyClient m_fullScreenClient;
#endif
};

// ===== Implemented PageClient surface =====

Ref<DrawingAreaProxy> MavericksPageClient::createDrawingAreaProxy(WebProcessProxy& process)
{
    return TiledCoreAnimationDrawingAreaProxy::create(*m_page, process);
}

WebCore::IntSize MavericksPageClient::viewSize()
{
    return WebCore::IntSize([m_view bounds].size);
}

bool MavericksPageClient::isViewWindowActive()
{
    NSWindow *window = [m_view window];
    return window && ([window isKeyWindow] || [window isMainWindow]);
}

bool MavericksPageClient::isViewFocused()
{
    NSWindow *window = [m_view window];
    return window && [window firstResponder] == m_view;
}

// MAVERICKS_BACKPORT: see the declaration comment; the WKView's window hosts permission sheets.
CocoaWindow *MavericksPageClient::platformWindow() const
{
    return [m_view window];
}

bool MavericksPageClient::isActiveViewVisible()
{
    // MAVERICKS_BACKPORT: upstream PageClientImpl::isViewVisible's truth table — window presence,
    // the view's own hidden-ancestor chain, window visibility, then window occlusion. The view's
    // own isHidden matters here: Safari hides the BrowserWKView itself (not an ancestor) behind the
    // Reader view, and -viewDidHide/-viewDidUnhide forwarding recomputes activity state on every
    // toggle. WKView observes NSWindowDidChangeOcclusionStateNotification to recompute this.
    if (!m_view)
        return false;
    NSWindow *window = [m_view window];
    if (!window)
        return false;
    if ([m_view isHiddenOrHasHiddenAncestor])
        return false;
    if (![window isVisible])
        return false;
    if (m_windowOcclusionDetectionEnabled && (window.occlusionState & NSWindowOcclusionStateVisible) != NSWindowOcclusionStateVisible)
        return false;
    return true;
}

bool MavericksPageClient::isMainViewVisible()
{
    return isActiveViewVisible();
}

bool MavericksPageClient::isViewVisibleOrOccluded()
{
    // MAVERICKS_BACKPORT: upstream truth table (PageClientImpl::isViewVisibleOrOccluded) — window
    // visibility alone; an occluded window, an inactive-Space window, and a hidden view inside a
    // visible window all count as visible-or-occluded.
    return m_view && [[m_view window] isVisible];
}

bool MavericksPageClient::isViewInWindow()
{
    return m_view && [m_view window];
}

bool MavericksPageClient::isVisuallyIdle()
{
    return WindowServerConnection::singleton().applicationWindowModificationsHaveStopped() || !isActiveViewVisible();
}

bool MavericksPageClient::canTakeForegroundAssertions()
{
    return true;
}

// MAVERICKS_BACKPORT: the colour space the page composites in, chosen exactly as WebViewImpl does
// for WKWebView — the view's window, else the main screen, else sRGB.
WebCore::DestinationColorSpace MavericksPageClient::colorSpace()
{
    if (!m_colorSpace) {
        m_colorSpace = [[m_view window] colorSpace];

        if (!m_colorSpace)
            m_colorSpace = [NSScreen mainScreen].colorSpace;

        if (!m_colorSpace)
            m_colorSpace = [NSColorSpace sRGBColorSpace];
    }

    return WebCore::DestinationColorSpace { [m_colorSpace CGColorSpace] };
}

// MAVERICKS_BACKPORT: sent by WKView when AppKit reports new backing properties, which is where a
// window that moved to a display with a different profile shows up. Same shape as
// WebViewImpl::viewDidChangeBackingProperties.
void MavericksPageClient::viewDidChangeBackingProperties()
{
    RetainPtr<NSColorSpace> colorSpace = [[m_view window] colorSpace];
    if ([colorSpace isEqualTo:m_colorSpace.get()])
        return;

    m_colorSpace = nullptr;
    if (RefPtr drawingArea = m_page ? m_page->drawingArea() : nullptr)
        drawingArea->colorSpaceDidChange();
}

WebCore::FloatRect MavericksPageClient::convertToDeviceSpace(const WebCore::FloatRect& rect)
{
    return rect;
}

WebCore::FloatRect MavericksPageClient::convertToUserSpace(const WebCore::FloatRect& rect)
{
    return rect;
}

WebCore::IntPoint MavericksPageClient::screenToRootView(const WebCore::IntPoint& point)
{
    NSWindow *window = [m_view window];
    if (!window)
        return point;
    NSPoint windowPoint = [window convertRectFromScreen:NSMakeRect(point.x(), point.y(), 0, 0)].origin;
    NSPoint viewPoint = [m_view convertPoint:windowPoint fromView:nil];
    return WebCore::IntPoint(static_cast<int>(viewPoint.x), static_cast<int>(viewPoint.y));
}

WebCore::IntPoint MavericksPageClient::rootViewToScreen(const WebCore::IntPoint& point)
{
    NSWindow *window = [m_view window];
    if (!window)
        return point;
    NSPoint windowPoint = [m_view convertPoint:NSMakePoint(point.x(), point.y()) toView:nil];
    NSRect screenRect = [window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 0, 0)];
    return WebCore::IntPoint(static_cast<int>(screenRect.origin.x), static_cast<int>(screenRect.origin.y));
}

WebCore::IntRect MavericksPageClient::rootViewToScreen(const WebCore::IntRect& rect)
{
    NSWindow *window = [m_view window];
    NSRect viewRect = [m_view convertRect:NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height()) toView:nil];
    if (!window)
        return rect;
    NSRect screenRect = [window convertRectToScreen:viewRect];
    return WebCore::IntRect(static_cast<int>(screenRect.origin.x), static_cast<int>(screenRect.origin.y), static_cast<int>(screenRect.size.width), static_cast<int>(screenRect.size.height));
}

WebCore::IntRect MavericksPageClient::rootViewToWindow(const WebCore::IntRect& rect)
{
    NSRect windowRect = [m_view convertRect:NSMakeRect(rect.x(), rect.y(), rect.width(), rect.height()) toView:nil];
    return WebCore::IntRect(static_cast<int>(windowRect.origin.x), static_cast<int>(windowRect.origin.y), static_cast<int>(windowRect.size.width), static_cast<int>(windowRect.size.height));
}

void MavericksPageClient::makeFirstResponder()
{
    [[m_view window] makeFirstResponder:m_view];
}

void MavericksPageClient::refView()
{
    [m_view retain];
}

void MavericksPageClient::derefView()
{
    [m_view release];
}

// MAVERICKS_BACKPORT: install `renderLayer` as the sole sublayer of a dedicated layer-HOSTING
// subview of the WKView (the Safari-537 _layerHostingView design; stock 537
// _setAcceleratedCompositingModeRootLayer: is this same shape). The subview owns its layer via
// -setLayer:, keeping the hosted content independent of the WKView's AppKit-owned backing
// layer. Like 537, the render layer gets no frame: its (0,0) anchors the remote layer tree to
// the hosting view's top-left, and the web-process side sizes the content.
void MavericksPageClient::installRenderLayer(CALayer *renderLayer)
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
        m_layerHostingView = adoptNS([[WKMavericksLayerHostingView alloc] initWithFrame:[m_view bounds]]);
        [m_layerHostingView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        RetainPtr<CALayer> hostingRootLayer = adoptNS([[CALayer alloc] init]);
        [m_layerHostingView setLayer:hostingRootLayer.get()];
        [m_layerHostingView setWantsLayer:YES];
        [m_view addSubview:m_layerHostingView.get() positioned:NSWindowBelow relativeTo:nil];
    }
    [m_layerHostingView layer].sublayers = @[ renderLayer ];
}

void MavericksPageClient::enterAcceleratedCompositingMode(const LayerTreeContext& context)
{
    RetainPtr<CALayer> renderLayer = [CALayer _web_renderLayerWithContextID:context.contextID shouldPreserveFlip:NO];
    installRenderLayer(renderLayer.get());
}

void MavericksPageClient::updateAcceleratedCompositingMode(const LayerTreeContext& context)
{
    enterAcceleratedCompositingMode(context);
}

void MavericksPageClient::exitAcceleratedCompositingMode()
{
    installRenderLayer(nil);
}

void MavericksPageClient::didFirstLayerFlush(const LayerTreeContext& context)
{
    if (!context.isEmpty())
        enterAcceleratedCompositingMode(context);
}

#if ENABLE(TILED_CA_DRAWING_AREA)
// MAVERICKS_BACKPORT: WebKit-537 parity. On 10.9 a CALayerHost only displays a hosted context
// whose flavor matches how its window composites layers: windows hosting their layer tree in the
// WindowServer (every normal window, and the default for windowless views) display
// CGS-connection contexts; windows compositing in-process ([NSWindow _hostsLayersInWindowServer]
// == NO — iBooks' reader window is the one known case) display only contexts created against
// this process's CARemoteLayerServer port. WebPageProxy::viewDidEnterWindow() re-queries this on
// every window attach and tells the web process to recreate its context on a change.
LayerHostingMode MavericksPageClient::viewLayerHostingMode()
{
    NSWindow *window = [m_view window];
    if (window && ![window _hostsLayersInWindowServer])
        return LayerHostingMode::InProcess;
    return LayerHostingMode::InWindowServer;
}
#endif

void MavericksPageClient::setRemoteLayerTreeRootNode(RemoteLayerTreeNode* rootNode)
{
    installRenderLayer(rootNode ? rootNode->layer() : nil);
}

CALayer *MavericksPageClient::acceleratedCompositingRootLayer() const
{
    return m_rootLayer.get();
}

// ===== Stubs for the remaining PageClient surface =====

void MavericksPageClient::setViewNeedsDisplay(const WebCore::Region&)
{ ASSERT_NOT_REACHED(); }
void MavericksPageClient::requestScroll(const WebCore::FloatPoint& scrollPosition, const WebCore::IntPoint& scrollOrigin, WebCore::ScrollIsAnimated, WebCore::InterruptScrollAnimation)
{ }
WebCore::FloatPoint MavericksPageClient::viewScrollPosition()
{ return { }; }
void MavericksPageClient::processDidExit()
{
    // MAVERICKS_BACKPORT: the remote accessibility element names the process that just exited, so
    // drop it and unregister the pid, as WebViewImpl does from the same hook.
    [m_view _mavericksUpdateRemoteAccessibilityRegistration:NO];
}
void MavericksPageClient::pageClosed()
{
    [m_view _mavericksUpdateRemoteAccessibilityRegistration:NO];
}
void MavericksPageClient::didRelaunchProcess()
{
    // MAVERICKS_BACKPORT: a relaunched WebContent process has a fresh accessibility root and knows
    // nothing about this view, so re-send the UI-process tokens (upstream's didRelaunchProcess does
    // exactly this).
    [m_view _mavericksRegisterUIProcessAccessibilityTokens];
}
void MavericksPageClient::preferencesDidChange()
{ }
void MavericksPageClient::toolTipChanged(const String&, const String& newToolTip)
{
    // MAVERICKS_BACKPORT: wire the title-attribute tooltip to WKView's classic -addToolTipRect:/
    // -view:stringForToolTip: mechanism (see -[WKView _wkSetToolTip:]); the reimplemented WKView does
    // not use WebViewImpl's NSToolTipManager path.
    if (m_view)
        [m_view _wkSetToolTip:newToolTip.createNSString().get()];
}
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::decidePolicyForGeolocationPermissionRequest(WebFrameProxy&, const FrameInfoData&, Function<void(bool)>&)
{ }
#endif
// MAVERICKS_BACKPORT: WebViewImpl::updateSupportsArbitraryLayoutModes and ::pageDidScroll are the
// WKWebView layout-mode SPI and the hasScrolledContentsUnderTitlebar KVO, neither of which a WKView has.
void MavericksPageClient::didCommitLoadForMainFrame(const String&, bool)
{
    dismissContentRelativeChildWindows();
    [m_view _wkClearPromisedDragImage];
}
#if ENABLE(PDF_HUD)
void MavericksPageClient::createPDFHUD(PDFPluginIdentifier, WebCore::FrameIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_HUD)
void MavericksPageClient::updatePDFHUDLocation(PDFPluginIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_HUD)
void MavericksPageClient::removePDFHUD(PDFPluginIdentifier)
{ }
#endif
#if ENABLE(PDF_HUD)
void MavericksPageClient::removeAllPDFHUDs()
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MavericksPageClient::createPDFPageNumberIndicator(PDFPluginIdentifier, const WebCore::IntRect&, size_t pageCount)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MavericksPageClient::updatePDFPageNumberIndicatorLocation(PDFPluginIdentifier, const WebCore::IntRect&)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MavericksPageClient::updatePDFPageNumberIndicatorCurrentPage(PDFPluginIdentifier, size_t pageIndex)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MavericksPageClient::removePDFPageNumberIndicator(PDFPluginIdentifier)
{ }
#endif
#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
void MavericksPageClient::removeAnyPDFPageNumberIndicator()
{ }
#endif
void MavericksPageClient::didChangeContentSize(const WebCore::IntSize&)
{ }
#if ENABLE(DRAG_SUPPORT)
#if PLATFORM(GTK)
void MavericksPageClient::startDrag(WebCore::SelectionData&&, OptionSet<WebCore::DragOperation>, RefPtr<WebCore::ShareableBitmap>&& dragImage, WebCore::IntPoint&& dragImageHotspot)
{ }
#endif
// MAVERICKS_BACKPORT: hand the OS drag session off to the WKView. Mirrors
// WebViewImpl::startDrag, except a promised-attachment drag is cancelled rather
// than attempted: the modern path carries that promise via NSFilePromiseProvider
// (10.12+), and WKView's classic promised-file pasteboard has no carrier for it.
void MavericksPageClient::startDrag(const WebCore::DragItem& item, WebCore::ShareableBitmap::Handle&& dragImageHandle, const std::optional<WebCore::NodeIdentifier>&, const std::optional<WebCore::FrameIdentifier>&)
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
void MavericksPageClient::setCursor(const WebCore::Cursor& cursor)
{
    // MAVERICKS_BACKPORT: WebCore asks the page client to change the cursor (hand over links, I-beam over
    // text, etc.). Mirrors PageClientImpl, minus the WebViewImpl-only image-analysis overlay check.
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
void MavericksPageClient::setCursorHiddenUntilMouseMoves(bool hiddenUntilMouseMoves)
{
    [NSCursor setHiddenUntilMouseMoves:hiddenUntilMouseMoves];
}
// MAVERICKS_BACKPORT: the WKView undo surface. The WebProcess sends RegisterEditCommandForUndo and
// WebPageProxy routes it here; register the command with the view's NSUndoManager so the standard
// undo:/redo: actions drive WebEditCommandProxy::unapply()/reapply(). Mirrors
// WebViewImpl/PageClientImplMac.
void MavericksPageClient::registerEditCommand(Ref<WebEditCommandProxy>&& command, UndoOrRedo undoOrRedo)
{
    auto actionName = command->label();
    auto commandObjC = adoptNS([[WKEditCommand alloc] initWithWebEditCommandProxy:WTF::move(command)]);

    RetainPtr undoManager = [m_view undoManager];
    [undoManager registerUndoWithTarget:m_undoTarget.get() selector:((undoOrRedo == UndoOrRedo::Undo) ? @selector(undoEditing:) : @selector(redoEditing:)) object:commandObjC.get()];
    if (!actionName.isEmpty())
        [undoManager setActionName:actionName.createNSString().get()];
}
void MavericksPageClient::clearAllEditCommands()
{
    [[m_view undoManager] removeAllActionsWithTarget:m_undoTarget.get()];
}
bool MavericksPageClient::canUndoRedo(UndoOrRedo undoOrRedo)
{
    RetainPtr undoManager = [m_view undoManager];
    return undoOrRedo == UndoOrRedo::Undo ? [undoManager canUndo] : [undoManager canRedo];
}
void MavericksPageClient::executeUndoRedo(UndoOrRedo undoOrRedo)
{
    RetainPtr undoManager = [m_view undoManager];
    undoOrRedo == UndoOrRedo::Undo ? [undoManager undo] : [undoManager redo];
}
void MavericksPageClient::wheelEventWasNotHandledByWebCore(const NativeWebWheelEvent& event)
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->wheelEventWasNotHandledByWebCore(event);
}
#if PLATFORM(COCOA)
// MAVERICKS_BACKPORT: hand the WebContent process's remote-accessibility token to WKView, which
// owns the NSAccessibilityRemoteUIElement that stands for the page in the UI process's AX tree
// (see the accessibility section of WKViewMavericks.mm). PageClientImpl routes this to
// WebViewImpl::setAccessibilityWebProcessToken the same way; WKView just is not backed by one.
void MavericksPageClient::accessibilityWebProcessTokenReceived(std::span<const uint8_t> data, pid_t pid)
{
    if (!m_view)
        return;
    RetainPtr<NSData> token = adoptNS([[NSData alloc] initWithBytes:data.data() length:data.size()]);
    [m_view _mavericksSetAccessibilityWebProcessToken:token.get() processIdentifier:pid];
}
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

bool MavericksPageClient::executeSavedCommandBySelector(const String& selector)
{
    // MAVERICKS_BACKPORT: the IPC fallback (WebPageProxy::executeSavedCommandBySelector ->
    // _web_superDoCommandBySelector:) lands on WKWebView's NSResponder action methods upstream, and
    // Safari's WKView has none — so resolve the scroll selector to its Editor command and execute it
    // on the page here, as those action methods would. Selectors outside the map are unhandled
    // (false) and bubble to Safari's own responder handling.
    if (!m_page)
        return false;
    String commandName = scrollCommandNameForSavedSelector(selector);
    if (commandName.isEmpty())
        return false;
    m_page->executeEditCommand(commandName, String());
    return true;
}
#endif
// MAVERICKS_BACKPORT: HIToolbox secure-event-input, forward-declared to keep <Carbon/Carbon.h> and
// its namespace pollution out of this file.
extern "C" OSStatus EnableSecureEventInput(void);
extern "C" OSStatus DisableSecureEventInput(void);

#if PLATFORM(COCOA)
// MAVERICKS_BACKPORT: enable secure event input while a web password field is focused — the
// keylogger protection AppKit gives native password fields. Mirrors
// WebViewImpl::updateSecureInputState; editorState().isInPasswordField is populated by
// WebPage.cpp from input->isPasswordField().
void MavericksPageClient::updateSecureInputState()
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
void MavericksPageClient::resetSecureInputState()
{
    if (m_inSecureInputState) {
        DisableSecureEventInput();
        m_inSecureInputState = false;
    }
}
#endif
#if PLATFORM(COCOA)
void MavericksPageClient::notifyInputContextAboutDiscardedComposition()
{
    // <rdar://problem/9359055>: -discardMarkedText can only be called for active contexts.
    if (![[m_view window] isKeyWindow] || m_view != [[m_view window] firstResponder])
        return;

    // Inform the input method that we won't have an inline input area despite having been asked to.
    [[m_view inputContext] discardMarkedText];
}
#endif
#if PLATFORM(COCOA)
void MavericksPageClient::assistiveTechnologyMakeFirstResponder()
{ [[m_view window] makeFirstResponder:m_view]; }
#endif
#if PLATFORM(COCOA)
#if ENABLE(MAC_GESTURE_EVENTS)
void MavericksPageClient::gestureEventWasNotHandledByWebCore(const NativeWebGestureEvent&)
{ }
#endif
#endif
#if PLATFORM(MAC)
CALayer *MavericksPageClient::headerBannerLayer() const
{ return { }; }
#endif
#if PLATFORM(MAC)
CALayer *MavericksPageClient::footerBannerLayer() const
{ return { }; }
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
// MAVERICKS_BACKPORT: WebViewImpl::selectionDidChange's other work is its own private state
// (m_softSpaceRange) and HAVE(TOUCH_BAR); the font-manager update reads only the page.
void MavericksPageClient::selectionDidChange()
{
    if (!m_page)
        return;

    BOOL fontPanelIsVisible = NSFontPanel.sharedFontPanelExists && NSFontPanel.sharedFontPanel.visible;
    if (!fontPanelIsVisible && !(m_page->isEditable() && m_page->editorState().isContentRichlyEditable))
        return;

    m_page->requestFontAttributesAtSelectionStart([] (auto& attributes) {
        if (!attributes.font)
            return;

        RetainPtr nsFont = (__bridge NSFont *)attributes.font->ctFont();
        if (!nsFont)
            return;

        [NSFontManager.sharedFontManager setSelectedFont:nsFont.get() isMultiple:attributes.hasMultipleFonts];
        [NSFontManager.sharedFontManager setSelectedAttributes:attributes.createDictionary().get() isMultiple:attributes.hasMultipleFonts];
    });
}
#endif
#if PLATFORM(COCOA) || PLATFORM(GTK) || PLATFORM(WPE)
// Wrap the WKView's on-screen content in a ViewSnapshot. ViewSnapshotStore feeds both
// back/forward swipe snapshots and Safari's Top Sites thumbnails; the capture itself is
// cropWindowCaptureToView above.
static RefPtr<ViewSnapshot> captureViewSnapshot(NSView *view)
{
    RetainPtr<CGImageRef> croppedSnapshotImage = cropWindowCaptureToView(view);
    if (!croppedSnapshotImage)
        return nullptr;

    auto surface = WebCore::IOSurface::createFromImage(nullptr, croppedSnapshotImage.get());
    if (!surface)
        return nullptr;

    return ViewSnapshot::create(WTF::move(surface));
}

RefPtr<ViewSnapshot> MavericksPageClient::takeViewSnapshot(std::optional<WebCore::IntRect>&&)
{ return captureViewSnapshot(m_view); }
#endif
#if PLATFORM(MAC)
RefPtr<ViewSnapshot> MavericksPageClient::takeViewSnapshot(std::optional<WebCore::IntRect>&&, ForceSoftwareCapturingViewportSnapshot)
{ return captureViewSnapshot(m_view); }
#endif
#if USE(APPKIT)
void MavericksPageClient::setPromisedDataForImage(const String& pasteboardName, Ref<WebCore::FragmentedSharedBuffer>&& imageBuffer, const String& filename, const String& extension, const String& title, const String& url, const String& visibleURL, RefPtr<WebCore::FragmentedSharedBuffer>&& archiveBuffer, const String& originIdentifier)
{
    // MAVERICKS_BACKPORT: hand the promise to WKView, which owns the drag pasteboard and serves
    // -pasteboard:provideDataForType: / -namesOfPromisedFilesDroppedAtDestination: (see the
    // promised-file section of WKViewMavericks.mm) — this hop is what puts the promise type on the
    // drag pasteboard, and with it dragging an image out of a page to the Finder produces the file.
    // PageClientImpl routes this to WebViewImpl the same way; WKView just is not backed by one.
    UNUSED_PARAM(title);
    UNUSED_PARAM(visibleURL);
    UNUSED_PARAM(originIdentifier);

    if (!m_view)
        return;

    RetainPtr imageData = imageBuffer->makeContiguous()->createNSData();
    RetainPtr archiveData = archiveBuffer ? archiveBuffer->makeContiguous()->createNSData() : RetainPtr<NSData> { };

    // The UTI the destination will ask for. WebCore gives us the filename extension; map it here rather
    // than carrying a WebCore::Image across, which is all WebViewImpl uses its copy for.
    RetainPtr uti = adoptCF(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension,
        extension.createCFString().get(), nullptr));

    [m_view _wkSetPromisedImageData:imageData.get()
                                uti:(__bridge NSString *)uti.get()
                           filename:filename.createNSString().get()
                                url:url.createNSString().get()
                      archiveBuffer:archiveData.get()
                     pasteboardName:pasteboardName.createNSString().get()];
}
#endif
WebCore::IntPoint MavericksPageClient::accessibilityScreenToRootView(const WebCore::IntPoint& point)
{ return screenToRootView(point); }
WebCore::IntRect MavericksPageClient::rootViewToAccessibilityScreen(const WebCore::IntRect& rect)
{ return rootViewToScreen(rect); }
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::relayAccessibilityNotification(String&&, RetainPtr<NSData>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::relayAriaNotifyNotification(const WebCore::AriaNotifyData&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::relayLiveRegionNotification(const WebCore::LiveRegionAnnouncementData&)
{ }
#endif
#if ENABLE(TWO_PHASE_CLICKS)
void MavericksPageClient::didNotHandleTapAsClick(const WebCore::IntPoint&)
{ }
#endif
void MavericksPageClient::doneWithKeyEvent(const NativeWebKeyboardEvent& event, bool wasEventHandled)
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
    [m_view _mavericksResendUnhandledKeyDownEvent:nativeEvent];
}
#if ENABLE(TOUCH_EVENTS)
void MavericksPageClient::doneWithTouchEvent(const WebTouchEvent&, bool wasEventHandled)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MavericksPageClient::doneDeferringTouchStart(bool preventNativeGestures)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MavericksPageClient::doneDeferringTouchMove(bool preventNativeGestures)
{ }
#endif
#if ENABLE(IOS_TOUCH_EVENTS)
void MavericksPageClient::doneDeferringTouchEnd(bool preventNativeGestures)
{ }
#endif
RefPtr<WebPopupMenuProxy> MavericksPageClient::createPopupMenuProxy(WebPageProxy& page)
{
    // Back the WKView path's <select> dropdowns with the standard AppKit popup proxy
    // (PageClientImpl does the same).
    return WebPopupMenuProxyMac::create(m_view, protect(page.popupMenuClient()));
}
#if ENABLE(CONTEXT_MENUS)
Ref<WebContextMenuProxy> MavericksPageClient::createContextMenuProxy(WebPageProxy& page, FrameInfoData&& frameInfo, ContextMenuContextData&& context, const UserData& userData)
{
    // Back right-click / control-click menus with the standard AppKit context-menu proxy
    // (PageClientImpl does the same).
    return WebContextMenuProxyMac::create(m_view, page, WTF::move(frameInfo), WTF::move(context), userData);
}
#endif
RefPtr<WebColorPicker> MavericksPageClient::createColorPicker(WebPageProxy& page, const WebCore::Color& initialColor, const WebCore::IntRect& rect, ColorControlSupportsAlpha supportsAlpha, Vector<WebCore::Color>&& suggestions, std::optional<WebCore::FrameIdentifier>)
{
    // MAVERICKS_BACKPORT: mirror PageClientImplMac — vend a real NSColorPanel-backed
    // WebColorPickerMac so clicking an <input type=color> opens the native color picker.
    return WebColorPickerMac::create(protect(page.colorPickerClient()).ptr(), initialColor, rect, supportsAlpha, WTF::move(suggestions), m_view);
}
RefPtr<WebDataListSuggestionsDropdown> MavericksPageClient::createDataListSuggestionsDropdown(WebPageProxy& page)
{
    // MAVERICKS_BACKPORT: mirror PageClientImplMac — vend the real AppKit dropdown so a datalist
    // input shows its suggestions.
    return WebDataListSuggestionsDropdownMac::create(page, m_view);
}
RefPtr<WebDateTimePicker> MavericksPageClient::createDateTimePicker(WebPageProxy& page)
{
    // MAVERICKS_BACKPORT: mirror PageClientImplMac — vend the real calendar picker for
    // <input type=date>.
    return WebDateTimePickerMac::create(page, m_view);
}
#if PLATFORM(COCOA) || PLATFORM(GTK)
Ref<WebCore::ValidationBubble> MavericksPageClient::createValidationBubble(String&& message, const WebCore::ValidationBubble::Settings& settings)
{
    // HTML form-validation bubbles (e.g. a required field left empty on submit) reach here.
    return WebCore::ValidationBubble::create(m_view, WTF::move(message), settings);
}
#endif
#if PLATFORM(COCOA)
CALayer *MavericksPageClient::textIndicatorInstallationLayer()
{
    // MAVERICKS_BACKPORT: the parent layer for every text indicator, most visibly the find
    // overlay's yellow highlight on the current match (#85). WebPageProxy::setTextIndicator adds
    // the WebTextIndicatorLayer as a sublayer of this layer, so it must belong to a live layer
    // tree: WKView hosts the WebContent render layer in a dedicated layer-hosting subview (see
    // installRenderLayer above), and the indicator goes into that same hosting layer — exactly
    // what WebViewImpl::textIndicatorInstallationLayer returns for WKWebView. Both hosting views
    // are flipped, so the root-view coordinates the indicator's frame is expressed in land right
    // side up.
    return [m_layerHostingView layer];
}
#endif
#if PLATFORM(COCOA)
void MavericksPageClient::didPerformDictionaryLookup(const WebCore::DictionaryPopupInfo& info)
{
    // MAVERICKS_BACKPORT: the modern "Look Up" popover uses the Reveal framework, which does not
    // exist on 10.9 (ENABLE(REVEAL)=0, so WebCore's DictionaryLookup::showPopup is a no-op).
    // WebViewImpl is also absent on the standalone WKView. Present the classic definition panel
    // instead via -[NSView showDefinitionForAttributedString:atPoint:] (AppKit, 10.6+) — the same
    // panel stock Safari 7's Look Up context-menu item presents. info.origin is the text baseline
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
WebCore::Color MavericksPageClient::accentColor()
{ return WebCore::colorFromCocoaColor([NSApp _effectiveAccentColor]); }
#endif
#if HAVE(APP_ACCENT_COLORS)
#if PLATFORM(MAC)
bool MavericksPageClient::appUsesCustomAccentColor()
{ return { }; }
#endif
#endif
#if USE(DICTATION_ALTERNATIVES)
void MavericksPageClient::showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext)
{ }
#endif
#if PLATFORM(MAC)
void MavericksPageClient::showCorrectionPanel(WebCore::AlternativeTextType type, const WebCore::FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings)
{
#if USE(AUTOCORRECTION_PANEL)
    if (m_page)
        m_correctionPanel.show(m_view, *m_page, type, boundingBoxOfReplacedString, replacedString, replacementString, alternativeReplacementStrings);
#endif
}
#endif
#if PLATFORM(MAC)
void MavericksPageClient::dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText reason)
{
#if USE(AUTOCORRECTION_PANEL)
    m_correctionPanel.dismiss(reason);
#endif
}
#endif
#if PLATFORM(MAC)
String MavericksPageClient::dismissCorrectionPanelSoon(WebCore::ReasonForDismissingAlternativeText reason)
{
#if USE(AUTOCORRECTION_PANEL)
    return m_correctionPanel.dismiss(reason);
#else
    return String();
#endif
}
#endif
#if PLATFORM(MAC)
void MavericksPageClient::recordAutocorrectionResponse(WebCore::AutocorrectionResponse response, const String& replacedString, const String& replacementString)
{
#if USE(AUTOCORRECTION_PANEL)
    if (!m_page)
        return;

    // MAVERICKS_BACKPORT: upstream's toCorrectionResponse is file-static in PageClientImplMac.mm,
    // which shares a unified source with this file, so the mapping is spelled out here.
    auto correctionResponse = [&] {
        switch (response) {
        case WebCore::AutocorrectionResponse::Reverted:
            return NSCorrectionResponseReverted;
        case WebCore::AutocorrectionResponse::Edited:
            return NSCorrectionResponseEdited;
        case WebCore::AutocorrectionResponse::Accepted:
            return NSCorrectionResponseAccepted;
        }

        ASSERT_NOT_REACHED();
        return NSCorrectionResponseAccepted;
    }();

    CorrectionPanel::recordAutocorrectionResponse(*m_page, m_page->spellDocumentTag(), correctionResponse, replacedString, replacementString);
#endif
}
#endif
#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: recreate the WKView's mouse-tracking area with options matching the new
// scrollbar style (legacy scrollbars rely on tracking the mouse all the time, overlay scrollbars
// only need tracking while the window is key), mirroring PageClientImpl::
// recommendedScrollbarStyleDidChange. The tracking area — installed by the WKView designated
// initializer — is what delivers mouseMoved: to the view when it is not the window's first
// responder, which keeps cursor changes and CSS :hover working.
void MavericksPageClient::recommendedScrollbarStyleDidChange(WebCore::ScrollbarStyle newStyle)
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
void MavericksPageClient::handleControlledElementIDResponse(const String&)
{ }
#endif
#if PLATFORM(MAC)
CGRect MavericksPageClient::boundsOfLayerInLayerBackedWindowCoordinates(CALayer *layer) const
{
    RetainPtr<CALayer> windowContentLayer = static_cast<NSView *>([[m_view window] contentView]).layer;
    ASSERT(windowContentLayer);

    return [windowContentLayer convertRect:layer.bounds fromLayer:layer];
}
#endif
#if PLATFORM(MAC)
bool MavericksPageClient::useFormSemanticContext() const
{ return { }; }
#endif
#if PLATFORM(MAC)
NSView *MavericksPageClient::viewForPresentingRevealPopover() const
{ return m_view; }
#endif
#if PLATFORM(MAC)
void MavericksPageClient::showPlatformContextMenu(NSMenu *menu, WebCore::IntPoint location)
{ [menu popUpMenuPositioningItem:nil atLocation:location inView:m_view]; }
#endif
#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: WebViewImpl passes the mouse-down it recorded; this client is only reached
// synchronously from that event's dispatch (InspectorFrontendHost.startWindowDrag off a mousedown
// listener, -webkit-app-region:drag), so the application's current event is that same event.
void MavericksPageClient::startWindowDrag()
{ [[m_view window] performWindowDragWithEvent:[NSApp currentEvent]]; }
#endif
#if PLATFORM(MAC)
void MavericksPageClient::setShouldSuppressFirstResponderChanges(bool)
{ }
#endif
#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: the view the Web Inspector docks alongside, as WebViewImpl reports it. WKView's
// _setInspectorAttachmentView: SPI postdates Safari 7, so the WKView is always the attachment view.
RetainPtr<NSView> MavericksPageClient::inspectorAttachmentView()
{ return m_view; }
#endif
#if PLATFORM(MAC)
_WKRemoteObjectRegistry *MavericksPageClient::remoteObjectRegistry()
{ return { }; }
#endif
#if PLATFORM(MAC)
void MavericksPageClient::intrinsicContentSizeDidChange(const WebCore::IntSize& intrinsicContentSize)
{
    // MAVERICKS_BACKPORT: forward the web process's laid-out content size to the WKView's
    // auto-layout SPI so self-sizing embedders (Mail's message viewer) size to fit.
    [m_view _setIntrinsicContentSize:NSMakeSize(intrinsicContentSize.width(), intrinsicContentSize.height())];
}
#endif
#if PLATFORM(MAC)
void MavericksPageClient::registerInsertionUndoGrouping()
{
    // MAVERICKS_BACKPORT: coalesce typed-character insertions into proper undo groups,
    // so Cmd+Z removes a typing run, matching AppKit text fields.
    WebCore::registerInsertionUndoGroupingWithUndoManager([m_view undoManager]);
}
#endif
#if PLATFORM(MAC)
void MavericksPageClient::setEditableElementIsFocused(bool)
{ }
#endif
#if PLATFORM(COCOA)
void MavericksPageClient::scrollingNodeScrollViewDidScroll(WebCore::ScrollingNodeID)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::couldNotRestorePageState()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::restorePageState(std::optional<WebCore::FloatPoint> scrollPosition, const WebCore::FloatPoint& scrollOrigin, const WebCore::FloatBoxExtent& obscuredInsetsOnSave, double scale)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::restorePageCenterAndScale(std::optional<WebCore::FloatPoint> center, double scale)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::elementDidFocus(const FocusedElementInformation&, bool userIsInteracting, bool blurPreviousNode, OptionSet<WebCore::ActivityState> activityStateChanges, API::Object* userData)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::updateInputContextAfterBlurringAndRefocusingElement()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::didProgrammaticallyClearFocusedElement(WebCore::ElementContext&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::updateFocusedElementInformation(const FocusedElementInformation&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::elementDidBlur()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::focusedElementDidChangeInputMode(WebCore::InputMode)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::didUpdateEditorState()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
bool MavericksPageClient::isFocusingElement()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
bool MavericksPageClient::interpretKeyEvent(const NativeWebKeyboardEvent&, KeyEventInterpretationContext&&)
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::saveImageToLibrary(Ref<WebCore::SharedBuffer>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::showPlaybackTargetPicker(bool hasVideo, const WebCore::IntRect& elementRect, WebCore::RouteSharingPolicy, const String&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::showDataDetectorsUIForPositionInformation(const InteractionInformationAtPosition&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
double MavericksPageClient::minimumZoomScale() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::FloatRect MavericksPageClient::documentRect() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::scrollingNodeScrollViewWillStartPanGesture(WebCore::ScrollingNodeID)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::scrollingNodeScrollWillStartScroll(std::optional<WebCore::ScrollingNodeID>)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::scrollingNodeScrollDidEndScroll(std::optional<WebCore::ScrollingNodeID>)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
Vector<String> MavericksPageClient::mimeTypesWithCustomContentProviders()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::hardwareKeyboardAvailabilityChanged()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::showInspectorHighlight(const WebCore::InspectorOverlay::Highlight&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::hideInspectorHighlight()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::showInspectorIndication()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::hideInspectorIndication()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::enableInspectorNodeSearch()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::disableInspectorNodeSearch()
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::handleAutocorrectionContext(const WebAutocorrectionContext&)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
#if HAVE(UISCROLLVIEW_ASYNCHRONOUS_SCROLL_EVENT_HANDLING)
void MavericksPageClient::handleAsynchronousCancelableScrollEvent(WKBaseScrollView *, WKBEScrollViewScrollUpdate *, void (^completion)(BOOL handled))
{ }
#endif
#endif
#if PLATFORM(IOS_FAMILY)
bool MavericksPageClient::isSimulatingCompatibilityPointerTouches() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::FloatBoxExtent MavericksPageClient::computedObscuredInset() const
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::Color MavericksPageClient::contentViewBackgroundColor()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
WebCore::Color MavericksPageClient::insertionPointColor()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
bool MavericksPageClient::isScreenBeingCaptured()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
String MavericksPageClient::sceneID()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
UIScreen *MavericksPageClient::screen()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::beginTextRecognitionForFullscreenVideo(WebCore::ShareableBitmap::Handle&&, AVPlayerViewController *)
{ }
#endif
#if PLATFORM(IOS_FAMILY)
void MavericksPageClient::cancelTextRecognitionForFullscreenVideo(AVPlayerViewController *)
{ }
#endif
#if PLATFORM(COCOA)
void MavericksPageClient::positionInformationDidChange(const InteractionInformationAtPosition&)
{ }
#endif
#if ENABLE(FULLSCREEN_API)
WebFullScreenManagerProxyClient& MavericksPageClient::fullScreenManagerProxyClient()
{
    return m_fullScreenClient;
}
#endif
void MavericksPageClient::didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>)
{ }
// MAVERICKS_BACKPORT: what WebViewImpl::dismissContentRelativeChildWindowsFromViewOnly does that a
// WKView reaches: the immediate-action controller and the writing-tools popover are WebViewImpl's own,
// and DictionaryLookup::hidePopup() is notImplemented() on this branch. Upstream routes this through
// -[WKView _web_dismissContentRelativeChildWindows] so a client can override it; Safari 7 predates
// that SPI, so the work sits here.
void MavericksPageClient::dismissContentRelativeChildWindows()
{
    if ([[m_view window] isKeyWindow] && PAL::isDataDetectorsFrameworkAvailable())
        [[PAL::getDDActionsManagerClassSingleton() sharedManager] requestBubbleClosureUnanchorOnFailure:YES];

    if (m_page)
        m_page->clearTextIndicatorWithAnimation(WebCore::TextIndicatorDismissalAnimation::FadeOut);

    dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText::Ignored);
}

void MavericksPageClient::navigationGestureDidBegin()
{
    dismissContentRelativeChildWindows();
}
void MavericksPageClient::navigationGestureWillEnd(bool willNavigate, WebBackForwardListItem&)
{ }
void MavericksPageClient::navigationGestureDidEnd(bool willNavigate, WebBackForwardListItem&)
{ }
void MavericksPageClient::navigationGestureDidEnd()
{ }
void MavericksPageClient::willRecordNavigationSnapshot(WebBackForwardListItem&)
{ }
void MavericksPageClient::didRemoveNavigationGestureSnapshot()
{ }
void MavericksPageClient::didStartProvisionalLoadForMainFrame()
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didStartProvisionalLoadForMainFrame();
}
void MavericksPageClient::didFirstVisuallyNonEmptyLayoutForMainFrame()
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didFirstVisuallyNonEmptyLayoutForMainFrame();
}
void MavericksPageClient::didFinishNavigation(API::Navigation* navigation)
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didFinishNavigation(navigation);

    NSAccessibilityPostNotification(RetainPtr { NSAccessibilityUnignoredAncestor(m_view) }.get(), @"AXLoadComplete");
}
void MavericksPageClient::didFailNavigation(API::Navigation* navigation)
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didFailNavigation(navigation);

    NSAccessibilityPostNotification(RetainPtr { NSAccessibilityUnignoredAncestor(m_view) }.get(), @"AXLoadComplete");
}
void MavericksPageClient::didSameDocumentNavigationForMainFrame(SameDocumentNavigationType type)
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didSameDocumentNavigationForMainFrame(type);
}
void MavericksPageClient::didChangeBackgroundColor()
{ }
#if PLATFORM(MAC)
void MavericksPageClient::didPerformImmediateActionHitTest(const WebHitTestResultData&, bool contentPreventsDefault, API::Object*)
{ }
#endif
#if PLATFORM(MAC)
NSObject *MavericksPageClient::immediateActionAnimationControllerForHitTestResult(RefPtr<API::HitTestResult>, uint64_t, RefPtr<API::Object>)
{ return { }; }
#endif
#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)
WebCore::WebMediaSessionManager& MavericksPageClient::mediaSessionManager()
{ return WebCore::WebMediaSessionManager::singleton(); }
#endif
void MavericksPageClient::didRestoreScrollPosition()
{
    if (RefPtr gestureController = [m_view _wkExistingGestureController])
        gestureController->didRestoreScrollPosition();
}
WebCore::UserInterfaceLayoutDirection MavericksPageClient::userInterfaceLayoutDirection()
{
    if (!m_view)
        return WebCore::UserInterfaceLayoutDirection::LTR;
    return ([m_view userInterfaceLayoutDirection] == NSUserInterfaceLayoutDirectionLeftToRight) ? WebCore::UserInterfaceLayoutDirection::LTR : WebCore::UserInterfaceLayoutDirection::RTL;
}
#if USE(QUICK_LOOK)
void MavericksPageClient::requestPasswordForQuickLookDocument(const String& fileName, WTF::Function<void(const String&)>&&)
{ }
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
void MavericksPageClient::willReceiveEditDragSnapshot()
{ }
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(DRAG_SUPPORT)
void MavericksPageClient::didReceiveEditDragSnapshot(RefPtr<WebCore::TextIndicator>&&)
{ }
#endif
#if ENABLE(MODEL_PROCESS)
void MavericksPageClient::didReceiveInteractiveModelElement(std::optional<WebCore::NodeIdentifier>)
{ }
#endif
} // namespace WebKit

// MAVERICKS_BACKPORT: ported from WebViewImpl's WKDOMPasteMenuDelegate; it holds this client rather
// than a WebViewImpl, which is all the menu ever needed.
@interface WKMavericksDOMPasteMenuDelegate : NSObject<NSMenuDelegate>
- (instancetype)initWithPageClient:(WebKit::MavericksPageClient&)pageClient pasteAccessCategory:(WebCore::DOMPasteAccessCategory)category;
- (void)invalidate;
@end

@implementation WKMavericksDOMPasteMenuDelegate {
    WebKit::MavericksPageClient *_pageClient;
    WebCore::DOMPasteAccessCategory _category;
}

- (instancetype)initWithPageClient:(WebKit::MavericksPageClient&)pageClient pasteAccessCategory:(WebCore::DOMPasteAccessCategory)category
{
    if (!(self = [super init]))
        return nil;

    _pageClient = &pageClient;
    _category = category;
    return self;
}

- (void)invalidate
{
    _pageClient = nullptr;
}

- (void)menuDidClose:(NSMenu *)menu
{
    RunLoop::mainSingleton().dispatch([self, protectedSelf = RetainPtr { self }] {
        if (_pageClient)
            _pageClient->hideDOMPasteMenuWithResult(WebCore::DOMPasteAccessResponse::DeniedForGesture);
    });
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu
{
    return 1;
}

- (void)_web_grantDOMPasteAccess
{
    if (_pageClient)
        _pageClient->handleDOMPasteRequestForCategoryWithResult(_category, WebCore::DOMPasteAccessResponse::GrantedForGesture);
}

@end

namespace WebKit {

static NSPasteboardName pasteboardNameForAccessCategory(WebCore::DOMPasteAccessCategory pasteAccessCategory)
{
    switch (pasteAccessCategory) {
    case WebCore::DOMPasteAccessCategory::General:
        return NSPasteboardNameGeneral;

    case WebCore::DOMPasteAccessCategory::Fonts:
        return NSPasteboardNameFont;
    }
}

static RetainPtr<NSPasteboard> pasteboardForAccessCategory(WebCore::DOMPasteAccessCategory pasteAccessCategory)
{
    switch (pasteAccessCategory) {
    case WebCore::DOMPasteAccessCategory::General:
        return NSPasteboard.generalPasteboard;

    case WebCore::DOMPasteAccessCategory::Fonts:
        return [NSPasteboard pasteboardWithName:NSPasteboardNameFont];
    }
}

void MavericksPageClient::handleDOMPasteRequestForCategoryWithResult(WebCore::DOMPasteAccessCategory pasteAccessCategory, WebCore::DOMPasteAccessResponse response)
{
    if (m_page && (response == WebCore::DOMPasteAccessResponse::GrantedForCommand || response == WebCore::DOMPasteAccessResponse::GrantedForGesture))
        m_page->grantAccessToCurrentPasteboardData(pasteboardNameForAccessCategory(pasteAccessCategory), [] () { });

    hideDOMPasteMenuWithResult(response);
}

void MavericksPageClient::hideDOMPasteMenuWithResult(WebCore::DOMPasteAccessResponse response)
{
    if (auto handler = std::exchange(m_domPasteRequestHandler, { }))
        handler(response);
    [m_domPasteMenu removeAllItems];
    [m_domPasteMenu update];
    [m_domPasteMenu cancelTracking];
    [m_domPasteMenuDelegate invalidate];
    m_domPasteMenu = nil;
    m_domPasteMenuDelegate = nil;
}

void MavericksPageClient::requestDOMPasteAccess(WebCore::DOMPasteAccessCategory pasteAccessCategory, WebCore::DOMPasteRequiresInteraction requiresInteraction, const WebCore::IntRect&, const String& originIdentifier, CompletionHandler<void(WebCore::DOMPasteAccessResponse)>&& completion)
{
    hideDOMPasteMenuWithResult(WebCore::DOMPasteAccessResponse::DeniedForGesture);

    if (!m_page)
        return completion(WebCore::DOMPasteAccessResponse::DeniedForGesture);

    RetainPtr data = [pasteboardForAccessCategory(pasteAccessCategory).get() dataForType:RetainPtr { @(WebCore::PasteboardCustomData::cocoaType().characters()) }.get()];
    auto buffer = WebCore::SharedBuffer::create(data.get());
    if (requiresInteraction == WebCore::DOMPasteRequiresInteraction::No && WebCore::PasteboardCustomData::fromSharedBuffer(buffer.get()).origin() == originIdentifier) {
        m_page->grantAccessToCurrentPasteboardData(pasteboardNameForAccessCategory(pasteAccessCategory), [completion = WTF::move(completion)] () mutable {
            completion(WebCore::DOMPasteAccessResponse::GrantedForGesture);
        });
        return;
    }

    m_domPasteMenuDelegate = adoptNS([[WKMavericksDOMPasteMenuDelegate alloc] initWithPageClient:*this pasteAccessCategory:pasteAccessCategory]);
    m_domPasteRequestHandler = WTF::move(completion);
    m_domPasteMenu = adoptNS([[NSMenu alloc] initWithTitle:WebCore::contextMenuItemTagPaste().createNSString().get()]);

    [m_domPasteMenu setDelegate:m_domPasteMenuDelegate.get()];
    [m_domPasteMenu setAllowsContextMenuPlugIns:NO];

    auto pasteMenuItem = RetainPtr([m_domPasteMenu insertItemWithTitle:WebCore::contextMenuItemTagPaste().createNSString().get() action:@selector(_web_grantDOMPasteAccess) keyEquivalent:@"" atIndex:0]);
    [pasteMenuItem setTarget:m_domPasteMenuDelegate.get()];

    RetainPtr window = [m_view window];
    RetainPtr event = m_page->createSyntheticEventForContextMenu([window convertPointFromScreen:NSEvent.mouseLocation]);
    [NSMenu popUpContextMenu:m_domPasteMenu.get() withEvent:event.get() forView:retainPtr(window.get().contentView).get()];
}
#if USE(WPE_RENDERER)
UnixFileDescriptor MavericksPageClient::hostFileDescriptor()
{ return { }; }
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
bool MavericksPageClient::canHandleContextMenuTranslation() const
{ return { }; }
#endif
#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
void MavericksPageClient::handleContextMenuTranslation(const WebCore::TranslationContextMenuInfo&)
{ }
#endif
#if ENABLE(WRITING_TOOLS) && ENABLE(CONTEXT_MENUS)
bool MavericksPageClient::canHandleContextMenuWritingTools() const
{ return { }; }
#endif
#if ENABLE(WRITING_TOOLS)
void MavericksPageClient::proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(const WebCore::WritingTools::TextSuggestionID&, WebCore::IntRect selectionBoundsInRootView)
{ }
#endif
#if USE(GRAPHICS_LAYER_WC)
bool MavericksPageClient::usesOffscreenRendering() const
{ return { }; }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MavericksPageClient::didEnterFullscreen()
{ }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MavericksPageClient::didExitFullscreen()
{ }
#endif
#if ENABLE(VIDEO_PRESENTATION_MODE)
void MavericksPageClient::didCleanupFullscreen()
{ }
#endif
#if PLATFORM(GTK) || PLATFORM(WPE)
WebKitWebResourceLoadManager* MavericksPageClient::webResourceLoadManager()
{ return { }; }
#endif
#if PLATFORM(IOS_FAMILY)
UIViewController *MavericksPageClient::presentingViewController() const
{ return { }; }
#endif
#if HAVE(SPATIAL_TRACKING_LABEL)
String MavericksPageClient::spatialTrackingLabel() const
{ return { }; }
#endif

// ===== Free functions used by WKView =====

std::unique_ptr<PageClient> createMavericksPageClient(NSView *view)
{
    return std::unique_ptr<PageClient>(new MavericksPageClient(view));
}

void setMavericksPageClientPage(PageClient& client, WebPageProxy* page)
{
    static_cast<MavericksPageClient&>(client).setPage(page);
}

void mavericksPageClientViewDidChangeBackingProperties(PageClient& client)
{
    static_cast<MavericksPageClient&>(client).viewDidChangeBackingProperties();
}

void setMavericksPageClientWindowOcclusionDetectionEnabled(PageClient& client, bool enabled)
{
    static_cast<MavericksPageClient&>(client).setWindowOcclusionDetectionEnabled(enabled);
}

bool mavericksPageClientWindowOcclusionDetectionEnabled(PageClient& client)
{
    return static_cast<MavericksPageClient&>(client).windowOcclusionDetectionEnabled();
}

#if ENABLE(FULLSCREEN_API)
// MAVERICKS_BACKPORT: serves -[WKView fullScreenPlaceholderView], the Safari 7 SPI that asks for
// the view standing in for the web view while it is hosted by the full-screen window. Upstream's
// WKView answers with its full-screen controller's placeholder; this is the same view.
NSView *mavericksPageClientFullScreenPlaceholderView(PageClient& client)
{
    return static_cast<MavericksPageClient&>(client).fullScreenPlaceholderView();
}
#endif

} // namespace WebKit


#endif // PLATFORM(MAC)
