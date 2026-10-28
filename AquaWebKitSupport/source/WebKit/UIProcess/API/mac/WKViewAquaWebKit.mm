/*
 * Copyright (C) 2010, 2011 Apple Inc. All rights reserved.
 * Copyright (C) 2015-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// The 10.9 WKView implementation.
//
// WKView is Safari 7's WebKit2 view. Upstream's UIProcess/API/mac/WKView.mm is a thin shell over
// WebViewImpl, which drives text input through the asynchronous NSTextInputClient protocol (10.11+).
// 10.9's AppKit speaks the synchronous protocol; this WKView answers it by waiting, with a bound, on
// upstream's text-input reply messages. It is implemented against WebPageProxy directly, with
// AquaWebKitPageClient as its PageClient.
//
// This lives in its own file so that UIProcess/API/mac/WKView.mm stays BYTE-UPSTREAM: a whole-file
// reimplementation written over the upstream file would be a ~900-line divergence that every upstream
// merge has to re-resolve. Only the build lists differ -- WebKitPlatformAquaWebKit.cmake withholds
// WKView.mm from SourcesCocoa.txt and appends this file to WebKit_SOURCES. Same shape as
// platform/cocoa/AquaWebKitWebCoreGlue.mm.

#import <objc/runtime.h>

#import "config.h"
// include the public WKView.h (not WKViewInternal.h) — this is a standalone reimplementation, not the upstream PLATFORM(MAC) WebViewImpl wrapper.
#import "WKView.h"
// WKViewPrivate.h carries the Safari-7 WKView SPI declarations implemented
// below (the WKContentAnchor enum, the view-in-window deferral family, the async drawing-area
// size-update pair, and the automatic-substitution flags).
#import "WKViewPrivate.h"
#import <WebKit/WKShareSheet.h>

#import "APIPageConfiguration.h"
#import "LegacyExtensionHiddenTabs.h"
#import "NativeWebKeyboardEvent.h"
#import "NativeWebMouseEvent.h"
#import "NativeWebWheelEvent.h"
#import "PageClient.h"
#import "WKAPICast.h"
#import "WebPageGroup.h"
#import "WebPageProxy.h"
#import "WebPageMessages.h"
#import "WebPreferences.h"
#import "WebPreferencesKeys.h"
#import "WebProcessPool.h"
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
// LOG_ERROR, used by the spelling/substitutions panel actions below.
#import "Logging.h"
// process-global TextChecker state, which the automatic quote/dash
// substitution SPI below reads and writes.
#import "TextChecker.h"
// pinch/smart magnify and swipe navigation (see the magnification section below).
#import "ViewGestureController.h"
// promised-file drag support (see the promised-data section below).
#import "PasteboardTypes.h"
#import <WebCore/LegacyNSPasteboardTypes.h>
#import <wtf/FileSystem.h>
#import "TextCheckerState.h"
#import "WebEventFactory.h"
#import "WebProcessProxy.h"
#import "WebUserContentControllerProxy.h"
#import "WebKit2Initialize.h"
#import "DrawingAreaProxy.h"
#import "WKPrintingView.h"
#import "WebFrameProxy.h"
// legacy ObjC group/controller classes that QuickLook's
// Web2.qldisplay drives through WKView.
#import "WKBrowsingContextControllerInternal.h"
#import "WKProcessGroupPrivate.h"
#import "WKBrowsingContextGroupPrivate.h"
#import <WebCore/ActivityState.h>
#import <WebCore/ColorCocoa.h>
#import <WebCore/Editor.h>
#import <WebCore/FloatPoint.h>
#import <WebCore/FloatRect.h>
#import <WebCore/IntSize.h>
#import <WebCore/KeypressCommand.h>
#import <WebCore/LoaderNSURLExtras.h>
#import <WebCore/LocalizedStrings.h>
#import <WebCore/Pasteboard.h>
#import <WebCore/PasteboardCustomData.h>
#import <WebCore/PromisedAttachmentInfo.h>
#import <pal/spi/mac/NSPasteboardSPI.h>
#import "APIAttachment.h"
#import "WKErrorInternal.h"
#import <WebCore/TextAlternativeWithRange.h>
#import <WebCore/TextUndoInsertionMarkupMac.h>
#import <pal/spi/mac/NSTextInputContextSPI.h>
// needed so the WKView NSTextInputClient implementation can insert text, drive
// inline-IME composition, and answer the synchronous text-input queries 10.9 AppKit makes (#63).
#import "EditingRange.h"
#import "EditorState.h"
#import "InsertTextOptions.h"
#import <WebCore/AttributedString.h>
#import <WebCore/CompositionUnderline.h>
#import <wtf/SetForScope.h>
#import <wtf/text/MakeString.h>
// WebCoreFullScreenWindow backs the restored -createFullScreenWindow SPI.
#import <WebCore/WebCoreFullScreenWindow.h>
#import <QuartzCore/QuartzCore.h>
#import <wtf/RetainPtr.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/Vector.h>
// Services support — advertise the web selection to AppKit's Services
// machinery (the app-menu Services submenu and the context-menu services). The standalone
// WKView talks to WebPageProxy directly (no WebViewImpl), so these are wired here.
#import "EditorState.h"
#import "PasteboardTypes.h"
#import <WebCore/LegacyNSPasteboardTypes.h>
#import <WebCore/SharedBuffer.h>
#if ENABLE(DRAG_SUPPORT)
#import "PasteboardTypes.h"
#import "SandboxExtension.h"
#import <WebCore/DragData.h>
#import <WebCore/DragActions.h>
// file drops: the network-process grant, coordinated reads and promised-file MIME types.
#import "NetworkProcessMessages.h"
#import "NetworkProcessProxy.h"
#import "WebsiteDataStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <wtf/BlockPtr.h>
#import <wtf/Box.h>
#import <wtf/RunLoop.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/darwin/DispatchExtras.h>
#import <WebCore/PlatformEventFactoryMac.h>
// _NSRecommendedScrollerStyle(), used to pick the mouse-tracking-area options.
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <pal/spi/mac/NSWindowSPI.h> // NSWindowDidOrderOn/OffScreenNotification for the visibility observers.
// the WK2 remote-accessibility bridge below — NSAccessibilityRemoteUIElement,
// the AXObjectCache enable-on-demand gate, and makeVector for the token payloads.
#import <pal/spi/cocoa/NSAccessibilitySPI.h>
#import <WebCore/AXObjectCache.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/Compiler.h>
#endif

// this WKView reimplementation uses WebKit:: types unqualified throughout.
using namespace WebKit;

// the page-client factory and accessors defined in AquaWebKitPageClient.mm.
namespace WebKit {
std::unique_ptr<PageClient> createAquaWebKitPageClient(NSView *view);
void setAquaWebKitPageClientPage(PageClient&, WebPageProxy *);
void aquaWebKitPageClientViewWillDeallocate(PageClient&);
void aquaWebKitPageClientViewWillMoveToAnotherWindow(PageClient&);
void aquaWebKitPageClientViewDidChangeBackingProperties(PageClient&);
void setAquaWebKitPageClientWindowOcclusionDetectionEnabled(PageClient&, bool);
bool aquaWebKitPageClientWindowOcclusionDetectionEnabled(PageClient&);
void aquaWebKitPageClientShareSheetDidDismiss(PageClient&, WKShareSheet *);
#if ENABLE(FULLSCREEN_API)
NSView *aquaWebKitPageClientFullScreenPlaceholderView(PageClient&);
#endif
}

struct WKViewInterpretKeyEventsParameters {
    Vector<WebCore::KeypressCommand>& commands;
    bool consumedByIM;
    bool eventInterpretationHadSideEffects { false };
};

template<typename Message, typename ReplyHandler>
static bool waitForTextInputReply(WebPageProxy& page, Message&& message, ReplyHandler&& replyHandler)
{
    if (!page.hasRunningProcess())
        return false;
    Ref process = page.legacyMainFrameProcess();
    if (!process->hasConnection())
        return false;
    Ref connection = process->connection();
    auto replyID = process->sendWithAsyncReply(WTF::move(message), std::forward<ReplyHandler>(replyHandler), page.webPageIDInMainFrameProcess());
    if (!replyID)
        return false;
    return connection->waitForAsyncReplyAndDispatchImmediately<Message>(*replyID, 1_s) == IPC::Error::NoError;
}

// Per-view ownership and AppKit event-interpretation state.
// The promised-file contexts WebViewImpl.mm defines, which drags out of the view carry.
@interface WKPromisedAttachmentContext : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier fileName:(NSString *)fileName;
@property (nonatomic, readonly) NSString *fileName;
@property (nonatomic, readonly) NSString *attachmentIdentifier;
@end

@interface WKPromisedImageContext : NSObject
- (instancetype)initWithFileName:(NSString *)fileName data:(NSData *)data url:(NSString *)url;
@property (nonatomic, readonly) NSString *fileName;
@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) NSString *url;
@end

// Mirrors WebViewImpl::PromisedImageDragData, with the image's bytes, which are all the page client has of it.
struct WKPromisedImageDragData {
    RetainPtr<NSData> imageData;
    RetainPtr<NSString> filename;
    RetainPtr<NSString> title;
    RetainPtr<NSString> url;
    RetainPtr<NSString> visibleURL;
    RetainPtr<NSString> imageUTI;
    RetainPtr<NSData> archiveData;
    RetainPtr<NSString> originIdentifier;
};

struct WKViewState {
    std::unique_ptr<WebKit::PageClient> pageClient;
    RefPtr<WebKit::WebPageProxy> page;
    HashMap<String, Vector<RetainPtr<id<NSValidatedUserInterfaceItem>>>> validationMap;
    WKViewInterpretKeyEventsParameters* interpretKeyEventsParameters { nullptr };
    // pinch-to-zoom / smart-magnify / swipe-navigation state, mirroring
    // WebViewImpl's m_allowsMagnification, m_allowsBackForwardNavigationGestures and
    // m_gestureController. The controller is created lazily, exactly as
    // WebViewImpl::ensureGestureController does.
    bool allowsMagnification { false };
    bool allowsBackForwardNavigationGestures { false };
    RefPtr<WebKit::ViewGestureController> gestureController;
    // mirrors WebViewImpl::m_promisedImageDragData: the image a drag out of the page promises as a file.
    std::optional<WKPromisedImageDragData> promisedImageDragData;
    // mirrors WebViewImpl::m_lastMouseDownEvent: the left mouse-down until its mouse-up, which starts a drag
    // session or a window drag.
    RetainPtr<NSEvent> lastMouseDownEvent;
    // mirrors WebViewImpl::m_ignoresMouseDraggedEvents: set once a drag session ends, until the next mouse-down.
    bool ignoresMouseDraggedEvents { false };
#if ENABLE(DRAG_SUPPORT)
    // mirrors WebViewImpl::m_initialNumberOfValidItemsForDrop.
    NSInteger initialNumberOfValidItemsForDrop { 0 };
#endif
    // the unhandled key-down currently being re-dispatched to AppKit
    // (mirrors WebViewImpl::m_keyDownEventBeingResent); performKeyEquivalent:/keyDown:
    // pass it to super instead of re-entering the page.
    RetainPtr<NSEvent> keyDownEventBeingResent;
    // the WK2 remote-accessibility bridge, mirroring WebViewImpl's
    // m_remoteAccessibilityChild / m_remoteAccessibilityChildToken / m_registeredRemoteAccessibilityPids.
    // remoteAccessibilityChild is the WebContent process's AX tree seen from here; the view vends it
    // as its one accessibility child, which is what puts an AXWebArea under Safari's window.
    RetainPtr<NSAccessibilityRemoteUIElement> remoteAccessibilityChild;
    RetainPtr<NSData> remoteAccessibilityChildToken;
    // Safari 7's content-anchor SPI — the corner painted content stays
    // pinned to while frame-size updates are disabled (see -setContentAnchor:).
    WKContentAnchor contentAnchor { WKContentAnchorTopLeft };
    // accumulated content-anchor shift of the hosted layer, and the
    // -disableFrameSizeUpdates nesting count that gates the drawing-area size push (both
    // mirror the 537 WKView's _frameOrigin / _frameSizeUpdatesDisabledCount).
    NSPoint frameOrigin { 0, 0 };
    unsigned frameSizeUpdatesDisabledCount { 0 };
    // pending scroll compensation from -setFrame:andScrollBy:, mirroring
    // WebViewImpl::m_scrollOffsetAdjustment. Consumed by the next drawing-area size push.
    NSSize scrollOffsetAdjustment { 0, 0 };
    // view-in-window-change deferral state (mirrors WebViewImpl's
    // m_shouldDeferViewInWindowChanges / m_viewInWindowChangeWasDeferred). While deferring,
    // -viewDidMoveToWindow records the IsInWindow change here instead of pushing it;
    // -endDeferringViewInWindowChanges[Sync] pushes the coalesced change.
    bool shouldDeferViewInWindowChanges { false };
    bool viewInWindowChangeWasDeferred { false };
    // Safari-7 -[WKView setShouldClipToVisibleRect:] state (mirrors
    // WebViewImpl::m_clipsToVisibleRect). When set, the page's view-exposed-rect is pinned to
    // the view's visible rect so the tiled drawing area only backs visible content. iBooks'
    // BKWKViewTiling sends -setShouldClipToVisibleRect:YES right after creating the view.
    bool shouldClipToVisibleRect { false };
    // a window-and-view-frames push is scheduled (WebViewImpl::m_didScheduleWindowAndViewFrameUpdate).
    bool didScheduleWindowAndViewFrameUpdate { false };
};

// consume the pending -setFrame:andScrollBy: delta on a geometry push, mirroring
// WebViewImpl::setDrawingAreaSize (mac/WebViewImpl.mm:1900-1903), which passes the accumulated
// adjustment to DrawingAreaProxy::setSize and then clears it.
static WebCore::IntSize wkTakeScrollOffsetAdjustment(WKViewState* state)
{
    if (!state)
        return { };
    WebCore::IntSize offset(state->scrollOffsetAdjustment.width, state->scrollOffsetAdjustment.height);
    state->scrollOffsetAdjustment = NSZeroSize;
    return offset;
}

// WKContentAnchor corner tests, restored from the Safari-537-era WKView.mm.
static inline bool isWKContentAnchorRight(WKContentAnchor x)
{
    return x == WKContentAnchorTopRight || x == WKContentAnchorBottomRight;
}

static inline bool isWKContentAnchorBottom(WKContentAnchor x)
{
    return x == WKContentAnchorBottomLeft || x == WKContentAnchorBottomRight;
}

// NSApplication SPI WebViewImpl::doneWithKeyEvent uses when re-dispatching
// an unhandled key-down back to AppKit, so [NSApp currentEvent] matches during menu dispatch.
@interface NSApplication (WKAquaWebKitKeyResend)
- (void)_setCurrentEvent:(NSEvent *)event;
@end

// the speech SPI -startSpeaking:/-stopSpeaking: below forward to, declared the
// same way WebViewImpl.mm and WebHTMLView.mm declare it -- AppKit has never exposed these two in a
// public header, so the calls ported from WebViewImpl need the declaration to come along with them.
@interface NSApplication (WKAquaWebKitSpeech)
- (void)speakString:(NSString *)string;
- (void)stopSpeaking:(id)sender;
- (BOOL)isSpeaking;
@end

@interface WKView () <WKShareSheetDelegate, NSDraggingSource, NSFilePromiseProviderDelegate> {
    WKViewState *_wkState;
    WKBrowsingContextController *_browsingContextController;
    // cached intrinsic content size for the auto-layout SPI Mail's
    // MUIWKView drives (the web process reports the laid-out content size back via
    // AquaWebKitPageClient::intrinsicContentSizeDidChange -> -_setIntrinsicContentSize:).
    NSSize _intrinsicContentSize;
}
// private helper backing the clip-to-visible-rect SPI (see -setShouldClipToVisibleRect:).
- (void)_updateViewExposedRect;
// runs AppKit's key-binding translation for one event (see the definition).
- (BOOL)_aquaWebKitCollectKeypressCommands:(NSEvent *)event into:(WTF::Vector<WebCore::KeypressCommand>&)commands;
@end

@implementation WKView

// designated initializer — creates a WebPageProxy and page client for this view.
- (instancetype)initWithFrame:(NSRect)frame processPool:(std::reference_wrapper<WebKit::WebProcessPool>)processPool configuration:(Ref<API::PageConfiguration>&&)configuration
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    // layer-back the view and paint a white base so empty/loading pages aren't black.
    [self setWantsLayer:YES];
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);

    // start with a flexible intrinsic size until the web process reports a laid-out one.
    _intrinsicContentSize = NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);

    // ensure WebKit2 globals are initialized before creating the page proxy.
    WebKit::InitializeWebKit2();

    // 2013 MailUI predates API::PageConfiguration's corsDisablingPatterns, which modern MailUI sets so a
    // message's remote subresources load under the app's own remote-content consent rather than web
    // CORS/CORP rules (a message document's x-webdoc:// origin can never satisfy them).
    if (WTF::MacApplication::isAppleMail() && configuration->corsDisablingPatterns().isEmpty())
        configuration->setCORSDisablingPatterns({ "*://*/*"_s });

    // 2013 Safari serves an extension's resources over safari-extension:// through the network process,
    // where modern Safari's arrive through a WKURLSchemeHandler that answers in the web process and
    // never meets a cross-origin resource policy. LegacySchemeRegistry::isUserExtensionScheme carries
    // upstream's own exemption for those resources, and its FIXME names corsDisablingPatterns as what
    // replaces it once Safari adopts the modern surface; this Safari never will.
    if (WTF::MacApplication::isSafari() && configuration->corsDisablingPatterns().isEmpty())
        configuration->setCORSDisablingPatterns({ "safari-extension://*/*"_s });

    // The Network process reads the pool's process model through ephemeral page preferences.
    Ref preferences = configuration->preferences();
    preferences->setBoolValueForKey(WebKit::WebPreferencesKey::usesSingleWebProcessKey(), processPool.get().usesSingleWebProcess(), true);
    preferences->setBoolValueForKey(WebKit::WebPreferencesKey::processSwapOnCrossSiteNavigationEnabledKey(), processPool.get().configuration().processSwapsOnNavigation(), true);

    // 537 started the network process at page creation along with the web process (see the eager launch
    // below), so the data store's network session exists when the page joins the store.
    configuration->websiteDataStore().networkProcess();

    // allocate the per-view state holding the page proxy and page client.
    _wkState = new WKViewState;
    _wkState->pageClient = createAquaWebKitPageClient(self);
    _wkState->page = processPool.get().createWebPage(*_wkState->pageClient, WTF::move(configuration));
    setAquaWebKitPageClientPage(*_wkState->pageClient, _wkState->page.get());
    [self _wk_updateIntrinsicDeviceScaleFactor];

    // bring up the WebPage now that the page proxy + client are wired.
    auto& pageConfiguration = _wkState->page->configuration();
    _wkState->page->initializeWebPage(pageConfiguration.openedSite(), pageConfiguration.initialSandboxFlags(), pageConfiguration.initialReferrerPolicy());

    // legacy WebKit2 launched the context's web process as soon as a page
    // existed, and embedders sequence on the resulting connection callback — WKProcessGroup's
    // -processGroup:didCreateConnectionToWebProcessPlugIn: fires at web-process launch, and
    // iBooks won't load anything into a fresh document worker's view until that callback hands
    // it the connection. Modern WebKit defers the launch to the first load, which deadlocks that
    // pattern (no load -> no launch -> no callback -> iBooks' 60s watchdog). Launch eagerly, as
    // 537 did via ensureSharedWebProcess at page creation (no-op if a real process already runs;
    // launchProcess re-runs initializeWebPage against the launched process via
    // finishAttachingToWebProcess, replacing the drawing area created above). A createNewPage()-prepared
    // page that launches at its first load keeps that launch (see the C-ref initializer).
    if (!(pageConfiguration.windowFeatures() && pageConfiguration.delaysWebProcessLaunchUntilFirstLoad()))
        _wkState->page->launchInitialProcessIfNecessary();

    // tell AppKit which pasteboard types this view can supply from / accept into the
    // selection, so the Services machinery offers services for the web selection (app-menu Services submenu
    // and context-menu services). Ported from WebViewImpl's constructor (which this WKView does not use).
    [NSApp registerServicesMenuSendTypes:WebKit::PasteboardTypes::forSelectionSingleton() returnTypes:WebKit::PasteboardTypes::forEditingSingleton()];

    // mouse-tracking area so this view receives mouseMoved:/mouseEntered:/
    // mouseExited: regardless of first-responder status — AppKit routes plain NSMouseMoved window
    // events to the first responder alone, which an embedder can keep elsewhere (Mail's message
    // list stays first responder while the body WKView shows a message), and cursor changes and
    // CSS :hover depend on those events. Options match Safari 7 WebKit2's
    // -[WKView initWithFrame:contextRef:pageGroupRef:relatedToPage:]: legacy scrollbars have
    // design details that rely on tracking the mouse all the time, overlay scrollbars only need
    // tracking while the window is key. (WebViewImpl::trackingAreaOptions() additionally sets
    // NSTrackingCursorUpdate, which is for a cursorUpdate: handler this view does not have.)
    NSTrackingAreaOptions trackingOptions = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect;
    trackingOptions |= _NSRecommendedScrollerStyle() == NSScrollerStyleLegacy ? NSTrackingActiveAlways : NSTrackingActiveInKeyWindow;
    RetainPtr<NSTrackingArea> trackingArea = adoptNS([[NSTrackingArea alloc] initWithRect:frame options:trackingOptions owner:self userInfo:nil]);
    [self addTrackingArea:trackingArea.get()];

