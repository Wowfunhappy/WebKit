// wk_selref_scope.m — WebKit-scoped ObjC-method polyfills via per-image selector rewriting (THE MECHANISM).
//
// A category method added to a system class is process-global: a host app embedding WebKit that
// version-probes the method (respondsToSelector:/instancesRespondToSelector:) is told the API exists,
// assumes a newer OS, and then uses other modern APIs it can't have -> crash. Two-level namespacing
// scopes symbols (C functions, whole absent classes) but not a method added to a shared class, because
// dispatch keys on the selector, not a linker symbol.
//
// A polyfill is a method of a placeholder class (a WK_POLYFILL_ADD_METHODS / WK_POLYFILL_REPLACE_METHODS
// block, wk_selref_scope.h). At load this installs each such method on the block's target classes under
// a PRIVATE selector (wk_<name>) and rewrites the matching entries in each WebKit image's __objc_selrefs
// from the public selector to the private one. WebKit's own call sites (`[ctx CGContext]`) then dispatch
// `wk_CGContext` to the polyfill via ordinary objc_msgSend, while the public selector genuinely does not
// exist on the class — so a host app's respondsToSelector: returns NO for the correct reason. No
// interposition, no swizzling and no gating: the cost is a one-time selref scan per WebKit image, plus
// one pass over each image's classes to give a class that HAS the real method its own private-selector
// entry point (see wk_alias_class). Runs in every process WebKit loads into.
//
// A "WebKit image" is any binary carrying __DATA,__wk_marker, injected by wk_image_marker.c which is
// force-loaded into every WebKit framework (WEBKIT_FRAMEWORK). This object (the patcher + registry) and
// polyfills/methods/ (the blocks) are force-loaded into WebCore only — they load early in every
// rendering process and keep the AppKit categories out of the setuid-JSC path; polyfills/webkit/ holds
// the blocks that belong to WebKit.framework. THE POLYFILLS THEMSELVES LIVE THERE; add new ones there.

#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach-o/getsect.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <sys/mman.h>
#import <sys/syscall.h>
#import <unistd.h>

// A registry that cannot record an entry has no degraded mode. The polyfill is already compiled in and
// WebKit's selrefs are already pointing at it, so a dropped entry does not fall back to anything --
// the public selector simply stays unrewritten or the wk_ method never gets added to its class, and
// the first send dies with an unrecognized selector at whatever call site happens to run first,
// arbitrarily far from the load-time cause. Say what happened here instead.
static void wk_registry_full(const char *what, int cap, const char *capName, const char *dropped)
{
    fprintf(stderr, "[wk_selref_scope] FATAL: more than %d (%s) %s; \"%s\" cannot be recorded.\n"
                    "[wk_selref_scope] The registry is what points WebKit's rewritten selectors at the "
                    "polyfills, so anything past the cap would be dropped and would surface much later "
                    "as an unrecognized selector at an unrelated call site. Raise %s in "
                    "AquaWebKitSupport/polyfill/mechanism/wk_selref_scope.m.\n",
            cap, capName, what, dropped, capName);
    fflush(stderr);
    abort();
}

// Resolved public->private SEL map, built from every block's method list as the blocks' image arrives.
enum { WK_MAX_SEL = 512 };
static SEL wk_pub[WK_MAX_SEL];          // canonical public SEL (fast-path pointer match)
static const char *wk_pubname[WK_MAX_SEL]; // public selector NAME (content match — see wk_patch)
static SEL wk_priv[WK_MAX_SEL];
static int wk_count;                    // PUBLICATION POINT — see the synchronisation note below

// The bodies of every REPLACE block. wk_alias_class asks whether the private selector a class's chain
// answers is one of these (a deliberate shadow that must stay in front of the class's own method), and
// wk_original_of finds which class in a receiver's chain carries the body that is running.
enum { WK_MAX_REPLACE_BODIES = 128 };
static IMP wk_replace_body[WK_MAX_REPLACE_BODIES];
static int wk_replace_body_count;
// Whether registry entry j has a REPLACE body, which only a REPLACE block registering it installs. A chain
// can carry a body for that entry's private selector only then. Written and read under wk_reg_lock.
static bool wk_replace_sel[WK_MAX_SEL];

// Prefilters over the registry, so the two hot loops (every selref of every WebKit image in wk_patch,
// every method of every class in wk_alias_class) pay one bit test for the overwhelmingly common case
// of a name that is not registered, instead of a registry lookup.
//
// The guarantee is one-sided: a clear bit means NO entry has this name/SEL, so skipping is safe; a set
// bit means only "look it up in the registry", which stays the sole authority. Bits are set before the entry is
// published through wk_count (release-store), so any reader that can reach an entry can also see its
// bits — the same happens-before edge the arrays rely on. The reverse order would be a correctness
// bug: a reachable entry whose bit is not yet visible would be skipped. A bit set for an entry the
// reader cannot reach yet merely sends it into a lookup that finds nothing, which is what no filter
// would have done anyway. Bits are only ever set, never cleared, matching the append-only registry.
enum { WK_FILTER_BITS = 16384 };
static unsigned char wk_name_filter[WK_FILTER_BITS / 8];   // keyed on the selector NAME
static unsigned char wk_sel_filter[WK_FILTER_BITS / 8];    // keyed on the canonical SEL

static unsigned wk_name_hash32(const char *s)
{
    unsigned h = 5381;   // djb2
    while (*s)
        h = h * 33 ^ (unsigned char)*s++;
    return h;
}

static unsigned wk_name_hash(const char *s)
{
    return wk_name_hash32(s) & (WK_FILTER_BITS - 1);
}

// Every SEL hashed here is canonical: sel_registerName on the writer side, and on the reader side a
// realized method's name, a shared-cache method-list name or a uniqued selref. So hashing the pointer
// is sound. The low 4 bits carry no entropy (allocation alignment); fold in higher bits instead.
static unsigned wk_sel_hash(SEL sel)
{
    uintptr_t p = (uintptr_t)(const void *)sel;
    return (unsigned)((p >> 4) ^ (p >> 15)) & (WK_FILTER_BITS - 1);
}

#define WK_FILTER_SET(f, h)  ((f)[(h) >> 3] |= (unsigned char)(1u << ((h) & 7)))
#define WK_FILTER_TEST(f, h) ((f)[(h) >> 3] & (1u << ((h) & 7)))

// The registered public names, exactly: registry index + 1 by name hash, or 0 for an empty slot. The alias
// sweep looks up a name that passes wk_name_filter here under wk_reg_lock, for method lists the runtime has
// not realized, and wk_patch looks up selrefs without the lock. Slots are filled like the registry's
// arrays, before the entry is published through wk_count, so a reader skips an index at or above the
// count it acquire-loaded.
enum { WK_NAME_SLOTS = 2 * WK_MAX_SEL };   // power of two
static int wk_name_slots[WK_NAME_SLOTS];

static void wk_note_registered_name(const char *name, int index)
{
    unsigned i = wk_name_hash32(name) & (WK_NAME_SLOTS - 1);
    while (__atomic_load_n(&wk_name_slots[i], __ATOMIC_RELAXED))
        i = (i + 1) & (WK_NAME_SLOTS - 1);
    __atomic_store_n(&wk_name_slots[i], index + 1, __ATOMIC_RELAXED);
}

// The registry index of `name` among the first `count` entries, or -1. `hash` is wk_name_hash32(name).
static int wk_registered_name_index(const char *name, unsigned hash, int count)
{
    for (unsigned i = hash & (WK_NAME_SLOTS - 1);; i = (i + 1) & (WK_NAME_SLOTS - 1)) {
        int entry = __atomic_load_n(&wk_name_slots[i], __ATOMIC_RELAXED);
        if (!entry)
            return -1;
        int j = entry - 1;
        if (j < count && (name == wk_pubname[j] || !strcmp(name, wk_pubname[j])))
            return j;
    }
}

static bool wk_is_registered_name(const char *name)
{
    unsigned hash = wk_name_hash32(name);
    if (!WK_FILTER_TEST(wk_name_filter, hash & (WK_FILTER_BITS - 1)))
        return false;
    return wk_registered_name_index(name, hash, wk_count) >= 0;
}

// The registered public SELs, exactly: registry index + 1 by SEL hash, or 0 for an empty slot. Method
// lists of shared-cache images store their names as the canonical SEL pointers (10.9's dyld preoptimizes
// them, and sel_registerName answers the same pointer for any name the cache holds), and so do the
// selrefs of an image the runtime has read, so comparing pointers there reads no name strings, which
// would otherwise be paged in from every framework in the process. Filled and read like wk_name_slots.
static int wk_sel_slots[WK_NAME_SLOTS];

