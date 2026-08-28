// wk_selref_scope.m — WebKit-scoped ObjC-method polyfills via per-image selector rewriting (THE MECHANISM).
//
// A category method added to a system class is process-global: a host app embedding WebKit that
// version-probes the method (respondsToSelector:/instancesRespondToSelector:) is told the API exists,
// assumes a newer OS, and then uses other modern APIs it can't have -> crash. Two-level namespacing
// scopes symbols (C functions, whole absent classes) but not a method added to a shared class, because
// dispatch keys on the selector, not a linker symbol.
//
// This registers each polyfilled method under a PRIVATE selector (wk_<name>) on the real class, and at
// load time rewrites the matching entries in each WebKit image's __objc_selrefs from the public selector
// to the private one. WebKit's own call sites (`[ctx CGContext]`) then dispatch `wk_CGContext` to the
// polyfill via ordinary objc_msgSend, while the public selector genuinely does not exist on the class —
// so a host app's respondsToSelector: returns NO for the correct reason. No interposition, no swizzling
// and no gating: the cost is a one-time selref scan per WebKit image, plus one pass over each image's
// classes to give a class that HAS the real method its own private-selector entry point (see
// wk_alias_class). Runs in every process WebKit loads into.
//
// A "WebKit image" is any binary carrying __DATA,__wk_marker, injected by wk_image_marker.c which is
// force-loaded into every WebKit framework (WEBKIT_FRAMEWORK). This object (the patcher + registry) and
// polyfills/methods/ (the polyfill methods + WK_POLYFILL_SEL registrations) are force-loaded into WebCore only
// — they load early in every rendering process and keep the AppKit categories out of the setuid-JSC path.
// THE POLYFILLS THEMSELVES LIVE IN polyfills/methods/; add new ones there.

#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// A registry that cannot record an entry has no degraded mode. The polyfill is already compiled in and
// WebKit's selrefs are already pointing at it, so a dropped entry does not fall back to anything --
// the public selector simply stays unrewritten (WK_MAX_SEL) or the wk_ method never gets added to its
// class (WK_MAX_ADD), and the first send dies with an unrecognized selector at whatever call site
// happens to run first, arbitrarily far from the load-time cause. Say what happened here instead.
// Same reasoning, and same shape, as resolveSystemDlsym() in wk_polyfill_runtime.c.
static void wk_registry_full(const char *what, int cap, const char *capName, const char *dropped)
{
    fprintf(stderr, "[wk_selref_scope] FATAL: more than %d (%s) %s; \"%s\" cannot be recorded.\n"
                    "[wk_selref_scope] The registry is what points WebKit's rewritten selectors at the "
                    "polyfills, so anything past the cap would be dropped and would surface much later "
                    "as an unrecognized selector at an unrelated call site. Raise %s in "
                    "MavericksSupport/polyfill/mechanism/wk_selref_scope.m.\n",
            cap, capName, what, dropped, capName);
    fflush(stderr);
    abort();
}

// Resolved public->private SEL map, built from all __wk_selmap sections as their images arrive.
enum { WK_MAX_SEL = 512 };
static SEL wk_pub[WK_MAX_SEL];          // canonical public SEL (fast-path pointer match)
static const char *wk_pubname[WK_MAX_SEL]; // public selector NAME (content match — see wk_patch)
static SEL wk_priv[WK_MAX_SEL];
static int wk_intent[WK_MAX_SEL];       // WK_SELMAP_GAP_FILL / WK_SELMAP_REPLACES — see wk_alias_class
static int wk_count;                    // PUBLICATION POINT — see the synchronisation note below

// Prefilters over the registry, so the two hot loops (every selref of every WebKit image in wk_patch,
// every method of every class in wk_alias_class) pay one bit test for the overwhelmingly common case
// of a name that is not registered, instead of a linear scan of the registry. Measured in Safari's UI
// process at launch: 267,740 methods and 28,656 selrefs (the latter twice — the add-image registration
// replays the constructor's sweep) against 144 entries, ~70 ms of which the filters remove all but a
// few ms.
//
// The guarantee is one-sided: a clear bit means NO entry has this name/SEL, so skipping is safe; a set
// bit means only "scan the registry", which stays the sole authority. Bits are set before the entry is
// published through wk_count (release-store), so any reader that can reach an entry can also see its
// bits — the same happens-before edge the arrays rely on. The reverse order would be a correctness
// bug: a reachable entry whose bit is not yet visible would be skipped. A bit set for an entry the
// reader cannot reach yet merely sends it into a scan that finds nothing, which is what no filter
// would have done anyway. Bits are only ever set, never cleared, matching the append-only registry.
enum { WK_FILTER_BITS = 16384 };
static unsigned char wk_name_filter[WK_FILTER_BITS / 8];   // keyed on the selector NAME (wk_patch)
static unsigned char wk_sel_filter[WK_FILTER_BITS / 8];    // keyed on the canonical SEL (wk_alias_class)

