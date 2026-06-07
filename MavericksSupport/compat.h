/* Compatibility shim for macOS 10.9 - provides missing POSIX functions */
#ifndef _COMPAT_H
#define _COMPAT_H

#ifdef __ASSEMBLER__
/* Skip everything for assembly files */
#else

#include <sys/cdefs.h>
#ifdef __APPLE__
#include <CoreAudio/CoreAudioTypes.h>
/* mach_vm_offset_t / MACH_VM_MAX_ADDRESS: not pulled in transitively by
 * <mach/vm_param.h> where WTF expands OS_CONSTANT(EFFECTIVE_ADDRESS_WIDTH)
 * (Packed.h, CompactPointerTuple.h, Signals.cpp, WTFConfig.cpp). */
#include <mach/vm_types.h>
#endif

/* KERN_NOT_FOUND added in macOS 10.13 */
#ifndef KERN_NOT_FOUND
#define KERN_NOT_FOUND 56
#endif

/* Security.framework typedef compatibility: 10.9 uses OpaqueSecXxxRef structs,
   modern WebKit expects __SecXxx structs. Since both are opaque pointers,
   alias them so the typedef doesn't conflict. */
#ifdef __APPLE__
#define OpaqueSecCertificateRef __SecCertificate
#define OpaqueSecKeychainItemRef __SecKeychainItem
#endif

/* Disable WebKit feature flags that require APIs not available on 10.9.
   These override PlatformHave.h definitions. */
#define HAVE_TCC_IOS_14_BIG_SUR_SPI 0
#define ENABLE_DNS_SERVER_FOR_TESTING 0
#define ENABLE_DNS_SERVER_FOR_TESTING_IN_NETWORKING_PROCESS 0
#define HAVE_CFNETWORK_HOSTOVERRIDE 0
#define ENABLE_WEB_TRANSPORT 0
#define ENABLE_IMAGE_ANALYSIS 0
#define ENABLE_IMAGE_ANALYSIS_ENHANCEMENTS 0
#define HAVE_VIDEO_FULLSCREEN_SUPPORT 0
#define ENABLE_APP_STORE_REQUIREMENT_ENFORCEMENT 0
#define HAVE_STYLUS_DEVICE_OBSERVATION 0
#define HAVE_APP_SSO 0
#define HAVE_SCREEN_CAPTURE_KIT 0
#define HAVE_SC_CONTENT_SHARING_PICKER 0
#define ENABLE_MEDIA_STREAM 0
#define ENABLE_REVEAL 0
#define ENABLE_FILE_REPLACEMENT 0
#define HAVE_ACCESSIBILITY_FRAMEWORK 0
#define ENABLE_OPUS 0
#define ENABLE_VORBIS 0
#define ENABLE_VP9 0
#define HAVE_AVCONTENTKEYSESSION 0
#define USE_CORE_IMAGE 0
#define HAVE_TOUCH_BAR 0
#define HAVE_LSDATABASECONTEXT 0
#define HAVE_SYSTEM_CONTENT_LS_DATABASE 0

/* tls_protocol_version_t + tls_protocol_version_TLSv1x are the enum and
 * enumerators defined by pal/spi/cf/CFNetworkSPI.h (#if !HAVE(TLS_PROTOCOL_VERSION_T));
 * do NOT stub them here or the typedef/enum conflict and the #defines break the enum. */

/* CGColorSpaceSupportsOutput (10.12+) */
#ifndef CGColorSpaceSupportsOutput
#define CGColorSpaceSupportsOutput(cs) true
#endif

/* NOTIFY_TOKEN_INVALID (10.12+ in <notify.h>) */
#ifndef NOTIFY_TOKEN_INVALID
#define NOTIFY_TOKEN_INVALID -1
#endif

/* os_state (10.12+) - disable */
#define USE_OS_STATE 0

/* NSURLSession task priority constants (10.10+) */
#ifndef NSURLSessionTaskPriorityDefault
#define NSURLSessionTaskPriorityDefault 0.5f
#define NSURLSessionTaskPriorityLow 0.25f
#define NSURLSessionTaskPriorityHigh 0.75f
#endif

/* NSAttributedStringDocumentReadingOptionKey and NSEdgeInsetsEqual are
   provided in the SDK overlay NSObjCRuntime.h instead of here, since
   compat.h is included before Foundation headers. */

/* Polyfill availability tokens for SDK versions newer than 10.9 */
#define __NSi_10_10 introduced=10.10
#define __NSi_10_10_2 introduced=10.10.2
#define __NSi_10_10_3 introduced=10.10.3
#define __NSi_10_11 introduced=10.11
#define __NSi_10_11_2 introduced=10.11.2
#define __NSi_10_11_3 introduced=10.11.3
#define __NSi_10_11_4 introduced=10.11.4
#define __NSi_10_12 introduced=10.12
#define __NSi_10_12_1 introduced=10.12.1
#define __NSi_10_12_2 introduced=10.12.2
#define __NSi_10_12_4 introduced=10.12.4
#define __NSi_10_13 introduced=10.13
#define __NSi_10_13_1 introduced=10.13.1
#define __NSi_10_13_2 introduced=10.13.2
#define __NSi_10_13_4 introduced=10.13.4
#define __NSi_10_14 introduced=10.14
#define __NSi_10_14_1 introduced=10.14.1
#define __NSi_10_14_4 introduced=10.14.4
#define __NSi_10_15 introduced=10.15
#define __NSi_10_15_1 introduced=10.15.1
#define __NSi_10_15_4 introduced=10.15.4
#define __NSi_10_16 introduced=10.16
#define __NSi_11_0 introduced=11.0
#define __NSi_11_3 introduced=11.3
#define __NSi_12_0 introduced=12.0
#define __NSi_12_3 introduced=12.3
#define __NSi_13_0 introduced=13.0
#define __NSi_13_3 introduced=13.3
#define __NSi_14_0 introduced=14.0
#define __NSi_15_0 introduced=15.0
#define __NSd_10_10 deprecated=10.10
#define __NSd_10_11 deprecated=10.11
#define __NSd_10_12 deprecated=10.12
#define __NSd_10_13 deprecated=10.13
#define __NSd_10_14 deprecated=10.14
#define __NSd_10_15 deprecated=10.15

/* Skip Swift interop code */
#ifndef CLANG_WEBKIT_BRANCH
#define CLANG_WEBKIT_BRANCH 0

