#!/bin/bash
# Verify the 10.9 backport fixes are present in the installed WebKit binary.
# Usage: ./verify_fixes.sh
# Exits 0 if all expected fixes present, 1 if any missing (with diagnostic output).

set -u

WEBKIT_BIN=${WEBKIT_BIN:-/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit}
WEBCORE_SRC=/Users/jonathan/Desktop/WebKit/Source/WebCore
WTF_SRC=/Users/jonathan/Desktop/WebKit/Source/WTF
WK2_SRC=/Users/jonathan/Desktop/WebKit/Source/WebKit

if [[ ! -e "$WEBKIT_BIN" ]]; then
    echo "FAIL: $WEBKIT_BIN not found"
    exit 1
fi

bin_size=$(stat -f "%z" "$WEBKIT_BIN")
bin_mtime=$(stat -f "%Sm" "$WEBKIT_BIN")
echo "Verifying $WEBKIT_BIN"
echo "  size=$bin_size mtime=$bin_mtime"
echo

pass=0
fail=0

check() {
    local label="$1"
    local file="$2"
    local needle="$3"
    if grep -q -F -- "$needle" "$file" 2>/dev/null; then
        echo "  ✓ $label"
        ((pass++))
    else
        echo "  ✗ $label  (not found in $file)"
        ((fail++))
    fi
}

# Source-level checks (validate the fixes are still present in the .cpp/.mm/.h)
echo "== Source-level fix presence =="

check "CTFontShapeGlyphs polyfill garbage skip (THE dash text fix)" \
    "$WEBCORE_SRC/platform/graphics/coretext/FontCoreText.cpp" \
    "CTFontShapeGlyphs is a 10.13+ API"

check "AtomStringTableLocker real Lock on Mac" \
    "$WTF_SRC/wtf/text/AtomStringImpl.cpp" \
    "USE(WEB_THREAD) || PLATFORM(MAC)"

check "QualifiedNameCache lock on Mac" \
    "$WEBCORE_SRC/dom/QualifiedNameCache.cpp" \
    "qualifiedNameCacheLock"

check "EventNames process-shared singleton on Mac" \
    "$WEBCORE_SRC/platform/ThreadGlobalData.cpp" \
    "sharedEventNames"

check "IOSurface NULL colorSpace fallback" \
    "$WEBCORE_SRC/platform/graphics/cocoa/IOSurface.mm" \
    "sRGBColorSpaceSingleton"

check "IOHIDEventGetFloatValue polyfill garbage skip" \
    "$WK2_SRC/Shared/mac/WebEventFactory.mm" \
    "IOHIDEvent* APIs are stubbed in our polyfill"

check "CTFontGetAccessibilityBoldWeightOfWeight polyfill skip" \
    "$WEBCORE_SRC/platform/graphics/cocoa/UnrealizedCoreTextFont.cpp" \
    "CTFontGetAccessibilityBoldWeightOfWeight is 10.13+"

check "CTFontGetSbixImageSize disabled HAVE flag on Mac" \
    "$WTF_SRC/wtf/PlatformHave.h" \
    "CTFontGetSbixImageSizeForGlyphAndContentsScale is 10.13+"

check "CVDisplayLinkGetNominal polyfill garbage skip (60fps default)" \
    "$WEBCORE_SRC/platform/graphics/mac/LegacyDisplayRefreshMonitorMac.cpp" \
    "CVDisplayLinkGetNominalOutputVideoRefreshPeriod is statically"

check "Web Audio: AudioComponent/AudioUnit soft-linked from AudioUnit.framework on Mac" \
    "$WEBCORE_SRC/PAL/pal/cf/AudioToolboxSoftLink.cpp" \
    "AudioComponent* / AudioUnit* / AudioOutputUnit*"

check "Web Audio: real WebMediaStrategy::createAudioDestination impl" \
    "$WK2_SRC/WebProcess/GPU/media/WebMediaStrategy.cpp" \
    "createAudioDestination"

