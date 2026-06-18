/*
 * Wrapper/replacement for <stdlib.h>, adding aligned_alloc (C11, added to macOS
 * in 10.15) which the 10.9 SDK lacks. Backed by src/aligned_alloc.c. Custom
 * (non-MacPorts) polyfill, following the wrapper convention of the other headers.
 */
#ifndef _MAVERICKS_STDLIB_H_
#define _MAVERICKS_STDLIB_H_

/* MP support header */
#include "LegacySupport.h"

/* Include the primary system stdlib.h (provides size_t etc.) */
#include_next <stdlib.h>

/* aligned_alloc (C11) -- provided by src/aligned_alloc.c on 10.9 */
__MP__BEGIN_DECLS
void *aligned_alloc(size_t alignment, size_t size);
__MP__END_DECLS

#endif /* _MAVERICKS_STDLIB_H_ */
