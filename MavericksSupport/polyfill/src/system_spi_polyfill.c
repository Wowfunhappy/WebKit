// system-framework SPI that the macOS 26.1 SDK resolves against the system
// frameworks (recording a two-level bind) but the 10.9 runtime does not export. Without a definition
// here the link records a bind to e.g. Security/CoreText/CFNetwork that fails on 10.9 — a non-lazy
// bind SIGTRAPs at load, a lazy one when the call site is first reached. libpolyfill.a is on every
// WebKit framework's link line ahead of the system frameworks, so defining a symbol here makes the
// linker satisfy WebKit's reference from the archive instead of the (absent-on-10.9) system export.
//
// Each function below is either (a) runtime-gated by WebKit so it is never actually executed on 10.9
// (the definition only needs to exist to satisfy the bind), (b) a feature genuinely absent on 10.9
// whose callers tolerate a null/zero result, or (c) implemented for real against the 10.9-available
// underlying API. The classification is noted per function.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <Security/Security.h>
#include <CommonCrypto/CommonCrypto.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------
// AppKit / AX — runtime-gated; never executed on 10.9.
// ---------------------------------------------------------------------------------------------------

// drawFocusRing()/ControlMac take a < 10.10 path that draws a plain stroked ring; this is compiled in
// for the >= 10.10 branch only. Definition exists solely to satisfy the bind. (NSFocusRingPlacement,
// CGFocusRingStyle elided to void*/int — never called here.)
int NSInitializeCGFocusRingStyleForTime(int placement, void *style, double time)
{
    (void)placement; (void)style; (void)time;
    return 0;
}

// Notifies AX of a process suspend/resume. No AX process-suspend tracking on 10.9; return success.
int _AXUIElementNotifyProcessSuspendStatus(int status)
{
    (void)status;
    return 0; // kAXErrorSuccess
}

// AccessibilitySupport: "Increase Contrast > Enhance text legibility" accessibility setting (absent on
// 10.9 — the framework that vends it postdates this OS). FontCache::platformInvalidate reads it during
// WebProcess init (a flat-namespace bind, so it must resolve). The setting is off by default.
unsigned char _AXSEnhanceTextLegibilityEnabled(void) { return 0; }

// HIServices SPI that tags the calling process with an AX "client type" (e.g. WebKitTesting) so the AX
// runtime can special-case test harnesses. Absent on 10.9 (postdates this OS). The layout-test drivers
// (DumpRenderTree/WebKitTestRunner) call it during accessibility-controller setup; on 10.9 there is no AX
// client-type registry, so a no-op is the correct behavior (the AX tests that depend on it are skipped).
void _AXSetClientIdentificationOverride(int clientType) { (void)clientType; }

// LaunchServices UTType predicates added after 10.9 (10.9's LaunchServices has the rest of the UTType API
// — UTTypeConformsTo/UTTypeCopyPreferredTagWithClass/etc. — but not these two). The layout-test drivers
// reference them; callers fall back to the pre-UTI MIME/extension path, so a conservative "no" is correct
// on 10.9 (treat nothing as a dynamic or specially-declared UTI).
Boolean UTTypeIsDynamic(CFStringRef inUTI) { (void)inUTI; return false; }
Boolean UTTypeIsDeclared(CFStringRef inUTI) { (void)inUTI; return false; }

// ---------------------------------------------------------------------------------------------------
// CFNetwork — features absent on 10.9; callers tolerate null/no-op.
// ---------------------------------------------------------------------------------------------------

// Cross-process handoff of an identified cookie store. 10.9 has no identifying-data API; returning
// null makes CookieStorageUtilsCF fall back to the default shared storage (its own comment notes this).
void *CFHTTPCookieStorageCreateIdentifyingData(CFAllocatorRef allocator, void *storage)
{
    (void)allocator; (void)storage;
    return NULL;
}

void *CFHTTPCookieStorageCreateFromIdentifyingData(CFAllocatorRef allocator, CFDataRef data)
{
    (void)allocator; (void)data;
    return NULL;
}

// App Transport Security context (10.11+). No ATS on 10.9: nothing to copy, nothing to set.
CFDataRef _CFNetworkCopyATSContext(void)
{
    return NULL;
}