static void wk_note_registered_sel(SEL sel, int index)
{
    unsigned i = wk_sel_hash(sel) & (WK_NAME_SLOTS - 1);
    while (__atomic_load_n(&wk_sel_slots[i], __ATOMIC_RELAXED))
        i = (i + 1) & (WK_NAME_SLOTS - 1);
    __atomic_store_n(&wk_sel_slots[i], index + 1, __ATOMIC_RELAXED);
}

// The registry index of `sel` among the first `count` entries, or -1.
static int wk_registered_sel_index(SEL sel, int count)
{
    for (unsigned i = wk_sel_hash(sel) & (WK_NAME_SLOTS - 1);; i = (i + 1) & (WK_NAME_SLOTS - 1)) {
        int entry = __atomic_load_n(&wk_sel_slots[i], __ATOMIC_RELAXED);
        if (!entry)
            return -1;
        if (entry - 1 < count && wk_pub[entry - 1] == sel)
            return entry - 1;
    }
}

static bool wk_is_registered_sel(SEL sel)
{
    if (!WK_FILTER_TEST(wk_sel_filter, wk_sel_hash(sel)))
        return false;
    return wk_registered_sel_index(sel, wk_count) >= 0;
}

// Synchronisation.
//
// Writers (wk_collect, wk_install_deferred) run from the constructor AND from the dyld image-state
// handler, which fires on whichever thread called dlopen, at any point in the process's life. wk_patch
// reads the registry from the add-image callback without the lock, so two concurrent dlopens can have
// one publishing entries while the other reads them.
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
static long wk_stat_classes, wk_stat_realized, wk_stat_methods;
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
// Class-correct aliasing: a class that HAS the real method also answers the private selector.
//
// The rewrite is by NAME: every `foo` selref in a WebKit image becomes `wk_foo`, and a selref carries
// no class. That is exactly right when WebKit sends `foo` to the one class whose `foo` is missing on
// 10.9, but some names go to several classes (`valueForHTTPHeaderField:` to NSHTTPURLResponse, which
// lacks it here, and to NSURLRequest, which has it). A class that DOES have the real method would
// otherwise be sent a `wk_foo` it does not implement -> unrecognized selector.
//
// So as each image arrives, every class of that image that implements a registered public selector
// ITSELF gets an alias under the private name, with the public method's type encoding: a stub that sends
// on as the public selector would (see "Alias trampolines" below). Declaring a method polyfill therefore
// does not require knowing which other classes share the name — it is correct by construction for every
// class, including ones nobody thought to list. A category in an image loaded later that gives an
// already-swept class a registered selector has that class aliased again (wk_alias_category_targets).
//
// Nothing is ever added under a PUBLIC selector: the only method installed anywhere is wk_<name>, which
// nothing outside WebKit's rewritten images ever sends. A host app's respondsToSelector: for the public
// name keeps answering exactly what the class really says, and no NSObject resolver is involved.
//
// The class's OWN methods (class_copyMethodList), not class_getInstanceMethod: an inherited method is
// aliased on the class that defines it and subclasses inherit the alias along with it, and
// class_getInstanceMethod consults the resolver, so asking it would send +resolveInstanceMethod: to every
// class in the process for every selector the class does not have. Pass a metaclass to alias class
// methods.
//
// On an ADD block's target the body is installed first, so the alias is never added there and the body
// keeps serving WebKit's rewritten call. A DIFFERENT class that merely shares the selector name has no
// wk_<name> of its own, so it gets an alias reaching its real method (the by-name selref rewrite must not
// hijack another class's method). If an ADD target turns out to implement the public selector after all,
// the body shadows 10.9's — the same mistake as a shadowing C gap-fill.
//
// INTENT DECIDES WHAT HAPPENS TO A SUBCLASS OF THE TARGET. An alias on a class puts that class's own
// method in FRONT of an inherited body, because the class's own method list is searched first.
// For an ADD that is right: 10.9 has no such method, so any class carrying the name is an unrelated
// class whose real method the by-name rewrite must not hijack. For a REPLACE it inverts the polyfill —
// the body exists precisely to shadow a method 10.9 HAS, and the classes most likely to implement that
// method are the target's own subclasses. Aliasing there hands the subclass back its own method and the
// body never runs. Measured on 10.9.5: -[NSPanel initWithContentRect:styleMask:backing:defer:],
// -[NSSavePanel initWithContentRect:…], -[_NSPopoverWindow initWithContentRect:…] / -setContentView:,
// -[NSCarbonWindow setStyleMask:] all shadow their NSWindow polyfill this way, and NSURL's
// initWithString: replacement is written for an NSURL SUBCLASS (isMemberOfClass: test).
//
// So a class whose chain already answers the private selector with a REPLACE body is NOT aliased: the
// body keeps serving the rewritten call on every such subclass and calls through to that subclass's
// own implementation. An UNRELATED class (no body in its chain: -[NSScrollView setContentView:],
// -[NSBox setContentView:]) is aliased.
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
// The chain test is only meaningful because the body is already installed when this runs: wk_collect
// installs every block whose targets are loaded before it aliases, and wk_image_initializing drains the
// deferred blocks before it aliases the arriving image.
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

// Published like the registry: bodies are appended under wk_reg_lock and the count release-stored, so
// a reader on any thread (wk_original_of) that sees index i sees body i.
static bool wk_is_replace_body(IMP imp)
{
    int count = __atomic_load_n(&wk_replace_body_count, __ATOMIC_ACQUIRE);
    for (int i = 0; i < count; i++)
        if (wk_replace_body[i] == imp)
            return true;
    return false;
}

// The first class up `cls`'s chain whose OWN private-selector implementation is a REPLACE body, or Nil.
// A class between it and `cls` may own the private selector too — a WebKit-image override aliased by
// wk_alias_class — and is walked past.
static Class wk_replace_body_owner(Class cls, SEL priv)
{
    for (Class c = cls; c; c = class_getSuperclass(c))
        if (wk_is_replace_body(wk_own_imp(c, priv)))
            return c;
    return Nil;
}

// THE CALL-THROUGH FOR A REPLACE BODY (WK_ORIGINAL_METHOD). Every REPLACE body needs to run "the
// implementation I stand in for", and the naive spelling — send the PUBLIC selector to self — is wrong,
// because it re-resolves from the TOP of the receiver's chain. If any class between the receiver and the
// body overrides the public selector in a WebKit image, that override runs again, its [super …]
// (rewritten to wk_) lands back in the body, and it recurses without bound.
//
// The question is not "what would the receiver do", it is "what is one level below ME". So the answer is
// derived from the BODY's class — the first class up the receiver's chain whose own private-selector
// implementation is a REPLACE body:
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
// which classes exist. Each chain carries one REPLACE body per selector, which is what makes "the first
// body up the chain" the running one.
//
// The implementation itself comes from the runtime on every call (class_getMethodImplementation from the
// class found above), so a method another library exchanges or adds after the first call is the one that
// runs; the search never ends without one, since the body's class chain implements the public selector,
// so the runtime's resolver is never consulted.
//
// Memo over the search. Which class to look the public selector up from is a pure function of (receiver's
// class, private selector) between our method installations: the registry is append-only and an installed
// body never moves, so an entry only goes stale when an image-load event installs methods (wk_alias_class /
// wk_install_side), each of which bumps the generation. WK_ORIGINAL_METHOD runs on hot paths — every NSURL
// construction and every request stamp goes through a REPLACE body — and the search costs several
// class_copyMethodList allocations, so the memo is what keeps a call-through at one hash probe and one
// runtime cache lookup. Per-entry seqlock, no lock on the read path; a writer that loses the claim simply
// doesn't cache, and the search it already ran supplies its answer.
enum { WK_ORIG_MEMO_SLOTS = 256 };   // power of two
struct wk_orig_memo {
    uint32_t seq;        // odd while a writer is mid-update
    uint32_t gen;
    Class cls;
    SEL priv;
    Class lookupClass;
    SEL pub;
};
static struct wk_orig_memo wk_orig_memo[WK_ORIG_MEMO_SLOTS];
// Read by the alias entries' cache check as well (see wk_alias_entry).
uint32_t wk_install_generation __attribute__((visibility("hidden"))) = 1;

