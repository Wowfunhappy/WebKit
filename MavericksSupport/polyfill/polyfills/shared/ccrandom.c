/*
 * CCRandomGenerateBytes (CommonCrypto, 10.10+).
 *
 * Forwards to CCRandomCopyBytes(kCCRandomDefault, ...), which 10.9's libcommonCrypto exports
 * and which is what the real implementation is built on
 * (apple-oss-distributions/CommonCrypto lib/CommonRandom.c). This feeds WebCrypto key
 * generation and Crypto::getRandomValues, so it takes the OS's own CSPRNG rather than a
 * different generator that merely looks equivalent.
 *
 * Argument handling matches CommonRandom.c: a zero count is checked FIRST and returns
 * kCCSuccess; only a null buffer with a nonzero count is kCCParamError (-4300). WebCore's
 * Crypto::getRandomValues RELEASE_ASSERTs on the return code and legally passes (NULL, 0) for
 * zero-length typed arrays.
 *
 * Resolved with dlsym rather than declared extern: CCRandomCopyBytes lives in 10.9's
 * libcommonCrypto but is not in the modern SDK's stub library, so a link-time reference fails
 * to build even though the call works at runtime. If it cannot be resolved the call reports
 * failure instead of silently substituting a weaker source -- a caller that RELEASE_ASSERTs is
 * better served by a loud failure than by unverified randomness.
 *
 * Plain C, no wk_polyfill.h: the non-WebKit binaries (the GStreamer/FFmpeg media stack, the
 * build's own python3) compile this same source, and they carry no polyfill registry. One
 * definition, used by all of them.
 */

#include <stddef.h>
#include <dlfcn.h>

typedef int (*MavCCRandomCopyBytes)(const void *rng, void *bytes, size_t count);

int CCRandomGenerateBytes(void *bytes, size_t count) {
	static MavCCRandomCopyBytes copyBytes;
	static const void *defaultRNG;
	static int resolved;

	if (count == 0) {
		return 0; /* kCCSuccess */
	}
	if (bytes == NULL) {
		return -4300; /* kCCParamError */
	}

	if (!resolved) {
		copyBytes = (MavCCRandomCopyBytes)dlsym(RTLD_DEFAULT, "CCRandomCopyBytes");
		/* kCCRandomDefault is `const CCRandomRef` -- a pointer VARIABLE naming the default
		 * RNG, so dlsym hands back its address and the value is one dereference in.
		 * Measured on this host: the dereferenced value, the slot address and NULL all
		 * return kCCSuccess with full-entropy output, NULL being CommonCrypto's own
		 * default-RNG fallback; pass the real value and let NULL stand in if it is absent. */
		void *slot = dlsym(RTLD_DEFAULT, "kCCRandomDefault");
		defaultRNG = slot ? *(const void **)slot : NULL;
		resolved = 1;
	}
	if (copyBytes == NULL) {
		return -4300; /* kCCParamError: no source to draw from */
	}
	return copyBytes(defaultRNG, bytes, count);
}