/* Disable all Apple Pay sub-features since APPLE_PAY is OFF */
#define ENABLE_APPLE_PAY_AUTOMATIC_RELOAD_LINE_ITEM 0
#define ENABLE_APPLE_PAY_AUTOMATIC_RELOAD_PAYMENTS 0
#define ENABLE_APPLE_PAY_COUPON_CODE 0
#define ENABLE_APPLE_PAY_DEFERRED_LINE_ITEM 0
#define ENABLE_APPLE_PAY_FEATURES 0
#define ENABLE_APPLE_PAY_INSTALLMENTS 0
#define ENABLE_APPLE_PAY_LATER 0
#define ENABLE_APPLE_PAY_LATER_AVAILABILITY 0
#define ENABLE_APPLE_PAY_MERCHANT_CATEGORY_CODE 0
#define ENABLE_APPLE_PAY_MULTI_MERCHANT_PAYMENTS 0
#define ENABLE_APPLE_PAY_NEW_BUTTON_TYPES 0
#define ENABLE_APPLE_PAY_RECURRING_LINE_ITEM 0
#define ENABLE_APPLE_PAY_RECURRING_PAYMENTS 0
#define ENABLE_APPLE_PAY_SHIPPING_CONTACT_EDITING_MODE 0
#define ENABLE_APPLE_PAY_UPDATE_SHIPPING_METHODS_WHEN_CHANGING_LINE_ITEMS 0
#define ENABLE_APPLE_PAY_DISBURSEMENTS 0
#define ENABLE_APPLE_PAY_SHIPPING_METHOD_DATE_COMPONENTS_RANGE 0
#define ENABLE_APPLE_PAY_SETUP 0
#define ENABLE_APPLE_PAY_SESSION_V11 0
#define ENABLE_APPLE_PAY_SELECTED_SHIPPING_METHOD 0
#define ENABLE_APPLE_PAY_REMOTE_UI_USES_SCENE 0
#define ENABLE_APPLE_PAY_REMOTE_UI 0
#define ENABLE_APPLE_PAY_PAYMENT_ORDER_DETAILS 0
#define ENABLE_APPLE_PAY_DELEGATED_REQUEST 0
#define ENABLE_APPLE_PAY_DEFERRED_PAYMENTS 0
#define ENABLE_APPLE_PAY_AMS_UI 0
#endif
#include <sys/types.h>

/* ===== mach VM types needed before vm_param.h ===== */
#ifdef __APPLE__
#include <mach/i386/vm_types.h>
#endif

/* ===== clock_gettime (macOS 10.12+) ===== */
#ifndef CLOCK_REALTIME
#include <time.h>
typedef int clockid_t;
enum {
  _CLOCK_REALTIME = 0,
  _CLOCK_MONOTONIC = 6,
  _CLOCK_MONOTONIC_RAW = 4,
  _CLOCK_MONOTONIC_RAW_APPROX = 5,
  _CLOCK_UPTIME_RAW = 8,
  _CLOCK_UPTIME_RAW_APPROX = 9,
  _CLOCK_PROCESS_CPUTIME_ID = 12,
  _CLOCK_THREAD_CPUTIME_ID = 16
};
#define CLOCK_REALTIME _CLOCK_REALTIME
#define CLOCK_MONOTONIC _CLOCK_MONOTONIC
#define CLOCK_MONOTONIC_RAW _CLOCK_MONOTONIC_RAW
#define CLOCK_MONOTONIC_RAW_APPROX _CLOCK_MONOTONIC_RAW_APPROX
#define CLOCK_UPTIME_RAW _CLOCK_UPTIME_RAW
#define CLOCK_UPTIME_RAW_APPROX _CLOCK_UPTIME_RAW_APPROX
#define CLOCK_PROCESS_CPUTIME_ID _CLOCK_PROCESS_CPUTIME_ID
#define CLOCK_THREAD_CPUTIME_ID _CLOCK_THREAD_CPUTIME_ID
__BEGIN_DECLS
extern int clock_gettime(clockid_t, struct timespec *);
extern int clock_getres(clockid_t, struct timespec *);
__END_DECLS
#endif

/* ===== *at() functions (macOS 10.10+) ===== */
#ifndef AT_FDCWD
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#define AT_FDCWD -2
#define AT_SYMLINK_NOFOLLOW 0x0020
#define AT_REMOVEDIR 0x0080
#define AT_SYMLINK_FOLLOW 0x0040
#define AT_EACCESS 0x0010
__BEGIN_DECLS
extern int openat(int, const char *, int, ...);
extern int unlinkat(int, const char *, int);
extern int renameat(int, const char *, int, const char *);
extern int fchmodat(int, const char *, mode_t, int);
extern int fchownat(int, const char *, uid_t, gid_t, int);
extern int linkat(int, const char *, int, const char *, int);
extern int symlinkat(const char *, int, const char *);
extern int mkdirat(int, const char *, mode_t);
extern ssize_t readlinkat(int, const char *, char *, size_t);
extern int faccessat(int, const char *, int, int);
extern DIR *fdopendir(int);
extern int utimensat(int, const char *, const struct timespec[2], int);
__END_DECLS
#endif

/* ===== utimensat constants ===== */
#ifndef UTIME_NOW
#define UTIME_NOW  -1
#define UTIME_OMIT -2
#endif

/* ===== getentropy (macOS 10.12+) ===== */
#ifdef __cplusplus
extern "C" {
#endif
int getentropy(void *buf, size_t buflen);
#ifdef __cplusplus
}
#endif

/* ===== fstatat (macOS 10.10+) ===== */
#include <sys/stat.h>
__BEGIN_DECLS
extern int fstatat(int, const char *, struct stat *, int);
__END_DECLS

/* ===== memmem (macOS 10.7+ but sometimes missing) ===== */
#include <string.h>
__BEGIN_DECLS
extern void *memmem(const void *, size_t, const void *, size_t);
__END_DECLS

/* ===== dispatch types (macOS 10.10+/10.12+) ===== */
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#ifndef DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL
typedef dispatch_queue_t dispatch_queue_main_t;
typedef dispatch_queue_t dispatch_queue_global_t;
typedef unsigned int dispatch_qos_class_t;
#define DISPATCH_QOS_CLASS_USER_INTERACTIVE 0x21
#define DISPATCH_QOS_CLASS_USER_INITIATED   0x19
#define DISPATCH_QOS_CLASS_DEFAULT          0x15
#define DISPATCH_QOS_CLASS_UTILITY          0x11
#define DISPATCH_QOS_CLASS_BACKGROUND       0x09
#define DISPATCH_QOS_CLASS_UNSPECIFIED      0x00
#define DISPATCH_BLOCK_ENFORCE_QOS_CLASS    0x04

