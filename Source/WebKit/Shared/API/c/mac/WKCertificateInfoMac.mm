/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WKCertificateInfoMac.h"

// MAVERICKS_BACKPORT: restored the whole file — upstream gutted every function to return
// null when it deleted the deprecated WKCertificateInfo C API. Safari 7 reads the chain
// off the main frame's certificate info on every commit to drive the address-bar lock and
// the Show Certificate sheet, and wraps the client-certificate panel's chosen identity in
// a chain-created WKCertificateInfo (#103).
#import "APICertificateInfo.h"
#import "WKAPICast.h"
#import <Security/Security.h>
#import <WebCore/Credential.h>
#import <wtf/RetainPtr.h>

namespace API {

Ref<CertificateInfo> CertificateInfo::create(CFArrayRef certificateChain)
{
    // The chain may lead with a SecIdentityRef (client-certificate flow); SecTrust wants
    // certificates only, so substitute the identity's certificate when building the trust
    // but preserve the caller's array verbatim for WKCertificateInfoGetCertificateChain.
    RetainPtr<CFMutableArrayRef> certificates = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
    CFIndex count = certificateChain ? CFArrayGetCount(certificateChain) : 0;
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(certificateChain, i);
        if (CFGetTypeID(value) == SecIdentityGetTypeID()) {
            SecCertificateRef certificate = nullptr;
            // No CFTypeTrait exists for Sec types, so cast plainly; the type ID check above guards it.
            if (SecIdentityCopyCertificate(static_cast<SecIdentityRef>(const_cast<void*>(value)), &certificate) == errSecSuccess && certificate)
                CFArrayAppendValue(certificates.get(), adoptCF(certificate).get());
        } else if (CFGetTypeID(value) == SecCertificateGetTypeID())
            CFArrayAppendValue(certificates.get(), value);
    }

    WebCore::CertificateInfo coreCertificateInfo;
    if (CFArrayGetCount(certificates.get())) {
        RetainPtr<SecPolicyRef> policy = adoptCF(SecPolicyCreateSSL(true, nullptr));
        SecTrustRef trust = nullptr;
        if (SecTrustCreateWithCertificates(certificates.get(), policy.get(), &trust) == errSecSuccess && trust)
            coreCertificateInfo = WebCore::CertificateInfo(adoptCF(trust));
    }

    Ref<CertificateInfo> certificateInfo = adoptRef(*new CertificateInfo(coreCertificateInfo));
    if (certificateChain)
        certificateInfo->m_certificateChain = certificateChain;
    return certificateInfo;
}

CFArrayRef CertificateInfo::certificateChain() const
{
    if (!m_certificateChain) {
        if (const RetainPtr<SecTrustRef>& trust = m_certificateInfo.trust())
            m_certificateChain = WebCore::CertificateInfo::certificateChainFromSecTrust(trust.get());
    }
    return m_certificateChain.get();
}

} // namespace API

namespace WebKit {

WebCore::Credential credentialWithCertificateInfo(API::CertificateInfo* certificateInfo)
{
    if (!certificateInfo)
        return { };

    CFArrayRef chain = certificateInfo->certificateChain();
    CFIndex count = chain ? CFArrayGetCount(chain) : 0;
    if (!count)
        return { };

    // Safari 7 passes the client-certificate panel's selection as an identity-first chain;
    // fall back to looking the identity up in the keychain when given certificates only.
    RetainPtr<SecIdentityRef> identity;
    CFIndex firstCertificateIndex = 0;
    CFTypeRef first = CFArrayGetValueAtIndex(chain, 0);
    if (CFGetTypeID(first) == SecIdentityGetTypeID()) {
        // No CFTypeTrait exists for Sec types, so cast plainly; the type ID checks guard these.
        identity = static_cast<SecIdentityRef>(const_cast<void*>(first));
        firstCertificateIndex = 1;
    } else if (CFGetTypeID(first) == SecCertificateGetTypeID()) {
        SecIdentityRef foundIdentity = nullptr;
        if (SecIdentityCreateWithCertificate(nullptr, static_cast<SecCertificateRef>(const_cast<void*>(first)), &foundIdentity) == errSecSuccess)
            identity = adoptCF(foundIdentity);
    }
    if (!identity)
        return { };

    RetainPtr<NSMutableArray> intermediates = adoptNS([[NSMutableArray alloc] init]);
    for (CFIndex i = firstCertificateIndex; i < count; ++i)
        [intermediates addObject:(__bridge id)CFArrayGetValueAtIndex(chain, i)];

    RetainPtr<NSURLCredential> credential = [NSURLCredential credentialWithIdentity:identity.get() certificates:([intermediates count] ? intermediates.get() : nil) persistence:NSURLCredentialPersistenceForSession];
    return WebCore::Credential(credential.get());
}

} // namespace WebKit

WKCertificateInfoRef WKCertificateInfoCreateWithServerTrust(SecTrustRef serverTrust)
{
    // MAVERICKS_BACKPORT: upstream gutted this to null.
    // return nullptr;
    return WebKit::toAPILeakingRef(API::CertificateInfo::create(WebCore::CertificateInfo(retainPtr(serverTrust))));
}

WKCertificateInfoRef WKCertificateInfoCreateWithCertficateChain(CFArrayRef certificateChain)
{
    // MAVERICKS_BACKPORT: upstream gutted this to null.
    // return nullptr;
    return WebKit::toAPILeakingRef(API::CertificateInfo::create(certificateChain));
}

CFArrayRef WKCertificateInfoGetCertificateChain(WKCertificateInfoRef certificateInfoRef)
{
    // MAVERICKS_BACKPORT: upstream gutted this to null. Guarded because Safari 7 can hold
    // a null WKCertificateInfoRef from a frame that has not committed.
    // return nullptr;
    if (!certificateInfoRef)
        return nullptr;
    return WebKit::toImpl(certificateInfoRef)->certificateChain();
}

SecTrustRef WKCertificateInfoGetServerTrust(WKCertificateInfoRef certificateInfoRef)
{
    // MAVERICKS_BACKPORT: upstream gutted this to null.
    // return nullptr;
    if (!certificateInfoRef)
        return nullptr;
    return WebKit::toImpl(certificateInfoRef)->certificateInfo().trust().get();
}
