/* polyfill_stubs.m - Polyfill stubs for macOS 10.9 Mavericks
 * Provides C function stubs, ObjC class stubs, and API polyfills
 * for symbols not available on 10.9 but needed by modern WebKit 615.1.1
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <dirent.h>
#include <limits.h>
#include <dispatch/dispatch.h>
#include <mach/port.h>

// POLYFILL_GSTREAMER_ONLY: when defined, compile ONLY the "GStreamer media backend" section below
// (the portable C / CoreFoundation symbols the bundled GStreamer needs), skipping every WebKit-
// specific stub, ObjC class, and category. This lets the same single source of truth also produce a
// small, dependency-light polyfill object for the GStreamer dylibs without duplicating any code.
#ifndef POLYFILL_GSTREAMER_ONLY

// 10.9 backport: CTRunGetBaseAdvancesAndOrigins is 10.11+. The prebuilt
// all_stubs.o provides a return-0 no-op for it, which zeroes every glyph's
// advance and origin — so any complex-text run that reports
// kCTRunStatusHasOrigins (e.g. ligature-substituted icon fonts like Material
// Icons) collapses all its glyphs onto x=0 and renders blank.
// Provide a correct implementation: base advances come from the real (10.9)
// CTRunGetAdvances, and origins are zero (10.9 CoreText has no per-glyph
// origin offsets for the scripts WebKit shapes here). The return-0 copy in
// all_stubs.o is localized out (rebuild_polyfill_stubs.sh) so this wins.
void CTRunGetBaseAdvancesAndOrigins(CTRunRef run, CFRange range, CGSize* advances, CGPoint* origins)
{
    if (!run)
        return;
    CFIndex glyphCount = CTRunGetGlyphCount(run);
    CFIndex count = range.length ? range.length : glyphCount;
    if (advances)
        CTRunGetAdvances(run, range, advances);
    if (origins) {
        for (CFIndex i = 0; i < count; ++i)
            origins[i] = CGPointZero;
    }
}

#pragma mark - C function stubs

int CCRandomGenerateBytes(void *bytes, size_t count) {
    arc4random_buf(bytes, count);
    return 0;
}

void abort_with_reason(uint32_t a, uint64_t b, const char *c, uint64_t d) { abort(); }
void os_fault_with_payload(uint32_t a, uint64_t b, const void *c, uint32_t d, const char *e, uint64_t f) { }

// dyld stubs
bool dyld_program_sdk_at_least(uint32_t v) { return false; }
bool dyld_program_minos_at_least(uint32_t v) { return false; }
bool dyld_sdk_at_least(const void *h, uint32_t v) { return false; }

// cache/simulator stubs
void cache_simulate_size_response(uint64_t a, uint64_t b, uint64_t c) { }

// os_variant stubs
bool os_variant_allows_internal_security_policies(const char *s) { return false; }
bool os_variant_has_internal_content(const char *s) { return false; }
bool os_variant_has_internal_diagnostics(const char *s) { return false; }

// pthread
bool pthread_self_is_exiting_np(void) { return false; }

// os_unfair_lock_assert_owner / _assert_not_owner (10.12+) are the lock-ownership debug assertions WTF::Lock
// emits under the modern SDK. The lock primitive itself is already polyfilled (os_unfair_lock_lock/unlock in
// libpolyfill's os_unfair_lock.o); only these assert helpers are absent on 10.9. No-op them (the lazy bind of
// the weak reference otherwise aborts fatally on first use, during IPC message handling on page load).
void os_unfair_lock_assert_owner(void *lock) { (void)lock; }
void os_unfair_lock_assert_not_owner(void *lock) { (void)lock; }

// os_log unified logging is 10.12+; _os_log_internal is the macro-emitted backing for every os_log()
// call site and is absent from 10.9's libSystem (it links as the Mach-O symbol __os_log_internal).
// WebKit imports it weakly, but the LAZY bind of a weak FUNCTION still aborts fatally on the first
// os_log() call ("lazy symbol binding failed"). Defining a no-op here (libpolyfill.a links into each
// framework) satisfies it in-image; logging just no-ops. (_os_log_default stays weak/NULL — the no-op
// ignores its log argument, and weak DATA resolves to NULL without a fatal bind.)
// Signature uses plain types (os_log_t/os_log_type_t aren't visible under --no-default-config);
// ABI-equivalent: os_log_t==pointer, os_log_type_t==uint8_t, buf==uint8_t*, size==uint32_t.
void _os_log_internal(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

// os_log_create(subsystem, category) -> os_log_t (10.12+, absent on 10.9). os_log_t is an os_object /
// ObjC type, and WebKit wraps the result in a RetainPtr<os_log_t> — so it sends -retain/-release to it.
// Therefore the returned handle MUST be a real, retainable Objective-C object (a bare pointer crashes in
// objc_msgSend on [obj retain]). Return a fresh +1 NSObject (matching os_log_create's create semantics);
// _os_log_internal ignores the log, so the object's only role is to be a valid refcounted handle.
void *_os_log_create(const char *subsystem, const char *category) {
    (void)subsystem; (void)category;
    return (void *)[[NSObject alloc] init];
}

// os_signpost performance tracing is 10.14+; absent on 10.9. No-op so signpost call sites link and the
// "is signposting enabled" guard always reports disabled (no emit happens).
bool os_signpost_enabled(void *log) { (void)log; return false; }
uint64_t os_signpost_id_make_with_pointer(void *log, const void *ptr) { (void)log; return (uint64_t)(uintptr_t)ptr; }
void _os_signpost_emit_with_name_impl(void *dso, void *log, uint8_t type, uint64_t spid,
        const char *name, const char *format, uint8_t *buf, uint32_t size) {
    (void)dso; (void)log; (void)type; (void)spid; (void)name; (void)format; (void)buf; (void)size;
}

// aligned_alloc (C11) was added to macOS libc only in 10.15; on 10.9 use posix_memalign, which yields
// free()-compatible memory just like aligned_alloc.
void *aligned_alloc(size_t alignment, size_t size) {
    void *p = NULL;
    return posix_memalign(&p, alignment, size) ? NULL : p;
}

// mkostemp/mkostemps (the flags-taking mkstemp variants) are absent on 10.9; emulate via mkstemp/mkstemps
// plus fcntl to apply the documented O_CLOEXEC/O_APPEND/O_NONBLOCK flags.
static void applyOpenFlags(int fd, int flags) {
    if (fd < 0) return;
    if (flags & O_CLOEXEC) fcntl(fd, F_SETFD, FD_CLOEXEC);
    int sfl = (flags & (O_APPEND | O_NONBLOCK));
    if (sfl) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | sfl);
}
int mkostemp(char *tmpl, int flags) { int fd = mkstemp(tmpl); applyOpenFlags(fd, flags); return fd; }
int mkostemps(char *tmpl, int suffixlen, int flags) { int fd = mkstemps(tmpl, suffixlen); applyOpenFlags(fd, flags); return fd; }

// timingsafe_bcmp (constant-time compare, used by crypto) is absent on 10.9. Provide a constant-time
// implementation (no early-out) so timing characteristics match the real function.
int timingsafe_bcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    unsigned char r = 0;
    for (size_t i = 0; i < n; i++) r |= x[i] ^ y[i];
    return r != 0;
}

// voucher_mach_msg_set (libdispatch QoS voucher propagation) is 10.10+. Vouchers don't exist on 10.9;
// report "no voucher set" (FALSE). Vouchers are only a QoS-propagation optimization, so this is benign.
int voucher_mach_msg_set(void *msg) { (void)msg; return 0; }

// mach_memory_entry_ownership (footprint-ledger attribution of shared memory) is ~10.13+. 10.9 has no
// phys_footprint ledger, so there is genuinely nothing to attribute; report success (the sole caller,
// SharedMemoryHandle, only RELEASE_LOG_ERRORs on failure and is otherwise a no-op).
int mach_memory_entry_ownership(unsigned int mem_entry, unsigned int owner, int ledger_tag, int ledger_flags) {
    (void)mem_entry; (void)owner; (void)ledger_tag; (void)ledger_flags;
    return 0; // KERN_SUCCESS
}

// (__darwin_check_fd_set_overflow lives in the shared "GStreamer media backend" section below, since
// it is one of the symbols the bundled GStreamer also needs; it is defined exactly once.)

// dispatch_queue_create_with_target() (10.10 SDK) has no 10.9 runtime symbol — the modern SDK emits the
// ABI-tagged "$V2" variant. Recreate it from dispatch_queue_create + dispatch_set_target_queue (both 10.6).
dispatch_queue_t polyfill_dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target)
    __asm__("_dispatch_queue_create_with_target$V2");
dispatch_queue_t polyfill_dispatch_queue_create_with_target(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target) {
    dispatch_queue_t queue = dispatch_queue_create(label, attr);
    if (queue && target) dispatch_set_target_queue(queue, target);
    return queue;
}

// CGColorCreateSRGB (10.15+) — build the color through the named sRGB color space (available since 10.5).
CGColorRef CGColorCreateSRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef color = CGColorCreate(cs, comps);
    CGColorSpaceRelease(cs);
    return color;
}

// sqlite3_errstr (SQLite 3.7.15) — 10.9 ships an older SQLite. Map the primary result codes to the same
// strings SQLite uses, so WebCore's diagnostic logging stays meaningful. Used only for error messages.
const char *sqlite3_errstr(int rc) {
    switch (rc & 0xff) {
        case 0:  return "not an error";
        case 1:  return "SQL logic error";
        case 2:  return "internal error";
        case 3:  return "access permission denied";
        case 4:  return "query aborted";
        case 5:  return "database is locked";
        case 6:  return "database table is locked";
        case 7:  return "out of memory";
        case 8:  return "attempt to write a readonly database";
        case 9:  return "interrupted";
        case 10: return "disk I/O error";
        case 11: return "database disk image is malformed";
        case 12: return "unknown operation";
        case 13: return "database or disk is full";
        case 14: return "unable to open database file";
        case 15: return "locking protocol";
        case 17: return "database schema has changed";
        case 18: return "string or blob too big";
        case 19: return "constraint failed";
        case 20: return "datatype mismatch";
        case 21: return "library routine called out of sequence";
        case 23: return "authorization denied";
        case 25: return "column index out of range";
        case 26: return "file is not a database";
        case 100: return "another row available";
        case 101: return "no more rows available";
        default: return "unknown error";
    }
}

// kIOMainPortDefault (the 12.0 rename of kIOMasterPortDefault) has no 10.9 symbol; its value is the same
// MACH_PORT_NULL sentinel meaning "use the default IOKit master port".
const mach_port_t kIOMainPortDefault = 0;

// kCTFontOpenTypeFeatureTag / ...Value (10.10 SDK) are the CFDictionary keys for OpenType font features.
// They have no 10.9 symbol; building a feature dictionary with a NULL key would crash CFDictionary, so
// define them with CoreText's documented key strings. (10.9 CoreText may not honor the new-style feature
// dictionary, but the code links and runs without crashing.)
const CFStringRef kCTFontOpenTypeFeatureTag = CFSTR("CTFeatureOpenTypeTag");
const CFStringRef kCTFontOpenTypeFeatureValue = CFSTR("CTFeatureOpenTypeValue");

// CAFrameRateRangeMake (12.0+) — CADisplayLink frame-rate range constructor. Build the
// {minimum,maximum,preferred} struct directly. asm label so the C identifier doesn't collide with the
// SDK's CAFrameRateRange return type (which AppKit→QuartzCore may declare); the struct layout is ABI-
// identical (three floats), so the returned value is passed back exactly as callers expect.
typedef struct { float minimum; float maximum; float preferred; } PolyCAFrameRateRange;
PolyCAFrameRateRange polyfill_CAFrameRateRangeMake(float minimum, float maximum, float preferred) __asm__("_CAFrameRateRangeMake");
PolyCAFrameRateRange polyfill_CAFrameRateRangeMake(float minimum, float maximum, float preferred) {
    PolyCAFrameRateRange r = { minimum, maximum, preferred };
    return r;
}

// xpc_type_get_name (newer XPC introspection) — used only for diagnostic strings; return a generic label.
const char *xpc_type_get_name(void *type) { (void)type; return "xpc-object"; }

// QuartzCore/CoreText string constants with no 10.9 symbol. Define them non-NULL (documented values) so
// the corner-curve / downloaded-font features degrade gracefully and never feed a NULL key to a
// CFDictionary/CTFontDescriptor (which would crash). 10.9 won't honor the values, which is fine.
const CFStringRef kCACornerCurveCircular = CFSTR("circular");
const CFStringRef kCTFontDownloadedAttribute = CFSTR("kCTFontDownloadedAttribute");

#endif // !POLYFILL_GSTREAMER_ONLY

#pragma mark - GStreamer media backend: newer-than-10.9 symbols
// The bundled upstream GStreamer media player (MavericksSupport/deps/gstreamer — a prebuilt 1.20.7
// stack that targets 10.11) references a handful of symbols absent from the 10.9 runtime. They are
// all plain C / CoreFoundation symbols (no ObjC), so they belong in this shared polyfill: the same
// source is compiled into libpolyfill.a (every WebKit framework) AND into the GStreamer-bundled
// polyfill dylib (built from this very file with -DPOLYFILL_NO_OBJC_CLASSES). Single source of truth.
// (mkostemp + __darwin_check_fd_set_overflow, which GStreamer also needs, are already defined above.)

#ifndef AT_FDCWD
#define AT_FDCWD -2
#endif
#ifndef AT_SYMLINK_NOFOLLOW
#define AT_SYMLINK_NOFOLLOW 0x0020
#endif

// LaunchServices app-lookup (10.10+), reached through glib gio's osxappinfo backend. Media playback
// never needs to resolve a handler application, so "none found" (NULL) is correct and safe.
CFArrayRef LSCopyApplicationURLsForBundleIdentifier(CFStringRef bundleID, CFErrorRef *outError) {
    (void)bundleID; if (outError) *outError = NULL; return NULL;
}
CFURLRef LSCopyDefaultApplicationURLForContentType(CFStringRef contentType, int roleMask, CFErrorRef *outError) {
    (void)contentType; (void)roleMask; if (outError) *outError = NULL; return NULL;
}

// __darwin_check_fd_set_overflow (the fortified FD_SET bounds check) is newer; on 10.9 reproduce its
// semantics: a descriptor is valid if non-negative and (when not unlimited) within FD_SETSIZE. Both
// WebKit and GStreamer reference it, and no other libpolyfill member defines it, so it lives here
// (always compiled) as the single definition.
int __darwin_check_fd_set_overflow(int n, const void *fdset, int unlimited) {
    (void)fdset;
    return (n >= 0 && (unlimited || n < FD_SETSIZE)) ? 1 : 0;
}

// openat / fdopendir / fstatat (all 10.10+) collide with the MacPorts-legacy-support members already
// inside libpolyfill.a (atcalls.o / fdopendir.o / statxx.o), which satisfy WebKit's own references.
// So compile them ONLY for the standalone GStreamer polyfill slice, which links none of those members.
#ifdef POLYFILL_GSTREAMER_ONLY
// openat (10.10+). Handle AT_FDCWD and absolute paths directly; resolve a relative path against the
// dirfd via /dev/fd (present on 10.9).
int openat(int dirfd, const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    if (dirfd == AT_FDCWD || (path && path[0] == '/'))
        return open(path, flags, mode);
    char full[PATH_MAX];
    snprintf(full, sizeof full, "/dev/fd/%d/%s", dirfd, path ? path : "");
    return open(full, flags, mode);
}

// fdopendir (10.10+) — open a directory stream from an existing fd. Recover the path with F_GETPATH
// (works for directory fds on 10.9) and opendir() it, taking ownership of the fd like the real call.
// The x86_64 10.x symbol carries the $INODE64 suffix; emit that exact name via an asm label.
DIR *polyfill_fdopendir(int fd) __asm__("_fdopendir$INODE64");
DIR *polyfill_fdopendir(int fd) {
    char path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, path) == -1) return NULL;
    DIR *d = opendir(path);
    if (d) close(fd);
    return d;
}

// fstatat (10.10+) — stat relative to a dirfd. On 10.9 x86_64, stat()/lstat() ARE the $INODE64
// variants, so the struct stat layout matches the caller's exactly. Resolve relative paths against
// the dirfd's path; honor AT_SYMLINK_NOFOLLOW. Emit the $INODE64-suffixed symbol via an asm label.
int polyfill_fstatat(int dirfd, const char *path, struct stat *buf, int flags) __asm__("_fstatat$INODE64");
int polyfill_fstatat(int dirfd, const char *path, struct stat *buf, int flags) {
    int nofollow = (flags & AT_SYMLINK_NOFOLLOW) != 0;
    if (dirfd == AT_FDCWD || (path && path[0] == '/'))
        return nofollow ? lstat(path, buf) : stat(path, buf);
    char dir[PATH_MAX], full[PATH_MAX];
    if (fcntl(dirfd, F_GETPATH, dir) == -1) return -1;
    snprintf(full, sizeof full, "%s/%s", dir, path ? path : "");
    return nofollow ? lstat(full, buf) : stat(full, buf);
}
#endif // POLYFILL_GSTREAMER_ONLY

// CoreVideo color-space constants added in 10.11 / 10.13 (referenced by GStreamer's video plugins to
// tag HDR / wide-gamut frames). Absent on 10.9; provide the canonical CFString values. Rarely hit by
// SDR web video, which uses ITU_R_709_2 (present on 10.9). Defining them non-NULL keeps the plugins
// loadable and avoids feeding a NULL key/value into a CoreVideo attachment dictionary.
const CFStringRef kCVImageBufferColorPrimaries_ITU_R_2020         = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferColorPrimaries_P3_D65             = CFSTR("P3_D65");
const CFStringRef kCVImageBufferColorPrimaries_DCI_P3             = CFSTR("DCI_P3");
const CFStringRef kCVImageBufferTransferFunction_ITU_R_2020       = CFSTR("ITU_R_2020");
const CFStringRef kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = CFSTR("SMPTE_ST_2084_PQ");
const CFStringRef kCVImageBufferTransferFunction_sRGB             = CFSTR("IEC_sRGB");
const CFStringRef kCVImageBufferYCbCrMatrix_ITU_R_2020            = CFSTR("ITU_R_2020");

#ifndef POLYFILL_GSTREAMER_ONLY

#pragma mark - ObjC class stubs (proper metadata for 10.9 ObjC runtime)
// Defined ONLY in JavaScriptCore.framework (JSC loads first). WebCore and WebKit
// reference these via their JSC dylib dependency — otherwise duplicate class
// registrations overflow libobjc's _read_images limit on 10.9.
#ifndef POLYFILL_NO_OBJC_CLASSES

@interface LSDatabaseContext : NSObject @end
@implementation LSDatabaseContext @end

@interface NSPresentationIntent : NSObject @end
@implementation NSPresentationIntent @end

@interface SecKeyProxy : NSObject @end
@implementation SecKeyProxy @end

// UTType polyfill — provides class methods returning UTType instances whose
// .identifier matches the kUTType* CFString constant. This avoids the
// unrecognized-selector crash from `UTTypeFileURL.identifier` etc.
@interface UTType : NSObject {
    NSString *_identifier;
}
@property (nullable, copy, readonly) NSString *identifier;
@end

@implementation UTType
@synthesize identifier = _identifier;
- (instancetype)initWithIdentifier:(NSString *)ident
{
    if ((self = [super init]))
        _identifier = [ident copy];
    return self;
}
- (void)dealloc { [_identifier release]; [super dealloc]; }
+ (instancetype)_polyfillTypeWith:(CFStringRef)ident
{
    if (!ident) return nil;
    return [[[self alloc] initWithIdentifier:(__bridge NSString *)ident] autorelease];
}
+ (instancetype)png       { return [self _polyfillTypeWith:kUTTypePNG]; }
+ (instancetype)jpeg      { return [self _polyfillTypeWith:kUTTypeJPEG]; }
+ (instancetype)tiff      { return [self _polyfillTypeWith:kUTTypeTIFF]; }
+ (instancetype)gif       { return [self _polyfillTypeWith:kUTTypeGIF]; }
+ (instancetype)bmp       { return [self _polyfillTypeWith:kUTTypeBMP]; }
+ (instancetype)pdf       { return [self _polyfillTypeWith:kUTTypePDF]; }
+ (instancetype)rtf       { return [self _polyfillTypeWith:kUTTypeRTF]; }
+ (instancetype)rtfd      { return [self _polyfillTypeWith:kUTTypeRTFD]; }
+ (instancetype)flatRTFD  { return [self _polyfillTypeWith:kUTTypeFlatRTFD]; }
+ (instancetype)html      { return [self _polyfillTypeWith:kUTTypeHTML]; }
+ (instancetype)xml       { return [self _polyfillTypeWith:kUTTypeXML]; }
+ (instancetype)text      { return [self _polyfillTypeWith:kUTTypeText]; }
+ (instancetype)plainText { return [self _polyfillTypeWith:kUTTypePlainText]; }
+ (instancetype)utf8PlainText { return [self _polyfillTypeWith:kUTTypeUTF8PlainText]; }
+ (instancetype)url       { return [self _polyfillTypeWith:kUTTypeURL]; }
+ (instancetype)fileURL   { return [self _polyfillTypeWith:kUTTypeFileURL]; }
+ (instancetype)image     { return [self _polyfillTypeWith:kUTTypeImage]; }
+ (instancetype)movie     { return [self _polyfillTypeWith:kUTTypeMovie]; }
+ (instancetype)audio     { return [self _polyfillTypeWith:kUTTypeAudio]; }
+ (instancetype)video     { return [self _polyfillTypeWith:kUTTypeVideo]; }
+ (instancetype)data      { return [self _polyfillTypeWith:kUTTypeData]; }
+ (instancetype)content   { return [self _polyfillTypeWith:kUTTypeContent]; }
+ (instancetype)item      { return [self _polyfillTypeWith:kUTTypeItem]; }
+ (instancetype)directory { return [self _polyfillTypeWith:kUTTypeDirectory]; }
+ (instancetype)folder    { return [self _polyfillTypeWith:kUTTypeFolder]; }
+ (instancetype)vCard     { return [self _polyfillTypeWith:kUTTypeVCard]; }
+ (instancetype)webArchive { return [[[self alloc] initWithIdentifier:@"com.apple.webarchive"] autorelease]; }
+ (instancetype)mp3       { return [self _polyfillTypeWith:kUTTypeMP3]; }
+ (instancetype)mpeg      { return [self _polyfillTypeWith:kUTTypeMPEG]; }
+ (instancetype)mpeg4Movie { return [self _polyfillTypeWith:kUTTypeMPEG4]; }
+ (instancetype)mpeg4Audio { return [self _polyfillTypeWith:kUTTypeMPEG4Audio]; }
+ (instancetype)quickTimeMovie { return [self _polyfillTypeWith:kUTTypeQuickTimeMovie]; }
+ (instancetype)application { return [self _polyfillTypeWith:kUTTypeApplication]; }
+ (instancetype)applicationBundle { return [self _polyfillTypeWith:kUTTypeApplicationBundle]; }
+ (instancetype)compositeContent { return [self _polyfillTypeWith:kUTTypeCompositeContent]; }
+ (instancetype)sourceCode { return [self _polyfillTypeWith:kUTTypeSourceCode]; }
+ (instancetype)icns      { return [self _polyfillTypeWith:kUTTypeAppleICNS]; }
+ (instancetype)ico       { return [self _polyfillTypeWith:kUTTypeICO]; }
+ (instancetype)utf16PlainText { return [self _polyfillTypeWith:kUTTypeUTF16PlainText]; }
+ (instancetype)webP      { return [[[self alloc] initWithIdentifier:@"public.webp"] autorelease]; }
+ (instancetype)heic      { return [[[self alloc] initWithIdentifier:@"public.heic"] autorelease]; }
+ (instancetype)svg       { return [[[self alloc] initWithIdentifier:@"public.svg-image"] autorelease]; }
// Aliases to handle both lowercase (real UTType API) and uppercase (some WebKit code) selectors.
+ (instancetype)PNG       { return [self png]; }
+ (instancetype)JPEG      { return [self jpeg]; }
+ (instancetype)TIFF      { return [self tiff]; }
+ (instancetype)GIF       { return [self gif]; }
+ (instancetype)BMP       { return [self bmp]; }
+ (instancetype)PDF       { return [self pdf]; }
+ (instancetype)RTF       { return [self rtf]; }
+ (instancetype)RTFD      { return [self rtfd]; }
+ (instancetype)HTML      { return [self html]; }
+ (instancetype)XML       { return [self xml]; }
+ (instancetype)URL       { return [self url]; }
+ (instancetype)UTF8PlainText { return [self utf8PlainText]; }
+ (nullable instancetype)typeWithIdentifier:(NSString *)ident
{
    if (!ident) return nil;
    return [[[self alloc] initWithIdentifier:ident] autorelease];
}
+ (nullable instancetype)typeWithFilenameExtension:(NSString *)ext
{
    if (!ext) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)ext, NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
+ (nullable instancetype)typeWithMIMEType:(NSString *)mimeType
{
    if (!mimeType) return nil;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)mimeType, NULL);
    if (!uti) return nil;
    UTType *t = [[[self alloc] initWithIdentifier:(__bridge NSString *)uti] autorelease];
    CFRelease(uti);
    return t;
}
- (BOOL)conformsToType:(UTType *)other
{
    if (!other || !_identifier || !other->_identifier) return NO;
    return UTTypeConformsTo((__bridge CFStringRef)_identifier, (__bridge CFStringRef)other->_identifier);
}
- (NSString *)preferredMIMEType
{
    if (!_identifier) return nil;
    CFStringRef mime = UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)_identifier, kUTTagClassMIMEType);
    if (!mime) return nil;
    return [(__bridge NSString *)mime autorelease];
}
- (NSString *)preferredFilenameExtension
{
    if (!_identifier) return nil;
    CFStringRef ext = UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)_identifier, kUTTagClassFilenameExtension);
    if (!ext) return nil;
    return [(__bridge NSString *)ext autorelease];
}
- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[UTType class]]) return NO;
    NSString *otherId = ((UTType *)other)->_identifier;
    if (!_identifier) return !otherId;
    return [_identifier isEqualToString:otherId];
}
- (NSUInteger)hash { return _identifier.hash; }
// 11.0+ instance method used by WebCore::canWritePasteboardType during Cmd+C copy.
// Without this, Safari crashes on every copy operation with NSInvalidArgumentException.
// UTTypeIsDeclared isn't exported from CoreServices on 10.9, so use the convention
// that "dyn." prefixed UTIs are dynamic / not-declared, and everything else is
// treated as declared (matches LaunchServices semantics for the common cases).
- (BOOL)isDeclared
{
    if (!_identifier) return NO;
    return ![_identifier hasPrefix:@"dyn."];
}
- (BOOL)isDynamic
{
    if (!_identifier) return NO;
    return [_identifier hasPrefix:@"dyn."];
}
@end

@interface NSTouchBar : NSObject @end
@implementation NSTouchBar @end

@interface NSCandidateListTouchBarItem : NSObject @end
@implementation NSCandidateListTouchBarItem @end

@interface NSColorPickerTouchBarItem : NSObject @end
@implementation NSColorPickerTouchBarItem @end

@interface NSPopoverTouchBarItem : NSObject @end
@implementation NSPopoverTouchBarItem @end

@interface NSTextTouchBarItemController : NSObject @end
@implementation NSTextTouchBarItemController @end

@interface NSFilePromiseReceiver : NSObject @end
@implementation NSFilePromiseReceiver @end

@interface LSAppLink : NSObject @end
@implementation LSAppLink @end

@interface _LSOpenConfiguration : NSObject @end
@implementation _LSOpenConfiguration @end

@interface WebSpeechRecognizerTask : NSObject @end
@implementation WebSpeechRecognizerTask @end

@interface _NSScrollingMomentumCalculator : NSObject @end
@implementation _NSScrollingMomentumCalculator @end

@interface _NSScrollingPredominantAxisFilter : NSObject @end
@implementation _NSScrollingPredominantAxisFilter @end

@interface WebFullScreenController : NSObject @end
@implementation WebFullScreenController @end

// WebViewVisualIdentificationOverlay: the real Source/WebCore/testing/cocoa/
// WebViewVisualIdentificationOverlay.mm is excluded from the build (it would
// duplicate this stub, since libpolyfill links into every framework). Both
// WKWebView and (legacy) WebView call +installForWebViewIfNeeded:kind:deprecated:
// at creation time, so the stub MUST implement that class method (as a no-op)
// or every web-view creation throws unrecognized-selector. The overlay is a
// debug/visual-identification affordance, so a no-op is functionally complete.
@interface WebViewVisualIdentificationOverlay : NSObject @end
@implementation WebViewVisualIdentificationOverlay
+ (void)installForWebViewIfNeeded:(id)view kind:(NSString *)kind deprecated:(BOOL)isDeprecated { }
@end

// WKWebInspectorProxyObjCAdapter and WebKeyGenerator are defined in
// Source/WebKit/PolyfillClasses_109.mm so Safari finds them in WebKit.framework
// (where it expects them) without duplicating them in JSC too.

// Additional stub classes that the polyfill previously provided as 3-byte
// function stubs (libobjc would crash on those). Defining them here as proper
// @interface/@implementation gives them real ObjC class metadata.
// NOTE: CATransformLayer (QuartzCore), NSColorPopoverController (AppKit) and
// SFCertificatePanel (SecurityInterface) are REAL classes that DO exist on macOS
// 10.9 — they must NOT be stubbed here, or the empty stub can shadow the genuine
// system class (e.g. CATransformLayer backs 3D CSS transforms). They resolve from
// their system frameworks, which WebCore/WebKit already link.
@interface LSBundleProxy : NSObject @end
@implementation LSBundleProxy @end
@interface WKCaptionStyleMenuController : NSObject @end
@implementation WKCaptionStyleMenuController @end
@interface WKDownloadProgress : NSObject @end
@implementation WKDownloadProgress @end
// WKInspectorViewController is compiled from real source
// (Source/WebKit/UIProcess/Inspector/mac/WKInspectorViewController.mm) into
// WebKit.framework, so it must NOT be stubbed here — doing so duplicated the
// symbol in the WebKit framework link.
@interface WKTextExtractionContainerItem : NSObject @end
@implementation WKTextExtractionContainerItem @end
@interface WKTextExtractionContentEditableItem : NSObject @end
@implementation WKTextExtractionContentEditableItem @end
@interface WKTextExtractionEditable : NSObject @end
@implementation WKTextExtractionEditable @end
@interface WKTextExtractionFormItem : NSObject @end
@implementation WKTextExtractionFormItem @end
@interface WKTextExtractionIFrameItem : NSObject @end
@implementation WKTextExtractionIFrameItem @end
@interface WKTextExtractionImageItem : NSObject @end
@implementation WKTextExtractionImageItem @end
@interface WKTextExtractionLink : NSObject @end
@implementation WKTextExtractionLink @end
@interface WKTextExtractionLinkItem : NSObject @end
@implementation WKTextExtractionLinkItem @end
@interface WKTextExtractionScrollableItem : NSObject @end
@implementation WKTextExtractionScrollableItem @end
@interface WKTextExtractionSelectItem : NSObject @end
@implementation WKTextExtractionSelectItem @end
@interface WKTextExtractionTextFormControlItem : NSObject @end
@implementation WKTextExtractionTextFormControlItem @end
@interface WKTextExtractionTextItem : NSObject @end
@implementation WKTextExtractionTextItem @end
@interface WebAVPlayerLayer : NSObject @end
@implementation WebAVPlayerLayer @end
@interface _NSHSTSStorage : NSObject @end
@implementation _NSHSTSStorage @end
@interface _NSHTTPAlternativeServicesFilter : NSObject @end
@implementation _NSHTTPAlternativeServicesFilter @end
@interface _NSHTTPAlternativeServicesStorage : NSObject @end
@implementation _NSHTTPAlternativeServicesStorage @end
@interface _WKTextExtractionInteractionResult : NSObject @end
@implementation _WKTextExtractionInteractionResult @end
@interface _WKTextExtractionResult : NSObject @end
@implementation _WKTextExtractionResult @end
@interface _WKTextManipulationItem : NSObject @end
@implementation _WKTextManipulationItem @end
@interface _WKTextPreview : NSObject @end
@implementation _WKTextPreview @end
@interface _WKWarningView : NSObject @end
@implementation _WKWarningView @end
@interface _WKWebPushDaemonConnection : NSObject @end
@implementation _WKWebPushDaemonConnection @end
@interface _WKWebPushMessage : NSObject @end
@implementation _WKWebPushMessage @end
@interface _WKWebPushSubscriptionData : NSObject @end
@implementation _WKWebPushSubscriptionData @end

#endif  // POLYFILL_NO_OBJC_CLASSES

#pragma mark - NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonBounds = @"NSPopUpMenuPopupButtonBounds";
NSString * const NSPopUpMenuPopupButtonOrigin = @"NSPopUpMenuPopupButtonOrigin";

#pragma mark - NSTouchBar notifications
NSString * const NSTouchBarDidExitCustomization = @"NSTouchBarDidExitCustomization";
NSString * const NSTouchBarWillEnterCustomization = @"NSTouchBarWillEnterCustomization";

#pragma mark - NSWorkspace polyfill (10.15+)
@implementation NSWorkspace (Polyfill10_9)
- (NSArray *)URLsForApplicationsToOpenURL:(NSURL *)url {
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end

#pragma mark - CGColorSpace polyfills

/* CGColorSpaceGetName (10.12+) */
CFStringRef CGColorSpaceGetName(CGColorSpaceRef cs) {
    return NULL;
}