static unsigned wk_orig_memo_slot(Class cls, SEL priv)
{
    uintptr_t a = (uintptr_t)cls, b = (uintptr_t)(const void *)priv;
    return (unsigned)(((a >> 4) ^ (a >> 12) ^ (b >> 4)) & (WK_ORIG_MEMO_SLOTS - 1));
}

struct wk_original wk_original_of(id receiver, SEL privateSelector)
{
    Class start = object_getClass(receiver);
    uint32_t generation = __atomic_load_n(&wk_install_generation, __ATOMIC_ACQUIRE);
    struct wk_orig_memo *memo = &wk_orig_memo[wk_orig_memo_slot(start, privateSelector)];
    uint32_t seq = __atomic_load_n(&memo->seq, __ATOMIC_ACQUIRE);
    if (!(seq & 1) && memo->cls == start && memo->priv == privateSelector && memo->gen == generation) {
        Class lookupClass = memo->lookupClass;
        SEL cachedPub = memo->pub;
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&memo->seq, __ATOMIC_ACQUIRE) == seq) {
            struct wk_original cached = { class_getMethodImplementation(lookupClass, cachedPub), cachedPub };
            return cached;
        }
    }

    SEL pub = NULL;
    int count = __atomic_load_n(&wk_count, __ATOMIC_ACQUIRE);
    for (int j = 0; j < count && !pub; j++)
        if (wk_priv[j] == privateSelector)
            pub = wk_pub[j];
    Class bodyClass = pub ? wk_replace_body_owner(start, privateSelector) : Nil;
    if (!bodyClass) {
        fprintf(stderr, "[wk_selref_scope] FATAL: WK_ORIGINAL_METHOD called for %s on %s, which is not a "
                        "REPLACE body's selector on this receiver's chain.\n",
                sel_getName(privateSelector), class_getName(start));
        fflush(stderr);
        abort();
    }

    Class overrideOwner = Nil;
    for (Class c = start; c && c != bodyClass; c = class_getSuperclass(c))
        if (wk_own_imp(c, privateSelector))
            overrideOwner = c;   // keep the LAST, which is the one closest to bodyClass

    Class lookupClass = overrideOwner ? class_getSuperclass(overrideOwner) : start;

    uint32_t current = __atomic_load_n(&memo->seq, __ATOMIC_RELAXED);
    if (!(current & 1) && __atomic_compare_exchange_n(&memo->seq, &current, current + 1, false,
                                                      __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        memo->cls = start;
        memo->priv = privateSelector;
        memo->lookupClass = lookupClass;
        memo->pub = pub;
        memo->gen = generation;
        __atomic_store_n(&memo->seq, current + 2, __ATOMIC_RELEASE);
    }

    struct wk_original original = { class_getMethodImplementation(lookupClass, pub), pub };
    return original;
}

static bool wk_is_placeholder(Class cls)
{
    return strncmp(class_getName(cls), "WKPolyfill_", 11) == 0;
}

// ---------------------------------------------------------------------------------------------
// Alias trampolines.
//
// A rewritten send that reaches an alias has to do what the public send would: run whatever the receiver's
// class answers for the public selector at that moment — an override in a class the runtime created below
// the alias's class (KVO's notifying subclasses), a method another library exchanged or added since, the
// forwarding machinery — with the public selector as _cmd. So an alias is a stub carrying (class, public
// SEL, private SEL), and what it decides and remembers is structural only, never an implementation.
//
// The rule is wk_original_of's, with the alias's class in place of the body's class. When a class strictly
// below it in the receiver's chain owns the private selector, the send can only be that class's
// implementation reaching up through [super wk_foo]: the answer is the runtime's implementation of the
// public selector from that class's superclass, looked up per call. Otherwise it is an ordinary send, and
// the stub hands the public selector to objc_msgSend (objc_msgSend_stret), so the runtime's own method
// cache, which the runtime flushes itself, does the rest.
//
// Each alias also remembers, for one receiver class (seq, gen, cls under a seqlock), that a send from it is
// an ordinary one, which the entry checks before saving any register. The entry reads pub and priv at
// offsets 8 and 16 and that record at offsets 24-32.
struct wk_alias_context {
    Class owner;
    SEL pub;
    SEL priv;
    uint32_t seq;        // odd while a writer is mid-update
    uint32_t gen;
    Class cls;
};

// The class closest to the alias's class, strictly below it in `start`'s chain, that owns the private
// selector, or Nil.
static Class wk_alias_override_owner(Class start, const struct wk_alias_context *context)
{
    Class overrideOwner = Nil;
    for (Class c = start; c && c != context->owner; c = class_getSuperclass(c))
        if (wk_own_imp(c, context->priv))
            overrideOwner = c;   // keep the LAST, which is the one closest to the alias's class
    return overrideOwner;
}

// Memo over wk_alias_override_owner, keyed by (receiver's class, alias) and invalidated by the same install
// generation as wk_original_of's: per-entry seqlock, no lock on the read path.
enum { WK_ALIAS_MEMO_SLOTS = 2048 };   // power of two
struct wk_alias_memo {
    uint32_t seq;        // odd while a writer is mid-update
    uint32_t gen;
    Class cls;
    const struct wk_alias_context *context;
    Class overrideOwner;
};
static struct wk_alias_memo wk_alias_memo[WK_ALIAS_MEMO_SLOTS];

static Class wk_alias_memoized_override_owner(Class start, const struct wk_alias_context *context, uint32_t generation)
{
    uintptr_t a = (uintptr_t)start, b = (uintptr_t)context;
    struct wk_alias_memo *memo = &wk_alias_memo[((a >> 4) ^ (a >> 13) ^ (b >> 4) ^ (b >> 11)) & (WK_ALIAS_MEMO_SLOTS - 1)];
    uint32_t seq = __atomic_load_n(&memo->seq, __ATOMIC_ACQUIRE);
    if (!(seq & 1) && memo->cls == start && memo->context == context && memo->gen == generation) {
        Class cached = memo->overrideOwner;
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&memo->seq, __ATOMIC_ACQUIRE) == seq)
            return cached;
    }

    Class overrideOwner = wk_alias_override_owner(start, context);

    uint32_t current = __atomic_load_n(&memo->seq, __ATOMIC_RELAXED);
    if (!(current & 1) && __atomic_compare_exchange_n(&memo->seq, &current, current + 1, false,
                                                      __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        memo->cls = start;
        memo->context = context;
        memo->overrideOwner = overrideOwner;
        memo->gen = generation;
        __atomic_store_n(&memo->seq, current + 2, __ATOMIC_RELEASE);
    }
    return overrideOwner;
}

