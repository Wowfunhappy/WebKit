#ifndef _COMPRESSION_H_
#define _COMPRESSION_H_

#include <stdint.h>
#include <stddef.h>

/* compression.h not available on macOS 10.9 */
typedef int compression_algorithm;
#define COMPRESSION_ZLIB 0x205
#define COMPRESSION_LZMA 0x306

typedef struct {
    uint8_t *dst_ptr;
    size_t dst_size;
    const uint8_t *src_ptr;
    size_t src_size;
    void *state;
} compression_stream;

typedef int compression_status;
#define COMPRESSION_STATUS_OK 0
#define COMPRESSION_STATUS_ERROR -1
#define COMPRESSION_STATUS_END 1
#define COMPRESSION_STREAM_ENCODE 0
#define COMPRESSION_STREAM_DECODE 1
#define COMPRESSION_STREAM_FINALIZE (1 << 0)

size_t compression_decode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size, void *scratch, compression_algorithm algo);
size_t compression_encode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size, void *scratch, compression_algorithm algo);
compression_status compression_stream_init(compression_stream *, int operation, compression_algorithm);
compression_status compression_stream_process(compression_stream *, int flags);
compression_status compression_stream_destroy(compression_stream *);

#endif
