/*
 * Copyright (C) 2017-2024 Apple Inc. All rights reserved.
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

#import "config.h"
#import "WKInspectorViewController.h"

#if PLATFORM(MAC)

#import "APINavigation.h"
#import "AppKitSPI.h"
#import "WKContextMenuItemTypes.h"
#import "WKInspectorResourceURLSchemeHandler.h"
#import "WKInspectorWKWebView.h"
#import "WKOpenPanelParameters.h"
#import "WKProcessPoolInternal.h"
#import "WKWebViewInternal.h"
// MAVERICKS_BACKPORT: for _pageConfiguration access used by the shared-process-pool divergence below.
#import "WKWebViewConfigurationInternal.h"
#import "WKWebsiteDataStoreInternal.h"
#import "WebInspectorUIProxy.h"
#import "WebInspectorUtilities.h"
#import "WebPageProxy.h"
// MAVERICKS_BACKPORT: for the _pageConfiguration->setDelaysWebProcessLaunchUntilFirstLoad shared-process-pool divergence below.
#import "APIPageConfiguration.h"
#import "WebsiteDataStore.h"
#import "_WKInspectorConfigurationInternal.h"
#import <WebKit/WKFrameInfo.h>
#import <WebKit/WKNavigationAction.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKUIDelegatePrivate.h>
// MAVERICKS_BACKPORT: for the classic-frontend bridge user script (see _mavericksClassicFrontendBridgeScript).
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKUserScript.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

#if ENABLE(WK_WEB_EXTENSIONS) && ENABLE(INSPECTOR_EXTENSIONS)
#import "WKWebExtensionController.h"
#import "WebExtensionController.h"
#endif

static NSString * const WKInspectorResourceScheme = @"inspector-resource";

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// static NSString * const safeAreaInsetsKVOKey = @"safeAreaInsets";
// static void* const safeAreaInsetsKVOContext = (void*)&safeAreaInsetsKVOContext;
//
// (end MAVERICKS_BACKPORT restored block)
@interface WKInspectorViewController () <WKUIDelegate, WKNavigationDelegate, WKInspectorWKWebViewDelegate>
// MAVERICKS_BACKPORT: classic-frontend bridge user script (see the definition below).
+ (NSString *)_mavericksClassicFrontendBridgeScript;
@end

@implementation WKInspectorViewController {
    WeakPtr<WebKit::WebPageProxy> _inspectedPage;
    RetainPtr<WKInspectorWKWebView> _webView;
    WeakObjCPtr<id <WKInspectorViewControllerDelegate>> _delegate;
    RetainPtr<_WKInspectorConfiguration> _configuration;
}

- (instancetype)initWithConfiguration:(_WKInspectorConfiguration *)configuration inspectedPage:(NakedPtr<WebKit::WebPageProxy>)inspectedPage
{
    if (!(self = [super init]))
        return nil;

    _configuration = adoptNS([configuration copy]);

    // The (local) inspected page is nil if the controller is hosting a Remote Web Inspector view.
    _inspectedPage = inspectedPage.get();

    return self;
}

- (void)dealloc
{
    if (_webView) {
        [_webView setUIDelegate:nil];
        [_webView setNavigationDelegate:nil];
        [_webView setInspectorWKWebViewDelegate:nil];
        _webView = nil;
    }

    [super dealloc];
}

- (id <WKInspectorViewControllerDelegate>)delegate
{
    return _delegate.getAutoreleased();
}

- (WKWebView *)webView
{
    // Construct lazily so the client can set the delegate before the WebView is created.
    if (!_webView) {
        NSRect initialFrame = NSMakeRect(0, 0, WebKit::WebInspectorUIProxy::initialWindowWidth, WebKit::WebInspectorUIProxy::initialWindowHeight);
        _webView = adoptNS([[WKInspectorWKWebView alloc] initWithFrame:initialFrame configuration:self.webViewConfiguration]);
        [_webView setInspectable:YES];
        [_webView setUIDelegate:self];
        [_webView setNavigationDelegate:self];
        [_webView setInspectorWKWebViewDelegate:self];
        // MAVERICKS_BACKPORT: guard 10.10+ private accessors that WKWebView doesn't implement.
        if ([_webView respondsToSelector:@selector(_setAutomaticallyAdjustsContentInsets:)])
            [_webView _setAutomaticallyAdjustsContentInsets:NO];
        if ([_webView respondsToSelector:@selector(_setUseSystemAppearance:)])
            [_webView _setUseSystemAppearance:YES];
        [_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // MAVERICKS_BACKPORT: guard 10.10+ _setObscuredContentInsets: that WKWebView doesn't implement (no safeAreaInsets on 10.9).
        if ([_webView respondsToSelector:@selector(_setObscuredContentInsets:immediate:)])
            [_webView _setObscuredContentInsets:NSEdgeInsetsMake(0, 0, 0, 0) immediate:NO];
    }

    return _webView.get();
}

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void*)context
{
    if (context == safeAreaInsetsKVOContext)
        [_webView _setObscuredContentInsets:_webView.get().safeAreaInsets immediate:NO];
    else
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

MAVERICKS_BACKPORT */
- (void)setDelegate:(id <WKInspectorViewControllerDelegate>)delegate
{
    _delegate = delegate;
}

