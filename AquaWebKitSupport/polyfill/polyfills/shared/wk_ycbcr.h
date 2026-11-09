/*
 * R'G'B' <-> Y'CbCr: the matrix VideoToolbox assumes for untagged video of a given size, a 32ARGB/32BGRA
 * -> 4:2:0 bi-planar conversion with it, and the inverse into 32ARGB for Mavericks' display layer.
 *
 * Plain C, no framework calls: VideoToolbox.c (libpolyfill.a), vtcompression_cadence.c (libpolyfill.a
 * and the deps gap archive) and avf-display-color.h include it and do their own buffer locking.
 */
#ifndef WK_YCBCR_H
#define WK_YCBCR_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ITU-R BT.709 from 720 lines up, BT.601 below.
static inline CFStringRef wk_ycbcr_default_matrix(size_t width, size_t height)
{
    (void)width;
    return height >= 720 ? CFSTR("ITU_R_709_2") : CFSTR("ITU_R_601_4");
}

// Q16 coefficients: Y from R, G, B; Cb from R, G, B; Cr from R, G, B, for the four matrices CoreVideo names.
static inline const int32_t *wk_ycbcr_coefficients(CFStringRef matrix, bool fullRange)
{
    static const int32_t bt709VideoRange[9] = { 11966, 40254, 4064, -6596, -22189, 28784, 28784, -26145, -2639 };
    static const int32_t bt709FullRange[9] = { 13933, 46871, 4732, -7509, -25259, 32768, 32768, -29763, -3005 };
    static const int32_t bt601VideoRange[9] = { 16829, 33039, 6416, -9714, -19070, 28784, 28784, -24103, -4681 };
    static const int32_t bt601FullRange[9] = { 19595, 38470, 7471, -11059, -21709, 32768, 32768, -27439, -5329 };
    static const int32_t smpte240MVideoRange[9] = { 11932, 39455, 4897, -6684, -22100, 28784, 28784, -25606, -3178 };
    static const int32_t smpte240MFullRange[9] = { 13894, 45940, 5702, -7609, -25159, 32768, 32768, -29150, -3618 };
    static const int32_t bt2020VideoRange[9] = { 14786, 38160, 3338, -8038, -20746, 28784, 28784, -26469, -2315 };
    static const int32_t bt2020FullRange[9] = { 17216, 44434, 3886, -9151, -23617, 32768, 32768, -30133, -2635 };
    if (!matrix)
        return NULL;
    if (CFEqual(matrix, CFSTR("ITU_R_709_2")))
        return fullRange ? bt709FullRange : bt709VideoRange;
    if (CFEqual(matrix, CFSTR("ITU_R_601_4")))
        return fullRange ? bt601FullRange : bt601VideoRange;
    if (CFEqual(matrix, CFSTR("SMPTE_240M_1995")))
        return fullRange ? smpte240MFullRange : smpte240MVideoRange;
    if (CFEqual(matrix, CFSTR("ITU_R_2020")))
        return fullRange ? bt2020FullRange : bt2020VideoRange;
    return NULL;
}

