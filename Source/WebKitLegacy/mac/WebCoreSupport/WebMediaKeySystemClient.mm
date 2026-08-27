/*
 * Copyright (C) 2021 Igalia S.L.
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

#import "WebMediaKeySystemClient.h"

#if ENABLE(ENCRYPTED_MEDIA)

#import <WebCore/MediaKeySystemRequest.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/TZoneMallocInlines.h>

// MAVERICKS_BACKPORT: for the per-origin media-keys salt made below.
#import <WebCore/Document.h>
#import <WebCore/SecurityOrigin.h>
#import <wtf/CryptographicallyRandomNumber.h>
#import <wtf/FileSystem.h>
#import <wtf/HexNumber.h>
#import <wtf/text/StringBuilder.h>

#if PLATFORM(MAC) && USE(GSTREAMER)
// MAVERICKS_BACKPORT: com.widevine.alpha runs on Google's own CDM, installed at runtime below.
#import <WebCore/WidevineCdmInstaller.h>
#import <WebCore/WidevineCdmLocation.h>
#endif

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebMediaKeySystemClient);

WebMediaKeySystemClient& WebMediaKeySystemClient::singleton()
{
    static NeverDestroyed<WebMediaKeySystemClient> client;
    return client;
}

// MAVERICKS_BACKPORT: the salt WebKit derives from the website data store, which WebKitLegacy does
// not have. An origin that keeps media-keys records keeps its salt in that same directory, so
// clearing the origin's media-keys data clears the identity the CDM built on it; an origin with
// nowhere to keep them -- an ephemeral session -- gets one that lasts as long as this process.
// Same shape as DeviceIdHashSaltStorage's: 48 hex digits of cryptographic randomness.
static constexpr auto deviceIdHashSaltFileName = "deviceIdHashSalt"_s;

static String createMediaKeysHashSalt()
{
    std::array<uint64_t, 3> randomData;
    cryptographicallyRandomValues(asWritableBytes(std::span<uint64_t> { randomData }));

    StringBuilder builder;
    builder.reserveCapacity(randomData.size() * 16);
    for (uint64_t number : randomData)
        builder.append(hex(number, 16, Lowercase));
    return builder.toString();
}

String WebMediaKeySystemClient::mediaKeysHashSalt(MediaKeySystemRequest& request)
{
    RefPtr document = request.document();
    if (!document)
        return { };

    auto directory = document->mediaKeysStorageDirectory();
    if (directory.isEmpty()) {
        return m_ephemeralMediaKeysHashSalts.ensure(document->securityOrigin().data().toString(), [] {
            return createMediaKeysHashSalt();
        }).iterator->value;
    }

    auto path = FileSystem::pathByAppendingComponent(directory, deviceIdHashSaltFileName);
    if (auto stored = FileSystem::readEntireFile(path); stored && !stored->isEmpty())
        return String::fromUTF8(stored->span());

    auto salt = createMediaKeysHashSalt();
    auto bytes = salt.utf8();
    FileSystem::overwriteEntireFile(path, byteCast<uint8_t>(bytes.span()));
    return salt;
}

void WebMediaKeySystemClient::requestMediaKeySystem(MediaKeySystemRequest& request)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS

    auto salt = mediaKeysHashSalt(request);

#if PLATFORM(MAC) && USE(GSTREAMER)
    // MAVERICKS_BACKPORT: Google's CDM is not redistributable, so it is installed at runtime the
    // first time a page needs it. This is where the page's request waits for it: WidevineCdm
    // answers requestMediaKeySystemAccess() from the module path, so the module has to be in
    // place before the request is allowed. WebKitLegacy loads it in this same process, so naming
    // it here is all it takes; a failed install denies the request, which the page sees as
    // NotSupportedError.
    if (request.keySystem() == "com.widevine.alpha"_s) {
        WidevineCdmInstaller::singleton().ensureModule([request = Ref { request }, salt = WTF::move(salt)](const std::optional<WidevineCdmModule>& module) mutable {
            if (!module) {
                request->deny();
                return;
            }
            setWidevineCdmModulePath(module->path);
            request->allow(WTF::move(salt));
        });
        return;
    }
#endif

    // MAVERICKS_BACKPORT: the salt travels with the grant, so a CDM has a per-origin identity to
    // key its own storage with.
    request.allow(WTF::move(salt));

    END_BLOCK_OBJC_EXCEPTIONS
}

#endif // ENABLE(ENCRYPTED_MEDIA)