Boolean _CFNetworkSetATSContext(CFDataRef context)
{
    (void)context;
    return false;
}

// Per-storage-session cache disable (newer API). The caller guards the call; on 10.9 it is a no-op
// (cache policy is handled through the storage session that is created without an on-disk cache).
void _CFURLStorageSessionDisableCache(void *storageSession)
{
    (void)storageSession;
}

// ---------------------------------------------------------------------------------------------------
// CoreFoundation prefs daemon tuning — optimizations for sandboxed XPC services; no-ops on 10.9.
// ---------------------------------------------------------------------------------------------------

void _CFPrefsSetDirectModeEnabled(int enabled) { (void)enabled; }
void _CFPrefsSetReadOnly(Boolean flag) { (void)flag; }

// ---------------------------------------------------------------------------------------------------
// CoreGraphics
// ---------------------------------------------------------------------------------------------------

// Absent on 10.9 (modern WebCore calls it constantly from GraphicsContextCG during -drawRect:).
// The obvious forward — CGBitmapContextGetColorSpace() — is WRONG: on any non-bitmap context (the
// IOSurface-backed layer/drawRect contexts of compositing views, window contexts, …) it doesn't just
// return null, it first emits "CGBitmapContextGetColorSpace: invalid context 0x… This is a serious
// error…" to the console. WebKit drawing hits that on every paint, producing thousands of log lines
// (visible in Safari's WebContent and DashboardClient). CGContextCopyDeviceColorSpace() returns the
// context's colorspace for EVERY context kind silently (for a genuine bitmap context it returns that
// bitmap's colorspace, matching CGBitmapContextGetColorSpace). It returns +1 (a Copy), so autorelease
// to match CGContextGetColorSpace()'s +0 "get" ownership — the caller stores the result in a RetainPtr.
// CGContextCopyDeviceColorSpace exists in 10.9's CoreGraphics but the modern SDK we build against
// dropped its header declaration, so forward-declare it.
extern CGColorSpaceRef CGContextCopyDeviceColorSpace(CGContextRef);
CGColorSpaceRef CGContextGetColorSpace(CGContextRef context)
{
    CGColorSpaceRef colorSpace = CGContextCopyDeviceColorSpace(context);
    return colorSpace ? (CGColorSpaceRef)CFAutorelease(colorSpace) : NULL;
}

// Lockdown Mode for PDF (macOS 13+). No Lockdown Mode on 10.9.
void CGEnterLockdownModeForPDF(void) { }

// Wide-gamut / extended-range / HDR transfer-function color-space predicates (10.12+/10.14+). 10.9 is
// sRGB-only with no extended range or ITU-R BT.2100 transfer function: report false for all.
bool CGColorSpaceIsWideGamutRGB(CGColorSpaceRef space) { (void)space; return false; }
bool CGColorSpaceUsesExtendedRange(CGColorSpaceRef space) { (void)space; return false; }
bool CGColorSpaceUsesITUR_2100TF(CGColorSpaceRef space) { (void)space; return false; }

// ---------------------------------------------------------------------------------------------------
// CoreText
// ---------------------------------------------------------------------------------------------------

// CTFontShapeGlyphs (the unified glyph-shaping entry point) is 10.13+ and absent on 10.9. It is called
// from Font::applyTransforms (the SimpleShaper path) to fill per-glyph horizontal advances (and, for
// complex cases, reorder glyphs via the handler). On 10.9 that path historically used the still-present
// CTFontGetAdvancesForGlyphs to fill base horizontal advances, and complex-script reshaping/reordering
// went through WebCore's ComplexTextController (CTLine/CTTypesetter), NOT this simple path. So the
// faithful 10.9 behavior here is: fill base horizontal advances from CTFontGetAdvancesForGlyphs, keep
// the caller's glyphs/origins/indexes (horizontal simple text has zero origins and no reordering), and
// return a zero initial advance (LTR). This is a real implementation over the present 10.9 API, not a
// value stub. CTFontShapeOptions is a CFOptionFlags; the reorder handler is unused on this OS path.
extern CGSize CTFontShapeGlyphs(CTFontRef, CGGlyph[], CGSize[], CGPoint[], CFIndex[], const UniChar[], CFIndex, CFOptionFlags, CFStringRef, void (^)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**));
CGSize CTFontShapeGlyphs(CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**))
{
    (void)origins; (void)indexes; (void)chars; (void)options; (void)language; (void)handler;
    if (count > 0 && advances && glyphs)
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, count);
    CGSize zero = { 0, 0 };
    return zero;
}

