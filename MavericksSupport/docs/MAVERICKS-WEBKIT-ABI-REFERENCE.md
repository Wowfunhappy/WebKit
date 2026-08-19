# The Mavericks WebKit Private API — ABI Reference

The private WebKit API contract the backported frameworks must satisfy on **OS X 10.9.5**. Its frozen core is
what stock **Safari 7.0.6** (WebKit 9537.78.2, dylib version 537.78.x) binds against — Safari is unmodifiable,
so the frameworks must export exactly those symbols, with compatible signatures, at the paths Safari loads. A
few other Safari-7-era system clients (**Mail**, **QuickLook**) additionally bind legacy surface Safari does
not; that surface, also removed or gutted upstream, is restored by the backport and flagged inline. No public
Apple documentation covers this SPI; this reference is reconstructed from the symbols Safari imports
(`host-abi/safari-needs-from-*.txt`, **725** symbols total) plus the WebKit C/Objective-C API of that era.

It is organized by providing framework, then by API group. Symbol counts per group are Safari's imports;
representative entry points are named. The exhaustive symbol lists are the `host-abi/safari-needs-from-<framework>.txt`
files, and `host-abi/check-abi-gap.sh` (run by `build.sh` after staging) fails the build if the staged
frameworks miss any of them.

---

## Frameworks and loading

Safari 7 loads three WebKit dylibs by absolute `LC_LOAD_DYLIB` path. The 10.9 layout uses a **name shift**
relative to modern WebKit:

| Safari-7 framework | Load path | Modern equivalent | Symbols Safari needs |
|---|---|---|---|
| **JavaScriptCore** | `/System/Library/Frameworks/JavaScriptCore.framework` | JavaScriptCore | 95 |
| **WebKit** (WebKit1 / `WebView`) | `/System/Library/Frameworks/WebKit.framework` | **WebKitLegacy** | 24 |
| **WebKit2** (WK2 / `WKView`) | `/System/Library/PrivateFrameworks/WebKit2.framework` | **WebKit** | 606 |

`compatibility_version` is `1.0.0` for all; dyld accepts our build's higher `current_version` against
Safari's `>= 537.78.x` requirement. (Safari also imports ~1385 symbols from system frameworks; those are
not WebKit's responsibility.)

## Conventions

**WebKit2 C API object model.** Everything is an opaque, reference-counted handle: a generic `WKTypeRef`
and concrete types (`WKPageRef`, `WKContextRef`, `WKStringRef`, `WKArrayRef`, …). Lifetime is managed with
`WKRetain` / `WKRelease`; runtime type with `WKGetTypeID` and per-type `WK<Type>GetTypeID`. Naming follows
Core Foundation: `Create*` / `Copy*` return a +1 reference the caller must release; `Get*` return a borrowed
reference. Text is `WKStringRef` / `WKURLRef`, not `NSString`.

**Client/delegate registration.** Behavior is injected by registering versioned C **client structs** of
function pointers, rather than subclassing — `WKPageSetPage<Role>Client(page, &client)` in the UI process
and `WKBundlePageSet<Role>Client(page, &client)` in the content process. Safari implements the browser's
behavior by filling in these structs.

**Two address spaces.** The API spans two processes. The **UI-process** API (`WKContext`, `WKPage`,
`WKView`, …) runs in Safari. The **injected-bundle** API (`WKBundle*`) runs inside each **WebProcess**:
Safari ships a WebProcess plug-in (an "injected bundle") loaded via `WKContextCreateWithInjectedBundlePath`,
which uses the `WKBundle*` API for synchronous, in-process access to the live DOM.

**WebKitLegacy (WK1)** is classic Cocoa — `WebView` and friends, with ordinary retain/release, delegates,
and `NSNotification`s. **JavaScriptCore** is the standard JSC C API (opaque `JSValueRef`/`JSObjectRef`,
`JSValueProtect`/`Unprotect` for GC roots). The UI API is main-thread-affine.

---

## JavaScriptCore.framework (95)

### The JavaScriptCore C API
- **Contexts & groups** — `JSGlobalContextCreate` / `JSGlobalContextCreateInGroup`, `JSGlobalContextRetain` /
  `Release`, `JSContextGetGlobalObject` / `GetGlobalContext` / `GetGroup`.
- **Values** — create (`JSValueMakeNumber`/`String`/`Boolean`/`Null`/`Undefined`, `JSValueMakeFromJSONString`),
  inspect (`JSValueIsObject`/`String`/`Number`/`Boolean`/`Null`/`Undefined`/`ObjectOfClass`/
  `InstanceOfConstructor`), convert (`JSValueToNumber`/`Boolean`/`Object`/`StringCopy`), JSON
  (`JSValueCreateJSONString`), GC roots (`JSValueProtect` / `JSValueUnprotect`).
