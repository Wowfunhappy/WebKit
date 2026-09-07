// The port's HAVE_* values, supplied through the hook PlatformHave.h has for additions from outside
// the main repository. Every block it preempts is `#if !defined(HAVE_X)`-guarded upstream, so
// defining the value here keeps Source/WTF/wtf/PlatformHave.h byte-upstream. polyfill/headers is on
// every compile's include path (-idirafter, cmake/OptionsMacMavericks.cmake).

#pragma once

// AppKit runs pending -layout passes as part of every window's display cycle from 10.10 on, which is
// what makes -setNeedsLayout:YES guarantee -layout before the next draw. 10.9 runs that pass only for
// a window whose autolayout engine is engaged (measured on 10.9.5: needsLayout + display runs -layout
// with a constraint present and never without one), so a view that lays its subviews out only in
// -layout stays at its initial frames. Views that rely on the implicit pass run it from -viewWillDraw
// when this is off. Not an upstream macro — this port introduces it.
#define HAVE_NSVIEW_IMPLICIT_LAYOUT_PASS 0

// VisionKit image analysis (VKCImageAnalysis) on Mac is macOS 13+.
#define HAVE_VK_IMAGE_ANALYSIS 0

// The modern AuthenticationServices credential manager needs macOS 14; with it on, the isUVPAA path in
// WebAuthenticatorCoordinatorProxy names a soft-link getter whose header only comes in under
// HAVE(WEB_AUTHN_AS_MODERN), which is off at this deployment target. Off, the forward declaration, the
// soft link and the use compile out together. Unreachable here regardless: isUVPAA answers false
// earlier through the nil ASCWebKitSPISupport class.
#define HAVE_WEB_AUTHN_PUBLIC_KEY_CREDENTIAL_MANAGER 0

// This one describes the SDK, not the deployment target: it decides whether WebKit's SPI headers
// re-declare types (IOSurfaceMemoryLedgerTags and friends) that a newer SDK already declares. The
// build SDK is macOS 26.1, so they are declared.
#define HAVE_BROWSER_ENGINE_SUPPORTING_API 1

// ImageDecoderAVFObjC reads its frames through AVAssetReaderSampleReferenceOutput, a class 10.9's
// AVFoundation does not have (nm lists only AVAssetReader{,Output,TrackOutput,AudioMixOutput,
// VideoCompositionOutput}), while +[AVURLAsset audiovisualMIMETypes] still claims video/mp4. With this
// on, ImageDecoder::create picks that decoder ahead of ImageDecoderGStreamer for every video type and
// readSamples() passes a nil output to -[AVAssetReader addOutput:]. Off, upstream's own fall-through
// reaches ImageDecoderGStreamer, the decoder this port's media engine already uses.
#define HAVE_AVASSETREADER 0

// SCNMetalLayer, which SceneKitModelPlayer's layer is, arrived after 10.9: SceneKit.framework here
// exports no such class.
#define HAVE_SCENEKIT 0

// TranslationUIServices.framework is macOS 12+.
#define HAVE_TRANSLATION_UI_SERVICES 0

// LSDatabaseContext.sharedDatabaseContext is 10.10+.
#define HAVE_LSDATABASECONTEXT 0

// getSystemContentDatabaseObject4WebKit reaches LSDatabaseContext (10.10+) as well.
#define HAVE_SYSTEM_CONTENT_LS_DATABASE 0

// ContactsUI.framework, which vends the contact-picker UI, is 10.11+. WKContactPicker and every
// ContactPicker reference is HAVE(CONTACTSUI)-guarded.
#define HAVE_CONTACTSUI 0

// CoreTelephony is not usable on 10.9; CoreTelephonyUtilities is HAVE(CORE_TELEPHONY)-guarded.
#define HAVE_CORE_TELEPHONY 0

// The WebGPU native bindings (wgpu) are not built for this port.
#define HAVE_WEBGPU_IMPLEMENTATION 0

// The Shape Detection API implementation is built on Vision.framework, which is 10.13+.
#define HAVE_SHAPE_DETECTION_API_IMPLEMENTATION 0

// ISO/IEC 23008-12 image sequences (.heics) decode through this port's GStreamer stack: the file is
// an ISO-BMFF one whose samples are HEVC, so qtdemux and the HEVC decoder carry it, and
// ImageDecoderGStreamer is what the image pipeline reaches for them. Not an upstream macro — this
// port introduces it. Distinct from HAVE(HEIC), which describes ImageIO decoding every HEIF flavour
// including still images and puts image/heic in the image Accept header; 10.9's ImageIO decodes none
// of them and nothing here decodes a still HEIF item, so that one stays off.
#define HAVE_HEIF_IMAGE_SEQUENCE 1
