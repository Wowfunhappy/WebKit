/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// A server reads the browser from its ClientHello as much as from its User-Agent: the cipher
// suites and their order, the groups, the signature algorithms, GREASE, and which extensions
// appear. These are the values behind the Safari version UserAgentMac.mm reports. The deps
// capability gate compiles this header too, and holds Safari's own bytes as its expectation.
#include <openssl/pool.h>
#include <openssl/ssl.h>
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>

#define COCOA_CURL_CIPHER_LIST \
    "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:" \
    "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305:" \
    "ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:" \
    "AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA:AES128-SHA:" \
    "ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:DES-CBC3-SHA"

// The encodings the transport decodes, in the order and spelling a browser advertises them.
#define COCOA_CURL_ACCEPT_ENCODING "gzip, deflate, br, zstd"

static inline int cocoaCurlDecompressCertificate(SSL *connection, CRYPTO_BUFFER **out, size_t size,
    const uint8_t *data, size_t length)
{
    uint8_t *bytes = NULL;
    CRYPTO_BUFFER *buffer;
    uLongf produced = (uLongf)size;
    (void)connection;
    buffer = CRYPTO_BUFFER_alloc(&bytes, size);
    if (!buffer)
        return 0;
    if (uncompress(bytes, &produced, data, (uLong)length) != Z_OK || produced != size) {
        CRYPTO_BUFFER_free(buffer);
        return 0;
    }
    *out = buffer;
    return 1;
}

// Returns one when every value reached the context.
static inline int cocoaCurlInstallClientHello(SSL_CTX *ssl)
{
    static const uint16_t cocoaCurlTLS13Ciphers[] = { SSL_CIPHER_AES_256_GCM_SHA384,
        SSL_CIPHER_CHACHA20_POLY1305_SHA256, SSL_CIPHER_AES_128_GCM_SHA256 };
    static const uint16_t cocoaCurlGroups[] = { SSL_GROUP_X25519_MLKEM768, SSL_GROUP_X25519,
        SSL_GROUP_SECP256R1, SSL_GROUP_SECP384R1, SSL_GROUP_SECP521R1 };
    // rsa_pss_rsae_sha384 appears twice, as it does in Safari's own advertisement.
    static const uint16_t cocoaCurlVerifyAlgorithms[] = { SSL_SIGN_ECDSA_SECP256R1_SHA256,
        SSL_SIGN_RSA_PSS_RSAE_SHA256, SSL_SIGN_RSA_PKCS1_SHA256, SSL_SIGN_ECDSA_SECP384R1_SHA384,
        SSL_SIGN_RSA_PSS_RSAE_SHA384, SSL_SIGN_RSA_PSS_RSAE_SHA384, SSL_SIGN_RSA_PKCS1_SHA384,
        SSL_SIGN_RSA_PSS_RSAE_SHA512, SSL_SIGN_RSA_PKCS1_SHA512, SSL_SIGN_RSA_PKCS1_SHA1 };
    if (!SSL_CTX_set_strict_cipher_list(ssl, COCOA_CURL_CIPHER_LIST))
        return 0;
    if (!SSL_CTX_set1_tls13_cipher_ids(ssl, cocoaCurlTLS13Ciphers,
            sizeof(cocoaCurlTLS13Ciphers) / sizeof(cocoaCurlTLS13Ciphers[0])))
        return 0;
    if (!SSL_CTX_set1_group_ids(ssl, cocoaCurlGroups,
            sizeof(cocoaCurlGroups) / sizeof(cocoaCurlGroups[0])))
        return 0;
    if (!SSL_CTX_set_repeated_verify_algorithm_prefs(ssl, cocoaCurlVerifyAlgorithms,
            sizeof(cocoaCurlVerifyAlgorithms) / sizeof(cocoaCurlVerifyAlgorithms[0])))
        return 0;
    if (!SSL_CTX_add_cert_compression_alg(ssl, TLSEXT_cert_compression_zlib, NULL,
            cocoaCurlDecompressCertificate))
        return 0;
    SSL_CTX_set_grease_enabled(ssl, 1);
    SSL_CTX_enable_ocsp_stapling(ssl);
    SSL_CTX_enable_signed_cert_timestamps(ssl);
    return 1;
}