#if ENABLE(DRAG_SUPPORT)
    // become an NSDraggingDestination so drops route into the page.
    auto dragTypes = adoptNS([[NSMutableSet alloc] initWithArray:WebKit::PasteboardTypes::forEditingSingleton()]);
    [dragTypes addObjectsFromArray:WebKit::PasteboardTypes::forURLSingleton()];
    [dragTypes addObject:WebKit::PasteboardTypes::WebDummyPboardType];
    [self registerForDraggedTypes:[dragTypes allObjects]];
#endif

    return self;
}

// tear down the backported per-view state (page proxy, page client, cached controller).
- (void)dealloc
{
    // stop observing backing-scale changes (registered in -viewDidMoveToWindow for the Retina fix).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    // stop observing screen changes (registered in -viewDidMoveToWindow for the display-link wiring).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    // stop observing window visibility/key-state changes (registered in -viewDidMoveToWindow).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidOrderOnScreenNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidOrderOffScreenNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMiniaturizeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidDeminiaturizeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMoveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    // configurationRef: can release an unconfigured view; configured views close with their PageClient alive.
    if (_wkState) {
        [self _aquaWebKitUpdateRemoteAccessibilityRegistration:NO];
        aquaWebKitPageClientViewWillDeallocate(*_wkState->pageClient);
        _wkState->page->close();
    }
    // release the lazily-created browsing-context controller and delete the WKViewState.
    [_browsingContextController release];
    _browsingContextController = nil;
    delete _wkState;
    _wkState = nullptr;
    [super dealloc];
}

// WKView auto-layout / intrinsic-content-size SPI, ported from WebViewImpl.
// Mail's message viewer (MUIWKView) drives the message view through this: it enables auto-sizing
// with -setMinimumSizeForAutoLayout:, and the web process reports the laid-out content height back
// so the view sizes to fit the message inside Mail's scroll view.
- (NSSize)intrinsicContentSize
{
    return _intrinsicContentSize;
}

// Safari-7 auto-layout SPI -setMinimumSizeForAutoLayout: (declared in WKViewPrivate.h), ported from WebViewImpl.
- (void)setMinimumSizeForAutoLayout:(NSSize)minimumSizeForAutoLayout
{
    // Matches WebViewImpl::setMinimumSizeForAutoLayout: a positive minimum width enables
    // auto-sizing (the web process lays out at >= this width and reports the content height
    // back via intrinsicContentSizeDidChange), and the main frame becomes non-scrollable so
    // it grows to fit instead of clipping. Mail relies on this to size each message body.
    BOOL expandsToFit = minimumSizeForAutoLayout.width > 0;
    _wkState->page->setMinimumSizeForAutoLayout(WebCore::IntSize(minimumSizeForAutoLayout.width, minimumSizeForAutoLayout.height));
    _wkState->page->setMainFrameIsScrollable(!expandsToFit);
}

// auto-layout SPI getter for the configured minimum layout size (ported from WebViewImpl).
- (NSSize)minimumSizeForAutoLayout
{
    auto size = _wkState->page->minimumSizeForAutoLayout();
    return NSMakeSize(size.width(), size.height());
}

// auto-layout SPI — let auto-sizing expand to fill the view height (ported from WebViewImpl for Mail).
- (void)setShouldExpandToViewHeightForAutoLayout:(BOOL)shouldExpand
{
    _wkState->page->setAutoSizingShouldExpandToViewHeight(shouldExpand);
}

// auto-layout SPI getter mirroring WebViewImpl::shouldExpandToViewHeightForAutoLayout.
- (BOOL)shouldExpandToViewHeightForAutoLayout
{
    return _wkState->page->autoSizingShouldExpandToViewHeight();
}

// called by AquaWebKitPageClient::intrinsicContentSizeDidChange when the web
// process reports a new laid-out content size.
- (void)_setIntrinsicContentSize:(NSSize)intrinsicContentSize
{
    // A content width below the minimum layout width means the content flowed to fit, so report the
    // width as flexible; otherwise report it so auto-layout reserves space. Matches WebViewImpl.
    NSSize size = intrinsicContentSize;
    if (intrinsicContentSize.width < _wkState->page->minimumSizeForAutoLayout().width())
        size.width = NSViewNoIntrinsicMetric;
    _intrinsicContentSize = size;
    [self invalidateIntrinsicContentSize];
}

// C-ref WKView initializer Safari/QuickLook use; forwards to the relatedToPage: variant.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef
{
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef relatedToPage:nil];
}

// build an API::PageConfiguration from the C refs and route through the designated initializer.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef relatedToPage:(WKPageRef)relatedPage
{
    // A view built inside a createNewPage() callback hosts the page that callback opens: start from the
    // configuration createNewPage() prepared for it (window features, opened main-frame name, opener,
    // initial sandbox flags and referrer policy), as a configuration-based client would.
    RefPtr<API::PageConfiguration> configuration = WebKit::WebPageProxy::takeConfigurationOfPageBeingOpened();
    if (!configuration) {
        configuration = API::PageConfiguration::create();
        // A C API page shares its context's visited links, which WKContextAddVisitedLink writes, as in
        // WebKit 601's WebProcessPool::createWebPage; a prepared configuration carries its opener's.
        configuration->setVisitedLinkStore(&WebKit::toImpl(contextRef)->visitedLinkStore());
    }
    configuration->setProcessPool(WebKit::toImpl(contextRef));
    // honor the page group Safari passes — its identifier is
    // how the injected bundle scopes extension content scripts
    // (WKBundleAddUserScript), and its preferences carry Safari's settings.
    if (pageGroupRef) {
        RefPtr<WebKit::WebPageGroup> pageGroup = WebKit::toImpl(pageGroupRef);
        configuration->setPreferences(&pageGroup->preferences());
        // share the page group's user content controller so user
        // scripts/style sheets installed on the group (WKPageGroupAddUserScript /
        // AddUserStyleSheet, e.g. via Mail's WKBrowsingContextGroup) are injected
        // into this page.
        configuration->setUserContentController(&pageGroup->userContentController());
        configuration->setPageGroup(WTF::move(pageGroup));
    }

    // honor relatedToPage — the related page pins this page into the same
    // WebProcess (WebProcessPool::createWebPage uses relatedPage->ensureRunningProcess()).
    // Safari's SearchableWKView passes the current tab's page here; Safari Reader depends on it:
    // the reader page's injected-bundle controller resolves the browser page's article finder
    // in-process (ReaderWebProcessController::originalArticleFinder walks a same-process
    // WKBundlePage link), and the extracted article DOM node is adopted across the two pages.
    if (relatedPage)
        configuration->setRelatedPage(protect(WebKit::toImpl(relatedPage)));

    // Safari 7 builds this view at a zero frame and places it after this initializer returns, and the
    // WebPage sizes a popup against the view size it is created with, so a createNewPage()-prepared page
    // that launches at its first load keeps that launch: WebProcessPool::createWebPage takes a related
    // page's running process ahead of a delayed launch, so the page is created without its related page
    // and takes it back for launchProcess, which honors it.
    RefPtr<WebKit::WebPageProxy> relatedPageForLaunch;
    if (configuration->windowFeatures() && configuration->delaysWebProcessLaunchUntilFirstLoad()) {
        relatedPageForLaunch = configuration->relatedPage();
        configuration->setRelatedPage({ });
    }

    RefPtr<API::PageConfiguration> pageConfiguration = configuration;
    self = [self initWithFrame:frame processPool:*WebKit::toImpl(contextRef) configuration:configuration.releaseNonNull()];
    if (self && relatedPageForLaunch)
        pageConfiguration->setRelatedPage(WeakPtr { *relatedPageForLaunch });
    return self;
}

- (id)initWithFrame:(NSRect)frame configurationRef:(WKPageConfigurationRef)configurationRef { [self release]; return nil; }
- (WKPageRef)pageRef { return WebKit::toAPI(_wkState->page.get()); }

// QuickLook previews use Safari's cookies (WKBrowsingContextController), so their data store prevents
// cross-site tracking exactly when Safari 7 does: for any account cookie accept policy but Always.
static void followSafariTrackingPreventionForQuickLookPreviews()
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        auto apply = [] {
            bool preventsTracking = [NSHTTPCookieStorage sharedHTTPCookieStorage].cookieAcceptPolicy != NSHTTPCookieAcceptPolicyAlways;
            WebKit::WebsiteDataStore::defaultDataStore().setTrackingPreventionEnabled(preventsTracking);
        };
        apply();
        [[NSDistributedNotificationCenter defaultCenter] addObserverForName:NSHTTPCookieManagerAcceptPolicyChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *) {
            apply();
        }];
    });
}

// legacy initializer used by QuickLook's Web2.qldisplay. It hands
// us a WKProcessGroup + WKBrowsingContextGroup; unwrap them to the underlying
// WKContextRef/WKPageGroupRef and route through the existing C-ref init path.
- (id)initWithFrame:(NSRect)frame processGroup:(WKProcessGroup *)processGroup browsingContextGroup:(WKBrowsingContextGroup *)browsingContextGroup
{
    WKContextRef contextRef = processGroup ? [processGroup _contextRef] : nullptr;
    if (!contextRef) {
        [self release];
        return nil;
    }
    WKPageGroupRef pageGroupRef = browsingContextGroup ? [browsingContextGroup _pageGroupRef] : nullptr;
    if (pageGroupRef && WebKit::toImpl(pageGroupRef)->identifier() == "QuickLookPreview"_s)
        followSafariTrackingPreventionForQuickLookPreviews();
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef];
}

// vend a controller bound to this view's page so Web2.qldisplay
// can load/observe via the controller (or pull its pageRef for the C SPI).
- (WKBrowsingContextController *)browsingContextController
{
    if (!_browsingContextController)
        _browsingContextController = [[WKBrowsingContextController alloc] _initWithPageRef:WebKit::toAPI(_wkState->page.get())];
    return _browsingContextController;
}

// propagate the new viewport size to WebContent via WebPageProxy::setSize.
// Safari creates WKViews with a zero frame and resizes them later, so this is what gives the web
// process a real viewport.
//
// The Safari-537-era frame-size-updates gate and content-anchor shift are ported in here:
// Safari 7's resize animations run disableFrameSizeUpdates → -setFrameSize: (repeatedly) →
// forceAsyncDrawingAreaSizeUpdate: → waitForAsyncDrawingAreaSizeUpdate →
// enableFrameSizeUpdates. While updates are disabled, the drawing-area push is skipped and
// the hosted layer is shifted so the already-painted content stays pinned to the corner
// Safari chose with -setContentAnchor: (the 537 setFrameSize: _frameOrigin/rootLayer.position
// mechanism); -enableFrameSizeUpdates then pushes the settled frame size and clears the shift.
- (void)setFrameSize:(NSSize)newSize
{
    // compute the anchor-shifted content origin against the OLD frame size,
    // before super updates it (mirrors the 537 setFrameSize: ordering).
    bool frameSizeUpdatesEnabled = ![self frameSizeUpdatesDisabled];
    NSPoint newFrameOrigin = NSZeroPoint;
    if (!frameSizeUpdatesEnabled) {
        newFrameOrigin = _wkState->frameOrigin;
        if (isWKContentAnchorRight(_wkState->contentAnchor))
            newFrameOrigin.x += [self frame].size.width - newSize.width;
        if (isWKContentAnchorBottom(_wkState->contentAnchor))
            newFrameOrigin.y += [self frame].size.height - newSize.height;
    }

    [super setFrameSize:newSize];

    if (frameSizeUpdatesEnabled) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(newSize.width, newSize.height), wkTakeScrollOffsetAdjustment(_wkState));
        // keep the clipped view-exposed-rect matched to the new visible rect.
        if (_wkState->shouldClipToVisibleRect)
            [self _updateViewExposedRect];
    }
    // the WebContent's render layer lives in AquaWebKitPageClient's dedicated
    // layer-hosting subview (autoresized with us), unframed — so plain resizes need no layer
    // fix-up. Only the 537 content-anchor shift is applied here: while frame-size updates are
    // disabled the render layer's position moves by the accumulated size delta so the painted
    // content stays pinned to the anchored corner, and the outermost re-enable (or the next
    // enabled-state resize) puts it back. This view is flipped, so the top-left-origin math of
    // the 537 shift (rootLayer.position = -newFrameOrigin) carries over directly.
    CALayer *renderLayer = _wkState->pageClient->acceleratedCompositingRootLayer();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (frameSizeUpdatesEnabled) {
        if (!NSEqualPoints(_wkState->frameOrigin, NSZeroPoint)) {
            _wkState->frameOrigin = NSZeroPoint;
            [renderLayer setPosition:CGPointZero];
        }
    } else {
        _wkState->frameOrigin = newFrameOrigin;
        [renderLayer setPosition:CGPointMake(-newFrameOrigin.x, -newFrameOrigin.y)];
    }
    [CATransaction commit];
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    // honor the frame-size-updates gate here too — while Safari has called
    // -disableFrameSizeUpdates, no frame change reaches the drawing area until
    // -enableFrameSizeUpdates pushes the settled size.
    if (![self frameSizeUpdatesDisabled]) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(frame.size.width, frame.size.height), wkTakeScrollOffsetAdjustment(_wkState));
    }
    [self _updateViewExposedRect];
}

// moving this view within its superview changes which part of it is visible
// but fires no other geometry hook (layer-backed views rarely get -renewGState). iBooks' reader
// turns pages by SLIDING its wide paginated strip view via frame-origin changes, so the clipped
// view-exposed rect must follow here or the newly exposed page region is never painted.
- (void)setFrameOrigin:(NSPoint)origin
{
    [super setFrameOrigin:origin];
    [self _updateViewExposedRect];
}

// the display pass that follows any layout/attach reaches -viewWillDraw with
// FINAL geometry, so the clipped view-exposed rect is refreshed here. A view swapped into a window
// at its final position (iBooks installs each chapter's strip view this way) gets no
// frame/origin/gstate hook afterwards, and its -visibleRect at -viewDidMoveToWindow time is empty.
- (void)viewWillDraw
{
    [self _updateViewExposedRect];
    [super viewWillDraw];
}

// Safari-7 clip-to-visible-rect SPI, declared in WKViewPrivate.h and ported
// from WebViewImpl::{setClipsToVisibleRect,clipsToVisibleRect,updateViewExposedRect}. iBooks'
// BKWKViewTiling sends -setShouldClipToVisibleRect:YES unguarded when wiring up its page.
- (BOOL)shouldClipToVisibleRect
{
    return _wkState->shouldClipToVisibleRect;
}

- (void)setShouldClipToVisibleRect:(BOOL)clipsToVisibleRect
{
    _wkState->shouldClipToVisibleRect = clipsToVisibleRect;
    [self _updateViewExposedRect];
}