static unsigned wk_name_hash(const char *s)
{
    unsigned h = 5381;   // djb2
    while (*s)
        h = h * 33 ^ (unsigned char)*s++;
    return h & (WK_FILTER_BITS - 1);
}

// SELs are canonical pointers (sel_registerName on the writer side, method_getName of a realized
// class's method on the reader side), so hashing the pointer is sound. The low 4 bits carry no
// entropy (allocation alignment); fold in higher bits instead.
static unsigned wk_sel_hash(SEL sel)
{
    uintptr_t p = (uintptr_t)(const void *)sel;
    return (unsigned)((p >> 4) ^ (p >> 15)) & (WK_FILTER_BITS - 1);
}

#define WK_FILTER_SET(f, h)  ((f)[(h) >> 3] |= (unsigned char)(1u << ((h) & 7)))
#define WK_FILTER_TEST(f, h) ((f)[(h) >> 3] & (1u << ((h) & 7)))

// Synchronisation.
//
// Writers (wk_collect, wk_install_added) run from the constructor AND from the dyld add-image callback,
// which fires on whichever thread called dlopen, at any point in the process's life. wk_patch reads the
// registry from that same callback without the lock, so two concurrent dlopens can have one publishing
// entries while the other reads them.
//
// The registry is APPEND-ONLY: an entry's three fields are stored once, before the entry is reachable,
// and are never mutated or removed for the life of the process. So a reader needs exactly one guarantee
// — if it can see index i, it can also see entry i's fields. wk_count provides it: the writer stores the
// fields, then stores the incremented count with __ATOMIC_RELEASE; a reader loads the count with
// __ATOMIC_ACQUIRE and never touches an index at or above what it loaded. That release/acquire pair is a
// happens-before edge covering the three field stores, so a half-written entry is simply unreachable —
// no lock, no atomic, and no added instruction on wk_patch's read path (an acquire load is a plain mov
// on x86_64). Immutability after publication is what makes an ordered publish SUFFICIENT here: with
// entries that could be rewritten or freed a reader would additionally need reclamation (RCU/refcount),
// but nothing here ever unpublishes.
//
// Startup-cost accounting, printed by the constructor when WK_POLYFILL_REPORT is set (the same switch
// wk_polyfill_runtime.c's report() reads). This work runs in every process that loads WebKit, so what
// it costs is worth being able to see. The patch counters are relaxed atomics because wk_patch runs
// without the lock; the numbers are diagnostics, not part of any protocol.
static long wk_stat_classes, wk_stat_methods;
static long wk_stat_refs, wk_stat_rewritten;

// Writers additionally take wk_reg_lock, so two concurrent dlopens cannot claim the same slot or race
// each other's duplicate scan. wk_image_initializing takes it too — not for the registry, which it only
// reads, but so that an arriving image cannot be aliased against a half-grown registry at the same
// moment wk_collect is sweeping the loaded images for the entries it just added; serialising the two
// leaves the image covered by exactly one of them. Nothing under the lock can re-enter this file
// (objc_getClass/sel_registerName/class_addMethod/class_copyMethodList load no images), so it cannot
// deadlock against dyld's own lock, which is already held whenever it is taken.
static pthread_mutex_t wk_reg_lock = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------------------------------------
// Class-correct aliasing: a class that HAS the real method also gets its own implementation under the
// private selector.
//
// The rewrite is by NAME: every `foo` selref in a WebKit image becomes `wk_foo`, and a selref carries
// no class. That is exactly right when WebKit sends `foo` to the one class whose `foo` is missing on
// 10.9, but some names go to several classes (`valueForHTTPHeaderField:` to NSHTTPURLResponse, which
// lacks it here, and to NSURLRequest, which has it). A class that DOES have the real method would
// otherwise be sent a `wk_foo` it does not implement -> unrecognized selector.
//
// So as each image arrives, every registered public selector that a class of that image implements
// ITSELF is installed a second time under the private name, bound to that class's own IMP and type
// encoding. Declaring a method polyfill therefore does not require knowing which other classes share
// the name — it is correct by construction for every class, including ones nobody thought to list.
//
// This is deliberately load-time work rather than a +resolveInstanceMethod:/+resolveClassMethod: hook
// on the unrecognized-selector path. Those are methods of NSObject: replacing their implementations
// would install a patched ObjC runtime in every process that loads WebKit — Mail, iBooks, Xcode — to
// paper over an ambiguity that only this layer's own by-name rewrite creates. The rewrite is what turns
// `foo` into `wk_foo` for classes it did not mean, so the rewrite's own load-time pass is where that is
// answered.
//
// Nothing is ever added under a PUBLIC selector: the only method installed anywhere is wk_<name>, which
// nothing outside WebKit's rewritten images ever sends. A host app's respondsToSelector: for the public
// name keeps answering exactly what the class really says.
//
// The unit is the class as its own image defines it, which is what the alias is for: `wk_foo` has to
// find 10.9's real `foo`, and a class's real API ships with the class. A method some THIRD image bolts
// onto someone else's class by category is outside that, and no per-image enumeration the runtime
// offers reports it. Audited on 10.9.5 across a 180-image process: of every class implementing one of
// the registered selectors, exactly two got it from another image -- -[NSString containsString:] via
// ISSupport and -[NSArray containsString:] via QTKit. NSString carries this layer's own
// wk_containsString: either way, and nothing sends containsString: to an NSArray.

