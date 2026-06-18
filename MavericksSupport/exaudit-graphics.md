# Exhaustive JUSTIFY-OR-REVERT audit — `Source/WebCore/platform/graphics` (excl. avfoundation/)

Base: upstream `83b24ce`. Build: macOS **26.1 SDK** (`/Users/jonathan/Desktop/MacOSX26.1.sdk`), clang-22, deploy target **10.9**.

## Key build facts that drive verdicts (verified, not guessed)
- Under this build `__MAC_OS_X_VERSION_MAX_ALLOWED` = `__MAC_26_1` (huge), and `__MAC_OS_X_VERSION_MIN_REQUIRED` = `1090`.
- Therefore any guard written `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 10xxxx` is now **always-true** → it compiles the *modern* API path in, which **weak-links to NULL at runtime on 10.9 and crashes**. Such guards are **BROKEN as written** even when their intent (use a 10.9 path) is still needed. These are flagged **KEEP-INTENT / FIX-CONDITION** (re-key on `MIN_REQUIRED` or a runtime `respondsToSelector`/`NSClassFromString`/`NSAppKitVersionNumber` check). They are NOT pure reverts.
- The new vendored `MavericksSupport/legacy-polyfills` archive is **libc/libSystem-level only** (dispatch, os_unfair_lock, objc-runtime, POSIX). It contains **no CoreGraphics/CoreText/CoreMedia high-level API**. So CG/CT call-site swaps are generally **KEEP** (a runtime-absent symbol replaced by a classic API), not CONVERT, unless the symbol is a trivial constant/thin wrapper genuinely worth adding.
- Verified ABSENT-at-runtime-on-10.9 (declared in 26.1 SDK but `API_AVAILABLE` > 10.9, or not declared at all): `CGColorSpaceCreateExtended` (11.0), `CGContextDrawPathDirect` (private/not in SDK), `CTFontShapeGlyphs` (not in SDK), `CTFontCreateForCharactersWithLanguageAndOption` (not in SDK), `IOMainPort` (12.0), `vImageCopyBuffer` (10.10), `CGImageSourceGetPrimaryImageIndex` (10.14), `kCGImagePropertyWebPDictionary` (11.0), `CGContextDrawConicGradient`/`CGShadingCreateConic` (10.12).
- Verified NOW-DECLARED-AND-USABLE in 26.1 SDK (so re-declaration shims are pure REVERT): `kCGColorSpace*` constants, `kCGImageByteOrder32Little`, all `kCTFontTable*` tags.

---

## REVERT (redundant under 26.1 SDK / dead scaffolding / now-provided declaration)

| File | Hunk | Why redundant |
|---|---|---|
| `ImageBuffer.cpp` | `calculateBackendSize` rewritten with `{FILE*_d=((FILE*)0);if(_d){...}}` fprintf blocks | Dead debug scaffolding behind a permanently-null FILE*. Revert to the upstream one-liner. |
| `ImageBufferBackend.cpp` | 3× `{FILE*_d=((FILE*)0);...}` debug prints in `calculateSafeBackendSize` | Dead debug scaffolding (null FILE*). Pure revert. |
| `cg/PDFDocumentImage.cpp` | `drawPDFPage` body replaced with a null-FILE debug print + `(void)context` (PDF page draw skipped) | The Mac path is handled by `mac/PDFDocumentImageMac.mm` (which has a real, kept fix). This `cg/` version is `#if !USE(PDFKIT_FOR_PDFDOCUMENTIMAGE)` and on Mac PDFKit IS used → this hunk is dead code carrying only a disabled debug print. Revert to upstream. (If reachable, the real fix belongs here too — see UNSURE.) |
| `cg/ImageBackingStoreCG.cpp` | `#ifndef kCGImageByteOrder32Little #define (2<<12)` | 26.1 SDK defines `kCGImageByteOrder32Little = (2<<12)` in CGImage.h. Redundant macro. Revert. |
| `cocoa/FontInterrogation.h` | `#ifndef kCTFontTable{STAT,Morx,Mort,GPOS,GSUB,Trak,Fvar} #define …` | All these tags are in 26.1 `CTFont.h`. Pure SDK-declaration gap-fill. Revert all 7. |
| `coretext/FontCoreText.cpp` | `#ifndef kCTFontTableSVG`/`kCTFontTableMATH #define …` | Both tags now in 26.1 `CTFont.h`. Revert the two `#ifndef` blocks (the `unionBitVectors` null-guard and the determinePitch change are separate; see KEEP). |
| `coretext/FontCascadeCoreText.cpp` | added blank line; `RetainPtr{platformData.ctFont()}.get()` → `platformData.ctFont()` | Cosmetic only (whitespace + dropping a redundant RetainPtr wrap). No 10.9 need. Revert to upstream. |
| `coretext/FontCoreText.cpp` | stray extra blank lines in `platformInit` | Whitespace noise. Revert. |
| `GraphicsLayer.cpp` | `#if PLATFORM(COCOA)` → `#if PLATFORM(COCOA) && defined(__OBJC__)` around `<QuartzCore/CALayer.h>` | Build glue, but investigate whether still needed: this guards a non-ObjC TU including an ObjC header. Likely a leftover from the old compat-overlay era. Low-value; lean REVERT unless a `.cpp` (non-`.mm`) TU still includes this on Cocoa (FLAG-light). |
| `angle/GraphicsContextGLANGLE.cpp` | `GLint maxSampleCount;` → `= 0;` init | Trivial uninitialized-var hardening, not 10.9-specific. Harmless but not justified by the target; revert for minimal-divergence (or fold into upstream separately). Borderline — keep only if you want the defensive init. |

