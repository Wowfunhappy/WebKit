# Exhaustive JUSTIFY-OR-REVERT audit — `Source/WebCore/platform` (excl. `graphics`) vs `83b24ce`

Build context: macOS 26.1 SDK, clang-22, deploy target 10.9, vendored polyfill archive available.
Method: every changed hunk gets exactly one verdict. KEEP requires a concrete runtime-absence /
ABI / behavior / build-glue reason (must carry a `// MAVERICKS_BACKPORT:` comment). "Compiles now" ⇒ REVERT.

Scope = 122 changed files. Core/cocoa/sql/text/gamepad files audited directly below; the five large
subdirectories (network, audio, mediastream+video-codecs+mediarecorder, ios, mac) were audited by
dedicated passes and are folded into the sections + counts.

---

## REVERT

### Core / misc (audited directly)
| File | Hunk | Why REVERT |
|---|---|---|
| `VideoPixelFormat.cpp` | `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300` around `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange` | 26.1 SDK declares the Lossless enum; the SDK-version `#if` is a compile gap-fill. Constant is only *used* as a value compare, not called → revert to upstream single-line `||`. |
| `libwebrtc/LibWebRTCVPXVideoDecoder.cpp` | 4× `#ifndef kCVPixelFormatType_*10BiPlanar*` FourCC `#define` block | 26.1 SDK declares all four enums; `#ifndef` bodies are dead. |
| `sql/SQLiteDatabase.cpp` | `#ifndef SQLITE_CHECKPOINT_TRUNCATE / #define …3` | 26.1 SDK `usr/include/sqlite3.h` declares `SQLITE_CHECKPOINT_TRUNCATE` (verified). The `#ifndef` body is dead. (It is only a compile-time enum value, not a runtime symbol — so unlike `bind_blob64` this one is a pure declaration gap-fill.) |
| `cocoa/SharedMemoryCocoa.mm` | 2× `{FILE *_d=((FILE*)0); if(_d){fprintf…}}` dead-debug lines (makeMemoryEntry, createVMShare) | Dead `((FILE*)0)` scaffolding — always-false, never logs. Drop. (The `MAP_MEM_USE_DATA_ADDR`-flag drop on the same lines is KEEP — see below.) |
| `gamepad/cocoa/GameControllerSPI.h` | `NSArray<_GCCControllerHIDServiceInfo *> *` → `NSArray *` | Pure ObjC-generics strip; 26.1 SDK supports lightweight generics and the `@class` fwd-decl is retained. |
| `cocoa/PlatformSpeechSynthesizerCocoa.mm` | block param `NSArray<AVSpeechSynthesisVoice *> *` → `NSArray *` | Pure generics strip; the AVSpeechSynthesisVoice type is declared by the 26.1 SDK. (Whole TU runs only if AVSpeech voices SPI exists at runtime, but that's unchanged by the strip.) |

### Subdir REVERTs (from directory passes)
**mediastream/video-codecs/mediarecorder** — the single biggest REVERT cluster:
- All `PAL::`→bare-token strips on CoreMedia/AVFoundation soft-link calls in `DisplayCaptureSourceCocoa.cpp`, `IncomingAudioMediaStreamTrackRendererUnit.cpp`, `MockAudioCaptureUnit.mm`, `RealtimeIncomingAudioSourceCocoa.cpp`, `AVVideoCaptureSource.mm` (CM calls), `mediarecorder/MediaRecorderPrivateEncoder.cpp` (6), `mediarecorder/cocoa/MediaRecorderPrivateWriterAVFObjC.mm` (5), `video-codecs/cocoa/RTCVideoDecoderVTBAV1.mm` (5). **CAVEAT: only revert jointly with reverting the out-of-scope PAL headers `PAL/pal/cf/CoreMediaSoftLink.h` + `…/cocoa/AVFoundationSoftLink.h`** (they were re-`#define`d to expand to `PAL::softLink_…`, which forced the call-site strips). Runtime-identical; these CM/AVF symbols exist on 10.9.
- `VideoFrameLibWebRTC.cpp` + `RealtimeIncomingVideoSourceCocoa.mm`: 4× `#ifndef kCVPixelFormatType_*10BiPlanar*` blocks (SDK declares them).
- `AVVideoCaptureSource.mm`: `supportedMaxPhotoDimensions` generics strip + `firstObject` cast; `#if PLATFORM(IOS_FAMILY)` around the dead torch-on path.
- Redundant no-op flag guards on flags that are actually ON: `#if USE(LIBWEBRTC)` include-guards in `AudioMediaStreamTrackRendererCocoa.cpp` + `MediaStreamTrackAudioSourceProviderCocoa.cpp`; `#if ENABLE(VP9)` guards in `LibWebRTCProviderCocoa.{cpp,h}` (VP9 is ENABLED — `#else` dead); `#if ENABLE(MEDIA_STREAM)` removal in `DisplayCapturePromptType.h` (serializer is SCKit-gated off anyway).
- Dead file: `mac/RealtimeOutgoingVideoSourceCocoa.mm` reduced to `#include "config.h"` — orphan (build references the `.cpp`); delete.

**ios** — 4 fully-REVERT files, all pure ObjC lightweight-generics strips, all additionally `#if PLATFORM(IOS_FAMILY)`-compiled-out on Mac: `AbstractPasteboard.h` (8), `PlatformPasteboardIOS.mm` (5), `WebItemProviderPasteboard.h` (5), `WebItemProviderPasteboard.mm` (25 — includes a *malformed* strip `static NSArray *> *allLoadableClasses()` that only builds because the TU is excluded; reverting fixes it).

**mac** — 2 fully-REVERT files + scattered hunks: `NSScrollerImpDetails.h` (`__OBJC__` guard + AppKit import + removed `NSScrollerStyle` fwd-decl — SDK provides it); `WebPlaybackControlsManager.h` (`AVTouchBarMediaSelectionOption` generics strip). Scattered: `PlatformEventFactoryMac.mm` `#ifndef NSEventModifierFlag*` macro block; `PlatformPasteboardMac.mm` `#ifndef NSPasteboardType*` block; `RevealUtilities.mm` BSD-header deletion; `ScrollViewMac.mm` whitespace-only sub-hunks.

**network** — `ResourceRequestCocoa.mm` one trailing-whitespace hunk; the `WebCoreNSURLSession.h` generics strip (moot — see KEEP/UNSURE).

**audio** — `AudioSampleDataSource.mm` `~dtor(){}`→`=default` + comment-only blocks; `WebAudioBufferList.cpp` comment + `::AudioBuffer` global-namespace qualifiers (name-lookup workaround, not a 10.9 need). All other audio call-site `PAL::` strips are UNSURE-revert-with-header (same caveat as mediastream).

---

## CONVERT (missing-on-10.9 C symbol → move to vendored polyfill, source reverts upstream)

| File | Call site | Polyfill symbol(s) | Impl note |
|---|---|---|---|
| `network/cf/CertificateInfoCFNet.cpp` | `copyCertificateChainCompat()` helper replacing `SecTrustCopyCertificateChain(trust)` (Security, 12.0) at 3 sites | **`SecTrustCopyCertificateChain`** → `CFArrayRef` | Impl = the helper's own loop: `SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex` (both present on 10.9) into a `CFMutableArrayRef`. Then source reverts to upstream `adoptCF(SecTrustCopyCertificateChain(...))`. The single cleanest CONVERT in the whole scope. |
| `mac` UTType helper family (`UTTypeIdentifiers.h` DEFINE_UT_HELPER macros + the `respondsToSelector:` guards duplicated in `PasteboardMac.mm`/`PlatformPasteboardMac.mm`/`PasteboardWriter.mm`/`PasteboardCocoa.mm`/`DragDataCocoa.mm`) | `+[UTType PNG/JPEG/TIFF/URL/fileURL/HTML/…]` class accessors (11.0) guarded vs `kUTType*` (10.3) | A real `UTType` **polyfill class** exposing `+PNG/+fileURL/…` backed by the `kUTType*` constants | Large CONVERT *opportunity* (~25–30 hunks across 6 files), but lower priority: needs a faithful `UTType` shim class. Until then these stay KEEP (runtime-required guards). Flagged, not actioned. |

No CONVERT candidates in audio (all touched C symbols exist on 10.9 via PAL) or ios/mediastream.

---

## KEEP (each needs a `// MAVERICKS_BACKPORT:` reason comment)

### (b) 10.9 runtime guards — absent ObjC selector / class / behavior (cannot be a C polyfill)
- **Core:** `LocalizedStrings.cpp` (null-`webCoreBundleSingleton()` guard — crash fix, cat d/b); `MIMETypeRegistry.cpp` (`CGImageDestinationCopyTypeIdentifiers` null guard + static fallback — crash fix); `CommonAtomStrings.cpp` (drop `RELEASE_ASSERT(isUIThread())` inside `call_once` — WebContent inits off the XPC queue; behavior).
- **cocoa:** `DragImageCocoa.mm` (`labelColor`/`secondaryLabelColor`/`quaternaryLabelColor` 10.10+ guards + `graphicsPort` instead of `.CGContext` 10.10+ + `initWithString:nil` guard); `LowPowerModeNotifier.mm` (`isLowPowerModeEnabled`/`NSProcessInfoPowerStateDidChangeNotification` 10.12+ guards); `PublicSuffixStoreCocoa.mm` (drop `RELEASE_ASSERT(isMainThread)` + lazy-create cache — main-thread-identity); `PasteboardCocoa.mm`+`DragDataCocoa.mm` (UTType-vs-kUTType branches via UTTypeIdentifiers.h).
- **text:** `LocaleCocoa.mm` (`-[NSLocale languageCode]` 10.12+ → `objectForKey:NSLocaleLanguageCode`); `LocalizedDateCache.mm` (`-[NSString containsString:]` 10.10+ → `rangeOfString:` — was a real WebContent crash on any date `<input>`).
- **sql:** `SQLiteExtras.h` (`sqlite3_bind_blob64` → `sqlite3_bind_blob`). **Runtime gap, NOT a declaration gap:** the 26.1 SDK header declares `bind_blob64`, but WebKit links the *system* `libsqlite3.tbd`; on 10.9 that is SQLite 3.7.13, which lacks `bind_blob64` (added 3.8.7 / 10.10). Reverting would link-fail / crash on 10.9. KEEP.
- **cocoa:** `SharedMemoryCocoa.mm` (drop `MAP_MEM_USE_DATA_ADDR` — declared in 26.1 SDK but a 10.12+ *kernel* flag; 10.9 kernel returns KERN_INVALID_ARGUMENT → KEEP the flag-drop; only the `((FILE*)0)` lines REVERT).
- **mac:** the large runtime-guard set — `LocalCurrentGraphicsContextMac.mm`/`WidgetMac.mm` (`graphicsContextWithGraphicsPort:` vs 10.10+ `…CGContext:`), `LocalDefaultSystemAppearance.mm`/`ScrollbarsControllerMac.mm` (`currentDrawingAppearance` 10.14+), `ScrollbarThemeMac.mm` (`setUserInterfaceLayoutDirection:` 10.10+), `ScrollingMomentumCalculatorMac.mm` (`_NSScrollingMomentumCalculator` 10.10+), `ThemeMac.mm` (`accessibilityDisplayShould*` 10.10+/10.12+), `ValidationBubbleMac.mm` (`setMaximumNumberOfLines:` 10.11+), `PlatformEventFactoryMac.mm` (`menuTypeForEvent:` 10.10+, `convertPointToScreen:` 10.12+, `stage`/`pressure` 10.10.3+), `ScrollViewMac.mm` (`convertPointToScreen:`→`convertRectToScreen:`, content-insets 10.10+ removal), `PasteboardMac.mm`/`PasteboardWriter.mm`/`PlatformPasteboardMac.mm` (UTType 11.0+ guards, `_setExpirationDate:` 11.0+, `initWithString:nil` guards).
- **mediastream:** `AVVideoCaptureSource.mm` (`deviceType` 10.15+ / `portraitEffectActive` 12.0+ `respondsToSelector:` guards + conditional KVO — the getUserMedia crash); `AVCaptureDeviceManager.mm` (`AVCaptureDeviceDiscoverySession` 10.10+ nil-fallback + `systemPreferredCamera` 12.0+ conditional KVO).
- **network:** `NetworkLoadMetrics.mm` (`NSURLSessionTaskTransactionMetrics` 10.12+, `_timingData` SPI), `ResourceRequestCocoa.mm` (`_privacyProxyFailClosed…` SPI guards), `ResourceResponseCocoa.mm` (`SecTrustEvaluateWithError` 10.14+ → `SecTrustEvaluate`), `ResourceErrorMac.mm` (`underlyingErrors` 11.3+, `nw_*` 10.14+ removal), `UTIUtilities.mm`+`WebCoreURLResponse.mm` (`UTType` class 11.0+ → classic CoreServices C API; `_schemeWasUpgradedDueToDynamicHSTS` SPI), `WebCoreResourceHandleAsOperationQueueDelegate.mm` (`_timingData` SPI).

### (c) restored lost upstream file / new backport stub file
- **mac:** `ScrollViewMac.mm` — restored `platformSetContentsSize()` (whole feature; WK1 WebViews never paint without it).
- **cocoa:** `SharedBufferCocoa.mm`, `MIMETypeRegistryCocoa.mm`, `MediaUtilities.cpp` — re-implemented because the previous backport left them stubbed/excluded and callers bound to garbage-returning polyfill stubs → real crashes (image/CT/media/getUserMedia). Use APIs present on 10.9. **MIMETypeRegistryCocoa.mm/UTType path overlaps the CONVERT-UTType opportunity** but is functionally a restored impl.
- **new stub files (build glue, cat e):** `cocoa/PlatformView.h`, `cocoa/PublicSuffixCocoa.mm`, `cocoa/RuntimeApplicationChecksCocoa.mm` (all 1-line stubs satisfying the source list); `ios/PlaybackSessionInterfaceAVKit.{h,mm}`, `ios/VideoPresentationInterfaceAVKit.mm` (SourcesCocoa.txt lists files with no upstream content at base); `mediastream/libwebrtc/WebRTCCodecStubs109.mm` (NEW — provides RTCVideoEncoder/DecoderH265/AV1, `kRTCVideoCodecH265Name`, `RTCDispatchQueueCreateWithTarget` that force-loaded libwebrtc.a references but whose impls are 10.12+/HEVC/AV1 absent → dyld abort at launch without it); `mediastream/mac/CoreAudioCaptureUnit.cpp` (defns for VAD/mute methods whose canonical `.mm` is build-excluded).

### (d) genuine behavior/feature-reduction (whole-feature gutting of 10.9-impossible features → KEEP the deletion)
- **cocoa:** `EffectiveRateChangedListener.mm`, `ParentalControlsContentFilter.mm`, `CoreLocationGeolocationProvider.mm` → 2-line stubs (depend on CMTimebase notification SPI / WebContentAnalysis / CoreLocation website-identifier SPI absent on 10.9). `PlaybackSessionModelMediaElement.mm` `wirelessVideoPlaybackDisabled→false`. `SharedBufferCocoa.mm` `FragmentedSharedBuffer::createNSDataArray()` by-reference rewrite (fixes the O(n²) NYTimes-clip 6GB RSS leak — real bug fix).
- **audio:** `AudioFileReaderCocoa.mm` (working `ExtAudioFile` in-memory decoder replacing the AVAssetReader path; fixes scritch.dev/play SIGABRT); `AudioSession.cpp` dummy session + MAC return-value fallbacks; `MediaSessionManagerCocoa.mm`, `AudioSessionMac.mm`, `SharedRoutingArbitrator.mm` reduced (MediaRemote 10.12+ / AVAudioRoutingArbiter 11+ absent).
- **mac:** `PlaybackSessionInterfaceMac.mm`, `VideoPresentationInterfaceMac.mm`, `WebCoreFullScreenPlaceholderView.mm`, `VideoFullscreenInterfaceMac.h`, `RevealUtilities.mm` body (AVKit Touch-Bar/PiP 10.12+, RevealKit 10.13+); `UserAgentMac.mm` (Safari-7-consistent UA string — behavior); `UTTypeIdentifiers.h` (consumed by 5 out-of-scope files — load-bearing).
- **network:** `NetworkStorageSessionCocoa.mm` (cookie rewrite over `NSHTTPCookieStorage`, tasks #49/#71), `ResourceResponseCocoa.mm` `+load` download-file shim (NetworkProcess crash fix), `NetworkStateNotifierMac.cpp` `startObserving()` early-return (avoids polyfill SC-constant crash — FLAG to re-test after polyfill retirement), `ResourceRequestCocoa.mm` `doUpdatePlatformRequest` private-CF-SPI removal (#51).

### (e) build glue
- See the stub files under (c); plus `ScalableImageDecoder.cpp` (compile WEBPImageDecoder + `matchesWebPSignature` on PLATFORM(MAC) for libwebp WebP fallback — ImageIO on this build can't decode WebP; KEEP) and `ScrollView.cpp` (`scrollTo` clamp — pairs with the frameViewDidScroll visual-scroll fix; behavior, cat d).
- `MediaSamplesBlock.cpp` / `MediaStrategy.cpp` `#if` tightenings (CoreMedia PAL / MSE-renderer gating) — KEEP (feature gating, avoids undefined-symbol / ASSERT_NOT_REACHED on 10.9).

---

## UNSURE / FLAG (human judgment)

1. **`network/cocoa/CookieCocoa.mm` gutted to a 2-line stub — LIKELY A LATENT LINK ERROR.** The 4 `WebCore::Cookie` ↔ `NSHTTPCookie` methods it deleted are still referenced by `WKHTTPCookieStore.mm:66,135`, `MediaPlayerPrivateAVFoundationObjC.mm:1837`, and `InspectorPageAgent.cpp:385` (`ListHashSet<Cookie>`). Those methods use only 10.9-present NSHTTPCookie APIs → no 10.9 reason to gut. **Recommend un-gutting.** Confirm whether the build currently links.
2. **`network/cocoa/WebCoreNSURLSession.mm` gutted (1078 del)** — dead-coded (nothing instantiates it; media goes via WebCoreAVFResourceLoader). Effectively KEEP the stub, but large divergence; keep the `.h`.
3. **`network/cf/DNSResolveQueueCFNet.cpp`** — `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101400` is mis-keyed to the SDK (always true on 26.1) so it now selects the 10.14 `nw_endpoint_create_host` path on 10.9. Needs a deployment-target/runtime gate or polyfill routing.
4. **`audio` PAL-strip family + `AudioSampleBufferConverter.mm` stub** — strips revert only with the PAL headers (test whether upstream `#if !__has_feature(modules)` compiles under clang-22 first). The converter `.mm` is stubbed while `AudioEncoderCocoa.cpp` still calls it — possible latent link break; confirm build inclusion.
5. **`mac/PlatformScreenMac.mm` (494-line gut)** — removes ~25 screen-geometry functions still declared in PlatformScreen.h and called in-tree; links only because the polyfill shadows them. The legit part is dropping HDR/EDR/GPU-ID/AVFoundation paths (10.13+). **Recommend re-doing as a targeted strip** rather than gut-and-lean-on-polyfill-stubs (the "polyfill shadows" anti-pattern). The `gpuIDForDisplay→0` and `displayID intValue→unsignedIntValue` hunks are genuine KEEP.
6. **`mac` video-presentation gut link safety** — `WebView.mm:9133` / `WebPlaybackControlsManager.mm` still call the gutted `PlaybackSessionInterfaceMac::{create,…}`; confirm symbols resolve (or define `ENABLE_VIDEO_PRESENTATION_MODE 0`) rather than rely on polyfill-shadowed C++.
7. **`ios` 4 whole-feature gut stubs** (`PlaybackSessionInterfaceIOS.{h,mm}`, `PlaybackSessionInterfaceAVKitLegacy.mm`, `WebAVPlayerController.mm`) — dead on the Mac CMake build; not justifiable as KEEP. Prefer reverting to upstream; if AVKit-SPI compile fails, re-guard `#if PLATFORM(IOS_FAMILY) && HAVE(AVKIT)` (matching the sibling files left intact) — do NOT keep the lossy `#include "config.h"` stub.
8. **UTType helper duplication** — `PasteboardMac.mm`/`PlatformPasteboardMac.mm` re-define the `UT_*_ID()` helpers locally instead of including `UTTypeIdentifiers.h`; de-dup.

---

## Counts

Hunk-bucket totals (grouped; whole-file rewrites counted as 1 unit):
- **REVERT:** ~95 hunks. Dominated by: ios pure-generics strips (43), mediastream/mediarecorder/video-codecs PAL-strips + SDK-enum + dead-flag-guards (~36, revert-with-PAL-header), mac (~6), core/cocoa/gamepad/speech (~8), network/audio cosmetic (~3).
- **CONVERT:** 1 actionable (`SecTrustCopyCertificateChain`) + 1 large opportunity (UTType polyfill class, ~25–30 hunks, deferred).
- **KEEP:** ~75 hunks/units — runtime guards (~40), restored/stub files (~12), whole-feature gutting (~15), build glue (~8).
- **UNSURE/FLAG:** 8 items (CookieCocoa likely-link-error; WebCoreNSURLSession gut; DNS gate; audio PAL+converter; PlatformScreenMac gut; mac video-presentation link; ios 4 gut stubs; UTType dup).

File totals (122 files):
- **Fully-REVERT files:** ~21 — ios (4: AbstractPasteboard.h, PlatformPasteboardIOS.mm, WebItemProviderPasteboard.{h,mm}); mediastream/mediarecorder/video-codecs (~15: DisplayCaptureSourceCocoa.cpp, IncomingAudioMediaStreamTrackRendererUnit.cpp, AudioMediaStreamTrackRendererCocoa.cpp, MediaStreamTrackAudioSourceProviderCocoa.cpp, MockAudioCaptureUnit.mm, RealtimeIncomingAudioSourceCocoa.cpp, RealtimeIncomingVideoSourceCocoa.mm, RealtimeOutgoingVideoSourceCocoa.mm, VideoFrameLibWebRTC.cpp, LibWebRTCProviderCocoa.{cpp,h}, DisplayCapturePromptType.h, MediaRecorderPrivateEncoder.cpp, MediaRecorderPrivateWriterAVFObjC.mm, RTCVideoDecoderVTBAV1.mm); mac (2: NSScrollerImpDetails.h, WebPlaybackControlsManager.h). NOTE: the ~17 mediastream/audio PAL-revert files are "fully-revert ONLY jointly with the out-of-scope PAL soft-link headers."
- **Has-KEEP files:** ~80.
- **CONVERT-only file:** 1 (CertificateInfoCFNet.cpp).
- **UNSURE-dominant files:** ~8.
