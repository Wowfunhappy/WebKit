// Loaded-image symbol lookup for the native protection-space archive writer.
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

// Reports |reason| against |what| and ends the process. A patch that quietly did not apply leaves its
// caller believing in behaviour the process does not have.
void wk_patch_fail(const char *what, const char *reason) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif // WK_SYMBOLS_H
