/*
 * dyld_shared_cache_iterate_text (10.10) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Stub: report no shared cache.
 */

int dyld_shared_cache_iterate_text(const void *uuid, void (*callback)(const void *info)) {
	(void)uuid; (void)callback;
	return -1;
}