// ---------------------------------------------------------------------------------------------------
// CoreServices / LaunchServices — called before LS check-in in auxiliary processes; no-op on 10.9.
// ---------------------------------------------------------------------------------------------------

void _CSCheckFixDisable(void) { }

// ---------------------------------------------------------------------------------------------------
// CoreText — text rendering hits these live, so the live ones forward to 10.9-available CoreText.
// ---------------------------------------------------------------------------------------------------

// Color-glyph coverage bit vectors (color emoji / feature coverage). 10.9 lacks both; callers guard
// the null return (FontCoreText only proceeds "if (bitVector)").
CFBitVectorRef CTFontCopyColorGlyphCoverage(CTFontRef font) { (void)font; return NULL; }
CFBitVectorRef CTFontCopyGlyphCoverageForFeature(CTFontRef font, CFDictionaryRef feature)
{
    (void)font; (void)feature;
    return NULL;
}

// CSS generic family -> concrete 10.9 font descriptor. The cssFamily argument is one of the
// kCTFontCSSFamily* constants supplied by const_polyfill.c (its value is its own name). Map each to a
// font that ships on 10.9 so generic families (serif/sans-serif/monospace/cursive/fantasy) resolve.
CTFontDescriptorRef CTFontDescriptorCreateForCSSFamily(CFStringRef cssFamily, CFStringRef language)
{
    (void)language;
    if (!cssFamily)
        return NULL;
    CFStringRef name = NULL;
    if (CFStringHasSuffix(cssFamily, CFSTR("Serif")) && !CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Times");
    else if (CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Helvetica");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Monospace")))
        name = CFSTR("Courier");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Cursive")))
        name = CFSTR("Apple Chancery");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Fantasy")))
        name = CFSTR("Papyrus");
    if (!name)
        return NULL;
    return CTFontDescriptorCreateWithNameAndSize(name, 0.0);
}

// "Last Resort" tofu fallback font descriptor. The LastResort font ships on 10.9.
CTFontDescriptorRef CTFontDescriptorCreateLastResort(void)
{
    return CTFontDescriptorCreateWithNameAndSize(CFSTR("LastResort"), 0.0);
}

// Dynamic-Type text-style descriptor (style/size/language). 10.9 has no Dynamic Type; return the
// system UI font's descriptor so system/caption text resolves to a real font.
CTFontDescriptorRef CTFontDescriptorCreateWithTextStyle(CFStringRef style, CFStringRef size, CFStringRef language)
{
    (void)style; (void)size; (void)language;
    CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 0.0, NULL);
    if (!system)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(system);
    CFRelease(system);
    return descriptor;
}

// Descriptor option flags (newer). 10.9 descriptors carry none; report none.
uint64_t CTFontDescriptorGetOptions(CTFontDescriptorRef descriptor) { (void)descriptor; return 0; }

// Glyphs for a run of consecutive BMP characters. The modern convenience over CTFontGetGlyphsFor
// Characters (which 10.9 has): the caller passes a CFRange of UniChar code points and a glyph buffer
// sized to the range length.
bool CTFontGetGlyphsForCharacterRange(CTFontRef font, CGGlyph glyphs[], CFRange range)
{
    if (!font || range.length <= 0)
        return false;
    UniChar *characters = (UniChar *)malloc(sizeof(UniChar) * (size_t)range.length);
    if (!characters)
        return false;
    for (CFIndex i = 0; i < range.length; ++i)
        characters[i] = (UniChar)(range.location + i);
    bool result = CTFontGetGlyphsForCharacters(font, characters, glyphs, range.length);
    free(characters);
    return result;
}

// "Physical" (non-synthesized) symbolic traits. 10.9 exposes only CTFontGetSymbolicTraits; the
// physical traits are the same set for a real (non-synthesized) font.
CTFontSymbolicTraits CTFontGetPhysicalSymbolicTraits(CTFontRef font)
{
    return CTFontGetSymbolicTraits(font);
}

