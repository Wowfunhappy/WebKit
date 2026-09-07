/*
 * Copyright (C) 2024-2025 Apple Inc. All rights reserved.
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
#import "CoreIPCNSURLCredential.h"

#import <pal/spi/cf/CFNetworkSPI.h>
// MAVERICKS_BACKPORT: the owning keychain file comes from Security.
#import <Security/SecKeychain.h>
#include <limits.h>

@interface NSURLCredential(WKSecureCoding)
- (NSDictionary *)_webKitPropertyListData;
- (instancetype)_initWithWebKitPropertyListData:(NSDictionary *)plist;
@end

#define SET_MDATA(NAME, CLASS, WRAPPER)     \
    id NAME = dict[@#NAME];                 \
    if ([NAME isKindOfClass:CLASS.class]) { \
        auto var = WRAPPER(NAME);           \
        m_data.NAME = WTF::move(var);         \
    }

namespace WebKit {

#if HAVE(WK_SECURE_CODING_NSURLCREDENTIAL)
CoreIPCNSURLCredential::CoreIPCNSURLCredential(NSURLCredential *credential)
{
    // MAVERICKS_BACKPORT: pass the selected key's persistent item reference and public certificate DER.
    // Mavericks' SecItem identity queries depend on the search list; the native item reference
    // identifies the owning keychain directly, including keys that cannot be exported.
    if (auto identity = credential.identity) {
        SecKeyRef privateKey = nullptr;
        if (SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess) {
            auto key = adoptCF(privateKey);
            m_data.privateKeyReference.emplace(reinterpret_cast<SecKeychainItemRef>(key.get()));
            // MAVERICKS_BACKPORT: persistent references identify the key but do not authorize
            // a sandboxed recipient to read a file-backed keychain's CSSM metadata.
            SecKeychainRef rawKeychain = nullptr;
            if (SecKeychainItemCopyKeychain(reinterpret_cast<SecKeychainItemRef>(key.get()), &rawKeychain) == errSecSuccess) {
                auto keychain = adoptCF(rawKeychain);
                char path[PATH_MAX];
                UInt32 length = sizeof(path);
                if (SecKeychainGetPath(keychain.get(), &length, path) == errSecSuccess) {
                    m_keychainAccess = SandboxExtension::createHandle(String::fromUTF8(std::span { path, length }), SandboxExtension::Type::ReadOnly);
                    if (!m_keychainAccess)
                        m_data.privateKeyReference.reset();
                }
            }
        }
        SecCertificateRef leaf = nullptr;
        if (SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess) {
            auto certificate = adoptCF(leaf);
            auto bytes = adoptCF(SecCertificateCopyData(certificate.get()));
            if (bytes)
                m_data.certificates.append(CoreIPCSecCertificate(WTF::move(bytes)));
        }
        for (id certificate in credential.certificates) {
            if (CFGetTypeID((__bridge CFTypeRef)certificate) == SecCertificateGetTypeID()) {
                auto bytes = adoptCF(SecCertificateCopyData((__bridge SecCertificateRef)certificate));
                if (bytes)
                    m_data.certificates.append(CoreIPCSecCertificate(WTF::move(bytes)));
            }
        }
    }
    auto dict = [credential _webKitPropertyListData];

    NSNumber *persistence = dict[@"persistence"];
    if ([persistence isKindOfClass:NSNumber.class]) {
        switch ([persistence unsignedCharValue]) {
        case kCFURLCredentialPersistenceNone:
            m_data.persistence = CoreIPCNSURLCredentialPersistence::None;
            break;
        case kCFURLCredentialPersistenceForSession:
            m_data.persistence = CoreIPCNSURLCredentialPersistence::Session;
            break;
        case kCFURLCredentialPersistencePermanent:
            m_data.persistence = CoreIPCNSURLCredentialPersistence::Permanent;
            break;
        case kCFURLCredentialPersistenceSynchronizable:
            m_data.persistence = CoreIPCNSURLCredentialPersistence::Synchronizable;
            break;
        default:
            ASSERT_NOT_REACHED();
            m_data.persistence = CoreIPCNSURLCredentialPersistence::None;
            break;
        }
    }
    SET_MDATA(user, NSString, CoreIPCString);
    SET_MDATA(password, NSString, CoreIPCString);

    NSDictionary *attributes = dict[@"attributes"];
    if ([attributes isKindOfClass:NSDictionary.class]) {
        Vector<CoreIPCNSURLCredentialData::Attributes> vector;
        vector.reserveCapacity(attributes.count);
        for (id key in attributes) {
            if (![key isKindOfClass:NSString.class]) {
                ASSERT_NOT_REACHED();
                break;
            }
            id value = [attributes objectForKey:key];
            if (![value isKindOfClass:NSString.class] || ![value isKindOfClass:NSNumber.class] || ![value isKindOfClass:NSDate.class]) {
                ASSERT_NOT_REACHED();
                break;
            }
            std::optional<Variant<CoreIPCNumber, CoreIPCString, CoreIPCDate>> option;
            if ([value isKindOfClass:NSString.class])
                option = CoreIPCString(value);
            if ([value isKindOfClass:NSNumber.class])
                option = CoreIPCNumber(value);
            if ([value isKindOfClass:NSDate.class])
                option = CoreIPCDate(value);
            if (option) {
                auto k = CoreIPCString(key);
                vector.append(std::make_pair(WTF::move(k), WTF::move(*option)));
            }
        }
        m_data.attributes = WTF::move(vector);
    }

    SET_MDATA(identifier, NSString, CoreIPCString);

    NSNumber *useKeychain = dict[@"useKeychain"];
    if ([useKeychain isKindOfClass:NSNumber.class])
        m_data.useKeychain = [useKeychain boolValue];

    // MAVERICKS_BACKPORT: clang-22 demands the bridge for a CF_BRIDGED_TYPE cast under ARC.
    // SecTrustRef secTrust = static_cast<SecTrustRef>(dict[@"trust"]);
    SecTrustRef secTrust = (__bridge SecTrustRef)dict[@"trust"];
    if (secTrust && CFGetTypeID(secTrust) == SecTrustGetTypeID())
        m_data.trust = CoreIPCSecTrust(secTrust);

    SET_MDATA(service, NSString, CoreIPCString);

    NSDictionary *flags = dict[@"flags"];
    if ([flags isKindOfClass:NSDictionary.class]) {
        Vector<WebKit::CoreIPCNSURLCredentialData::Flags> vector;
        vector.reserveCapacity(flags.count);
        for (NSString *key in attributes) {
            if (![key isKindOfClass:NSString.class]) {
                ASSERT_NOT_REACHED();
                break;
            }
            NSString *value = [flags objectForKey:key];
            if (![value isKindOfClass:NSString.class]) {
                ASSERT_NOT_REACHED();
                break;
            }
            auto k = CoreIPCString(key);
            auto v = CoreIPCString(value);
            vector.append(std::make_pair(WTF::move(k), WTF::move(v)));
        }
        m_data.flags = WTF::move(vector);
    }

    SET_MDATA(uuid, NSString, CoreIPCString);
    SET_MDATA(appleID, NSString, CoreIPCString);
    SET_MDATA(realm, NSString, CoreIPCString);
    SET_MDATA(token, NSString, CoreIPCString);

    NSNumber *type = dict[@"type"];
    if ([type isKindOfClass:NSNumber.class]) {
        switch ([type intValue]) {
        case kURLCredentialInternetPassword:
            m_data.type = CoreIPCNSURLCredentialType::Password;
            break;
        case kURLCredentialServerTrust:
            m_data.type = CoreIPCNSURLCredentialType::ServerTrust;
            break;
        case kURLCredentialKerberosTicket:
            m_data.type = CoreIPCNSURLCredentialType::KerberosTicket;
            break;
        case kURLCredentialXMobileMeAuthToken:
            m_data.type = CoreIPCNSURLCredentialType::XMobileMeAuthToken;
            break;
        case kURLCredentialOAuth2:
            m_data.type = CoreIPCNSURLCredentialType::OAuth2;
            break;
        case kURLCredentialClientCertificate:
            m_data.type = CoreIPCNSURLCredentialType::ClientCertificate;
            break;
        default:
            ASSERT_NOT_REACHED();
            m_data.type = CoreIPCNSURLCredentialType::Password;
            break;
        }
    }
}

// MAVERICKS_BACKPORT: decode the credential and the file capability together.
/*
CoreIPCNSURLCredential::CoreIPCNSURLCredential(CoreIPCNSURLCredentialData&& data)
    : m_data(WTF::move(data)) { }
*/ // MAVERICKS_BACKPORT: retain the upstream constructor beside capability-aware decoding.
CoreIPCNSURLCredential::CoreIPCNSURLCredential(CoreIPCNSURLCredentialData&& data, std::optional<SandboxExtension::Handle>&& keychainAccess)
    : m_data(WTF::move(data))
    , m_keychainAccess(WTF::move(keychainAccess)) { }

