// Minimal PageClientImpl for macOS 10.9 backport
// Provides bare minimum for WebPageProxy creation

#import "config.h"
#import "PageClient.h"
#import <objc/runtime.h>
#import "WebFullScreenManagerProxy.h"
#import <WebCore/ColorSpace.h>
#import <WebCore/DestinationColorSpace.h>
#import "DrawingAreaProxy.h"
#import "RemoteLayerTreeDrawingAreaProxyMac.h"
#import "RemoteLayerTreeNode.h"
#import "TiledCoreAnimationDrawingAreaProxy.h"
#import "WebPageProxy.h"
#import "PageLoadState.h"
#import "WebEditCommandProxy.h"
#import "WebContextMenuProxyMac.h"
#import "WebPopupMenuProxyMac.h"
#import "WebColorPickerMac.h"
#import "WebDataListSuggestionsDropdownMac.h"
#import "WebDateTimePickerMac.h"
#import "UndoOrRedo.h"
#import <WebCore/ValidationBubble.h>
#import <QuartzCore/QuartzCore.h>
#import <WebCore/Cursor.h>
#import <wtf/Vector.h>
#import <wtf/text/WTFString.h>
namespace WebKit {
class MinimalPageClient final : public PageClient {
    NSView *m_view;
    WebPageProxy *m_page { nullptr };
    Vector<Ref<WebEditCommandProxy>> m_undoStack;
    Vector<Ref<WebEditCommandProxy>> m_redoStack;
public:
    MinimalPageClient(NSView *view) : m_view(view) {}
    void setPage(WebPageProxy *page) { m_page = page; }

