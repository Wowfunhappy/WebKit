// Native capability overrides for PlatformHave.h's WebKitAdditions hook.

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

// The polyfill layer implements CTFontManagerCreateMemorySafeFontDescriptorFromData and
// FPFontCreateMemorySafeFontsFromData on the OpenType Sanitiser (polyfill/polyfills/c/CoreText.c).
#define HAVE_CTFONTMANAGER_CREATEMEMORYSAFEFONTDESCRIPTORFROMDATA 1

// CoreTelephony is not usable on 10.9; CoreTelephonyUtilities is HAVE(CORE_TELEPHONY)-guarded.
#define HAVE_CORE_TELEPHONY 0

// The WebGPU native bindings (wgpu) are not built for this port.
#define HAVE_WEBGPU_IMPLEMENTATION 0

// The Shape Detection API implementation is built on Vision.framework, which is 10.13+.
#define HAVE_SHAPE_DETECTION_API_IMPLEMENTATION 0

// ISO/IEC 23008-12 image sequences (.heics) decode through this port's GStreamer stack: the file is
// an ISO-BMFF one whose samples are HEVC, so qtdemux and the HEVC decoder carry it, and
// ImageDecoderGStreamer is what the image pipeline reaches for them. Not an upstream macro — this
// port introduces it. Still HEIF images are HEIFImageDecoder's, on libheif; HAVE(HEIC) covers those
// and the image Accept header.
#define HAVE_HEIF_IMAGE_SEQUENCE 1

// Upstream's deployment target is macOS 14, so PlatformHave.h defines the capabilities below for
// every Mac build. Each names an API that shipped in macOS 14 or later (309362@main gated every
// one of them on __MAC_OS_X_VERSION_MIN_REQUIRED >= 140000 or higher), and 10.9's frameworks have
// none of them: NSURLRequest answers no _useEnhancedPrivacyMode, NSWindow no
// _holdResizeSnapshotWithReason:, libsystem_malloc exports no malloc_type_malloc, and so on. Off,
// the code takes the paths upstream keeps for the OS releases before each API.
#define HAVE_APPLE_CAMERA_USER_CLIENT 0
#define HAVE_AUDIOFORMATPROPERTY_VARIABLEPACKET_SUPPORTED 0
#define HAVE_AUDIO_CONVERTER_SERVICE 0
#define HAVE_AUDIO_DEVICE_PROPERTY_REFERENCE_STREAM_ENABLED 0
#define HAVE_AUTOCORRECTION_ENHANCEMENTS 0
#define HAVE_AVASSETWRITER_WITH_OPUS_SUPPORTED 0
#define HAVE_AVAUDIOAPPLICATION 0
#define HAVE_AVAUDIOSESSION_SMARTROUTING 0
#define HAVE_AVSAMPLEBUFFERVIDEORENDERER 0
#define HAVE_AVSPEECHSYNTHESIS_VOICES_CHANGE_NOTIFICATION 0
#define HAVE_CFNETWORK_SEPARATE_CREDENTIAL_STORAGE 0
#define HAVE_COREGRAPHICS_WITH_PDF_AREA_OF_INTEREST_SUPPORT 0
#define HAVE_CORE_CRYPTO_SIGNATURES_INT_RETURN_VALUE 0
#define HAVE_DDSCANNER_QOS_CONFIGURATION 0
#define HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA 0
#define HAVE_JPEGXL 0
#define HAVE_MACH_BOOTSTRAP_EXTENSION 0
#define HAVE_MACH_EVENTLINK 0
#define HAVE_MACH_RANGE_CREATE 0
#define HAVE_NETWORK_RESOLUTION_FAILURE_REPORT 0
#define HAVE_NSCOLOR_FILL_COLOR_HIERARCHY 0
#define HAVE_NSRESPONDER_WRITING_TOOLS_SUPPORT 0
#define HAVE_NSURL_ENCODING_INVALID_CHARACTERS 0
#define HAVE_NSWINDOW_SNAPSHOT_READINESS_HANDLER 0
#define HAVE_NS_EMOJI_IMAGE_STRIKE_PROVENANCE 0
#define HAVE_NS_TEXT_CHECKING_TYPE_MATH_COMPLETION 0
#define HAVE_NWSETTINGS_UNIFIED_HTTP 0
#define HAVE_PASSKIT_APPLE_PAY_LATER_AVAILABILITY 0
#define HAVE_PASSKIT_MERCHANT_CATEGORY_CODE 0
#define HAVE_PDFDOCUMENT_ANNOTATIONS_FOR_FIELD_NAME 0
#define HAVE_PDFDOCUMENT_ENABLE_DATA_DETECTORS 0
#define HAVE_PDFDOCUMENT_RESET_FORM_FIELDS 0
#define HAVE_PDFDOCUMENT_SELECTION_WITH_GRANULARITY 0
#define HAVE_PDFKIT_WITH_NEXT_ACTIONS 0
#define HAVE_PDFPAGE_AREA_OF_INTEREST_AT_POINT 0
#define HAVE_PDFPAGE_DATA_DETECTOR_RESULTS 0
#define HAVE_PDFSELECTION_ENUMERATE_RECTS_AND_TRANSFORMS 0
#define HAVE_PDFSELECTION_HTMLDATA_RTFDATA 0
#define HAVE_PKPAYMENTREQUEST_USERAGENT 0
#define HAVE_REDESIGNED_TEXT_CURSOR 0
#define HAVE_SECURE_ACTION_CONTEXT 0
#define HAVE_STRICT_DECODABLE_CNCONTACT 0
#define HAVE_STRICT_DECODABLE_PKCONTACT 0
#define HAVE_STRICT_DECODABLE_PKPAYMENTPASS 0
#define HAVE_SYSTEM_SUPPORT_FOR_ADVANCED_PRIVACY_PROTECTIONS 0
#define HAVE_TYPE_AWARE_MALLOC 0
#define HAVE_VOICEACTIVITYDETECTION 0
#define HAVE_VPIO_DUCKING_LEVEL_API 0
#define HAVE_WEB_AUTHN_AS_MODERN 0
#define HAVE_WEB_AUTHN_PRF_API 0
#define HAVE_WK_SECURE_CODING_DATA_DETECTORS 0
#define HAVE_X25519_ZERO_CHECKS 0

// The compositor's threaded animations run on CAPresentationModifier (macOS 15). Material hosting
// (CoreMaterial.framework), NSTextSelectionRect, inline predictions, UserNotifications.framework,
// CGStyle colour-matrix and blur styles, continuous rounded rects and CGImage HDR gain maps are
// later system additions as well, and PassKit here has no disbursement classes.
#define HAVE_CORE_MATERIAL 0
#define HAVE_NSTEXTPLACEHOLDER_RECTS 0
#define HAVE_INLINE_PREDICTIONS 0
#define HAVE_FULL_FEATURED_USER_NOTIFICATIONS 0
#define HAVE_CGSTYLE_COLORMATRIX_BLUR 0
#define HAVE_CG_PATH_CONTINUOUS_ROUNDED_RECT 0
#define HAVE_SUPPORT_HDR_DISPLAY 0
#define HAVE_PASSKIT_DISBURSEMENTS 0