static void wk_alias_note_ordinary(struct wk_alias_context *context, Class cls, uint32_t generation)
{
    uint32_t current = __atomic_load_n(&context->seq, __ATOMIC_RELAXED);
    if ((current & 1) || !__atomic_compare_exchange_n(&context->seq, &current, current + 1, false,
                                                      __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
    context->cls = cls;
    context->gen = generation;
    __atomic_store_n(&context->seq, current + 2, __ATOMIC_RELEASE);
}

// Where the entry jumps, with the public selector as _cmd: objc_msgSend (objc_msgSend_stret when the result
// travels through a hidden pointer) for an ordinary send, the runtime's implementation above the override
// for a super send.
IMP wk_alias_resolve(id receiver, struct wk_alias_context *context, long stret) __attribute__((used, visibility("hidden")));
IMP wk_alias_resolve(id receiver, struct wk_alias_context *context, long stret)
{
    Class start = object_getClass(receiver);
    uint32_t generation = __atomic_load_n(&wk_install_generation, __ATOMIC_ACQUIRE);
    Class overrideOwner = wk_alias_memoized_override_owner(start, context, generation);
    if (!overrideOwner) {
        wk_alias_note_ordinary(context, start, generation);
        return stret ? (IMP)objc_msgSend_stret : (IMP)objc_msgSend;
    }
    Class lookupClass = class_getSuperclass(overrideOwner);
    return stret ? class_getMethodImplementation_stret(lookupClass, context->pub)
                 : class_getMethodImplementation(lookupClass, context->pub);
}

// The shared entry. A stub arrives with its context in r11. The sender passed self in rdi and _cmd in rsi,
// or, for a method returning its result through a hidden pointer, the result's address in rdi, self in rsi
// and _cmd in rdx; _cmd is always the alias's private selector, which an object pointer never equals, so
// the register holding it tells the two apart. Each path first checks whether this receiver's class is the
// one the alias last found sending ordinarily, using only r10, r11 and a saved rax (x86-64 keeps loads in
// order, so the seqlock read needs no fence); a tagged pointer, whose class is not its first word, always
// resolves. A resolve keeps every register an argument can travel in (rax carries a variadic call's
// vector-register count).
void wk_alias_entry(void);
#define WK_ALIAS_ENTRY_ORDINARY(SELF, SELF8, CMD, SEND, MISS) \
    "    testb $1, " SELF8 "\n"                     \
    "    jnz " MISS "\n"                            \
    "    pushq %rax\n"                              \
    "    movl 24(%r11), %eax\n"                     \
    "    testl $1, %eax\n"                          \
    "    jnz 1f\n"                                  \
    "    movq (" SELF "), %r10\n"                   \
    "    cmpq 32(%r11), %r10\n"                     \
    "    jne 1f\n"                                  \
    "    movl 28(%r11), %r10d\n"                    \
    "    cmpl _wk_install_generation(%rip), %r10d\n" \
    "    jne 1f\n"                                  \
    "    cmpl 24(%r11), %eax\n"                     \
    "    jne 1f\n"                                  \
    "    popq %rax\n"                               \
    "    movq 8(%r11), " CMD "\n"                   \
    "    jmpq *" SEND "@GOTPCREL(%rip)\n"           \
    "1:  popq %rax\n"
#define WK_ALIAS_ENTRY_SAVE                         \
    "    pushq %rbp\n"                              \
    "    movq %rsp, %rbp\n"                         \
    "    subq $0xd0, %rsp\n"                        \
    "    movq %rdi, 0x00(%rsp)\n"                   \
    "    movq %rsi, 0x08(%rsp)\n"                   \
    "    movq %rdx, 0x10(%rsp)\n"                   \
    "    movq %rcx, 0x18(%rsp)\n"                   \
    "    movq %r8, 0x20(%rsp)\n"                    \
    "    movq %r9, 0x28(%rsp)\n"                    \
    "    movq %rax, 0x30(%rsp)\n"                   \
    "    movq %r11, 0x38(%rsp)\n"                   \
    "    movdqa %xmm0, 0x40(%rsp)\n"                \
    "    movdqa %xmm1, 0x50(%rsp)\n"                \
    "    movdqa %xmm2, 0x60(%rsp)\n"                \
    "    movdqa %xmm3, 0x70(%rsp)\n"                \
    "    movdqa %xmm4, 0x80(%rsp)\n"                \
    "    movdqa %xmm5, 0x90(%rsp)\n"                \
    "    movdqa %xmm6, 0xa0(%rsp)\n"                \
    "    movdqa %xmm7, 0xb0(%rsp)\n"
#define WK_ALIAS_ENTRY_RESTORE                      \
    "    movq %rax, %r10\n"                         \
    "    movq 0x00(%rsp), %rdi\n"                   \
    "    movq 0x08(%rsp), %rsi\n"                   \
    "    movq 0x10(%rsp), %rdx\n"                   \
    "    movq 0x18(%rsp), %rcx\n"                   \
    "    movq 0x20(%rsp), %r8\n"                    \
    "    movq 0x28(%rsp), %r9\n"                    \
    "    movq 0x30(%rsp), %rax\n"                   \
    "    movq 0x38(%rsp), %r11\n"                   \
    "    movdqa 0x40(%rsp), %xmm0\n"                \
    "    movdqa 0x50(%rsp), %xmm1\n"                \
    "    movdqa 0x60(%rsp), %xmm2\n"                \
    "    movdqa 0x70(%rsp), %xmm3\n"                \
    "    movdqa 0x80(%rsp), %xmm4\n"                \
    "    movdqa 0x90(%rsp), %xmm5\n"                \
    "    movdqa 0xa0(%rsp), %xmm6\n"                \
    "    movdqa 0xb0(%rsp), %xmm7\n"
__asm__(
    "    .text\n"
    "    .private_extern _wk_alias_entry\n"
    "    .globl _wk_alias_entry\n"
    "    .p2align 4\n"
    "_wk_alias_entry:\n"
    "    cmpq 16(%r11), %rsi\n"
    "    jne 3f\n"
    WK_ALIAS_ENTRY_ORDINARY("%rdi", "%dil", "%rsi", "_objc_msgSend", "2f")
    "2:\n"
    WK_ALIAS_ENTRY_SAVE
    "    movq %r11, %rsi\n"
    "    xorl %edx, %edx\n"
    "    callq _wk_alias_resolve\n"
    WK_ALIAS_ENTRY_RESTORE
    "    movq 8(%r11), %rsi\n"
    "    leave\n"
    "    jmpq *%r10\n"
    "3:\n"
    WK_ALIAS_ENTRY_ORDINARY("%rsi", "%sil", "%rdx", "_objc_msgSend_stret", "4f")
    "4:\n"
    WK_ALIAS_ENTRY_SAVE
    "    movq %rsi, %rdi\n"
    "    movq %r11, %rsi\n"
    "    movl $1, %edx\n"
    "    callq _wk_alias_resolve\n"
    WK_ALIAS_ENTRY_RESTORE
    "    movq 8(%r11), %rdx\n"
    "    leave\n"
    "    jmpq *%r10\n");

// Stubs: movabs r11, context; movabs r10, entry; jmp r10. A sweep writes its stubs into pages that are
// writable and not executable, then makes those pages executable and not writable before installing any
// of them (wk_alias_install_pending), and never writes to them again; the next sweep starts a new page.
// Stubs and contexts live as long as the class they are installed on, which for a class carrying ObjC
// metadata is the process. Everything here runs under wk_reg_lock.
enum { WK_ALIAS_STUB_SIZE = 32, WK_ALIAS_STUB_PAGE = 4096 };
static uint8_t *wk_alias_stub_page;               // the page being written, or NULL
static size_t wk_alias_stub_used;
static uint8_t **wk_alias_unsealed_pages;
static size_t wk_alias_unsealed_count, wk_alias_unsealed_capacity;

struct wk_pending_alias {
    Class cls;
    SEL priv;
    IMP stub;
    const char *types;
};
static struct wk_pending_alias *wk_pending_aliases;
static size_t wk_pending_alias_count, wk_pending_alias_capacity;

static void *wk_grow(void *array, size_t *capacity, size_t elementSize)
{
    size_t newCapacity = *capacity ? *capacity * 2 : 64;
    void *grown = realloc(array, newCapacity * elementSize);
    if (!grown)
        abort();
    *capacity = newCapacity;
    return grown;
}

static IMP wk_alias_stub(Class owner, int j)
{
    struct wk_alias_context *context = calloc(1, sizeof(*context));
    if (!context)
        abort();
    context->owner = owner;
    context->pub = wk_pub[j];
    context->priv = wk_priv[j];

    if (!wk_alias_stub_page || wk_alias_stub_used + WK_ALIAS_STUB_SIZE > WK_ALIAS_STUB_PAGE) {
        void *page = mmap(NULL, WK_ALIAS_STUB_PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (page == MAP_FAILED) {
            fprintf(stderr, "[wk_selref_scope] FATAL: cannot map memory for alias stubs (errno %d).\n", errno);
            fflush(stderr);
            abort();
        }
        if (wk_alias_unsealed_count == wk_alias_unsealed_capacity)
            wk_alias_unsealed_pages = wk_grow(wk_alias_unsealed_pages, &wk_alias_unsealed_capacity, sizeof(*wk_alias_unsealed_pages));
        wk_alias_unsealed_pages[wk_alias_unsealed_count++] = page;
        wk_alias_stub_page = page;
        wk_alias_stub_used = 0;
    }
    uint8_t *stub = wk_alias_stub_page + wk_alias_stub_used;
    wk_alias_stub_used += WK_ALIAS_STUB_SIZE;

    void *entry = (void *)wk_alias_entry;
    stub[0] = 0x49;
    stub[1] = 0xbb;
    memcpy(stub + 2, &context, 8);
    stub[10] = 0x49;
    stub[11] = 0xba;
    memcpy(stub + 12, &entry, 8);
    stub[20] = 0x41;
    stub[21] = 0xff;
    stub[22] = 0xe2;
    memset(stub + 23, 0xcc, WK_ALIAS_STUB_SIZE - 23);
    return (IMP)(void *)stub;
}

static void wk_alias_add_pending(Class cls, SEL priv, IMP stub, const char *types)
{
    if (wk_pending_alias_count == wk_pending_alias_capacity)
        wk_pending_aliases = wk_grow(wk_pending_aliases, &wk_pending_alias_capacity, sizeof(*wk_pending_aliases));
    wk_pending_aliases[wk_pending_alias_count++] = (struct wk_pending_alias) { cls, priv, stub, types };
}

static bool wk_alias_is_pending(Class cls, SEL priv)
{
    for (size_t k = 0; k < wk_pending_alias_count; k++)
        if (wk_pending_aliases[k].cls == cls && wk_pending_aliases[k].priv == priv)
            return true;
    return false;
}

// Makes the sweep's stub pages executable and installs its aliases.
static void wk_alias_install_pending(void)
{
    if (!wk_pending_alias_count)
        return;
    for (size_t k = 0; k < wk_alias_unsealed_count; k++) {
        if (mprotect(wk_alias_unsealed_pages[k], WK_ALIAS_STUB_PAGE, PROT_READ | PROT_EXEC)) {
            fprintf(stderr, "[wk_selref_scope] FATAL: cannot make alias stubs executable (errno %d).\n", errno);
            fflush(stderr);
            abort();
        }
    }
    wk_alias_unsealed_count = 0;
    wk_alias_stub_page = NULL;
    for (size_t k = 0; k < wk_pending_alias_count; k++)
        class_addMethod(wk_pending_aliases[k].cls, wk_pending_aliases[k].priv, wk_pending_aliases[k].stub, wk_pending_aliases[k].types);
    wk_pending_alias_count = 0;
    // Invalidates the memos: these classes' chains answer differently now.
    __atomic_fetch_add(&wk_install_generation, 1, __ATOMIC_RELEASE);
}

// Whether a class's own method list already carries a method named `sel`.
static bool wk_method_list_has(Method *methods, unsigned int n, SEL sel)
{
    for (unsigned int k = 0; k < n; k++)
        if (method_getName(methods[k]) == sel)
            return true;
    return false;
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
            // A block defines the public selector by construction; its bodies are installed on the
            // targets, and the block itself receives no sends.
            if (wk_is_placeholder(cls))
                break;
            if (!clsFromWebKitImage && wk_replace_sel[j] && wk_replace_body_owner(cls, wk_priv[j]))
                break;   // a REPLACE body is already in this class's chain — let it win (see above)
            if (!wk_method_list_has(methods, n, wk_priv[j]) && !wk_alias_is_pending(cls, wk_priv[j]))
                wk_alias_add_pending(cls, wk_priv[j], wk_alias_stub(cls, j), method_getTypeEncoding(methods[i]));
            break;
        }
    }
    free(methods);
}

// A WebKit image is one carrying __DATA,__wk_marker — the same test wk_patch uses to decide whose
// selrefs to rewrite, which is exactly the property wk_alias_class needs: an image whose sends are
// rewritten is one whose [super …] sends are rewritten.
static bool wk_is_webkit_image(const struct mach_header *mh)
{
    unsigned long size = 0;
    return mh && getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__wk_marker", &size) != NULL;
}

// The ObjC 2 metadata the compiler emits for a class, a category and a method list, as 10.9's runtime
// (objc4-551) reads it out of __DATA,__objc_classlist and __objc_catlist. Until the runtime realizes a
// class, the class's data word points at its read-only class_ro_t; realizing allocates a class_rw_t,
// sets RW_REALIZED in its flags (a bit the compiler never sets in class_ro_t's), and attaches the
// methods of every loaded category on the class.
struct wk_raw_method {
    const char *name;
    const char *types;
    IMP imp;
};

struct wk_raw_method_list {
    uint32_t entsizeAndFlags;
    uint32_t count;
    struct wk_raw_method first;
};

struct wk_raw_class_ro {
    uint32_t flags;
    uint32_t instanceStart;
    uint32_t instanceSize;
    uint32_t reserved;
    const uint8_t *ivarLayout;
    const char *name;
    const struct wk_raw_method_list *baseMethods;
};

struct wk_raw_class {
    struct wk_raw_class *isa;
    struct wk_raw_class *superclass;
    void *cache;
    void *vtable;
    uintptr_t data;
};

struct wk_raw_category {
    const char *name;
    struct wk_raw_class *cls;
    const struct wk_raw_method_list *instanceMethods;
    const struct wk_raw_method_list *classMethods;
};

enum { WK_RW_REALIZED = 1u << 31 };

// The class_ro_t of a class the runtime has not realized; NULL once it has.
static const struct wk_raw_class_ro *wk_unrealized_ro(const struct wk_raw_class *cls)
{
    uintptr_t data = __atomic_load_n(&cls->data, __ATOMIC_ACQUIRE) & ~(uintptr_t)3;
    const struct wk_raw_class_ro *ro = (const struct wk_raw_class_ro *)data;
    return (ro->flags & WK_RW_REALIZED) ? NULL : ro;
}

// The address range of the dyld shared cache this process maps, from the cache's own header: the start
// the kernel reports for the shared region plus the extent of the cache's mappings. Images inside it are
// the ones whose method names are canonical SELs (see wk_sel_slots). Empty when no cache is mapped.
struct wk_cache_header {
    char magic[16];
    uint32_t mappingOffset;
    uint32_t mappingCount;
};

struct wk_cache_mapping {
    uint64_t address;
    uint64_t size;
    uint64_t fileOffset;
    uint32_t maxProt;
    uint32_t initProt;
};

static uintptr_t wk_cache_start, wk_cache_end;

static void wk_note_shared_cache_range(void)
{
    uint64_t start = 0;
    if (syscall(SYS_shared_region_check_np, &start) != 0 || !start)
        return;
    const struct wk_cache_header *header = (const struct wk_cache_header *)(uintptr_t)start;
    const struct wk_cache_mapping *mappings =
        (const struct wk_cache_mapping *)((const char *)header + header->mappingOffset);
    uint64_t slide = start - mappings[0].address;
    uint64_t end = 0;
    for (uint32_t i = 0; i < header->mappingCount; i++)
        if (mappings[i].address + mappings[i].size > end)
            end = mappings[i].address + mappings[i].size;
    wk_cache_start = (uintptr_t)start;
    wk_cache_end = (uintptr_t)(end + slide);
}

static bool wk_is_shared_cache_image(const struct mach_header *mh)
{
    return (uintptr_t)mh >= wk_cache_start && (uintptr_t)mh < wk_cache_end;
}

// Whether a method list names a registered public selector. Method names are C strings whether or not
// the runtime has uniqued them yet; a shared-cache image's are canonical SELs and are compared as such.
static bool wk_raw_list_may_register(const struct wk_raw_method_list *list, bool canonicalNames)
{
    if (!list)
        return false;
    uint32_t entsize = list->entsizeAndFlags & ~3u;
    const char *entry = (const char *)&list->first;
    for (uint32_t i = 0; i < list->count; i++, entry += entsize) {
        const char *name = ((const struct wk_raw_method *)entry)->name;
        if (canonicalNames ? wk_is_registered_sel((SEL)name) : wk_is_registered_name(name))
            return true;
    }
    return false;
}

// The classes some loaded category gives a method that names a registered selector, so realizing them
// would attach it. Recorded when an image is bound, ahead of the dependents_initialized notification of
// every image in its batch: a category in one image routinely targets a class from an image that batch
// initializes first. Rebuilt from every loaded image when the registry grows, since an earlier scan
// tested names against fewer filter bits. Guarded by wk_reg_lock; entries point into images that carry
// ObjC metadata, which the runtime never unloads.
static const struct wk_raw_class **wk_category_targets;
static size_t wk_category_target_capacity;   // power of two, or 0
static size_t wk_category_target_count;

static size_t wk_category_target_slot(const struct wk_raw_class *cls)
{
    uintptr_t p = (uintptr_t)cls;
    return (size_t)(((p >> 4) ^ (p >> 13)) & (wk_category_target_capacity - 1));
}

static bool wk_is_category_target(const struct wk_raw_class *cls)
{
    if (!wk_category_target_count)
        return false;
    for (size_t i = wk_category_target_slot(cls);; i = (i + 1) & (wk_category_target_capacity - 1)) {
        if (wk_category_targets[i] == cls)
            return true;
        if (!wk_category_targets[i])
            return false;
    }
}

static void wk_note_category_target(const struct wk_raw_class *cls)
{
    if (wk_is_category_target(cls))
        return;
    if ((wk_category_target_count + 1) * 2 > wk_category_target_capacity) {
        const struct wk_raw_class **previous = wk_category_targets;
        size_t previousCapacity = wk_category_target_capacity;
        wk_category_target_capacity = previousCapacity ? previousCapacity * 2 : 64;
        wk_category_targets = calloc(wk_category_target_capacity, sizeof(*wk_category_targets));
        if (!wk_category_targets)
            abort();
        wk_category_target_count = 0;
        for (size_t i = 0; i < previousCapacity; i++)
            if (previous[i])
                wk_note_category_target(previous[i]);
        free(previous);
    }
    size_t i = wk_category_target_slot(cls);
    while (wk_category_targets[i])
        i = (i + 1) & (wk_category_target_capacity - 1);
    wk_category_targets[i] = cls;
    wk_category_target_count++;
}

static void wk_note_image_categories(const struct mach_header *mh)
{
    unsigned long size = 0;
    struct wk_raw_category *const *categories = (struct wk_raw_category *const *)
        getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__objc_catlist", &size);
    if (!categories)
        return;
    bool canonicalNames = wk_is_shared_cache_image(mh);
    for (unsigned long i = 0; i < size / sizeof(*categories); i++) {
        // A category's class is NULL while it is a weak-linked class this OS lacks; once the runtime has
        // read the image it also nils that category's catlist entry, as its own unload pass expects.
        const struct wk_raw_category *category = categories[i];
        if (category && category->cls && (wk_raw_list_may_register(category->instanceMethods, canonicalNames)
                                          || wk_raw_list_may_register(category->classMethods, canonicalNames)))
            wk_note_category_target(category->cls);
    }
}

static void wk_note_loaded_categories(void)
{
    if (wk_category_targets)
        memset(wk_category_targets, 0, wk_category_target_capacity * sizeof(*wk_category_targets));
    wk_category_target_count = 0;
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++)
        wk_note_image_categories(_dyld_get_image_header(i));
}