// The class's OWN methods (class_copyMethodList), not class_getInstanceMethod: an inherited method is
// aliased on the class that defines it and subclasses inherit the alias along with it, and — the reason
// it matters — class_getInstanceMethod consults the resolver, so asking it would send
// +resolveInstanceMethod: to every class in the process for every selector the class does not have.
// Pass a metaclass to alias class methods.
//
// A class that implements the real public selector ITSELF gets wk_<name> bound to that real IMP, via
// class_addMethod. On the polyfill's own TARGET class this layer's category already installed
// wk_<name> (the body), so class_addMethod is a no-op there and the body keeps serving WebKit's
// rewritten call — the runtime does what the polyfill declared, with no forwarding to 10.9. A
// DIFFERENT class that merely shares the selector name has no wk_<name> of its own, so it gets one
// bound to its real method (the by-name selref rewrite must not hijack another class's method).
//
// If the target class turns out to implement the public selector after all, a GAP_FILL body would
// shadow 10.9's — a mistake the build gate rejects (the shadow gate in build-polyfill.sh), exactly as it rejects a
// shadowing C gap-fill.
//
// INTENT DECIDES WHAT HAPPENS TO A SUBCLASS OF THE TARGET. Aliasing a class's own IMP under wk_<name>
// puts that IMP in FRONT of an inherited body, because the class's own method list is searched first.
// For a GAP_FILL that is right: 10.9 has no such method, so any class carrying the name is an unrelated
// class whose real method the by-name rewrite must not hijack. For a REPLACES it inverts the polyfill —
// the body exists precisely to shadow a method 10.9 HAS, and the classes most likely to implement that
// method are the target's own subclasses. Aliasing there hands the subclass back its own IMP and the
// body never runs, which is the exact failure WK_POLYFILL_ADD_REPLACES documents (wk_selref_scope.h) and
// answers with class_replaceMethod. Measured on 10.9.5: -[NSPanel initWithContentRect:styleMask:backing:
// defer:], -[NSSavePanel initWithContentRect:…], -[_NSPopoverWindow initWithContentRect:…] /
// -setContentView:, -[NSCarbonWindow setStyleMask:] all shadow their NSWindow polyfill this way, and
// -[NSURL wk_initWithString:] is written for an NSURL SUBCLASS (isMemberOfClass: test) it could never
// reach.
//
// So a REPLACES entry does NOT alias over a body already in the class's chain: the body keeps serving
// the rewritten call on every such subclass and calls through to that subclass's own implementation.
// An UNRELATED class (no body in its chain: -[NSScrollView setContentView:], -[NSBox setContentView:])
// is aliased exactly as before.
//
// ONE EXCEPTION, and it is not a carve-out but the same rule applied honestly: a class defined in a
// WEBKIT image. Those classes' own sends are rewritten too, so they are participants in the wk_ chain,
// not just receivers of it — and a subclass override that says [super foo] emits a rewritten
// wk_foo super-send. Leaving such a class un-aliased puts the body in FRONT of the override, so the
// body's call-through re-enters the override, whose super lands back in the body: unbounded recursion.
// Measured targets in this tree: -[WebCoreFullScreenWindow initWithContentRect:styleMask:backing:defer:]
// and -setStyleMask:, and -[WKDataListSuggestionWindow initWithContentRect:…], all of which call super.
// Aliasing them keeps the override as the entry point and makes its [super wk_foo] mean exactly what
// [super foo] means — one level up, into the body — which is where the polyfill's work belongs anyway.
// A SYSTEM class is never rewritten, sends the polyfill nothing, and so is safe in front of.
//
// The chain test is only meaningful because the body is already attached when this runs: the polyfill
// category and this pass ship in the SAME image (WebCore), and the ObjC runtime attaches an image's
// categories in map_images, before any of that image's initializers — the constructor below and the
// dyld state-change handler both run after it, and every later image arrives later still.
//
// Resolver-free by construction: the chain is walked over each class's OWN method list rather than
// asked via class_getInstanceMethod, which consults +resolveInstanceMethod:. The walk runs only for a
// class that actually implements a registered public selector — a handful process-wide — and stops at
// the first class defining the name, so the target's subclasses stop within a step or two.
// One class's OWN method list, resolver-free. NULL if the class does not define the selector itself.
static IMP wk_own_imp(Class cls, SEL sel)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    if (!methods)
        return NULL;
    IMP imp = NULL;
    for (unsigned int i = 0; i < n && !imp; i++)
        if (method_getName(methods[i]) == sel)
            imp = method_getImplementation(methods[i]);
    free(methods);
    return imp;
}