---

## CONVERT (works around a missing-on-10.9 C function; could be a real polyfill symbol so the source reverts to upstream)

| File | Call site | Polyfill symbol(s) to add | Impl note |
|---|---|---|---|
| `cg/GraphicsContextCG.cpp` | `drawPathWithCGContext` swaps `CGContextDrawPathDirect(ctx, mode, path, nullptr)` → `CGContextAddPath + CGContextDrawPath` | `CGContextDrawPathDirect` | 10.13+ SPI, no-op stub today, **not in 26.1 SDK**. Thin wrapper: `void CGContextDrawPathDirect(CGContextRef c, CGPathDrawingMode m, CGPathRef p, const CGAffineTransform*){ CGContextAddPath(c,p); CGContextDrawPath(c,m); }` (ignore the transform arg or pre-concat). Lets the source revert. (Otherwise KEEP — current swap is correct.) |
| `cv/VideoFrameCV.mm` | `createBGRA` replaces `vImageCopyBuffer(&src,&dst,4,kvImageDoNotTile)` with a manual row-copy loop | `vImageCopyBuffer` | 10.10+. A straight rowBytes-bounded `memcpy` loop is exactly what the manual code does; could live in the polyfill so the call site reverts. Low priority (single call site). |
| `ca/cocoa/GradientRendererCG.cpp` | conic-gradient manual wedge fan replaces `CGContextDrawConicGradient`/`CGShadingCreateConic` | `CGShadingCreateConic` + `CGContextDrawConicGradient` | 10.12+, absent on 10.9. **Hard to polyfill faithfully** (needs a real conic shading evaluator); the in-tree wedge-fan is a reasonable SW fallback. Treat as KEEP unless someone writes a real conic polyfill. Listed here only as the theoretical CONVERT. |

(The linear-gradient `CGGradientCreateWithColorComponentsAndOptions`→`CGGradientCreateWithColorComponents` swap in the same file is **KEEP** — see below; the AndOptions variant is genuinely absent and the classic one is the correct 10.9 API. Not worth polyfilling just to restore the premultiplied-interpolation option.)

---

## KEEP (each hunk justified; carry a `// MAVERICKS_BACKPORT:` comment with the reason)