// Whether wk_alias_class could find a registered selector on the class or its metaclass. A class the
// runtime has realized is asked through its method lists; one it has not is answered from the metadata
// realizing it would read, so a class nothing here concerns stays unrealized.
static bool wk_class_may_register(const struct wk_raw_class *cls, bool canonicalNames)
{
    const struct wk_raw_class_ro *ro = wk_unrealized_ro(cls);
    const struct wk_raw_class_ro *metaRO = ro ? wk_unrealized_ro(cls->isa) : NULL;
    if (!ro || !metaRO)
        return true;
    return wk_raw_list_may_register(ro->baseMethods, canonicalNames)
        || wk_raw_list_may_register(metaRO->baseMethods, canonicalNames) || wk_is_category_target(cls);
}

static const char *wk_raw_class_name(const struct wk_raw_class *cls)
{
    const struct wk_raw_class_ro *ro = wk_unrealized_ro(cls);
    return ro ? ro->name : class_getName((Class)cls);
}

// One image's classes, so the work a dlopen pays for is bounded by what it brought in rather than by
// every class in the process. objc_getClass realizes the class, which is what makes its method list
// safe to copy.
static void wk_alias_image(const struct mach_header *mh, int from, int to)
{
    if (!mh || from >= to)
        return;
    unsigned long size = 0;
    struct wk_raw_class *const *classes = (struct wk_raw_class *const *)
        getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__objc_classlist", &size);
    if (!classes)
        return;
    bool webKitImage = wk_is_webkit_image(mh);
    bool canonicalNames = wk_is_shared_cache_image(mh);
    for (unsigned long i = 0; i < size / sizeof(*classes); i++) {
        wk_stat_classes++;
        if (!wk_class_may_register(classes[i], canonicalNames))
            continue;
        Class cls = objc_getClass(wk_raw_class_name(classes[i]));
        if (!cls)
            continue;
        wk_stat_realized++;
        wk_alias_class(cls, from, to, webKitImage);                  // instance methods
        wk_alias_class(object_getClass(cls), from, to, webKitImage); // class methods, on the metaclass
    }
}