- **Objects** — `JSObjectMake` / `JSObjectMakeArray`, property access (`JSObjectGet`/`SetProperty`,
  `…AtIndex`, `HasProperty`, the `Private` and `PrivateProperty` family), `JSObjectCallAsFunction`,
  `JSObjectIsFunction`, `JSObjectSetPrototype`, name enumeration (`JSObjectCopyPropertyNames`,
  `JSPropertyNameArray*`, `JSPropertyNameAccumulatorAddName`).
- **Classes / strings / scripts** — `JSClassCreate` (+ `kJSClassDefinitionEmpty`); `JSStringCreateWithCFString`
  / `WithUTF8CString`, `JSStringCopyCFString`, retain/release; `JSEvaluateScript`,
  `JSScriptCreateReferencingImmortalASCIIText` + `JSScriptEvaluate`.
- **Weak object maps** — `JSWeakObjectMapCreate`/`Get`/`Set`/`Remove`, used to associate native wrappers
  with JS objects without rooting them.

### WTF support (C++, mangled symbols)
Low-level runtime the embedder links against. **These are an old WTF ABI** — several were later renamed or
removed upstream, so the backport must keep exporting the exact mangled names:
- **Allocation** — `fastMalloc` / `fastRealloc` / `fastFree` / `fastZeroedMalloc` / `fastMallocGoodSize`.
- **Threading** — `initializeThreading` / `initializeMainThread`; `createThread` / `detachThread` /
  `waitForThreadCompletion` / `currentThread` / `isMainThread`; `WTF::Mutex`, `WTF::ThreadCondition`, the
  `lock`/`unlockAtomicallyInitializedStaticMutex` pair; `callOnMainThread` (both the function-pointer and
  `WTF::Function` overloads) and `cancelCallOnMainThread`.
- **Time** — `currentTime`, `monotonicallyIncreasingTime`.
- **Misc** — `WTF::AutodrainedPool`, `numberToFixedWidthString`, `WTFCrash`, `WTFLogAlways`.

---

## WebKit.framework — WebKitLegacy / WK1 (24)

The classic single-process `WebView` API. Safari 7 is a WebKit2 browser but still touches a few WK1 classes
for history, downloads, preferences, and utilities.

- **Views** — `WebView`, `WebHTMLView`.
- **Preferences** — `WebPreferences` (+ the `WebPreferencesChangedNotification`).
- **History** — `WebHistory`, `WebHistoryItem`.
- **Downloads & authentication** — `WebDownload`, `WebPanelAuthenticationHandler`.
- **Storage & security** — `WebDatabaseManager` (+ `WebDatabaseDirectoryDefaultsKey`), `WebSecurityOrigin`,
  `WebCache`.
- **Utilities** — `WebStringTruncator`, `WebURLsWithTitles`, `WebKeyGenerator` (legacy `<keygen>`),
  `WebCoreStatistics`, `WebKitStatistics`.
- **Constants & functions** — `WebActionModifierFlagsKey` / `WebActionNavigationTypeKey` (navigation-action
  dictionary keys), `WebKitErrorDomain`, `WebLocalizedString`, `WebInstallMemoryPressureHandler`,
  `WebURLNamePboardType` / `WebURLPboardType` (drag-and-drop pasteboard types).

---

## WebKit2.framework — modern WebKit / WK2 (606)

The multiprocess API: a UI-process C API, three Cocoa SPI classes, and the in-WebProcess injected-bundle API.
This is the surface through which Safari drives the browser.

### Embedding (Objective-C SPI)
- **`WKView`** — the `NSView` subclass Safari hosts in its window; the on-screen WebKit2 web view.
- **`WKBrowsingContextController`** — Objective-C controller wrapping a page's loading/navigation.
- **`WKWebInspectorProxyObjCAdapter`** — Objective-C shim bridging the inspector proxy to AppKit.

> These three classes were **removed from upstream WebKit** and are reimplemented by the backport (the rest
> of the WK2 surface is the still-living C API).