/* CGColorSpaceEqualToColorSpace (10.12+) */
CG_EXTERN CFPropertyListRef CGColorSpaceCopyPropertyList(CGColorSpaceRef) __attribute__((weak_import));

bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef cs1, CGColorSpaceRef cs2) {
    if (cs1 == cs2) return true;
    if (!cs1 || !cs2) return false;
    if (CGColorSpaceGetModel(cs1) != CGColorSpaceGetModel(cs2)) return false;
    if (CGColorSpaceGetNumberOfComponents(cs1) != CGColorSpaceGetNumberOfComponents(cs2)) return false;
    if (CGColorSpaceCopyPropertyList) {
        CFPropertyListRef plist1 = CGColorSpaceCopyPropertyList(cs1);
        CFPropertyListRef plist2 = CGColorSpaceCopyPropertyList(cs2);
        bool equal = false;
        if (plist1 && plist2) equal = CFEqual(plist1, plist2);
        if (plist1) CFRelease(plist1);
        if (plist2) CFRelease(plist2);
        return equal;
    }
    return false;
}

#pragma mark - CGColorSpace name constants (10.11.2+)
CFStringRef const kCGColorSpaceDisplayP3 = CFSTR("kCGColorSpaceDisplayP3");
CFStringRef const kCGColorSpaceExtendedSRGB = CFSTR("kCGColorSpaceExtendedSRGB");
CFStringRef const kCGColorSpaceLinearSRGB = CFSTR("kCGColorSpaceLinearSRGB");
CFStringRef const kCGColorSpaceExtendedLinearSRGB = CFSTR("kCGColorSpaceExtendedLinearSRGB");
CFStringRef const kCGColorSpaceExtendedDisplayP3 = CFSTR("kCGColorSpaceExtendedDisplayP3");
CFStringRef const kCGColorSpaceLinearDisplayP3 = CFSTR("kCGColorSpaceLinearDisplayP3");
CFStringRef const kCGColorSpaceExtendedLinearDisplayP3 = CFSTR("kCGColorSpaceExtendedLinearDisplayP3");
CFStringRef const kCGColorSpaceITUR_2020 = CFSTR("kCGColorSpaceITUR_2020");
CFStringRef const kCGColorSpaceExtendedITUR_2020 = CFSTR("kCGColorSpaceExtendedITUR_2020");
CFStringRef const kCGColorSpaceROMMRGB = CFSTR("kCGColorSpaceROMMRGB");