/* dispatch_queue_attr_make_with_qos_class stub - just returns the base attr */
static inline dispatch_queue_attr_t
_compat_dispatch_queue_attr_make_with_qos_class(dispatch_queue_attr_t attr,
    dispatch_qos_class_t qos, int relative_priority) {
    (void)qos; (void)relative_priority;
    return attr;
}
#define dispatch_queue_attr_make_with_qos_class _compat_dispatch_queue_attr_make_with_qos_class
#endif
#endif

/* ===== pthread QoS (macOS 10.10+) ===== */
#ifdef __APPLE__
#include <pthread.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef PTHREAD_HAS_QOS_CLASS_NP
/* Use unsigned int directly since qos_class_t may not be defined yet in C mode */
static inline int pthread_set_qos_class_self_np(unsigned int c, int p) {
    (void)c; (void)p; return 0;
}
static inline int pthread_get_qos_class_np(pthread_t t, unsigned int *c, int *p) {
    (void)t; if (c) *c = 0x15; if (p) *p = 0; return 0;
}
static inline int pthread_attr_set_qos_class_np(pthread_attr_t *a, unsigned int c, int p) {
    (void)a; (void)c; (void)p; return 0;
}
#define PTHREAD_HAS_QOS_CLASS_NP 1
#endif
#ifdef __cplusplus
}
#endif
#endif

/* ===== VM flags (macOS 10.12+) ===== */
#ifndef VM_FLAGS_PERMANENT
#define VM_FLAGS_PERMANENT 0
#endif
#ifndef VM_MEMORY_IOACCELERATOR
#define VM_MEMORY_IOACCELERATOR 78
#endif
#ifndef VM_MEMORY_IOSURFACE
#define VM_MEMORY_IOSURFACE 79
#endif
#ifndef VM_MEMORY_MALLOC_MEDIUM
#define VM_MEMORY_MALLOC_MEDIUM 12
#endif

/* ===== os_retain / os_release (libdispatch as OS objects, macOS 10.10+) ===== */
#ifdef __APPLE__
#ifndef os_retain
#define os_retain(obj) dispatch_retain((dispatch_object_t)(obj))
#define os_release(obj) dispatch_release((dispatch_object_t)(obj))
#endif
#endif

/* ===== mach_approximate_time / mach_continuous_time (macOS 10.10+/10.12+) ===== */
#ifdef __APPLE__
#include <mach/mach_time.h>
#ifdef __cplusplus
extern "C" {
#endif
static inline uint64_t mach_approximate_time(void) {
    return mach_absolute_time();
}
static inline uint64_t mach_continuous_time(void) {
    return mach_absolute_time();
}
static inline uint64_t mach_continuous_approximate_time(void) {
    return mach_absolute_time();
}
#ifdef __cplusplus
}
#endif
#endif /* __APPLE__ */

/* ===== aligned_alloc (C11 / macOS 10.15+) ===== */
#include <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
static inline void *_compat_aligned_alloc(size_t alignment, size_t size) {
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment < sizeof(void*) ? sizeof(void*) : alignment, size) != 0)
        return NULL;
    return ptr;
}
#ifdef __cplusplus
}
#endif
/* Only define the macro if aligned_alloc is not already available */
#ifndef aligned_alloc
#define aligned_alloc(alignment, size) _compat_aligned_alloc(alignment, size)
#endif

/* ===== QoS classes (macOS 10.10+) ===== */
#include <sys/types.h>
#ifndef QOS_CLASS_DEFAULT
typedef unsigned int qos_class_t;
#define QOS_CLASS_USER_INTERACTIVE 0x21
#define QOS_CLASS_USER_INITIATED   0x19
#define QOS_CLASS_DEFAULT          0x15
#define QOS_CLASS_UTILITY          0x11
#define QOS_CLASS_BACKGROUND       0x09
#define QOS_CLASS_UNSPECIFIED      0x00
#define QOS_MIN_RELATIVE_PRIORITY (-15)
#endif

/* ===== mkostemp (not available on macOS 10.9) ===== */
#include <stdlib.h>
#include <fcntl.h>
#ifdef __cplusplus
extern "C" {
#endif
static inline int _compat_mkostemp(char *tmpl, int flags) {
    int fd = mkstemp(tmpl);
    if (fd >= 0 && (flags & O_CLOEXEC)) {
        fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
    }
    return fd;
}
#ifdef __cplusplus
}
#endif
#define mkostemp(tmpl, flags) _compat_mkostemp(tmpl, flags)

/* mkostemps - like mkstemps but with flags */
#ifdef __cplusplus
extern "C" {
#endif
static inline int _compat_mkostemps(char *tmpl, int suffixlen, int flags) {
    int fd = mkstemps(tmpl, suffixlen);
    if (fd >= 0 && (flags & O_CLOEXEC)) {
        fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
    }
    return fd;
}
#ifdef __cplusplus
}
#endif
#define mkostemps(tmpl, suffixlen, flags) _compat_mkostemps(tmpl, suffixlen, flags)