- (WKWebViewConfiguration *)webViewConfiguration
{
    RetainPtr<WKWebViewConfiguration> configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    // MAVERICKS_BACKPORT: ensure processPool is set (WKWebView _initializeWithConfiguration crashes if not).
    // Reuse the inspected page's process pool so the inspector shares a WebContent process
    // (CreateWebPage IPC won't deliver into a Launching XPC process on 10.9).
    // MAVERICKS_BACKPORT: share the inspectedPage's process pool so the inspector page actually
    // creates a WebPage in WebContent (a fresh pool tries to launch a 2nd XPC service which
    // never moves out of Launching state on 10.9). Combined with the WebProcessPool.cpp
    // MAVERICKS_BACKPORT that reuses existing Running process when freshly-picked is Launching,
    // this gets the inspector WebPage created and HTML loaded inside the shared WebContent.
    if (RefPtr inspectedPage = _inspectedPage.get()) {
        WebKit::WebProcessPool& pool = inspectedPage->configuration().processPool();
        [configuration setProcessPool:protect(WebKit::wrapper(pool)).get()];
    } else if (![configuration processPool])
        [configuration setProcessPool:adoptNS([[WKProcessPool alloc] init]).get()];
    configuration.get()->_pageConfiguration->setDelaysWebProcessLaunchUntilFirstLoad(true);
    // MAVERICKS_BACKPORT (#52): the frontend page draws no background, so the injected unified-
    // toolbar CSS's rounded top corners are genuinely transparent and the NSThemeFrame's own
    // rounded titlebar corners show through — the web view covers the whole window (frame-view
    // hosting in WebInspectorUIProxy::platformCreateFrontendWindow) and would otherwise paint
    // square corners over them. The page content stays opaque (body paints the gradient, #main
    // is white). Must be set at configuration time: the page reads drawsBackground once at init.
    configuration.get()->_pageConfiguration->setDrawsBackground(false);
    RetainPtr<WKInspectorResourceURLSchemeHandler> inspectorSchemeHandler = adoptNS([WKInspectorResourceURLSchemeHandler new]);
    RetainPtr<NSMutableSet<NSString *>> allowedURLSchemes = adoptNS([[NSMutableSet alloc] initWithObjects:WKInspectorResourceScheme, nil]);
    for (auto& pair : _configuration->_configuration->urlSchemeHandlers())
        [allowedURLSchemes addObject:pair.second.createNSString().get()];

    [inspectorSchemeHandler setAllowedURLSchemesForCSP:allowedURLSchemes.get()];
    [configuration setURLSchemeHandler:inspectorSchemeHandler.get() forURLScheme:WKInspectorResourceScheme];

    // MAVERICKS_BACKPORT: this backport deliberately ships the system stock (Safari 8-era)
    // WebInspectorUI frontend — its Aqua toolbar and pill tab icons are the native Mavericks
    // look — served through the upstream inspector-resource:// scheme handler from the
    // com.apple.WebInspectorUI bundle. The classic frontend predates today's
    // InspectorFrontendHost IDL and protocol, so a document-start user script bridges the
    // drift in-page (method-vs-attribute IFH accessors, Target-routed protocol, two CSS
    // payload shape changes) and builds the #52/#66/#69 unified titlebar+toolbar. The page
    // CSP does not apply to native-injected user scripts, and InspectorFrontendHost is
    // installed at window-object-clear, before document-start user scripts run.
    [[configuration userContentController] addUserScript:adoptNS([[WKUserScript alloc]
        initWithSource:[WKInspectorViewController _mavericksClassicFrontendBridgeScript]
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]).get()];

    RefPtr inspectedPage = _inspectedPage.get();
#if ENABLE(WK_WEB_EXTENSIONS) && ENABLE(INSPECTOR_EXTENSIONS)
    if (inspectedPage) {
        if (RefPtr webExtensionController = inspectedPage->webExtensionController())
            configuration.get().webExtensionController = protect(webExtensionController->wrapper()).get();
    }
#endif

    RetainPtr<WKPreferences> preferences = configuration.get().preferences;
    preferences.get()._allowFileAccessFromFileURLs = YES;
    [configuration _setAllowUniversalAccessFromFileURLs:YES];
    [configuration _setAllowTopNavigationToDataURLs:YES];
    preferences.get()._storageBlockingPolicy = _WKStorageBlockingPolicyAllowAll;
    preferences.get()._javaScriptRuntimeFlags = 0;

#ifndef NDEBUG
    // Allow developers to inspect the Web Inspector in debug builds without changing settings.
    preferences.get()._developerExtrasEnabled = YES;
    preferences.get()._logsPageMessagesToSystemConsoleEnabled = YES;
#endif

    preferences.get()._diagnosticLoggingEnabled = YES;

    // Disable Site Isolation for Web Inspector View.
    preferences.get()._siteIsolationEnabled = NO;

    [_configuration applyToWebViewConfiguration:configuration.get()];

    RetainPtr delegate = _delegate.get();
    if (!!delegate && [delegate respondsToSelector:@selector(inspectorViewControllerInspectorIsUnderTest:)]) {
        if ([delegate inspectorViewControllerInspectorIsUnderTest:self]) {
            preferences.get()._hiddenPageDOMTimerThrottlingEnabled = NO;
            preferences.get()._pageVisibilityBasedProcessSuppressionEnabled = NO;
            preferences.get().inactiveSchedulingPolicy = WKInactiveSchedulingPolicyNone;
        }
    }

    // WKInspectorConfiguration allows the client to specify a process pool to use.
    // If not specified or the inspection level is >1, use the default strategy.
    // This ensures that Inspector^2 cannot be affected by client (mis)configuration.
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    RetainPtr<WKProcessPool> customProcessPool = configuration.get().processPool;
    ALLOW_DEPRECATED_DECLARATIONS_END
    auto inspectorLevel = WebKit::inspectorLevelForPage(inspectedPage.get());
    auto useDefaultProcessPool = inspectorLevel > 1 || !customProcessPool;
    if (customProcessPool && !useDefaultProcessPool)
        WebKit::prepareProcessPoolForInspector(Ref { *customProcessPool->_processPool.get() });

    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (useDefaultProcessPool)
        [configuration setProcessPool:wrapper(protect(WebKit::defaultInspectorProcessPool(inspectorLevel))).get()];
    ALLOW_DEPRECATED_DECLARATIONS_END

    // Ensure that a page group identifier is set. This is for computing inspection levels.
    if (!configuration.get()._groupIdentifier)
        [configuration _setGroupIdentifier:WebKit::defaultInspectorPageGroupIdentifierForPage(inspectedPage.get()).createNSString().get()];

    // Prefer using a custom persistent data store if one exists.
    RetainPtr<WKWebsiteDataStore> targetDataStore;
    WebKit::WebsiteDataStore::forEachWebsiteDataStore([&targetDataStore](WebKit::WebsiteDataStore& dataStore) {
        if (dataStore.sessionID() != PAL::SessionID::defaultSessionID() && dataStore.resolvedDirectories().resourceLoadStatisticsDirectory == WebKit::WebsiteDataStore::defaultResourceLoadStatisticsDirectory()) {
            ASSERT(!targetDataStore);
            targetDataStore = WebKit::wrapper(dataStore);
        }
    });
    if (targetDataStore)
        [configuration setWebsiteDataStore:targetDataStore.get()];

    return configuration.autorelease();
}