#pragma mark - Additional dyld/cache stubs (10.10+)
const void *_dyld_get_dlopen_image_header(void *handle) { return NULL; }
const void *_dyld_get_image_uuid(const void *header) { return NULL; }
const void *_dyld_get_shared_cache_uuid(void) { return NULL; }
void cache_simulate_memory_warning_event(uint64_t a) { }
const char *dyld_shared_cache_file_path(void) { return NULL; }
const void *dyld_image_header_containing_address(const void *addr) { return NULL; }

#pragma mark - NSText constants (10.12+)
NSString * const NSTextCheckingInsertionPointKey = @"NSTextCheckingInsertionPointKey";
NSString * const NSTextInsertionUndoableAttributeName = @"NSTextInsertionUndoableAttributeName";

#pragma mark - Additional NSPopUpMenu constants
NSString * const NSPopUpMenuPopupButtonLabelOffset = @"NSPopUpMenuPopupButtonLabelOffset";
NSString * const NSPopUpMenuPopupButtonSize = @"NSPopUpMenuPopupButtonSize";
NSString * const NSPopUpMenuPopupButtonWidget = @"NSPopUpMenuPopupButtonWidget";

#pragma mark - NSURLProtocol private methods (10.10+) used by Safari 9.x
// Safari 9.x calls +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] which is a 10.10+
// private API. On 10.9 this throws "doesNotRecognizeSelector". Provide a category that
// implements it by falling back to the public +[NSURLProtocol classForRequest:] equivalent
// (which doesn't exist publicly either, but the underlying lookup table does).
// Inject +_protocolClassForRequest:skipAppSSO: at runtime (class_addMethod on the metaclass) rather
// than via an ObjC category, so this object carries NO static reference to _OBJC_CLASS_$_NSURLProtocol.
// The 26.1 build SDK homes that class symbol in CFNetwork, but on the 10.9 runtime NSURLProtocol lives
// in Foundation; a static category reference mis-binds to CFNetwork and fails to load (dyld: Symbol not
// found _OBJC_CLASS_$_NSURLProtocol Expected in CFNetwork). App SSO does not exist on 10.9, so the
// method returns Nil and the caller (WebCoreNSURLExtras) falls back to the standard URL-loading path.
static Class polyfill_NSURLProtocol_protocolClassForRequest_skipAppSSO(id self, SEL _cmd, id request, BOOL skip) {
    (void)self; (void)_cmd; (void)request; (void)skip;
    return Nil;
}
__attribute__((constructor)) static void installNSURLProtocolSkipAppSSOPolyfill(void) {
    Class cls = objc_getClass("NSURLProtocol");
    if (!cls)
        return;
    SEL sel = sel_registerName("_protocolClassForRequest:skipAppSSO:");
    if (class_getClassMethod(cls, sel))
        return; // already provided by the OS (10.10+)
    Class meta = object_getClass((id)cls); // class methods live on the metaclass
    class_addMethod(meta, sel, (IMP)polyfill_NSURLProtocol_protocolClassForRequest_skipAppSSO, "#@:@c");
}