/* ObjC nullability and Swift interop macros for old SDKs */
#ifdef __OBJC__
#ifndef NS_DESIGNATED_INITIALIZER
#define NS_DESIGNATED_INITIALIZER
#endif
#ifndef NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_BEGIN _Pragma("clang assume_nonnull begin")
#define NS_ASSUME_NONNULL_END _Pragma("clang assume_nonnull end")
#endif
#ifndef NS_SWIFT_NAME
#define NS_SWIFT_NAME(name)
#endif
#ifndef NS_SWIFT_UNAVAILABLE
#define NS_SWIFT_UNAVAILABLE(msg)
#endif
#ifndef NS_REFINED_FOR_SWIFT
#define NS_REFINED_FOR_SWIFT
#endif
#ifndef NS_SWIFT_ASYNC_NAME
#define NS_SWIFT_ASYNC_NAME(name)
#endif
#ifndef NS_SWIFT_NONISOLATED
#define NS_SWIFT_NONISOLATED
#endif
#ifndef NS_HEADER_AUDIT_BEGIN
#define NS_HEADER_AUDIT_BEGIN(...)
#define NS_HEADER_AUDIT_END(...)
#endif
#ifndef NS_SWIFT_SENDABLE
#define NS_SWIFT_SENDABLE
#endif
#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
#ifndef NS_SWIFT_NAME
#define NS_SWIFT_NAME(x)
#endif
#ifndef OS_NOTHROW
#define OS_NOTHROW __attribute__((__nothrow__))
#endif
#ifndef NS_SWIFT_NONSENDABLE
#define NS_SWIFT_NONSENDABLE
#endif
#ifndef NS_REFINED_FOR_SWIFT
#define NS_REFINED_FOR_SWIFT
#endif
#ifndef API_AVAILABLE
#define API_AVAILABLE(...)
#endif
#ifndef API_UNAVAILABLE
#define API_UNAVAILABLE(...)
#endif
#ifndef API_DEPRECATED
#define API_DEPRECATED(...)
#endif
#ifndef API_DEPRECATED_WITH_REPLACEMENT
#define API_DEPRECATED_WITH_REPLACEMENT(...)
#endif
#ifndef SPI_AVAILABLE
#define SPI_AVAILABLE(...)
#endif
#ifndef SPI_AVAILABLE_BUT_DEPRECATED
#define SPI_AVAILABLE_BUT_DEPRECATED(...)
#endif
/* NSPersonNameComponents (10.11+) */
@class NSPersonNameComponents;
/* NSNotificationName (10.12+) */
/* NSPersonNameComponents (10.11+) */
@class NSPersonNameComponents;
#ifndef NSNotificationName
/* NSPersonNameComponents (10.11+) */
@class NSPersonNameComponents;
typedef NSString *NSNotificationName;
#endif
/* NSControlSizeMini (renamed in 10.12) */
#ifndef NSControlSizeMini
#define NSControlSizeMini NSMiniControlSize
#define NSControlSizeSmall NSSmallControlSize
#define NSControlSizeRegular NSRegularControlSize
#define NSControlSizeLarge ((NSControlSize)3)
#endif
/* NSWindowStyleMask (renamed in 10.12) */
#ifndef NSWindowStyleMaskMiniaturizable
typedef NSUInteger NSWindowStyleMask;
#define NSWindowStyleMaskMiniaturizable NSMiniaturizableWindowMask
#define NSWindowStyleMaskResizable NSResizableWindowMask
#define NSWindowStyleMaskClosable NSClosableWindowMask
#define NSWindowStyleMaskTitled NSTitledWindowMask
#define NSWindowStyleMaskFullScreen (1 << 14)
#define NSWindowStyleMaskBorderless NSBorderlessWindowMask
#define NSWindowStyleMaskUnifiedTitleAndToolbar NSUnifiedTitleAndToolbarWindowMask
#define NSWindowStyleMaskFullSizeContentView (1 << 15)
#endif
#if defined(__OBJC__) && !defined(NSErrorDomain_DEFINED)
#define NSErrorDomain_DEFINED 1
typedef NSString *NSErrorDomain;
typedef NSString *NSExceptionName;
typedef NSString *NSNotificationName;
typedef NSString *NSRunLoopMode;
typedef NSString *NSAttributedStringDocumentAttributeKey;
typedef NSString *NSAttributedStringDocumentType;
#endif
/* NSEventModifierFlags (renamed in 10.12) */
#ifndef NSEventModifierFlagShift
#define NSEventModifierFlagShift NSShiftKeyMask
#define NSEventModifierFlagControl NSControlKeyMask
#define NSEventModifierFlagOption NSAlternateKeyMask
#define NSEventModifierFlagCommand NSCommandKeyMask
#endif
/* NSEventTypePressure (10.10.3+) */
#ifndef NSEventTypePressure
#define NSEventTypePressure 34
#endif
/* NSLevelIndicatorStyleContinuousCapacity (renamed in 10.14) */
#ifndef NSLevelIndicatorStyleContinuousCapacity
#define NSLevelIndicatorStyleContinuousCapacity NSContinuousCapacityLevelIndicatorStyle
#endif
/* NSSliderTypeLinear / NSSliderTypeCircular (renamed in 10.12) */
#ifndef NSSliderTypeLinear
#define NSSliderTypeLinear NSLinearSlider
#define NSSliderTypeCircular NSCircularSlider
#endif
/* NSBezelStyle (renamed in 10.12) */
#ifndef NSBezelStyleShadowlessSquare
#define NSBezelStyleShadowlessSquare NSShadowlessSquareBezelStyle
#define NSBezelStyleRounded NSRoundedBezelStyle
#define NSBezelStyleRegularSquare NSRegularSquareBezelStyle
#define NSBezelStyleThickSquare NSThickSquareBezelStyle
#define NSBezelStyleThickerSquare NSThickerSquareBezelStyle
#define NSBezelStyleDisclosure NSDisclosureBezelStyle
#define NSBezelStyleCircular NSCircularBezelStyle
#define NSBezelStyleTexturedSquare NSTexturedSquareBezelStyle
#define NSBezelStyleHelpButton NSHelpButtonBezelStyle
#define NSBezelStyleSmallSquare NSSmallSquareBezelStyle
#define NSBezelStyleTexturedRounded NSTexturedRoundedBezelStyle
#define NSBezelStyleRoundRect NSRoundRectBezelStyle
#define NSBezelStyleRecessed NSRecessedBezelStyle
#define NSBezelStyleRoundedDisclosure NSRoundedDisclosureBezelStyle
#define NSBezelStyleInline NSInlineBezelStyle
#endif
/* NSButtonType (renamed in 10.12) */
#ifndef NSButtonTypeMomentaryPushIn
#define NSButtonTypeMomentaryPushIn NSMomentaryPushInButton
#define NSButtonTypeMomentaryLight NSMomentaryLightButton
#define NSButtonTypePushOnPushOff NSPushOnPushOffButton
#define NSButtonTypeOnOff NSOnOffButton
#define NSButtonTypeMomentaryChange NSMomentaryChangeButton
#define NSButtonTypeSwitch NSSwitchButton
#define NSButtonTypeRadio NSRadioButton
#define NSButtonTypeToggle NSToggleButton
#define NSButtonTypeAccelerator (NSToggleButton + 1)
#define NSButtonTypeMultiLevelAccelerator (NSToggleButton + 2)
#endif

/* NSTextAlignment constants (10.11+ renamed from NSLeftTextAlignment etc.) */
#ifndef NSTextAlignmentLeft
#define NSTextAlignmentLeft NSLeftTextAlignment
#define NSTextAlignmentRight NSRightTextAlignment
#define NSTextAlignmentCenter NSCenterTextAlignment
#define NSTextAlignmentJustified NSJustifiedTextAlignment
#define NSTextAlignmentNatural NSNaturalTextAlignment
#endif