+ (BOOL)viewIsInspectorWebView:(NSView *)view
{
    return [view isKindOfClass:[WKInspectorWKWebView class]];
}

+ (NSURL *)URLForInspectorResource:(NSString *)resource
{
    // MAVERICKS_BACKPORT: cast to NSURL* so -URLByStandardizingPath resolves on 10.9 (NSString id-return ambiguity).
    return [(NSURL *)[NSURL URLWithString:adoptNS([[NSString alloc] initWithFormat:@"%@:///%@", WKInspectorResourceScheme, resource]).get()] URLByStandardizingPath];
}

// MAVERICKS_BACKPORT: document-start bridge for the stock classic (Safari 8-era) WebInspectorUI
// frontend against the modern backend. Injected as a WKUserScript from webViewConfiguration.
// Three parts:
//  1. InspectorFrontendHost drift: the classic frontend calls platform()/localizedStringsURL()/
//     inspectorBackendCommandsURL() as METHODS and uses a few IFH methods the modern host no
//     longer ships; the modern IDL exposes attribute getters. Wrap the attributes as methods
//     and stub the removed ones.
//  2. Protocol bridge: the classic frontend sends bare per-domain commands
//     ({method:'Inspector.enable',id:N}); the modern backend routes per-target via
//     Target.sendMessageToTarget and answers with Target.dispatchMessageFromTarget. Wrap
//     outgoing non-Target/Browser commands (queueing until Target.targetCreated supplies the
//     targetId) and unwrap incoming target-routed messages. Two CSS payload shapes drifted
//     since the classic frontend (#52): CSS.SelectorList.selectors became CSSSelector OBJECTS
//     ({text,specificity}) where the frontend expects strings (section headers render as
//     "[object Object]" otherwise), and the author stylesheet origin was renamed
//     "regular" -> "author" (the frontend's origin switch drops every author rule for the
//     unknown value). fixSel() flattens selectors to .text and maps the origin back, gated to
//     CSS payload shapes (selectorList/style/styleSheetId present).
//  3. #52/#66/#69 unified titlebar+toolbar: a 22px #wk-titlebar strip as body's first flex
//     child (the stock 56px toolbar stays byte-untouched below it; its fixed border-box height
//     means padding would squish the icons), ONE continuous measured Aqua gradient painted on
//     body spanning strip+toolbar (78px), the centered window title fed from
//     InspectorFrontendHost.inspectedURLChanged, and background mousedowns on the strip/toolbar
//     routed to IFH.startWindowDrag() (undocked only — a docked drag would move the browser
//     window). Gradient endpoints were measured off a native Mavericks unified titlebar
//     (Finder, lossless screen samples, frontmost-verified): ACTIVE = 1px rgb(242) bevel,
//     rgb(234)->rgb(176), 1px rgb(105) border; INACTIVE = rgb(240)->rgb(223), 1px rgb(166).
+ (NSString *)_mavericksClassicFrontendBridgeScript
{
    NSString *unifiedToolbarCSS =
        @"body:not(.docked){background-image:-webkit-linear-gradient(top,rgb(242,242,242),rgb(234,234,234) 1px,rgb(176,176,176) 77px,rgb(105,105,105) 77px,rgb(105,105,105) 78px);background-repeat:no-repeat;background-size:100% 78px;border-top-left-radius:4px;border-top-right-radius:4px;}"
        @"body:not(.docked).window-inactive{background-image:-webkit-linear-gradient(top,rgb(240,240,240),rgb(223,223,223) 77px,rgb(166,166,166) 77px,rgb(166,166,166) 78px);}"
        @"body.docked{background-color:white;}"
        @"#wk-titlebar{height:22px;-webkit-flex:none;text-align:center;font-family:'Lucida Grande';font-size:13px;line-height:22px;color:rgba(0,0,0,0.85);text-shadow:rgba(255,255,255,0.5) 0 1px 0;padding:0 80px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;cursor:default;}"
        @"body.window-inactive #wk-titlebar{color:rgba(0,0,0,0.5);}"
        @"body.docked #wk-titlebar{display:none;}";

    NSString *script = [NSString stringWithFormat:@"(function(){"
        // Install the unified-toolbar CSS as a <style> node (the classic Main.html is served
        // byte-untouched, so the stylesheet has to arrive from here).
        "var wkCSS=\"%@\";" // the CSS below contains no double quotes or backslashes, so it embeds directly as a JS string literal
        "function wkAddStyle(){if(document.getElementById('wk-unified-style'))return;var st=document.createElement('style');st.id='wk-unified-style';st.textContent=wkCSS;(document.head||document.documentElement).appendChild(st);}"
        "if(document.documentElement)wkAddStyle();else document.addEventListener('DOMContentLoaded',wkAddStyle);"
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
        "(function(){var origSend=IFH.sendMessageToBackend.bind(IFH);var currentTargetId=null;var pendingQueue=[];var wrapperIdBase=1000000;var wrapperIds=Object.create(null);"
        "function wrap(ms){var wid=wrapperIdBase++;wrapperIds[wid]=true;return JSON.stringify({id:wid,method:'Target.sendMessageToTarget',params:{targetId:currentTargetId,message:ms}});}"
        "function flushQueue(){if(!currentTargetId||!pendingQueue.length)return;var q=pendingQueue;pendingQueue=[];for(var i=0;i<q.length;i++)origSend(wrap(q[i]));}"
        "function fixSel(o){if(!o||typeof o!=='object')return;var sl=o.selectorList;if(sl&&sl.selectors instanceof Array&&sl.selectors.length&&typeof sl.selectors[0]==='object'){sl.selectors=sl.selectors.map(function(s){return s&&typeof s==='object'?String(s.text||''):s;});}if(o.origin==='author'&&(o.selectorList||o.style||o.styleSheetId))o.origin='regular';for(var k in o){var v=o[k];if(v&&typeof v==='object')fixSel(v);}}"
        "IFH.sendMessageToBackend=function(messageStr){"
        "try{var msg=JSON.parse(messageStr);var dom=msg.method&&msg.method.split('.')[0];"
        "if(dom==='Target'||dom==='Browser')return origSend(messageStr);"
        "if(!currentTargetId){pendingQueue.push(messageStr);return;}"
        "return origSend(wrap(messageStr));"
        "}catch(e){}return origSend(messageStr);};"
        "var _backendObj=null;Object.defineProperty(window,'InspectorBackend',{configurable:true,enumerable:true,get:function(){return _backendObj;},set:function(v){_backendObj=v;if(v&&!v.__patched){v.__patched=true;var origDisp=v.dispatch.bind(v);v.dispatch=function(message){try{var obj=(typeof message==='string')?JSON.parse(message):message;if(obj.method==='Target.targetCreated'&&obj.params&&obj.params.targetInfo){currentTargetId=obj.params.targetInfo.targetId;flushQueue();return;}if(obj.id!==undefined&&wrapperIds[obj.id]){delete wrapperIds[obj.id];return;}if(obj.method==='Target.dispatchMessageFromTarget'&&obj.params&&obj.params.message){var im=obj.params.message;if(typeof im==='string'&&(im.indexOf('selectorList')!==-1||im.indexOf('\"origin\":\"author\"')!==-1)){try{var po=JSON.parse(im);fixSel(po);return origDisp(po);}catch(e2){}}return origDisp(im);}}catch(e){}return origDisp(message);};}}});"
        "})();"
        "try{var wkTitle='Web Inspector';"
        "document.addEventListener('DOMContentLoaded',function(){try{"
        "if(document.getElementById('wk-titlebar'))return;"
        "var bar=document.createElement('div');bar.id='wk-titlebar';bar.textContent=wkTitle;"
        "document.body.insertBefore(bar,document.body.firstChild);"
        "}catch(e){}});"
        "if(typeof IFH.inspectedURLChanged==='function'){var origIUC=IFH.inspectedURLChanged.bind(IFH);Object.defineProperty(IFH,'inspectedURLChanged',{value:function(t){try{wkTitle='Web Inspector \\u2014 '+t;var b=document.getElementById('wk-titlebar');if(b)b.textContent=wkTitle;}catch(e){}return origIUC(t);},writable:true,configurable:true});}"
        "}catch(e){}"
        "try{document.addEventListener('mousedown',function(ev){"
        "if(ev.button!==0||!ev.target||!ev.target.closest)return;"
        "if(document.body&&document.body.classList.contains('docked'))return;"
        "if(!ev.target.closest('#wk-titlebar, #toolbar, .toolbar'))return;"
        "if(ev.target.closest('button,input,select,textarea,a,.item,.toolbar-item,.dashboard-container,.navigation-bar,.search-bar,[role=button]'))return;"
        "if(IFH.startWindowDrag){IFH.startWindowDrag();ev.preventDefault();ev.stopPropagation();}"
        "},true);}catch(e){}"
        "})();", unifiedToolbarCSS];
    return script;
}

