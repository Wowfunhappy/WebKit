/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Apple Inc. ("Apple") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: this file does not exist in the base; it reconstructs the legacy
// WebKeyGenerator class (+sharedGenerator / -addCertificatesToKeychainFromData:) that Safari
// 7.0.6 binds against to import downloaded X.509/PKCS#7 certificates into the keychain. Modern
// WebKit removed it with the rest of legacy <keygen> support, so it is provided here for the 10.9 build.

#import "WebKeyGenerator.h"

#import "WebKitLogging.h"

// SecItemImport / SecKeychainCopyDefault live in the (10.9-era) keychain APIs.
// They are marked deprecated in newer SDKs but are fully present and functional
// on macOS 10.9, which is the only platform this framework ships on.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <Security/SecImportExport.h>
#import <Security/SecKeychain.h>

@implementation WebKeyGenerator

+ (WebKeyGenerator *)sharedGenerator
{
    static WebKeyGenerator *sharedGenerator = [[WebKeyGenerator alloc] init];
    return sharedGenerator;
}

- (void)addCertificatesToKeychainFromData:(NSData *)data
{
    if (![data length])
        return;

    // Let Security auto-detect the wire format (single DER/PEM certificate or a
    // PKCS#7 bundle) and the item type, matching how Safari delivers the bytes
    // from the various x509/pkcs7 certificate-download MIME handlers.
    SecExternalFormat format = kSecFormatUnknown;
    SecExternalItemType itemType = kSecItemTypeUnknown;
    CFArrayRef outItems = NULL;

    SecKeychainRef keychain = NULL;
    if (SecKeychainCopyDefault(&keychain) != errSecSuccess)
        keychain = NULL;

    SecItemImportExportKeyParameters params;
    memset(&params, 0, sizeof(params));
    params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;

    OSStatus status = SecItemImport(static_cast<CFDataRef>(data), NULL, &format, &itemType, 0, &params, keychain, &outItems);
    if (status != errSecSuccess)
        LOG_ERROR("WebKeyGenerator: failed to import certificate data into keychain (OSStatus %d)", static_cast<int>(status));

    if (outItems)
        CFRelease(outItems);
    if (keychain)
        CFRelease(keychain);
}

@end

#pragma clang diagnostic pop
