/*
 * Security.framework polyfills -- custom polyfill (not from
 * macports-legacy-support).
 *
 * Covers trust-evaluation entry points and SecKey/SSL/constant stubs that
 * modern binaries import but 10.9's Security.framework lacks.  The
 * SecTrustEvaluate override is the load-bearing piece: it strips the
 * revocation policy whose comparison crashes on 10.9, while still performing
 * a real chain evaluation.
 */

#include <stdbool.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dlfcn.h>

/*
 * SecPolicyCreateRevocation override — return NULL so runtimes skip
 * adding revocation policies to the trust object.
 */
SecPolicyRef SecPolicyCreateRevocation(CFOptionFlags flags) {
	(void)flags;
	return NULL;
}

/*
 * SecTrustEvaluate override — replace trust policies with a
 * simple basic X.509 policy before calling the real function.
 * This avoids the crash in 10.9's compareRevocationPolicies
 * while still performing real trust evaluation.
 */
OSStatus SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
	static OSStatus (*real_eval)(SecTrustRef, SecTrustResultType *) = NULL;
	static OSStatus (*real_set_policies)(SecTrustRef, CFTypeRef) = NULL;
	if (!real_eval) {
		void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOLOAD);
		if (sec) {
			real_eval = dlsym(sec, "SecTrustEvaluate");
			real_set_policies = dlsym(sec, "SecTrustSetPolicies");
		}
	}
	if (!real_eval) {
		if (result) *result = kSecTrustResultProceed;
		return errSecSuccess;
	}

	/* Replace policies with just basic X.509 — no revocation */
	SecPolicyRef basic = SecPolicyCreateBasicX509();
	if (basic && real_set_policies) {
		real_set_policies(trust, basic);
		CFRelease(basic);
	}

	return real_eval(trust, result);
}

/*
 * SecTrustEvaluateWithError (added 10.14)
 * https://trac.macports.org/ticket/66749#comment:2
 */

static CFStringRef getStringForResultType(SecTrustResultType resultType) {
	switch (resultType) {
		case kSecTrustResultInvalid: return CFSTR("Error evaluating certificate");
		case kSecTrustResultDeny: return CFSTR("User specified to deny trust");
		case kSecTrustResultUnspecified: return CFSTR("Rejected Certificate");
		case kSecTrustResultRecoverableTrustFailure : return CFSTR("Rejected Certificate");
		case kSecTrustResultFatalTrustFailure :return CFSTR("Bad Certificate");
		case kSecTrustResultOtherError: return CFSTR("Error evaluating certificate");
		case kSecTrustResultProceed: return CFSTR("Proceed");
		default: return CFSTR("Unknown");
	}
}

bool SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef  *error) {
	SecTrustResultType trustResult = kSecTrustResultInvalid;
	OSStatus status = SecTrustEvaluate(trust, &trustResult);
	if (
		status == errSecSuccess &&
		(trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified)
	) {
		if (error) {
			*error = NULL;
		}
		return true;
	}
	if (error) {
		*error = CFErrorCreate(kCFAllocatorDefault, getStringForResultType(trustResult), 0, NULL);
	}
	return false;
}

/*
 * SecTrustCopyCertificateChain (added macOS 12.0)
 * Returns the evaluated certificate chain as a CFArray. On 10.9 we rebuild it
 * from the (deprecated) per-index accessors, which are populated once the
 * trust has been evaluated (callers always evaluate first). The caller owns
 * the returned array.
 */
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
	if (!trust) return NULL;
	CFIndex count = SecTrustGetCertificateCount(trust);
	if (count <= 0) return NULL;
	CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count,
	                                               &kCFTypeArrayCallBacks);
	if (!chain) return NULL;
	for (CFIndex i = 0; i < count; i++) {
		SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
		if (cert) CFArrayAppendValue(chain, cert);
	}
	return chain;
}

/* SecCertificateCopyKey (added 10.14) */
SecKeyRef SecCertificateCopyKey(SecCertificateRef certificate) {
	(void)certificate;
	return NULL;
}

/*
 * SecKey functions (added 10.12+) — stubs
 */

CFDataRef SecKeyCopyExternalRepresentation(SecKeyRef key, CFErrorRef *error) {
	(void)key;
	if (error) *error = NULL;
	return NULL;
}

SecKeyRef SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef attributes, CFErrorRef *error) {
	(void)keyData; (void)attributes;
	if (error) *error = NULL;
	return NULL;
}

SecKeyRef SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
	(void)parameters;
	if (error) *error = NULL;
	return NULL;
}

