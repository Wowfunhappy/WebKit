#!/usr/bin/env python3
"""Deterministic decoded-body fixture for curl's asynchronous pause/replay path."""
import argparse
import ctypes
import gzip
import http.server
import pathlib
import zlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18987)
    parser.add_argument('--brotli-library', type=pathlib.Path, required=True)
    args = parser.parse_args()
    def byte_at(index):
        value = index % 16384
        value = ((value ^ (value >> 16)) * 0x7feb352d) & 0xffffffff
        value = ((value ^ (value >> 15)) * 0x846ca68b) & 0xffffffff
        return (value ^ (value >> 16)) & 0xff
    # A non-aligned decoded prefix followed by a repeated dictionary forces
    # decompression output across multiple curl input and pause buffers.
    body = bytes(byte_at(index) for index in range(16384)) * 64
    library = ctypes.CDLL(str(args.brotli_library.resolve()))
    compress = library.BrotliEncoderCompress
    compress.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_size_t,
                         ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p]
    compress.restype = ctypes.c_int
    encoded = ctypes.create_string_buffer(len(body) + 1024)
    length = ctypes.c_size_t(len(encoded))
    if not compress(5, 22, 0, len(body), body, ctypes.byref(length), encoded):
        raise RuntimeError('Brotli fixture encoding failed')
    responses = {'identity': body, 'gzip': gzip.compress(body),
                 'deflate': zlib.compress(body), 'br': encoded.raw[:length.value]}

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def do_GET(self):
            encoding = self.path.removeprefix('/')
            if encoding not in responses:
                self.send_error(404)
                return
            data = responses[encoding]
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Encoding', encoding)
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            self.wfile.write(data)

    print({encoding: len(data) for encoding, data in responses.items()}, flush=True)
    http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
