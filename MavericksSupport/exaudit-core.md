# Exhaustive JUSTIFY-OR-REVERT audit — WebCore core dirs vs upstream 83b24ce

Scope: Source/WebCore/{dom,rendering,html,loader,page,editing,bindings,style,Modules,workers,accessibility,css,svg} + crypto.
Build context: macOS 26.1 SDK + clang-22, deploy target 10.9, vendored polyfill archive (force-loaded). gcrypt is the WebCrypto backend (USE_GCRYPT=TRUE); the cocoa CommonCrypto/CryptoKit crypto path is NOT built.

Verdict legend: REVERT (SDK-compile gap-fill / dead scaffolding / unbuilt-file edit / generics-strip / orphan) · CONVERT (missing-on-10.9 C symbol → polyfill) · KEEP (concrete runtime/ABI/behavior/build reason) · FLAG (keystone hack-cluster band-aid; KEEP+FLAG) · UNSURE.

---

## crypto/  (audited directly)

KEYSTONE FINDING: The backport's WebCrypto runs on **libgcrypt** (`crypto/gcrypt/*`, USE_GCRYPT=TRUE in OptionsMac.cmake). Only TWO cocoa crypto files are compiled (per SourcesCocoa.txt): `CryptoKeyCocoa.cpp` and `CryptoUtilitiesCocoa.cpp`. All other `crypto/cocoa/*Cocoa.cpp` files are NOT in any sources list → never compiled. The backport filled their upstream `#else /* RELEASE_ASSERT_NOT_REACHED */` stubs with an implementation referencing `pal::ECKey109`, a type **defined nowhere in the tree** — it would not even compile if built. (`CLANG_WEBKIT_BRANCH` is an upstream clang-branch macro, defined in this build; upstream already stubs cocoa crypto under it.)

### REVERT — dead scaffolding in NOT-BUILT cocoa crypto files (11 files)
| File | Verdict | Reason |
|---|---|---|
| crypto/cocoa/CryptoKeyECCocoa.cpp | REVERT | Not built (gcrypt backend). 17 refs to undefined `pal::ECKey109` — would not compile. Dead. |
| crypto/cocoa/CryptoAlgorithmECDHCocoa.cpp | REVERT | Not built. 2 refs to undefined `pal::ECKey109`. Dead. |
| crypto/cocoa/CryptoKeyOKPCocoa.cpp | REVERT | Not built. Dead `#else`-stub fill. |
| crypto/cocoa/CryptoKeyRSACocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmECDSACocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmEd25519Cocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmHKDFCocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmHMACCocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmX25519Cocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmAESGCMCocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmAESKWCocoa.cpp | REVERT | Not built. Dead. |
| crypto/cocoa/CryptoAlgorithmPBKDF2Cocoa.cpp | REVERT | Not built. Dead. |

### KEEP — built crypto files + build glue + behavior
| File | Verdict | Reason |
|---|---|---|
| crypto/cocoa/CryptoKeyCocoa.cpp | KEEP (c) | BUILT. CryptoKey::randomData uses `gcry_randomize` instead of `CCRandomGenerateBytes`, consistent with the gcrypt backend (same RNG as rest of stack). Real behavior. |
| crypto/cocoa/CryptoUtilitiesCocoa.cpp | KEEP (a/c) | BUILT (used by WebRTC SFrame transformer). `#if PLATFORM(MAC)` hand-rolled RFC-5869 HKDF via CCHmac because `CCKDFParametersCreateHkdf`/`CCDeriveKey` are 10.10+; the polyfill stub returns kCCSuccess but leaves the buffer untouched → silently wrong derived key. Genuine runtime-absence + behavior fix. |
| crypto/keys/CryptoKeyEC.h | KEEP (d) | `#if OS(DARWIN) && !PLATFORM(GTK) && !USE(GCRYPT)` selects the gcrypt PlatformECKeyContainer; build glue for the gcrypt WebCrypto backend. Reverting breaks the gcrypt key-container type. |
| crypto/keys/CryptoKeyRSA.h | KEEP (d) | Same `!USE(GCRYPT)` guard skipping the cocoa CCRSACryptor path. Build glue. |