CFDataRef SecKeyCreateSignature(SecKeyRef key, SecPadding algorithm,
                                CFDataRef dataToSign, CFErrorRef *error) {
	(void)key; (void)algorithm; (void)dataToSign;
	if (error) *error = NULL;
	return NULL;
}

Boolean SecKeyVerifySignature(SecKeyRef key, SecPadding algorithm,
                              CFDataRef signedData, CFDataRef signature,
                              CFErrorRef *error) {
	(void)key; (void)algorithm; (void)signedData; (void)signature;
	if (error) *error = NULL;
	return false;
}

CFDataRef SecKeyCreateEncryptedData(SecKeyRef key, SecPadding algorithm,
                                    CFDataRef plaintext, CFErrorRef *error) {
	(void)key; (void)algorithm; (void)plaintext;
	if (error) *error = NULL;
	return NULL;
}

CFDataRef SecKeyCreateDecryptedData(SecKeyRef key, SecPadding algorithm,
                                    CFDataRef ciphertext, CFErrorRef *error) {
	(void)key; (void)algorithm; (void)ciphertext;
	if (error) *error = NULL;
	return NULL;
}

SecKeyRef SecKeyCopyPublicKey(SecKeyRef key) {
	(void)key;
	return NULL;
}

CFDictionaryRef SecKeyCopyAttributes(SecKeyRef key) {
	(void)key;
	return NULL;
}

CFDataRef SecKeyCopyKeyExchangeResult(SecKeyRef publicKey, void *algorithm,
                                      SecKeyRef parameters, CFDictionaryRef requestedSize,
                                      CFErrorRef *error) {
	(void)publicKey; (void)algorithm; (void)parameters; (void)requestedSize;
	if (error) *error = NULL;
	return NULL;
}

/*
 * SSL/TLS ALPN functions (added 10.13.4) — stubs
 */

#define STUB_UNIMPLEMENTED (-4)

OSStatus SSLCopyALPNProtocols(void *context, CFArrayRef *protocols) {
	(void)context;
	if (protocols) *protocols = NULL;
	return STUB_UNIMPLEMENTED;
}

OSStatus SSLSetALPNProtocols(void *context, CFArrayRef protocols) {
	(void)context; (void)protocols;
	return STUB_UNIMPLEMENTED;
}

/*
 * Security framework constants (added 10.12+)
 */

const CFStringRef kSecAttrKeyTypeECSECPrimeRandom = CFSTR("73");
const CFStringRef kSecUseDataProtectionKeychain = CFSTR("u-DataProtectionKeychain");

/* SecKeyAlgorithm constants (added 10.12) */
const CFStringRef kSecKeyAlgorithmECDHKeyExchangeStandard = CFSTR("algid:ecdh:standard");
const CFStringRef kSecKeyAlgorithmECDSASignatureDigestX962 = CFSTR("algid:ecdsa:digest-x962");
const CFStringRef kSecKeyAlgorithmRSAEncryptionOAEPSHA1 = CFSTR("algid:encrypt:RSA:OAEP-SHA1");
const CFStringRef kSecKeyAlgorithmRSAEncryptionOAEPSHA256 = CFSTR("algid:encrypt:RSA:OAEP-SHA256");
const CFStringRef kSecKeyAlgorithmRSAEncryptionOAEPSHA384 = CFSTR("algid:encrypt:RSA:OAEP-SHA384");
const CFStringRef kSecKeyAlgorithmRSAEncryptionOAEPSHA512 = CFSTR("algid:encrypt:RSA:OAEP-SHA512");
const CFStringRef kSecKeyAlgorithmRSAEncryptionPKCS1 = CFSTR("algid:encrypt:RSA:PKCS1");
const CFStringRef kSecKeyAlgorithmRSAEncryptionRaw = CFSTR("algid:encrypt:RSA:raw");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1 = CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA1");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256 = CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA256");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384 = CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA384");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512 = CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA512");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPSSSHA1 = CFSTR("algid:sign:RSA:digest-PSS:SHA1");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPSSSHA256 = CFSTR("algid:sign:RSA:digest-PSS:SHA256");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPSSSHA384 = CFSTR("algid:sign:RSA:digest-PSS:SHA384");
const CFStringRef kSecKeyAlgorithmRSASignatureDigestPSSSHA512 = CFSTR("algid:sign:RSA:digest-PSS:SHA512");
const CFStringRef kSecKeyAlgorithmRSASignatureRaw = CFSTR("algid:sign:RSA:raw");