### (a) Runtime-absent C function / data symbol on 10.9 → classic-API swap or guard (compiles now, would CRASH if reverted)
- `cg/GradientRendererCG.cpp` — linear path uses `CGGradientCreateWithColorComponents` (AndOptions variant is 10.12+, returns null on 10.9 → all CSS gradients invisible; #30).
- `cocoa/FontCacheCoreText.cpp` — `CTFontCreateForCharactersWithLanguage` instead of `…WithLanguageAndOption` in `lookupFallbackFont` + `prewarm` (AndOption absent → all font fallback dead/tofu; #31). The dropped `fallbackOption` only restricted user-installed fonts.
- `coretext/FontCustomPlatformDataCoreText.cpp` — full CGFont-path `create()` + `stripVariationTablesForLegacyCoreText` (10.9 CoreText can't instance multi-axis variable fonts; #34). Large restored logic; verified behavior fix.
- `coretext/FontCoreText.cpp` — `determinePitch` drops `CTFontCopyAttribute(font, kCTFontUserInstalledAttribute)` (stub→garbage) ⇒ `userInstalled=false`; `applyTransforms` skips `CTFontShapeGlyphs` (10.13+, not in SDK; stub returns CGSize garbage → baseline shift); `unionBitVectors` null-guard (CTFontCopyGlyphCoverageForFeature can return null). All runtime-crash/garbage avoidance.
- `cocoa/FontCacheCoreText.cpp` — `platformInit` drops `kCTFontManagerRegisteredFontsChangedNotification`/`kAXSEnhanceTextLegibilityChangedNotification` observers (stub-as-function used as CFStringRef → crash); the `kCT*Attribute`/`kCTFontFallbackOption*` UNUSED_PARAM hunks (function-stub-as-CFStringRef in CFDictionary/CFSet → hash-callout crash). Keep but see UNSURE re over-broad capability skip.
- `cocoa/SystemFontDatabaseCoreText.cpp` — drop `kCTFontUIFontDesign*` traits pair; `#if 0` the `kCTUIFontTextStyle*` table; default `CTFontDescriptorGetTextStyleSize` (10.10+). Runtime-absent CT constants/functions.
- `cocoa/UnrealizedCoreTextFont.cpp` — skip `appendOpenTypeFeature` (kCTFontOpenTypeFeature{Tag,Value} stub→crash); `#if !PLATFORM(MAC)` around `CTFontGetAccessibilityBoldWeightOfWeight` (10.13+). Runtime-absent.
- `cg/GraphicsContextCG.cpp` — `CGContextDrawPathDirect`→`AddPath/DrawPath` (also a CONVERT candidate; KEEP as-is otherwise).
- `cg/PathCG.cpp` — gate `CGPathAddUnevenCornersRoundedRect` behind `… && __MAC_OS_X_VERSION_MIN_REQUIRED >= 101300` (10.13+ no-op stub on 10.9; #25). **Correctly keyed on MIN_REQUIRED** → safe under new SDK.
- `mac/GraphicsChecksMac.cpp` — `IOMainPort` (12.0+) replaced with `mainPort = 0` (kIOMasterPortDefault). Runtime-absent.
- `mac/LegacyDisplayRefreshMonitorMac.cpp` — `CVDisplayLinkGetNominalOutputVideoRefreshPeriod` stub returns garbage CVTime → return 60. Keyed on `PLATFORM(MAC)`; runtime-correct.
- `cocoa/CMUtilities.mm` — `CMSampleBufferCreateReady`(10.10+)→`CMSampleBufferCreate(…,dataReady=true,…)`; defines `isOpus/VorbisDecoderAvailable()=false`. Behavior + runtime-absent.
- `cv/VideoFrameCV.mm` — manual row-copy for `vImageCopyBuffer` (also CONVERT candidate).
- `ca/cocoa/GradientRendererCG.cpp` conic block — `#if … __MAC_OS_X_VERSION_MIN_REQUIRED < 101200` SW wedge-fan (correctly keyed on MIN). KEEP (or CONVERT).

### (b) Runtime-absent ObjC selector / class / AppKit behavior → guard (cannot be a C polyfill)
- `ca/cocoa/PlatformCAAnimationCocoa.mm` — `CASpringAnimation` (10.11+) via `NSClassFromString` + KVC `setValue:forKey:` for mass/stiffness/damping/initialVelocity.
- `ca/cocoa/PlatformCALayerCocoa.mm` — `NSClassFromString(@"AVPlayerLayer"/@"CABackdropLayer")`; `setWindowServerAware:`/`setContents:`/`contentsScale`/`contents` `respondsToSelector` guards; skip `kCACornerCurveCircular` (10.13+). The TransformLayer→CALayer fallback + actions-dict + avPlayerLayer stub are **behavior fixes (d)/feature-disable** — see (d)/UNSURE.
- `mac/ColorMac.mm` — `-[NSGraphicsContext CGContext]`(10.10+) → `-graphicsPort` (restores `colorFromCocoaColor`; #fix purple Top Sites title).
- `mac/ScrollbarTrackCornerSystemImageMac.mm`, `mac/controls/{ControlMac,ControlFactoryMac,InnerSpinButtonMac,ProgressBarMac,SwitchMacUtilities,SwitchThumbMac,SwitchTrackMac,WebControlView}.mm` — `+[NSAppearance currentDrawingAppearance]` (10.14+) and `_drawInRect:context:options:`, `_setSemanticContext:`, `setCenteredLook:` guarded via `respondsToSelector`. Runtime-absent SPI.
- `mac/controls/{ButtonControlMac,ControlMac,ToggleButtonMac}.mm` — `_setHighlighted:animated:`/`_setState:animated:`/`_stateAnimationRunning` (10.10+ NSButtonCell SPI) guarded.
- `mac/controls/ControlMac.mm` — `NSWorkspace accessibilityDisplay…` category + `respondsToSelector`; `NSAppKitVersionNumber >= 1343` gate on `drawCellFocusRing`. Runtime-absent + black-box behavior (#33).
- `cocoa/GraphicsContextCocoa.mm` — `drawFocusRing`: on `NSAppKitVersionNumber < 1343` draw a plain stroked ring (NSInitializeCGFocusRingStyleForTime struct mismatch → solid-black flood; #33).
- `mac/PDFDocumentImageMac.mm` — `respondsToSelector:@selector(drawWithBox:toContext:)` (10.13+) else fall to `pageRef`+`CGContextDrawPDFPage`. Runtime-absent SPI.
- `cocoa/MediaPlayerPrivateWebM.mm`, `cocoa/CMUtilities.mm`, `cv/ImageTransferSessionVT.mm`, `cv/VideoFrameCV.mm` — `PAL::CMxxx`→`CMxxx` direct linkage (drop PAL soft-link wrappers). Build/link glue for this target; behavior-preserving. KEEP (could also be considered cosmetic but is load-bearing for linking against the real 10.9 CoreMedia without PAL's soft-link tables).

### (c) Restored / reimplemented lost-or-gutted upstream source (added so things link / a feature works)
- `cocoa/IOSurface.mm` — 188-line functional minimal IOSurface wrapper (alloc, mach port, createImage via `CGBitmapContextCreateImage`, createFromImage). Load-bearing for layer backing store; overrides a broken libpolyfill `createImage` stub.
- `cocoa/SourceBufferParserISOBMFF.{h,cpp}` (new, 1087+86 lines) + `SourceBufferParser.{h,cpp}` wiring — SW fragmented-MP4 MSE parser replacing AVStreamDataParser/WebM (absent on 10.9). Feature enabler.
- `coretext/FontCustomPlatformDataCoreText.cpp` — (also (a)) restored create() path.
- `cocoa/FontCascadeCocoa.cpp`, `mac/{FloatPointMac,FloatSizeMac,ImageMac,IntPointMac,IntSizeMac}.mm` — new 1-line `#include "config.h"` TUs (empty translation units to satisfy the source list where upstream inlined or relocated symbols). Build glue; harmless. KEEP (or remove from source lists — minor).
- `mac/SwitchingGPUClient.h`, `cocoa/MediaPlaybackTargetContext.h` — 1-line stub headers so includers compile. Build glue.

### (d) Genuine behavior / bug fixes (target-independent or 10.9-runtime-rooted)
- `FontCascade.cpp` — route shaping/kerning runs to the Complex path on `PLATFORM(MAC)` (simple path can't shape without CTFontShapeGlyphs → ligature icon fonts blank). Pairs with FontCoreText.cpp shaping skip.
- `graphics/SourceBufferPrivate.cpp` — synchronous inline `iterateTrackBuffers([](tb){tb.reset();})` instead of async `resetTrackBuffers()` (async marshal never runs before loop restart → 100% CPU / GB RSS / frozen video). Real concurrency bug fix.
- `ImageFrameWorkQueue.cpp` — decoder QoS Default→UserInitiated (multi-second lazy-image stalls on CPU-limited VM; #27).
- `ImageDecoder.cpp` — pass `ProcessIdentity{CurrentProcess}` to `ImageDecoderAVFObjC::create` (signature alignment). KEEP (matches the restored AVFObjC signature; build correctness).
- `angle/GraphicsContextGLANGLE.cpp` — debug-callback null/negative-length guard (KHR_debug allows length<0 → SIZE_MAX span → CString crash on Maps/Twitch); `GL_ReadnPixelsRobustANGLE`→`GL_ReadPixelsRobustANGLE` ×2 (CGL backend lacks GL_*_robustness the "n" variant requires). Real crash/feature fixes for the CGL backend.
- `ca/TileController.cpp` + `ca/TileGrid.cpp` — guard zero IOSurface max-size → divide-by-zero. Defensive but real (uninitialized `maximumIOSurfaceSize` on the legacy WK2 path).
- `WOFFFileFormat.cpp` — force `HAVE_WOFF_SUPPORT 0` so the in-tree WOFF/WOFF2 decoder runs (10.9 CGFont can't decode wOF2 → missing icon/web fonts).
- `cocoa/FontCacheCoreText.cpp` + `coretext/FontCoreText.cpp` — the `PLATFORM(MAC)` "warm-up draw a probe glyph" blocks (absorb the bad first-draw clipping of fallback glyphs). 10.9-rooted rendering bug fix.
- `cocoa/PlatformCALayerCocoa.mm` + `cocoa/WebCoreCALayerExtras.mm` — actions-dict instead of `WebActionDisablingCALayerDelegate` (stale-delegate CA crash on 2nd nav); real `_web_renderLayerWithContextID` via CALayerHost (prior stub painted blank). CA-compositing fixes (#56 cluster). NOTE the gutted hit-test helpers (`collectDescendantLayersAtPoint`/`layersAtPointToCheckForScrolling` → empty, `_web_maskContainsPoint`→YES) are **feature-disables** → UNSURE.

### (e) Build-system glue for the 10.9 / Safari-7 target
- `cocoa/ANGLEUtilitiesCocoa.mm` + `cocoa/GraphicsContextGLCocoa.mm` — `WK_ANGLE_METAL`/`WK_WEBGL_METAL_BACKEND` gating (Metal is 10.11+; this build uses ANGLE's CGL/OpenGL backend). Includes: `platformIsANGLEAvailable()`→true (ANGLE statically linked); per-thread `currentContextThread` re-bind (rotating-worker main thread); CGL EGL display attrs (omit Metal-only power/device-id attrs that made `eglGetPlatformDisplay` reject the list → WebGL null); `GL_ANGLE_texture_rectangle` enable for the IOSurface-backed rect texture; Metal-shared-event paths stubbed. Extensive but coherent CGL-backend glue. KEEP. (One pre-existing oddity: the `cp_proxy_…get_metal_maps`/`…descriptors` SOFT_LINK signatures were edited to `NSArray *>*` / `NSArray **` — looks like a generics-strip artifact; FLAG-light, verify it compiles.)
- `cocoa/TransformationMatrixCocoa.cpp` — `simd_float4x4` built via `memcpy` into `.columns[]` instead of the aggregate initializer. Compiler/ABI workaround for simd init on this toolchain. KEEP (build glue) — low-risk, but could REVERT if the aggregate init compiles under clang-22 (FLAG-light).
- `cocoa/WebCoreDecompressionSession.h` — include real CM/CV/VT headers + `CMTaggedBufferGroupRef` fallback typedef instead of forward typedefs (avoids conflicting redeclarations against the modern SDK). KEEP build glue.

### Feature-disable stub-outs (gutted to `// Stubbed … #include "config.h"`) — KEEP as build-glue feature exclusions, BUT several flagged below
KEEP (genuinely unavailable on 10.9, AV/Metal/CoreMaterial-era): `cocoa/VideoMediaSampleRenderer.mm`, `cocoa/WebCoreDecompressionSession.mm`, `cocoa/VP9UtilitiesCocoa.mm`, `cocoa/HEVCUtilitiesCocoa.mm`, `cocoa/H264UtilitiesCocoa.mm`, `cocoa/WebMAudioUtilitiesCocoa.mm`, `graphics/MediaSampleConverter.cpp` (CoreMedia PAL soft-link mismatch), `graphics/PlatformPlaybackSessionInterface.h` (minimal RefCounted stub), `cocoa/WebSampleBufferVideoRendering.h`, `mac/AppKitControlSystemImage.mm` (currentDrawingAppearance/tintColor 10.14+).
Config-guard companions (KEEP): `graphics/MediaPlayer.cpp` (drop MediaPlayerPrivateWebM registration — libwebm absent), `cocoa/PlatformMediaEngineConfigurationFactoryCocoa.cpp` (VP9 gating — but condition is MAX_ALLOWED, see UNSURE).

---

## UNSURE / FLAG (needs human judgment)

1. **`#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 10xxxx` guards are now always-true → BROKEN on 10.9 at runtime.** Intent is right, condition is wrong. Re-key each on `__MAC_OS_X_VERSION_MIN_REQUIRED` (= 1090) or a runtime check. Affected:
   - `DestinationColorSpace.cpp` (`CGColorSpaceCreateExtended`, 11.0) — currently `>= 101200` → now compiles the call in → **runtime NULL/crash on 10.9**.
   - `cg/ColorSpaceCG.cpp` — the `#ifndef kCGColorSpace*` redeclarations are pure REVERT (SDK has them), BUT the `#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101200` around `CGColorSpaceCreateExtended` in `extendedColorSpace<>()` is the same always-true bug → calls an 11.0 API on 10.9. Fix condition (MIN) or keep a runtime fallback.
   - `cg/ImageDecoderCG.cpp` — `kCGImagePropertyWebPDictionary` (`>=101300`) and `CGImageSourceGetPrimaryImageIndex` (`>=101400`) guards are now always-true → WebP dict access + primaryImageIndex (10.14) called on 10.9. (The `createImageSourceOptions` CFSTR-literal swap is a separate KEEP/CONVERT — see #3.) Fix conditions to MIN.
   - `cocoa/FontCacheCoreText.cpp` — `variationAxesWithNonLocalizedAxesNames` guard `>= 101300` → `kCTFontVariationAxesAttribute` (10.13) accessed on 10.9. Fix to MIN.
   - `cocoa/WebActionDisablingCALayerDelegate.h` — `>= 101200` selects the `<CALayerDelegate>` conformance; now always-true (fine, since the delegate is no longer installed — see PlatformCALayerCocoa). But it's a no-op guard now; either revert to plain upstream or re-key. Low risk.
   - `cocoa/PlatformMediaEngineConfigurationFactoryCocoa.cpp` — `ENABLE(VP9) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300` now always-true → `kCMVideoCodecType_VP9` referenced. Constant likely exists in SDK so it compiles; but it advertises VP9 support that 10.9 VideoToolbox can't decode. Re-key on MIN or `ENABLE(VP9)` gating consistent with the stubbed VP9 utilities.
   - `cv/GraphicsContextGLCVCocoa.mm` — the two `#if defined(MAC_OS_X_VERSION_10_13) && MAC_OS_X_VERSION_MAX_ALLOWED >= 101300` blocks excluding 10-bit HDR `kCVPixelFormatType_*10*` cases: now always-true → those case labels compile back in. The constants exist in the SDK so it compiles, and they're just `switch` labels (harmless if the format never occurs on 10.9), but the guard no longer does what it says. Decide: revert (harmless) or re-key.
   - `ANGLEUtilitiesCocoa.mm` / `GraphicsContextGLCocoa.mm` `WK_*_METAL` macros key on `MAC_OS_X_VERSION_MAX_ALLOWED >= 101100` → now always-true → **Metal backend would be selected**, contradicting the CGL-only intent. This is the most serious: if these flip to 1 under the 26.1 SDK, the whole WebGL backend switches to Metal (unavailable on 10.9). MUST re-key on `MIN_REQUIRED` (or a hard `0`). HIGH priority.

2. **`cg/ImageDecoderCG.cpp` `createImageSourceOptions`** — replaces real `kCGImageSource*` constant keys with `CFSTR("kCGImageSourceShouldCache")` literals (comment blames the *old* libpolyfill xorl-stub). Under the new build the real constants are in the SDK and link to real ImageIO globals at runtime on 10.9 (these keys existed since 10.4). The literal-string workaround is likely now **REVERTABLE** to the real constants — verify the constants resolve at runtime on 10.9 (they should). FLAG for a quick A/B.

3. **CoreImage SVG-filter appliers gutted** — `coreimage/FEBlendCoreImageApplier.mm`, `FEDisplacementMapCoreImageApplier.mm`, `FEOffsetCoreImageApplier.mm` stubbed to empty TUs. CIFilter exists on 10.9; these SVG filter effects could plausibly work. The gutting may be over-broad (disables `feBlend`/`feDisplacementMap`/`feOffset` accelerated paths). Verify whether the CoreImage applier path even runs on this build (it may be gated off elsewhere) before accepting the disable.

4. **`cocoa/PlatformTimeRangesCocoa.mm` gutted** — just CMTimeRange math (`PlatformTimeRanges` ↔ CoreMedia), CoreMedia is present on 10.9. Likely buildable; the empty stub may silently break `<video>.buffered`/seekable range reporting. Verify it's not needed.

5. **`cocoa/WebCoreCALayerExtras.mm` hit-test helpers gutted** — `collectDescendantLayersAtPoint`→no-op, `layersAtPointToCheckForScrolling`→`{}`, `_web_maskContainsPoint`/`_web_maskMayIntersectRect`→`YES`. These feed scrolling hit-testing; returning YES/empty is a correctness compromise (UI-process scroll hit-test). Confirm acceptable vs the #56 compositing cluster.

6. **`cocoa/FontCacheCoreText.cpp capabilitiesForFontDescriptor`** — early-returns hardcoded default weight/width/slope, skipping ALL variation-capability introspection. Broad; may regress `font-weight`/`font-stretch` matching on installed fonts. The crash it avoids is real, but verify the blast radius vs a narrower guard.

7. **`PlatformCALayerCocoa.mm` TransformLayer→CALayer + `updateContentsFormat` skip + `avPlayerLayer()` stub** — feature-disables (loses 3D `preserve-3d` compositing, contents-format selection, AVPlayerLayer). Tracked under #56/media; confirm these are still desired given any compositing keystone work.

8. **`mac/controls/ProgressBarMac.mm` manual CG progress bar** (when `currentDrawingAppearance` absent) — a real fallback (not a stub). KEEP, but note it diverges visually from native; fine for 10.9.

---

## Counts
- Files changed in scope: **89** (87 tracked-modified + new files).
- **REVERT (pure):** ~10 hunks across ~8 files (debug-fprintf scaffolding ×2 files, `kCGImageByteOrder32Little` macro, FontInterrogation 7 tags, FontCoreText 2 tags, whitespace/RetainPtr cosmetic ×2, PDFDocumentImage cg debug-skip, GraphicsLayer `__OBJC__`, ANGLE maxSampleCount-init [borderline]).
- **CONVERT:** **3** candidates (`CGContextDrawPathDirect`, `vImageCopyBuffer`, theoretical `CGShadingCreateConic`) — only the first is clearly worth doing.
- **KEEP:** the large majority — ~70 files have at least one justified KEEP hunk (runtime-absent symbol/selector, restored source, behavior fix, or CGL/feature build glue).
- **UNSURE/FLAG:** **8 clusters**, dominating concern = the **`__MAC_OS_X_VERSION_MAX_ALLOWED >=` always-true guards** (≥8 files, esp. the WebGL Metal-backend macros and `CGColorSpaceCreateExtended`) which are now logically inverted and need re-keying to `MIN_REQUIRED`.

### Files that are FULLY revertable (no KEEP hunk)
- `ImageBuffer.cpp` (debug only)
- `ImageBufferBackend.cpp` (debug only)
- `cocoa/FontInterrogation.h` (SDK-provided tags only)
- `cg/ImageBackingStoreCG.cpp` (SDK-provided macro only)
- `coretext/FontCascadeCoreText.cpp` (cosmetic only)
- `cg/PDFDocumentImage.cpp` (dead/disabled debug path; real Mac fix lives in PDFDocumentImageMac.mm) — revert pending UNSURE#? (confirm `cg/` path unreachable on Mac)

All other changed files contain at least one KEEP hunk (mixed files).
