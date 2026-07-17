/*
 * Copyright (C) 2006-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Apple Inc. ("Apple") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "WebInspectorClient.h"

#import "DOMNodeInternal.h"
#import "LegacyWebPageInspectorController.h"
#import "WebDelegateImplementationCaching.h"
#import "WebFrameInternal.h"
#import "WebFrameView.h"
#import "WebInspector.h"
#import "WebInspectorFrontend.h"
#import "WebInspectorPrivate.h"
#import "WebLocalizableStringsInternal.h"
#import "WebNodeHighlighter.h"
#import "WebPolicyDelegate.h"
#import "WebQuotaManager.h"
#import "WebSecurityOriginPrivate.h"
#import "WebUIDelegatePrivate.h"
#import "WebViewInternal.h"
#import <JavaScriptCore/InspectorAgentBase.h>
#import <SecurityInterface/SFCertificatePanel.h>
#import <SecurityInterface/SFCertificateView.h>
#import <WebCore/CertificateInfo.h>
#import <WebCore/InspectorFrontendClient.h>
#import <WebCore/LocalFrame.h>
#import <WebCore/Page.h>
#import <WebCore/PageInspectorController.h>
#import <WebCore/ScriptController.h>
#import <WebCore/Settings.h>
#import <WebKitLegacy/DOMExtensions.h>
#import <algorithm>
#import <wtf/NakedPtr.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/text/Base64.h>

using namespace WebCore;
using namespace Inspector;

static const CGFloat minimumWindowWidth = 500;
static const CGFloat minimumWindowHeight = 400;
static const CGFloat initialWindowWidth = 1000;
static const CGFloat initialWindowHeight = 650;

@interface WebInspectorWindowController : NSWindowController <NSWindowDelegate, WebPolicyDelegate, WebUIDelegate> {
@private
    RetainPtr<WebView> _inspectedWebView;
    RetainPtr<WebView> _frontendWebView;
    NakedPtr<WebInspectorFrontendClient> _frontendClient;
    WebInspectorClient* _inspectorClient;
    BOOL _attachedToInspectedWebView;
    BOOL _shouldAttach;
    BOOL _visible;
    BOOL _destroyingInspectorView;
}
- (id)initWithInspectedWebView:(WebView *)inspectedWebView isUnderTest:(BOOL)isUnderTest;
- (NSString *)inspectorPagePath;
- (NSString *)inspectorTestPagePath;
- (WebView *)frontendWebView;
- (void)attach;
- (void)detach;
- (BOOL)attached;
- (void)setFrontendClient:(NakedPtr<WebInspectorFrontendClient>)frontendClient;
- (void)setInspectorClient:(NakedPtr<WebInspectorClient>)inspectorClient;
- (NakedPtr<WebInspectorClient>)inspectorClient;
- (void)setAttachedWindowHeight:(unsigned)height;
- (void)setDockingUnavailable:(BOOL)unavailable;
- (void)destroyInspectorView;
@end


// MARK: -

WebInspectorClient::WebInspectorClient(WebView* inspectedWebView)
    : m_inspectedWebView(inspectedWebView)
    , m_highlighter(adoptNS([[WebNodeHighlighter alloc] initWithInspectedWebView:inspectedWebView]))
{
}

WebInspectorClient::~WebInspectorClient() = default;

void WebInspectorClient::inspectedPageDestroyed()
{
}

FrontendChannel* WebInspectorClient::openLocalFrontend(PageInspectorController* inspectedPageController)
{
    RetainPtr<WebInspectorWindowController> windowController = adoptNS([[WebInspectorWindowController alloc] initWithInspectedWebView:m_inspectedWebView.get().get() isUnderTest:inspectedPageController->isUnderTest()]);
    [windowController.get() setInspectorClient:this];

    m_frontendPage = core([windowController.get() frontendWebView]);

    RefPtr webPageInspectorController = [m_inspectedWebView.get() inspectorController];
    m_frontendClient = makeUnique<WebInspectorFrontendClient>(m_inspectedWebView.get().get(), *webPageInspectorController, windowController.get(), inspectedPageController, m_frontendPage.get(), createFrontendSettings());

    RetainPtr<WebInspectorFrontend> webInspectorFrontend = adoptNS([[WebInspectorFrontend alloc] initWithFrontendClient:m_frontendClient.get()]);
    [[m_inspectedWebView.get() inspector] setFrontend:webInspectorFrontend.get()];

    m_frontendPage->inspectorController().setInspectorFrontendClient(m_frontendClient.get());

    webPageInspectorController->connectFrontend(*this);
    return nullptr;
}

void WebInspectorClient::bringFrontendToFront()
{
    ASSERT(m_frontendClient);
    m_frontendClient->bringToFront();
}

void WebInspectorClient::didResizeMainFrame(LocalFrame*)
{
    if (m_frontendClient)
        m_frontendClient->attachAvailabilityChanged(canAttach());
}

void WebInspectorClient::windowFullScreenDidChange()
{
    if (m_frontendClient)
        m_frontendClient->attachAvailabilityChanged(canAttach());
}

bool WebInspectorClient::canAttach()
{
    return m_frontendClient->canAttach() && !inspectorAttachDisabled();
}

void WebInspectorClient::highlight()
{
    [m_highlighter.get() highlight];
}

void WebInspectorClient::hideHighlight()
{
    [m_highlighter.get() hideHighlight];
}

void WebInspectorClient::didSetSearchingForNode(bool enabled)
{
    RetainPtr inspector = [m_inspectedWebView.get() inspector];

    ASSERT(isMainThread());

    if (enabled) {
        [[m_inspectedWebView.get() window] makeKeyAndOrderFront:nil];
        [[m_inspectedWebView.get() window] makeFirstResponder:m_inspectedWebView.get().get()];
        [[NSNotificationCenter defaultCenter] postNotificationName:WebInspectorDidStartSearchingForNode object:inspector.get()];
    } else
        [[NSNotificationCenter defaultCenter] postNotificationName:WebInspectorDidStopSearchingForNode object:inspector.get()];
}

void WebInspectorClient::releaseFrontend()
{
    m_frontendClient = nullptr;
    m_frontendPage = nullptr;
}

WebInspectorFrontendClient::WebInspectorFrontendClient(WebView* inspectedWebView, LegacyWebPageInspectorController& webPageInspectorController, WebInspectorWindowController* frontendWindowController, PageInspectorController* inspectedPageController, Page* frontendPage, std::unique_ptr<Settings> settings)
    : InspectorFrontendClientLocal(inspectedPageController, frontendPage, WTF::move(settings))
    , m_inspectedWebView(inspectedWebView)
    , m_webPageInspectorController(&webPageInspectorController)
    , m_frontendWindowController(frontendWindowController)
{
    [frontendWindowController setFrontendClient:this];
}

void WebInspectorFrontendClient::attachAvailabilityChanged(bool available)
{
    setDockingUnavailable(!available);
    [m_frontendWindowController.get() setDockingUnavailable:!available];
}

bool WebInspectorFrontendClient::canAttach()
{
    if ([[m_frontendWindowController window] styleMask] & NSWindowStyleMaskFullScreen)
        return false;

    return canAttachWindow();
}

void WebInspectorFrontendClient::frontendLoaded()
{
    [m_frontendWindowController.get() showWindow:nil];
    if ([m_frontendWindowController.get() attached])
        restoreAttachedWindowHeight();

    InspectorFrontendClientLocal::frontendLoaded();

    RetainPtr frame = [m_inspectedWebView.get() mainFrame];

    WebFrameLoadDelegateImplementationCache* implementations = WebViewGetFrameLoadDelegateImplementations(m_inspectedWebView.get().get());
    if (implementations->didClearInspectorWindowObjectForFrameFunc)
        CallFrameLoadDelegate(implementations->didClearInspectorWindowObjectForFrameFunc, m_inspectedWebView.get().get(),
                              @selector(webView:didClearInspectorWindowObject:forFrame:), [frame.get() windowObject], frame.get());

    bool attached = [m_frontendWindowController.get() attached];
    setAttachedWindow(attached ? DockSide::Bottom : DockSide::Undocked);
}

void WebInspectorFrontendClient::startWindowDrag()
{
    [[m_frontendWindowController window] performWindowDragWithEvent:[NSApp currentEvent]];
}

String WebInspectorFrontendClient::localizedStringsURL() const
{
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"];
    if (!bundle)
        return String();

    NSString *path = [bundle pathForResource:@"localizedStrings" ofType:@"js"];
    if (!path.length)
        return String();
    
    // MAVERICKS_BACKPORT: +[NSURL fileURLWithPath:isDirectory:] returns id on the 10.9 SDK, so the
    // result is cast to NSURL * and -absoluteString is sent explicitly (dot-property syntax on id
    // does not resolve here).
    return [(NSURL *)[NSURL fileURLWithPath:path isDirectory:NO] absoluteString];
}

void WebInspectorFrontendClient::bringToFront()
{
    updateWindowTitle();

    [m_frontendWindowController.get() showWindow:nil];

    // Use the window from the WebView since m_frontendWindowController's window
    // is not the same when the Inspector is docked.
    WebView *frontendWebView = [m_frontendWindowController.get() frontendWebView];
    [[frontendWebView window] makeFirstResponder:frontendWebView];
}

void WebInspectorFrontendClient::closeWindow()
{
    [m_frontendWindowController.get() destroyInspectorView];
}

void WebInspectorFrontendClient::reopen()
{
    RetainPtr inspector = [m_inspectedWebView.get() inspector];
    [inspector.get() close:nil];
    [inspector.get() show:nil];
}

void WebInspectorFrontendClient::resetState()
{
    InspectorFrontendClientLocal::resetState();

    auto inspectorClient = [m_frontendWindowController inspectorClient];
    inspectorClient->deleteInspectorStartsAttached();
    inspectorClient->deleteInspectorAttachDisabled();

    [NSWindow removeFrameUsingName:[[m_frontendWindowController window] frameAutosaveName]];
}

void WebInspectorFrontendClient::setForcedAppearance(InspectorFrontendClient::Appearance appearance)
{
    NSWindow *window = [m_frontendWindowController window];
    ASSERT(window);

    switch (appearance) {
    case InspectorFrontendClient::Appearance::System:
        window.appearance = nil;
        break;

    case InspectorFrontendClient::Appearance::Light:
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        break;

    case InspectorFrontendClient::Appearance::Dark:
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        break;
    }
}

bool WebInspectorFrontendClient::supportsDockSide(DockSide dockSide)
{
    switch (dockSide) {
    case DockSide::Undocked:
    case DockSide::Bottom:
        return true;

    case DockSide::Right:
    case DockSide::Left:
        return false;
    }

    ASSERT_NOT_REACHED();
    return false;
}

void WebInspectorFrontendClient::attachWindow(DockSide)
{
    if ([m_frontendWindowController.get() attached])
        return;
    [m_frontendWindowController.get() attach];
    restoreAttachedWindowHeight();
}

void WebInspectorFrontendClient::detachWindow()
{
    [m_frontendWindowController.get() detach];
}

void WebInspectorFrontendClient::setAttachedWindowHeight(unsigned height)
{
    [m_frontendWindowController.get() setAttachedWindowHeight:height];
}

void WebInspectorFrontendClient::setAttachedWindowWidth(unsigned)
{
    // Dock to right is not implemented in WebKit 1.
}

void WebInspectorFrontendClient::setSheetRect(const FloatRect& rect)
{
    m_sheetRect = rect;
}

void WebInspectorFrontendClient::inspectedURLChanged(const String& newURL)
{
    m_inspectedURL = newURL;
    updateWindowTitle();
}

void WebInspectorFrontendClient::showCertificate(const CertificateInfo& certificateInfo)
{
    ASSERT(!certificateInfo.isEmpty());

    RetainPtr<SFCertificatePanel> certificatePanel = adoptNS([[SFCertificatePanel alloc] init]);

    NSWindow *window = [[m_frontendWindowController frontendWebView] window];
    if (!window)
        window = [NSApp keyWindow];

    [certificatePanel beginSheetForWindow:window modalDelegate:nil didEndSelector:NULL contextInfo:nullptr trust:certificateInfo.trust().get() showGroup:YES];

    // This must be called after the trust panel has been displayed, because the certificateView doesn't exist beforehand.
    SFCertificateView *certificateView = [certificatePanel certificateView];
    [certificateView setDisplayTrust:YES];
    [certificateView setEditableTrust:NO];
    [certificateView setDisplayDetails:YES];
    [certificateView setDetailsDisclosed:YES];
}

#if ENABLE(INSPECTOR_TELEMETRY)
bool WebInspectorFrontendClient::supportsDiagnosticLogging()
{
    auto* page = frontendPage();
    return page ? page->settings().diagnosticLoggingEnabled() : false;
}

void WebInspectorFrontendClient::logDiagnosticEvent(const String& eventName, const DiagnosticLoggingClient::ValueDictionary& dictionary)
{
    if (auto* page = frontendPage())
        page->diagnosticLoggingClient().logDiagnosticMessageWithValueDictionary(eventName, "Legacy Web Inspector Frontend Diagnostics"_s, dictionary, ShouldSample::No);
}
#endif

void WebInspectorFrontendClient::updateWindowTitle() const
{
    RetainPtr title = [NSString stringWithFormat:UI_STRING_INTERNAL("Web Inspector — %@", "Web Inspector window title"), m_inspectedURL.createNSString().get()];
    [[m_frontendWindowController.get() window] setTitle:title.get()];
}

bool WebInspectorFrontendClient::canSave(InspectorFrontendClient::SaveMode saveMode)
{
    switch (saveMode) {
    case InspectorFrontendClient::SaveMode::SingleFile:
        return true;

    case InspectorFrontendClient::SaveMode::FileVariants:
        return false;
    }

    ASSERT_NOT_REACHED();
    return false;
}

void WebInspectorFrontendClient::save(Vector<InspectorFrontendClient::SaveData>&& saveDatas, bool forceSaveAs)
{
    // FIXME: Share with WebInspectorUIProxyMac.

    ASSERT(saveDatas.size() == 1);

    auto suggestedURL = saveDatas[0].url;
    ASSERT(!suggestedURL.isEmpty());

    RetainPtr<NSURL> platformURL = m_suggestedToActualURLMap.get(suggestedURL);
    if (!platformURL) {
        platformURL = [NSURL URLWithString:suggestedURL.createNSString().get()];
        // The user must confirm new filenames before we can save to them.
        forceSaveAs = true;
    }

    ASSERT(platformURL);
    if (!platformURL)
        return;

    // Necessary for the block below.
    String suggestedURLCopy = suggestedURL;
    String contentCopy = saveDatas[0].content;
    bool base64Encoded = saveDatas[0].base64Encoded;

    auto saveToURL = ^(NSURL *actualURL) {
        ASSERT(actualURL);

        m_suggestedToActualURLMap.set(suggestedURLCopy, actualURL);

        if (base64Encoded) {
            auto decodedData = base64Decode(contentCopy, { Base64DecodeOption::ValidatePadding });
            if (!decodedData)
                return;
            RetainPtr dataContent = toNSData(decodedData->span());
            [dataContent writeToURL:actualURL atomically:YES];
        } else
            [contentCopy.createNSString() writeToURL:actualURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };

    if (!forceSaveAs) {
        saveToURL(platformURL.get());
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = platformURL.get().lastPathComponent;

    // If we have a file URL we've already saved this file to a path and
    // can provide a good directory to show. Otherwise, use the system's
    // default behavior for the initial directory to show in the dialog.
    if (platformURL.get().isFileURL)
        panel.directoryURL = [platformURL URLByDeletingLastPathComponent];

    auto completionHandler = ^(NSInteger result) {
        if (result == NSModalResponseCancel)
            return;
        ASSERT(result == NSModalResponseOK);
        saveToURL(panel.URL);
    };

    NSWindow *frontendWindow = [[m_frontendWindowController frontendWebView] window];
    RetainPtr window = frontendWindow ? frontendWindow : [NSApp keyWindow];
    if (window)
        [panel beginSheetModalForWindow:window.get() completionHandler:completionHandler];
    else
        completionHandler([panel runModal]);
}

void WebInspectorFrontendClient::sendMessageToBackend(const String& message)
{
    if (RefPtr controller = m_webPageInspectorController.get())
        controller->dispatchMessageFromFrontend(message);
}

// MARK: -

@implementation WebInspectorWindowController
- (id)init
{
    if (!(self = [super initWithWindow:nil]))
        return nil;

    // Keep preferences separate from the rest of the client, making sure we are using expected preference values.

    auto preferences = adoptNS([[WebPreferences alloc] init]);
    [preferences setAllowsAnimatedImages:YES];
    [preferences setAuthorAndUserStylesEnabled:YES];
    [preferences setAutosaves:NO];
    [preferences setDefaultFixedFontSize:11];
    [preferences setFixedFontFamily:@"Menlo"];
    [preferences setJavaScriptEnabled:YES];
    [preferences setLoadsImagesAutomatically:YES];
    [preferences setMinimumFontSize:0];
    [preferences setMinimumLogicalFontSize:9];
    [preferences setTabsToLinks:NO];
    [preferences setUserStyleSheetEnabled:NO];
    [preferences setAllowFileAccessFromFileURLs:YES];
    [preferences setAllowUniversalAccessFromFileURLs:YES];
    [preferences setAllowTopNavigationToDataURLs:YES];
    [preferences setStorageBlockingPolicy:WebAllowAllStorage];

    _frontendWebView = adoptNS([[WebView alloc] init]);
    [_frontendWebView setPreferences:preferences.get()];
    [_frontendWebView setProhibitsMainFrameScrolling:YES];
    [_frontendWebView setUIDelegate:self];
    [_frontendWebView setPolicyDelegate:self];

    [self setWindowFrameAutosaveName:@"Web Inspector 2"];
    return self;
}

// MAVERICKS_BACKPORT: the classic Safari-8-era frontend needs the same load-time adaptations WK1-side
// that WK2 applies in WebInspectorUIProxy::platformInspectorPageLoadOverride: strip the CSP meta
// (under file:// the frontend's `default-src 'self'` blocks everything because 'self' is the null
// origin) and bridge the classic InspectorFrontendHost API shapes (platform()/localizedStringsURL()/
// inspectorBackendCommandsURL() as METHODS, setToolbarHeight/setAttachedWindow* present) to the
// modern WebKit 615 IDL (attribute getters / removed methods), and — like WK2 — wrap the frontend's
// bare per-domain commands in the modern Target domain (the Target-protocol bridge below): the
// WebKit 615 WK1 local backend routes every command through Target, so without the bridge the DOM
// and Resources trees stay empty and console eval returns nothing. Every bridge is typeof-guarded,
// so a modern frontend (the built-tree Test.html) passes through untouched. The WK2 unified-toolbar
// CSS and toolbar-mousedown window-drag shims are ported too (#52): the undocked WK1 inspector
// window hosts the frontend WebView in its frame view so the HTML toolbar fills the titlebar region
// (see -[WebInspectorWindowController showWindow:]), which needs the same painted gradient,
// traffic-light inset, and whole-toolbar drag handle the WK2 inspector window uses.
static NSData *wkTransformedClassicFrontendPage(NSString *pagePath)
{
    NSData *htmlData = [NSData dataWithContentsOfFile:pagePath options:NSDataReadingMappedIfSafe error:nullptr];
    if (!htmlData)
        return nil;
    NSString *html = adoptNS([[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding]).autorelease();
    if (!html)
        return htmlData;

    NSRange metaStart = [html rangeOfString:@"<meta http-equiv=\"Content-Security-Policy\""];
    if (metaStart.location != NSNotFound) {
        NSRange metaEnd = [html rangeOfString:@">" options:0 range:NSMakeRange(metaStart.location, html.length - metaStart.location)];
        if (metaEnd.location != NSNotFound) {
            NSRange whole = NSMakeRange(metaStart.location, metaEnd.location - metaStart.location + 1);
            html = [html stringByReplacingCharactersInRange:whole withString:@"<!-- CSP stripped by MAVERICKS_BACKPORT -->"];
        }
    }

    NSRange firstScript = [html rangeOfString:@"<script"];
    if (firstScript.location != NSNotFound) {
        // Unified titlebar+toolbar CSS (same rules WebInspectorUIProxy::platformInspectorPageLoadOverride
        // injects for WK2, #52): a 22px #wk-titlebar strip (inserted by the shim below) holds the
        // floating traffic lights and the centered window title, the stock toolbar below keeps its
        // untouched 56px layout (its fixed border-box height means padding would squish the icons),
        // and ONE continuous gradient painted on body spans strip+toolbar (78px). The stock undocked
        // .toolbar is transparent (it expected a native textured window), so the gradient shows
        // through it.
        // Gradient endpoints measured off a native Mavericks unified titlebar+toolbar (Finder
        // window, lossless screen samples, frontmost-app-verified in each state): ACTIVE = 1px
        // rgb(242) top bevel, rgb(234) -> rgb(176), 1px rgb(105) bottom border; INACTIVE =
        // rgb(240) -> rgb(223), 1px rgb(166) bottom border. The 4px top-corner radius + the
        // transparent WebView (drawsBackground NO in the undocked branch of -showWindow:) let the
        // NSThemeFrame's own rounded titlebar corners show through instead of the WebView painting
        // square over them.
        NSString *unifiedToolbarCSS = @"<style>"
            @"body:not(.docked){background-image:-webkit-linear-gradient(top,rgb(242,242,242),rgb(234,234,234) 1px,rgb(176,176,176) 77px,rgb(105,105,105) 77px,rgb(105,105,105) 78px);background-repeat:no-repeat;background-size:100% 78px;border-top-left-radius:4px;border-top-right-radius:4px;}"
            @"body:not(.docked).window-inactive{background-image:-webkit-linear-gradient(top,rgb(240,240,240),rgb(223,223,223) 77px,rgb(166,166,166) 77px,rgb(166,166,166) 78px);}"
            @"body.docked{background-color:white;}"
            @"#wk-titlebar{height:22px;-webkit-flex:none;text-align:center;font-family:'Lucida Grande';font-size:13px;line-height:22px;color:rgba(0,0,0,0.85);text-shadow:rgba(255,255,255,0.5) 0 1px 0;padding:0 80px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;cursor:default;}"
            @"body.window-inactive #wk-titlebar{color:rgba(0,0,0,0.5);}"
            @"body.docked #wk-titlebar{display:none;}"
            @"</style>";
        NSString *shim = @"<script>(function(){"
                          "var IFH=window.InspectorFrontendHost;if(!IFH)return;"
                          "function asMethod(name){var val=IFH[name];Object.defineProperty(IFH,name,{value:function(){return val;},writable:true,configurable:true});}"
                          "if(typeof IFH.platform!=='function')asMethod('platform');"
                          "if(typeof IFH.localizedStringsURL!=='function')asMethod('localizedStringsURL');"
                          "if(typeof IFH.inspectorBackendCommandsURL!=='function')Object.defineProperty(IFH,'inspectorBackendCommandsURL',{value:function(){return 'InspectorBackendCommands.js';},writable:true,configurable:true});"
                          "if(typeof IFH.inspectorBackendCommandsURLs!=='function')Object.defineProperty(IFH,'inspectorBackendCommandsURLs',{value:function(){return ['InspectorBackendCommands.js'];},writable:true,configurable:true});"
                          "if(typeof IFH.debuggableType!=='function'&&'debuggableInfo' in IFH){var di=IFH.debuggableInfo;Object.defineProperty(IFH,'debuggableType',{value:function(){return di&&di.debuggableType||'web';},writable:true,configurable:true});}"
                          "if(typeof IFH.setToolbarHeight!=='function')Object.defineProperty(IFH,'setToolbarHeight',{value:function(){},writable:true,configurable:true});"
                          "if(typeof IFH.setAttachedWindowHeight!=='function')Object.defineProperty(IFH,'setAttachedWindowHeight',{value:function(){},writable:true,configurable:true});"
                          "if(typeof IFH.setAttachedWindowWidth!=='function')Object.defineProperty(IFH,'setAttachedWindowWidth',{value:function(){},writable:true,configurable:true});"
                          // Protocol bridge (ported from WebInspectorUIProxyMac.mm platformInspectorPageLoadOverride):
                          // the WebKit 615 backend routes every command through the modern Target domain, but the
                          // Safari-8-era frontend emits bare per-domain commands ({method:'DOM.getDocument',id:N}).
                          // Wrap outgoing non-Target/Browser commands in Target.sendMessageToTarget once the target
                          // exists (queue until then), and unwrap incoming Target.dispatchMessageFromTarget. Without
                          // this the console never returns a result and the Resources/Elements trees stay empty.
                          "try{(function(){var origSend=IFH.sendMessageToBackend.bind(IFH);var currentTargetId=null;var pendingQueue=[];var wrapperIdBase=1000000;var wrapperIds=Object.create(null);"
                          "function wrap(ms){var wid=wrapperIdBase++;wrapperIds[wid]=true;return JSON.stringify({id:wid,method:'Target.sendMessageToTarget',params:{targetId:currentTargetId,message:ms}});}"
                          "function flushQueue(){if(!currentTargetId||!pendingQueue.length)return;var q=pendingQueue;pendingQueue=[];for(var i=0;i<q.length;i++){try{origSend(wrap(q[i]));}catch(e){}}}"
                          // Two CSS-protocol shapes drifted since this classic frontend (#52):
                          // (1) CSS.SelectorList.selectors are CSSSelector OBJECTS ({text, specificity});
                          // the frontend expects plain strings and renders the section headers by joining
                          // them — giving "[object Object], [object Object]" for every rule. Flatten each
                          // selector object to its .text. (2) the author stylesheet origin was renamed
                          // "regular" -> "author"; the frontend's origin switch leaves the rule type
                          // undefined for the unknown value and the Rules sidebar drops every author rule
                          // (only Style Attribute + User Agent Stylesheet entries survived). Map it back,
                          // gated to CSS payload shapes (selectorList/style/styleSheetId present).
                          "function fixSel(o){if(!o||typeof o!=='object')return;var sl=o.selectorList;if(sl&&sl.selectors instanceof Array&&sl.selectors.length&&typeof sl.selectors[0]==='object'){sl.selectors=sl.selectors.map(function(s){return s&&typeof s==='object'?String(s.text||''):s;});}if(o.origin==='author'&&(o.selectorList||o.style||o.styleSheetId))o.origin='regular';for(var k in o){var v=o[k];if(v&&typeof v==='object')fixSel(v);}}"
                          "IFH.sendMessageToBackend=function(messageStr){"
                          "try{var msg=JSON.parse(messageStr);var dom=msg.method&&msg.method.split('.')[0];"
                          "if(dom==='Target'||dom==='Browser')return origSend(messageStr);"
                          "if(!currentTargetId){pendingQueue.push(messageStr);return;}"
                          "return origSend(wrap(messageStr));"
                          "}catch(e){}return origSend(messageStr);};"
                          "var _backendObj=null;Object.defineProperty(window,'InspectorBackend',{configurable:true,enumerable:true,get:function(){return _backendObj;},set:function(v){_backendObj=v;if(v&&!v.__patched){v.__patched=true;var origDisp=v.dispatch.bind(v);v.dispatch=function(message){try{var obj=(typeof message==='string')?JSON.parse(message):message;if(obj.method==='Target.targetCreated'&&obj.params&&obj.params.targetInfo){currentTargetId=obj.params.targetInfo.targetId;flushQueue();return;}if(obj.id!==undefined&&wrapperIds[obj.id]){delete wrapperIds[obj.id];return;}if(obj.method==='Target.dispatchMessageFromTarget'&&obj.params&&obj.params.message){var im=obj.params.message;if(typeof im==='string'&&(im.indexOf('selectorList')!==-1||im.indexOf('\"origin\":\"author\"')!==-1)){try{var po=JSON.parse(im);fixSel(po);return origDisp(po);}catch(e2){}}return origDisp(im);}}catch(e){}return origDisp(message);};}}});"
                          "})();}catch(e){}"
                          // The 22px unified-titlebar strip (ported from the WK2 shim, #52; see the injected
                          // CSS above). The title text comes from the frontend's
                          // InspectorFrontendHost.inspectedURLChanged(host) — the same source the native
                          // (hidden) window title is formatted from.
                          "try{var wkTitle='Web Inspector';"
                          "document.addEventListener('DOMContentLoaded',function(){try{"
                          "if(document.getElementById('wk-titlebar'))return;"
                          "var bar=document.createElement('div');bar.id='wk-titlebar';bar.textContent=wkTitle;"
                          "document.body.insertBefore(bar,document.body.firstChild);"
                          "}catch(e){}});"
                          "if(typeof IFH.inspectedURLChanged==='function'){var origIUC=IFH.inspectedURLChanged.bind(IFH);Object.defineProperty(IFH,'inspectedURLChanged',{value:function(t){try{wkTitle='Web Inspector \\u2014 '+t;var b=document.getElementById('wk-titlebar');if(b)b.textContent=wkTitle;}catch(e){}return origIUC(t);},writable:true,configurable:true});}"
                          "}catch(e){}"
                          // Titlebar-strip + whole-toolbar window-drag handle (ported from the WK2 shim, #52):
                          // the frontend WebView covers the native titlebar in the undocked unified-toolbar
                          // window, so route background mousedowns (off interactive items, undocked only) to
                          // InspectorFrontendHost.startWindowDrag() — backed by the wk_ manual drag loop
                          // polyfill for -[NSWindow performWindowDragWithEvent:] on 10.9.
                          "try{document.addEventListener('mousedown',function(ev){"
                          "if(ev.button!==0||!ev.target||!ev.target.closest)return;"
                          "if(document.body&&document.body.classList.contains('docked'))return;"
                          "if(!ev.target.closest('#wk-titlebar, #toolbar, .toolbar'))return;"
                          "if(ev.target.closest('button,input,select,textarea,a,.item,.toolbar-item,.dashboard-container,.navigation-bar,.search-bar,[role=button]'))return;"
                          "if(IFH.startWindowDrag){IFH.startWindowDrag();ev.preventDefault();ev.stopPropagation();}"
                          "},true);}catch(e){}"
                          "})();</script>";
        html = [html stringByReplacingCharactersInRange:NSMakeRange(firstScript.location, 0) withString:[unifiedToolbarCSS stringByAppendingString:shim]];
    }
    return [html dataUsingEncoding:NSUTF8StringEncoding];
}

- (id)initWithInspectedWebView:(WebView *)webView isUnderTest:(BOOL)isUnderTest
{
    if (!(self = [self init]))
        return nil;

    _inspectedWebView = webView;

    NSString *pagePath = isUnderTest ? [self inspectorTestPagePath] : [self inspectorPagePath];
    // MAVERICKS_BACKPORT: never hand a nil path to +[NSURL fileURLWithPath:] — the uncaught
    // NSInvalidArgumentException kills the whole host app. With no frontend page on disk the
    // inspector window opens empty instead.
    if (!pagePath)
        return self;

    NSURL *pageURL = [NSURL fileURLWithPath:pagePath isDirectory:NO];
    if (NSData *transformed = wkTransformedClassicFrontendPage(pagePath)) {
        // The page file URL itself is the base: relative subresources resolve identically to a
        // regular load, and the frontend policy delegate (-webView:decidePolicyForNavigationAction:...)
        // path-matches the navigation URL against inspectorPagePath/inspectorTestPagePath — a
        // directory base would be refused there and kicked to the INSPECTED web view instead.
        [[_frontendWebView mainFrame] loadData:transformed MIMEType:@"text/html" textEncodingName:@"UTF-8" baseURL:pageURL];
        return self;
    }

    auto request = adoptNS([[NSURLRequest alloc] initWithURL:pageURL]);
    [[_frontendWebView mainFrame] loadRequest:request.get()];

    return self;
}

// MARK: -

- (NSString *)inspectorPagePath
{
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"];
    if (!bundle)
        return nil;

    return [bundle pathForResource:@"Main" ofType:@"html"];
}

- (NSString *)inspectorTestPagePath
{
    // MAVERICKS_BACKPORT: under DumpRenderTree nothing loads WebInspectorUI.framework and the
    // stock PrivateFrameworks bundle ships no Test.html — probe the build tree's staged modern
    // frontend relative to the test-driver binary before the loaded-bundle lookup.
    NSString *executableDirectory = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *builtTestPage = [[executableDirectory stringByAppendingPathComponent:@"../WebInspectorUI/DerivedSources/InspectorResources/WebInspectorUI/Test.html"] stringByStandardizingPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:builtTestPage])
        return builtTestPage;

    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"com.apple.WebInspectorUI"];
    if (!bundle)
        return nil;

    // We might not have a Test.html in Production builds.
    return [bundle pathForResource:@"Test" ofType:@"html"];
}

// MARK: -

- (WebView *)frontendWebView
{
    return _frontendWebView.get();
}

- (NSWindow *)window
{
    if (auto *window = [super window])
        return window;

    // MAVERICKS_BACKPORT: NSWindowStyleMaskFullSizeContentView + -setTitlebarAppearsTransparent:
    // (below) are the 10.10+ "content fills the titlebar region" combo. On 10.9 the style bit is
    // inert but -setTitlebarAppearsTransparent: is an unrecognized selector that kills the host app,
    // so both are dropped here; the full-size-content-view appearance is instead emulated by the
    // undocked branch of -showWindow:, which hosts the frontend WebView in the window's frame view
    // sized to the full window (the HTML #toolbar fills the titlebar region).
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    if ([NSWindow instancesRespondToSelector:@selector(setTitlebarAppearsTransparent:)])
        styleMask |= NSWindowStyleMaskFullSizeContentView;
    auto window = adoptNS([[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, initialWindowWidth, initialWindowHeight) styleMask:styleMask backing:NSBackingStoreBuffered defer:NO]);
    [window setDelegate:self];
    [window setMinSize:NSMakeSize(minimumWindowWidth, minimumWindowHeight)];
    [window setCollectionBehavior:([window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary)];

    CGFloat approximatelyHalfScreenSize = ([window screen].frame.size.width / 2) - 4;
    CGFloat minimumFullScreenWidth = std::max<CGFloat>(636, approximatelyHalfScreenSize);
    // MAVERICKS_BACKPORT: -[NSWindow setMinFullScreenContentSize:] and the
    // NSWindowCollectionBehaviorFullScreenAllowsTiling / ...Auxiliary tiling behaviors are 10.11+ and
    // absent on 10.9, so the inspector window skips them; minimumFullScreenWidth is voided to avoid an
    // unused-variable warning.
    (void)minimumFullScreenWidth;

    // MAVERICKS_BACKPORT: -setTitlebarAppearsTransparent: is 10.10+; guard it (see styleMask above).
    if ([window respondsToSelector:@selector(setTitlebarAppearsTransparent:)])
        [window setTitlebarAppearsTransparent:YES];

    [self setWindow:window.get()];
    return window.unsafeGet();
}

// MARK: -

- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect
{
    if (_frontendClient)
        return NSMakeRect(0, _frontendClient->sheetRect().height(), _frontendClient->sheetRect().width(), 0);

    // AppKit doesn't know about our HTML toolbar, and places the sheet just a little bit too high.
    rect.origin.y -= 1;
    return rect;
}

- (BOOL)windowShouldClose:(id)sender
{
    [self destroyInspectorView];

    return YES;
}

// MAVERICKS_BACKPORT (#52): the undocked frontend WebView is hosted in the window's frame view
// (NSThemeFrame) for the unified toolbar, and 10.9's NSThemeFrame does its own layout and does
// not honor the autoresizing mask on a manually-added subview — the same reason
// WebInspectorUIProxy::inspectedViewFrameDidChange resizes the WK2 inspector webView explicitly.
// Track window resizes by hand; the classic WebView reflows itself from setFrame:.
- (void)windowDidResize:(NSNotification *)notification
{
    if (_attachedToInspectedWebView || !_visible)
        return;
    NSView *contentView = [[self window] contentView];
    NSView *frameView = [contentView superview] ?: contentView;
    if ([_frontendWebView superview] == frameView)
        [_frontendWebView setFrame:[frameView bounds]];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    _inspectorClient->windowFullScreenDidChange();
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    _inspectorClient->windowFullScreenDidChange();
}

- (void)close
{
    if (!_visible)
        return;

    _visible = NO;

    if (_attachedToInspectedWebView) {
        if ([_inspectedWebView.get() _isClosed])
            return;

        [_frontendWebView removeFromSuperview];

        WebFrameView *frameView = [[_inspectedWebView.get() mainFrame] frameView];
        NSRect frameViewRect = [frameView frame];

        // Setting the height based on the previous height is done to work with
        // Safari's find banner. This assumes the previous height is the Y origin.
        frameViewRect.size.height += NSMinY(frameViewRect);
        frameViewRect.origin.y = 0.0;

        [frameView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        [frameView setFrame:frameViewRect];

        [_inspectedWebView.get() displayIfNeeded];
    } else
        [super close];
}

- (IBAction)attachWindow:(id)sender
{
    _frontendClient->attachWindow(InspectorFrontendClient::DockSide::Bottom);
}

- (IBAction)showWindow:(id)sender
{
    if (_visible) {
        if (!_attachedToInspectedWebView)
            [super showWindow:sender]; // call super so the window will be ordered front if needed
        return;
    }

    _visible = YES;

    _shouldAttach = _inspectorClient->inspectorStartsAttached() && _frontendClient->canAttach();

    if (_shouldAttach) {
        WebFrameView *frameView = [[_inspectedWebView.get() mainFrame] frameView];

        [_frontendWebView removeFromSuperview];
        [_inspectedWebView.get() addSubview:_frontendWebView.get() positioned:NSWindowBelow relativeTo:(NSView *)frameView];
        [[_inspectedWebView.get() window] makeFirstResponder:_frontendWebView.get()];

        [_frontendWebView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable | NSViewMaxYMargin)];
        [frameView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin)];

        // MAVERICKS_BACKPORT (#52): docked, the frontend WebView sits inside the inspected
        // WebView and must paint its own background again (the undocked branch makes it
        // transparent for the rounded window corners).
        [_frontendWebView setDrawsBackground:YES];

        _attachedToInspectedWebView = YES;
    } else {
        _attachedToInspectedWebView = NO;

        // MAVERICKS_BACKPORT (#52, unified inspector toolbar): NSWindowStyleMaskFullSizeContentView +
        // -setTitlebarAppearsTransparent: are 10.10+ (see -window), so on 10.9 the frontend WebView
        // is hosted directly in the window's FRAME VIEW (the content view's superview / NSThemeFrame)
        // sized to the FULL window — the HTML #toolbar fills the titlebar region and merges with it,
        // and the standard window buttons are then raised above it so the traffic lights float over
        // the toolbar. Mirror of WebInspectorUIProxy::platformCreateFrontendWindow (WK2); the toolbar
        // gradient/inset comes from the CSS wkTransformedClassicFrontendPage injects.
        NSView *contentView = [[self window] contentView];
        NSView *frameView = [contentView superview] ?: contentView;
        [_frontendWebView setFrame:[frameView bounds]];
        [_frontendWebView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        // MAVERICKS_BACKPORT (#52): transparent WebView so the injected CSS's rounded top corners
        // reveal the NSThemeFrame's own rounded titlebar corners (the page content itself stays
        // opaque — body paints the unified gradient, #main is white).
        [_frontendWebView setDrawsBackground:NO];
        [_frontendWebView removeFromSuperview];
        [frameView addSubview:_frontendWebView.get() positioned:NSWindowAbove relativeTo:contentView];

        for (NSInteger buttonType = NSWindowCloseButton; buttonType <= NSWindowZoomButton; ++buttonType) {
            if (NSButton *windowButton = [[self window] standardWindowButton:(NSWindowButton)buttonType])
                [[windowButton superview] addSubview:windowButton positioned:NSWindowAbove relativeTo:nil];
        }

        [super showWindow:nil];
    }
}

// MARK: -

- (void)attach
{
    if (_attachedToInspectedWebView)
        return;

    _inspectorClient->setInspectorStartsAttached(true);
    _frontendClient->setAttachedWindow(InspectorFrontendClient::DockSide::Bottom);

    [self close];
    [self showWindow:nil];
}

- (void)detach
{
    if (!_attachedToInspectedWebView)
        return;

    _inspectorClient->setInspectorStartsAttached(false);
    _frontendClient->setAttachedWindow(InspectorFrontendClient::DockSide::Undocked);

    [self close];
    [self showWindow:nil];
}

- (BOOL)attached
{
    return _attachedToInspectedWebView;
}

- (void)setFrontendClient:(NakedPtr<WebInspectorFrontendClient>)frontendClient
{
    _frontendClient = frontendClient;
}

- (void)setInspectorClient:(NakedPtr<WebInspectorClient>)inspectorClient
{
    _inspectorClient = inspectorClient;
}

- (NakedPtr<WebInspectorClient>)inspectorClient
{
    return _inspectorClient;
}

- (void)setAttachedWindowHeight:(unsigned)height
{
    if (!_attachedToInspectedWebView)
        return;

    WebFrameView *frameView = [[_inspectedWebView.get() mainFrame] frameView];
    NSRect frameViewRect = [frameView frame];

    // Setting the height based on the difference is done to work with
    // Safari's find banner. This assumes the previous height is the Y origin.
    CGFloat heightDifference = (NSMinY(frameViewRect) - height);
    frameViewRect.size.height += heightDifference;
    frameViewRect.origin.y = height;

    [_frontendWebView setFrame:NSMakeRect(0.0, 0.0, NSWidth(frameViewRect), height)];
    [frameView setFrame:frameViewRect];
}

- (void)setDockingUnavailable:(BOOL)unavailable
{
    // Do nothing.
}

- (void)destroyInspectorView
{
    RetainPtr<WebInspectorWindowController> protect(self);

    if (Page* frontendPage = _frontendClient->frontendPage())
        frontendPage->inspectorController().setInspectorFrontendClient(nullptr);
    RefPtr { [_inspectedWebView.get() inspectorController] }->disconnectFrontend(*_inspectorClient);

    [[_inspectedWebView.get() inspector] releaseFrontend];
    _inspectorClient->releaseFrontend();

    if (_destroyingInspectorView)
        return;
    _destroyingInspectorView = YES;

    [self close];

    _visible = NO;

    [_frontendWebView close];
}

// MARK: -
// MARK: UI delegate

- (void)webView:(WebView *)sender runOpenPanelForFileButtonWithResultListener:(id<WebOpenPanelResultListener>)resultListener allowMultipleFiles:(BOOL)allowMultipleFiles
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = allowMultipleFiles;

    auto completionHandler = ^(NSInteger result) {
        if (result == NSModalResponseCancel) {
            [resultListener cancel];
            return;
        }
        ASSERT(result == NSModalResponseOK);

        NSArray *URLs = panel.URLs;
        NSMutableArray *filenames = [NSMutableArray arrayWithCapacity:URLs.count];
        for (NSURL *URL in URLs)
            [filenames addObject:URL.path];

        [resultListener chooseFilenames:filenames];
    };

    if ([_frontendWebView window])
        [panel beginSheetModalForWindow:[_frontendWebView window] completionHandler:completionHandler];
    else
        completionHandler([panel runModal]);
}

- (void)webView:(WebView *)sender frame:(WebFrame *)frame exceededDatabaseQuotaForSecurityOrigin:(WebSecurityOrigin *)origin database:(NSString *)databaseIdentifier
{
    id <WebQuotaManager> databaseQuotaManager = origin.databaseQuotaManager;
    databaseQuotaManager.quota = std::max<unsigned long long>(5 * 1024 * 1024, databaseQuotaManager.usage * 1.25);
}

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems
{
    auto menuItems = adoptNS([[NSMutableArray alloc] init]);

    for (NSMenuItem *item in defaultMenuItems) {
        switch (item.tag) {
        case WebMenuItemTagOpenLinkInNewWindow:
        case WebMenuItemTagOpenImageInNewWindow:
        case WebMenuItemTagOpenFrameInNewWindow:
        case WebMenuItemTagOpenMediaInNewWindow:
        case WebMenuItemTagDownloadLinkToDisk:
        case WebMenuItemTagDownloadImageToDisk:
            break;
        default:
            [menuItems addObject:item];
            break;
        }
    }

    return menuItems.autorelease();
}

// MARK: -
// MARK: Policy delegate

- (void)webView:(WebView *)webView decidePolicyForNavigationAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener
{
    // Allow non-main frames to navigate anywhere.
    if (frame != [webView mainFrame]) {
        [listener use];
        return;
    }

    // Allow loading of the main inspector file.
    if ([[request URL] isFileURL] && [[[request URL] path] isEqualToString:[self inspectorPagePath]]) {
        [listener use];
        return;
    }

    // Allow loading of the test inspector file.
    NSString *testPagePath = [self inspectorTestPagePath];
    if (testPagePath && [[request URL] isFileURL] && [[[request URL] path] isEqualToString:testPagePath]) {
        [listener use];
        return;
    }

    // Prevent everything else from loading in the inspector's page.
    [listener ignore];

    // And instead load it in the inspected page.
    [[_inspectedWebView.get() mainFrame] loadRequest:request];
}

// MARK: -
// These methods can be used by UI elements such as menu items and toolbar buttons when the inspector is the key window.

// This method is really only implemented to keep any UI elements enabled.
- (void)showWebInspector:(id)sender
{
    [[_inspectedWebView.get() inspector] show:sender];
}

- (void)showErrorConsole:(id)sender
{
    [[_inspectedWebView.get() inspector] showConsole:sender];
}

- (void)toggleDebuggingJavaScript:(id)sender
{
    [[_inspectedWebView.get() inspector] toggleDebuggingJavaScript:sender];
}

- (void)toggleProfilingJavaScript:(id)sender
{
    [[_inspectedWebView.get() inspector] toggleProfilingJavaScript:sender];
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item
{
    BOOL isMenuItem = [(id)item isKindOfClass:[NSMenuItem class]];
    if ([item action] == @selector(toggleDebuggingJavaScript:) && isMenuItem) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        if ([[_inspectedWebView.get() inspector] isDebuggingJavaScript])
            [menuItem setTitle:UI_STRING_INTERNAL("Stop Debugging JavaScript", "title for Stop Debugging JavaScript menu item")];
        else
            [menuItem setTitle:UI_STRING_INTERNAL("Start Debugging JavaScript", "title for Start Debugging JavaScript menu item")];
    } else if ([item action] == @selector(toggleProfilingJavaScript:) && isMenuItem) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        if ([[_inspectedWebView.get() inspector] isProfilingJavaScript])
            [menuItem setTitle:UI_STRING_INTERNAL("Stop Profiling JavaScript", "title for Stop Profiling JavaScript menu item")];
        else
            [menuItem setTitle:UI_STRING_INTERNAL("Start Profiling JavaScript", "title for Start Profiling JavaScript menu item")];
    }

    return YES;
}

@end