// UI-font-type classification (newer). 10.9 cannot classify an arbitrary font; report "no type".
uint32_t CTFontGetUIFontType(CTFontRef font) { (void)font; return (uint32_t)-1; /* kCTFontNoFontType */ }

// Is this the Apple Color Emoji font? Compare the PostScript name (the emoji font ships on 10.9).
bool CTFontIsAppleColorEmoji(CTFontRef font)
{
    if (!font)
        return false;
    CFStringRef postScriptName = CTFontCopyPostScriptName(font);
    bool result = postScriptName && CFStringCompare(postScriptName, CFSTR("AppleColorEmoji"), 0) == kCFCompareEqualTo;
    if (postScriptName)
        CFRelease(postScriptName);
    return result;
}

// Is this the system UI font? 10.9 has no such predicate; WebKit only uses it to take a fast path,
// so reporting false (treat as an ordinary font) is correct, just not the fast path.
bool CTFontIsSystemUIFont(CTFontRef font) { (void)font; return false; }

// Enable user-installed fonts process-wide (newer). User fonts are already enabled on 10.9.
bool CTFontManagerEnableAllUserFonts(bool postFontChangeNotification)
{
    (void)postFontChangeNotification;
    return true;
}

// Composition language hint on a paragraph style (newer). No effect on 10.9 line layout.
void CTParagraphStyleSetCompositionLanguage(CTParagraphStyleRef style, int language)
{
    (void)style; (void)language;
}

// Does the font contain a given sfnt table? 10.9 lacks the predicate but has the underlying copy.
bool CTFontHasTable(CTFontRef font, CTFontTableTag tag)
{
    CFDataRef table = CTFontCopyTable(font, tag, 0);
    bool present = table != NULL;
    if (table)
        CFRelease(table);
    return present;
}

// ---------------------------------------------------------------------------------------------------
// DataDetectorsCore — the 10.9 DataDetectors result type differs; report no type id so DataDetection
// finds nothing of this type (degrades gracefully rather than crashing).
// ---------------------------------------------------------------------------------------------------

CFTypeID DDResultGetCFTypeID(void) { return 0; }

// ---------------------------------------------------------------------------------------------------
// IOKit HID event system client (newer HID API) — used to read the pointer scroll-acceleration curve.
// Absent on 10.9; returning null/no-op leaves WebKit on the default acceleration curve.
// ---------------------------------------------------------------------------------------------------

void IOHIDEventSystemClientActivate(void *client) { (void)client; }
void *IOHIDEventSystemClientCopyServiceForRegistryID(void *client, uint64_t registryID)
{
    (void)client; (void)registryID;
    return NULL;
}
void IOHIDEventSystemClientSetDispatchQueue(void *client, void *queue) { (void)client; (void)queue; }

// IOHIDEventGetScrollMomentum (10.9's IOKit lacks this one; the sibling IOHIDEvent accessors
// IOHIDEventGetFloatValue/GetTimeStamp/GetSenderID/GetType ARE present and link to the real
// symbols). Momentum-phase bits aren't reported through this API on 10.9; returning 0 (no bits)
// is the honest answer — scroll deltas still come through the present IOHIDEventGetFloatValue path.
unsigned char IOHIDEventGetScrollMomentum(void *event) { (void)event; return 0; }

// ---------------------------------------------------------------------------------------------------
// ImageIO decode-policy controls (newer, security hardening). No-op on 10.9: images decode normally.
// ---------------------------------------------------------------------------------------------------

int CGImageSourceDisableHardwareDecoding(void) { return 0; /* noErr */ }
int CGImageSourceEnableRestrictedDecoding(void) { return 0; /* noErr */ }
// Restricts which image UTIs may be decoded (newer hardening). No-op on 10.9: all types decode.
OSStatus CGImageSourceSetAllowableTypes(CFArrayRef allowableTypes) { (void)allowableTypes; return 0; }

// CGImageSourceGetPrimaryImageIndex (10.14+): the primary-image concept (a HEIF/HEIC container's
// primary item) postdates 10.9, and 10.9's ImageIO exports no such symbol. On 10.9 the primary frame
// is always index 0 (single-frame images have only frame 0; animated GIF/APNG treat frame 0 as
// primary). Declared in the 26.1 SDK's ImageIO headers, so ImageDecoderCG.cpp calls the upstream name
// unchanged.
size_t CGImageSourceGetPrimaryImageIndex(CGImageSourceRef source) { (void)source; return 0; }