// pin the page's view-exposed-rect to the view's visible rect while clipping
// is on (nullopt = no restriction). Mirrors WebViewImpl::updateViewExposedRect; refreshed from the
// geometry hooks below so a view that turned clipping on while zero-sized/out-of-window (iBooks
// enables it before attaching the view to a window) does not stay clipped to an empty rect.
- (void)_updateViewExposedRect
{
    CGRect exposedRect = NSRectToCGRect([self visibleRect]);
    _wkState->page->setViewExposedRect(_wkState->shouldClipToVisibleRect ? std::optional<WebCore::FloatRect>(exposedRect) : std::nullopt);
}

// content-anchor SPI, declared in WKViewPrivate.h (with the restored
// WKContentAnchor enum) and sent unguarded by Safari 7 around its gated resize animations
// (-disableFrameSizeUpdates … -enableFrameSizeUpdates). The Safari-537-era anchoring had two
// halves, and this port restores the UI-process half: while frame-size updates are disabled,
// -setFrameSize: shifts the hosted layer by the accumulated size delta so the already-painted
// content stays pinned to the anchored corner (537's rootLayer.position = -_frameOrigin shift).
// The web-process half is gone from modern WebKit: 537's geometry update carried a layer offset
// (DrawingAreaProxy::setSize(size, layerOffset, scrollOffset) → TiledCoreAnimationDrawingArea::
// updateGeometry) that kept the FRESHLY painted new-size layout anchored too, whereas the modern
// UpdateGeometry message is only (viewSize, flushSynchronously, fencePort) with no offset for
// the web process to apply. So when -enableFrameSizeUpdates pushes the settled size, the anchor
// shift is cleared in the same transaction and the fenced new-size layout swaps in
// top-left-aligned — the anchor holds throughout the animation, not across the final repaint.
- (void)setContentAnchor:(WKContentAnchor)contentAnchor
{
    _wkState->contentAnchor = contentAnchor;
}

// Content-anchor getter.
- (WKContentAnchor)contentAnchor
{
    return _wkState->contentAnchor;
}

// async drawing-area size-update SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7, typically while frame-size updates are disabled (the force bypasses
// the -disableFrameSizeUpdates gate, which is its entire point). Ported from the Safari-537-era
// -[WKView forceAsyncDrawingAreaSizeUpdate:] against the current drawing-area API: push the
// given size to the drawing area without waiting (the drawn area need not match the view frame),
// then poll with a zero timeout so an already-answered UpdateGeometry dispatches and the fresh
// size can go out immediately — the modern shape of the old zero-timeout
// waitForPossibleGeometryUpdate poll. Like the 537 version, this leaves any content-anchor shift
// in place; -enableFrameSizeUpdates clears it. (The 537 version also refreshed the exposed rect
// when clipping to the visible rect; this WKView has no clips-to-visible-rect machinery, so
// there is no exposed rect to refresh.)
- (void)forceAsyncDrawingAreaSizeUpdate:(NSSize)size
{
    if (RefPtr drawingArea = _wkState->page->drawingArea()) {
        drawingArea->setSize(WebCore::IntSize(size.width, size.height), wkTakeScrollOffsetAdjustment(_wkState));
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds { });
    }
}

// blocking counterpart, ported from the Safari-537-era
// -[WKView waitForAsyncDrawingAreaSizeUpdate]. If a geometry update is still pending then
// receiving its reply may schedule another update (the drawing area resends when the size
// changed while waiting) — wait for that one too, matching the 537 implementation's split of
// the 500ms didUpdateBackingStoreStateTimeout into two half-timeout waits.
- (void)waitForAsyncDrawingAreaSizeUpdate
{
    if (RefPtr drawingArea = _wkState->page->drawingArea()) {
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds::fromMilliseconds(250));
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds::fromMilliseconds(250));
    }
}

// the underlayColor property declared in WKViewPrivate.h, mirroring
// WebViewImpl::setUnderlayColor / underlayColor by delegating straight to the page proxy. Safari 7's
// ContinuousReadingListViewController sends -setUnderlayColor: unguarded to BrowserWKView when it
// opens a Reading List item.
- (void)setUnderlayColor:(NSColor *)underlayColor
{
    _wkState->page->setUnderlayColor(WebCore::colorFromCocoaColor(underlayColor));
}

- (NSColor *)underlayColor
{
    return WebCore::cocoaColorOrNil(_wkState->page->underlayColor()).autorelease();
}

// the drawsBackground / drawsTransparentBackground properties declared in WKView.h, mirroring
// WebViewImpl::setDrawsBackground / drawsBackground / updateLayer and WKWebView's
// _setDrawsTransparentBackground:. Safari 7's ReaderController sends -setDrawsTransparentBackground:YES
// to ReaderWKView so Reader's dimmed backdrop shows around the article.
- (void)setDrawsBackground:(BOOL)drawsBackground
{
    std::optional<WebCore::Color> backgroundColor;
    if (!drawsBackground)
        backgroundColor = WebCore::Color(WebCore::Color::transparentBlack);
    _wkState->page->setBackgroundColor(backgroundColor);
    self.layer.backgroundColor = CGColorGetConstantColor(drawsBackground ? kCGColorWhite : kCGColorClear);
}

- (BOOL)drawsBackground
{
    auto& backgroundColor = _wkState->page->backgroundColor();
    return !backgroundColor || backgroundColor.value().isVisible();
}

- (void)setDrawsTransparentBackground:(BOOL)drawsTransparentBackground
{
    [self setDrawsBackground:!drawsTransparentBackground];
}

- (BOOL)drawsTransparentBackground
{
    return ![self drawsBackground];
}
- (NSArray *)validAttributesForMarkedText
{
    return @[
        NSUnderlineStyleAttributeName,
        NSUnderlineColorAttributeName,
        NSMarkedClauseSegmentAttributeName,
        NSTextAlternativesAttributeName,
        NSTextInsertionUndoableAttributeName,
        NSBackgroundColorAttributeName,
        NSForegroundColorAttributeName,
    ];
}

- (NSTextInputContext *)inputContext
{
    if (!_wkState->page->editorState().isContentEditable)
        return nil;
    return [super inputContext];
}

// The view's input context whatever the page's editor state, as WKView's.
- (NSTextInputContext *)_web_superInputContext
{
    return [super inputContext];
}

- (void)_aquaWebKitExecuteSavedKeypressCommands
{
    auto* parameters = _wkState->interpretKeyEventsParameters;
    if (!parameters || parameters->commands.isEmpty())
        return;

    // Drain before sending so a query reentered by a responder cannot replay commands.
    auto commands = std::exchange(parameters->commands, { });
    Ref page = *_wkState->page;
    auto handled = Box<bool>::create(false);
    if (waitForTextInputReply(page.get(), Messages::WebPage::ExecuteKeypressCommands(commands), [handled](bool result) {
        *handled = result;
    }))
        parameters->eventInterpretationHadSideEffects |= *handled;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    if (actualRange)
        *actualRange = EditingRange();
    auto& state = _wkState->page->editorState();
    if (!state.isContentEditable || state.isInPasswordField)
        return nil;

    struct Result {
        RetainPtr<NSAttributedString> string;
        EditingRange actualRange;
    };
    auto result = Box<Result>::create();
    if (!waitForTextInputReply(*_wkState->page, Messages::WebPage::AttributedSubstringForCharacterRangeAsync(EditingRange { range }), [result](const WebCore::AttributedString& string, const EditingRange& actualRange) {
        result->string = string.nsAttributedString();
        result->actualRange = actualRange;
    }))
        return nil;
    if (actualRange)
        *actualRange = result->actualRange;
    return result->string.autorelease();
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    if (NSWindow *window = [self window])
        point = [window convertPointFromScreen:point];
    point = [self convertPoint:point fromView:nil];
    auto result = Box<uint64_t>::create(0);
    if (!waitForTextInputReply(*_wkState->page, Messages::WebPage::CharacterIndexForPointAsync(WebCore::IntPoint(point)), [result](uint64_t location) {
        *result = location;
    }))
        return 0;
    return *result == notFound ? NSNotFound : *result;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    RetainPtr protectedSelf = self;
    [self _aquaWebKitExecuteSavedKeypressCommands];
    // Match NSTextView's treatment of overflowed ranges (webkit.org/b/4682).
    if ((range.location + range.length < range.location) && (range.location + range.length != 0))
        range.length = 0;
    if (range.location == NSNotFound) {
        if (actualRange)
            *actualRange = range;
        return NSZeroRect;
    }
    if (actualRange)
        *actualRange = EditingRange();

    struct Result {
        WebCore::IntRect rect;
        EditingRange actualRange;
    };
    auto result = Box<Result>::create();
    if (!waitForTextInputReply(*_wkState->page, Messages::WebPage::FirstRectForCharacterRangeAsync(EditingRange { range }), [result](const WebCore::IntRect& rect, const EditingRange& actualRange) {
        result->rect = rect;
        result->actualRange = actualRange;
    }))
        return NSZeroRect;
    if (actualRange)
        *actualRange = result->actualRange;
    NSRect rectInView = result->rect;
    NSRect rectInWindow = [self convertRect:rectInView toView:nil];
    return [[self window] convertRectToScreen:rectInWindow];
}

- (BOOL)hasMarkedText
{
    if (_wkState->interpretKeyEventsParameters) {
        BOOL result = _wkState->page->editorState().hasComposition;
        if (result) {
            [self _aquaWebKitExecuteSavedKeypressCommands];
            result = [self markedRange].location != NSNotFound;
        }
        return result;
    }
    return [self markedRange].location != NSNotFound;
}

- (void)insertText:(id)string
{
    [self insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    // As WebViewImpl::insertText: text from the keyboard layout's key bindings is saved for the key event, which
    // performs it after keydown; text from an input method, which has the page's composition, or from outside key
    // interpretation is inserted now.
    NSString *s;
    Vector<WebCore::TextAlternativeWithRange> dictationAlternatives;
    bool registerUndoGroup = false;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        WebCore::collectDictationTextAlternatives(string, dictationAlternatives);
        registerUndoGroup = WebCore::shouldRegisterInsertionUndoGroup(string);
        s = [(NSAttributedString *)string string];
    } else
        s = (NSString *)string;
    if (!s)
        return;
    auto* parameters = _wkState->interpretKeyEventsParameters;
    if (parameters)
        parameters->consumedByIM = false;
    if (parameters && !_wkState->page->editorState().hasComposition) {
        WebCore::KeypressCommand command("insertText:"_s, String(s), { }, { }, { }, EditingRange { replacementRange }.toCharacterRange());
        parameters->commands.append(command);
        _wkState->page->registerKeypressCommandName(command.commandName);
        return;
    }
    String eventText = makeStringByReplacingAll(String(s), NSBackTabCharacter, NSTabCharacter);
    InsertTextOptions options;
    options.registerUndoGroup = registerUndoGroup;
    if (!dictationAlternatives.isEmpty())
        _wkState->page->insertDictatedTextAsync(eventText, replacementRange, dictationAlternatives, WTF::move(options));
    else
        _wkState->page->insertTextAsync(eventText, replacementRange, WTF::move(options));
    if (parameters)
        parameters->eventInterpretationHadSideEffects = true;
}

- (NSRange)markedRange
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    auto result = Box<EditingRange>::create();
    waitForTextInputReply(*_wkState->page, Messages::WebPage::GetMarkedRangeAsync(), [result](const EditingRange& range) {
        *result = range;
    });
    return *result;
}

- (NSRange)selectedRange
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    auto result = Box<EditingRange>::create();
    waitForTextInputReply(*_wkState->page, Messages::WebPage::GetSelectedRangeAsync(), [result](const EditingRange& range, const EditingRange&) {
        *result = range;
    });
    return *result;
}

- (void)_aquaWebKitNotifyInputContextAboutDiscardedComposition
{
    // rdar://9359055: discardMarkedText requires an active input context.
    if (![[self window] isKeyWindow] || self != [[self window] firstResponder])
        return;
    [[super inputContext] discardMarkedText];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)newSelectedRange replacementRange:(NSRange)replacementRange
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    if (auto* parameters = _wkState->interpretKeyEventsParameters) {
        parameters->eventInterpretationHadSideEffects = true;
        parameters->consumedByIM = false;
    }
    BOOL isAttributed = [string isKindOfClass:[NSAttributedString class]];
    NSString *text = isAttributed ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!text)
        text = @"";
    Vector<WebCore::CompositionUnderline> underlines;
    // WebViewImpl's compositionUnderlines interpretation of AppKit's marked-text attributes.
    if (isAttributed) {
        for (NSUInteger i = 0, length = [text length]; i < length;) {
            NSRange range;
            NSDictionary *attributes = [string attributesAtIndex:i longestEffectiveRange:&range inRange:NSMakeRange(i, length - i)];
            if (NSNumber *style = [attributes objectForKey:NSUnderlineStyleAttributeName]) {
                WebCore::Color color = WebCore::Color::black;
                auto colorType = WebCore::CompositionUnderlineColor::TextColor;
                if (NSColor *underlineColor = [attributes objectForKey:NSUnderlineColorAttributeName]) {
                    color = WebCore::colorFromCocoaColor(underlineColor);
                    colorType = WebCore::CompositionUnderlineColor::GivenColor;
                }
                underlines.append(WebCore::CompositionUnderline(range.location, NSMaxRange(range), colorType, color, [style intValue] > 1));
            }
            i = NSMaxRange(range);
        }
    } else
        underlines.append(WebCore::CompositionUnderline(0, [text length], WebCore::CompositionUnderlineColor::TextColor, WebCore::Color::black, false));
    if (_wkState->page->editorState().isInPasswordField) {
        [self _aquaWebKitNotifyInputContextAboutDiscardedComposition];
        if ([text length] == 1 && [[text decomposedStringWithCanonicalMapping] characterAtIndex:0] < 0x80)
            _wkState->page->insertTextAsync(String(text), replacementRange, InsertTextOptions { });
        else
            NSBeep();
        return;
    }
    _wkState->page->setCompositionAsync(String(text), underlines, { }, { }, newSelectedRange, replacementRange);
}

- (void)unmarkText
{
    [self _aquaWebKitExecuteSavedKeypressCommands];
    if (auto* parameters = _wkState->interpretKeyEventsParameters) {
        parameters->eventInterpretationHadSideEffects = true;
        parameters->consumedByIM = false;
    }
    _wkState->page->confirmCompositionAsync();
}

- (void)_web_superDoCommandBySelector:(SEL)selector
{
    [super doCommandBySelector:selector];
}

- (void)doCommandBySelector:(SEL)selector
{
    auto* parameters = _wkState->interpretKeyEventsParameters;
    if (parameters)
        parameters->consumedByIM = false;
    if (!parameters || _wkState->page->editorState().hasComposition) {
        [super doCommandBySelector:selector];
        return;
    }
    WebCore::KeypressCommand command(String::fromLatin1(sel_getName(selector)));
    parameters->commands.append(command);
    _wkState->page->registerKeypressCommandName(command.commandName);
}
// the UI-process half of the WK2 remote-accessibility bridge. WebKit2 renders
// the page in another process, so the AX tree Safari's window exposes has to be stitched across
// the process boundary: the WebContent process hands up a token for its root object, the UI
// process turns it into an NSAccessibilityRemoteUIElement and vends it as this view's only
// accessibility child, and the UI process hands *down* tokens for this view and its window so the
// remote tree knows its parent. Upstream does all of this in WebViewImpl
// (setAccessibilityWebProcessToken / updateRemoteAccessibilityRegistration /
// accessibilityRegisterUIProcessTokens / accessibilityAttributeValue:), which the WKView path does
// not use, so it is wired here. Every entry point used is present on 10.9 (class + all four
// selectors verified against this host's AppKit), so nothing here is a polyfill.
- (void)_aquaWebKitSetAccessibilityWebProcessToken:(NSData *)token processIdentifier:(pid_t)pid
{
    if (pid != _wkState->page->legacyMainFrameProcess().processID())
        return;

    _wkState->remoteAccessibilityChild = [token length] ? adoptNS([[NSAccessibilityRemoteUIElement alloc] initWithRemoteToken:token]) : nil;
    _wkState->remoteAccessibilityChildToken = token;
    [self _aquaWebKitUpdateRemoteAccessibilityRegistration:YES];
}

// Registering the WebContent pid is what lets the WindowServer resolve the remote element's
// tree; unregistering on teardown is the matching half (upstream's updateRemoteAccessibilityRegistration).
- (void)_aquaWebKitUpdateRemoteAccessibilityRegistration:(BOOL)registerProcess
{
    // When the tree is connected/disconnected the registration has to be updated with the remote
    // process's pid. On the way out that pid comes from the remote element itself, because by then the
    // process may be gone and the page can no longer name it (upstream does exactly this).
    pid_t pid = 0;
    if (registerProcess) {
        pid = _wkState->page->legacyMainFrameProcess().processID();
    } else {
        pid = [_wkState->remoteAccessibilityChild processIdentifier];
        _wkState->remoteAccessibilityChild = nil;
        _wkState->remoteAccessibilityChildToken = nil;
    }
    if (!pid)
        return;

    if (registerProcess)
        [NSAccessibilityRemoteUIElement registerRemoteUIProcessIdentifier:pid];
    else
        [NSAccessibilityRemoteUIElement unregisterRemoteUIProcessIdentifier:pid];
}

// The other direction: hand the WebContent process tokens for this view and its window, so the
// remote tree's root reports the right parent and window. Sent whenever the window connection is
// (re)established, exactly as upstream does from viewDidMoveToWindow and didRelaunchProcess.
- (void)_aquaWebKitRegisterUIProcessAccessibilityTokens
{
    RetainPtr<NSData> elementToken = [NSAccessibilityRemoteUIElement remoteTokenForLocalUIElement:self];
    RetainPtr<NSData> windowToken = [NSAccessibilityRemoteUIElement remoteTokenForLocalUIElement:[self window]];
    _wkState->page->registerUIProcessAccessibilityTokens({ makeVector(elementToken.get()) }, { makeVector(windowToken.get()) });
}

