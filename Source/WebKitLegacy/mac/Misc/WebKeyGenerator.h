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

// 10.9 / Safari-7 backport: WebKeyGenerator is the legacy WebKit.framework class
// that Safari 7.0.6 binds against (it sends +sharedGenerator and
// -addCertificatesToKeychainFromData:). It is the receiver Safari uses to import
// downloaded X.509 certificates (the application/x-x509-*-cert and
// application/pkcs7-mime download path) into the user's keychain. Modern WebKit
// removed this class along with the rest of legacy <keygen> support; this
// reconstructs the exact two-selector surface Safari requires.

#import <Foundation/Foundation.h>

@interface WebKeyGenerator : NSObject

+ (WebKeyGenerator *)sharedGenerator;

// Imports the certificate(s) contained in |data| (a single DER/PEM certificate
// or a PKCS#7 bundle, as delivered by the various x509/pkcs7 download MIME
// types) into the user's default keychain.
- (void)addCertificatesToKeychainFromData:(NSData *)data;

@end