// ---------------------------------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------------------------------

// Keychain access-control objects (passkeys / SE-backed keys). Absent on 10.9; callers tolerate null.
// The type id is used in CFGetTypeID comparisons; 0 never matches, so such objects are never seen.
CFTypeID SecAccessControlGetTypeID(void) { return 0; }
CFDataRef SecAccessControlCopyData(void *accessControl) { (void)accessControl; return NULL; }
void *SecAccessControlCreateFromData(CFAllocatorRef allocator, CFDataRef data, CFErrorRef *error)
{
    (void)allocator; (void)data;
    if (error)
        *error = NULL;
    return NULL;
}

// Certificate signature hash algorithm (used for weak-signature UI). 10.9 lacks the accessor; report
// "unknown" (0) so no weak-signature downgrade is asserted.
int SecCertificateGetSignatureHashAlgorithm(SecCertificateRef certificate) { (void)certificate; return 0; }

// Process signing identifier. Absent on 10.9; callers use it for telemetry/diagnostics and accept null.
CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error)
{
    (void)task;
    if (error)
        *error = NULL;
    return NULL;
}

// Code-sign status flags. WebKit tests `& CS_PLATFORM_BINARY`; our frameworks are not platform
// binaries on 10.9, so report no flags (matches the behavior the prior build relied on).
uint32_t SecTaskGetCodeSignStatus(SecTaskRef task) { (void)task; return 0; }

// SecTrust IPC serialization. Both halves are absent on 10.9 and both resolve here, so they only need
// to round-trip with each other: carry the certificate chain (a binary plist of DER datas); the
// receiver rebuilds a SecTrust and re-evaluates with a basic X.509 policy. (Custom anchors/policies
// degrade to the default, but the chain — the part used for display and validation — survives.)
CFDataRef SecTrustSerialize(SecTrustRef trust, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (!trust)
        return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);
        CFDataRef der = certificate ? SecCertificateCopyData(certificate) : NULL;
        if (der) {
            CFArrayAppendValue(certificates, der);
            CFRelease(der);
        }
    }
    CFDataRef data = CFPropertyListCreateData(NULL, certificates, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(certificates);
    return data;
}

SecTrustRef SecTrustDeserialize(CFDataRef serializedTrust, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (!serializedTrust)
        return NULL;
    CFArrayRef certificateDatas = (CFArrayRef)CFPropertyListCreateWithData(NULL, serializedTrust, kCFPropertyListImmutable, NULL, NULL);
    if (!certificateDatas || CFGetTypeID(certificateDatas) != CFArrayGetTypeID()) {
        if (certificateDatas)
            CFRelease(certificateDatas);
        return NULL;
    }
    CFIndex count = CFArrayGetCount(certificateDatas);
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; ++i) {
        CFDataRef der = (CFDataRef)CFArrayGetValueAtIndex(certificateDatas, i);
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, der);
        if (certificate) {
            CFArrayAppendValue(certificates, certificate);
            CFRelease(certificate);
        }
    }
    CFRelease(certificateDatas);
    SecTrustRef trust = NULL;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustCreateWithCertificates(certificates, policy, &trust);
    CFRelease(policy);
    CFRelease(certificates);
    return trust;
}

// Attribution of a cross-process trust evaluation to the client. Single-system on 10.9: accept it.
int SecTrustSetClientAuditToken(SecTrustRef trust, CFDataRef auditToken)
{
    (void)trust; (void)auditToken;
    return 0; // errSecSuccess
}

// ---------------------------------------------------------------------------------------------------
// libSystem — diagnostics + audit-token sandbox checks absent on 10.9.
// ---------------------------------------------------------------------------------------------------

typedef struct { unsigned int val[8]; } mav_audit_token_t;

// State-dump (sysdiagnose) handler registration. None on 10.9; return a null handle.
unsigned long os_state_add_handler(void *queue, void *handler) { (void)queue; (void)handler; return 0; }