// AX is off until something asks for it. Turning it on has to reach WebCore, and the view's
// position has to be resent afterwards, because while AX is off that position is never computed
// (upstream's enableAccessibilityIfNecessary -> updateWindowAndViewFrames, same reason).
- (void)_aquaWebKitEnableAccessibilityIfNecessary:(NSString *)attribute
{
#if ENABLE(INITIALIZE_ACCESSIBILITY_ON_DEMAND)
    // This is the half that starts accessibility in the WEB CONTENT process. With accessibility
    // on demand (on by default on Mac), WebPage::platformInitialize deliberately skips
    // -[NSApplication _accessibilityInitialize] there and waits to be asked; the UI process asking
    // here is what starts it, and until then the WebContent process has no AX server for the remote
    // element this view vends to resolve against.
    // NSAccessibilityParentAttribute and NSAccessibilityPositionAttribute are answered locally and
    // do not need the web process, so they do not trigger initialization (upstream excludes them
    // for the same reason).
    if (![attribute isEqualToString:NSAccessibilityParentAttribute] && ![attribute isEqualToString:NSAccessibilityPositionAttribute]) {
        Ref { _wkState->page->configuration().processPool() }->initializeAccessibilityIfNecessary();
    }
#endif // closes the INITIALIZE_ACCESSIBILITY_ON_DEMAND guard (see above).

    if (WebCore::AXObjectCache::accessibilityEnabled())
        return;
    WebCore::AXObjectCache::enableAccessibility();

    [self _wk_updateWindowAndViewFrames];
}

// the page's window frame (its screenX/screenY/outerWidth/outerHeight) and this view's
// accessibility position follow the window, as WebViewImpl::updateWindowAndViewFrames sends them:
// one push per run-loop turn, from window moves and resizes, gstate renewal, moving to a window and
// accessibility starting.
- (void)_wk_updateWindowAndViewFrames
{
    if (_wkState->didScheduleWindowAndViewFrameUpdate)
        return;
    _wkState->didScheduleWindowAndViewFrameUpdate = true;
    RunLoop::mainSingleton().dispatch([view = RetainPtr { self }] {
        WKViewState* state = view.get()->_wkState;
        if (!state || !state->page)
            return;
        state->didScheduleWindowAndViewFrameUpdate = false;
        NSPoint accessibilityPosition = NSZeroPoint;
        if (WebCore::AXObjectCache::accessibilityEnabled())
            accessibilityPosition = [[view accessibilityAttributeValue:NSAccessibilityPositionAttribute] pointValue];
        state->page->windowAndViewFramesChanged(WebCore::FloatRect(), WebCore::FloatPoint(accessibilityPosition));
    });
}

- (void)_wk_windowDidMoveOrResize:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    [self _wk_updateWindowAndViewFrames];
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
    [self _aquaWebKitEnableAccessibilityIfNecessary:attribute];

    if ([attribute isEqualToString:NSAccessibilityChildrenAttribute]) {
        id child = _wkState->remoteAccessibilityChild.get();
        return child ? @[child] : nil;
    }
    if ([attribute isEqualToString:NSAccessibilityRoleAttribute])
        return NSAccessibilityGroupRole;
    if ([attribute isEqualToString:NSAccessibilityRoleDescriptionAttribute])
        return NSAccessibilityRoleDescription(NSAccessibilityGroupRole, nil);
    if ([attribute isEqualToString:NSAccessibilityParentAttribute])
        return NSAccessibilityUnignoredAncestor([self superview]);
    if ([attribute isEqualToString:NSAccessibilityEnabledAttribute])
        return @YES;

    return [super accessibilityAttributeValue:attribute];
}

- (BOOL)accessibilityIsIgnored { return NO; }

- (id)accessibilityFocusedUIElement
{
    [self _aquaWebKitEnableAccessibilityIfNecessary:nil];
    return _wkState->remoteAccessibilityChild.get();
}

- (id)accessibilityHitTest:(NSPoint)point
{
    return [self accessibilityFocusedUIElement];
}

- (BOOL)wantsUpdateLayer { return NO; }
// fullscreen SPI declared in WKViewPrivate.h and sent by Safari 7. Upstream's
// WKView answers with its full-screen controller's placeholder view; this port's element-fullscreen
// path keeps the equivalent placeholder in the page client (AquaWebKitPageClient.mm), so hand that
// one over. nil outside a fullscreen session, which is also what upstream answers.
- (NSView *)fullScreenPlaceholderView
{
#if ENABLE(FULLSCREEN_API)
    return aquaWebKitPageClientFullScreenPlaceholderView(*_wkState->pageClient);
#endif // closes the FULLSCREEN_API guard on -fullScreenPlaceholderView (see above).
    return nil;
}

// navigator.share()'s picker, which AquaWebKitPageClient::showShareSheet presents with this view in
// place of a WKWebView: the delegate callback WKWebView forwards to WebViewImpl, and the testing
// override WKShareSheet reads off its view, which a WKView never carries.
- (void)shareSheetDidDismiss:(WKShareSheet *)shareSheet
{
    aquaWebKitPageClientShareSheetDidDismiss(*_wkState->pageClient, shareSheet);
}

- (std::optional<BOOL>)_resolutionForShareSheetImmediateCompletionForTesting
{
    return std::nullopt;
}

// legacy fullscreen SPI, declared in WKViewPrivate.h and sent unguarded by
// Safari 7's fullscreen controller, which asks its WKView for a window to host fullscreen content
// in. It hands back the same window this port's own element-fullscreen path uses, so both paths
// share one factory.
- (NSWindow *)createFullScreenWindow
{
#if ENABLE(FULLSCREEN_API)
    // The same window WebViewImpl::fullScreenWindow() builds for the WKWebView path, so both paths hand
    // WKFullScreenWindowController the same thing. NSWindowStyleMaskFullSizeContentView is what lets
    // the page fill the screen rather than sit below a title bar; this port implements it for real
    // (the full-size-content adapter in AquaWebKitSupport polyfills/methods/AppKit.m).
    return adoptNS([[WebCoreFullScreenWindow alloc] initWithContentRect:[[NSScreen mainScreen] frame] styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskUnifiedTitleAndToolbar | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO]).autorelease();
#endif // closes the FULLSCREEN_API guard; -createFullScreenWindow returns nil when fullscreen is compiled out.
    return nil;
}

- (void)updateLayer {}
- (BOOL)isFlipped { return YES; }
- (BOOL)canChangeFrameLayout:(WKFrameRef)f { return NO; }
// printing, mirroring WebViewImpl::printOperationWithPrintInfo — build a
// WKPrintingView over the frame and wrap it in an NSPrintOperation that Safari drives.
// WKPrintingView paginates via the WebProcess print IPC.
- (NSPrintOperation *)printOperationWithPrintInfo:(NSPrintInfo *)pi forFrame:(WKFrameRef)f
{
    WebFrameProxy* frame = toImpl(f);
    if (!frame)
        return nil;
    RetainPtr<WKPrintingView> printingView = adoptNS([[WKPrintingView alloc] initWithFrameProxy:*frame view:self]);
    RetainPtr<NSPrintOperation> printOperation = [NSPrintOperation printOperationWithView:printingView.get() printInfo:pi];
    [printOperation setCanSpawnSeparateThread:YES];
    [printOperation setJobTitle:frame->title().createNSString().get()];
    printingView->_printOperation = printOperation.get();
    return printOperation.autorelease();
}
// applies the frame and stashes the scroll delta. Safari sends this to its
// WKView (treated as "viewBelowBanner") during Banner._moveBannerIntoPlace: to shrink the web view
// by banner.height so the banner can occupy that vacated area.
//
// The scroll delta rides the geometry update, exactly as WebViewImpl does it
// (WebViewImpl::setFrameAndScrollBy at mac/WebViewImpl.mm:1811 stashes it in
// m_scrollOffsetAdjustment; setDrawingAreaSize passes it as DrawingAreaProxy::setSize's second
// argument and clears it). DrawingAreaProxy::setSize(size, scrollOffset) still takes that argument
// (DrawingAreaProxy.h:102), so the web process scroll-compensates the resize itself.
- (void)setFrame:(NSRect)r andScrollBy:(NSSize)o
{
    if (!NSEqualSizes(o, NSZeroSize))
        _wkState->scrollOffsetAdjustment = o;

    [super setFrame:r];
}

// frame-size-updates gate, ported from the Safari-537-era WKView
// (disableFrameSizeUpdates / enableFrameSizeUpdates / frameSizeUpdatesDisabled). Safari 7 nests
// disable/enable around its resize animations so the web process sees one settled size instead
// of every animation frame; while disabled, -setFrameSize: also applies the content-anchor
// shift (see there). -enableFrameSizeUpdates pushes the current frame size on reaching zero,
// exactly as the 537 implementation pushed _setDrawingAreaSize:[self frame].size — and, because
// the modern geometry update carries no layer offset for the web process to compensate with
// (see -setContentAnchor:), it also clears the anchor shift in the same transaction so the
// fenced new-size layout swaps in aligned to the view.
- (void)disableFrameSizeUpdates
{
    _wkState->frameSizeUpdatesDisabledCount++;
}

// decrement the gate; on reaching zero push the settled frame size and clear the anchor shift (see -disableFrameSizeUpdates).
- (void)enableFrameSizeUpdates
{
    if (!_wkState->frameSizeUpdatesDisabledCount)
        return;

    // Only the outermost enable resumes frame-size updates.
    if (--_wkState->frameSizeUpdatesDisabledCount)
        return;

    if (RefPtr drawingArea = _wkState->page->drawingArea())
        drawingArea->setSize(WebCore::IntSize([self frame].size.width, [self frame].size.height), wkTakeScrollOffsetAdjustment(_wkState));
    _wkState->frameOrigin = NSZeroPoint;
    if (CALayer *renderLayer = _wkState->pageClient->acceleratedCompositingRootLayer()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [renderLayer setPosition:CGPointZero];
        [CATransaction commit];
    }
}

// Frame-size-updates gate query, matching the 537 implementation.
- (BOOL)frameSizeUpdatesDisabled
{
    return _wkState->frameSizeUpdatesDisabledCount > 0;
}
// +hideWordDefinitionWindow stub; Safari 7 sends it unguarded to dismiss the dictionary definition panel.
+ (void)hideWordDefinitionWindow {}

// NSServicesRequests responder hooks. AppKit walks the responder chain calling
// -validRequestorForSendType:returnType: to decide which services apply to the current selection, then
// -writeSelectionToPasteboard:types: to hand the selection to the chosen service (and
// -readSelectionFromPasteboard: for services that return a replacement). The standalone WKView talks
// to WebPageProxy directly (no WebViewImpl), so these are what offer the web selection to Services in
// both the app menu and the context menu. Ported from
// WebViewImpl::validRequestorForSendAndReturnTypes / writeSelectionToPasteboard / readSelectionFromPasteboard.
- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
    // consult the page's EditorState to decide which send types the current selection offers to Services.
    const WebKit::EditorState& editorState = _wkState->page->editorState();
    bool isValidSendType = !sendType;
    if (sendType && editorState.selectionType != WebCore::SelectionType::None) {
        if (editorState.isInPlugin)
            isValidSendType = [sendType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];
        else
            isValidSendType = [WebKit::PasteboardTypes::forSelectionSingleton() containsObject:sendType];
    }

    // a Service returning a replacement is valid only over editable content (rich or plain text).
    bool isValidReturnType = false;
    if (!returnType)
        isValidReturnType = true;
    else if ([WebKit::PasteboardTypes::forEditingSingleton() containsObject:returnType] && editorState.isContentEditable)
        isValidReturnType = editorState.isContentRichlyEditable || [returnType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];

    // offer this view as the Services requestor when send/return types match, else fall through the responder chain.
    if (isValidSendType && isValidReturnType)
        return self;
    return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];
}

// -writeSelectionToPasteboard: hands the web selection to the chosen Service (ported from WebViewImpl::writeSelectionToPasteboard).
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray *)types
{
    [pasteboard clearContents];
    [pasteboard addTypes:types owner:nil];
    for (NSString *type in types) {
        if ([type isEqualTo:WebCore::legacyStringPasteboardTypeSingleton()])
            [pasteboard setString:_wkState->page->stringSelectionForPasteboard().createNSString().get() forType:WebCore::legacyStringPasteboardTypeSingleton()];
        else {
            RefPtr<WebCore::SharedBuffer> buffer = _wkState->page->dataSelectionForPasteboard(type);
            [pasteboard setData:buffer ? buffer->createNSData().get() : nil forType:type];
        }
    }
    return YES;
}

// -readSelectionFromPasteboard: lets a Service replace the web selection (ported from WebViewImpl::readSelectionFromPasteboard).
- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pasteboard
{
    return _wkState->page->readSelectionFromPasteboard([pasteboard name]);
}

// NSEvent forwarding into WebPageProxy — mouseDown/Up/Moved/Dragged,
// scrollWheel and keyDown/Up — since this WKView does not use WebViewImpl's input pipeline.
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// #138: notify the page when this view gains/loses first-responder status so the
// WebContent's ActivityState::IsFocused flag tracks focus, which is what FrameSelection::
// isFocusedAndActive() reads to show the text-insertion caret and active selection highlight.
// Matches WebViewImpl, which fires activityStateDidChange(IsFocused) on become/resignFirstResponder.
// activityStateDidChange defers the recompute, so by the time it re-queries -isViewFocused the
// window firstResponder has settled.
- (BOOL)becomeFirstResponder
{
    BOOL result = [super becomeFirstResponder];
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return result;
}

// clear ActivityState::IsFocused on resign so the page's FocusController matches first-responder state (#138).
- (BOOL)resignFirstResponder
{
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return [super resignFirstResponder];
}

// ported from the Safari-537 WKView, which refreshed its window/view frames
// here. AppKit invalidates the gstate whenever this view's geometry RELATIVE TO THE WINDOW changes
// — window resize, ancestor moves, scrolling — none of which touch the view's own frame, so they
// reach no other geometry hook. iBooks attaches its reader views while the reader window is still
// animating open at a tiny size, so their -visibleRect is empty at -viewDidMoveToWindow time and
// this signal is what re-clips the exposed rect once the window reaches full size.
- (void)renewGState
{
    if ([self window]) {
        [self _updateViewExposedRect];
        [self _wk_updateWindowAndViewFrames];
    }
    [super renewGState];
}

// WebViewImpl::viewWillMoveToWindowImpl clears commands while the old window's undo manager is reachable.
- (void)viewWillMoveToWindow:(NSWindow *)window
{
    if (window != [self window])
        aquaWebKitPageClientViewWillMoveToAnotherWindow(*_wkState->pageClient);
    [super viewWillMoveToWindow:window];
}

// (re)register the window observers and push this view's activity state to the
// page. Safari's tab swap removes the inactive tab's WKView from the window and re-adds it on
// switch-back; the activityStateDidChange below is the WebPage::SetActivityState IPC that makes
// WebContent send a fresh layer-tree commit for the re-attached view.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    WebKit::LegacyExtensionHiddenTabs::singleton().webViewDidMoveToWindow(*_wkState->page, [self window]);

    // propagate the window's backing scale to the page so it renders at the
    // display's device pixel ratio (Retina = 2x). The AquaWebKitPageClient/WKView path replaces
    // WebViewImpl, so its setIntrinsicDeviceScaleFactor wiring is mirrored here: set the factor on
    // (re)entering a window and observe NSWindowDidChangeBackingPropertiesNotification (display /
    // scale change).
    NSNotificationCenter *backingCenter = [NSNotificationCenter defaultCenter];
    [backingCenter removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    if (NSWindow *window = [self window])
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeBackingProperties:) name:NSWindowDidChangeBackingPropertiesNotification object:window];
    [self _wk_updateIntrinsicDeviceScaleFactor];

    // report the hosting window's screen to the page, mirroring upstream
    // WebViewImpl::windowDidChangeScreen. WebPageProxy::windowScreenDidChange sets m_displayID,
    // which updateDisplayLinkFrequency() needs to request full-speed DisplayLink updates for
    // wheel/animated-scroll activity, and tells the WebContent side (WebPage::WindowScreenDidChange
    // + EventDispatcher::PageScreenDidChange) which display the ThreadedScrollingTree belongs to —
    // its displayDidRefresh() only services callbacks whose displayID matches. Safari 7's WKView
    // predates all of this wiring.
    [backingCenter removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeScreen:) name:NSWindowDidChangeScreenNotification object:window];
        [self _wk_windowDidChangeScreen:nil];
    }

    // window visibility / key-state observers, mirroring upstream
    // WebViewImpl's WKWindowVisibilityObserver registrations. They are what recomputes visibility
    // for a view attached to a not-yet-shown window (Safari attaches restored windows' views before
    // ordering the window front at launch) once that window orders on screen; a WebCore page left
    // "hidden" suspends rAF, alignment-throttles DOM timers and runs no rendering updates.
    // The order-on/off-screen notifications are the private-SPI pair upstream observes
    // (NSWindowSPI.h; posted on 10.9 — runtime-verified via a symbol-registered observer on
    // orderFront:/makeKeyAndOrderFront:/deminiaturize: and orderOut:/miniaturize:). Observed with
    // _wk_-prefixed selectors because NSView itself observes these notifications (upstream's
    // WKWindowVisibilityObserver exists for the same reason).
    [backingCenter removeObserver:self name:NSWindowDidOrderOnScreenNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidOrderOffScreenNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidMiniaturizeNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidDeminiaturizeNotification object:nil];
    // the WindowServer computes occlusion asynchronously, so the Visible bit
    // arrives after the window orders in; this notification is how that transition is delivered
    // (upstream observes it at WebViewImpl::registerViewObservers). AquaWebKitPageClient::isActiveViewVisible
    // reads window.occlusionState under this recompute.
    [backingCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidOrderOnScreen:) name:NSWindowDidOrderOnScreenNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidOrderOffScreen:) name:NSWindowDidOrderOffScreenNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeMiniaturization:) name:NSWindowDidMiniaturizeNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeMiniaturization:) name:NSWindowDidDeminiaturizeNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeOcclusionState:) name:NSWindowDidChangeOcclusionStateNotification object:window];
    }
    // Key notifications are observed with object:nil like upstream (the key window may be this
    // window's attached sheet); remove-then-add so re-entering a window never double-registers.
    [backingCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeKeyState:) name:NSWindowDidBecomeKeyNotification object:nil];
    // window moves and resizes, which WebViewImpl observes for updateWindowAndViewFrames.
    [backingCenter removeObserver:self name:NSWindowDidMoveNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidResizeNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidMoveOrResize:) name:NSWindowDidMoveNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidMoveOrResize:) name:NSWindowDidResizeNotification object:window];
        [self _wk_updateWindowAndViewFrames];
    }
    [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeKeyState:) name:NSWindowDidResignKeyNotification object:nil];

    // recompute IsVisible when the active Space changes, mirroring upstream
    // WKWindowVisibilityObserver's NSWorkspaceActiveSpaceDidChangeNotification registration. A
    // window on another Space carries the change in its occlusion state, which is what
    // AquaWebKitPageClient::isActiveViewVisible reads under this recompute.
    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter removeObserver:self name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(_wk_activeSpaceDidChange:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];

    OptionSet<WebCore::ActivityState> flags;
    // while Safari is deferring view-in-window changes
    // (-beginDeferringViewInWindowChanges), the IsInWindow push is suppressed and recorded so
    // -endDeferringViewInWindowChanges[Sync] pushes the coalesced change. Mirrors the
    // m_shouldDeferViewInWindowChanges gate in WebViewImpl::viewDidMoveToWindow.
    if (_wkState->shouldDeferViewInWindowChanges)
        _wkState->viewInWindowChangeWasDeferred = true;
    else
        flags.add(WebCore::ActivityState::IsInWindow);
    flags.add(WebCore::ActivityState::IsVisible);
    flags.add(WebCore::ActivityState::IsVisibleOrOccluded);
    flags.add(WebCore::ActivityState::WindowIsActive);
    flags.add(WebCore::ActivityState::IsFocused);
    _wkState->page->activityStateDidChange(flags);

    // refresh the clipped view-exposed-rect now that the view is in a window
    // (its visible rect only becomes meaningful once attached), mirroring WebViewImpl's
    // updateWindowAndViewFrames -> updateViewExposedRect trigger.
    if (_wkState->shouldClipToVisibleRect)
        [self _updateViewExposedRect];

    // the remote accessibility tokens describe this view and the window it is
    // in, so they are (re)sent once the window connection exists, as upstream does from the same
    // place. Sending them from -initWithFrame: would name a window the view does not have yet.
    if ([self window])
        [self _aquaWebKitRegisterUIProcessAccessibilityTokens];
}