The same legacy WebKit2 ObjC embedding API is used by the **other Safari-7-era system WebKit2 clients** — chiefly
**Mail** (message rendering) and **QuickLook** (`Web2.qldisplay` HTML previews) — which build a `WKView` from a
process/page group object rather than from C refs. The backport therefore reimplements two further removed-upstream
classes they need (not in Safari's own import set):
- **`WKProcessGroup`** — wraps the process pool that backs a `WKView`'s web processes.
- **`WKBrowsingContextGroup`** — wraps the page group: `-initWithIdentifier:`, JavaScript/plug-in toggles, and the
  user-content methods `-addUserStyleSheet:…` / `-removeAllUserStyleSheets` / `-addUserScript:…` /
  `-removeAllUserScripts` (forwarded to the `WKPageGroup` user-content C SPI above). Mail's `MUIWebDocumentViewGroup`
  installs its message-view style sheet and scripts through these while opening a message; a missing selector
  terminates Mail with an unrecognized-selector exception.

### `WKContext` — process pool & global context (52)
`WKContextCreate` / `WKContextCreateWithInjectedBundlePath` (Safari passes its WebProcess plug-in here),
`WKContextSetCacheModel`, history/download/connection client registration, and accessors to the storage
managers below (`WKContextGetCookieManager`, `…GetIconDatabase`, `…GetApplicationCacheManager`, …).

### `WKPage` — the web page (91)
- **Loading** — `WKPageLoadURL` / `LoadURLRequest` / `LoadHTMLString` / `LoadAlternateHTMLString`.
- **Navigation** — `WKPageGoBack` / `GoForward` / `Reload` / `StopLoading`; `WKPageGetBackForwardList`.
- **State** — `WKPageCopyCustomUserAgent` / `CustomTextEncodingName` / `PendingAPIRequestURL` /
  `RelatedPages`, title, URL, estimated progress.
- **Clients** — `WKPageSetPage{UI,Loader,Policy,Form,ContextMenu,Find}Client`: the callback structs through
  which Safari implements window/UI prompts, load notifications, navigation policy, form submission, the
  context menu, and find-on-page.

### `WKPageGroup` — page group (3)
Groups pages that share preferences and user content. Safari creates one per page and attaches its
`WKPreferences`: `WKPageGroupCreateWithIdentifier`, `WKPageGroupGetPreferences` / `WKPageGroupSetPreferences`.
The backport additionally **restores the page group's user-content C SPI** — `WKPageGroupGetUserContentController`,
`WKPageGroupAddUserStyleSheet` / `WKPageGroupRemoveAllUserStyleSheets`, `WKPageGroupAddUserScript` /
`WKPageGroupRemoveAllUserScripts` (gutted to no-ops upstream when the page-group user-content model was removed).
The page group owns a `WebUserContentControllerProxy`, and pages created in the group share it (the WKView
initializer seeds the page configuration with it), so scripts and style sheets added here are injected. Safari
itself drives user content through the injected bundle (`WKBundleAddUserScript`) and only imports the three
preferences symbols; **Mail** and **QuickLook** install their user content here via `WKBrowsingContextGroup`.

### `WKPreferences` — settings (106)
Per-page-group settings as one setter/getter pair per feature: `WKPreferencesCreate` / `CreateCopy`,
`WKPreferencesSetJavaScriptEnabled` / `SetJavaScriptCanOpenWindowsAutomatically`, and ~50 further toggles
(plug-ins, WebGL, full-screen, developer extras, storage, media, …). Safari's Preferences UI maps onto these.

### `WKBackForwardList` — session history (11)
`WKBackForwardListItem` plus list queries: `GetBackItem` / `GetCurrentItem` / `GetForwardItem`,
`CopyBackListWithLimit` / `CopyForwardListWithLimit`, `GetBackListCount` / `GetForwardListCount`.

### Value types & object model
- **Strings & URLs** — `WKString`, `WKURL`, `WKURLRequest`, `WKURLResponse` (+ the `_WKURLResponseCopyNSURLResponse`
  bridge to Cocoa networking).
- **Collections** — `WKArray` / `WKMutableArray`, `WKDictionary` / `WKMutableDictionary`
  (`AddItem` / `GetItemForKey` / `CopyKeys` / `GetSize`).
- **Scalars & geometry** — `WKBoolean`, `WKDouble`, `WKSize`, `WKRect` (boxed values passed across the API).
- **Data & serialization** — `WKData`, `WKImage`, `WKSerializedScriptValue` (serializes a JS value across
  contexts/processes — e.g. the result of "run JavaScript").

### Storage & site-data managers (via `WKContext`)
`WKCookieManager`, `WKDatabaseManager` (WebSQL), `WKApplicationCacheManager`, `WKResourceCacheManager`,
`WKMediaCacheManager`, `WKKeyValueStorageManager` (localStorage), `WKIconDatabase` (favicons),
`WKPluginSiteDataManager`. Each enumerates origins and deletes by origin or in full — backing Safari's
"Remove All Website Data" and per-site privacy UI.

### Networking, authentication & downloads
`WKAuthenticationChallenge` + `WKCredential` + `WKProtectionSpace` + `WKCertificateInfo` (HTTP auth & TLS
trust), `WKError` (+ `WKErrorCopyCFError`), `WKDownload`, and `WKOpenPanelParameters` /
`WKOpenPanelResultListener` (`<input type=file>`).

### Permissions & prompts
`WKGeolocationManager` + `WKGeolocationPermissionRequest`; `WKNotificationManager` +
`WKNotificationPermissionRequest` + `WKNotification`; `WKSecurityOrigin`.

### `WKInspector` — Web Inspector (15)
`WKInspectorShow` / `Close` / `ShowConsole` / `ShowResources` / `ShowMainResourceForFrame`, attach/detach,
`IsAttached` — driving Develop ▸ Show Web Inspector.

### `WKRender*` — render-tree introspection (18)
`WKRenderObject` / `WKRenderLayer` tree walking (children, name, element tag/id, rect, layer flags), used by
the inspector and layout diagnostics.

### `WKFrame` — frames in the UI process (20)
`WKFrameCopyURL` / `CopyProvisionalURL` / `CopyName`, `GetParentFrame`, `IsMainFrame`, `GetFrameLoadState`,
security origin, hit-testing.

### `WKUserContentURLPattern` — user content (6)
URL-pattern matching for user scripts/stylesheets and origin allow-lists.

### Injected-bundle API — `WKBundle*` (113), runs in the WebProcess
The in-content-process half. Safari's WebProcess plug-in uses this for synchronous DOM access and to hook
page lifecycle. Subgroups:
- **`WKBundle`** — the bundle object: `WKBundleSetClient`; message passing to/from the UI process
  (`WKBundlePostMessage` / `PostSynchronousMessage`); user scripts/stylesheets (`AddUserScript` /
  `AddUserStyleSheet` / `Remove…`); origin-access allow-list; `WKBundleReportException`;
  `WKBundleIsProcessingUserGesture`.
- **`WKBundlePage`** — the page in-process: per-page client hooks (`SetPageLoaderClient` /
  `ResourceLoadClient` / `PolicyClient` / `FormClient` / `UIClient` / `ContextMenuClient` /
  `DiagnosticLoggingClient`); capability checks (`CanShowMIMEType` / `CanHandleRequest`); snapshots
  (`CreateSnapshot…`); render-tree copy; page overlays & header/footer banners; `ForceRepaint`;
  layout-milestone listening; `SetDefersLoading`.
- **`WKBundleFrame`** — the frame in-process: URL / provisional URL, child frames, security origin,
  WebArchive capture (`CopyWebArchive…`), content bounds & scroll offset, and the bridge into JavaScriptCore
  (`GetJavaScriptContextForWorld`, `GetJavaScriptWrapperForNodeForWorld`).
- **`WKBundleNodeHandle` / `WKBundleHitTestResult`** — DOM node handles and hit-testing: element bounds /
  render rect, owning document/frame, input-element autofill state and "last change was a user edit"
  (autofill heuristics), table-cell navigation; hit-test link/image/media/PDF URLs and media type/state.
- **`WKBundlePageGroup` / `WKBundleScriptWorld`** — page-group identity and isolated script worlds (the
  normal world plus created worlds; wrapper clearing) — the basis for content-script isolation.
- **`WKBundleNavigationAction` / `WKBundleDOMWindowExtension` / `WKBundleBackForwardList`** —
  navigation-action introspection (type, originating form element, hit-test), DOM-window lifecycle
  extensions, and the in-process back/forward list.

---

## The contract and verifying it

All **725** symbols must be exported by the backport's frameworks at the install paths above. A missing one
is fatal: Safari either fails to launch (`dyld: Symbol not found`) or traps when the feature is first used.

Most WK2 C-API symbols still exist unchanged in modern WebKit and need no work. What the backport actively
fills in:
- the **Objective-C classes** `WKView`, `WKBrowsingContextController`, `WKWebInspectorProxyObjCAdapter` (Safari),
  plus `WKProcessGroup` and `WKBrowsingContextGroup` (Mail / QuickLook) — all removed upstream → reimplemented;
- some gutted C API such as the `WKPageGroup` user-content functions, parts of `WKBundlePageGroup*`, and
  `WKSerializedScriptValue*` (restored);
- the **old WTF mangled names** in JavaScriptCore.

## How the contract was captured

The three `safari-needs-from-<framework>.txt` files are the intersection of what Safari imports with what each
stock 537.78 framework exported, computed once from the factory binaries (kept in `stock-webkit-backup`
beside the checkout — `scripts/stage-frameworks.sh` captures them at build time):

```
nm -gu /Applications/Safari.app/Contents/Frameworks/Safari.framework/Safari | awk '{print $NF}' | sort -u > safari-imports.txt
nm -gU <stock>/JavaScriptCore.framework/Versions/A/JavaScriptCore | awk '{print $3}' | sort -u > exports-JavaScriptCore.txt
comm -12 safari-imports.txt exports-JavaScriptCore.txt > safari-needs-from-JavaScriptCore.txt
```
and likewise for `WebKit.framework/Versions/A/WebKit` (24) and `WebKit2.framework/Versions/A/WebKit2` (606). Safari
imports 2110 symbols in all; the remaining ~1385 come from system frameworks and 0 from WebCore directly.
`StagedFrameworks/Safari` (a Safari-9 mechanism) is empty and unused by Safari 7.