// The classes of other images that an image's categories give a registered selector. A category in an
// image loaded after launch attaches its methods to a class whose own image was swept before they
// existed, so that class is aliased again for them.
static void wk_alias_category_targets(const struct mach_header *mh, int from, int to)
{
    if (from >= to)
        return;
    unsigned long size = 0;
    struct wk_raw_category *const *categories = (struct wk_raw_category *const *)
        getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__objc_catlist", &size);
    if (!categories)
        return;
    bool canonicalNames = wk_is_shared_cache_image(mh);
    for (unsigned long i = 0; i < size / sizeof(*categories); i++) {
        const struct wk_raw_category *category = categories[i];
        if (!category || !category->cls)
            continue;
        bool instanceSide = wk_raw_list_may_register(category->instanceMethods, canonicalNames);
        bool classSide = wk_raw_list_may_register(category->classMethods, canonicalNames);
        if (!instanceSide && !classSide)
            continue;
        const struct mach_header *classImage = _dyld_get_image_header_containing_address(category->cls);
        if (classImage == mh)
            continue;   // the image's own sweep reads its classes with their categories attached
        Class cls = objc_getClass(wk_raw_class_name(category->cls));
        if (!cls)
            continue;
        bool webKitImage = wk_is_webkit_image(classImage);
        if (instanceSide)
            wk_alias_class(cls, from, to, webKitImage);
        if (classSide)
            wk_alias_class(object_getClass(cls), from, to, webKitImage);
    }
}

// Every image loaded so far, for a range of registry entries. Runs when the REGISTRY grows rather than
// when an image arrives: classes scanned earlier have never been asked about a selector registered
// since. Bounded by the number of images carrying __wk_methods (WebCore and WebKit), not by dlopens.
static void wk_alias_loaded_images(int from, int to)
{
    wk_note_loaded_categories();
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++)
        wk_alias_image(_dyld_get_image_header(i), from, to);
    wk_alias_install_pending();
}

// ---------------------------------------------------------------------------------------------
// Blocks: registering their selectors and installing their bodies.

// The block's class, realized so its method lists can be read. objc_getClass realizes without sending
// +initialize, which a subclass of a system class must never receive (the superclass's +initialize
// would run for it).
static Class wk_placeholder_class(const struct wk_methods_entry *e)
{
    Class cls = objc_getClass(e->placeholder);
    if (!cls) {
        fprintf(stderr, "[wk_selref_scope] FATAL: polyfill block %s is not a class in this process.\n",
                e->placeholder);
        fflush(stderr);
        abort();
    }
    return cls;
}

// The private selector for a public one, from the registry.
static SEL wk_private_selector(SEL pub)
{
    for (int j = 0; j < wk_count; j++)   // plain reads: callers hold wk_reg_lock
        if (wk_pub[j] == pub)
            return wk_priv[j];
    return NULL;
}

// Registers one public selector (idempotent) and returns its private one.
static SEL wk_register_selector(SEL pub)
{
    SEL priv = wk_private_selector(pub);
    if (priv)
        return priv;
    if (wk_count >= WK_MAX_SEL)
        wk_registry_full("distinct ObjC method polyfills are registered", WK_MAX_SEL, "WK_MAX_SEL",
                         sel_getName(pub));
    const char *name = sel_getName(pub);
    char *privName = malloc(strlen(name) + 4);
    strcpy(privName, "wk_");
    strcat(privName, name);
    priv = sel_registerName(privName);
    free(privName);
    int slot = wk_count;
    wk_pub[slot] = pub;
    wk_pubname[slot] = name;   // sel_getName is stable for the life of the process
    wk_priv[slot] = priv;
    // The entry's filter bits, before the entry is reachable (see the prefilter note).
    WK_FILTER_SET(wk_name_filter, wk_name_hash(name));
    wk_note_registered_name(name, slot);
    WK_FILTER_SET(wk_sel_filter, wk_sel_hash(pub));
    wk_note_registered_sel(pub, slot);
    // Publishes the stores above to every reader that acquire-loads wk_count.
    __atomic_store_n(&wk_count, slot + 1, __ATOMIC_RELEASE);
    return priv;
}

// Registers every method of one side (instance methods of the block, or class methods via its
// metaclass) and, for a REPLACE block, records its bodies.
static void wk_register_side(Class side, int intent)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(side, &n);
    for (unsigned int i = 0; i < n; i++) {
        SEL priv = wk_register_selector(method_getName(methods[i]));
        if (intent == WK_METHODS_REPLACE) {
            for (int j = 0; j < wk_count; j++)
                if (wk_priv[j] == priv)
                    wk_replace_sel[j] = true;
            IMP imp = method_getImplementation(methods[i]);
            if (!wk_is_replace_body(imp)) {
                if (wk_replace_body_count >= WK_MAX_REPLACE_BODIES)
                    wk_registry_full("REPLACE bodies are registered", WK_MAX_REPLACE_BODIES,
                                     "WK_MAX_REPLACE_BODIES", sel_getName(method_getName(methods[i])));
                wk_replace_body[wk_replace_body_count] = imp;
                __atomic_store_n(&wk_replace_body_count, wk_replace_body_count + 1, __ATOMIC_RELEASE);
            }
        }
    }
    free(methods);
}