/* NSAttributedStringKey (10.12+) - just a typedef for NSString* */
#ifndef NSAttributedStringKey
typedef NSString *NSAttributedStringKey;
#endif

/* NSTextListMarkerFormat (10.13+) */
#ifndef NSTextListMarkerFormat
typedef NSString *NSTextListMarkerFormat;
/* NSTextList marker format strings */
#define NSTextListMarkerDisc @"{disc}"
#define NSTextListMarkerCircle @"{circle}"
#define NSTextListMarkerSquare @"{square}"
#define NSTextListMarkerDecimal @"{decimal}"
#define NSTextListMarkerOctal @"{octal}"
#define NSTextListMarkerLowercaseRoman @"{lower-roman}"
#define NSTextListMarkerUppercaseRoman @"{upper-roman}"
#define NSTextListMarkerLowercaseAlpha @"{lower-alpha}"
#define NSTextListMarkerUppercaseAlpha @"{upper-alpha}"
#define NSTextListMarkerLowercaseLatin @"{lower-latin}"
#define NSTextListMarkerUppercaseLatin @"{upper-latin}"
#define NSTextListMarkerLowercaseHexadecimal @"{lower-hexadecimal}"
#define NSTextListMarkerUppercaseHexadecimal @"{upper-hexadecimal}"
#endif

/* NSPresentationIntentAttributeName (macOS 12+) */
#ifndef NSPresentationIntentAttributeName
#define NSPresentationIntentAttributeName @"NSPresentationIntent"
/* NSPresentationIntent class defined after Foundation import below */
#endif

/* CGColorCreateSRGB (macOS 10.15+) - use inline expansion at use site via macro.
   CGColorSpaceCreateWithName + CGColorCreate are always available when CG is included. */
#ifndef CGColorCreateSRGB
#define CGColorCreateSRGB(r,g,b,a) ({ \
    CGColorSpaceRef _srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); \
    CGFloat _comps[4] = {(r), (g), (b), (a)}; \
    CGColorRef _c = CGColorCreate(_srgb, _comps); \
    CGColorSpaceRelease(_srgb); \
    _c; \
})
#endif

/* NSHTTPCookieSameSitePolicy (10.15+) */
#ifndef NSHTTPCookieSameSitePolicy
typedef NSString *NSHTTPCookieSameSitePolicy;
#define NSHTTPCookieSameSiteStrict @"strict"
#define NSHTTPCookieSameSiteLax @"lax"
#endif

/* NSHTTPCookiePropertyKey (10.12+) */
#ifndef NSHTTPCookiePropertyKey_DEFINED
#define NSHTTPCookiePropertyKey_DEFINED
typedef NSString *NSHTTPCookiePropertyKey;
#endif

/* AXCustomContentImportanceHigh (macOS 12+ accessibility) */
#ifndef AXCustomContentImportanceHigh
#define AXCustomContentImportanceHigh 1
#endif

#endif /* __OBJC__ */

/* IOSurfaceRef from IOSurface framework */
#include <IOSurface/IOSurface.h>
/* NOTE: CAIOSurfaceRef is defined by pal/spi/cocoa/QuartzCoreSPI.h (as
 * struct _CAIOSurface*); do NOT stub it here or it conflicts. */
/* CMTaggedBufferGroupRef (newer CoreMedia) */
typedef void *CMTaggedBufferGroupRef;
typedef void *CMTaggedBufferGroupFormatDescriptionRef;
/* DDResultRef / DDScannerRef */
/* CF_BRIDGED_TYPE for old SDKs */
#ifndef CF_BRIDGED_TYPE
#define CF_BRIDGED_TYPE(T)
#endif

/* CM_RETURNS_RETAINED_PARAMETER (newer CoreMedia) */
/* NOTE: FigThreadAbortAction/Token are defined by pal/spi/cf/CoreMediaSPI.h
 * (as void(*)(void*) / struct OpaqueFigThreadAbortActionToken*); do NOT stub
 * them here or they conflict. */
/* CoreMedia macros for old SDKs */
#ifndef CF_NOESCAPE
#define CF_NOESCAPE
#endif
#ifndef CMSAMPLEBUFFERCALL_NOESCAPE
#define CMSAMPLEBUFFERCALL_NOESCAPE
#endif
/* CMTag (macOS 14+) — only here (no SPI header defines these).
 * CMBaseObjectRef/CMBaseVTable/CMBaseClassID are defined by libwebrtc's
 * CMBaseObjectSPI.h (pulled in by CoreMediaSPI.h); do NOT stub them here. */
#ifndef CMTag
typedef struct { uint64_t value; uint32_t category; } CMTag;
typedef uint32_t CMTagCategory;
typedef void *CMTagCollectionRef;
#endif
#ifndef CM_RETURNS_RETAINED_PARAMETER
#define CM_RETURNS_RETAINED_PARAMETER
#endif
#ifndef task_id_token_t
typedef unsigned int task_id_token_t;
#endif
/* PKCanMakePaymentsCompletion */
#ifdef __OBJC__
#ifndef PKCanMakePaymentsCompletion
typedef void (^PKCanMakePaymentsCompletion)(BOOL);
#endif
#endif

/* WebGPU types (stub) */
typedef uint32_t WGPUTextureFormat;
typedef void *WGPUTexture;
typedef void *WGPUTextureView;
typedef void *WGPUBindGroupLayout;
typedef void *WGPUBindGroup;
typedef void *WGPURenderPipeline;
typedef void *WGPUComputePipeline;
typedef void *WGPUPipelineLayout;
typedef void *WGPUShaderModule;
typedef void *WGPUDevice;
typedef void *WGPUQueue;
typedef void *WGPUBuffer;
typedef void *WGPUSampler;
typedef void *WGPURenderPassEncoder;
typedef void *WGPUCommandEncoder;
typedef void *WGPUComputePassEncoder;
typedef uint32_t WGPUPresentMode;
typedef uint32_t WGPUCompositeAlphaMode;

/* nw_path_t (Network.framework 10.14+) */

/* VTDecompressionOutputHandler (VideoToolbox 10.11+) */
typedef void (^VTDecompressionOutputHandler)(int status, int flags, void *imageBuffer, long long pts, long long duration);
typedef void (^VTDecompressionMultiImageCapableOutputHandler)(int status, int flags, void *imageBuffer, long long pts, long long duration, void *taggedBufferGroup);

/* CAFilter is declared by pal/spi/cocoa/QuartzCoreSPI.h (@interface); do NOT
 * redeclare it here or it is a duplicate interface definition. */