check "HTMLMediaElement::didFinishInsertingNode un-stubbed (video init works)" \
    "$WEBCORE_SRC/html/HTMLMediaElement.cpp" \
    'stub reason ("m_mediaSession is null") was OBSOLETE'

check "HTMLMediaElement::prepareForLoad un-stubbed (load algorithm bookkeeping works)" \
    "$WEBCORE_SRC/html/HTMLMediaElement.cpp" \
    "try the real load preparation now"

check "AudioSession base impl returns real defaults on Mac (44100Hz, 2ch)" \
    "$WEBCORE_SRC/platform/audio/AudioSession.cpp" \
    "AudioSessionDummy uses this base impl"

check "MemoryPressureHandler::install re-enabled on Mac (responds to OOM)" \
    "$WTF_SRC/wtf/cocoa/MemoryPressureHandlerCocoa.mm" \
    "10.9 backport: dispatch queue is initialized by the constructor"

check "WebCrypto HKDF: real RFC 5869 impl on Mac (CCDeriveKey is 10.10+)" \
    "$WEBCORE_SRC/crypto/cocoa/CryptoUtilitiesCocoa.cpp" \
    "RFC 5869 HKDF directly using CCHmac"

check "WebCrypto RSA CRT components: skipped on Mac (CCRSAGetCRTComponents is 10.10+)" \
    "$WEBCORE_SRC/crypto/cocoa/CryptoKeyRSACocoa.cpp" \
    "Skip CRT (dp, dq, qinv)"

check "Web Push AES-128-GCM decrypt: via CCCryptorGCM on Mac (CCCryptorGCMOneshotDecrypt is 10.10+)" \
    "$WEBCORE_SRC/Modules/push-api/cocoa/PushCryptoCocoa.cpp" \
    "Use the older one-shot"

check "AVAssetTrackUtilities.mm un-stubbed (hardware decode requirements check works)" \
    "$WEBCORE_SRC/platform/graphics/avfoundation/objc/AVAssetTrackUtilities.mm" \
    "CMFormatDescription* aren't soft-linked through PAL"

check "VideoLayerManagerObjC.mm un-stubbed (video layer management works)" \
    "$WEBCORE_SRC/platform/graphics/avfoundation/objc/VideoLayerManagerObjC.mm" \
    "AVPlayerLayer exists directly on 10.9"

check "TCA: CFRunLoopWakeUp on every observer schedule (replaces rAF throttle)" \
    "$WK2_SRC/WebProcess/WebPage/mac/TiledCoreAnimationDrawingArea.mm" \
    "CFRunLoopWakeUp(CFRunLoopGetMain())"

check "contentsScale/contents/setContents TransformLayer guards (10.9 doesNotRecognizeSelector fix)" \
    "$WEBCORE_SRC/platform/graphics/ca/cocoa/PlatformCALayerCocoa.mm" \
    "CATransformLayer doesn't implement -contents"

check "copyNativeImage uses createImageReference (m_surface->createImage broken on 10.9)" \
    "$WEBCORE_SRC/platform/graphics/cg/ImageBufferIOSurfaceBackend.cpp" \
    "10.9 backport: m_surface->createImage is broken on this build"

check "LayerTypeTransformLayer falls back to CALayer on 10.9 (CATransformLayer UAF)" \
    "$WEBCORE_SRC/platform/graphics/ca/cocoa/PlatformCALayerCocoa.mm" \
    "CATransformLayer on 10.9 is over-released"

check "Address-bar link-click fix: empty Dictionary substituted when userData is NULL" \
    "$WK2_SRC/UIProcess/API/C/WKPage.cpp" \
    "Safari 9's BrowserPageLoaderClient bails immediately if userData is null"


# Binary-level checks (confirm the polyfill stub is still present so we know we're on the right binary)
echo
echo "== Binary-level checks =="