// Installs one side's bodies on one target class (the metaclass, for class methods). Idempotent:
// class_addMethod is a no-op once the wk_ method exists, and re-replacing with the same IMP changes
// nothing. An ADD uses class_addMethod because the alias pass may already have bound the wk_ name on a
// class that has the real method — which an ADD target is not, so the body lands. A REPLACE uses
// class_replaceMethod so the body wins over an alias in either order. Returns whether a body landed.
static bool wk_install_side(Class side, Class target, int intent)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(side, &n);
    bool installed = false;
    for (unsigned int i = 0; i < n; i++) {
        SEL priv = wk_private_selector(method_getName(methods[i]));
        IMP imp = method_getImplementation(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        if (intent == WK_METHODS_REPLACE)
            installed |= class_replaceMethod(target, priv, imp, types) != imp;
        else
            installed |= class_addMethod(target, priv, imp, types);
    }
    free(methods);
    // Invalidates the wk_original_of memo: the targets' chains answer differently now.
    if (installed)
        __atomic_fetch_add(&wk_install_generation, 1, __ATOMIC_RELEASE);
    return installed;
}

// YES once every target class exists — the bodies are now installed on all of them. Sets *installed
// when a body landed on a target that lacked it.
//
// The metaclass is reached through the class object (object_getClass), NOT objc_getMetaClass: 10.9's
// objc_getMetaClass prints "class `X' not linked into application" on every miss, and a deferred block
// for a lazily-loaded framework's class polls this on every image event until the class arrives —
// hundreds of stderr lines per process launch. objc_getClass misses silently.
static BOOL wk_install_entry(const struct wk_methods_entry *e, bool *installed)
{
    Class placeholder = wk_placeholder_class(e);
    BOOL complete = YES;
    for (const char *const *name = e->targets; *name; name++) {
        Class target = objc_getClass(*name);
        if (!target) {
            complete = NO;
            continue;
        }
        *installed |= wk_install_side(placeholder, target, e->intent);
        *installed |= wk_install_side(object_getClass(placeholder), object_getClass(target), e->intent);
    }
    return complete;
}

// Blocks with a target class that did not exist yet when their image was scanned — see wk_collect.
// Pointers into the declaring image's __wk_methods, which is const data in an image that is never
// unloaded (the sections live in WebCore's force-loaded polyfill objects), so they stay valid.
// Guarded by wk_reg_lock and only ever touched from the image-load path. The cap bounds the number of
// blocks in the build, not anything the running process controls.
enum { WK_MAX_BLOCKS = 256 };
static const struct wk_methods_entry *wk_deferred[WK_MAX_BLOCKS];
static int wk_deferred_count;

// Retries the blocks still waiting for a class; the list drains as the classes appear and is empty in
// the common case, so an image load costs nothing extra once everything is installed. Returns whether
// a body landed. Caller holds wk_reg_lock.
static bool wk_install_deferred(void)
{
    bool installed = false;
    int keep = 0;
    for (int i = 0; i < wk_deferred_count; i++)
        if (!wk_install_entry(wk_deferred[i], &installed))
            wk_deferred[keep++] = wk_deferred[i];
    wk_deferred_count = keep;
    return installed;
}

// Images whose blocks have been collected: the constructor scans the launch batch, and an image that
// arrives later is scanned from wk_image_initializing.
enum { WK_MAX_BLOCK_IMAGES = 8 };
static const struct mach_header *wk_collected[WK_MAX_BLOCK_IMAGES];
static int wk_collected_count;

// The images listed when the constructor runs, sorted by header address. The constructor's sweep aliases
// every one of them for each entry registered by then, and every later wk_collect aliases every loaded
// image for the entries it adds, so such an image's own dependents_initialized notification has nothing
// left to alias unless that callback installed a body. An unloaded image leaves the set, since a later
// image can be mapped at its address. Guarded by wk_reg_lock.
static const struct mach_header **wk_launch_images;
static uint32_t wk_launch_image_count;
// Set while the constructor has yet to read the launch images' blocks and sweep them. Guarded by
// wk_reg_lock.
static bool wk_launch_sweep_pending;

static int wk_compare_headers(const void *a, const void *b)
{
    uintptr_t x = (uintptr_t)*(const struct mach_header *const *)a;
    uintptr_t y = (uintptr_t)*(const struct mach_header *const *)b;
    return x < y ? -1 : x > y;
}

static void wk_note_launch_images(void)
{
    uint32_t c = _dyld_image_count();
    wk_launch_images = malloc(c * sizeof(*wk_launch_images));
    if (!wk_launch_images)
        abort();
    uint32_t n = 0;
    for (uint32_t i = 0; i < c; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh)
            wk_launch_images[n++] = mh;
    }
    qsort(wk_launch_images, n, sizeof(*wk_launch_images), wk_compare_headers);
    wk_launch_image_count = n;
}

static const struct mach_header **wk_find_launch_image(const struct mach_header *mh)
{
    return bsearch(&mh, wk_launch_images, wk_launch_image_count, sizeof(*wk_launch_images),
                   wk_compare_headers);
}

static void wk_remove_image(const struct mach_header *mh, intptr_t slide)
{
    (void)slide;
    pthread_mutex_lock(&wk_reg_lock);
    const struct mach_header **entry = wk_find_launch_image(mh);
    if (entry) {
        memmove(entry, entry + 1, (wk_launch_images + wk_launch_image_count - (entry + 1)) * sizeof(*entry));
        wk_launch_image_count--;
    }
    pthread_mutex_unlock(&wk_reg_lock);
}

static void wk_patch(const struct mach_header *mh);
static void wk_patch_loaded_images(void)
{
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++)
        wk_patch(_dyld_get_image_header(i));
}

// Registers one image's blocks and installs their bodies, without the alias sweep or the patch. Returns
// whether it read any. Callable only once the ObjC runtime has that image's classes: at constructor
// time for everything in the launch batch, and from wk_image_initializing for an image that arrives
// later (inside the add-image callback the runtime cannot see the arriving image's classes yet — see
// the note above wk_image_initializing — and a block is a class). Caller holds wk_reg_lock.
static bool wk_collect_blocks(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_methods_entry *e =
        (const struct wk_methods_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                         "__DATA", "__wk_methods", &size);
    if (!e)
        return false;
    int n = (int)(size / sizeof(struct wk_methods_entry));
    for (int i = 0; i < wk_collected_count; i++)
        if (wk_collected[i] == mh)
            return false;
    if (wk_collected_count >= WK_MAX_BLOCK_IMAGES)
        wk_registry_full("images carry polyfill blocks", WK_MAX_BLOCK_IMAGES, "WK_MAX_BLOCK_IMAGES",
                         e[0].placeholder);
    wk_collected[wk_collected_count++] = mh;

    for (int i = 0; i < n; i++) {
        Class placeholder = wk_placeholder_class(&e[i]);
        wk_register_side(placeholder, e[i].intent);
        wk_register_side(object_getClass(placeholder), e[i].intent);
    }
    // Bodies first, then the alias sweep: the sweep's chain test (wk_alias_class) has to see a REPLACE
    // body on its target before it looks at the target's subclasses.
    for (int i = 0; i < n; i++) {
        bool installed = false;
        if (wk_install_entry(&e[i], &installed))
            continue;
        if (wk_deferred_count >= WK_MAX_BLOCKS)
            wk_registry_full("polyfill blocks are waiting for a class to load", WK_MAX_BLOCKS,
                             "WK_MAX_BLOCKS", e[i].placeholder);
        wk_deferred[wk_deferred_count++] = &e[i];
    }
    return true;
}