#pragma mark - NSView beginDeferringViewInWindowChanges (10.11+)

// Safari 9's BrowserWindowControllerMac _selectTabAtIndex: calls
// -[NSView beginDeferringViewInWindowChanges] / endDeferringViewInWindowChanges
// before/after swapping the active tab's view (10.11+ NSView API).
// On 10.9 the call throws "unrecognized selector" and aborts Safari's tab
// transition — without this polyfill, Cmd+T leaves Safari with no visible tab
// bar and a blank content area. With the polyfill (no-op), Safari's transition
// completes: tab bar becomes visible, new tab shows its top-sites/favorites
// page. NOTE: the previous tab's WKView content is still lost on switch-back —
// that is a separate deeper bug being worked on independently.
@interface NSView (Polyfill_10_11_DeferViewInWindow)
- (void)beginDeferringViewInWindowChanges;
- (void)endDeferringViewInWindowChanges;
- (void)endDeferringViewInWindowChangesSync;
@end

@implementation NSView (Polyfill_10_11_DeferViewInWindow)
- (void)beginDeferringViewInWindowChanges { /* 10.9 no-op */ }
- (void)endDeferringViewInWindowChanges { /* 10.9 no-op */ }
- (void)endDeferringViewInWindowChangesSync { /* 10.9 no-op */ }
@end

