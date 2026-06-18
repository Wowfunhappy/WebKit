# Divergence audit vs upstream `83b24ce`

Working tree vs the upstream base the backport branched from. ~1092 hand-edited
`Source/*.{cpp,mm,h}` files (+ vendored deps/generated Makefiles, excluded as
noise). Per-area detail: `/tmp/audit-{uiprocess,wcplatform,webprocess,shared,pal-wtf,wccore}.md`.

The divergence is three things in a trenchcoat:
1. **Deliberate Safari-7 backport** (KEEP) — feature stub-outs + legacy ABI/SPI restoration.
2. **Mechanical removable noise** (REMOVE) — dead debug scaffolding, SDK-decl shims, dupes.
3. **Polyfill-convertible workarounds** (CONVERT) — source edits that should be archive symbols.

## KEYSTONE INSIGHT
A large share of the CONVERT/REMOVE wins are unlocked by retiring `libpolyfill.a`
(tasks #80/#81). Many source files were gutted/guarded ONLY because libpolyfill's
`webcore_stubs.o`/`all_stubs.o` *shadowed* a real symbol with a garbage stub
(e.g. `screenColorSpace`, `CVDisplayLinkGetNominalOutputVideoRefreshPeriod`,
`SharedBuffer::create(NSData*)`). De-shadow + provide real impls → the source
reverts to upstream automatically. Fix the polyfill layer, the source divergence
falls out.

## ⚠️ CRITICAL — bugs the SDK switch itself introduced (fix first)
Several guards use a **compile-time** `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= NNN`
(SDK version) instead of a **runtime** `@available`/`respondsToSelector`. Against
the 26.1 SDK `MAX_ALLOWED` is always huge → these now compile the 10.10+ path and
**crash on 10.9 at runtime**. Confirmed:
- `WebKit/Shared/Cocoa/CocoaImage.mm` — `+[UTType typeWithMIMEType:]` (>=110000)
- `WebCore/rendering/cocoa/RenderThemeCocoa.mm` — NSDateComponentsFormatter
- `WebCore/testing/WebArchiveDumpSupport.mm`
- audit `RenderThemeMac.mm` + grep the tree for the pattern.
→ convert each to a runtime guard.

## REMOVE (mechanical, high-volume, low-risk)
- **Dead debug scaffolding (task #63)** — `FILE *_f=((FILE*)0); if(_f){fprintf…}`
  never-execute blocks + `// removed debug fopen logging` comment stubs, in ~50+
  files across every subsystem; the `SAFARI_AUTOOPEN_URL` ~250-line dev hook in
  WebKit2InitializeCocoa.mm; `/tmp/wk_wordlock_trips.log` writers in WordLock/
  RunLoop/StringImpl. Biggest single win, zero behavior change.
- **Lightweight-generics strips (~79 sites, ~25 SPI headers)** — `NSArray<Foo*>*`→
  `NSArray*`; modern SDK parses generics. Reverting `NSViewSPI.h` also fixes a real
  bug it introduced (double-pointer `_subviewsIvar` typo + dropped `<CALayerDelegate>`).
- **SDK-declaration shim halves** — `#ifndef`/`#define`/`MAX_ALLOWED<101200`-gated
  type re-decls now inert: CFNetworkSPI.h (tls_protocol_version_t, NSURLSessionTask*),
  SecuritySPI.h, CommonCryptoSPI.h, OSObjectPtr.h, bmalloc.h, the `@protocol
  CAAnimationDelegate`/`CAContext`/enum shims in UIProcess CA files. Keep the inner
  runtime guards; drop the outer shim.
- **Dupes / orphans** — duplicate `Platform/IPC/{,cocoa/}MachPort.h`; orphan
  `rendering/cocoa/DrawGlyphsRecorder.h` (byte-identical, referenced nowhere);
  empty `Platform/spi/Cocoa/os/base.h` stub that *shadows* the SDK (reverting it
  also reverts OSStateSPI.h macro block); orphan SystemFontDatabaseCoreTextStub.cpp.
- **Redundant feature gut-outs** — 4 ShapeDetection .mm (already dead via the
  HAVE macro); NSKeyedArchiver(WKEncodedData) category (encodedData is 10.2+).
- **Generated Makefiles** (Source/*/Makefile, +40k lines) — `.gitignore`, not audit.

## CONVERT (move workaround into the vendored polyfill archive → source reverts)
Real impls / constants to add to MavericksSupport/legacy-polyfills (or de-shadow):
- `CGGradientCreateWithColorComponentsAndOptions` → forward to classic (#30 revert)
- `CTFontCreateForCharactersWithLanguageAndOption` ×3 → forward to classic (#31)
- CT CFStringRef constants: kCTFontFallbackOptionAttribute, kCTFontUserInstalledAttribute,
  kCTFontUIFontDesign*, kCTUIFontTextStyle*, kCTFontOpenTypeFeature{Tag,Value} → real consts
- `CGContextDrawPathDirect` → AddPath+DrawPath (fixes SVG <path>)
- `screenColorSpace(Widget*)` — de-shadow real WebCore symbol (3 call sites revert)
- `CVDisplayLinkGetNominalOutputVideoRefreshPeriod` — real on 10.9, de-shadow
- `CGColorSpaceGetName`, `CGColorSpaceCreateWithPropertyList` (SerializedScriptValue)
- `CGContextDelegateSetCallback` family (GlyphDisplayListCache / DrawGlyphsRecorder)
- `NSEdgeInsetsEqual`, `NSLanguageIdentifierAttributeName`
- IOHIDEvent float/scroll-momentum getters (fix wrong stub → scroll momentum)
- VTRestrictVideoDecoders, kCMVideoCodecType_{HEVCWithAlpha,AV1}, CABackingStoreCollectBlocking,
  NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
- SharedBuffer::create(NSData*), nsCookieStorage(), standardUserAgentWithApplicationName (de-shadow)
- SystemConfiguration kSC* reachability constants (navigator.onLine)
- os_log stubs, dispatch_queue_create_with_target, HKDF/CCDeriveKey

## KEEP (the irreducible backport)
(a) Safari-7 ABI/SPI restoration — WKView.mm rewrite, MinimalPageClient.mm (1456 ln),
legacy V0/V1 callbacks, WKPage/WKContext compat exports, QuickLook Web2.qldisplay SPI.
(b) 10.9 runtime guards — ~100+ respondsToSelector:/@available sites (declaration on
the modern SDK does NOT make these removable — the symbol is NULL on 10.9 at runtime).
(c) Restored lost upstream files + ~103 UIProcess feature stubs (WebExtensions, WebAuthn,
Automation, …), inline-PDF stub-out, AX isolated-tree stub-out — deliberate.
(d) Behavior/bug fixes; crypto CommonCrypto backports.
(e) Build-system glue (clang-22/SDK), PAL soft-link prefix strips.

## FLAG — human judgment / re-test (do NOT blind-revert)
- Hack clusters masking the heap-corruption keystone (#40/#43/#45/#48/#53/#54/#55/#56):
  CoreIPCError/ArgumentCodersCocoa crash-skips, ~9 files downgrading RELEASE_ASSERT(isMainThread),
  TreeScopeOrderedMap skipped security asserts, compositing masks, IPC double-dispatch,
  Document::visualUpdatesAllowed()=true. May be SDK-obsoleted — RUNTIME re-test, not revert.
- Security: WebPageProxyMac.mm drops an IPC MESSAGE_CHECK (executeSavedCommandBySelector).
- `SHA1.cpp` (replaces CC_SHA1_Update, "crashes on 10.9") vs CryptoDigestCommonCrypto.cpp
  (calls it directly) — contradiction; one is wrong.
- PlatformScreenMac sRGB color regression; NetworkStorageSession dropped privacy semantics;
  PDFDocumentImage blanket disable; StyleResolver root-font init disabled (likely revertable
  now fonts are fixed #31/#34).

## SDK-migration build residuals (build12 → build13) — fixed

After deleting the `os/base.h` shadow stub (root of 6540 errors; see
webkit-mavericks-os-base-shadow memory), build12 fell to 288 errors in ~10 root causes,
all fixed:

1. **CFTypes.serialization.in** — REVERTED to upstream 83b24ce. Backport had changed the
   `SecCertificateRef`/`SecKeychainItemRef` forward-decl struct tags to the historical
   `OpaqueSec*` names (10.9 SDK); the 26.1 SDK declares them as `__SecCertificate`/`__SecKeychainItem`,
   so the historical tags collided (278 of the 288 errors: SecBase.h + GeneratedSerializers.h).
   Struct tag is compile-time-only — runtime pointer ABI identical, safe on 10.9.
2. **WKWebView.mm** — removed `#ifndef NSTextAlignmentNatural / #define …4`. `#ifndef` can't see
   the SDK's enum constant → fired → return-type int mismatch. SDK provides it; REMOVE.
3. **WebDataListSuggestionsDropdownMac.mm** — removed `#ifndef NSWindowTitleHidden / #define …1`
   (collided with the SDK's `enum NSWindowTitleVisibility`; leaked into WebDateTimePickerMac.mm via
   unified source). REMOVE.
4. **NetworkSessionCocoa.mm** — removed `#ifndef tls_ciphersuite_t / typedef uint16_t` (SDK has the
   enum; the function now takes the SDK type). REMOVE.
5. **WebViewImpl.mm** — `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` is 10.10+
   (weak-null on 10.9) and the SDK now declares it extern → static redefinition. RENAMED to a
   WebKit-local constant (`webkit…`) + use sites; a nil notification name would observe ALL
   notifications. KEEP (MAVERICKS_BACKPORT).
6. **WebPopupMenuProxyMac.mm** — same pattern for `NSLanguageIdentifierAttributeName` (10.11+); used
   as a dict key (nil → throw). RENAMED to `webkitNSLanguageIdentifierAttributeName`. KEEP.
7. **WKWebsiteDataStore.mm** — guarded the explicit `_proxyConfigurations` ivar with
   `#if HAVE(NW_PROXY_CONFIG)` (0 on 10.9; the accessors are already guarded, but the always-declared
   @property auto-synthesized and mismatched the RetainPtr ivar). KEEP.
8. **PlatformHave.h HAVE_APP_SSO** — gate was `__MAC_OS_X_VERSION_MAX_ALLOWED >= 101500` (SDK), but
   App SSO needs the 10.15+ SOAuthorization *runtime*, absent on 10.9. Changed to MIN_REQUIRED
   (deployment target) → off on 10.9, consistently compiling out the gutted SOAuthorizationCoordinator
   + the NavigationState `tryAuthorize` call. The MIN-vs-MAX correction.
9. **WKTextExtractionUtilities.mm** — added `#import "Logging.h"` (provides LOG_CHANNEL_PREFIX for the
   RELEASE_LOG). Upstream relies on a unified-source sibling importing it first; our source set bundles
   this file alone. KEEP.