- (void)didAttachOrDetach
{
#if ENABLE(CONTENT_INSET_BACKGROUND_FILL)
    RetainPtr attachedView = [self _horizontallyAttachedInspectedWebView];
    [_webView _setOverrideTopScrollEdgeEffectColor:[attachedView _topScrollPocket].captureColor];

    if (attachedView)
        [_webView _addReasonToPreferSolidColorHardPocket:WebKit::PreferSolidColorHardPocketReason::AttachedInspector];
    else
        [_webView _removeReasonToPreferSolidColorHardPocket:WebKit::PreferSolidColorHardPocketReason::AttachedInspector];

    [_webView _setOverflowHeightForTopScrollEdgeEffect:[attachedView _overflowHeightForTopScrollEdgeEffect]];
    [_webView _updateHiddenScrollPocketEdges];
#endif // ENABLE(CONTENT_INSET_BACKGROUND_FILL)
}

- (WKWebView *)_horizontallyAttachedInspectedWebView
{
    if (![_delegate.get() inspectorViewControllerInspectorIsHorizontallyAttached:self])
        return nil;

    if (RefPtr inspectedPage = _inspectedPage.get())
        return inspectedPage->cocoaView().autorelease();

    return nil;
}

// MARK: WKUIDelegate methods

- (void)_webView:(WKWebView *)webView getWindowFrameWithCompletionHandler:(void (^)(CGRect))completionHandler
{
    if (!_webView.get().window)
        completionHandler(CGRectZero);
    else
        completionHandler(NSRectToCGRect([webView frame]));
}