// 10.9 backport: kVTVideoEncoderSpecification_RequiredLowLatency is a 10.13+
// VideoToolbox encoder-spec key. libwebrtc's VTB H.264/VP9 encoder (built with
// ENABLE_WEB_RTC) references it; WebCore resolves it via flat-namespace dynamic
// lookup, so without a definition dyld aborts Safari at launch ("Symbol not
// found: _kVTVideoEncoderSpecification_RequiredLowLatency"). Provide the real
// CFString value; on 10.9 the encoder simply ignores this unknown spec key.
#import <CoreFoundation/CoreFoundation.h>
const CFStringRef kVTVideoEncoderSpecification_RequiredLowLatency = CFSTR("RequiredLowLatency");

#pragma mark - macOS 26.1 SDK symbols absent on the 10.9 runtime
// The 26.1 build SDK declares these as extern / @interface, so WebKit emits
// undefined references that dyld cannot resolve against the 10.9 system
// frameworks. Define them here (force-loaded polyfill archive) so the
// references bind in-image. The features are unused/inert on 10.9, so only the
// SYMBOL needs to exist with the right type; values are low-stakes.

// --- NSTextList marker format constants (10.13+) -------------------------
// Documented "{...}" CSS-list-style marker strings.
NSString * const NSTextListMarkerCircle = @"{circle}";
NSString * const NSTextListMarkerDecimal = @"{decimal}";
NSString * const NSTextListMarkerDisc = @"{disc}";
NSString * const NSTextListMarkerLowercaseAlpha = @"{lower-alpha}";
NSString * const NSTextListMarkerLowercaseHexadecimal = @"{lower-hexadecimal}";
NSString * const NSTextListMarkerLowercaseLatin = @"{lower-latin}";
NSString * const NSTextListMarkerLowercaseRoman = @"{lower-roman}";
NSString * const NSTextListMarkerOctal = @"{octal}";
NSString * const NSTextListMarkerSquare = @"{square}";
NSString * const NSTextListMarkerUppercaseAlpha = @"{upper-alpha}";
NSString * const NSTextListMarkerUppercaseHexadecimal = @"{upper-hexadecimal}";
NSString * const NSTextListMarkerUppercaseLatin = @"{upper-latin}";
NSString * const NSTextListMarkerUppercaseRoman = @"{upper-roman}";

