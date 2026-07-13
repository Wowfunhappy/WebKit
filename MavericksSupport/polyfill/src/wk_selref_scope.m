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
// so a host app's respondsToSelector: returns NO for the correct reason. No interposition, no gating; the
// only cost is a one-time selref scan per WebKit image at load. Runs in every process WebKit loads into.
//
// A "WebKit image" is any binary carrying __DATA,__wk_marker, injected by wk_image_marker.c which is
// force-loaded into every WebKit framework (WEBKIT_FRAMEWORK). This object (the patcher + registry) and
// wk_polyfills.m (the polyfill methods + WK_POLYFILL_SEL registrations) are force-loaded into WebCore only
// — they load early in every rendering process and keep the AppKit categories out of the setuid-JSC path.
// THE POLYFILLS THEMSELVES LIVE IN wk_polyfills.m; add new ones there.

#import "wk_selref_scope.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <string.h>
#import <stdint.h>

// Resolved public->private SEL map, built once from all __wk_selmap sections.
enum { WK_MAX_SEL = 256 };
static SEL wk_pub[WK_MAX_SEL];          // canonical public SEL (fast-path pointer match)
static const char *wk_pubname[WK_MAX_SEL]; // public selector NAME (content match — see wk_patch)
static SEL wk_priv[WK_MAX_SEL];
static int wk_count;

static void wk_collect(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_selmap_entry *e =
        (const struct wk_selmap_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                        "__DATA", "__wk_selmap", &size);
    if (!e)
        return;
    int n = (int)(size / sizeof(struct wk_selmap_entry));
    for (int i = 0; i < n; i++) {
        SEL p = sel_registerName(e[i].pub);
        int dup = 0;
        for (int j = 0; j < wk_count; j++)
            if (wk_pub[j] == p) { dup = 1; break; }
        if (dup || wk_count >= WK_MAX_SEL)
            continue;
        wk_pub[wk_count] = p;
        wk_pubname[wk_count] = e[i].pub; // stable string literal in the image's __wk_selmap owner
        wk_priv[wk_count] = sel_registerName(e[i].priv);
        wk_count++;
    }
}

static void wk_patch(const struct mach_header *mh)
{
    unsigned long msz = 0;
    if (!getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__wk_marker", &msz))
        return; // not a WebKit image
    unsigned long size = 0;
    SEL *refs = (SEL *)getsectiondata((const struct mach_header_64 *)mh, "__DATA", "__objc_selrefs", &size);
    if (!refs)
        refs = (SEL *)getsectiondata((const struct mach_header_64 *)mh, "__DATA_CONST", "__objc_selrefs", &size);
    if (!refs || !size || wk_count == 0)
        return;
    // selrefs may live in read-only __DATA_CONST; make the range writable (no SIP on 10.9).
    vm_protect(mach_task_self(), (vm_address_t)refs, size, false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    int n = (int)(size / sizeof(SEL));
    for (int i = 0; i < n; i++) {
        // Match by NAME, not just pointer: for an image dlopen'd AFTER launch, dyld runs this add-image
        // callback BEFORE objc uniques the image's selrefs, so refs[i] still points to the image's local
        // methname string (not the canonical SEL) — a pointer compare would miss it. strcmp catches both
        // states; a selref always points to a valid C string (methname before uniquing, SEL after). After
        // we rewrite to wk_priv, objc's later uniquing reads "wk_<name>" and re-derives the same private
        // SEL, so the rewrite sticks.
        const char *s = (const char *)refs[i];
        for (int j = 0; j < wk_count; j++)
            if (refs[i] == wk_pub[j] || strcmp(s, wk_pubname[j]) == 0) { refs[i] = wk_priv[j]; break; }
    }
}

// Install the wk_<name> aliases registered by WK_POLYFILL_ALIAS in this image: add wk_<name> to the named
// class as an alias of the class's own real <name> IMP (so a selref rewritten to wk_<name> reaches the real
// method on classes that already implement <name>). See wk_aliasmap_entry in the header.
static void wk_install_aliases(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_aliasmap_entry *e =
        (const struct wk_aliasmap_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                         "__DATA", "__wk_aliasmap", &size);
    if (!e)
        return;
    int n = (int)(size / sizeof(struct wk_aliasmap_entry));
    for (int i = 0; i < n; i++) {
        Class c = objc_getClass(e[i].cls);
        if (!c)
            continue;
        SEL pub = sel_registerName(e[i].pub);
        SEL priv = sel_registerName(e[i].priv);
        Method m = e[i].is_class_method ? class_getClassMethod(c, pub) : class_getInstanceMethod(c, pub);
        if (!m)
            continue;
        // Metaclass for + methods. class_addMethod is a no-op (returns NO) if wk_<name> already exists, so
        // firing this again for a post-launch dlopen is harmless.
        Class target = e[i].is_class_method ? object_getClass(c) : c;
        class_addMethod(target, priv, method_getImplementation(m), method_getTypeEncoding(m));
    }
}

// Install the wk_ methods registered by WK_POLYFILL_ADD in this image: add each C-function IMP to the
// runtime-resolved class (no compile-time classref — safe for moved-framework classes). See the header.
static void wk_install_added(const struct mach_header *mh)
{
    unsigned long size = 0;
    const struct wk_addmap_entry *e =
        (const struct wk_addmap_entry *)getsectiondata((const struct mach_header_64 *)mh,
                                                       "__DATA", "__wk_addmap", &size);
    if (!e)
        return;
    int n = (int)(size / sizeof(struct wk_addmap_entry));
    for (int i = 0; i < n; i++) {
        Class c = objc_getClass(e[i].cls);
        if (!c)
            continue;
        // Idempotent: class_addMethod is a no-op (returns NO) if the wk_ method already exists.
        class_addMethod(c, sel_registerName(e[i].sel), (IMP)e[i].imp, e[i].types);
    }
}

static void wk_add_image(const struct mach_header *mh, intptr_t slide)
{
    (void)slide;
    wk_collect(mh);
    wk_install_aliases(mh);
    wk_install_added(mh);
    wk_patch(mh);
}

__attribute__((constructor)) static void wk_selref_scope_init(void)
{
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++)
        wk_collect(_dyld_get_image_header(i));
    // Install aliases before patching: the classes they target are launch-time system classes (already
    // loaded here), so wk_<name> exists on them before any WebKit call site dispatches the rewritten selref.
    for (uint32_t i = 0; i < c; i++)
        wk_install_aliases(_dyld_get_image_header(i));
    for (uint32_t i = 0; i < c; i++)
        wk_install_added(_dyld_get_image_header(i));
    for (uint32_t i = 0; i < c; i++)
        wk_patch(_dyld_get_image_header(i));
    // Also covers images dlopen'd later (fires immediately for already-loaded ones; collect dedups,
    // patch is idempotent since a rewritten wk_ selref no longer matches any public selector).
    _dyld_register_func_for_add_image(wk_add_image);
}