// Ordinary method lookup for `sel` starting at `cls`, done by hand so it never consults
// +resolveInstanceMethod: the way class_getMethodImplementation does.
static IMP wk_chain_imp(Class cls, SEL sel)
{
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        IMP imp = wk_own_imp(c, sel);
        if (imp)
            return imp;
    }
    return NULL;
}

// THE CALL-THROUGH FOR A REPLACES BODY. Every WK_POLYFILL_SEL_REPLACES / WK_POLYFILL_ADD_REPLACES body
// needs to run "the implementation I stand in for", and the naive spelling — send the PUBLIC selector to
// self — is wrong, because it re-resolves from the TOP of the receiver's chain. If any class between the
// receiver and the body overrides the public selector in a WebKit image, that override runs again, its
// [super …] (rewritten to wk_) lands back in the body, and it recurses without bound.
//
// The question is not "what would the receiver do", it is "what is one level below ME". So the answer is
// derived from the BODY's class:
//
//   * Find C: the class CLOSEST TO THE BODY'S CLASS, strictly below it in the receiver's chain, that
//     defines the private selector in its OWN method list. That is the aliased override whose
//     [super wk_foo] reached this body — possibly several levels below the receiver's own class, which
//     is exactly the case a receiver-derived answer gets wrong.
//   * If C exists, the body stands in for what super means THERE: the public implementation starting at
//     C's superclass.
//   * If no C exists, nothing overrides between here and the receiver, so this body is the receiver's own
//     entry point and the receiver's own public implementation is what to call.
//
// Correct for: plain target class; a multi-level system chain (NSSavePanel : NSPanel : NSWindow); one
// WebKit override; a WebKit override sitting on a system subclass; a WebKit subclass that merely inherits
// an aliased override; and two WebKit overrides stacked in one chain. No class list, no assumption about
// which classes exist, and resolver-free throughout.
IMP wk_replaces_call_through_class(id receiver, Class bodyClass, SEL privateSelector, SEL publicSelector)
{
    Class start = object_getClass(receiver);

    // If the body's class is not in this chain at all, there is no "below me" to speak of; the receiver's
    // own implementation is the only meaningful answer. (Not reachable from a body that is running on
    // this receiver; guarded so a mis-wired caller degrades instead of walking off the chain.)
    bool bodyClassInChain = false;
    for (Class c = start; c; c = class_getSuperclass(c))
        if (c == bodyClass) { bodyClassInChain = true; break; }
    if (!bodyClassInChain)
        return wk_chain_imp(start, publicSelector);

    Class overrideOwner = Nil;
    for (Class c = start; c && c != bodyClass; c = class_getSuperclass(c))
        if (wk_own_imp(c, privateSelector))
            overrideOwner = c;   // keep the LAST, which is the one closest to bodyClass

    IMP imp = overrideOwner ? wk_chain_imp(class_getSuperclass(overrideOwner), publicSelector)
                            : wk_chain_imp(start, publicSelector);
    // A REPLACES entry asserts 10.9 HAS the method, so this cannot be NULL for a correct registration;
    // fall back to the receiver's own rather than hand a caller a NULL to jump through.
    return imp ? imp : wk_chain_imp(start, publicSelector);
}

// Same, for a WK_POLYFILL_ADD_REPLACES body: a C function IMP installed on a class named by string, so
// the caller knows its own IMP but not which of the entry's classes this receiver belongs to. The body's
// class is the one in the chain whose OWN private-selector implementation IS that function.
IMP wk_replaces_call_through_imp(id receiver, IMP bodyIMP, SEL privateSelector, SEL publicSelector)
{
    for (Class c = object_getClass(receiver); c; c = class_getSuperclass(c))
        if (wk_own_imp(c, privateSelector) == bodyIMP)
            return wk_replaces_call_through_class(receiver, c, privateSelector, publicSelector);
    return wk_chain_imp(object_getClass(receiver), publicSelector);
}