// view-in-window-change deferral SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7 when it moves a WKView between windows (tab drag-out/merge). Ported from
// WebViewImpl::beginDeferringViewInWindowChanges / endDeferringViewInWindowChanges /
// endDeferringViewInWindowChangesSync onto this WKView's activityStateDidChange machinery:
// while deferring, -viewDidMoveToWindow suppresses the ActivityState::IsInWindow push and records
// it; ending the deferral pushes the coalesced in-window change so the page sees one transition
// instead of an out-of-window/in-window flicker.
- (void)beginDeferringViewInWindowChanges
{
    if (_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"beginDeferringViewInWindowChanges was called while already deferring view-in-window changes!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = true;
}

// end the deferral and push the coalesced IsInWindow change (ported from WebViewImpl::endDeferringViewInWindowChanges).
- (void)endDeferringViewInWindowChanges
{
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChanges was called without beginDeferringViewInWindowChanges!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = false;

    if (_wkState->viewInWindowChangeWasDeferred) {
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// Sync variant, ported from WebViewImpl::endDeferringViewInWindowChangesSync,
// whose body upstream is identical to the non-Sync variant — the historical synchronous
// waitForDidUpdateInWindowState is gone from modern WebKit, so "Sync" carries no extra wait.
// (WebViewImpl also flushes its pending obscured-content-inset changes here; this WKView has no
// content-inset machinery, so there is nothing to flush.)
- (void)endDeferringViewInWindowChangesSync
{
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChangesSync was called without beginDeferringViewInWindowChanges!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = false;

    if (_wkState->viewInWindowChangeWasDeferred) {
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// deferral-state getter (ported from WebViewImpl::isDeferringViewInWindowChanges; declared in WKViewPrivate.h).
- (BOOL)isDeferringViewInWindowChanges
{
    return _wkState->shouldDeferViewInWindowChanges;
}
// upstream closes its #if ENABLE(MAC_GESTURE_EVENTS) guard (which wraps
// -rotateWithEvent:) with this #endif here. MAC_GESTURE_EVENTS is unavailable on 10.9, so the guard
// is disabled and its closing #endif is kept commented out for upstream merges.
//#endif

// recompute visibility when this view (or an ancestor) hides/unhides, mirroring
// upstream WebViewImpl's viewDidHide/viewDidUnhide forwarding — the unhide is the only signal that
// clears an IsVisible=0 latched while the view was hidden.
- (void)viewDidHide
{
    [super viewDidHide];
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// mirror -viewDidHide: recompute visibility when this view (or an ancestor) unhides.
- (void)viewDidUnhide
{
    [super viewDidUnhide];
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// read the current window's (or main screen's) backing scale and push it to the page.
- (void)_wk_updateIntrinsicDeviceScaleFactor
{
    NSWindow *window = [self window];
    _wkState->page->setIntrinsicDeviceScaleFactor(window ? [window backingScaleFactor] : [[NSScreen mainScreen] backingScaleFactor]);
}

// the window changed backing scale (e.g. moved to a Retina display) — re-propagate it.
- (void)_wk_windowDidChangeBackingProperties:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    [self _wk_updateIntrinsicDeviceScaleFactor];
}

// push the hosting window's display ID to WebPageProxy (see -viewDidMoveToWindow).
- (void)_wk_windowDidChangeScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    NSScreen *screen = [[self window] screen] ?: [NSScreen mainScreen];
    CGDirectDisplayID displayID = [[[screen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
    if (!displayID)
        displayID = CGMainDisplayID();
    _wkState->page->windowScreenDidChange(displayID);
}

// the hosting window's occlusion state changed — recompute visibility,
// mirroring WebViewImpl::windowDidChangeOcclusionState.
- (void)_wk_windowDidChangeOcclusionState:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// the hosting window ordered on screen — push IsVisible/WindowIsActive to the
// page, mirroring WebViewImpl::windowDidOrderOnScreen.
- (void)_wk_windowDidOrderOnScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::WindowIsActive });
}

// the hosting window ordered off screen — recompute visibility, mirroring
// WebViewImpl::windowDidOrderOffScreen.
- (void)_wk_windowDidOrderOffScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::WindowIsActive });
}

// the hosting window miniaturized or deminiaturized — recompute visibility,
// mirroring WebViewImpl::windowDidMiniaturize/windowDidDeminiaturize.
- (void)_wk_windowDidChangeMiniaturization:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// the active Space changed — recompute IsVisible, mirroring
// WebViewImpl::activeSpaceDidChange.
- (void)_wk_activeSpaceDidChange:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// a window became or resigned key — recompute WindowIsActive, mirroring
// WebViewImpl::windowDidBecomeKey/windowDidResignKey.
- (void)_wk_windowDidChangeKeyState:(NSNotification *)notification
{
    NSWindow *window = [self window];
    if (!window)
        return;
    id changedWindow = [notification object];
    if (changedWindow != window && changedWindow != [window attachedSheet])
        return;
    _wkState->page->activityStateDidChange(WebCore::ActivityState::WindowIsActive);
}

// AppKit delivers this directly to the view when its backing properties change —
// the backing scale factor and the colour space of the display it is on.
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self _wk_updateIntrinsicDeviceScaleFactor];
    aquaWebKitPageClientViewDidChangeBackingProperties(*_wkState->pageClient);
}

// WKViewPrivate.h's occlusion-detection switch, carried through to the page
// client that reads window.occlusionState.
- (void)setWindowOcclusionDetectionEnabled:(BOOL)flag
{
    setAquaWebKitPageClientWindowOcclusionDetectionEnabled(*_wkState->pageClient, flag);
}

- (BOOL)windowOcclusionDetectionEnabled
{
    return aquaWebKitPageClientWindowOcclusionDetectionEnabled(*_wkState->pageClient);
}

// the WebContent layer tree is hosted on a dedicated layer-hosting subview
// (AquaWebKitPageClient's WKAquaWebKitLayerHostingView — the 537 _layerHostingView arrangement). That
// subview's -hitTest: returns nil, so AppKit's hit-testing lands on the WKView itself and the
// mouse/scroll/key NSResponder overrides below fire naturally via -[NSWindow sendEvent:]. The
// redirect here is the upstream-equivalent insurance (WebViewImpl::hitTest): a hit on self or
// any descendant resolves to self so the responder-chain forwarding stays correct.
- (NSView *)hitTest:(NSPoint)point
{
    NSView *result = [super hitTest:point];
    if (!result)
        return nil;
    if (result == self || [result isDescendantOf:self])
        return self;
    return result;
}

// macro that forwards each NSResponder mouse selector into the page proxy.
#define WKV_FORWARD_MOUSE(SEL_NAME) \
- (void)SEL_NAME:(NSEvent *)event \
{ \
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven); \
    _wkState->page->handleMouseEvent(webEvent); \
}

// mouseDown, mouseUp and mouseDragged are explicit (not via the macro) for the state WebViewImpl's keep: the
// last mouse-down, and the mouse-dragged events a finished drag session ignores.
- (void)mouseDown:(NSEvent *)event
{
    _wkState->lastMouseDownEvent = event;
    _wkState->ignoresMouseDraggedEvents = false;
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}

- (void)mouseUp:(NSEvent *)event
{
    _wkState->lastMouseDownEvent = nil;
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}

- (void)mouseDragged:(NSEvent *)event
{
    if (_wkState->ignoresMouseDraggedEvents)
        return;
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}
// mouseMoved is explicit (not via the macro) because it needs a filter the
// other forwards don't: while this view is first responder, the window routes mouseMoved events
// to it from anywhere in the window (not just over the tracking area installed in the designated
// initializer), so moves outside the visible rect are dropped rather than hit-tested at bogus
// coordinates. Matches Safari 7 WebKit2's -[WKView mouseMoved:] and WebViewImpl::mouseMoved().
- (void)mouseMoved:(NSEvent *)event
{
    if (self == [[self window] firstResponder] && !NSPointInRect([self convertPoint:[event locationInWindow] fromView:nil], [self visibleRect]))
        return;
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}
WKV_FORWARD_MOUSE(rightMouseDown)
WKV_FORWARD_MOUSE(rightMouseUp)
WKV_FORWARD_MOUSE(rightMouseDragged)
WKV_FORWARD_MOUSE(otherMouseDown)
WKV_FORWARD_MOUSE(otherMouseUp)
WKV_FORWARD_MOUSE(otherMouseDragged)
WKV_FORWARD_MOUSE(mouseEntered)
WKV_FORWARD_MOUSE(mouseExited)

#undef WKV_FORWARD_MOUSE

// three-finger-tap "Look Up" trackpad gesture. AppKit delivers the gesture as
// quickLookWithEvent: down the responder chain; upstream handles it in WebViewImpl::quickLookWithEvent,
// which this WKView doesn't use. There is no immediate-action gesture recognizer on 10.9
// (NSImmediateActionGestureRecognizer is 10.10.3+), so this is upstream's non-recognizer path:
// a dictionary lookup at the tap location.
- (void)quickLookWithEvent:(NSEvent *)event
{
    NSPoint locationInViewCoordinates = [self convertPoint:[event locationInWindow] fromView:nil];
    _wkState->page->performDictionaryLookupAtLocation(WebCore::FloatPoint(locationInViewCoordinates));
}

#if ENABLE(DRAG_SUPPORT)
// HTML5 drag-and-drop for WKView. Safari 7 drives WebKit2 through WKView,
// whose input pipeline is written here rather than in WebViewImpl, so the drag source and
// destination are wired directly to WebPageProxy. Mirrors WebViewImpl.

// map an NSDragOperation to a WebCore::DragOperation mask for the hand-written WKView drag pipeline (mirrors WebViewImpl).
static OptionSet<WebCore::DragOperation> wkCoreDragOperationMask(NSDragOperation operation)
{
    OptionSet<WebCore::DragOperation> result;
    if (operation & NSDragOperationCopy)
        result.add(WebCore::DragOperation::Copy);
    if (operation & NSDragOperationLink)
        result.add(WebCore::DragOperation::Link);
    if (operation & NSDragOperationGeneric)
        result.add(WebCore::DragOperation::Generic);
    if (operation & NSDragOperationPrivate)
        result.add(WebCore::DragOperation::Private);
    if (operation & NSDragOperationMove)
        result.add(WebCore::DragOperation::Move);
    if (operation & NSDragOperationDelete)
        result.add(WebCore::DragOperation::Delete);
    return result;
}

// map a WebCore::DragOperation back to an NSDragOperation for the hand-written WKView drag pipeline.
static NSDragOperation wkKitDragOperation(std::optional<WebCore::DragOperation> op)
{
    if (!op)
        return NSDragOperationNone;
    switch (*op) {
    case WebCore::DragOperation::Copy: return NSDragOperationCopy;
    case WebCore::DragOperation::Link: return NSDragOperationLink;
    case WebCore::DragOperation::Generic: return NSDragOperationGeneric;
    case WebCore::DragOperation::Private: return NSDragOperationPrivate;
    case WebCore::DragOperation::Move: return NSDragOperationMove;
    case WebCore::DragOperation::Delete: return NSDragOperationDelete;
    }
    return NSDragOperationNone;
}

// derive WebCore::DragApplicationFlags from AppKit state for the hand-written WKView drag destination.
static OptionSet<WebCore::DragApplicationFlags> wkDragApplicationFlags(NSView *view, id<NSDraggingInfo> info)
{
    OptionSet<WebCore::DragApplicationFlags> flags;
    if ([NSApp modalWindow])
        flags.add(WebCore::DragApplicationFlags::IsModal);
    if (view.window.attachedSheet)
        flags.add(WebCore::DragApplicationFlags::HasAttachedSheet);
    if (info.draggingSource == view)
        flags.add(WebCore::DragApplicationFlags::IsSource);
    if ([NSApp currentEvent].modifierFlags & NSEventModifierFlagOption)
        flags.add(WebCore::DragApplicationFlags::IsCopyKeyDown);
    return flags;
}

// assemble a WebCore::DragData from an NSDraggingInfo for the hand-written WKView drag destination.
static WebCore::DragData wkDragDataFromInfo(NSView *view, id<NSDraggingInfo> info, WebKit::WebPageProxy& page)
{
    WebCore::IntPoint client([view convertPoint:info.draggingLocation fromView:nil]);
    NSPoint global = WebCore::globalPoint(info.draggingLocation, [view window]);
    return WebCore::DragData(info, client, WebCore::IntPoint(global), wkCoreDragOperationMask(info.draggingSourceOperationMask), wkDragApplicationFlags(view, info), WebCore::anyDragDestinationAction(), page.webPageIDInMainFrameProcess());
}

// the MIME types of the files a drag promises or carries; -[WKWebView _promisedFileMIMETypes:].
static Vector<String> wkPromisedFileMIMETypes(NSView *view, id<NSDraggingInfo> info)
{
    __block Vector<String> mimeTypes;
    [info enumerateDraggingItemsWithOptions:0 forView:view classes:@[NSFilePromiseReceiver.class] searchOptions:@{ } usingBlock:^(NSDraggingItem *item, NSInteger, BOOL *) {
        RetainPtr receiver = dynamic_objc_cast<NSFilePromiseReceiver>(item.item);
        if (!receiver)
            return;

        for (NSString *typeIdentifier in [receiver fileTypes]) {
            RetainPtr type = [UTType typeWithIdentifier:typeIdentifier];
            if (!type)
                continue;

            if (RetainPtr mimeType = [type preferredMIMEType])
                mimeTypes.append({ mimeType.get() });
        }
    }];

    if (mimeTypes.isEmpty()) {
        RetainPtr filenames = dynamic_objc_cast<NSArray>([info.draggingPasteboard propertyListForType:WebCore::legacyFilenamesPasteboardTypeSingleton()]);
        if (!filenames)
            return { };

        for (id name in filenames.get()) {
            RetainPtr pathExtension = [dynamic_objc_cast<NSString>(name) pathExtension];
            if (![pathExtension length])
                continue;

            RetainPtr type = [UTType typeWithFilenameExtension:pathExtension.get()];
            if (!type)
                continue;

            if (RetainPtr mimeType = [type preferredMIMEType])
                mimeTypes.append({ mimeType.get() });
        }
    }

    return mimeTypes;
}

// WebViewImpl's performDragWithLegacyFiles: let the network and web processes read the dropped files,
// then deliver the drop carrying their paths.
static void wkPerformDragWithLegacyFiles(WebKit::WebPageProxy& page, Box<Vector<String>>&& fileNames, Box<WebCore::DragData>&& dragData, const String& pasteboardName)
{
    RefPtr networkProcess = page.websiteDataStore().networkProcessIfExists();
    if (!networkProcess)
        return;
    networkProcess->sendWithAsyncReply(Messages::NetworkProcess::AllowFilesAccessFromWebProcess(page.legacyMainFrameProcess().coreProcessIdentifier(), *fileNames), [page = Ref { page }, fileNames, dragData, pasteboardName]() mutable {
        if (!page->hasRunningProcess()) {
            if (RefPtr pageClient = page->pageClient())
                pageClient->didPerformDragOperation(false);
            return;
        }

        WebKit::SandboxExtension::Handle sandboxExtensionHandle;
        Vector<WebKit::SandboxExtension::Handle> sandboxExtensionForUpload;

        page->createSandboxExtensionsIfNeeded(*fileNames, sandboxExtensionHandle, sandboxExtensionForUpload);
        dragData->setFileNames(*fileNames);
        page->performDragOperation(*dragData, pasteboardName, WTF::move(sandboxExtensionHandle), WTF::move(sandboxExtensionForUpload));
    });
}