#endif /* !__ASSEMBLER__ */
#endif /* _COMPAT_H */

/* Missing NSAccessibility constants for 10.9 */
#ifdef __OBJC__
#ifndef NSAccessibilityRequiredAttribute
#define NSAccessibilityRequiredAttribute @"AXRequired"
#endif
#endif

/* NSRectEdge constants (renamed in 10.12) */
#ifndef NSRectEdgeMinY
#define NSRectEdgeMinY 1
#define NSRectEdgeMinX 0
#define NSRectEdgeMaxY 3
#define NSRectEdgeMaxX 2
#endif

/* Pre-declare PAL namespace for soft-link macro expansion */
#ifdef __cplusplus
namespace PAL {}
#endif

/* NSAppearance dark mode (10.14+) */
#ifdef __OBJC__
#ifndef NSAppearanceNameDarkAqua
#define NSAppearanceNameDarkAqua @"NSAppearanceNameDarkAqua"
#endif
/* CALayerDelegate: On 10.9, CALayer.h uses an informal protocol via
   @interface NSObject (CALayerDelegate). Modern WebKit expects a formal
   @protocol CALayerDelegate, but defining it here conflicts with the
   QuartzCore category definition and breaks header parsing. Instead,
   we define the macro to suppress code that checks for CALayerDelegate
   conformance; the informal protocol provides the same methods. */
#endif

/* kAudioObjectPropertyElementMain (renamed from kAudioObjectPropertyElementMaster in 12.0+) */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain 0
#endif

/* kCMVideoCodecType_HEVC (10.13+) */
#ifndef kCMVideoCodecType_HEVC
#define kCMVideoCodecType_HEVC 'hvc1'
#endif
/* kCMVideoCodecType_VP9 (10.13+), _AV1 (11.0+), kAudioFormatOpus (10.13+) */
#ifndef kCMVideoCodecType_VP9
#define kCMVideoCodecType_VP9 'vp09'
#endif
#ifndef kCMVideoCodecType_AV1
#define kCMVideoCodecType_AV1 'av01'
#endif
#ifndef kAudioFormatOpus
#define kAudioFormatOpus 'opus'
#endif
/* UTTypePackage (UniformTypeIdentifiers, 11.0) — dead at runtime on 10.9
 * (the NSURLContentTypeKey lookup feeding it fails); nil sentinel for compile. */
#ifndef UTTypePackage
#define UTTypePackage ((UTType *)nil)
#endif

/* AudioFormatFlags */
#ifndef AudioFormatFlags
typedef UInt32 AudioFormatFlags;
#endif
#ifndef AudioFormatID
typedef UInt32 AudioFormatID;
#endif

/* kCTFontOpenTypeFeatureTag (newer CoreText) */
#ifndef kCTFontOpenTypeFeatureTag
#define kCTFontOpenTypeFeatureTag CFSTR("CTFeatureOpenTypeTag")
#endif
#ifndef kCTFontOpenTypeFeatureValue
#define kCTFontOpenTypeFeatureValue CFSTR("CTFeatureOpenTypeValue")
#endif


/* NSCompositing* renamed in macOS 10.12 */
#ifdef __OBJC__
#ifndef NSCompositingOperationSourceOver
#define NSCompositingOperationSourceOver NSCompositeSourceOver
#define NSCompositingOperationCopy NSCompositeCopy
#define NSCompositingOperationDestinationOver NSCompositeDestinationOver
#endif
#endif

/* nw_path_t / nw_connection_t (Network.framework types not on 10.9)
 * Now handled by NetworkSPI.h and CFNetworkSPI.h - do not define here. */
#ifndef nw_path_status_t
typedef uint32_t nw_path_status_t;
#endif

/* NS_NOESCAPE for old SDKs */
#ifdef __OBJC__
#ifndef NS_NOESCAPE
#define NS_NOESCAPE
#endif
#endif

/* NSURLSession task metrics (10.12+) - declared in CFNetworkSPI.h */

/* NSURLSessionWebSocket (10.15+) */
#ifdef __OBJC__
#import <Foundation/Foundation.h>

/* NSPresentationIntent (macOS 12+) - needs Foundation for NSObject */
#ifndef NSPresentationIntent_DEFINED
#define NSPresentationIntent_DEFINED
@interface NSPresentationIntent : NSObject
@end
#endif

/* NSURLSessionWebSocketTask is declared by pal/spi/cf/CFNetworkSPI.h; only
 * NSURLSessionWebSocketMessage is unique to compat.h. */
@interface NSURLSessionWebSocketMessage : NSObject
@end
#ifndef NSURLSessionWebSocketCloseCode
typedef NSInteger NSURLSessionWebSocketCloseCode;
#endif
#endif

/* SecTrustEvaluateWithError (10.14+) */
#ifdef __cplusplus
extern "C" {
#endif
int SecTrustEvaluateWithError(void *trust, void **error);
#ifdef __cplusplus
}
#endif

/* NSBitmapImageFileType renamed in 10.12 */
#ifdef __OBJC__
#ifndef NSBitmapImageFileTypePNG
#define NSBitmapImageFileTypePNG NSPNGFileType
#define NSBitmapImageFileTypeJPEG NSJPEGFileType
#define NSBitmapImageFileTypeTIFF NSTIFFFileType
#endif
#endif

/* NSDecodingFailurePolicy (10.11+) */
#ifdef __OBJC__
#ifndef NSDecodingFailurePolicyRaiseException
#define NSDecodingFailurePolicyRaiseException 0
#endif
#endif

/* NSTouchBar (10.12.1+) */
#ifdef __OBJC__
#ifndef NSTouchBar
@interface NSTouchBar : NSObject
@property (copy) NSArray *defaultItemIdentifiers;
@end
typedef NSString *NSTouchBarItemIdentifier;
#define NSTouchBarItemIdentifierTextFormat @"NSTouchBarItemIdentifierTextFormat"
#define NSTouchBarItemIdentifierCandidateList @"NSTouchBarItemIdentifierCandidateList"
#endif
/* NSTextAlignment renamed (10.11+) */
#ifndef NSTextAlignmentLeft
#define NSTextAlignmentLeft NSLeftTextAlignment
#define NSTextAlignmentRight NSRightTextAlignment
#define NSTextAlignmentCenter NSCenterTextAlignment
#define NSTextAlignmentJustified NSJustifiedTextAlignment
#endif
#endif

