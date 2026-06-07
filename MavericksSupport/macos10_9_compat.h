/* Compatibility shim for macOS 10.9 - provides missing POSIX functions */
#ifndef _COMPAT_H
#define _COMPAT_H

/* Skip for assembly files */
#ifndef __ASSEMBLER__

#include <sys/cdefs.h>
#include <sys/types.h>

/* mach_vm_offset_t / MACH_VM_MAX_ADDRESS live in <mach/vm_types.h> on 10.9 but
 * aren't pulled in transitively by <mach/vm_param.h> where WTF expands
 * OS_CONSTANT(EFFECTIVE_ADDRESS_WIDTH) (Packed.h, CompactPointerTuple.h,
 * Signals.cpp, WTFConfig.cpp). Force-include so the typedef is always visible. */
#include <mach/vm_types.h>

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

/* ===== aligned_alloc (C11; macOS 10.15+) =====
 * Absent on 10.9. bmalloc/WTF call ::aligned_alloc; provide a static-inline
 * shim over posix_memalign (present since 10.6) so the upstream call sites
 * compile unchanged. static inline => no library symbol / ODR concerns. */
#include <stdlib.h>
static __inline__ void *aligned_alloc(size_t __alignment, size_t __size) {
    void *__p = 0;
    if (posix_memalign(&__p, __alignment, __size) != 0)
        return 0;
    return __p;
}

/* ===== VM_FLAGS_PERMANENT (mach; macOS 10.15+) =====
 * WTFConfig's makePagesFreezable() ORs this into mach_vm_map flags to make the
 * config page kernel-immutable. The 10.9 kernel has no such flag; define it as
 * 0 so the call degrades to an ordinary fixed/overwrite mapping rather than the
 * kernel rejecting an unknown flag. (Loses only a defense-in-depth hardening.) */
#ifndef VM_FLAGS_PERMANENT
#define VM_FLAGS_PERMANENT 0
#endif

/* ===== newer VM_MEMORY_* allocation tags (not on 10.9) =====
 * Advisory user tags ORed into vm_allocate flags purely for attribution in
 * Instruments / WTF ResourceUsageCocoa. 10.9 tops out around 76; these later
 * tags carry their real upstream values (harmless if a profiler differs). */
#ifndef VM_MEMORY_MALLOC_MEDIUM
#define VM_MEMORY_MALLOC_MEDIUM 18
#endif
#ifndef VM_MEMORY_IOSURFACE
#define VM_MEMORY_IOSURFACE 88
#endif
#ifndef VM_MEMORY_IOACCELERATOR
#define VM_MEMORY_IOACCELERATOR 91
#endif

/* ===== mkostemp / mkostemps (glibc extension; not on 10.9) =====
 * WTF FileSystemCocoa.mm calls mkostemp(t, O_CLOEXEC)/mkostemps(t, n, O_CLOEXEC).
 * 10.9 has mkstemp/mkstemps; wrap them and apply O_CLOEXEC via fcntl. */
#include <unistd.h>
#include <fcntl.h>
static __inline__ int mkostemp(char *__t, int __flags) {
    int __fd = mkstemp(__t);
    if (__fd >= 0 && (__flags & O_CLOEXEC)) fcntl(__fd, F_SETFD, FD_CLOEXEC);
    return __fd;
}
static __inline__ int mkostemps(char *__t, int __suffixlen, int __flags) {
    int __fd = mkstemps(__t, __suffixlen);
    if (__fd >= 0 && (__flags & O_CLOEXEC)) fcntl(__fd, F_SETFD, FD_CLOEXEC);
    return __fd;
}

/* ===== CF_BRIDGED_TYPE family (CoreFoundation; macOS 10.10+) =====
 * Toll-free-bridging annotation macros. Absent on 10.9, so WebKit SPI headers
 * that wrap opaque-pointer typedefs in them (e.g. DataDetectorsCoreSPI's
 * DDResultRef/DDScannerRef) fail to parse. Define as no-ops (the annotation is
 * only an ARC diagnostic hint; the types work without it). */