### KEEP+FLAG-minor — SHA-224 graceful-fail (de-assert behavior change)
These turn upstream's deliberate `RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE(sha224DeprecationMessage)` into graceful JS failure so a site requesting SHA-224 can't crash the tab. Real behavior/crash-avoidance fix, BUT it diverges from upstream intent (upstream deliberately removed SHA-224 from the WebCrypto spec and wants the trap). Low-risk; flag as a policy choice, not an SDK gap.
| File | Verdict | Reason |
|---|---|---|
| crypto/CommonCryptoUtilities.cpp | KEEP+FLAG-minor | SHA-224 → return false instead of assert. |
| crypto/SubtleCrypto.cpp | KEEP+FLAG-minor | SHA-224 → NotSupportedError instead of assert. |
| crypto/algorithms/CryptoAlgorithmHMAC.cpp | KEEP+FLAG-minor | SHA-224 graceful-fail. |
| crypto/algorithms/CryptoAlgorithmRSA_OAEP.cpp | KEEP+FLAG-minor | SHA-224 graceful-fail. |
| crypto/algorithms/CryptoAlgorithmRSA_PSS.cpp | KEEP+FLAG-minor | SHA-224 graceful-fail. |
| crypto/gcrypt/GCryptUtilities.cpp | KEEP+FLAG-minor | SHA-224 → nullopt/empty (gcrypt path, BUILT). |
| crypto/gcrypt/CryptoAlgorithmHMACGCrypt.cpp | KEEP+FLAG-minor | SHA-224 → GCRY_MAC_NONE (gcrypt path, BUILT). |

(The SHA-224 hunk inside CryptoUtilitiesCocoa.cpp is part of that KEEP file above.)

---

## dom/  +  bindings/

### REVERT (fully — dead `(FILE*)0` debug scaffolding / no-op refactors, task #63)
| File | Reason |
|---|---|
| bindings/js/JSCustomElementInterface.cpp | 3 dead `(FILE*)0` debug blocks; never run. |
| bindings/js/JSDOMExceptionHandling.cpp | 1 dead `(FILE*)0` block. |
| dom/DecodedDataDocumentParser.cpp | only "removed debug fopen logging" comment markers. |
| dom/EventLoop.cpp | comment markers + no-op local refactor. |
| dom/LoadableClassicScript.cpp | 1 dead `(FILE*)0` block. |
| dom/LoadableScript.cpp | 1 dead `(FILE*)0` block. |
| dom/PendingScript.cpp | 4 dead `(FILE*)0` blocks. |
| dom/ScriptRunner.cpp | 2 dead `(FILE*)0` blocks. |
| dom/TreeScope.cpp | 1 dead `(FILE*)0` block. |
| dom/CustomElementRegistry.cpp | entire diff is dead instrumentation/counters; upstream logic unchanged. |

### REVERT (partial — debug hunks only; file has KEEP hunks too)
| File | Reason |
|---|---|
| bindings/js/ScriptController.cpp | 2 `(FILE*)0` eval-logging blocks (canExecuteScripts hunk is KEEP+FLAG). |
| dom/Document.cpp | comment markers + an unused `released` local in destroyRenderTree. |
| dom/ScriptElement.cpp | `(FILE*)0` blocks + `JSCE_LOG_EXIT` no-op macro + `int phase` tracking (beforeload hunks are KEEP). |