static bool wk_chain_defines(Class cls, SEL sel)
{
    return wk_chain_imp(cls, sel) != NULL;
}

static void wk_alias_class(Class cls, int from, int to, bool clsFromWebKitImage)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    if (!methods)
        return;
    wk_stat_methods += n;
    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(methods[i]);
        if (!WK_FILTER_TEST(wk_sel_filter, wk_sel_hash(sel)))
            continue;   // definitely not a registered selector — see the prefilter note
        for (int j = from; j < to; j++) {
            if (wk_pub[j] != sel)
                continue;
            if (wk_intent[j] == WK_SELMAP_REPLACES && !clsFromWebKitImage
                && wk_chain_defines(cls, wk_priv[j]))
                break;   // the body is already in this class's chain — let it win (see above)
            IMP realIMP = method_getImplementation(methods[i]);
            const char *types = method_getTypeEncoding(methods[i]);
            class_addMethod(cls, wk_priv[j], realIMP, types);
            break;
        }
    }
    free(methods);
}

// One image's classes. objc_copyClassNamesForImage answers for that image alone, so the work a dlopen
// pays for is bounded by what it brought in rather than by every class in the process. objc_getClass
// realizes the class, which is what makes its method list safe to copy.
// A WebKit image is one carrying __DATA,__wk_marker — the same test wk_patch uses to decide whose
// selrefs to rewrite, which is exactly the property wk_alias_class needs: an image whose sends are
// rewritten is one whose [super …] sends are rewritten.
static bool wk_is_webkit_image(const struct mach_header *mh)
{
    unsigned long size = 0;
    return mh && getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__wk_marker", &size) != NULL;
}

static void wk_alias_image(const char *path, const struct mach_header *mh, int from, int to)
{
    if (!path || from >= to)
        return;
    unsigned int n = 0;
    const char **names = objc_copyClassNamesForImage(path, &n);
    if (!names)
        return;
    bool webKitImage = wk_is_webkit_image(mh);
    for (unsigned int i = 0; i < n; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls)
            continue;
        wk_stat_classes++;
        wk_alias_class(cls, from, to, webKitImage);                  // instance methods
        wk_alias_class(object_getClass(cls), from, to, webKitImage); // class methods, on the metaclass
    }
    free(names);
}

// Every image loaded so far, for a range of registry entries. Runs when the REGISTRY grows rather than
// when an image arrives: classes scanned earlier have never been asked about a selector registered
// since. Bounded by the number of WebKit images carrying __wk_selmap (one today), not by dlopens.
static void wk_alias_loaded_images(int from, int to)
{
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++)
        wk_alias_image(_dyld_get_image_name(i), _dyld_get_image_header(i), from, to);
}

static void wk_collect(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_selmap_entry *e =
        (const struct wk_selmap_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                        "__DATA", "__wk_selmap", &size);
    if (!e)
        return;
    int n = (int)(size / sizeof(struct wk_selmap_entry));
    pthread_mutex_lock(&wk_reg_lock);
    int before = wk_count;
    for (int i = 0; i < n; i++) {
        SEL p = sel_registerName(e[i].pub);
        int dup = 0;
        for (int j = 0; j < wk_count; j++)   // plain reads: we are the only writer while holding the lock
            if (wk_pub[j] == p) { dup = 1; break; }
        if (dup)
            continue;
        if (wk_count >= WK_MAX_SEL)
            wk_registry_full("distinct ObjC method polyfills (WK_POLYFILL_SEL) are registered",
                             WK_MAX_SEL, "WK_MAX_SEL", e[i].pub);
        int slot = wk_count;
        wk_pub[slot] = p;
        wk_pubname[slot] = e[i].pub; // stable string literal in the image's __wk_selmap owner
        wk_priv[slot] = sel_registerName(e[i].priv);
        wk_intent[slot] = e[i].intent;   // read by wk_alias_class, which runs below under this lock
        // The entry's filter bits, before the entry is reachable (see the prefilter note).
        WK_FILTER_SET(wk_name_filter, wk_name_hash(e[i].pub));
        WK_FILTER_SET(wk_sel_filter, wk_sel_hash(p));
        // Publishes the stores above to every reader that acquire-loads wk_count.
        __atomic_store_n(&wk_count, slot + 1, __ATOMIC_RELEASE);
    }
    // The selectors just registered have never been looked for in the classes already loaded. Classes
    // from images that arrive later are covered by wk_image_initializing.
    wk_alias_loaded_images(before, wk_count);
    pthread_mutex_unlock(&wk_reg_lock);
}