RetainPtr<id> CoreIPCNSURLCredential::toID() const
{
    auto dict = adoptNS([[NSMutableDictionary alloc] initWithCapacity:7]);

    RetainPtr<NSNumber> persistence;
    switch (m_data.persistence) {
    case CoreIPCNSURLCredentialPersistence::None:
        persistence = @(kCFURLCredentialPersistenceNone);
        break;
    case CoreIPCNSURLCredentialPersistence::Session:
        persistence = @(kCFURLCredentialPersistenceForSession);
        break;
    case CoreIPCNSURLCredentialPersistence::Permanent:
        persistence = @(kCFURLCredentialPersistencePermanent);
        break;
    case CoreIPCNSURLCredentialPersistence::Synchronizable:
        persistence = @(kCFURLCredentialPersistenceSynchronizable);
        break;
    default:
        ASSERT_NOT_REACHED();
        persistence = @(kCFURLCredentialPersistenceNone);
        break;
    }
    [dict setObject:persistence.get() forKey:@"persistence"];

    switch (m_data.type) {
    case CoreIPCNSURLCredentialType::Password:
        [dict setObject:@(kURLCredentialInternetPassword) forKey:@"type"];
        if (m_data.user)
            [dict setObject:(*m_data.user).toID().get() forKey:@"user"];
        if (m_data.password)
            [dict setObject:(*m_data.password).toID().get() forKey:@"password"];
        if (m_data.attributes) {
            RetainPtr attributes = adoptNS([[NSMutableDictionary alloc] initWithCapacity:(*m_data.attributes).size()]);
            for (auto& attributePair : *m_data.attributes) {
                RetainPtr<id> value;
                WTF::switchOn(attributePair.second,
                    [&] (const CoreIPCNumber& n) {
                        value = n.toID();
                    },
                    [&] (const CoreIPCString& s) {
                        value = s.toID();
                    },
                    [&] (const CoreIPCDate& d) {
                        value = d.toID();
                    }
                );
                [attributes setObject:attributes.get() forKey:attributePair.first.toID().get()];
            }
            [dict setObject:attributes.get() forKey:@"attributes"];
        }
        if (m_data.identifier)
            [dict setObject:(*m_data.identifier).toID().get() forKey:@"identifier"];
        if (m_data.useKeychain)
            [dict setObject:[NSNumber numberWithBool:(*m_data.useKeychain)] forKey:@"useKeychain"];
        break;
    case CoreIPCNSURLCredentialType::ServerTrust: {
        RetainPtr<SecTrustRef> trust = m_data.trust.createSecTrust();
        if (trust) {
            [dict setObject:@(kURLCredentialServerTrust) forKey:@"type"];
            // MAVERICKS_BACKPORT: clang-22 demands the bridge for a CF_BRIDGED_TYPE cast under ARC.
            // [dict setObject:(id)trust.get() forKey:@"trust"];
            [dict setObject:(__bridge id)trust.get() forKey:@"trust"];
        }
        break;
    }
    case CoreIPCNSURLCredentialType::KerberosTicket:
        [dict setObject:@(kURLCredentialKerberosTicket) forKey:@"type"];
        if (m_data.user)
            [dict setObject:(*m_data.user).toID().get() forKey:@"user"];
        if (m_data.service)
            [dict setObject:(*m_data.service).toID().get() forKey:@"service"];
        if (m_data.uuid)
            [dict setObject:(*m_data.uuid).toID().get() forKey:@"uuid"];
        if (m_data.flags) {
            auto flags = adoptNS([[NSMutableDictionary alloc] initWithCapacity:(*m_data.flags).size()]);
            for (auto& flagPair : *m_data.flags)
                [flags setObject: flagPair.second.toID().get() forKey:flagPair.first.toID().get()];
            [dict setObject:flags.get() forKey:@"flags"];
        }
        break;
    // MAVERICKS_BACKPORT: reconstruct the selected keychain identity directly, including non-exportable keys.
    /*
    case CoreIPCNSURLCredentialType::ClientCertificate:
        [dict setObject:@(kURLCredentialClientCertificate) forKey:@"type"];
        break;
    */ // MAVERICKS_BACKPORT: the keychain-backed client identity is reconstructed below.
    case CoreIPCNSURLCredentialType::ClientCertificate: {
        if (!m_data.privateKeyReference || m_data.certificates.isEmpty())
            return nullptr;
        // MAVERICKS_BACKPORT: Security keys can outlive this transient IPC wrapper in
        // credential storage and TLS signing jobs. The selected-file grant lasts for
        // the receiving process, while native key ACLs continue to authorize signing.
        if (m_keychainAccess) {
            auto access = *m_keychainAccess;
            if (!SandboxExtension::consumePermanently(access))
                return nullptr;
        }
        auto key = m_data.privateKeyReference->createSecKeychainItem();
        if (!key)
            return nullptr;
        if (CFGetTypeID(key.get()) != SecKeyGetTypeID())
            return nullptr;
        auto leaf = m_data.certificates[0].createSecCertificate();
        if (!leaf)
            return nullptr;
        // MAVERICKS_BACKPORT: SecIdentityCreate pairs the leaf with the key its persistent reference resolved to.
        auto identity = adoptCF(SecIdentityCreate(nullptr, leaf.get(), reinterpret_cast<SecKeyRef>(key.get())));
        if (!identity)
            return nullptr;
        auto certificates = adoptNS([[NSMutableArray alloc] init]);
        for (auto& encoded : m_data.certificates) {
            auto certificate = encoded.createSecCertificate();
            if (!certificate)
                return nullptr;
            [certificates addObject:(__bridge id)certificate.get()];
        }
        return [NSURLCredential credentialWithIdentity:identity.get() certificates:certificates.get() persistence:static_cast<NSURLCredentialPersistence>(static_cast<unsigned>(m_data.persistence) - 1)];
    }
    case CoreIPCNSURLCredentialType::XMobileMeAuthToken:
        [dict setObject:@(kURLCredentialXMobileMeAuthToken) forKey:@"type"];
        if (m_data.appleID)
            [dict setObject:(*m_data.appleID).toID().get() forKey:@"appleid"];
        if (m_data.password)
            [dict setObject:(*m_data.password).toID().get() forKey:@"password"];
        if (m_data.realm)
            [dict setObject:(*m_data.realm).toID().get() forKey:@"realm"];
        break;
    case CoreIPCNSURLCredentialType::OAuth2:
        [dict setObject:@(kURLCredentialOAuth2) forKey:@"type"];
        if (m_data.token)
            [dict setObject:(*m_data.token).toID().get() forKey:@"token"];
        if (m_data.realm)
            [dict setObject:(*m_data.realm).toID().get() forKey:@"realm"];
        break;
    default:
        ASSERT_NOT_REACHED();
        break;
    }

    return adoptNS([[NSURLCredential alloc] _initWithWebKitPropertyListData:dict.get()]);
}
#endif

} // namespace WebKit

#undef SET_MDATA