### KEEP
| File | Verdict | Reason |
|---|---|---|
| dom/BeforeLoadEvent.cpp/.h/.idl | KEEP (e) | Restored lost-upstream file (deleted in bug 234804); drives Safari-7 extension content-blocking `beforeload` event (uBlock network blocking, #62). |
| dom/EventInterfaces.in | KEEP (e) | Registers BeforeLoadEvent interface — build glue for the above. |
| bindings/js/WebCoreBuiltinNames.h | KEEP (e) | `macro(BeforeLoadEvent)` registration. |
| dom/Node.cpp/.h | KEEP (b/e) | Restored `Node::dispatchBeforeLoadEvent`; 8 verified callers. Safari-7 ABI/behavior. |
| dom/ScriptElement.cpp (2 hunks) | KEEP (b) | dispatchBeforeLoadEvent in requestClassic/ModuleScript — extension blocking. |
| dom/Document.cpp (3 hunks) | KEEP (b) | beforeload ListenerType add; haveStylesheetsLoaded rewrite now matches upstream (de-hacks #50). |
| dom/Document.h (BeforeLoad enum) | KEEP (b) | `BeforeLoad = 1<<14` ListenerType. |
| dom/ElementInlines.h | KEEP (c) | null-guard findAttributeByName result before ->value(); real NULL-deref fix. |
| dom/ScriptExecutionContext.cpp | KEEP (c) | raw `JSC::VM*` vs RefPtr to avoid transient ref/deref (media-controls crash). Low-risk. |
| dom/QualifiedNameCache.cpp | KEEP (a/c) | `#if PLATFORM(MAC)` Lock around shared process-wide cache; concurrent-rehash double-free fix. |
| bindings/scripts/CodeGeneratorJS.pm | KEEP (d) | inline `sub uniq` — build-host Perl List::Util 1.25 lacks `uniq` (added 1.26). Build glue. |
| bindings/scripts/preprocessor.pm | KEEP (d) | robustifies $ENV{ARCHS}/-target handling for this Xcode env. Build glue. |

### KEEP+FLAG (keystone hack-cluster band-aids)
| File | Keystone | Reason |
|---|---|---|
| dom/Document.h visualUpdatesAllowed()=return true | #50/#53/#55 | Hardcode masks suppression-timer never firing. |
| dom/Document.cpp removeAudioProducer | #54 main-thread-identity | RELEASE_ASSERT(isMainThread) → early-return. |
| dom/EventListenerMap.h | #54 | releaseAssertOrSetThreadUID gutted to return. |
| dom/TreeScopeOrderedMap.cpp | #54/#40 | RELEASE_ASSERT_WITH_SECURITY_IMPLICATION → silent bail. |
| dom/WindowEventLoop.cpp | (#54-adjacent, proper) | RELEASE_ASSERT(isMainThread) → real Lock around shared map. (Closer to a proper fix; flag.) |
| bindings/js/ScriptController.cpp canExecuteScripts (1 hunk) | #54-adjacent | null-bail + RELEASE_ASSERT(isScriptAllowed)→return false. |

### CONVERT-eligible but recommend KEEP
| File | Symbols | Note |
|---|---|---|
| bindings/js/SerializedScriptValue.cpp | `CGColorSpaceGetName` (10.10+), `CGColorSpaceCreateWithPropertyList` (10.12+) | Runtime-absent; current sRGB fallback is correct degradation. Polyfill can't reproduce CG-internal colorspace serialization → KEEP. Cleanup nit: the `if (false){...}` dead block should be a clean `#if`/early-return. |

---

## rendering/  +  svg/

### REVERT
| File | Reason |
|---|---|
| rendering/cocoa/DrawGlyphsRecorder.h | ADDED orphan duplicate of platform/graphics/coretext/DrawGlyphsRecorder.h (the canonical, in SourcesCocoa.txt). Never referenced. Delete. |
| rendering/GlyphDisplayListCache.cpp | `return nullptr` disables ALL glyph display-list caching b/c DrawGlyphsRecorder uses `CGContextDelegateSetCallback` (10.10+). Over-broad; better a polyfill (CONVERT-candidate) than gutting the cache. Re-eval. |
| rendering/RenderTheme.cpp | whitespace only. |
| rendering/updating/RenderTreeUpdater.cpp | one blank line. |
| rendering/RenderBlock.cpp | dead `(FILE*)0` + unused `int n` + comment markers. |
| rendering/RenderLayer.cpp | dead `(FILE*)0` + comment markers. |

### KEEP
| File | Verdict | Reason |
|---|---|---|
| rendering/mac/RenderThemeMac.mm | KEEP (a/c) | respondsToSelector guards on currentDrawingAppearance (10.14+), systemPurple/Red/Blue/secondaryLabel (10.10+/10.14+, throw at runtime — #75/#77), classic NSBackgroundStyleDark/graphicsPort substitutions, hardcoded selection colors (selection-paints-black fix). [nit: gratuitous NODELETE/whitespace noise could revert-in-place.] |
| rendering/cocoa/RenderThemeCocoa.mm | KEEP (a/c) | NSDateComponentsFormatter is 10.10+ (#if fallback); progress-bar interval crash-avoidance. |
| rendering/BorderPainter.cpp | KEEP (c) | clip-then-fill because bare CGContextFillRect drops thin border strips on 10.9 (#25-adjacent). |
| rendering/TextDecorationPainter.cpp | KEEP (c) | skips SkipInk CTFontCreatePathForGlyph underline path that corrupts next CTFontDrawGlyphs on 10.9. |

### KEEP+FLAG (keystones)
| File | Keystone | Reason |
|---|---|---|
| svg/graphics/SVGImage.cpp | #56 | rasterize-SVG-to-bitmap b/c CGContextFillPath fails on IOSurface-backed CALayer; + libxml2 chunked-parse crash fix. (view->paint line is noise.) |
| rendering/svg/RenderSVGRoot.cpp | #56 | same IOSurface rasterize-then-drawImageBuffer. |
| rendering/svg/legacy/LegacyRenderSVGRoot.cpp | #56 | same in paintReplaced. |
| rendering/RenderLayerCompositor.cpp | #55/#56 | frameViewDidScroll forces updateScrollLayerPosition + manual scrollbar offsetDidChange (async coordinator doesn't propagate). [+ revert-able debug comments.] |
| rendering/RenderBox.cpp | #50/#56 (UNSURE) | magic margin floor for large h1-h6 headings (glyph-below-line-box). Suspicious band-aid; root-cause then revert. |

### REVERT? — build-glue circular-include cluster (revert as a unit; FLAG: not build-verified)
| File | Reason |
|---|---|
| rendering/RenderTheme.h | `!defined(RENDERTHEMECOCOA_BEING_INCLUDED)` cycle guard. |
| rendering/cocoa/RenderThemeCocoa.h | the `#define/#undef RENDERTHEMECOCOA_BEING_INCLUDED` wrapper. |
| rendering/mac/RenderThemeMac.h | `__has_include` relative include that introduces the cycle. |
Generated forwarding header exists, so upstream `<WebCore/...>` includes should work → likely revert all 3 together.

---

## html/  +  loader/

### REVERT
| File | Reason |
|---|---|
| html/parser/HTMLDocumentParser.cpp | all 35 lines dead `(FILE*)0` instrumentation. (#35 fix lives elsewhere.) |
| html/parser/HTMLScriptRunner.cpp | all 29 lines dead `(FILE*)0`. |
| html/parser/HTMLMetaCharsetParser.cpp | no-op refactor + comment markers. |
| html/parser/HTMLConstructionSite.cpp | dead `(FILE*)0` + log-only local. |
| loader/ResourceLoader.cpp | dead `(FILE*)0` loadDataURL trace + blank line. |
| loader/TextResourceDecoder.cpp | comment markers only. |
| loader/DocumentLoader.cpp | dead `(FILE*)0` + comment markers. |
| html/HTMLPlugInElement.cpp | cosmetic brace-wrap only. |
| html/OffscreenCanvas.idl | drops EnabledBySetting=OffscreenCanvasEnabled (setting doesn't exist); bindings-gen gap, restore setting not delete gate. |
| html/canvas/OffscreenCanvasRenderingContext2D.idl | same EnabledBySetting strip. |

### KEEP
| File | Verdict | Reason |
|---|---|---|
| html/HTMLEmbedElement.cpp | KEEP (c) | #38 Web Clips: gate invalidateStyleAndRenderersForSubtree to actual type/src/code changes (Dashboard -apple-dashboard-region re-stamp). |
| html/HTMLMediaElement.cpp | KEEP (c) | media backport (#35/#67/#75): un-stub play/createMediaPlayer for custom MSE+AVFoundation; mediaSessionIfExists null-guards (real SEGV); beforeload on media URLs. |
| html/HTMLLinkElement.cpp | KEEP (c) | cancelable beforeload (uBlock #62). [strip one dead `(FILE*)0` block.] |
| loader/ImageLoader.cpp | KEEP (c) | restores image beforeload (extension blocking). |
| loader/archive/cf/LegacyWebArchiveMac.mm | KEEP (a) | initForReadingFromData:/decodingFailurePolicy/initRequiringSecureCoding:/encodedData are 10.13+ runtime-absent (#76); legacy fallback. |
| html/parser/HTMLParserOptions.cpp | KEEP (c) | re-enable usePreHTML5ParserQuirks for .wdgt file URLs (#38), scoped to widgets. |
| html/canvas/GPUCanvasContextCocoa.mm | KEEP (d) | 615-line gut: WebGPU OFF on Mac (ENABLE_WEBGPU OFF, GPU_PROCESS OFF); Metal/GPU-process plumbing non-functional on 10.9. Build glue. [verify link of GPUCanvasContext::create symbol in #84.] |
| html/canvas/CanvasRenderingContext2DBase.cpp | KEEP (c) | fillText baseline cap-height shift — 10.9 CTFontDrawGlyphs position-origin divergence. |
| loader/cache/CachedResourceRequest.cpp | KEEP (c) | drop image/webp from Accept (no WebP decoder in this build). |

### KEEP+FLAG (keystones)
| File | Keystone | Reason |
|---|---|---|
| loader/cache/MemoryCache.cpp | #54 | relaxes RELEASE_ASSERT(isMainThread) across ~40 methods. |
| loader/cache/CachedResource.cpp | #54 | isMainThread early-outs skipping MemoryCache touch. |
| loader/cache/CachedResourceLoader.cpp | #53 | disables m_garbageCollectDocumentResourcesTimer (corrupt timer heap). [+ revert-able debug comments.] |
| loader/ProgressTracker.cpp | #53 | disables m_progressHeartbeatTimer.startRepeating(). |
| loader/FrameLoader.cpp | #54 + #62 | checkCompleted thread-bounce (FLAG) + subframe beforeload (KEEP). [+ dead `(FILE*)0`.] |
| html/parser/HTMLTreeBuilder.cpp | (#54-adjacent) | guards dangling m_parser WeakRef after EOF destroys parser. |

---

## page/  +  editing/

### REVERT
| File | Reason |
|---|---|
| page/writing-tools/WritingToolsController.mm | pure generics-strip `NSDictionary<...>*`→`NSDictionary*`; SDK declares it. |
| page/scrolling/mac/ScrollerPairMac.mm | cosmetic nil→nullptr on a RetainPtr. |
| page/FrameDestructionObserver.h | dropped `inline` to dodge -Wundefined-inline; scaffolding. |
| page/LocalFrame.cpp | orphan "removed debug fopen logging" comment only. |
| page/ContextMenuController.cpp (hunk 1) | whitespace blank-line removal (other hunks KEEP). |

### KEEP
| File | Verdict | Reason |
|---|---|---|
| page/mac/WheelEventDeltaFilterMac.mm | KEEP (a) | _NSScrollingPredominantAxisFilter doesn't respond to filterInputDelta:... at runtime on 10.9 → crash per wheel event; respondsToSelector guard. |
| page/scrolling/mac/ScrollerMac.mm | KEEP (a) | currentDrawingAppearance (10.14+) respondsToSelector guards (#77). |
| page/scrolling/mac/ScrollingTreeMac.mm | KEEP (a) | CATransaction addCommitHandler:forPhase: (10.10+) throws on class on 10.9; guard. |
| page/scrolling/mac/ScrollingTreeScrollingNodeDelegateMac.mm/.h | KEEP (c) | #55/#39 active-gesture tracking → smooth scroller thumb; updateValues() fallback. |
| page/mac/EventHandlerMac.mm | KEEP (a) | convertPointFromScreen: is 10.12+; rewritten to 10.7+ convertRectFromScreen form. |
| page/mac/DragControllerMac.mm | KEEP (a) | UTType class accessors are 11.0+; routed to legacy kUTType helpers. |
| page/cocoa/WebTextIndicatorLayer.mm | KEEP (a) | +[NSColor findHighlightColor] is 10.10+; Cmd+F crash; guard + fallback. |
| page/Page.cpp | KEEP (c) | requiresUserGestureFor*Playback false under MEDIA_SOURCE (autoplay); mediaSessionManager re-enabled w/ guard. |
| page/SecurityOriginData.cpp | KEEP (c) | #14 safari-extension:// host-based origin (uBlock popup same-origin). |
| page/CaptionUserPreferencesMediaAF.cpp | KEEP (a) | MAAudibleMediaPrefCopyPreferDescriptiveVideo absent in 10.9 MediaAccessibility; dispatch_once crash on <track>. |
| page/ContextMenuController.cpp (hunks 2/3) | KEEP (c) | SERVICE_CONTROLS=0 → blank Share row; leave null + skip append. |
| page/mac/TextIndicatorWindow.h/.mm | KEEP (d/e) | empty build-glue stubs satisfying PlatformMac.cmake list entries (listed even at base). |
| editing/cocoa/NodeHTMLConverter.mm | KEEP (a) | NSTextAttachment setAccessibilityLabel:(10.10+)/initWithData:ofType:(10.11+); NSPresentationIntent (12.0+); #76 crash. |
| editing/cocoa/WebContentReaderCocoa.mm | KEEP (a/c) | UTType routing + @try/@catch over _htmlDocumentFragmentString: (10.9 NSHTMLWriter crash) #76. |
| editing/cocoa/AttributedString.mm | KEEP (a) | initWithData:ofType:/.image (10.11+) + accessibilityLabel (10.10+) guards; cell fallback. |
| editing/cocoa/EditingHTMLConverter.mm | KEEP (d) | #if ENABLE(ATTACHMENT_ELEMENT) (=0) — upstream unguarded refs wouldn't compile. |
| editing/cocoa/DictionaryLookup.mm | KEEP (d) | no-op hidePopup() under !ENABLE(REVEAL) to satisfy WebViewImpl link. |
| editing/mac/EditorMac.mm | KEEP (a) | UTTypeWebArchive.identifier (11.0+) → legacy helper (#76). |
| editing/mac/FrameSelectionMac.mm | KEEP (d) | missing-include build fix (FrameLoader/FrameLoaderClient) for clang-22 complete types. |
| page/cocoa/PerformanceLoggingCocoa.mm | KEEP (a) | task_vm_info.phys_footprint is 10.11+-populated; reads 0 on 10.9 → use resident_size. Telemetry. |

### KEEP+FLAG (keystones)
| File | Keystone | Reason |
|---|---|---|
| page/PerformanceMonitor.cpp | #53 | self-described WORKAROUND skipping Timer::stop/startOneShot (corrupt timer heap). NOT #36. |
| page/EventHandler.cpp | #53 | scheduleMouseEventTargetUpdateAfterLayout short-circuits to avoid heapInsert. |
| page/LocalFrameView.cpp | #55/#56 | handleWheelEventForScrolling bypasses ASYNC_SCROLLING coordinator (sync scroll). |

---

## Modules/  +  workers/  +  style/  +  css/

### REVERT
| File | Reason |
|---|---|
| Modules/webaudio/MediaStreamAudioSourceCocoa.cpp | PAL::CMTimeMake→CMTimeMake no-op (CoreMediaSoftLink #define resolves identically). |
| Modules/speech/SpeechRecognizer.cpp | PAL::kCMTimeZero→kCMTimeZero same no-op + blank line. |
| Modules/ShapeDetection/.../TextDetectorImplementation.mm | behind HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)=0; original already empty TU. Redundant strip. |
| Modules/ShapeDetection/.../BarcodeDetectorImplementation.mm | same guard=0. |
| Modules/ShapeDetection/.../FaceDetectorImplementation.mm | same guard=0. |
| Modules/ShapeDetection/.../VisionUtilities.mm | same guard=0. |
| Modules/applepay/PaymentInstallmentConfiguration.mm | behind HAVE(PASSKIT_INSTALLMENTS)=0 (deploy ≥10.12); original empty TU. |
| Modules/model-element/scenekit/SceneKitModel.h | ObjC generics strip (NSArray<SCNScene*>*→NSArray*); SDK declares it. |
| Modules/mediasource/MediaSource.cpp | dead MS_BISECT macro neutered to ((void)0) + unused asl.h includes (#63). |
| Modules/compression/CompressionStreamEncoder.cpp | z_const portability shim — modern SDK zlib defines it. Dead. |
| Modules/compression/DecompressionStreamDecoder.cpp | same z_const shim. Dead. |
| style/StyleScope.cpp | all 3 hunks dead `(FILE*)0` logging (#63). |

### KEEP
| File | Verdict | Reason |
|---|---|---|
| Modules/speech/cocoa/SpeechRecognizerCocoa.mm | KEEP (a) | SFSpeechRecognizer (Speech.framework 10.15+) absent at runtime; supplies all 4 methods, degrades cleanly. |
| Modules/speech/cocoa/WebSpeechRecognizerTask.mm | KEEP (a) | SF* APIs 10.15+; stub required. |
| Modules/model-element/scenekit/SceneKitModel.mm | KEEP (a) | body uses SCNMetalLayer (Metal 10.11+) + USD (10.13+); runtime-absent. |
| Modules/model-element/scenekit/SceneKitModelLoader.mm | KEEP (a) | SceneKit USD path runtime-absent. |
| Modules/model-element/scenekit/SceneKitModelLoaderClient.mm | KEEP (a) | same cluster stub. |
| Modules/model-element/scenekit/SceneKitModelLoaderUSD.mm | KEEP (a) | SCNSceneSource USD 10.13+. |
| Modules/model-element/scenekit/SceneKitModelPlayer.mm | KEEP (a) | SCNMetalLayer/Metal 10.11+. |
| Modules/push-api/cocoa/PushCryptoCocoa.cpp | KEEP (a) | BUILT; CCCryptorGCMOneshotDecrypt is 10.10+ → uses 10.9 CCCryptorGCM w/ constant-time compare. |
| Modules/geolocation/cocoa/GeolocationPositionDataCocoa.mm | KEEP (a) | CLLocation.floor/CLFloor is 10.15+ → unrecognized selector on every conversion. |
| workers/service/server/SWServer.cpp | KEEP (c) | SW context-staleness crash fixes (installContextData null race, setInspectable dangling WeakRef). |

### KEEP+FLAG (keystones / stale-suspect)
| File | Keystone | Reason |
|---|---|---|
| Modules/webaudio/DefaultAudioDestinationNode.cpp | #54 | ASSERT(isMainThread)→bail + m_destination null guards; some may be vestigial. |
| Modules/beacon/NavigatorBeacon.cpp | #54 | !isMainThread→return false (masks MemoryCache assert). |
| Modules/mediasource/MediaSource.idl | #50 | drops EnabledBySetting=MediaSourceEnabled (UIProcess never sets pref). |
| Modules/compression/CompressionStream.cpp | UNSURE | `#ifdef COMPRESSION_BROTLI` targets brotli 10.11+ gap, but COMPRESSION_BROTLI is an enum not a macro → #ifdef may always be false. Verify. |
| workers/Worker.cpp | #54 | comment-only (Workers re-enabled via relaxed MemoryCache assert). |
| workers/shared/SharedWorker.cpp | #55 | early-returns NotSupportedError (masks WorkerDedicatedRunLoop null-deref). |
| workers/service/SWClientConnection.cpp | #54 | RELEASE_ASSERT(isMainThread)→bounce. |
| workers/service/ServiceWorkerContainer.cpp | #54 | comment-only. |
| workers/service/ServiceWorkerGlobalScope.cpp | #54 | RELEASE_ASSERT(isMainThread)→nullptr. |
| css/CSSCounterStyleRegistry.cpp | #50 | synthesized decimal fallback when UA counter-style sheet not loaded (init-ordering). |
| style/StyleResolver.cpp | UNSURE/stale | comments out root fontCascade().primaryFont() init "font subsystem crashes" — but #31/#34 fixed fonts since; likely revertible. Verify. |

---

## accessibility/

KEYSTONE: backport flipped `ENABLE_ACCESSIBILITY_ISOLATED_TREE` to 0 (PlatformEnableCocoa.h) — the isolated-tree architecture needs post-10.9 AX threading/SPI. This one flag drives all the big guts. The gut was done IN-PLACE (SourcesCocoa.txt still lists the real .mm).

### REVERT
| File | Reason |
|---|---|
| accessibility/mac/WebAccessibilityObjectWrapperMac_stub.mm | ADDED dead orphan — appended to a HEADERS list (PlatformMac.cmake:501) so never compiled; only `#import "config.h"`. Delete file + cmake line. |
| accessibility/mac/WebAccessibilityObjectWrapperBase.h | pure ObjC lightweight-generics strip (clang-22 supports them); no backport marker. |
| accessibility/ios/WebAccessibilityObjectWrapperIOS.mm | same generics strip; doubly redundant (PLATFORM(IOS), never built on Mac). |

### KEEP / KEEP+FLAG
| File | Verdict | Reason |
|---|---|---|
| accessibility/mac/WebAccessibilityObjectWrapperMac.mm | KEEP+FLAG | 4478→3 gut coupled to isolated-tree (AXIsolatedTree/AXSearchManager/AXLiveRegionManager) compiled out by the keystone flag; revert won't link. Feature-disable, not SDK gap. |
| accessibility/mac/AXObjectCacheMac.mm | KEEP+FLAG | 1111→53 platform-stub; isolated-tree/live-region/_AXSIsolatedTreeMode soft-link removed. Same keystone. |
| accessibility/isolatedtree/AXIsolatedTree.h | KEEP+FLAG | gut to 3-line stub; many files include it unconditionally and reference the type. Scaffolding for the keystone flag. |
| accessibility/AXIsolatedTree.h (deleted) | KEEP | was a 0-byte empty file at base; deletion harmless. |
| accessibility/mac/WebAccessibilityObjectWrapperBase.mm | KEEP+FLAG | 2-line #if ENABLE(ACCESSIBILITY_ISOLATED_TREE) guard around isolated-object path. Keystone gate. |

---

## Bottom line
- The single biggest reducible cluster is crypto: 12 NOT-BUILT cocoa files (dead `pal::ECKey109` scaffolding) revert wholesale.
- Pervasive dead `(FILE*)0` debug scaffolding (#63) across dom/html/loader/page/rendering/style is ~22 fully-revertible files.
- The genuine SDK-gap-fill REVERTs are few: ObjC lightweight-generics strips (3 files), redundant HAVE()=0 gut-outs (ShapeDetection×4, applepay), z_const/CMTime no-ops, and the DrawGlyphsRecorder.h orphan.
- KEEP+FLAG keystone band-aids (#50/#53/#54/#55/#56) are concentrated and map to known tracked tasks — fix the keystone, delete the cluster.