// Audit-token sandbox checks (newer than the pid-based sandbox_check on 10.9). WebKit child processes
// run without the fine-grained profile on this backport, so report "permitted/not-restricted" (0),
// matching the pid-based path's behavior for an unsandboxed process.
int sandbox_check_by_audit_token(mav_audit_token_t token, const char *operation, int type, ...)
{
    (void)token; (void)operation; (void)type;
    return 0;
}

bool sandbox_enable_state_flag(const char *name, mav_audit_token_t token)
{
    (void)name; (void)token;
    return false;
}

// ---------------------------------------------------------------------------------------------------
// CommonCrypto — KDF + one-shot AES-GCM SPI absent on 10.9.
//
// The CCKDFParameters/CCDeriveKey key-derivation API and the one-shot CCCryptorGCMOneshotDecrypt are
// 10.10+ and have no symbol in 10.9's libcommonCrypto (verified: absent; CCHmac and the deprecated
// one-shot CCCryptorGCM ARE present). WebCore reaches them through PAL's CommonCryptoSPI.h — WebCrypto
// HKDF (deriveBits/deriveKey) via CCKDFParametersCreateHkdf + CCDeriveKey, and the Push API's aes128gcm
// payload decryption via CCCryptorGCMOneshotDecrypt. Reimplement each over the 10.9-present primitives
// so the upstream call sites revert to pristine. CCStatus/CCDigestAlgorithm/CCKDFParametersRef are SPI
// (not in the public SDK headers); use their underlying ABI types (int32_t / uint32_t /
// struct CCKDFParameters *) here to avoid redeclaring them. The CCDigestAlgorithm values are the
// CommonDigestSPI enum: kCCDigestSHA1=8, DeprecatedCCDigestSHA224=9, kCCDigestSHA256=10, SHA384=11,
// SHA512=12.
// ---------------------------------------------------------------------------------------------------

// CCCryptorGCM (the deprecated but 10.9-present one-shot GCM) is SPI; forward-declare it.
extern CCCryptorStatus CCCryptorGCM(CCOperation op, CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, void *tag, size_t *tagLength);

// One-shot AES-GCM decrypt-and-verify. CCCryptorGCM decrypts and computes the authentication tag over
// the data; compare it to the caller's expected tag in constant time and report kCCDecodeError on
// mismatch (the authenticated-decrypt contract: a forged/wrong tag fails rather than returning
// plaintext — the caller treats any non-success as decryption failure).
CCCryptorStatus CCCryptorGCMOneshotDecrypt(CCAlgorithm alg, const void *key, size_t keyLength, const void *iv, size_t ivLen, const void *aData, size_t aDataLen, const void *dataIn, size_t dataInLength, void *dataOut, const void *tagIn, size_t tagLength)
{
    unsigned char computedTag[16];
    if (tagLength > sizeof(computedTag))
        return kCCParamError;
    size_t computedTagLen = tagLength;
    CCCryptorStatus rv = CCCryptorGCM(kCCDecrypt, alg, key, keyLength, iv, ivLen, aData, aDataLen, dataIn, dataInLength, dataOut, computedTag, &computedTagLen);
    if (rv != kCCSuccess)
        return rv;
    const unsigned char *expected = (const unsigned char *)tagIn;
    unsigned char diff = 0;
    for (size_t i = 0; i < tagLength; ++i)
        diff |= (unsigned char)(computedTag[i] ^ expected[i]);
    return diff ? kCCDecodeError : kCCSuccess;
}

// CCKDFParametersRef is `struct CCKDFParameters *` (opaque to callers); complete it here to carry the
// HKDF salt + info(context). CreateHkdf copies them, CCDeriveKey runs extract+expand, Destroy frees.
struct CCKDFParameters {
    void *salt;    size_t saltLen;
    void *context; size_t contextLen;
};

int32_t CCKDFParametersCreateHkdf(struct CCKDFParameters **params, const void *salt, size_t saltLen, const void *context, size_t contextLen)
{
    if (!params)
        return kCCParamError;
    struct CCKDFParameters *p = (struct CCKDFParameters *)calloc(1, sizeof(*p));
    if (!p)
        return kCCMemoryFailure;
    if (saltLen) {
        p->salt = malloc(saltLen);
        if (!p->salt) { free(p); return kCCMemoryFailure; }
        memcpy(p->salt, salt, saltLen);
        p->saltLen = saltLen;
    }
    if (contextLen) {
        p->context = malloc(contextLen);
        if (!p->context) { free(p->salt); free(p); return kCCMemoryFailure; }
        memcpy(p->context, context, contextLen);
        p->contextLen = contextLen;
    }
    *params = p;
    return kCCSuccess;
}

