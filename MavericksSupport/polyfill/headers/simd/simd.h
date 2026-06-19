#ifndef _SIMD_SIMD_H_
#define _SIMD_SIMD_H_

/* Minimal SIMD stub for macOS 10.9 */
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float x, y, z, w; } simd_float4;
typedef struct { float columns[4][4]; } simd_float4x4;
typedef struct { double x, y, z, w; } simd_double4;
typedef struct { double columns[4][4]; } simd_double4x4;

typedef simd_float4x4 matrix_float4x4;
typedef simd_double4x4 matrix_double4x4;

#ifdef __cplusplus
}
#endif

#endif