// WebViewImpl's handleLegacyFilesPromisePasteboard.
static bool wkHandleLegacyFilesPromisePasteboard(id<NSDraggingInfo> draggingInfo, Box<WebCore::DragData>&& dragData, WebKit::WebPageProxy& page, NSView *view)
{
    // FIXME: legacyFilesPromisePasteboardTypeSingleton() contains UTIs, not path names. Also, it's not
    // guaranteed that the count of UTIs equals the count of files, since some clients only write
    // unique UTIs.
    RetainPtr files = dynamic_objc_cast<NSArray>([protect(draggingInfo.draggingPasteboard) propertyListForType:WebCore::legacyFilesPromisePasteboardTypeSingleton()]);
    if (!files)
        return false;

    RetainPtr dropDestinationPath = FileSystem::createTemporaryDirectory(@"WebKitDropDestination");
    if (!dropDestinationPath)
        return false;

    size_t fileCount = files.get().count;
    auto fileNames = Box<Vector<String>>::create();
    RetainPtr dropDestination = [NSURL fileURLWithPath:dropDestinationPath.get() isDirectory:YES];
    String pasteboardName = draggingInfo.draggingPasteboard.name;
    [draggingInfo enumerateDraggingItemsWithOptions:0 forView:view classes:@[NSFilePromiseReceiver.class] searchOptions:@{ } usingBlock:makeBlockPtr([
        pasteboardName,
        dropDestination,
        fileNames,
        fileCount,
        dragData,
        protectedPage = Ref { page }
    ](NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop) {
        RetainPtr queue = adoptNS([NSOperationQueue new]);
        BlockPtr readerBlock = makeBlockPtr([protectedPage, fileNames, fileCount, dragData, pasteboardName = pasteboardName.isolatedCopy()](NSURL *fileURL, NSError *errorOrNil) mutable {
            if (errorOrNil)
                return;

            RunLoop::mainSingleton().dispatch([protectedPage, path = protect(fileURL.path), fileNames, fileCount, dragData, pasteboardName] mutable {
                fileNames->append(path.get());
                if (fileNames->size() != fileCount)
                    return;
                wkPerformDragWithLegacyFiles(protectedPage, WTF::move(fileNames), WTF::move(dragData), pasteboardName);
            });
        });
        [protect(draggingItem.item) receivePromisedFilesAtDestination:dropDestination.get() options:@{ } operationQueue:queue.get() reader:readerBlock.get()];
    }).get()];

    return true;
}

// WebViewImpl's handleLegacyFilesPasteboard.
static bool wkHandleLegacyFilesPasteboard(id<NSDraggingInfo> draggingInfo, Box<WebCore::DragData>&& dragData, WebKit::WebPageProxy& page)
{
    RetainPtr files = dynamic_objc_cast<NSArray>([retainPtr(draggingInfo.draggingPasteboard) propertyListForType:WebCore::legacyFilenamesPasteboardTypeSingleton()]);
    if (!files)
        return false;

    String pasteboardName = draggingInfo.draggingPasteboard.name;

    RetainPtr originalFileURLs = adoptNS([[NSMutableArray alloc] initWithCapacity:[files count]]);
    for (NSString *file in files.get())
        [originalFileURLs addObject:adoptNS([[NSURL alloc] initFileURLWithPath:file]).get()];

    auto task = makeBlockPtr([protectedPage = Ref { page }, originalFileURLs, dragData, pasteboardName = pasteboardName.isolatedCopy()] mutable {
        ASSERT(!RunLoop::isMain());

        RetainPtr coordinator = adoptNS([[NSFileCoordinator alloc] initWithFilePresenter:nil]);

        NSError *prepareError = nil;
        [coordinator prepareForReadingItemsAtURLs:originalFileURLs.get() options:0 writingItemsAtURLs:@[] options:0 error:&prepareError byAccessor:[coordinator, originalFileURLs, protectedPage = WTF::move(protectedPage), dragData, pasteboardName](void (^completionHandler)(void)) mutable {
            auto fileNames = Box<Vector<String>>::create();

            for (NSURL *originalFileURL in originalFileURLs.get()) {
                NSError *error = nil;
                [coordinator coordinateReadingItemAtURL:originalFileURL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:[fileNames](NSURL *newURL) {
                    fileNames->append(newURL.path);
                }];

                RELEASE_LOG_ERROR_IF(error, DragAndDrop, "Failed to coordinate reading file: %@.", error.localizedDescription);
            }

            RunLoop::mainSingleton().dispatch([protectedPage = WTF::move(protectedPage), fileNames, dragData, pasteboardName, completionHandler = makeBlockPtr(completionHandler)] mutable {
                wkPerformDragWithLegacyFiles(protectedPage, WTF::move(fileNames), WTF::move(dragData), pasteboardName);
                completionHandler();
            });
        }];

        RELEASE_LOG_ERROR_IF(prepareError, DragAndDrop, "Failed to prepare for reading files with error: %@.", prepareError.localizedDescription);
    });

    dispatch_async(globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), task.get());
    return true;
}

// NSDraggingDestination for WKView — drops route directly into WebPageProxy.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    dragData.setPromisedFileMIMETypes(wkPromisedFileMIMETypes(self, info));
    _wkState->page->resetCurrentDragInformation();
    _wkState->page->dragEntered(dragData, info.draggingPasteboard.name);
    _wkState->initialNumberOfValidItemsForDrop = info.numberOfValidItemsForDrop;
    return NSDragOperationCopy;
}

// NSDraggingDestination -draggingUpdated: for WKView, mirroring WebViewImpl::draggingUpdated.
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
    auto& page = *_wkState->page;
    auto dragData = wkDragDataFromInfo(self, info, page);
    dragData.setPromisedFileMIMETypes(wkPromisedFileMIMETypes(self, info));
    page.dragUpdated(dragData, info.draggingPasteboard.name);

    NSInteger numberOfValidItemsForDrop = page.currentDragNumberOfFilesToBeAccepted();

    if (!page.currentDragOperation())
        numberOfValidItemsForDrop = _wkState->initialNumberOfValidItemsForDrop;

    NSDraggingFormation draggingFormation = NSDraggingFormationNone;
    if (page.currentDragIsOverFileInput() && numberOfValidItemsForDrop > 0)
        draggingFormation = NSDraggingFormationList;

    if (info.numberOfValidItemsForDrop != numberOfValidItemsForDrop)
        [info setNumberOfValidItemsForDrop:numberOfValidItemsForDrop];
    if (info.draggingFormation != draggingFormation)
        [info setDraggingFormation:draggingFormation];

    return wkKitDragOperation(page.currentDragOperation());
}

// NSDraggingDestination -draggingExited: for WKView — routes into WebPageProxy.
- (void)draggingExited:(id<NSDraggingInfo>)info
{
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->dragExited(dragData);
    _wkState->page->resetCurrentDragInformation();
    info.numberOfValidItemsForDrop = _wkState->initialNumberOfValidItemsForDrop;
    _wkState->initialNumberOfValidItemsForDrop = 0;
}

// NSDraggingDestination — always accept so AppKit proceeds to performDragOperation.
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    return YES;
}

// NSDraggingDestination drop handler, mirroring WebViewImpl::performDragOperation.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    auto& page = *_wkState->page;
    auto dragData = Box<WebCore::DragData>::create(wkDragDataFromInfo(self, info, page));

    RetainPtr<NSArray> types = info.draggingPasteboard.types;

    // https://bugs.webkit.org/show_bug.cgi?id=307601
    bool hasWebArchive = [types containsObject:WebKit::PasteboardTypes::WebArchivePboardType];
    bool hasFilePromises = [types containsObject:WebCore::legacyFilesPromisePasteboardTypeSingleton()];
    bool isDragFromSelf = dragData->flags().contains(WebCore::DragApplicationFlags::IsSource);
    if (hasFilePromises && !(hasWebArchive && isDragFromSelf))
        return wkHandleLegacyFilesPromisePasteboard(info, WTF::move(dragData), page, self);

    if ([types containsObject:WebCore::legacyFilenamesPasteboardTypeSingleton()])
        return wkHandleLegacyFilesPasteboard(info, WTF::move(dragData), page);

    page.performDragOperation(*dragData, info.draggingPasteboard.name, { }, { });
    return YES;
}

// NSDraggingSource. Mirrors WebViewImpl::dragSourceOperationMask.
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    if (context == NSDraggingContextOutsideApplication || _wkState->page->currentDragIsOverFileInput())
        return NSDragOperationCopy;
    return NSDragOperationGeneric | NSDragOperationMove | NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    [self _wkSendDragEndToPageAtWindowPoint:[[self window] convertRectFromScreen:NSMakeRect(screenPoint.x, screenPoint.y, 0, 0)].origin operation:operation];
}

// Mirrors WebViewImpl::sendDragEndToPage.
- (void)_wkSendDragEndToPageAtWindowPoint:(NSPoint)windowPoint operation:(NSDragOperation)operation
{
    // Prevent queued mouseDragged events from coming after the drag and fake mouseUp event.
    _wkState->ignoresMouseDraggedEvents = true;

    WebCore::IntPoint clientLocation([self convertPoint:windowPoint fromView:nil]);
    _wkState->page->dragEnded(clientLocation, WebCore::IntPoint(WebCore::globalPoint(windowPoint, [self window])), wkCoreDragOperationMask(operation));
}

// Called by AquaWebKitPageClient::startDrag once the drag image is ready. Mirrors WebViewImpl::startDrag: the
// session starts from the last mouse-down, and a drag no mouse-down started is cancelled. The drag of an
// extension's input, which no pointing device holds, ends at once with no operation where it started, as a
// session cancelled at its start ends. dragLocation is in the view's flipped coordinates, the bottom-left of
// the image.
- (void)_wk_beginDragWithImage:(NSImage *)dragImage atLocation:(NSPoint)dragLocation promisedAttachmentInfo:(const WebCore::PromisedAttachmentInfo&)promisedAttachmentInfo frameID:(std::optional<WebCore::FrameIdentifier>)frameID
{
    Ref page = *_wkState->page;
    // The web process announces an image's promise just ahead of the drag it belongs to, which takes it.
    auto promisedImageDragData = std::exchange(_wkState->promisedImageDragData, std::nullopt);
    RetainPtr lastMouseDownEvent = _wkState->lastMouseDownEvent;
    if (!lastMouseDownEvent) {
        page->dragCancelled();
        return;
    }
    if ([self _aquaWebKitIsExtensionInputEvent:lastMouseDownEvent.get()]) {
        [self _wkSendDragEndToPageAtWindowPoint:[lastMouseDownEvent locationInWindow] operation:NSDragOperationNone];
        return;
    }

    // clientDragLocation is the bottom-left of the image, but setDraggingFrame: expects a top-left origin.
    NSSize size = [dragImage size];
    NSRect draggingFrame = NSMakeRect(dragLocation.x, dragLocation.y - size.height, size.width, size.height);

    bool isImageDrag = promisedImageDragData.has_value();
    bool canUseFilePromiseForImageDrag = isImageDrag && [promisedImageDragData->imageUTI length];

    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
    RetainPtr<NSDraggingItem> draggingItem;

    // beginDraggingSessionWithItems: clears the pasteboard and populates it with UTI-typed data
    // from NSPasteboardItems. We restore the legacy-typed pasteboard data afterwards so that WP
    // read paths (which expect legacy types) can find this data in the original order.
    RetainPtr<NSArray> savedLegacyPasteboardTypes;
    RetainPtr<NSMutableDictionary> savedLegacyPasteboardData;

    if (promisedAttachmentInfo) {
        RefPtr attachment = page->attachmentForIdentifier(promisedAttachmentInfo.attachmentIdentifier);
        if (!attachment) {
            page->dragCancelled();
            return;
        }
        RetainPtr utiType = attachment->utiType().createNSString();
        if (![utiType length]) {
            page->dragCancelled();
            return;
        }
        RetainPtr provider = adoptNS([[NSFilePromiseProvider alloc] initWithFileType:utiType.get() delegate:self]);
        RetainPtr context = adoptNS([[WKPromisedAttachmentContext alloc] initWithIdentifier:promisedAttachmentInfo.attachmentIdentifier.createNSString().get() fileName:attachment->fileName().createNSString().get()]);
        [provider setUserInfo:context.get()];
        draggingItem = adoptNS([[NSDraggingItem alloc] initWithPasteboardWriter:provider.get()]);
    } else if (canUseFilePromiseForImageDrag) {
        RetainPtr provider = adoptNS([[NSFilePromiseProvider alloc] initWithFileType:promisedImageDragData->imageUTI.get() delegate:self]);
        RetainPtr context = adoptNS([[WKPromisedImageContext alloc] initWithFileName:promisedImageDragData->filename.get() data:promisedImageDragData->imageData.get() url:promisedImageDragData->url.get()]);
        [provider setUserInfo:context.get()];
        draggingItem = adoptNS([[NSDraggingItem alloc] initWithPasteboardWriter:provider.get()]);
    } else {
        // NSPasteboardItem here is a placeholder to satisfy the NSDraggingItem initializer.
        // The real data lives in the saved legacy state and is restored once the drag session starts.
        savedLegacyPasteboardTypes = adoptNS([[pasteboard types] copy]);
        savedLegacyPasteboardData = adoptNS([[NSMutableDictionary alloc] init]);
        for (NSString *type in [pasteboard types]) {
            if (NSData *data = [pasteboard dataForType:type])
                [savedLegacyPasteboardData setObject:data forKey:type];
        }
        RetainPtr pasteboardItem = adoptNS([[NSPasteboardItem alloc] init]);
        [pasteboardItem setData:[NSData data] forType:(__bridge NSString *)kUTTypeData];
        draggingItem = adoptNS([[NSDraggingItem alloc] initWithPasteboardWriter:pasteboardItem.get()]);
    }
    [draggingItem setDraggingFrame:draggingFrame contents:dragImage];

    [self beginDraggingSessionWithItems:@[ draggingItem.get() ] event:lastMouseDownEvent.get() source:self];

    if (promisedAttachmentInfo) {
        for (auto& [type, data] : promisedAttachmentInfo.additionalTypesAndData)
            [pasteboard setData:protect(*data)->createNSData().get() forType:type.createNSString().get()];
        // FIXME: should we plumb the frameID for promised blobs?
        page->didStartDrag();
    } else if (isImageDrag) {
        [self _wkWritePromisedImageDragData:*promisedImageDragData toPasteboard:pasteboard];
        if (page->sessionID().isEphemeral())
            [pasteboard _setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:WebCore::pasteboardExpirationDelay.seconds()]];
        page->didStartDrag(frameID);
    } else {
        if ([savedLegacyPasteboardTypes count]) {
            [pasteboard clearContents];
            [pasteboard addTypes:savedLegacyPasteboardTypes.get() owner:nil];
            for (NSString *type in savedLegacyPasteboardTypes.get()) {
                if (NSData *data = [savedLegacyPasteboardData objectForKey:type])
                    [pasteboard setData:data forType:type];
            }
            if (page->sessionID().isEphemeral())
                [pasteboard _setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:WebCore::pasteboardExpirationDelay.seconds()]];
        }
        [pasteboard setString:@"" forType:WebKit::PasteboardTypes::WebDummyPboardType];
        page->didStartDrag(frameID);
    }
}
#endif // ENABLE(DRAG_SUPPORT) — HTML5 drag source/destination wired up here for the WKView input path

// forward scroll-wheel NSEvents into the page.
- (void)scrollWheel:(NSEvent *)event
{
    WebKit::NativeWebWheelEvent webEvent(event, self);

    // give the two-finger back/forward swipe first refusal, exactly as
    // WebViewImpl::scrollWheel does — these are the wheel events that drive the swipe.
    if (_wkState->allowsBackForwardNavigationGestures) {
        if (auto *gestureController = [self _wkEnsureGestureController]) {
            if (gestureController->handleScrollWheelEvent(webEvent))
                return;
        }
    }

    _wkState->page->handleNativeWheelEvent(webEvent);
}

