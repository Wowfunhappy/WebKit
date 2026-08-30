// Resolving a symbol inside a loaded system image, and replacing one pointer-sized value in the data
// that symbol names.
//
// EVERY USE OF THIS INTERFACE REQUIRES THE MAINTAINER'S EXPLICIT APPROVAL, sanctioned one use at a
// time: each one is a divergence from a system framework's own behaviour. MavericksSupport/polyfill/
// README.md carries the same sentence where someone looking for a way to add a polyfill will meet it.
//
// Data only. Nothing here writes over an instruction, and there is no way to ask it to: a patch stores
// one pointer into a location a symbol names, and a replacement reaches the function it stands in for
// through the pointer the vtable form answers with.

#ifndef WK_SYMBOLS_H
#define WK_SYMBOLS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A loaded image and the slide its addresses carry.
typedef struct {
    uint32_t index;
    const char *path;
    intptr_t slide;
} wk_image;

// The loaded image whose path ends with |pathSuffix|.
bool wk_find_image(const char *pathSuffix, wk_image *image);

// The runtime address of |name| in |image|'s own symbol table. A local symbol answers as readily as an
// exported one, which is the point: the names worth reaching inside a system framework are not exported.
void *wk_symbol_in_image(const wk_image *image, const char *name);

// One pointer-sized location, named by the symbol that holds it.
typedef struct {
    // Names this patch in every failure message.
    const char *what;
    const char *imagePathSuffix;
    const char *symbol;
    // Whether this process is one to patch at all.
    bool (*isInScope)(void);
    // Whether the location holds what this patch is written against, read as the value in it. This
    // predicate is the description of the system the patch was written for, so it stays with the
    // caller; a system it does not describe keeps whatever it has.
    bool (*describes)(const void *currentValue);
    const void *replacement;
} wk_pointer_patch;

void wk_patch_pointer(const wk_pointer_patch *patch);

// A C++ vtable slot, named by the function expected to occupy it. The slot is scanned for, so no slot
// offset is written down anywhere and the scan is itself the validation.
typedef struct {
    const char *what;
    const char *imagePathSuffix;
    const char *vtableSymbol;
    const char *originalSymbol;
    bool (*isInScope)(void);
    const void *replacement;
} wk_vtable_patch;

// Answers with the function |originalSymbol| names, so a replacement can call through it, and sets
// |installed| to whether THIS image is the one that wrote the slot.
//
// libpolyfill.a is force-loaded into every WebKit framework, so a load-time patch runs once per
// framework over one location. dyld runs initializers serially, so the first framework to reach a set
// of patches claims all of them and the rest find the work done; |installed| is how a caller whose
// replacements share state checks that, rather than assuming it.
void *wk_patch_vtable_slot(const wk_vtable_patch *patch, bool *installed);

// Reports |reason| against |what| and ends the process. A patch that quietly did not apply leaves its
// caller believing in behaviour the process does not have.
void wk_patch_fail(const char *what, const char *reason) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif // WK_SYMBOLS_H