/* kCATransactionPhase* are enumerators of QuartzCoreSPI.h's CATransactionPhase
 * enum; do NOT #define them here or they break that enum ("expected identifier"). */

/* PDFViewDelegate (10.12+ - renamed from PDFView informal delegate) */
#ifdef __OBJC__
@protocol PDFViewDelegate <NSObject>
@optional
@end
/* NSEventModifierFlags (renamed in 10.12) */
#ifndef NSEventModifierFlags
typedef NSUInteger NSEventModifierFlags;
#endif
#endif

/* NS_EXTENSIBLE_STRING_ENUM (10.12+) */
#ifdef __OBJC__
#ifndef NS_EXTENSIBLE_STRING_ENUM
#define NS_EXTENSIBLE_STRING_ENUM
#endif
#ifndef NS_STRING_ENUM
#define NS_STRING_ENUM
#endif
#endif

/* NSWindow.onActiveSpace (10.11+) */
#ifdef __OBJC__
#import <AppKit/AppKit.h>
@interface NSWindow (Compat109)
@property (readonly, getter=isOnActiveSpace) BOOL onActiveSpace;
@end
#endif

/* NSTouchBarItem (10.12.1+) */
#ifdef __OBJC__
#ifndef NSTouchBarItem
@interface NSTouchBarItem : NSObject
@end
@interface NSColorPickerTouchBarItem : NSTouchBarItem
@property (weak) id target;
@property SEL action;
@property (strong) NSColor *color;
@end
@interface NSCustomTouchBarItem : NSTouchBarItem
@end
#endif
#endif

/* More NSTouchBar types */
#ifdef __OBJC__
@interface NSGroupTouchBarItem : NSTouchBarItem
@property (strong) NSTouchBar *groupTouchBar;
@end
#ifndef NSSpellCheckerDidChangeAutomaticTextCompletionNotification
#define NSSpellCheckerDidChangeAutomaticTextCompletionNotification NSSpellCheckerDidChangeAutomaticTextReplacementNotification
#endif
#endif

/* NSCandidateListTouchBarItem (10.12.1+) */
#ifdef __OBJC__
#ifndef NSCandidateListTouchBarItem
@interface NSCandidateListTouchBarItem : NSTouchBarItem
@end
#endif
#endif

/* More NSTouchBar identifiers */
#ifdef __OBJC__
#ifndef NSTouchBarItemIdentifierTextList
#define NSTouchBarItemIdentifierTextList @"NSTouchBarItemIdentifierTextList"
#define NSTouchBarItemIdentifierTextStyle @"NSTouchBarItemIdentifierTextStyle"
#define NSTouchBarItemIdentifierTextAlignment @"NSTouchBarItemIdentifierTextAlignment"
#define NSTouchBarItemIdentifierTextColorPicker @"NSTouchBarItemIdentifierTextColorPicker"
#define NSTouchBarItemIdentifierFlexibleSpace @"NSTouchBarItemIdentifierFlexibleSpace"
#endif
#endif

/* NSEvent type constants renamed in 10.12 */
#ifdef __OBJC__
#ifndef NSEventTypeLeftMouseDown
#define NSEventTypeLeftMouseDown NSLeftMouseDown
#define NSEventTypeRightMouseDown NSRightMouseDown
#define NSEventTypeLeftMouseUp NSLeftMouseUp
#define NSEventTypeRightMouseUp NSRightMouseUp
#define NSEventTypeMouseMoved NSMouseMoved
#define NSEventTypeLeftMouseDragged NSLeftMouseDragged
#define NSEventTypeRightMouseDragged NSRightMouseDragged
#define NSEventTypeKeyDown NSKeyDown
#define NSEventTypeKeyUp NSKeyUp
#define NSEventTypeFlagsChanged NSFlagsChanged
#define NSEventTypeScrollWheel NSScrollWheel
#define NSEventTypeOtherMouseDown NSOtherMouseDown
#define NSEventTypeOtherMouseUp NSOtherMouseUp
#define NSEventTypeOtherMouseDragged NSOtherMouseDragged
#define NSEventTypePressure 34
#endif
/* NSControlStateValue renamed in 10.13 */
#ifndef NSControlStateValue
typedef NSInteger NSControlStateValue;
#define NSControlStateValueOff NSOffState
#define NSControlStateValueOn NSOnState
#define NSControlStateValueMixed NSMixedState
#endif
#endif

/* UTType* constants (UniformTypeIdentifiers 10.15+ -> LaunchServices kUTType*) */
#ifdef __OBJC__
#ifndef UTTypePNG
#define UTTypePNG ((id)kUTTypePNG)
#define UTTypeJPEG ((id)kUTTypeJPEG)
#define UTTypeTIFF ((id)kUTTypeTIFF)
#define UTTypeGIF ((id)kUTTypeGIF)
#define UTTypeHTML ((id)kUTTypeHTML)
#define UTTypePlainText ((id)kUTTypePlainText)
#define UTTypeURL ((id)kUTTypeURL)
#define UTTypeRTF ((id)kUTTypeRTF)
#define UTTypePDF ((id)kUTTypePDF)
#endif
#endif

/* More NSEventType constants */
#ifdef __OBJC__
#ifndef NSEventTypeMouseEntered
#define NSEventTypeMouseEntered NSMouseEntered
#define NSEventTypeMouseExited NSMouseExited
#define NSEventTypeCursorUpdate NSCursorUpdate
#define NSEventTypeTabletPoint NSTabletPoint
#define NSEventTypeTabletProximity NSTabletProximity
#endif
#endif

/* NSEventTypeSystemDefined */
#ifdef __OBJC__
#ifndef NSEventTypeSystemDefined
#define NSEventTypeSystemDefined NSSystemDefined
#define NSEventTypeApplicationDefined NSApplicationDefined
#endif
#endif

/* NSEventMask renamed in 10.12 */
#ifdef __OBJC__
#ifndef NSEventMaskFlagsChanged
#define NSEventMaskFlagsChanged NSFlagsChangedMask
#define NSEventMaskLeftMouseDown NSLeftMouseDownMask
#define NSEventMaskLeftMouseUp NSLeftMouseUpMask
#define NSEventMaskMouseMoved NSMouseMovedMask
#define NSEventMaskLeftMouseDragged NSLeftMouseDraggedMask
#define NSEventMaskRightMouseDragged NSRightMouseDraggedMask
#define NSEventMaskScrollWheel NSScrollWheelMask
#define NSEventMaskKeyDown NSKeyDownMask
#define NSEventMaskKeyUp NSKeyUpMask
#define NSEventMaskAny NSAnyEventMask
#endif
#ifndef NSEventModifierFlagDeviceIndependentFlagsMask
#define NSEventModifierFlagDeviceIndependentFlagsMask NSDeviceIndependentModifierFlagsMask
#endif
/* NSPasteboard names renamed in 10.13 */
#ifndef NSPasteboardNameFont
#define NSPasteboardNameFont NSFontPboard
#define NSPasteboardNameRuler NSRulerPboard
#define NSPasteboardNameGeneral NSGeneralPboard
#define NSPasteboardNameDrag NSDragPboard
#define NSPasteboardNameFind NSFindPboard
#endif

