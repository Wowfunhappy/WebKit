// The SecTrustSerialize / SecTrustDeserialize polyfills (polyfills/c/Security.c): the blob carries the
// certificates the sender's trust was CREATED with, read without evaluating it. 10.9's public accessors
// report the evaluated chain and evaluate to produce it -- three certificates in, one out -- so a
// serializer built on them would ship a subset and pay a full evaluation per call.
//
// The chain here is three system anchors under an SSL policy: distinct real certificates with no
// on-disk fixture, and a chain the evaluator collapses to a single certificate, which is what makes
// "three on the wire" distinguishable from "the evaluated chain on the wire".
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <mach/mach_time.h>
#include <stdio.h>

extern CFDataRef SecTrustSerialize(SecTrustRef, CFErrorRef *);
extern SecTrustRef SecTrustDeserialize(CFDataRef, CFErrorRef *);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static double milliseconds(uint64_t from, uint64_t to)
{
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom)
        mach_timebase_info(&timebase);
    return (double)(to - from) * timebase.numer / timebase.denom / 1e6;
}

static CFIndex certificatesOnWire(CFDataRef blob)
{
    CFDictionaryRef state = (CFDictionaryRef)CFPropertyListCreateWithData(NULL, blob, kCFPropertyListImmutable, NULL, NULL);
    CFArrayRef certificates = state ? (CFArrayRef)CFDictionaryGetValue(state, CFSTR("certificates")) : NULL;
    CFIndex count = certificates ? CFArrayGetCount(certificates) : -1;
    if (state)
        CFRelease(state);
    return count;
}

static bool sameDER(SecCertificateRef a, SecCertificateRef b)
{
    if (!a || !b)
        return false;
    CFDataRef da = SecCertificateCopyData(a), db = SecCertificateCopyData(b);
    bool same = da && db && CFEqual(da, db);
    if (da)
        CFRelease(da);
    if (db)
        CFRelease(db);
    return same;
}

static SecTrustRef trustWith(CFTypeRef certificates, SecPolicyRef policy)
{
    SecTrustRef trust = NULL;
    SecTrustCreateWithCertificates(certificates, policy, &trust);
    return trust;
}

int main(void)
{
    CFArrayRef anchors = NULL;
    SecTrustCopyAnchorCertificates(&anchors);
    if (!anchors || CFArrayGetCount(anchors) < 3) {
        printf("Security-trust-serialize: fewer than three system anchors to build a chain from\n");
        return 1;
    }
    const void *chain[3] = { CFArrayGetValueAtIndex(anchors, 0), CFArrayGetValueAtIndex(anchors, 1), CFArrayGetValueAtIndex(anchors, 2) };
    CFArrayRef inputs = CFArrayCreate(NULL, chain, 3, &kCFTypeArrayCallBacks);
    SecCertificateRef leaf = (SecCertificateRef)chain[0];
    SecPolicyRef policy = SecPolicyCreateSSL(true, CFSTR("example.org"));

    // A fresh trust: the blob carries all three inputs, and producing it costs no evaluation.
    SecTrustRef trust = trustWith(inputs, policy);
    CFErrorRef error = NULL;
    double serializeCost = 1e9;
    CFDataRef blob = NULL;
    for (int i = 0; i < 5; ++i) {
        if (blob)
            CFRelease(blob);
        uint64_t before = mach_absolute_time();
        blob = SecTrustSerialize(trust, &error);
        uint64_t after = mach_absolute_time();
        if (milliseconds(before, after) < serializeCost)
            serializeCost = milliseconds(before, after);
    }
    check(blob && !error, "a fresh trust serializes");
    check(certificatesOnWire(blob) == 3, "the blob carries the three input certificates");

    SecTrustResultType result = kSecTrustResultInvalid;
    uint64_t before = mach_absolute_time();
    SecTrustEvaluate(trust, &result);
    double evaluateCost = milliseconds(before, mach_absolute_time());
    CFIndex evaluatedCount = SecTrustGetCertificateCount(trust);
    printf("  serialize %.3fms (best of 5), evaluate %.3fms, evaluated chain has %ld certificate(s)\n",
        serializeCost, evaluateCost, (long)evaluatedCount);
    check(evaluatedCount < 3, "the evaluator keeps fewer than the inputs, so the wire count is not its answer");
    check(serializeCost * 4 < evaluateCost, "serializing cost less than a quarter of an evaluation");

    // The same trust, evaluated: still the inputs, not the chain the evaluator kept.
    CFDataRef afterEvaluation = SecTrustSerialize(trust, &error);
    check(afterEvaluation && certificatesOnWire(afterEvaluation) == 3, "an evaluated trust still serializes its three inputs");

    // The receiver gets the sender's leaf and the sender's question.
    SecTrustRef back = SecTrustDeserialize(blob, &error);
    check(back && !error, "the blob deserializes");
    check(back && sameDER(SecTrustGetCertificateAtIndex(back, 0), leaf), "the receiver's leaf is the sender's leaf");
    CFArrayRef policies = NULL;
    CFIndex policyCount = back && SecTrustCopyPolicies(back, &policies) == errSecSuccess && policies ? CFArrayGetCount(policies) : -1;
    CFDictionaryRef properties = policyCount == 1 ? SecPolicyCopyProperties((SecPolicyRef)CFArrayGetValueAtIndex(policies, 0)) : NULL;
    CFStringRef name = properties ? (CFStringRef)CFDictionaryGetValue(properties, kSecPolicyName) : NULL;
    check(policyCount == 1, "the receiver has the one policy the sender had");
    check(name && CFStringGetLength(name) == 11 && CFEqual(name, CFSTR("example.org")), "the hostname arrives unterminated");

    // A trust made from a bare certificate rather than an array.
    SecTrustRef bare = trustWith(leaf, policy);
    CFDataRef bareBlob = SecTrustSerialize(bare, &error);
    check(bareBlob && certificatesOnWire(bareBlob) == 1, "a trust created from a bare certificate serializes that certificate");

    // The refusals: no trust, and no blob.
    error = NULL;
    check(!SecTrustSerialize(NULL, &error) && error && CFErrorGetCode(error) == errSecParam, "a NULL trust is refused with errSecParam");
    error = NULL;
    check(!SecTrustDeserialize(NULL, &error) && error && CFErrorGetCode(error) == errSecParam, "a NULL blob is refused with errSecParam");

    if (failures) {
        printf("Security-trust-serialize: %d check(s) FAILED\n", failures);
        return 1;
    }
    printf("Security-trust-serialize: all checks passed\n");
    return 0;
}
