// compression.c - Apple libcompression (10.11+), absent on 10.9 in its entirety
// (/usr/lib/libcompression.dylib does not exist).
//
// The streaming API is implemented over the in-tree Brotli codec (libbrotlidec/libbrotlienc, already
// vendored for WOFF2), for COMPRESSION_BROTLI only — the sole algorithm WebKit requests from
// libcompression (Modules/compression, the web CompressionStream/DecompressionStream 'br' format;
// the zlib formats go through <zlib.h> directly). Requesting any other algorithm fails
// compression_stream_init with COMPRESSION_STATUS_ERROR, which is a defined outcome of the real API,
// not a fake success: callers see "initialization failed" exactly as they would for a bad argument.
//
// Contract implemented (Apple's documented streaming semantics, correct for any caller):
//   - process() consumes src_ptr/src_size and fills dst_ptr/dst_size, advancing all four fields.
//   - decode returns COMPRESSION_STATUS_END as soon as the compressed stream is complete, leaving
//     any trailing input unconsumed in src_size.
//   - decode with COMPRESSION_STREAM_FINALIZE on a truncated stream returns COMPRESSION_STATUS_ERROR.
//   - encode returns COMPRESSION_STATUS_END only once FINALIZE has flushed everything.
//   - COMPRESSION_STATUS_OK otherwise (needs more input, or dst is full — the caller grows dst).

#include "wk_polyfill.h"

#include <compression.h>
#include <stdlib.h>
#include <string.h>

#include <brotli/decode.h>
#include <brotli/encode.h>

typedef struct {
    compression_stream_operation operation;
    BrotliEncoderState* encoder;
    BrotliDecoderState* decoder;
    int decoderFinished;
} WKBrotliCompressionState;

WK_POLYFILL_ABSENT("/usr/lib/libcompression.dylib", compression_status, compression_stream_init,
                   (compression_stream* stream, compression_stream_operation operation, compression_algorithm algorithm),
                   (stream, operation, algorithm))
{
    if (!stream || algorithm != COMPRESSION_BROTLI)
        return COMPRESSION_STATUS_ERROR;
    if (operation != COMPRESSION_STREAM_ENCODE && operation != COMPRESSION_STREAM_DECODE)
        return COMPRESSION_STATUS_ERROR;

    WKBrotliCompressionState* state = calloc(1, sizeof(WKBrotliCompressionState));
    if (!state)
        return COMPRESSION_STATUS_ERROR;
    state->operation = operation;
    if (operation == COMPRESSION_STREAM_ENCODE)
        state->encoder = BrotliEncoderCreateInstance(NULL, NULL, NULL);
    else
        state->decoder = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (!state->encoder && !state->decoder) {
        free(state);
        return COMPRESSION_STATUS_ERROR;
    }

    stream->dst_ptr = NULL;
    stream->dst_size = 0;
    stream->src_ptr = NULL;
    stream->src_size = 0;
    stream->state = state;
    return COMPRESSION_STATUS_OK;
}

WK_POLYFILL_ABSENT("/usr/lib/libcompression.dylib", compression_status, compression_stream_process,
                   (compression_stream* stream, int flags),
                   (stream, flags))
{
    if (!stream || !stream->state)
        return COMPRESSION_STATUS_ERROR;
    WKBrotliCompressionState* state = (WKBrotliCompressionState*)stream->state;

    if (state->operation == COMPRESSION_STREAM_ENCODE) {
        BrotliEncoderOperation op = (flags & COMPRESSION_STREAM_FINALIZE) ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS;
        size_t availableIn = stream->src_size;
        const uint8_t* nextIn = stream->src_ptr;
        size_t availableOut = stream->dst_size;
        uint8_t* nextOut = stream->dst_ptr;
        if (!BrotliEncoderCompressStream(state->encoder, op, &availableIn, &nextIn, &availableOut, &nextOut, NULL))
            return COMPRESSION_STATUS_ERROR;
        stream->src_ptr = nextIn;
        stream->src_size = availableIn;
        stream->dst_ptr = nextOut;
        stream->dst_size = availableOut;
        if ((flags & COMPRESSION_STREAM_FINALIZE) && !availableIn && BrotliEncoderIsFinished(state->encoder))
            return COMPRESSION_STATUS_END;
        return COMPRESSION_STATUS_OK;
    }

    // Decode. A finished Brotli decoder cannot be driven again: answer from the recorded end state,
    // treating further input as the error the real API reports for garbage past the stream.
    if (state->decoderFinished)
        return stream->src_size ? COMPRESSION_STATUS_ERROR : COMPRESSION_STATUS_END;

    BrotliDecoderResult result = BrotliDecoderDecompressStream(state->decoder,
        &stream->src_size, &stream->src_ptr, &stream->dst_size, &stream->dst_ptr, NULL);
    switch (result) {
    case BROTLI_DECODER_RESULT_SUCCESS:
        state->decoderFinished = 1;
        return COMPRESSION_STATUS_END;
    case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
        // All input consumed mid-stream: truncated if the caller says this was the final call.
        return (flags & COMPRESSION_STREAM_FINALIZE) ? COMPRESSION_STATUS_ERROR : COMPRESSION_STATUS_OK;
    case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
        return COMPRESSION_STATUS_OK;
    case BROTLI_DECODER_RESULT_ERROR:
    default:
        return COMPRESSION_STATUS_ERROR;
    }
}

WK_POLYFILL_ABSENT("/usr/lib/libcompression.dylib", compression_status, compression_stream_destroy,
                   (compression_stream* stream),
                   (stream))
{
    if (!stream || !stream->state)
        return COMPRESSION_STATUS_ERROR;
    WKBrotliCompressionState* state = (WKBrotliCompressionState*)stream->state;
    if (state->encoder)
        BrotliEncoderDestroyInstance(state->encoder);
    if (state->decoder)
        BrotliDecoderDestroyInstance(state->decoder);
    free(state);
    stream->state = NULL;
    return COMPRESSION_STATUS_OK;
}