/* NSWritingDirection (10.11+) */
#ifndef NSWritingDirectionOverride
#define NSWritingDirectionOverride 2
#define NSWritingDirectionEmbedding 0
#endif

/* NSControlSize values added in 10.10/11 */
#ifndef NSControlSizeRegular
#define NSControlSizeRegular NSRegularControlSize
#define NSControlSizeSmall NSSmallControlSize
#define NSControlSizeMini NSMiniControlSize
#define NSControlSizeLarge ((NSControlSize)3)
#endif

/* NSWindowCollectionBehavior values added in 10.11+ */
#ifndef NSWindowCollectionBehaviorFullScreenAllowsTiling
#define NSWindowCollectionBehaviorFullScreenAllowsTiling (1 << 11)
#define NSWindowCollectionBehaviorFullScreenDisallowsTiling (1 << 12)
#define NSWindowCollectionBehaviorAuxiliary (1 << 8)
#endif
#endif

/* More NSTouchBar properties and types */
#ifdef __OBJC__
@interface NSTouchBarItem ()
@property (copy) NSString *identifier;
@end
@interface NSTouchBar ()
@property (copy) NSString *customizationIdentifier;
@end
@interface NSCandidateListTouchBarItem ()
@property (readonly) BOOL candidateListVisible;
@property (copy) NSArray *candidates;
@end
@interface NSPopoverTouchBarItem : NSTouchBarItem
@end
@protocol NSTouchBarDelegate <NSObject>
@optional
@end
@protocol NSCandidateListTouchBarItemDelegate <NSObject>
@optional
@end
#ifndef NSTouchBarItemIdentifierCharacterPicker
#define NSTouchBarItemIdentifierCharacterPicker @"NSTouchBarItemIdentifierCharacterPicker"
#endif
/* NSFilePromiseReceiver (10.12+) is declared locally (with the method it uses)
 * by WebView.mm and WebViewImpl.mm under #if !__has_include(<AppKit/NSFilePromiseReceiver.h>);
 * do NOT stub it here or it is a duplicate interface definition. */
#endif

/* NSEventModifierFlagFunction */
#ifdef __OBJC__
#ifndef NSEventModifierFlagFunction
#define NSEventModifierFlagFunction NSFunctionKeyMask
#endif
#endif

/* Private CoreGraphics font functions */
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __cplusplus
}
#endif

/* PDFKit types */
#ifdef __OBJC__
#ifndef PDFKitPlatformScrollView
typedef NSScrollView PDFKitPlatformScrollView;
#endif
#endif

/* Private CoreGraphics font functions */
#include <CoreGraphics/CoreGraphics.h>
#ifdef __cplusplus
extern "C" {
#endif
bool CGContextGetAllowsFontSmoothing(CGContextRef ctx);
bool CGContextGetAllowsFontSubpixelQuantization(CGContextRef ctx);
void CGContextSetAllowsFontSubpixelQuantization(CGContextRef ctx, bool value);
#ifdef __cplusplus
}
#endif

/* NSColorPickerTouchBarItem more properties */
#ifdef __OBJC__
@interface NSColorPickerTouchBarItem ()
@property BOOL showsAlpha;
@end
#endif

/* CoreGraphics color space polyfills for macOS 10.9 (display P3, wide gamut, etc.) */
#ifdef __cplusplus
extern "C" {
#endif
extern const CFStringRef kCGColorSpaceDisplayP3;
extern const CFStringRef kCGColorSpaceExtendedDisplayP3;
extern const CFStringRef kCGColorSpaceExtendedSRGB;
extern const CFStringRef kCGColorSpaceExtendedLinearSRGB;
extern const CFStringRef kCGColorSpaceLinearSRGB;
extern const CFStringRef kCGColorSpaceExtendedGray;
extern const CFStringRef kCGColorSpaceLinearGray;
extern const CFStringRef kCGColorSpaceExtendedLinearGray;
extern const CFStringRef kCGColorSpaceITUR_709;
extern const CFStringRef kCGColorSpaceITUR_2020;
extern const CFStringRef kCGColorSpaceExtendedITUR_2020;
extern const CFStringRef kCGColorSpaceLinearITUR_2020;
extern const CFStringRef kCGColorSpaceExtendedLinearITUR_2020;
extern const CFStringRef kCGColorSpaceITUR_2100_HLG;
extern const CFStringRef kCGColorSpaceITUR_2100_PQ;
extern const CFStringRef kCGColorSpaceROMMRGB;
extern const CFStringRef kCGColorSpaceDCIP3;
extern const CFStringRef kCGColorSpaceLabD50;
extern const CFStringRef kCGColorSpaceLabD65;
extern const CFStringRef kCGColorSpaceACESCGLinear;
bool CGColorSpaceIsWideGamutRGB(CGColorSpaceRef space);
bool CGColorSpaceUsesExtendedRange(CGColorSpaceRef space);
bool CGColorSpaceUsesITUR_2100TF(CGColorSpaceRef space);
#ifdef __cplusplus
}
#endif

/* Virtual key codes (10.10+) */
#ifndef kVK_RightCommand
#define kVK_RightCommand 0x36
#endif

/* NSEvent modifier flags (10.12+ renamed) */
#ifndef NSEventModifierFlagNumericPad
#define NSEventModifierFlagNumericPad NSNumericPadKeyMask
#endif

/* CGEvent unaccelerated pointer movement (10.11+) */
#ifndef kCGEventUnacceleratedPointerMovementX
#define kCGEventUnacceleratedPointerMovementX 170
#define kCGEventUnacceleratedPointerMovementY 171
#endif

/* CGColorSpace name constants (10.11.2+) - global CFStringRef vars in polyfill_stubs.o */
/* kCGColorSpaceICCData, kCGLastIndexKey, kCGIndexedColorTableKey are defined in
   CoreIPCCGColorSpace.h as static const CFStringRef - no compat.h polyfill needed */
