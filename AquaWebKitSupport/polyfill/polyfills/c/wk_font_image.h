#ifndef WK_FONT_IMAGE_H
#define WK_FONT_IMAGE_H
#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Each returns NULL for bytes that do not decode, and for an image of more than maximumPixels pixels.
CGImageRef wk_fontImageDecodePNG(const uint8_t *bytes, size_t length, size_t maximumPixels);
CGImageRef wk_fontImageDecodeJPEG(const uint8_t *bytes, size_t length, size_t maximumPixels);
CGImageRef wk_fontImageDecodeTIFF(const uint8_t *bytes, size_t length, size_t maximumPixels);
#ifdef __cplusplus
}
#endif
#endif