- (void)_webView:(WKWebView *)webView setWindowFrame:(CGRect)frame
{
    if (!_webView.get().window)
        return;

    [_webView.get().window setFrame:NSRectFromCGRect(frame) display:YES];
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    openPanel.canChooseDirectories = parameters.allowsDirectories;

    auto reportSelectedFiles = ^(NSInteger result) {
        if (result == NSModalResponseOK)
            completionHandler(openPanel.URLs);
        else
            completionHandler(nil);
    };

    if (_webView.get().window)
        [openPanel beginSheetModalForWindow:_webView.get().window completionHandler:reportSelectedFiles];
    else
        reportSelectedFiles([openPanel runModal]);
}

- (void)_webView:(WKWebView *)webView decideDatabaseQuotaForSecurityOrigin:(WKSecurityOrigin *)securityOrigin currentQuota:(unsigned long long)currentQuota currentOriginUsage:(unsigned long long)currentOriginUsage currentDatabaseUsage:(unsigned long long)currentUsage expectedUsage:(unsigned long long)expectedUsage decisionHandler:(void (^)(unsigned long long newQuota))decisionHandler
{
    decisionHandler(std::max<unsigned long long>(expectedUsage, currentUsage * 1.25));
}

- (NSMenu *)_webView:(WKWebView *)webView contextMenu:(NSMenu *)menu forElement:(_WKContextMenuElementInfo *)element
{
    for (NSInteger i = menu.numberOfItems - 1; i >= 0; --i) {
        RetainPtr<NSMenuItem> item = [menu itemAtIndex:i];
        switch (item.get().tag) {
        case kWKContextMenuItemTagOpenLinkInNewWindow:
        case kWKContextMenuItemTagOpenImageInNewWindow:
        case kWKContextMenuItemTagOpenFrameInNewWindow:
        case kWKContextMenuItemTagOpenMediaInNewWindow:
        case kWKContextMenuItemTagCopyImageURLToClipboard:
        case kWKContextMenuItemTagCopyImageToClipboard:
        case kWKContextMenuItemTagDownloadLinkToDisk:
        case kWKContextMenuItemTagDownloadImageToDisk:
            [menu removeItemAtIndex:i];
            break;
        }
    }

    return menu;
}