- (void)keyDown:(NSEvent *)event
{
    // We could be receiving a key down from AppKit if we re-sent an event the page left
    // unhandled and it maps to an action that is currently unavailable (mirrors
    // WebViewImpl::keyDown); the page has already seen it, so pass it to super.
    if (_wkState->keyDownEventBeingResent.get() == event) { [super keyDown:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    bool handledByInputMethod = [self _aquaWebKitCollectKeypressCommands:event into:commands];
    WebKit::NativeWebKeyboardEvent webEvent(event, handledByInputMethod, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// run AppKit's key-binding translation for an event and collect what it
// produces, mirroring WebViewImpl::interpretKeyEvent on the WKWebView path (github #90).
//
// This runs for Cmd-modified events too. AppKit's StandardKeyBinding.dict deliberately contains no
// Cmd+X/C/V/Z — those are menu key equivalents, not key bindings — while it DOES bind Cmd+Delete to
// deleteToBeginningOfLine:, Cmd+Up/Down to moveToBeginningOfDocument:/moveToEndOfDocument:,
// Cmd+Left/Right to moveToLeftEndOfLine:/moveToRightEndOfLine: and their AndModifySelection:
// variants, alongside any user binding from ~/Library/KeyBindings/DefaultKeyBinding.dict.
- (BOOL)_aquaWebKitCollectKeypressCommands:(NSEvent *)event into:(WTF::Vector<WebCore::KeypressCommand>&)commands
{
    RetainPtr protectedSelf = self;
    WKViewInterpretKeyEventsParameters parameters { commands, !([event modifierFlags] & NSCommandKeyMask) };
    SetForScope interpretationScope(_wkState->interpretKeyEventsParameters, &parameters);
    [self interpretKeyEvents:@[event]];
    return parameters.consumedByIM || parameters.eventInterpretationHadSideEffects;
}

- (void)keyUp:(NSEvent *)event
{
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

- (void)flagsChanged:(NSEvent *)event
{
    // Don't make an event from the num lock and function keys (mirrors
    // WebViewImpl::eventKeyCodeIsZeroOrNumLockOrFn). A keyCode-0 flagsChanged — which virtual
    // keyboards (VMware) emit for bare modifier presses — maps to windows keyCode 65 ('A'), so a
    // bare Cmd press would reach the page as Cmd+A.
    unsigned short keyCode = [event keyCode];
    if (!keyCode || keyCode == 10 || keyCode == 63) { [super flagsChanged:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// give the page first crack at Cmd-modified key-downs before AppKit's menus
// (mirrors WebViewImpl::performKeyEquivalent; the Safari-7-era WKView has the same), so pages that
// implement their own shortcuts (Google Docs Cmd+Z undo/redo, etc.) see the key-down. Events the
// page leaves unhandled come back through AquaWebKitPageClient::doneWithKeyEvent and are
// re-dispatched to AppKit (-_aquaWebKitResendUnhandledKeyDownEvent:), so Safari's menu shortcuts
// still fire.
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if ([event type] != NSEventTypeKeyDown)
        return [super performKeyEquivalent:event];

    // A nested event loop during dispatch can release the current event; keep it alive.
    retainPtr(event).autorelease();

    // We get Esc here after Esc or Cmd+period gets transformed to a cancelOperation: command;
    // don't interpret it again (avoids re-entrancy / infinite loops), matching WebViewImpl.
    if ([[event charactersIgnoringModifiers] isEqualToString:@"\e"] && !([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask))
        return [super performKeyEquivalent:event];

    // The page already saw this event; it is being re-dispatched to AppKit for the menus.
    if (_wkState->keyDownEventBeingResent)
        return [super performKeyEquivalent:event];

    // Only Cmd-modified keys are menu key equivalents on this path; anything else keeps
    // flowing through keyDown: (which also runs interpretKeyEvents command collection).
    if (!([event modifierFlags] & NSCommandKeyMask))
        return [super performKeyEquivalent:event];

    // Pass key combos through WebCore so pages can intercept key-modified keypresses, but
    // only when the web view has focus (not, e.g., while the URL bar field editor does).
    if ([[self window] firstResponder] == self) {
        // collect the event's key-binding commands here too (github #90).
        // AppKit sends performKeyEquivalent: before keyDown:, and this returns YES, so this is the
        // ONLY chance a Cmd-modified event gets to be translated — Cmd+Delete
        // (deleteToBeginningOfLine:) and the Cmd+arrow document/line movers are real key bindings.
        // Upstream's WebViewImpl::performKeyEquivalent likewise goes through interpretKeyEvent.
        WTF::Vector<WebCore::KeypressCommand> commands;
        bool handledByInputMethod = [self _aquaWebKitCollectKeypressCommands:event into:commands];
        WebKit::NativeWebKeyboardEvent webEvent(event, handledByInputMethod, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
        return YES;
    }

    return [super performKeyEquivalent:event];
}

// called by AquaWebKitPageClient::doneWithKeyEvent when the page leaves a
// key-down unhandled — re-dispatch it to AppKit so menu key equivalents (Cmd+T, Cmd+Z when the
// page doesn't intercept it, etc.) still fire after the page had first crack. Mirrors the
// m_keyDownEventBeingResent re-send in WebViewImpl::doneWithKeyEvent.
- (void)_aquaWebKitResendUnhandledKeyDownEvent:(NSEvent *)event
{
    if (_wkState->keyDownEventBeingResent)
        return;
    RetainPtr<WKView> protector = self; // re-sending the event may destroy this view
    _wkState->keyDownEventBeingResent = event;
    [NSApp _setCurrentEvent:event];
    [NSApp sendEvent:event];
    _wkState->keyDownEventBeingResent = nil;
}

// The mouse-down WebViewImpl::startWindowDrag hands -[NSWindow performWindowDragWithEvent:].
- (NSEvent *)_aquaWebKitLastMouseDownEvent
{
    return _wkState->lastMouseDownEvent.get();
}

// Input an extension gives the page (LegacyExtensionInput.mm). Its events are marked as an extension's, as
// WebAutomationSession marks its own: the page's drag of an extension's mouse-down starts no drag session,
// AquaWebKitPageClient shows no native menu for them, and its doneWithKeyEvent passes a key the page leaves
// unhandled no further.
static const void* extensionInputEventKey = &extensionInputEventKey;

- (BOOL)_aquaWebKitIsExtensionInputEvent:(NSEvent *)event
{
    return !!objc_getAssociatedObject(event, extensionInputEventKey);
}

// As -mouseDown: and the other mouse handlers deliver an event, reporting `buttons` as the buttons held down,
// where WebEventFactory reads the hardware's, and completing once the page has processed every pending mouse
// event.
- (void)_aquaWebKitHandleExtensionMouseEvent:(NSEvent *)event buttons:(unsigned short)buttons completionHandler:(void (^)(void))completionHandler
{
    objc_setAssociatedObject(event, extensionInputEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (event.type == NSEventTypeLeftMouseDown) {
        _wkState->lastMouseDownEvent = event;
        _wkState->ignoresMouseDraggedEvents = false;
    } else if (event.type == NSEventTypeLeftMouseUp)
        _wkState->lastMouseDownEvent = nil;
    else if (event.type == NSEventTypeLeftMouseDragged && _wkState->ignoresMouseDraggedEvents) {
        completionHandler();
        return;
    }
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebEventInputSource::UserDriven);
    WebKit::WebMouseEvent& mouseEvent = webEvent;
    mouseEvent = WebKit::WebMouseEvent({ mouseEvent.type(), mouseEvent.modifiers(), mouseEvent.timestamp(), mouseEvent.authorizationToken() }, mouseEvent.button(), buttons, mouseEvent.position(), mouseEvent.globalPosition(), mouseEvent.deltaX(), mouseEvent.deltaY(), mouseEvent.deltaZ(), mouseEvent.clickCount(), mouseEvent.force(), mouseEvent.inputSource(), mouseEvent.canInitiateDrag(), mouseEvent.syntheticClickType(), mouseEvent.eventNumber(), mouseEvent.menuTypeForEvent(), mouseEvent.gestureWasCancelled(), mouseEvent.unadjustedMovementDelta(), mouseEvent.coalescedEvents(), mouseEvent.predictedEvents());
    Ref page = *_wkState->page;
    page->handleMouseEvent(webEvent);
    page->doAfterProcessingAllPendingMouseEvents([completionHandler = makeBlockPtr(completionHandler)] {
        completionHandler();
    });
}

// -keyDown:, -keyUp: or -flagsChanged:, completing once the page has processed every pending key event.
- (void)_aquaWebKitHandleExtensionKeyEvent:(NSEvent *)event completionHandler:(void (^)(void))completionHandler
{
    objc_setAssociatedObject(event, extensionInputEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Ref page = *_wkState->page;
    if (event.type == NSEventTypeKeyDown)
        [self keyDown:event];
    else if (event.type == NSEventTypeKeyUp)
        [self keyUp:event];
    else
        [self flagsChanged:event];
    page->doAfterProcessingAllPendingKeyEvents([completionHandler = makeBlockPtr(completionHandler)] {
        completionHandler();
    });
}

- (void)_aquaWebKitHandleExtensionWheelEvent:(NSEvent *)event
{
    [self scrollWheel:event];
}

- (void)_aquaWebKitInsertExtensionText:(NSString *)text
{
    [self insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
}

typedef HashMap<SEL, String> SelectorNameMap;

// Map selectors into Editor command names.
// This is not needed for any selectors that have the same name as the Editor command.
static const SelectorNameMap& selectorExceptionMap()
{
    static NeverDestroyed<SelectorNameMap> map;

    struct SelectorAndCommandName {
        SEL selector;
        ASCIILiteral commandName;
    };

    static const SelectorAndCommandName names[] = {
        { @selector(insertNewlineIgnoringFieldEditor:), "InsertNewline"_s },
        { @selector(insertParagraphSeparator:), "InsertNewline"_s },
        { @selector(insertTabIgnoringFieldEditor:), "InsertTab"_s },
        { @selector(pageDown:), "MovePageDown"_s },
        { @selector(pageDownAndModifySelection:), "MovePageDownAndModifySelection"_s },
        { @selector(pageUp:), "MovePageUp"_s },
        { @selector(pageUpAndModifySelection:), "MovePageUpAndModifySelection"_s },
        { @selector(scrollPageDown:), "ScrollPageForward"_s },
        { @selector(scrollPageUp:), "ScrollPageBackward"_s },
        { @selector(_pasteAsQuotation:), "PasteAsQuotation"_s },
    };

    for (auto& name : names)
        map.get().add(name.selector, name.commandName);

    return map;
}

static String commandNameForSelector(SEL selector)
{
    // Check the exception map first.
    static const SelectorNameMap& exceptionMap = selectorExceptionMap();
    SelectorNameMap::const_iterator it = exceptionMap.find(selector);
    if (it != exceptionMap.end())
        return it->value;

    // Remove the trailing colon.
    // No need to capitalize the command name since Editor command names are
    // not case sensitive.
    auto selectorName = unsafeSpan(sel_getName(selector));
    if (selectorName.size() < 2 || selectorName[selectorName.size() - 1] != ':')
        return String();
    return String(selectorName.first(selectorName.size() - 1));
}

- (void)_aquaWebKitValidateEditingAction:(NSMenuItem *)item completionHandler:(void (^)(BOOL))completionHandler
{
    auto command = commandNameForSelector(item.action);
    if (!WebCore::Editor::commandIsSupportedFromMenuOrKeyBinding(command)) {
        completionHandler([self validateUserInterfaceItem:item]);
        return;
    }
    _wkState->page->validateCommand(command, [completionHandler = makeBlockPtr(completionHandler)](bool enabled, int32_t) {
        completionHandler(enabled);
    });
}

// WKWebViewMac's WEBCORE_COMMAND actions forward through WebViewImpl's selector-to-command mapping.
#define WEBCORE_COMMAND(command) \
- (void)command:(id)sender \
{ \
    _wkState->page->executeEditCommand(commandNameForSelector(_cmd), { }); \
}

WEBCORE_COMMAND(alignCenter)
WEBCORE_COMMAND(alignJustified)
WEBCORE_COMMAND(alignLeft)
WEBCORE_COMMAND(alignRight)
WEBCORE_COMMAND(copy)
WEBCORE_COMMAND(copyFont)
WEBCORE_COMMAND(cut)
WEBCORE_COMMAND(delete)
WEBCORE_COMMAND(deleteBackward)
WEBCORE_COMMAND(deleteBackwardByDecomposingPreviousCharacter)
WEBCORE_COMMAND(deleteForward)
WEBCORE_COMMAND(deleteToBeginningOfLine)
WEBCORE_COMMAND(deleteToBeginningOfParagraph)
WEBCORE_COMMAND(deleteToEndOfLine)
WEBCORE_COMMAND(deleteToEndOfParagraph)
WEBCORE_COMMAND(deleteToMark)
WEBCORE_COMMAND(deleteWordBackward)
WEBCORE_COMMAND(deleteWordForward)
WEBCORE_COMMAND(ignoreSpelling)
WEBCORE_COMMAND(indent)
WEBCORE_COMMAND(insertBacktab)
WEBCORE_COMMAND(insertLineBreak)
WEBCORE_COMMAND(insertNewline)
WEBCORE_COMMAND(insertNewlineIgnoringFieldEditor)
WEBCORE_COMMAND(insertParagraphSeparator)
WEBCORE_COMMAND(insertTab)
WEBCORE_COMMAND(insertTabIgnoringFieldEditor)
WEBCORE_COMMAND(makeTextWritingDirectionLeftToRight)
WEBCORE_COMMAND(makeTextWritingDirectionNatural)
WEBCORE_COMMAND(makeTextWritingDirectionRightToLeft)
WEBCORE_COMMAND(moveBackward)
WEBCORE_COMMAND(moveBackwardAndModifySelection)
WEBCORE_COMMAND(moveDown)
WEBCORE_COMMAND(moveDownAndModifySelection)
WEBCORE_COMMAND(moveForward)
WEBCORE_COMMAND(moveForwardAndModifySelection)
WEBCORE_COMMAND(moveLeft)
WEBCORE_COMMAND(moveLeftAndModifySelection)
WEBCORE_COMMAND(moveParagraphBackwardAndModifySelection)
WEBCORE_COMMAND(moveParagraphForwardAndModifySelection)
WEBCORE_COMMAND(moveRight)
WEBCORE_COMMAND(moveRightAndModifySelection)
WEBCORE_COMMAND(moveToBeginningOfDocument)
WEBCORE_COMMAND(moveToBeginningOfDocumentAndModifySelection)
WEBCORE_COMMAND(moveToBeginningOfLine)
WEBCORE_COMMAND(moveToBeginningOfLineAndModifySelection)
WEBCORE_COMMAND(moveToBeginningOfParagraph)
WEBCORE_COMMAND(moveToBeginningOfParagraphAndModifySelection)
WEBCORE_COMMAND(moveToBeginningOfSentence)
WEBCORE_COMMAND(moveToBeginningOfSentenceAndModifySelection)
WEBCORE_COMMAND(moveToEndOfDocument)
WEBCORE_COMMAND(moveToEndOfDocumentAndModifySelection)
WEBCORE_COMMAND(moveToEndOfLine)
WEBCORE_COMMAND(moveToEndOfLineAndModifySelection)
WEBCORE_COMMAND(moveToEndOfParagraph)
WEBCORE_COMMAND(moveToEndOfParagraphAndModifySelection)
WEBCORE_COMMAND(moveToEndOfSentence)
WEBCORE_COMMAND(moveToEndOfSentenceAndModifySelection)
WEBCORE_COMMAND(moveToLeftEndOfLine)
WEBCORE_COMMAND(moveToLeftEndOfLineAndModifySelection)
WEBCORE_COMMAND(moveToRightEndOfLine)
WEBCORE_COMMAND(moveToRightEndOfLineAndModifySelection)
WEBCORE_COMMAND(moveUp)
WEBCORE_COMMAND(moveUpAndModifySelection)
WEBCORE_COMMAND(moveWordBackward)
WEBCORE_COMMAND(moveWordBackwardAndModifySelection)
WEBCORE_COMMAND(moveWordForward)
WEBCORE_COMMAND(moveWordForwardAndModifySelection)
WEBCORE_COMMAND(moveWordLeft)
WEBCORE_COMMAND(moveWordLeftAndModifySelection)
WEBCORE_COMMAND(moveWordRight)
WEBCORE_COMMAND(moveWordRightAndModifySelection)
WEBCORE_COMMAND(outdent)
WEBCORE_COMMAND(pageDown)
WEBCORE_COMMAND(pageDownAndModifySelection)
WEBCORE_COMMAND(pageUp)
WEBCORE_COMMAND(pageUpAndModifySelection)
WEBCORE_COMMAND(paste)
WEBCORE_COMMAND(pasteAsPlainText)
WEBCORE_COMMAND(scrollPageDown)
WEBCORE_COMMAND(scrollPageUp)
WEBCORE_COMMAND(pasteFont)
WEBCORE_COMMAND(scrollLineDown)
WEBCORE_COMMAND(scrollLineUp)
WEBCORE_COMMAND(scrollToBeginningOfDocument)
WEBCORE_COMMAND(scrollToEndOfDocument)
WEBCORE_COMMAND(selectAll)
WEBCORE_COMMAND(selectLine)
WEBCORE_COMMAND(selectParagraph)
WEBCORE_COMMAND(selectSentence)
WEBCORE_COMMAND(selectToMark)
WEBCORE_COMMAND(selectWord)
WEBCORE_COMMAND(setMark)
WEBCORE_COMMAND(subscript)
WEBCORE_COMMAND(superscript)
WEBCORE_COMMAND(swapWithMark)
WEBCORE_COMMAND(takeFindStringFromSelection)
WEBCORE_COMMAND(transpose)
WEBCORE_COMMAND(underline)
WEBCORE_COMMAND(unscript)
WEBCORE_COMMAND(yank)
WEBCORE_COMMAND(yankAndSelect)

#undef WEBCORE_COMMAND

- (void)centerSelectionInVisibleArea:(id)sender
{
    _wkState->page->centerSelectionInVisibleArea();
}

- (void)uppercaseWord:(id)sender
{
    _wkState->page->uppercaseWord();
}

- (void)lowercaseWord:(id)sender
{
    _wkState->page->lowercaseWord();
}

- (void)capitalizeWord:(id)sender
{
    _wkState->page->capitalizeWord();
}

// automatic quote/dash substitution SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7's substitutions plumbing. Ported from
// WebViewImpl::isAutomaticQuoteSubstitutionEnabled / setAutomaticQuoteSubstitutionEnabled /
// isAutomaticDashSubstitutionEnabled / setAutomaticDashSubstitutionEnabled: the flags live in the
// process-global TextChecker state (persisted to user defaults by TextCheckerMac), and a change is
// pushed to the WebContent process via WebProcessProxy::updateTextCheckerState.
- (BOOL)isAutomaticQuoteSubstitutionEnabled
{
    return TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticQuoteSubstitutionEnabled).
- (void)setAutomaticQuoteSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled))
        return;

    TextChecker::setAutomaticQuoteSubstitutionEnabled(flag);
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::isAutomaticDashSubstitutionEnabled).
- (BOOL)isAutomaticDashSubstitutionEnabled
{
    return TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticDashSubstitutionEnabled).
- (void)setAutomaticDashSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled))
        return;

    TextChecker::setAutomaticDashSubstitutionEnabled(flag);
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// Edit ▸ Substitutions menu actions for the quote/dash pair, ported from
// WebViewImpl::toggleAutomaticQuoteSubstitution / toggleAutomaticDashSubstitution (the
// Safari-537-era WKView ships the same responder actions). AppKit dispatches these down the
// responder chain from the menu items, which is what enables those items while the web view is
// first responder.
- (void)toggleAutomaticQuoteSubstitution:(id)sender
{
    TextChecker::setAutomaticQuoteSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// see -toggleAutomaticQuoteSubstitution: above (ported from WebViewImpl::toggleAutomaticDashSubstitution).
- (void)toggleAutomaticDashSubstitution:(id)sender
{
    TextChecker::setAutomaticDashSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// pinch-to-zoom, double-tap smart zoom and the two-finger back/forward swipe.
// WKViewPrivate.h declares allowsMagnification, magnification, -setMagnification:centeredAtPoint:
// and allowsBackForwardNavigationGestures, and Safari sets them. Each method below is ported from
// its WebViewImpl counterpart; the work itself lives in ViewGestureController
// (UIProcess/mac/ViewGestureControllerMac.mm), which needs only a WebPageProxy.

// Mirrors WebViewImpl::clearPromisedImageDragData; the page client calls it when the main frame commits a new
// load, and when the drag the promise was for does not start.
- (void)_wkClearPromisedImageDragData
{
    _wkState->promisedImageDragData.reset();
}

// The controller as it stands, for callers that must not bring one into being: AquaWebKitPageClient
// forwards the two PageClient members whose WebViewImpl counterparts read m_gestureController
// directly (wheelEventWasNotHandledByWebCore, didRestoreScrollPosition).
- (WebKit::ViewGestureController *)_wkExistingGestureController
{
    return _wkState->gestureController.get();
}

// ported from WebViewImpl::ensureGestureController.
- (WebKit::ViewGestureController *)_wkEnsureGestureController
{
    if (!_wkState->gestureController)
        _wkState->gestureController = WebKit::ViewGestureController::create(*_wkState->page);
    return _wkState->gestureController.get();
}

// ported from WebViewImpl::setAllowsMagnification / allowsMagnification.
- (BOOL)allowsMagnification
{
    return _wkState->allowsMagnification;
}

- (void)setAllowsMagnification:(BOOL)allowsMagnification
{
    _wkState->allowsMagnification = allowsMagnification;
}

// ported from WebViewImpl::magnification -- the live gesture's scale while a pinch
// is in flight, otherwise the page scale factor.
- (double)magnification
{
    if (RefPtr gestureController = _wkState->gestureController)
        return gestureController->magnification();
    return _wkState->page->pageScaleFactor();
}

// ported from WebViewImpl::setMagnification(double, CGPoint).
- (void)setMagnification:(double)magnification centeredAtPoint:(NSPoint)point
{
    if (magnification <= 0 || std::isnan(magnification) || std::isinf(magnification))
        [NSException raise:NSInvalidArgumentException format:@"Magnification should be a positive number"];

    _wkState->page->scalePageInViewCoordinates(magnification, WebCore::roundedIntPoint(WebCore::FloatPoint(point)));
}

// ported from WebViewImpl::setMagnification(double) -- centres on the view.
- (void)setMagnification:(double)magnification
{
    if (magnification <= 0 || std::isnan(magnification) || std::isinf(magnification))
        [NSException raise:NSInvalidArgumentException format:@"Magnification should be a positive number"];

    WebCore::FloatPoint viewCenter(NSMidX([self bounds]), NSMidY([self bounds]));
    _wkState->page->scalePageInViewCoordinates(magnification, WebCore::roundedIntPoint(viewCenter));
}

// ported from WebViewImpl::setAllowsBackForwardNavigationGestures -- the swipe needs
// navigation snapshots recorded and implicit rubber-band control to detect the pinned edge.
- (BOOL)allowsBackForwardNavigationGestures
{
    return _wkState->allowsBackForwardNavigationGestures;
}

- (void)setAllowsBackForwardNavigationGestures:(BOOL)allowsBackForwardNavigationGestures
{
    _wkState->allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures;
    _wkState->page->setShouldRecordNavigationSnapshots(allowsBackForwardNavigationGestures);
    _wkState->page->setShouldUseImplicitRubberBandControl(allowsBackForwardNavigationGestures);
}

// ported from WebViewImpl::magnifyWithEvent. ENABLE(MAC_GESTURE_EVENTS) is off for
// this port, so this is upstream's #else branch: hand the pinch straight to the gesture controller.
- (void)magnifyWithEvent:(NSEvent *)event
{
    if (![self allowsMagnification]) {
        [super magnifyWithEvent:event];
        return;
    }

    if (auto *gestureController = [self _wkEnsureGestureController])
        gestureController->handleMagnificationGesture(event.magnification, WebEventFactory::phaseForEvent(event), [self convertPoint:[event locationInWindow] fromView:nil]);
}

// ported from WebViewImpl::smartMagnifyWithEvent (double-tap / two-finger
// double-tap zoom-to-element).
- (void)smartMagnifyWithEvent:(NSEvent *)event
{
    if (![self allowsMagnification]) {
        [super smartMagnifyWithEvent:event];
        return;
    }

    if (auto *gestureController = [self _wkEnsureGestureController])
        gestureController->handleSmartMagnificationGesture([self convertPoint:[event locationInWindow] fromView:nil]);
}

// promised-file drags — dragging an image out of a page onto the Finder or the Desktop to save it.
// Ported from WebViewImpl::setPromisedDataForImage, writePromisedImageDragDataToPasteboard and the
// NSFilePromiseProviderDelegate methods WKWebView forwards to it.

static bool wkMatchesExtensionOrEquivalent(const String& filename, const String& extension)
{
    return filename.endsWithIgnoringASCIICase(makeString('.', extension))
        || (equalLettersIgnoringASCIICase(extension, "jpeg"_s) && filename.endsWithIgnoringASCIICase(".jpg"_s));
}

static NSError *wkUnknownError()
{
    return [NSError errorWithDomain:WKErrorDomain code:WKErrorUnknown userInfo:nil];
}

// Called from AquaWebKitPageClient::setPromisedDataForImage, ahead of the drag that carries the promise, which
// takes it.
- (void)_wkSetPromisedImageData:(NSData *)imageData uti:(NSString *)uti filename:(const String&)filename extension:(const String&)extension title:(NSString *)title url:(NSString *)url visibleURL:(NSString *)visibleURL archiveBuffer:(NSData *)archiveData originIdentifier:(NSString *)originIdentifier
{
    String filenameWithExtension = filename;
    if (!wkMatchesExtensionOrEquivalent(filename, extension))
        filenameWithExtension = makeString(filename, '.', extension);
    filenameWithExtension = filenameByFixingIllegalCharacters(filenameWithExtension.createNSString().get());

    _wkState->promisedImageDragData = WKPromisedImageDragData {
        .imageData = imageData,
        .filename = filenameWithExtension.createNSString(),
        .title = title,
        .url = url,
        .visibleURL = visibleURL,
        .imageUTI = uti,
        .archiveData = archiveData,
        .originIdentifier = originIdentifier,
    };
}

- (void)_wkWritePromisedImageDragData:(const WKPromisedImageDragData&)data toPasteboard:(NSPasteboard *)pasteboard
{
    NSString *visibleURLString = data.visibleURL.get();
    NSString *titleString = data.title.get();

    [pasteboard setString:visibleURLString forType:WebCore::legacyStringPasteboardTypeSingleton()];
    [pasteboard setString:visibleURLString forType:WebKit::PasteboardTypes::WebURLPboardType];
    [pasteboard setString:titleString forType:WebKit::PasteboardTypes::WebURLNamePboardType];
    [pasteboard setPropertyList:@[@[visibleURLString], @[titleString]] forType:WebKit::PasteboardTypes::WebURLsWithTitlesPboardType];

    NSURL *nsURL = [NSURL URLWithString:visibleURLString];
    if (NSURL *baseCocoaURL = [nsURL baseURL])
        [pasteboard setPropertyList:@[[nsURL relativeString], [baseCocoaURL absoluteString]] forType:WebCore::legacyURLPasteboardTypeSingleton()];
    else if (nsURL)
        [pasteboard setPropertyList:@[[nsURL absoluteString], @""] forType:WebCore::legacyURLPasteboardTypeSingleton()];
    else
        [pasteboard setPropertyList:@[@"", @""] forType:WebCore::legacyURLPasteboardTypeSingleton()];

    if ([data.imageUTI length] && [data.imageData length])
        [pasteboard setData:data.imageData.get() forType:data.imageUTI.get()];

    RetainPtr image = adoptNS([[NSImage alloc] initWithData:data.imageData.get()]);
    if (NSData *tiffData = [image TIFFRepresentation])
        [pasteboard setData:tiffData forType:WebCore::legacyTIFFPasteboardTypeSingleton()];

    if (data.archiveData) {
        [pasteboard setData:data.archiveData.get() forType:(__bridge NSString *)kUTTypeWebArchive];
        [pasteboard setData:data.archiveData.get() forType:WebKit::PasteboardTypes::WebArchivePboardType];
    }

    if ([data.originIdentifier length]) {
        WebCore::PasteboardCustomData customData;
        customData.setOrigin(data.originIdentifier.get());
        [pasteboard setData:customData.createSharedBuffer()->createNSData().get() forType:@(WebCore::PasteboardCustomData::cocoaType().characters())];
    }
}

// NSFilePromiseProviderDelegate. Ported from WebViewImpl::fileNameForFilePromiseProvider.
- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)filePromiseProvider fileNameForType:(NSString *)fileType
{
    if (auto userInfo = dynamic_objc_cast<WKPromisedAttachmentContext>(filePromiseProvider.userInfo))
        return [userInfo fileName];

    if (auto imageContext = dynamic_objc_cast<WKPromisedImageContext>(filePromiseProvider.userInfo))
        return [imageContext fileName];

    return nil;
}

// NSFilePromiseProviderDelegate. Ported from WebViewImpl::writeToURLForFilePromiseProvider.
- (void)filePromiseProvider:(NSFilePromiseProvider *)filePromiseProvider writePromiseToURL:(NSURL *)fileURL completionHandler:(void (^)(NSError *))completionHandler
{
    if (auto userInfo = dynamic_objc_cast<WKPromisedAttachmentContext>(filePromiseProvider.userInfo)) {
        if (RefPtr attachment = _wkState->page->attachmentForIdentifier([userInfo attachmentIdentifier])) {
            attachment->doWithFileWrapper([fileURL = RetainPtr { fileURL }, completionHandler](NSFileWrapper *fileWrapper) {
                NSError *attachmentWritingError = nil;
                if ([fileWrapper writeToURL:fileURL.get() options:0 originalContentsURL:nil error:&attachmentWritingError])
                    completionHandler(nil);
                else
                    completionHandler(attachmentWritingError);
            });
            return;
        }
        completionHandler(wkUnknownError());
        return;
    }

    if (auto imageContext = dynamic_objc_cast<WKPromisedImageContext>(filePromiseProvider.userInfo)) {
        String imageURLString { [imageContext url] };
        RetainPtr data = [imageContext data];
        if (!data && !imageURLString.isEmpty())
            data = [NSData dataWithContentsOfURL:adoptNS([[NSURL alloc] initWithString:[imageContext url]]).get()];
        if (data) {
            NSError *error = nil;
            if ([data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
                if (!imageURLString.isEmpty())
                    FileSystem::setMetadataURL(fileURL.path, imageURLString);
                completionHandler(nil);
            } else
                completionHandler(error);
            return;
        }
    }

    completionHandler(wkUnknownError());
}

// WebViewImpl::toggleAutomaticLinkDetection.
- (void)toggleAutomaticLinkDetection:(id)sender
{
    TextChecker::setAutomaticLinkDetectionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticLinkDetectionEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// Edit > Spelling and Grammar, and Edit > Speech. Safari 7 dispatches these
// action selectors down the responder chain to the web view, which is what enables the submenu
// while the web view is first responder; the Safari-537-era WKView implements them all. Each is
// ported from the WebViewImpl method of the same name — they depend only on the process-global
// TextChecker state and on WebPageProxy, both of which this view has.

// ported from WebViewImpl::showGuessPanel.
- (void)showGuessPanel:(id)sender
{
    RetainPtr checker = [NSSpellChecker sharedSpellChecker];
    if (!checker) {
        LOG_ERROR("No NSSpellChecker");
        return;
    }

    RetainPtr spellingPanel = [checker spellingPanel];
    if ([spellingPanel isVisible]) {
        [spellingPanel orderOut:sender];
        return;
    }

    _wkState->page->advanceToNextMisspelling(true);
    [spellingPanel orderFront:sender];
}

// ported from WebViewImpl::checkSpelling.
- (void)checkSpelling:(id)sender
{
    _wkState->page->advanceToNextMisspelling(false);
}

// ported from WebViewImpl::changeSpelling -- the guess panel sends the chosen
// replacement as the sender's selected cell.
- (void)changeSpelling:(id)sender
{
    RetainPtr word = [[sender selectedCell] stringValue];
    _wkState->page->changeSpellingToWord(word.get());
}

// ported from WebViewImpl::toggleContinuousSpellChecking.
- (void)toggleContinuousSpellChecking:(id)sender
{
    TextChecker::setContinuousSpellCheckingEnabled(!TextChecker::state().contains(TextCheckerState::ContinuousSpellCheckingEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleGrammarChecking.
- (void)toggleGrammarChecking:(id)sender
{
    TextChecker::setGrammarCheckingEnabled(!TextChecker::state().contains(TextCheckerState::GrammarCheckingEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleAutomaticSpellingCorrection.
- (void)toggleAutomaticSpellingCorrection:(id)sender
{
    TextChecker::setAutomaticSpellingCorrectionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticSpellingCorrectionEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleAutomaticTextReplacement.
- (void)toggleAutomaticTextReplacement:(id)sender
{
    TextChecker::setAutomaticTextReplacementEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticTextReplacementEnabled));
    protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleSmartInsertDelete -- this one is page state,
// not TextChecker state, so it needs no updateTextCheckerState push.
- (void)toggleSmartInsertDelete:(id)sender
{
    _wkState->page->setSmartInsertDeleteEnabled(!_wkState->page->isSmartInsertDeleteEnabled());
}

// ported from WebViewImpl::orderFrontSubstitutionsPanel.
- (void)orderFrontSubstitutionsPanel:(id)sender
{
    RetainPtr checker = [NSSpellChecker sharedSpellChecker];
    if (!checker) {
        LOG_ERROR("No NSSpellChecker");
        return;
    }

    RetainPtr substitutionsPanel = [checker substitutionsPanel];
    if ([substitutionsPanel isVisible]) {
        [substitutionsPanel orderOut:sender];
        return;
    }
    [substitutionsPanel orderFront:sender];
}

// ported from WebViewImpl::startSpeaking -- the selection (or, with no selection,
// the whole document) is fetched asynchronously and handed to NSApplication's speech synthesis.
- (void)startSpeaking:(id)sender
{
    _wkState->page->getSelectionOrContentsAsString([](const WTF::String& string) {
        if (!string)
            return;
        [NSApp speakString:string.createNSString().get()];
    });
}

// ported from WebViewImpl::stopSpeaking.
- (void)stopSpeaking:(id)sender
{
    [NSApp stopSpeaking:sender];
}

// NSMenuItem downcast for -validateUserInterfaceItem: (the Safari-537-era
// WKView.mm static menuItem() helper). Toolbar items validate through the same protocol and must
// not be sent NSMenuItem messages, so anything else answers nil.
static NSMenuItem *wkMenuItem(id <NSValidatedUserInterfaceItem> item)
{
    if (![(NSObject *)item isKindOfClass:[NSMenuItem class]])
        return nil;
    return (NSMenuItem *)item;
}

// WebViewImpl's validation and asynchronous menu/toolbar updates. This 10.9 WKView owns its state,
// so the reply holds a weak view in place of WebViewImpl's weak implementation pointer.
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL action = [item action];

    if (action == @selector(showGuessPanel:)) {
        if (RetainPtr menuItem = wkMenuItem(item))
            [menuItem setTitle:WebCore::contextMenuItemTagShowSpellingPanel(![[[NSSpellChecker sharedSpellChecker] spellingPanel] isVisible]).createNSString().get()];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(checkSpelling:) || action == @selector(changeSpelling:))
        return _wkState->page->editorState().isContentEditable;

    if (action == @selector(toggleContinuousSpellChecking:)) {
        bool enabled = TextChecker::isContinuousSpellCheckingAllowed();
        bool checked = enabled && TextChecker::state().contains(TextCheckerState::ContinuousSpellCheckingEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return enabled;
    }

    if (action == @selector(toggleGrammarChecking:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::GrammarCheckingEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return true;
    }

    if (action == @selector(toggleAutomaticSpellingCorrection:)) {
        bool enable = _wkState->page->editorState().canEnableAutomaticSpellingCorrection;
        protect(wkMenuItem(item)).get().state = TextChecker::state().contains(TextCheckerState::AutomaticSpellingCorrectionEnabled) && enable ? NSControlStateValueOn : NSControlStateValueOff;
        return enable;
    }

    if (action == @selector(orderFrontSubstitutionsPanel:)) {
        if (RetainPtr menuItem = wkMenuItem(item))
            [menuItem setTitle:WebCore::contextMenuItemTagShowSubstitutions(![[[NSSpellChecker sharedSpellChecker] substitutionsPanel] isVisible]).createNSString().get()];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(toggleSmartInsertDelete:)) {
        bool checked = _wkState->page->isSmartInsertDeleteEnabled();
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(toggleAutomaticQuoteSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(toggleAutomaticDashSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(toggleAutomaticLinkDetection:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticLinkDetectionEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(toggleAutomaticTextReplacement:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticTextReplacementEnabled);
        [protect(wkMenuItem(item)) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState->page->editorState().isContentEditable;
    }

    if (action == @selector(uppercaseWord:) || action == @selector(lowercaseWord:) || action == @selector(capitalizeWord:))
        return _wkState->page->editorState().selectionType == WebCore::SelectionType::Range && _wkState->page->editorState().isContentEditable;

    if (action == @selector(stopSpeaking:))
        return [NSApp isSpeaking];

    // The centerSelectionInVisibleArea: selector is enabled if there's a selection range or if there's an insertion point in an editable area.
    if (action == @selector(centerSelectionInVisibleArea:))
        return _wkState->page->editorState().selectionType == WebCore::SelectionType::Range || (_wkState->page->editorState().isContentEditable && _wkState->page->editorState().selectionType == WebCore::SelectionType::Caret);

    // Next, handle editor commands. Start by returning true for anything that is not an editor command.
    // Returning true is the default thing to do in an AppKit validate method for any selector that is not recognized.
    String commandName = commandNameForSelector([item action]);
    if (!WebCore::Editor::commandIsSupportedFromMenuOrKeyBinding(commandName))
        return true;

    // Add this item to the vector of items for a given command that are awaiting validation.
    auto addResult = _wkState->validationMap.add(commandName, Vector<RetainPtr<id<NSValidatedUserInterfaceItem>>> { });
    addResult.iterator->value.append(item);
    if (addResult.isNewEntry) {
        // If we are not already awaiting validation for this command, start the asynchronous validation process.
        // FIXME: Theoretically, there is a race here; when we get the answer it might be old, from a previous time
        // we asked for the same command; there is no guarantee the answer is still valid.
        _wkState->page->validateCommand(commandName, [weakSelf = WeakObjCPtr<WKView> { self }, commandName](bool isEnabled, int32_t state) {
            RetainPtr view = weakSelf.get();
            if (!view)
                return;
            for (auto& item : view->_wkState->validationMap.take(commandName)) {
                RetainPtr menuItem = wkMenuItem(item.get());
                RetainPtr toolbarItem = dynamic_objc_cast<NSToolbarItem>((NSObject *)item.get());
                [menuItem setState:state];
                [menuItem setEnabled:isEnabled];
                [toolbarItem setEnabled:isEnabled];
            }
        });
    }

    // Treat as enabled until the web process replies and the menu/toolbar items are updated.
    // FIXME <rdar://problem/8803459>: This means disabled items will flash enabled at first for a moment.
    // But returning NO here would be worse; that would make keyboard commands such as command-C fail.
    return true;
}
@end
// upstream WKView.mm ends with the lines below. This reimplementation opens no
// ALLOW_DEPRECATED_DECLARATIONS block and no PLATFORM(MAC) guard, so they are kept commented out
// for upstream merges.
// ALLOW_DEPRECATED_DECLARATIONS_END
//
// #endif // PLATFORM(MAC)