static void wk_patch(const struct mach_header *mh)
{
    unsigned long msz = 0;
    if (!getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__wk_marker", &msz))
        return; // not a WebKit image
    unsigned long size = 0;
    // Per the ObjC ABI a __objc_selrefs slot holds the image-local methname string before objc uniques
    // the image and the canonical SEL after, so the section is a pointer array, not an array of SEL.
    void **refs = (void **)getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__objc_selrefs", &size);
    if (!refs)
        refs = (void **)getsectiondata((const struct mach_header_64 *)mh, "__DATA_CONST", "__objc_selrefs", &size);
    int count = __atomic_load_n(&wk_count, __ATOMIC_ACQUIRE);   // see the synchronisation note
    if (!refs || !size || count == 0)
        return;
    // selrefs may live in read-only __DATA_CONST; make the range writable (no SIP on 10.9).
    vm_protect(mach_task_self(), (vm_address_t)refs, size, false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    int n = (int)(size / sizeof(void *));
    __atomic_fetch_add(&wk_stat_refs, n, __ATOMIC_RELAXED);
    for (int i = 0; i < n; i++) {
        // Match by NAME, not just pointer: for an image dlopen'd AFTER launch, dyld runs this add-image
        // callback BEFORE objc uniques the image's selrefs, so refs[i] still points to the image's local
        // methname string (not the canonical SEL) — a pointer compare would miss it. strcmp catches both
        // states; a selref always points to a valid C string (methname before uniquing, SEL after). After
        // we rewrite to wk_priv, objc's later uniquing reads "wk_<name>" and re-derives the same private
        // SEL, so the rewrite sticks.
        const char *s = (const char *)refs[i];
        if (!WK_FILTER_TEST(wk_name_filter, wk_name_hash(s)))
            continue;   // definitely not a registered name — see the prefilter note. This also makes
                        // the add-image replay of an already-patched image cheap: a rewritten ref
                        // reads "wk_<name>", whose bit is not set.
        for (int j = 0; j < count; j++)
            if (refs[i] == (void *)wk_pub[j] || strcmp(s, wk_pubname[j]) == 0) {
                refs[i] = (void *)wk_priv[j];
                __atomic_fetch_add(&wk_stat_rewritten, 1, __ATOMIC_RELAXED);
                break;
            }
    }
}

// Entries whose named class did not exist yet when their image was scanned — see wk_install_added.
// Pointers into the declaring image's __wk_addmap, which is const data in an image that is never
// unloaded (the sections live in WebCore's force-loaded polyfill objects), so they stay valid.
// Guarded by wk_reg_lock and only ever touched from the image-load path. The cap bounds the total number
// of WK_POLYFILL_ADD declarations in the build (66 as of the DataDetectors additions — recount with
// `grep -c "WK_POLYFILL_ADD" polyfills/*.m*` when raising), not anything the running process controls.
enum { WK_MAX_ADD = 128 };
static const struct wk_addmap_entry *wk_addmap_deferred[WK_MAX_ADD];
static int wk_addmap_deferred_count;

// YES once the entry's class exists — the method is now installed, or was already there.
static BOOL wk_install_add_entry(const struct wk_addmap_entry *e)
{
    // A leading '+' on the class name means the entry is a CLASS method: install it on the metaclass,
    // which is where the runtime looks when the receiver is the class object itself. Spelled this way so
    // the entry stays a plain (name, sel, imp, types) record resolved by string at runtime, which is the
    // whole reason WK_POLYFILL_ADD exists. The metaclass is reached through the class object
    // (object_getClass), NOT objc_getMetaClass: 10.9's objc_getMetaClass prints
    // "class `X' not linked into application" on every miss, and a deferred entry for a
    // lazily-loaded framework's class polls this on every image event until the class arrives —
    // hundreds of stderr lines per process launch. objc_getClass misses silently.
    BOOL isClassMethod = e->cls[0] == '+';
    Class base = objc_getClass(isClassMethod ? e->cls + 1 : e->cls);
    Class c = (base && isClassMethod) ? object_getClass(base) : base;
    if (!c)
        return NO;
    if (e->intent == WK_SELMAP_REPLACES) {
        // Deliberate override: the class-correct aliasing has already run for the classes loaded so
        // far, so the wk_ name may already be bound to 10.9's real method -- replace it. Idempotent
        // too: installing the same IMP again changes nothing.
        class_replaceMethod(c, sel_registerName(e->sel), (IMP)e->imp, e->types);
        return YES;
    }
    // Idempotent: class_addMethod is a no-op (returns NO) if the wk_ method already exists.
    class_addMethod(c, sel_registerName(e->sel), (IMP)e->imp, e->types);
    return YES;
}

// Install the wk_ methods registered by WK_POLYFILL_ADD: add each C-function IMP to the runtime-resolved
// class (no compile-time classref — safe for moved-framework classes). See the header.
//
// The class an entry names routinely belongs to a framework that loads LATER than the image declaring the
// entry — that is the whole point of WK_POLYFILL_ADD, which exists for classes that moved frameworks
// (NSURLSessionTask/__NSCFURLSessionTask arrive with CFNetwork/Foundation, long after WebCore). Installing
// only the new image's entries therefore left those permanently unresolved: objc_getClass returned NULL
// once and was never asked again, and the first send of the wk_ selector died with an unrecognised
// selector (this is what crashed the NetworkProcess on every fresh network load). So each image load also
// retries the entries still outstanding from EVERY image. The retry list drains as the classes appear and
// is empty in the common case, so a dlopen costs nothing extra once everything is installed — never
// O(images x entries).
static void wk_install_added(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_addmap_entry *e =
        (const struct wk_addmap_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                       "__DATA", "__wk_addmap", &size);
    int n = e ? (int)(size / sizeof(struct wk_addmap_entry)) : 0;

    pthread_mutex_lock(&wk_reg_lock);
    // Outstanding entries from earlier images: this image may be the framework they were waiting for.
    int keep = 0;
    for (int i = 0; i < wk_addmap_deferred_count; i++)
        if (!wk_install_add_entry(wk_addmap_deferred[i]))
            wk_addmap_deferred[keep++] = wk_addmap_deferred[i];
    wk_addmap_deferred_count = keep;
    // Then this image's own entries; whatever cannot be installed yet joins the retry list. Dedup by
    // entry address: an image is scanned twice at startup (the constructor's loop, then the add-image
    // registration firing for everything already loaded), and an entry may still be unsatisfied both times.
    for (int i = 0; i < n; i++) {
        if (wk_install_add_entry(&e[i]))
            continue;
        int dup = 0;
        for (int j = 0; j < wk_addmap_deferred_count; j++)
            if (wk_addmap_deferred[j] == &e[i]) { dup = 1; break; }
        if (dup)
            continue;
        if (wk_addmap_deferred_count >= WK_MAX_ADD)
            wk_registry_full("WK_POLYFILL_ADD methods are waiting for their class to load",
                             WK_MAX_ADD, "WK_MAX_ADD", e[i].sel);
        wk_addmap_deferred[wk_addmap_deferred_count++] = &e[i];
    }
    pthread_mutex_unlock(&wk_reg_lock);
}

static void wk_add_image(const struct mach_header *mh, intptr_t slide)
{
    (void)slide;
    wk_collect(mh);
    wk_install_added(mh);
    wk_patch(mh);
}

// WHEN a new image's classes can be aliased is not a free choice: the runtime has to know about them.
// objc reads an image's classes from its own dyld notification, and for an image loaded after launch
// that happens AFTER the add-image callback above — measured on 10.9.5, inside that callback
// objc_copyClassNamesForImage() reports 0 classes for the arriving image and objc_getClass() cannot
// find them, so aliasing from there would silently cover nothing but what was already loaded at launch.
// dyld_image_state_dependents_initialized is the first state where the runtime has them (798 of 798 for
// a dlopen'd AddressBook.framework), and it is still ahead of the image's own initializers, so no code
// from the image has run yet. It is the same state objc itself uses to run +load.
enum { WK_DYLD_STATE_DEPENDENTS_INITIALIZED = 45 };
typedef const char *(*wk_dyld_state_handler)(uint32_t state, uint32_t count,
                                             const struct dyld_image_info *info);
typedef void (*wk_dyld_register_handler)(uint32_t state, bool batch, wk_dyld_state_handler handler);

// Returning a string would tell dyld the image is unacceptable and fail the load; nothing here rejects
// an image, so the answer is always NULL.
static const char *wk_image_initializing(uint32_t state, uint32_t count,
                                         const struct dyld_image_info *info)
{
    (void)state;
    pthread_mutex_lock(&wk_reg_lock);   // see the synchronisation note
    // Deferred WK_POLYFILL_ADD entries must be retried HERE, not only from the add-image callback:
    // a class named by an entry can arrive via dlopen (DDActionsManager arrives with soft-linked
    // DataDetectors), and inside the add-image callback the runtime cannot see the arriving image's
    // classes yet (the measurement above), so wk_install_added's retry from there resolves nothing
    // for that image — and when the dlopen'ing call stack goes on to send the rewritten selector
    // immediately (PAL soft-link then send, WebViewImpl.mm:3703), there is no later image load to
    // rescue it and the send dies on the uninstalled wk_ method. This state is the first point the
    // runtime has the classes, so the drain belongs here; order against the alias sweep below is
    // immaterial, but not because either pass overrides the other (both use class_addMethod for a
    // GAP_FILL, which no-ops once the wk_ name exists) — it is because a passing build keeps the two
    // sweeps DISJOINT: the shadow gate forbids a gap-fill whose class owns the public selector, so no
    // (class, selector) pair is ever touched by both, and a REPLACES entry installs by
    // class_replaceMethod, which wins in either order by construction.
    int keep = 0;
    for (int i = 0; i < wk_addmap_deferred_count; i++)
        if (!wk_install_add_entry(wk_addmap_deferred[i]))
            wk_addmap_deferred[keep++] = wk_addmap_deferred[i];
    wk_addmap_deferred_count = keep;
    for (uint32_t i = 0; i < count; i++)
        wk_alias_image(info[i].imageFilePath, info[i].imageLoadAddress, 0, wk_count);
    pthread_mutex_unlock(&wk_reg_lock);
    return NULL;
}

// dyld_register_image_state_change_handler is dyld_priv.h SPI. 10.9's libdyld exports it; the build SDK
// neither declares nor stubs it, so it is declared above and resolved by name rather than linked.
//
// There is no second way to be told that the runtime has finished reading an image, and no degraded
// mode either: a process that stopped aliasing would keep running until something sent a polyfilled
// selector to a class from a dlopen'd framework, then die on an unrecognized wk_ selector arbitrarily
// far from the cause. Say what actually happened, where it happens, and stop.
static void wk_watch_for_images(void)
{
    wk_dyld_register_handler reg =
        (wk_dyld_register_handler)dlsym(RTLD_DEFAULT, "dyld_register_image_state_change_handler");
    if (!reg) {
        fprintf(stderr, "[wk_selref_scope] FATAL: libdyld does not export "
                        "dyld_register_image_state_change_handler.\n"
                        "[wk_selref_scope] It is how this layer learns that the ObjC runtime has read a "
                        "newly loaded image, which is when a class that has the real implementation of a "
                        "polyfilled method gets its wk_ entry point. Without it, WebKit's rewritten "
                        "selectors would reach such a class as an unrecognized selector, far from here. "
                        "See wk_image_initializing in "
                        "MavericksSupport/polyfill/mechanism/wk_selref_scope.m.\n");
        fflush(stderr);
        abort();
    }
    reg(WK_DYLD_STATE_DEPENDENTS_INITIALIZED, false, wk_image_initializing);
}

// Milliseconds between two mach_absolute_time readings.
static double wk_ms(uint64_t from, uint64_t to)
{
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom)
        mach_timebase_info(&timebase);
    return (double)(to - from) * timebase.numer / timebase.denom / 1e6;
}

__attribute__((constructor)) static void wk_selref_scope_init(void)
{
    // Registered before the first sweep rather than after it: an image arriving while the sweep runs is
    // aliased by its own notification, and one that arrives before the registry is published is aliased
    // by the sweep, since dyld has it listed by the time the notification can fire. Registering
    // afterwards would leave a window in which a concurrent dlopen is covered by neither. Nothing is
    // dispatched for the images already loaded (verified: a single-image handler is not called
    // retroactively) — the loop below is what covers those.
    wk_watch_for_images();

    uint64_t t0 = mach_absolute_time();
    uint32_t c = _dyld_image_count();
    // Also aliases each newly registered selector across every image loaded so far, before any patching,
    // so a rewritten selref that reaches a class this layer did not polyfill finds that class's own
    // method instead of dying.
    for (uint32_t i = 0; i < c; i++)
        wk_collect(_dyld_get_image_header(i));
    uint64_t t1 = mach_absolute_time();
    for (uint32_t i = 0; i < c; i++)
        wk_install_added(_dyld_get_image_header(i));
    uint64_t t2 = mach_absolute_time();
    for (uint32_t i = 0; i < c; i++)
        wk_patch(_dyld_get_image_header(i));
    uint64_t t3 = mach_absolute_time();
    // Also covers images dlopen'd later (fires immediately for already-loaded ones; collect dedups,
    // install_added retries whatever is still waiting for its class, and patch is idempotent since a
    // rewritten wk_ selref no longer matches any public selector).
    _dyld_register_func_for_add_image(wk_add_image);
    uint64_t t4 = mach_absolute_time();

    if (getenv("WK_POLYFILL_REPORT"))
        fprintf(stderr, "[wk_selref_scope] startup %.2f ms (%u images): collect+alias %.2f (%d sels, "
                        "%ld classes, %ld methods), install %.2f, patch %.2f (%ld refs, %ld rewritten), "
                        "add-image refire %.2f\n",
                wk_ms(t0, t4), c, wk_ms(t0, t1), wk_count, wk_stat_classes, wk_stat_methods,
                wk_ms(t1, t2), wk_ms(t2, t3), wk_stat_refs, wk_stat_rewritten, wk_ms(t3, t4));
}