// --- NSPasteboard name / type constants (10.13+) -------------------------
NSString * const NSPasteboardNameGeneral = @"Apple CFPasteboard general";
NSString * const NSPasteboardNameFind = @"Apple CFPasteboard find";
NSString * const NSPasteboardNameFont = @"Apple CFPasteboard font";
NSString * const NSPasteboardNameDrag = @"Apple CFPasteboard drag";
NSString * const NSPasteboardTypeURL = @"public.url";
NSString * const NSPasteboardTypeFileURL = @"public.file-url";

// --- Other AppKit / Foundation string constants --------------------------
NSString * const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
NSString * const NSPresentationIntentAttributeName = @"NSPresentationIntent";
NSString * const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification = @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification";

// --- NSHTTPCookie SameSite policy constants (10.15+) ----------------------
NSString * const NSHTTPCookieSameSiteLax = @"lax";
NSString * const NSHTTPCookieSameSiteStrict = @"strict";

// --- NSURLSessionTask priority constants (float) -------------------------
const float NSURLSessionTaskPriorityDefault = 0.5f;
const float NSURLSessionTaskPriorityLow = 0.0f;
const float NSURLSessionTaskPriorityHigh = 1.0f;

// --- NSEdgeInsetsEqual (10.10+) ------------------------------------------
// WebKit has an undefined ref, so the SDK exposes it as an extern function
// (not static inline) — define the real symbol with the SDK signature.
BOOL NSEdgeInsetsEqual(NSEdgeInsets a, NSEdgeInsets b)
{
    return a.top == b.top && a.left == b.left
        && a.bottom == b.bottom && a.right == b.right;
}

// --- Class stubs (only the class symbol matters; inert on 10.9) ----------
// The 26.1 SDK's @interface declarations for these are NOT in scope in this
// --no-default-config compile (clang reports "cannot find interface
// declaration"), so a bare @implementation would create a base-class-less root
// class. Per the established fallback, declare a minimal @interface with the
// correct superclass so the class gets real ObjC metadata.
#ifndef POLYFILL_NO_OBJC_CLASSES
@interface NSVisualEffectView : NSView @end
@implementation NSVisualEffectView @end

@interface NSDateComponentsFormatter : NSFormatter @end
@implementation NSDateComponentsFormatter @end
#endif  // POLYFILL_NO_OBJC_CLASSES

#endif // !POLYFILL_GSTREAMER_ONLY