// Reads an image's blocks, then aliases every loaded image for the entries they add and patches every
// WebKit image: the selectors just registered have never been looked for in the classes already loaded,
// nor rewritten in the WebKit images already patched. Classes from images that arrive later are covered
// by wk_image_initializing, their selrefs by wk_add_image.
//
// Returns the registry count from which this call aliased every loaded image — mh among them, since
// dyld lists an image from the moment it is mapped — or -1 when it read no blocks.
static int wk_collect(const struct mach_header *mh)
{
    pthread_mutex_lock(&wk_reg_lock);
    int before = wk_count;
    if (!wk_collect_blocks(mh)) {
        pthread_mutex_unlock(&wk_reg_lock);
        return -1;
    }
    wk_alias_loaded_images(before, wk_count);
    wk_patch_loaded_images();
    pthread_mutex_unlock(&wk_reg_lock);
    return before;
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
    int count = __atomic_load_n(&wk_count, __ATOMIC_ACQUIRE);   // see the synchronisation note
    if (!refs || !size || count == 0)
        return;
    int n = (int)(size / sizeof(void *));
    __atomic_fetch_add(&wk_stat_refs, n, __ATOMIC_RELAXED);
    unsigned long namesSize = 0;
    const char *names = (const char *)getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__objc_methname", &namesSize);
    for (int i = 0; i < n; i++) {
        // Until objc uniques the image, a selref points at the image's own __objc_methname string; after,
        // at the canonical SEL, which is the image's own string only for a name this image registered
        // first. So a selref pointing anywhere else is the canonical SEL, and the pointer identifies it.
        const char *s = (const char *)refs[i];
        if (!(s >= names && s < names + namesSize)) {
            SEL sel = (SEL)refs[i];
            if (!WK_FILTER_TEST(wk_sel_filter, wk_sel_hash(sel)))
                continue;
            int j = wk_registered_sel_index(sel, count);
            if (j >= 0) {
                refs[i] = (void *)wk_priv[j];
                __atomic_fetch_add(&wk_stat_rewritten, 1, __ATOMIC_RELAXED);
            }
            continue;
        }
        // Otherwise match by NAME: for an image dlopen'd AFTER launch, dyld runs the add-image callback
        // BEFORE objc uniques the image's selrefs, so refs[i] still points to the image's local methname
        // string (not the canonical SEL) — a pointer compare would miss it. After we rewrite to wk_priv,
        // objc's later uniquing reads "wk_<name>" and re-derives the same private SEL, so the rewrite sticks.
        unsigned hash = wk_name_hash32(s);
        if (!WK_FILTER_TEST(wk_name_filter, hash & (WK_FILTER_BITS - 1)))
            continue;   // definitely not a registered name — see the prefilter note. A rewritten ref
                        // reads "wk_<name>", whose bit is not set.
        int j = wk_registered_name_index(s, hash, count);
        if (j >= 0) {
            refs[i] = (void *)wk_priv[j];
            __atomic_fetch_add(&wk_stat_rewritten, 1, __ATOMIC_RELAXED);
        }
    }
}

static void wk_add_image(const struct mach_header *mh, intptr_t slide)
{
    (void)slide;
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
enum { WK_DYLD_STATE_BOUND = 40, WK_DYLD_STATE_DEPENDENTS_INITIALIZED = 45 };
typedef const char *(*wk_dyld_state_handler)(uint32_t state, uint32_t count,
                                             const struct dyld_image_info *info);
typedef void (*wk_dyld_register_handler)(uint32_t state, bool batch, wk_dyld_state_handler handler);

// Returning a string would tell dyld the image is unacceptable and fail the load; nothing here rejects
// an image, so the answer is always NULL.
static const char *wk_image_initializing(uint32_t state, uint32_t count,
                                         const struct dyld_image_info *info)
{
    (void)state;
    for (uint32_t i = 0; i < count; i++) {
        // The constructor's own sweep covers every launch image; the notifications that registering the
        // handler delivers for them while that sweep is still to run have nothing to add.
        pthread_mutex_lock(&wk_reg_lock);
        bool coveredByLaunchSweep = wk_launch_sweep_pending && wk_find_launch_image(info[i].imageLoadAddress);
        pthread_mutex_unlock(&wk_reg_lock);
        if (coveredByLaunchSweep)
            continue;
        // Blocks an arriving image carries (WebKit.framework's, when it is loaded after WebCore) are
        // read here, the first point the runtime has the image's classes. Reading them aliases every
        // loaded image, this one included, for the entries they add, so this image's own sweep below
        // covers the entries registered before them.
        int swept = wk_collect(info[i].imageLoadAddress);
        pthread_mutex_lock(&wk_reg_lock);   // see the synchronisation note
        // Deferred blocks are retried HERE, not from the add-image callback: a class a block names can
        // arrive via dlopen (DDActionsManager arrives with soft-linked DataDetectors), and inside the
        // add-image callback the runtime cannot see the arriving image's classes yet (the measurement
        // above) — and when the dlopen'ing call stack goes on to send the rewritten selector immediately
        // (PAL soft-link then send, WebViewImpl.mm:3703), there is no later image load to rescue it and
        // the send dies on the uninstalled wk_ method. The drain runs before the alias sweep so the sweep
        // sees a REPLACE body on its target before it looks at the target's subclasses. A launch image
        // is swept only when the drain installed a body (see wk_launch_images).
        bool installed = wk_install_deferred();
        if (installed || !wk_find_launch_image(info[i].imageLoadAddress)) {
            wk_alias_image(info[i].imageLoadAddress, 0, swept < 0 ? wk_count : swept);
            wk_alias_category_targets(info[i].imageLoadAddress, 0, swept < 0 ? wk_count : swept);
            wk_alias_install_pending();
        }
        pthread_mutex_unlock(&wk_reg_lock);
    }
    return NULL;
}

// A batch's categories, noted when dyld has bound it and before any of its images reaches
// dependents_initialized (see wk_category_targets).
static const char *wk_batch_bound(uint32_t state, uint32_t count, const struct dyld_image_info *info)
{
    (void)state;
    pthread_mutex_lock(&wk_reg_lock);
    for (uint32_t i = 0; i < count; i++)
        wk_note_image_categories(info[i].imageLoadAddress);
    pthread_mutex_unlock(&wk_reg_lock);
    return NULL;
}

// dyld_register_image_state_change_handler is dyld_priv.h SPI. 10.9's libdyld exports it; the build SDK
// neither declares nor stubs it, so it is declared above and resolved by name rather than linked.
static void wk_watch_for_images(void)
{
    wk_dyld_register_handler reg =
        (wk_dyld_register_handler)dlsym(RTLD_DEFAULT, "dyld_register_image_state_change_handler");
    reg(WK_DYLD_STATE_BOUND, true, wk_batch_bound);
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
    // afterwards would leave a window in which a concurrent dlopen is covered by neither. Registration
    // dispatches each image whose initializers are running, this one among them; those are launch
    // images, which the sweep below covers.
    uint64_t t0 = mach_absolute_time();
    wk_note_shared_cache_range();
    pthread_mutex_lock(&wk_reg_lock);
    wk_note_launch_images();
    wk_launch_sweep_pending = true;
    pthread_mutex_unlock(&wk_reg_lock);
    _dyld_register_func_for_remove_image(wk_remove_image);
    wk_watch_for_images();
    uint32_t c = _dyld_image_count();
    // Registers and installs the blocks of every launch image, then aliases every registered selector
    // across every image loaded so far in one sweep — before any patching, so a rewritten selref that
    // reaches a class this layer did not polyfill finds that class's own method instead of dying — and
    // then patches every WebKit image. The launch batch's classes are all known to the runtime by the
    // time any initializer runs.
    pthread_mutex_lock(&wk_reg_lock);
    int before = wk_count;
    bool collected = false;
    for (uint32_t i = 0; i < c; i++)
        collected |= wk_collect_blocks(_dyld_get_image_header(i));
    if (collected) {
        wk_alias_loaded_images(before, wk_count);
        wk_patch_loaded_images();
    }
    wk_launch_sweep_pending = false;
    pthread_mutex_unlock(&wk_reg_lock);
    uint64_t t1 = mach_absolute_time();
    // Patches images dlopen'd later (fires immediately for already-loaded ones; patch is idempotent
    // since a rewritten wk_ selref no longer matches any public selector).
    _dyld_register_func_for_add_image(wk_add_image);
    uint64_t t2 = mach_absolute_time();

    if (getenv("WK_POLYFILL_REPORT"))
        fprintf(stderr, "[wk_selref_scope] startup %.2f ms (%u images): collect+install+alias+patch %.2f "
                        "(%d sels, %d blocks deferred, %ld classes, %ld realized, %ld methods, %ld refs, "
                        "%ld rewritten), add-image refire %.2f\n",
                wk_ms(t0, t2), c, wk_ms(t0, t1), wk_count, wk_deferred_count, wk_stat_classes,
                wk_stat_realized, wk_stat_methods, wk_stat_refs, wk_stat_rewritten, wk_ms(t1, t2));
}