// A 32ARGB (|argb|) or 32BGRA image into same-sized luma and interleaved CbCr planes, chroma from the 2x2
// average.
static inline void wk_ycbcr_convert_rgb32(const uint8_t *rgb, size_t rgbStride, bool argb, uint8_t *luma,
    size_t lumaStride, uint8_t *chroma, size_t chromaStride, size_t width, size_t height, const int32_t *k,
    bool fullRange)
{
    const int32_t yOffset = fullRange ? 0 : 16 << 16;
    size_t r = argb ? 1 : 2, g = argb ? 2 : 1, b = argb ? 3 : 0;
    for (size_t y = 0; y < height; y += 2) {
        for (size_t x = 0; x < width; x += 2) {
            int32_t sumR = 0, sumG = 0, sumB = 0, count = 0;
            for (size_t dy = 0; dy < 2 && y + dy < height; ++dy) {
                for (size_t dx = 0; dx < 2 && x + dx < width; ++dx) {
                    const uint8_t *pixel = rgb + (y + dy) * rgbStride + (x + dx) * 4;
                    luma[(y + dy) * lumaStride + x + dx] = (uint8_t)((yOffset + k[0] * pixel[r] + k[1] * pixel[g] + k[2] * pixel[b] + 32768) >> 16);
                    sumR += pixel[r];
                    sumG += pixel[g];
                    sumB += pixel[b];
                    ++count;
                }
            }
            int32_t cb = ((128 << 16) * count + k[3] * sumR + k[4] * sumG + k[5] * sumB) / count;
            int32_t cr = ((128 << 16) * count + k[6] * sumR + k[7] * sumG + k[8] * sumB) / count;
            cb = (cb + 32768) >> 16;
            cr = (cr + 32768) >> 16;
            // CoreVideo's full-range chroma interval is [1, 255].
            chroma[(y / 2) * chromaStride + x] = (uint8_t)(cb < 1 ? 1 : cb > 255 ? 255 : cb);
            chroma[(y / 2) * chromaStride + x + 1] = (uint8_t)(cr < 1 ? 1 : cr > 255 ? 255 : cr);
        }
    }
}

// The inverse of wk_ycbcr_coefficients in Q16: R', G', B' from (Y' - luma offset), (Cb - 128), (Cr - 128).
static inline bool wk_ycbcr_inverse_coefficients(CFStringRef matrix, bool fullRange, int32_t out[9])
{
    const int32_t *k = wk_ycbcr_coefficients(matrix, fullRange);
    if (!k)
        return false;
    double m[9];
    for (int i = 0; i < 9; ++i)
        m[i] = k[i] / 65536.;
    double determinant = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (!determinant)
        return false;
    double inverse[9] = {
        m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
        m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
        m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
    };
    for (int i = 0; i < 9; ++i) {
        double value = inverse[i] / determinant * 65536.;
        out[i] = (int32_t)(value < 0 ? value - .5 : value + .5);
    }
    return true;
}

static inline uint8_t wk_ycbcr_clamp(int32_t value)
{
    return (uint8_t)(value < 0 ? 0 : value > 255 ? 255 : value);
}

// A Y'CbCr image with horizontally halved chroma into opaque 32ARGB, each chroma sample serving the luma
// samples it covers. |lumaStep| and |chromaStep| are the byte distances between horizontally adjacent
// samples, and a chroma row covers 1 << |chromaRowShift| luma rows. |m| is wk_ycbcr_inverse_coefficients.
static inline void wk_ycbcr_convert_to_argb(const uint8_t *luma, size_t lumaStride, size_t lumaStep, const uint8_t *cb,
    const uint8_t *cr, size_t chromaStride, size_t chromaStep, unsigned chromaRowShift, uint8_t *argb, size_t argbStride,
    size_t width, size_t height, const int32_t *m, bool fullRange)
{
    const int32_t yOffset = fullRange ? 0 : 16;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *lumaRow = luma + y * lumaStride;
        size_t chromaRow = (y >> chromaRowShift) * chromaStride;
        uint8_t *pixel = argb + y * argbStride;
        for (size_t x = 0; x < width; ++x, pixel += 4) {
            int32_t l = lumaRow[x * lumaStep] - yOffset;
            size_t chroma = chromaRow + (x >> 1) * chromaStep;
            int32_t u = cb[chroma] - 128, v = cr[chroma] - 128;
            pixel[0] = 255;
            pixel[1] = wk_ycbcr_clamp((m[0] * l + m[1] * u + m[2] * v + 32768) >> 16);
            pixel[2] = wk_ycbcr_clamp((m[3] * l + m[4] * u + m[5] * v + 32768) >> 16);
            pixel[3] = wk_ycbcr_clamp((m[6] * l + m[7] * u + m[8] * v + 32768) >> 16);
        }
    }
}

#endif // WK_YCBCR_H
