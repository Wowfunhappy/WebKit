/*
 * wild-free detector for demangler-crash-scan.
 *
 * The 10.9 __cxa_demangle bug manifests as free() of a garbage pointer
 * assembled from demangled-symbol TEXT. Whether that free aborts (detected)
 * or silently corrupts depends on whether the garbage address happens to
 * fall inside a mapped malloc region -- i.e. on how much heap the process
 * consumed before the bad symbol, which made scans position-dependent and
 * nondeterministic (Guard Malloc does not help: it forwards frees of
 * pointers it does not own to the previous zone, silently).
 *
 * This dylib is DYLD_INSERT_LIBRARIES'd into the scan worker and interposes
 * free(): a non-NULL pointer that no malloc zone claims is a wild free, so
 * the worker child dies immediately, letting the scanner attribute it to the
 * exact symbol. Note this cannot be fully deterministic either -- the bug
 * reads uninitialized stack, so a bad symbol may compute a pointer that a
 * zone happens to claim (or no wild pointer at all) in some layouts; the
 * orchestrator compensates with multiple varied-environment trials plus
 * family closure.
 *
 * clang -dynamiclib -mmacosx-version-min=10.9 -o demangler-crash-scan-freecheck.dylib \
 *       demangler-crash-scan-freecheck.c
 */

#include <malloc/malloc.h>
#include <stdlib.h>
#include <unistd.h>

static void checked_free(void *p)
{
    if (p && !malloc_zone_from_ptr(p))
        _exit(42); /* wild free: demangler heap corruption */
    free(p);
}

__attribute__((used)) static const struct { void *replacement; void *original; }
interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (void *)checked_free, (void *)free },
};