// MARK: WKNavigationDelegate methods

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     [_webView removeObserver:self forKeyPath:safeAreaInsetsKVOKey];
//
// (end MAVERICKS_BACKPORT restored block)
    RetainPtr delegate = _delegate.get();
    if (!!delegate && [delegate respondsToSelector:@selector(inspectorViewControllerInspectorDidCrash:)])
        [delegate inspectorViewControllerInspectorDidCrash:self];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    // Allow non-main frames to navigate anywhere.
    if (!navigationAction.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // Allow loading of the main inspector file.
    if ([navigationAction.request.URL.scheme isEqualToString:WKInspectorResourceScheme]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // Prevent everything else.
    decisionHandler(WKNavigationActionPolicyCancel);

    RetainPtr delegate = _delegate.get();
    if (delegate && [delegate respondsToSelector:@selector(inspectorViewController:openURLExternally:)]) {
        [delegate inspectorViewController:self openURLExternally:navigationAction.request.URL];
        return;
    }

    // Try to load the request in the inspected page if the delegate can't handle it.
    if (RefPtr page = _inspectedPage.get())
        page->loadRequest(navigationAction.request);
}

// MARK: WKInspectorWKWebViewDelegate methods

- (void)inspectorWKWebViewDidBecomeActive:(WKInspectorWKWebView *)webView
{
    RetainPtr delegate = _delegate.get();
    if ([delegate respondsToSelector:@selector(inspectorViewControllerDidBecomeActive:)])
        [delegate inspectorViewControllerDidBecomeActive:self];
}

- (void)inspectorWKWebViewReload:(WKInspectorWKWebView *)webView
{
    RefPtr page = _inspectedPage.get();
    if (!page)
        return;

    OptionSet<WebCore::ReloadOption> reloadOptions;
    if (linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::ExpiredOnlyReloadBehavior))
        reloadOptions.add(WebCore::ReloadOption::ExpiredOnly);

    page->reload(reloadOptions);
}

- (void)inspectorWKWebViewReloadFromOrigin:(WKInspectorWKWebView *)webView
{
    RefPtr page = _inspectedPage.get();
    if (!page)
        return;

    page->reload(WebCore::ReloadOption::FromOrigin);
}

- (void)inspectorWKWebView:(WKInspectorWKWebView *)webView willMoveToWindow:(NSWindow *)newWindow
{
    RetainPtr delegate = _delegate.get();
    if (delegate && [delegate respondsToSelector:@selector(inspectorViewController:willMoveToWindow:)])
        [delegate inspectorViewController:self willMoveToWindow:newWindow];
}

- (void)inspectorWKWebViewDidMoveToWindow:(WKInspectorWKWebView *)webView
{
    RetainPtr delegate = _delegate.get();
    if (!!delegate && [delegate respondsToSelector:@selector(inspectorViewControllerDidMoveToWindow:)])
        [delegate inspectorViewControllerDidMoveToWindow:self];
}

@end

#endif // PLATFORM(MAC)