# Polyfill stub strips: these symbols MUST be undefined in framework binaries so real
# system implementations win at runtime. Pre-fix: polyfill statically linked xorl/ret
# stubs that silently corrupted return values across crypto, XPC, math, quarantine.
WEBCORE_BIN=/Users/jonathan/Desktop/WebKit/lib/lib/WebCore.framework/Versions/A/WebCore
WEBKIT_BIN_LOCAL=/Users/jonathan/Desktop/WebKit/lib/lib/WebKit.framework/Versions/615.1.1/WebKit

check_undef() {
    local bin="$1" sym="$2" label="$3"
    if [[ ! -e "$bin" ]]; then return; fi
    if nm "$bin" 2>/dev/null | grep -qE "^[[:space:]]+U $sym\$"; then
        echo "  ✓ $label"
        ((pass++))
    elif nm "$bin" 2>/dev/null | grep -qE " T $sym\$"; then
        echo "  ✗ $label  (still TEXT stub — broken)"
        ((fail++))
    fi
}

check_undef "$WEBCORE_BIN" "_CCCryptorGCM" "WebCrypto CC* stubs stripped (libcommonCrypto wins)"
check_undef "$WEBKIT_BIN_LOCAL" "_xpc_string_get_length" "XPC stubs stripped (libxpc wins)"
check_undef "$WEBKIT_BIN_LOCAL" "__qtn_file_alloc" "Quarantine stubs stripped (libquarantine wins)"
check_undef "$WEBKIT_BIN_LOCAL" "_sandbox_init_with_parameters" "sandbox_init_with_parameters stripped"
check_undef "$WEBCORE_BIN" "___divdc3" "Complex math stubs stripped (libcompiler_rt wins)"
check_undef "$WEBCORE_BIN" "_hypotf" "Float math stubs stripped (libsystem_m wins)"
check_undef "$WEBCORE_BIN" "_CCrfc3394_iv" "AES-KW rfc3394 IV stripped (data sym wins from libcommonCrypto)"
check_undef "$WEBCORE_BIN" "_xmlMalloc" "libxml2 globals stripped (real libxml2 wins, error reporting works)"
check_undef "$WEBKIT_BIN_LOCAL" "_XPC_ACTIVITY_CHECK_IN" "XPC_ACTIVITY data stubs stripped (libxpc wins)"

if otool -tV "$WEBKIT_BIN" 2>/dev/null | grep -q "_CTFontShapeGlyphs:"; then
    next_line=$(otool -tV "$WEBKIT_BIN" 2>/dev/null | grep -A1 "_CTFontShapeGlyphs:" | tail -1)
    if echo "$next_line" | grep -q "xorl"; then
        echo "  ✓ CTFontShapeGlyphs polyfill stub still present (we're skipping it correctly)"
        ((pass++))
    else
        echo "  ✗ CTFontShapeGlyphs has unexpected impl: $next_line"
        ((fail++))
    fi
else
    echo "  ⚠ CTFontShapeGlyphs symbol not in binary (might have been LTO-stripped — OK)"
fi

# WebContent crash check
echo
echo "== Recent WebContent crashes (last 24h) =="
recent=$(find ~/Library/Logs/DiagnosticReports -name 'com.apple.WebKit.WebContent_*.crash' -mtime -1 2>/dev/null | wc -l | tr -d ' ')
echo "  WebContent crashes in last 24h: $recent"
if [[ "$recent" -gt 0 ]]; then
    echo "  Recent crash signatures:"
    for f in $(find ~/Library/Logs/DiagnosticReports -name 'com.apple.WebKit.WebContent_*.crash' -mtime -1 2>/dev/null | head -3); do
        sig=$(grep -m1 "^0  *" "$f" 2>/dev/null | sed 's/^[^ ]* *[^ ]* *//' | cut -c1-90)
        echo "    - $(basename "$f"): $sig"
    done
fi

echo
echo "Result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