    // ref/deref for prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent prevent
    void refView() {}
    void derefView() {}
WebCore::DestinationColorSpace colorSpace() { return WebCore::DestinationColorSpace::SRGB(); }
WebFullScreenManagerProxyClient& fullScreenManagerProxyClient() { static int dummy; return *(WebFullScreenManagerProxyClient*)&dummy; }
void setFullScreenClientForTesting(std::unique_ptr<WebFullScreenManagerProxyClient>&&) {}
Ref<DrawingAreaProxy> createDrawingAreaProxy(WebProcessProxy& webProcess)
{
    RELEASE_ASSERT(m_page);
    return TiledCoreAnimationDrawingAreaProxy::create(*m_page, webProcess);
}
void setViewNeedsDisplay(const WebCore::Region&) {}
void requestScroll(const WebCore::FloatPoint& scrollPosition, const WebCore::IntPoint& scrollOrigin, WebCore::ScrollIsAnimated, WebCore::InterruptScrollAnimation) {}
WebCore::FloatPoint viewScrollPosition() { return {}; }
WebCore::IntSize viewSize()
{
    if (!m_view)
        return {};
    NSRect bounds = [m_view bounds];
    return WebCore::IntSize(static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height));
}
bool isViewWindowActive() { return m_view && [m_view window] && [[m_view window] isKeyWindow]; }
bool isViewFocused() { return m_view && [m_view window] && [[m_view window] firstResponder] == m_view; }
bool isActiveViewVisible() { return m_view && [m_view window] && ![[m_view window] isMiniaturized]; }
bool canTakeForegroundAssertions() { return false; }
bool isViewInWindow() { return m_view && [m_view window] != nil; }
void processDidExit() {}
void didRelaunchProcess() {}
void pageClosed() {}
void preferencesDidChange() {}
// 10.9 backport: forward tooltip text changes to the WKView so AppKit's
// tooltip tracking machinery shows them on hover.
void toolTipChanged(const String&, const String& newToolTip)
{
    if (!m_view) return;
    if (newToolTip.isEmpty())
        [m_view setToolTip:nil];
    else
        [m_view setToolTip:newToolTip.createNSString().get()];
}
// 10.9 backport: deny geolocation by default so sites that request it don't
// hang waiting for a callback that the empty stub never fired.
void decidePolicyForGeolocationPermissionRequest(WebFrameProxy&, const FrameInfoData&, Function<void(bool)>& completion) { completion(false); }
void didCommitLoadForMainFrame(const String& mimeType, bool useCustomContentProvider)
{
    // 10.9 backport: Safari 9's BrowserWindow KVO-observes its NSWindow's
    // `representedURL` to drive the toolbar URL field. Upstream WebKit doesn't
    // set this — modern Safari/WKWebView uses WKWebView.URL KVO instead, which
    // Safari 9 doesn't subscribe to. Bridge by setting representedURL on the
    // host window every time the main frame commits a navigation, so the
    // address bar reflects link clicks, JS navigation, and server redirects,
    // not just user-typed URLs.
    if (!m_view || !m_page)
        return;
    NSWindow *win = [m_view window];
    if (!win)
        return;
    const auto& urlString = m_page->pageLoadState().url();
    if (urlString.isEmpty()) {
        [win setRepresentedURL:nil];
        return;
    }
    NSURL *nsURL = [NSURL URLWithString:urlString.createNSString().get()];
    [win setRepresentedURL:nsURL];
}
void createPDFHUD(PDFPluginIdentifier, WebCore::FrameIdentifier, const WebCore::IntRect&) {}
void updatePDFHUDLocation(PDFPluginIdentifier, const WebCore::IntRect&) {}
void removePDFHUD(PDFPluginIdentifier) {}
void removeAllPDFHUDs() {}
void createPDFPageNumberIndicator(PDFPluginIdentifier, const WebCore::IntRect&, size_t pageCount) {}
void updatePDFPageNumberIndicatorLocation(PDFPluginIdentifier, const WebCore::IntRect&) {}
void updatePDFPageNumberIndicatorCurrentPage(PDFPluginIdentifier, size_t pageIndex) {}
void removePDFPageNumberIndicator(PDFPluginIdentifier) {}
void removeAnyPDFPageNumberIndicator() {}
void didChangeContentSize(const WebCore::IntSize&) {}
void startDrag(WebCore::SelectionData&&, OptionSet<WebCore::DragOperation>, RefPtr<WebCore::ShareableBitmap>&& dragImage, WebCore::IntPoint&& dragImageHotspot) {}
void setCursor(const WebCore::Cursor& cursor)
{
    // 10.9 backport: map basic WebCore::Cursor types to NSCursor so link-hover and
    // text-selection cursors actually update on screen.
    NSCursor *nsCursor = nil;
    switch (cursor.type()) {
    case WebCore::Cursor::Type::Pointer:
    case WebCore::Cursor::Type::ContextMenu:
    case WebCore::Cursor::Type::Help:
        nsCursor = [NSCursor arrowCursor];
        break;
    case WebCore::Cursor::Type::Hand:
        nsCursor = [NSCursor pointingHandCursor];
        break;
    case WebCore::Cursor::Type::IBeam:
    case WebCore::Cursor::Type::Cell:
    case WebCore::Cursor::Type::VerticalText:
        nsCursor = [NSCursor IBeamCursor];
        break;
    case WebCore::Cursor::Type::Cross:
        nsCursor = [NSCursor crosshairCursor];
        break;
    case WebCore::Cursor::Type::EastResize:
    case WebCore::Cursor::Type::WestResize:
    case WebCore::Cursor::Type::EastWestResize:
    case WebCore::Cursor::Type::ColumnResize:
        nsCursor = [NSCursor resizeLeftRightCursor];
        break;
    case WebCore::Cursor::Type::NorthResize:
    case WebCore::Cursor::Type::SouthResize:
    case WebCore::Cursor::Type::NorthSouthResize:
    case WebCore::Cursor::Type::RowResize:
        nsCursor = [NSCursor resizeUpDownCursor];
        break;
    case WebCore::Cursor::Type::Wait:
    case WebCore::Cursor::Type::Progress:
        nsCursor = [NSCursor arrowCursor];
        break;
    case WebCore::Cursor::Type::NoDrop:
    case WebCore::Cursor::Type::NotAllowed:
        nsCursor = [NSCursor operationNotAllowedCursor];
        break;
    case WebCore::Cursor::Type::Grab:
        nsCursor = [NSCursor openHandCursor];
        break;
    case WebCore::Cursor::Type::Grabbing:
        nsCursor = [NSCursor closedHandCursor];
        break;
    default:
        nsCursor = [NSCursor arrowCursor];
        break;
    }
    if (nsCursor)
        [nsCursor set];
}
void setCursorHiddenUntilMouseMoves(bool) {}
// 10.9 backport: real undo/redo stacks (mirrors DefaultUndoController).
// MinimalPageClient previously stubbed these out, so Cmd+Z did nothing.
void registerEditCommand(Ref<WebEditCommandProxy>&& command, UndoOrRedo undoOrRedo)
{
    if (undoOrRedo == UndoOrRedo::Undo)
        m_undoStack.append(WTF::move(command));
    else
        m_redoStack.append(WTF::move(command));
}
void clearAllEditCommands()
{
    m_undoStack.clear();
    m_redoStack.clear();
}
bool canUndoRedo(UndoOrRedo undoOrRedo)
{
    return undoOrRedo == UndoOrRedo::Undo ? !m_undoStack.isEmpty() : !m_redoStack.isEmpty();
}
void executeUndoRedo(UndoOrRedo undoOrRedo)
{
    if (undoOrRedo == UndoOrRedo::Undo) {
        if (m_undoStack.isEmpty()) return;
        m_undoStack.takeLast()->unapply();
    } else {
        if (m_redoStack.isEmpty()) return;
        m_redoStack.takeLast()->reapply();
    }
}
void wheelEventWasNotHandledByWebCore(const NativeWebWheelEvent&) {}
void accessibilityWebProcessTokenReceived(std::span<const uint8_t>, pid_t) {}
bool executeSavedCommandBySelector(const String& selector)
{
    // 10.9 backport: WebContent sends us a selector its Editor didn't handle
    // (typically window-level: performClose:, performMiniaturize:, terminate:,
    // hide:). Forward to the AppKit responder chain so these still work.
    if (selector.isEmpty() || !selector.endsWith(':'))
        return false;
    SEL sel = sel_getUid(selector.utf8().data());
    if (!sel)
        return false;
    @try {
        NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
        if (window) {
            NSResponder *responder = [window firstResponder] ?: window;
            if ([responder respondsToSelector:sel]) {
                [NSApp sendAction:sel to:responder from:nil];
                return true;
            }
        }
        if ([NSApp respondsToSelector:sel]) {
            [NSApp performSelector:sel withObject:nil];
            return true;
        }
    } @catch (NSException *) { }
    return false;
}
void updateSecureInputState() {}
void resetSecureInputState() {}
void notifyInputContextAboutDiscardedComposition() {}
void makeFirstResponder() {}
void assistiveTechnologyMakeFirstResponder() {}
void setRemoteLayerTreeRootNode(RemoteLayerTreeNode* rootNode)
{
    NSView *targetView = m_view;
    NSWindow *win = targetView ? [targetView window] : nil;
    CALayer *rl = rootNode ? rootNode->layer() : nil;
    // 10.9 backport: WKView may temporarily have a nil window during URL-bar
    // typed navigation. We used to early-return but that left the layer tree
    // unattached forever for the URL-bar path. Try to find a visible Safari
    // window and use its NSThemeFrame layer as the host instead. As a last
    // resort, search [NSApp windows] for a visible browser window.
    if (!win) {
        for (NSWindow *w in [NSApp windows]) {
            if ([w isVisible] && [w isKeyWindow]) { win = w; break; }
        }
        if (!win) {
            for (NSWindow *w in [NSApp windows]) {
                if ([w isVisible] && [w level] == NSNormalWindowLevel) { win = w; break; }
            }
        }
        if (!win)
            return;
    }
    CALayer *viewLayer = targetView ? [targetView layer] : nil;
    NSRect viewBounds = targetView ? [targetView bounds] : NSZeroRect;
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[setRemoteLayerTreeRootNode PID %d] rootNode=%p layer=%p targetView=%p viewLayer=%p viewBounds=%gx%g window=%p visible=%d\n",
        getpid(), rootNode, rl, targetView, viewLayer, (double)viewBounds.size.width, (double)viewBounds.size.height,
        win, win ? (int)[win isVisible] : -1); fclose(_d);}}
    if (!targetView) return;
    if (!viewLayer) {
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[setRemoteLayerTreeRootNode PID %d] targetView has no layer\n", getpid()); fclose(_d);}}
        return;
    }
    {
        // 10.9 diagnostic: dump the targetView hierarchy so we can see what Safari's
        // actual view tree looks like.
        FILE *_d=((FILE*)0);
        if (_d) {
            fprintf(_d, "[setRemoteLayerTreeRootNode PID %d] targetView=%s %p wantsLayer=%d layer=%p layerHosted=%d drawsBackground=%d\n",
                getpid(), [[targetView className] UTF8String], targetView,
                (int)[targetView wantsLayer], [targetView layer],
                [targetView respondsToSelector:@selector(layer)] && [targetView layer] ? 1 : 0,
                0);
            fprintf(_d, "  superview=%s %p\n", [[[targetView superview] className] UTF8String], [targetView superview]);
            for (NSView *sv in [targetView subviews])
                fprintf(_d, "  subview=%s %p frame=(%g,%g,%gx%g) wantsLayer=%d\n",
                    [[sv className] UTF8String], sv,
                    (double)[sv frame].origin.x, (double)[sv frame].origin.y,
                    (double)[sv frame].size.width, (double)[sv frame].size.height,
                    (int)[sv wantsLayer]);
            fclose(_d);
        }
    }
    // 10.9 backport: Safari's BrowserWKView has drawRect: and uses AppKit's _NSViewBackingLayer
    // as its wantsLayer backing. Sublayers added to that backing layer on 10.9 are NOT
    // composited to the window. Workaround: attach the WebKit remote root layer directly to
    // the window's NSThemeFrame layer (which we've proven does composite), and position it
    // at BrowserWKView's frame in window coordinates.
    NSView *topView = targetView;
    while ([topView superview]) topView = [topView superview];
    CALayer *hostLayer = [topView layer];
    NSRect viewFrameInWindow;
    if (!hostLayer || ![targetView window]) {
        // 10.9 backport URL-bar fallback path: targetView is detached. Use the
        // visible window's contentView superview (NSThemeFrame) as the host,
        // and assume the layer should fill the content area.
        NSView *contentSuper = [[win contentView] superview];
        hostLayer = [contentSuper layer];
        if (!hostLayer)
            return;
        NSRect contentBounds = [[win contentView] bounds];
        viewFrameInWindow = NSMakeRect(0, 0, contentBounds.size.width, contentBounds.size.height - 80);
        topView = contentSuper;
    } else {
        // Convert BrowserWKView's bounds to topView's coordinate system.
        viewFrameInWindow = [targetView convertRect:[targetView bounds] toView:topView];
    }
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[setRemoteLayerTreeRootNode PID %d] attaching to topView=%s %p hostLayer=%p viewRectInWindow=(%g,%g,%gx%g)\n",
        getpid(), [[topView className] UTF8String], topView, hostLayer,
        (double)viewFrameInWindow.origin.x, (double)viewFrameInWindow.origin.y,
        (double)viewFrameInWindow.size.width, (double)viewFrameInWindow.size.height); fclose(_d);}}

    // Remove any previously-attached WebKit layers from the hostLayer.
    NSArray *existing = [[hostLayer sublayers] copy];
    for (CALayer *sl in existing) {
        if ([[sl name] isEqualToString:@"__webkit_10_9_root__"])
            [sl removeFromSuperlayer];
    }

    [viewLayer setSublayers:nil];
    if (rootNode && rootNode->layer()) {
        CALayer *l = rootNode->layer();
        CALayer *container = [CALayer layer];
        [container setName:@"__webkit_10_9_root__"];
        [container setAnchorPoint:CGPointMake(0, 0)];
        [container setPosition:CGPointMake(viewFrameInWindow.origin.x, viewFrameInWindow.origin.y)];
        [container setBounds:CGRectMake(0, 0, viewFrameInWindow.size.width, viewFrameInWindow.size.height)];
        [container setZPosition:0];
        [container setGeometryFlipped:YES];
        [l setAnchorPoint:CGPointMake(0, 0)];
        [l setPosition:CGPointMake(0, 0)];
        [l setBounds:CGRectMake(0, 0, viewFrameInWindow.size.width, viewFrameInWindow.size.height)];
        [l setMasksToBounds:NO];
        [container addSublayer:l];
        [hostLayer addSublayer:container];
    }
    [hostLayer setNeedsDisplay];
}
CALayer *acceleratedCompositingRootLayer() const
{
    if (!m_view) return nil;
    NSArray *subs = [[m_view layer] sublayers];
    return subs.count ? [subs objectAtIndex:0] : nil;
}
void gestureEventWasNotHandledByWebCore(const NativeWebGestureEvent&) {}
CALayer *headerBannerLayer() const { return {}; }
CALayer *footerBannerLayer() const { return {}; }
void selectionDidChange() {}
RefPtr<ViewSnapshot> takeViewSnapshot(std::optional<WebCore::IntRect>&&) { return nullptr; }
RefPtr<ViewSnapshot> takeViewSnapshot(std::optional<WebCore::IntRect>&&, ForceSoftwareCapturingViewportSnapshot) { return nullptr; }
void setPromisedDataForImage(const String& pasteboardName, Ref<WebCore::FragmentedSharedBuffer>&& imageBuffer, const String& filename, const String& extension, const String& title, const String& url, const String& visibleURL, RefPtr<WebCore::FragmentedSharedBuffer>&& archiveBuffer, const String& originIdentifier) {}
WebCore::FloatRect convertToDeviceSpace(const WebCore::FloatRect&) { return {}; }
WebCore::FloatRect convertToUserSpace(const WebCore::FloatRect&) { return {}; }
WebCore::IntPoint screenToRootView(const WebCore::IntPoint&) { return {}; }
WebCore::IntPoint rootViewToScreen(const WebCore::IntPoint&) { return {}; }
WebCore::IntRect rootViewToScreen(const WebCore::IntRect&) { return {}; }
WebCore::IntPoint accessibilityScreenToRootView(const WebCore::IntPoint&) { return {}; }
WebCore::IntRect rootViewToAccessibilityScreen(const WebCore::IntRect&) { return {}; }
void relayAccessibilityNotification(String&&, RetainPtr<NSData>&&) {}
void relayAriaNotifyNotification(const WebCore::AriaNotifyData&) {}
void relayLiveRegionNotification(const WebCore::LiveRegionAnnouncementData&) {}
WebCore::IntRect rootViewToWindow(const WebCore::IntRect&) { return {}; }
void didNotHandleTapAsClick(const WebCore::IntPoint&) {}
void didHandleTapAsHover() {}
void didCompleteSyntheticClick() {}
void doneWithKeyEvent(const NativeWebKeyboardEvent&, bool wasEventHandled) {}
void doneWithTouchEvent(const WebTouchEvent&, bool wasEventHandled) {}
void doneDeferringTouchStart(bool preventNativeGestures) {}
void doneDeferringTouchMove(bool preventNativeGestures) {}
void doneDeferringTouchEnd(bool preventNativeGestures) {}
// 10.9 backport: <select> dropdowns used to do nothing because the proxy was
// nullptr. Use the standard NSPopUpButtonCell-backed proxy.
RefPtr<WebPopupMenuProxy> createPopupMenuProxy(WebPageProxy& page)
{
    return WebPopupMenuProxyMac::create(m_view, page.popupMenuClient());
}
// 10.9 backport: right-click used to crash UIProcess via RELEASE_ASSERT_NOT_REACHED.
// Wire to the standard WebContextMenuProxyMac so right-click shows a real menu.
Ref<WebContextMenuProxy> createContextMenuProxy(WebPageProxy& page, FrameInfoData&& frameInfo, ContextMenuContextData&& context, const UserData& userData)
{
    return WebContextMenuProxyMac::create(m_view, page, WTF::move(frameInfo), WTF::move(context), userData);
}
// 10.9 backport: WebColorPickerMac uses NSPopoverColorWell + private
// _setRequiresCorrectContentAppearance: + _exclusiveColorPanelOwner — all
// 10.10+. Returning nullptr leaves <input type="color"> inert (no UI) but
// avoids a crash. Wire up properly only if a 10.9-safe color UI is built.
RefPtr<WebColorPicker> createColorPicker(WebPageProxy&, const WebCore::Color&, const WebCore::IntRect&, ColorControlSupportsAlpha, Vector<WebCore::Color>&&, std::optional<WebCore::FrameIdentifier>) { return nullptr; }
// 10.9 backport: <input type="date">/<input list> used to be inert. Wire to
// the standard Mac implementations.
RefPtr<WebDataListSuggestionsDropdown> createDataListSuggestionsDropdown(WebPageProxy& page)
{
    return WebDataListSuggestionsDropdownMac::create(page, m_view);
}
RefPtr<WebDateTimePicker> createDateTimePicker(WebPageProxy& page)
{
    return WebDateTimePickerMac::create(page, m_view);
}
// 10.9 backport: form validation bubble used to crash UIProcess. Use the
// standard Cocoa ValidationBubble instead.
Ref<WebCore::ValidationBubble> createValidationBubble(String&& message, const WebCore::ValidationBubble::Settings& settings)
{
    return WebCore::ValidationBubble::create(m_view, WTF::move(message), settings);
}
CALayer *textIndicatorInstallationLayer() { return {}; }
void didPerformDictionaryLookup(const WebCore::DictionaryPopupInfo&) {}
WebCore::Color accentColor() { return {}; }
bool appUsesCustomAccentColor() { return false; }
void enterAcceleratedCompositingMode(const LayerTreeContext& ctx) {
    // 10.9 backport: attach a CALayerHost to display the WebContent's
    // CALayer hosting context.
    if (!m_view || !ctx.contextID)
        return;
    Class remoteClass = NSClassFromString(@"CALayerHost");
    if (!remoteClass)
        return;
    id remoteLayer = [[remoteClass alloc] init];
    if ([remoteLayer respondsToSelector:@selector(setContextId:)])
        [remoteLayer setContextId:ctx.contextID];
    [(CALayer*)remoteLayer setFrame:[m_view bounds]];
    [m_view setWantsLayer:YES];
    [[m_view layer] setSublayers:@[remoteLayer]];
    [remoteLayer release];
}
void exitAcceleratedCompositingMode() {
    if (m_view && [m_view layer])
        [[m_view layer] setSublayers:@[]];
}
void updateAcceleratedCompositingMode(const LayerTreeContext& ctx) {
    enterAcceleratedCompositingMode(ctx);
}
void didFirstLayerFlush(const LayerTreeContext& ctx) {
    enterAcceleratedCompositingMode(ctx);
}
std::optional<WebCore::DictationContext> addDictationAlternatives(PlatformTextAlternatives *) { return {}; }
void replaceDictationAlternatives(PlatformTextAlternatives *, WebCore::DictationContext) {}
void removeDictationAlternatives(WebCore::DictationContext) {}
void showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext) {}
Vector<String> dictationAlternatives(WebCore::DictationContext) { return {}; }
PlatformTextAlternatives *platformDictationAlternatives(WebCore::DictationContext) { return {}; }
void showCorrectionPanel(WebCore::AlternativeTextType, const WebCore::FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings) {}
void dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText) {}
String dismissCorrectionPanelSoon(WebCore::ReasonForDismissingAlternativeText) { return {}; }
void recordAutocorrectionResponse(WebCore::AutocorrectionResponse, const String& replacedString, const String& replacementString) {}
void recommendedScrollbarStyleDidChange(WebCore::ScrollbarStyle) {}
void handleControlledElementIDResponse(const String&) {}
CGRect boundsOfLayerInLayerBackedWindowCoordinates(CALayer *) const { return {}; }
bool useFormSemanticContext() const { return false; }
NSView *viewForPresentingRevealPopover() const { return {}; }
void showPlatformContextMenu(NSMenu *, WebCore::IntPoint) {}
void startWindowDrag() {}
void setShouldSuppressFirstResponderChanges(bool) {}
RetainPtr<NSView> inspectorAttachmentView() { return {}; }
_WKRemoteObjectRegistry *remoteObjectRegistry() { return {}; }
void intrinsicContentSizeDidChange(const WebCore::IntSize& intrinsicContentSize) {}
void registerInsertionUndoGrouping() {}
void setEditableElementIsFocused(bool) {}
void didCommitLayerTree(const RemoteLayerTreeTransaction&, const std::optional<MainFrameData>&, const PageData&, const TransactionID&) {}
void didCommitMainFrameData(const MainFrameData&) {}
void scrollingNodeScrollViewDidScroll(WebCore::ScrollingNodeID) {}
CocoaWindow *platformWindow() const { return {}; }
void commitPotentialTapFailed() {}
void didGetTapHighlightGeometries(WebKit::TapIdentifier requestID, const WebCore::Color&, const Vector<WebCore::FloatQuad>& highlightedQuads, const WebCore::IntSize& topLeftRadius, const WebCore::IntSize& topRightRadius, const WebCore::IntSize& bottomLeftRadius, const WebCore::IntSize& bottomRightRadius, bool nodeHasBuiltInClickHandling) {}
bool isPotentialTapInProgress() const { return false; }
void disableDoubleTapGesturesDuringTapIfNecessary(WebKit::TapIdentifier) {}
void handleSmartMagnificationInformationForPotentialTap(WebKit::TapIdentifier, const WebCore::FloatRect& renderRect, bool fitEntireRect, double viewportMinimumScale, double viewportMaximumScale, bool nodeIsRootLevel, bool nodeIsPluginElement) {}
void couldNotRestorePageState() {}
void restorePageState(std::optional<WebCore::FloatPoint> scrollPosition, const WebCore::FloatPoint& scrollOrigin, const WebCore::FloatBoxExtent& obscuredInsetsOnSave, double scale) {}
void restorePageCenterAndScale(std::optional<WebCore::FloatPoint> center, double scale) {}
void elementDidFocus(const FocusedElementInformation&, bool userIsInteracting, bool blurPreviousNode, OptionSet<WebCore::ActivityState> activityStateChanges, API::Object* userData) {}
void updateInputContextAfterBlurringAndRefocusingElement() {}
void didProgrammaticallyClearFocusedElement(WebCore::ElementContext&&) {}
void updateFocusedElementInformation(const FocusedElementInformation&) {}
void elementDidBlur() {}
void focusedElementDidChangeInputMode(WebCore::InputMode) {}
void didUpdateEditorState() {}
bool isFocusingElement() { return false; }
bool interpretKeyEvent(const NativeWebKeyboardEvent&, KeyEventInterpretationContext&&) { return false; }
void saveImageToLibrary(Ref<WebCore::SharedBuffer>&&) {}
void showPlaybackTargetPicker(bool hasVideo, const WebCore::IntRect& elementRect, WebCore::RouteSharingPolicy, const String&) {}
void showDataDetectorsUIForPositionInformation(const InteractionInformationAtPosition&) {}
double minimumZoomScale() const { return {}; }
WebCore::FloatRect documentRect() const { return {}; }
void scrollingNodeScrollViewWillStartPanGesture(WebCore::ScrollingNodeID) {}
void scrollingNodeScrollWillStartScroll(std::optional<WebCore::ScrollingNodeID>) {}
void scrollingNodeScrollDidEndScroll(std::optional<WebCore::ScrollingNodeID>) {}
Vector<String> mimeTypesWithCustomContentProviders() { return {}; }
void hardwareKeyboardAvailabilityChanged() {}
void hideInspectorHighlight() {}
void showInspectorIndication() {}
void hideInspectorIndication() {}
void enableInspectorNodeSearch() {}
void disableInspectorNodeSearch() {}
void handleAutocorrectionContext(const WebAutocorrectionContext&) {}
void handleAsynchronousCancelableScrollEvent(WKBaseScrollView *, WKBEScrollViewScrollUpdate *, void (^completion)(BOOL handled)) {}
bool isSimulatingCompatibilityPointerTouches() const { return false; }
WebCore::FloatBoxExtent computedObscuredInset() const { return {}; }
WebCore::Color contentViewBackgroundColor() { return {}; }
WebCore::Color insertionPointColor() { return {}; }
bool isScreenBeingCaptured() { return false; }
String sceneID() { return {}; }
UIScreen *screen() { return {}; }
void beginTextRecognitionForFullscreenVideo(WebCore::ShareableBitmap::Handle&&, AVPlayerViewController *) {}
void cancelTextRecognitionForFullscreenVideo(AVPlayerViewController *) {}
void positionInformationDidChange(const InteractionInformationAtPosition&) {}
void didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>) {}
void navigationGestureDidBegin() {}
void navigationGestureWillEnd(bool willNavigate, WebBackForwardListItem&) {}
void navigationGestureDidEnd(bool willNavigate, WebBackForwardListItem&) {}
void navigationGestureDidEnd() {}
void willRecordNavigationSnapshot(WebBackForwardListItem&) {}
void didRemoveNavigationGestureSnapshot() {}
void didFirstVisuallyNonEmptyLayoutForMainFrame() {}
void didFinishNavigation(API::Navigation*) {}
void didFailNavigation(API::Navigation*) {}
void didSameDocumentNavigationForMainFrame(SameDocumentNavigationType) {}
void didChangeBackgroundColor() {}
void isPlayingAudioWillChange() {}
void isPlayingAudioDidChange() {}
void didPerformImmediateActionHitTest(const WebHitTestResultData&, bool contentPreventsDefault, API::Object*) {}
NSObject *immediateActionAnimationControllerForHitTestResult(RefPtr<API::HitTestResult>, uint64_t, RefPtr<API::Object>) { return {}; }
void didRestoreScrollPosition() {}
WebCore::UserInterfaceLayoutDirection userInterfaceLayoutDirection() { return {}; }
// 10.9 backport: cancel password prompts for encrypted QuickLook documents
// rather than letting the caller hang on a never-fired completion.
void requestPasswordForQuickLookDocument(const String&, WTF::Function<void(const String&)>&& completion) { completion({ }); }
void willReceiveEditDragSnapshot() {}
void didReceiveEditDragSnapshot(RefPtr<WebCore::TextIndicator>&&) {}
void didReceiveInteractiveModelElement(std::optional<WebCore::NodeIdentifier>) {}
// 10.9 backport: navigator.clipboard.readText() and other DOM-paste APIs
// send a synchronous IPC waiting for this completion. The empty stub never
// fired the handler, so WebContent hung forever. Grant access immediately so
// reads complete (security trade-off on a manual single-user 10.9 build).
void requestDOMPasteAccess(WebCore::DOMPasteAccessCategory, WebCore::DOMPasteRequiresInteraction, const WebCore::IntRect&, const String&, CompletionHandler<void(WebCore::DOMPasteAccessResponse)>&& completion)
{
    completion(WebCore::DOMPasteAccessResponse::GrantedForGesture);
}
void storeAppHighlight(const WebCore::AppHighlight&) {}
bool canHandleContextMenuTranslation() const { return false; }
void handleContextMenuTranslation(const WebCore::TranslationContextMenuInfo&) {}
void writingToolsActiveWillChange() {}
void writingToolsActiveDidChange() {}
void didEndPartialIntelligenceTextAnimation() {}
bool writingToolsTextReplacementsFinished() { return false; }
void addTextAnimationForAnimationID(const WTF::UUID&, const WebCore::TextAnimationData&) {}
void removeTextAnimationForAnimationID(const WTF::UUID&) {}
bool usesOffscreenRendering() const { return false; }
void didEnterFullscreen() {}
void didExitFullscreen() {}
void didCleanupFullscreen() {}
UIViewController *presentingViewController() const { return {}; }
String spatialTrackingLabel() const { return {}; }};
std::unique_ptr<PageClient> createMinimalPageClient(NSView *view) {
    return std::unique_ptr<PageClient>(new MinimalPageClient(view));
}

void setMinimalPageClientPage(PageClient& pageClient, WebPageProxy *page)
{
    static_cast<MinimalPageClient&>(pageClient).setPage(page);
}
} // namespace WebKit
