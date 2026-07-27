/*
 * CCRandomGenerateBytes (CommonCrypto, 10.10+).
 *
 * arc4random_buf is 10.9's CSPRNG and is seeded from the kernel entropy pool, so it
 * yields the same quality of randomness this call promises. Matching the real
 * implementation (apple-oss-distributions/CommonCrypto lib/CommonRandom.c): a zero
 * count is checked FIRST and returns kCCSuccess; only a null buffer with a nonzero
 * count is kCCParamError (-4300). WebCore's Crypto::getRandomValues RELEASE_ASSERTs
 * on the return code and legally passes (NULL, 0) for zero-length typed arrays.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
 */

#include <stddef.h>
#include <stdlib.h>

int CCRandomGenerateBytes(void *bytes, size_t count) {
	if (count == 0) {
		return 0; /* kCCSuccess */
	}
	if (bytes == NULL) {
		return -4300; /* kCCParamError */
	}
	arc4random_buf(bytes, count);
	return 0;
}