#ifndef CF_BRIDGED_TYPE
#define CF_BRIDGED_TYPE(T)
#endif
#ifndef CF_BRIDGED_MUTABLE_TYPE
#define CF_BRIDGED_MUTABLE_TYPE(T)
#endif
#ifndef CF_RELATED_TYPE
#define CF_RELATED_TYPE(T, C, I)
#endif
/* CF_NOESCAPE (10.12+): noescape annotation on block/function-pointer params.
 * Absent on 10.9; its absence breaks function-pointer param decls like
 * `OSStatus (* CF_NOESCAPE callback)(...)` in PAL CoreMediaSoftLink. No-op. */
#ifndef CF_NOESCAPE
#define CF_NOESCAPE
#endif
#ifndef CF_SWIFT_NAME
#define CF_SWIFT_NAME(_name)
#endif

/* ===== Foundation/ObjC annotation macros (macOS 10.10+) =====
 * Method/property annotation macros absent on the 10.9 SDK. Their absence leaves
 * a bare token mid-declaration ("expected ':'"), e.g. NS_DESIGNATED_INITIALIZER
 * in PAL RevealSPI.h and ~74 WebKit API/SPI headers. No-op shims (purely
 * advisory; no codegen impact). #ifndef-guarded so any that DO exist win. */
#ifndef NS_DESIGNATED_INITIALIZER
#define NS_DESIGNATED_INITIALIZER
#endif
#ifndef NS_UNAVAILABLE
#define NS_UNAVAILABLE
#endif
#ifndef NS_REQUIRES_SUPER
#define NS_REQUIRES_SUPER
#endif
#ifndef NS_NOESCAPE
#define NS_NOESCAPE
#endif
#ifndef NS_EXTENSIBLE_STRING_ENUM
#define NS_EXTENSIBLE_STRING_ENUM
#endif
#ifndef NS_REFINED_FOR_SWIFT
#define NS_REFINED_FOR_SWIFT
#endif

/* ===== nullability region macros (Foundation; macOS 10.10+) =====
 * NS_ASSUME_NONNULL_BEGIN/END normally emit `#pragma clang assume_nonnull`.
 * Absent on 10.9 (e.g. JSC API JSScript.h uses them). Define as no-ops:
 * unannotated pointers just get unspecified nullability, which is harmless. */
#ifndef NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_END
#endif

/* ===== CoreMedia "returns retained" parameter annotation (10.10+) =====
 * Ownership annotation on out-parameters; no-op shim for the 10.9 SDK so PAL
 * CoreMediaSoftLink declarations parse. */
#ifndef CM_RETURNS_RETAINED_PARAMETER
#define CM_RETURNS_RETAINED_PARAMETER
#endif
#ifndef CM_RETURNS_RETAINED
#define CM_RETURNS_RETAINED
#endif

/* ===== AppKit enum renames (macOS 10.12+) =====
 * 10.12 renamed NS*WindowMask -> NSWindowStyleMask* and NS*ControlSize ->
 * NSControlSize*. The 10.9 SDK only has the old names; alias the new spellings
 * WebKit uses (PopupMenu.mm, WebPanel.mm, ...) to them. */
#ifndef NSWindowStyleMaskBorderless
#define NSWindowStyleMaskBorderless        NSBorderlessWindowMask
#define NSWindowStyleMaskTitled            NSTitledWindowMask
#define NSWindowStyleMaskClosable          NSClosableWindowMask
#define NSWindowStyleMaskMiniaturizable    NSMiniaturizableWindowMask
#define NSWindowStyleMaskResizable         NSResizableWindowMask
#define NSWindowStyleMaskUtilityWindow     NSUtilityWindowMask
#define NSWindowStyleMaskFullScreen        NSFullScreenWindowMask
#define NSWindowStyleMaskNonactivatingPanel NSNonactivatingPanelMask
#define NSWindowStyleMaskHUDWindow         NSHUDWindowMask
#endif
#ifndef NSControlSizeRegular
#define NSControlSizeRegular  NSRegularControlSize
#define NSControlSizeSmall    NSSmallControlSize
#define NSControlSizeMini     NSMiniControlSize
#endif

/* NSRectEdge (10.12) */
#ifndef NSRectEdgeMinX
#define NSRectEdgeMinX NSMinXEdge
#define NSRectEdgeMinY NSMinYEdge
#define NSRectEdgeMaxX NSMaxXEdge
#define NSRectEdgeMaxY NSMaxYEdge
#endif