void CCKDFParametersDestroy(struct CCKDFParameters *params)
{
    if (!params)
        return;
    free(params->salt);
    free(params->context);
    free(params);
}

// Map a CCDigestAlgorithm (8..12) to its HMAC algorithm + output length.
static int mav_hkdfDigestInfo(uint32_t digest, CCHmacAlgorithm *hmacAlg, unsigned *hashLen)
{
    switch (digest) {
    case 8:  *hmacAlg = kCCHmacAlgSHA1;   *hashLen = CC_SHA1_DIGEST_LENGTH;   return 1; // kCCDigestSHA1
    case 9:  *hmacAlg = kCCHmacAlgSHA224; *hashLen = CC_SHA224_DIGEST_LENGTH; return 1; // DeprecatedCCDigestSHA224
    case 10: *hmacAlg = kCCHmacAlgSHA256; *hashLen = CC_SHA256_DIGEST_LENGTH; return 1; // kCCDigestSHA256
    case 11: *hmacAlg = kCCHmacAlgSHA384; *hashLen = CC_SHA384_DIGEST_LENGTH; return 1; // kCCDigestSHA384
    case 12: *hmacAlg = kCCHmacAlgSHA512; *hashLen = CC_SHA512_DIGEST_LENGTH; return 1; // kCCDigestSHA512
    default: return 0;
    }
}

// HKDF (RFC 5869): extract PRK = HMAC(salt, IKM), then expand OKM = T(1..N) where
// T(i) = HMAC(PRK, T(i-1) || info || i), truncated to derivedKeyLen.
int32_t CCDeriveKey(const struct CCKDFParameters *params, uint32_t digest, const void *keyDerivationKey, size_t keyDerivationKeyLen, void *derivedKey, size_t derivedKeyLen)
{
    if (!params || (!derivedKey && derivedKeyLen))
        return kCCParamError;

    CCHmacAlgorithm hmacAlg;
    unsigned hashLen;
    if (!mav_hkdfDigestInfo(digest, &hmacAlg, &hashLen))
        return kCCParamError;

    // HKDF-Extract (RFC 5869 §2.2): empty salt -> HashLen zero bytes.
    unsigned char prk[CC_SHA512_DIGEST_LENGTH];
    if (params->saltLen)
        CCHmac(hmacAlg, params->salt, params->saltLen, keyDerivationKey, keyDerivationKeyLen, prk);
    else {
        unsigned char zeroSalt[CC_SHA512_DIGEST_LENGTH];
        memset(zeroSalt, 0, hashLen);
        CCHmac(hmacAlg, zeroSalt, hashLen, keyDerivationKey, keyDerivationKeyLen, prk);
    }

    // HKDF-Expand (RFC 5869 §2.3).
    size_t N = (derivedKeyLen + hashLen - 1) / hashLen;
    if (N > 255)
        return kCCParamError;

    unsigned char *input = (unsigned char *)malloc(hashLen + params->contextLen + 1);
    if (!input)
        return kCCMemoryFailure;

    unsigned char T[CC_SHA512_DIGEST_LENGTH];
    size_t Tlen = 0, outOffset = 0;
    for (size_t i = 1; i <= N; ++i) {
        size_t pos = 0;
        if (Tlen) { memcpy(input + pos, T, Tlen); pos += Tlen; }
        if (params->contextLen) { memcpy(input + pos, params->context, params->contextLen); pos += params->contextLen; }
        input[pos++] = (unsigned char)i;
        CCHmac(hmacAlg, prk, hashLen, input, pos, T);
        Tlen = hashLen;
        size_t remain = derivedKeyLen - outOffset;
        size_t copyLen = hashLen < remain ? hashLen : remain;
        memcpy((unsigned char *)derivedKey + outOffset, T, copyLen);
        outOffset += copyLen;
    }
    free(input);
    return kCCSuccess;
}
