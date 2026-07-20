/*
 * CCRandomGenerateBytes (CommonCrypto, 10.10+).
 *
 * arc4random_buf is 10.9's CSPRNG and is seeded from the kernel entropy pool, so it
 * yields the same quality of randomness this call promises. kCCParamError (-4300)
 * is what the real function returns for a null buffer or a zero count.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
 */

#include <stddef.h>
#include <stdlib.h>

int CCRandomGenerateBytes(void *bytes, size_t count) {
	if (bytes == NULL || count == 0) {
		return -4300; /* kCCParamError */
	}
	arc4random_buf(bytes, count);
	return 0;
}