/* NSTextAlignment (10.12) */
#ifndef NSTextAlignmentLeft
#define NSTextAlignmentLeft      NSLeftTextAlignment
#define NSTextAlignmentRight     NSRightTextAlignment
#define NSTextAlignmentCenter    NSCenterTextAlignment
#define NSTextAlignmentJustified NSJustifiedTextAlignment
#define NSTextAlignmentNatural   NSNaturalTextAlignment
#endif

/* NSEventType (10.12 rename of the bare NS* event types) */
#ifndef NSEventTypeLeftMouseDown
#define NSEventTypeLeftMouseDown     NSLeftMouseDown
#define NSEventTypeLeftMouseUp       NSLeftMouseUp
#define NSEventTypeRightMouseDown    NSRightMouseDown
#define NSEventTypeRightMouseUp      NSRightMouseUp
#define NSEventTypeOtherMouseDown    NSOtherMouseDown
#define NSEventTypeOtherMouseUp      NSOtherMouseUp
#define NSEventTypeLeftMouseDragged  NSLeftMouseDragged
#define NSEventTypeRightMouseDragged NSRightMouseDragged
#define NSEventTypeOtherMouseDragged NSOtherMouseDragged
#define NSEventTypeMouseMoved        NSMouseMoved
#define NSEventTypeMouseEntered      NSMouseEntered
#define NSEventTypeMouseExited       NSMouseExited
#define NSEventTypeKeyDown           NSKeyDown
#define NSEventTypeKeyUp             NSKeyUp
#define NSEventTypeFlagsChanged      NSFlagsChanged
#define NSEventTypeScrollWheel       NSScrollWheel
#define NSEventTypeCursorUpdate      NSCursorUpdate
#define NSEventTypeAppKitDefined     NSAppKitDefined
#define NSEventTypeSystemDefined     NSSystemDefined
#define NSEventTypeApplicationDefined NSApplicationDefined
#define NSEventTypePeriodic          NSPeriodic
#define NSEventTypeTabletPoint       NSTabletPoint
#define NSEventTypeTabletProximity   NSTabletProximity
#endif

/* NSPasteboardName (10.13) */
#ifndef NSPasteboardNameGeneral
#define NSPasteboardNameGeneral NSGeneralPboard
#define NSPasteboardNameFont    NSFontPboard
#define NSPasteboardNameRuler   NSRulerPboard
#define NSPasteboardNameFind    NSFindPboard
#define NSPasteboardNameDrag    NSDragPboard
#endif

/* NSAppearanceNameDarkAqua (10.14) — no 10.9 equivalent; a sentinel string that
 * never matches a real 10.9 appearance (10.9 is always light/Aqua). */
#ifndef NSAppearanceNameDarkAqua
#define NSAppearanceNameDarkAqua @"NSAppearanceNameDarkAqua"
#endif

/* ===== CoreText OpenType feature keys (10.10) ===== */
#ifndef kCTFontOpenTypeFeatureTag
#define kCTFontOpenTypeFeatureTag   CFSTR("CTFontOpenTypeFeatureTag")
#define kCTFontOpenTypeFeatureValue CFSTR("CTFontOpenTypeFeatureValue")
#endif

/* ===== CoreMedia codec type (10.13) ===== */
#ifndef kCMVideoCodecType_HEVC
#define kCMVideoCodecType_HEVC 'hvc1'
#endif

/* ===== CoreAudio element-main rename (10.12) ===== */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

/* AudioFormatFlags typedef (later SDK) — 10.9 CoreAudioTypes.h declares
 * AudioStreamBasicDescription.mFormatFlags as a bare UInt32 and has no
 * AudioFormatFlags typedef. unsigned int == UInt32 on this target. */
#ifndef AUDIO_FORMAT_FLAGS_DEFINED
#define AUDIO_FORMAT_FLAGS_DEFINED
typedef unsigned int AudioFormatFlags;
#endif

/* ===== CoreGraphics extended-sRGB color space (10.12) — fall back to sRGB ===== */
#ifndef kCGColorSpaceExtendedSRGB
#define kCGColorSpaceExtendedSRGB kCGColorSpaceSRGB
#endif

#endif /* !__ASSEMBLER__ */
#endif /* _COMPAT_H */
