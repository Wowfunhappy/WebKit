/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

// WKAddCertificatesToKeychainFromData as 10.9's WebKit framework implements it. The data is decoded
// as a Netscape certificate sequence, a content-type OID followed by [0] EXPLICIT SEQUENCE OF
// certificates. Data that does not decode is one DER certificate. A sequence whose content type is
// PKCS #7 signed data is reported to the caller and not imported. Otherwise the certificates are
// imported in order up to, not including, the last, and the result is that of the last import made;
// a sequence of one certificate reports failure.

#import "WebKitSystemInterface.h"

#import <Security/SecAsn1Coder.h>
#import <Security/SecAsn1Templates.h>
#import <Security/Security.h>

ALLOW_DEPRECATED_DECLARATIONS_BEGIN

namespace {

struct NetscapeCertSequence {
    SecAsn1Oid contentType;
    SecAsn1Item** certs;
};

const SecAsn1Template netscapeCertSequenceTemplate[] = {
    { SEC_ASN1_SEQUENCE, 0, nullptr, sizeof(NetscapeCertSequence) },
    { SEC_ASN1_OBJECT_ID, offsetof(NetscapeCertSequence, contentType), nullptr, 0 },
    { SEC_ASN1_EXPLICIT | SEC_ASN1_CONSTRUCTED | SEC_ASN1_CONTEXT_SPECIFIC | 0, offsetof(NetscapeCertSequence, certs), kSecAsn1SequenceOfAnyTemplate, 0 },
    { 0, 0, nullptr, 0 },
};

// True when the certificate is in the default keychain afterwards, already there included.
bool addCertificateToKeychain(const void* bytes, unsigned length)
{
    CSSM_DATA data { length, static_cast<uint8_t*>(const_cast<void*>(bytes)) };
    SecCertificateRef certificate = nullptr;
    if (SecCertificateCreateFromData(&data, CSSM_CERT_X_509v3, CSSM_CERT_ENCODING_DER, &certificate))
        return false;
    OSStatus status = SecCertificateAddToKeychain(certificate, nullptr);
    CFRelease(certificate);
    return status == errSecSuccess || status == errSecDuplicateItem;
}

} // namespace

WKCertificateParseResult WKAddCertificatesToKeychainFromData(const void* bytes, unsigned length)
{
    SecAsn1CoderRef coder = nullptr;
    if (SecAsn1CoderCreate(&coder))
        return WKCertificateParseResultFailed;

    WKCertificateParseResult result = WKCertificateParseResultFailed;
    NetscapeCertSequence sequence { };
    if (SecAsn1Decode(coder, bytes, length, netscapeCertSequenceTemplate, &sequence))
        result = addCertificateToKeychain(bytes, length) ? WKCertificateParseResultSucceeded : WKCertificateParseResultFailed;
    else if (sequence.contentType.Length == CSSMOID_PKCS7_SignedData.Length && !memcmp(sequence.contentType.Data, CSSMOID_PKCS7_SignedData.Data, sequence.contentType.Length))
        result = WKCertificateParseResultPKCS7;
    else {
        unsigned count = 0;
        while (sequence.certs && sequence.certs[count])
            ++count;
        for (unsigned i = 0; i + 1 < count; ++i)
            result = addCertificateToKeychain(sequence.certs[i]->Data, sequence.certs[i]->Length) ? WKCertificateParseResultSucceeded : WKCertificateParseResultFailed;
    }

    SecAsn1CoderRelease(coder);
    return result;
}

ALLOW_DEPRECATED_DECLARATIONS_END
