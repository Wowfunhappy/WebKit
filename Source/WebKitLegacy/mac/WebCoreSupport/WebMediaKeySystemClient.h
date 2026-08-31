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

#if ENABLE(ENCRYPTED_MEDIA)

#import <WebCore/MediaKeySystemClient.h>
#import <wtf/TZoneMalloc.h>

// MAVERICKS_BACKPORT: for the per-origin media-keys salt this client keeps.
#import <wtf/HashMap.h>
#import <wtf/text/StringHash.h>
#import <wtf/text/WTFString.h>

class WebMediaKeySystemClient final : public WebCore::MediaKeySystemClient {
    WTF_MAKE_TZONE_ALLOCATED(WebMediaKeySystemClient);
public:
    static WebMediaKeySystemClient& NODELETE singleton();

    // Do nothing since this is a singleton object.
    void ref() const final { }
    void deref() const final { }

private:
    friend NeverDestroyed<WebMediaKeySystemClient>;
    WebMediaKeySystemClient() = default;

    void requestMediaKeySystem(WebCore::MediaKeySystemRequest&) override;
    void cancelMediaKeySystemRequest(WebCore::MediaKeySystemRequest&) override { }

    // MAVERICKS_BACKPORT: the salt a CDM derives its own per-origin, per-device storage identity
    // from. WebKit keeps it in the website data store (DeviceIdHashSaltStorage); this holds the
    // ones belonging to origins that have nowhere on disk to keep them.
    String mediaKeysHashSalt(WebCore::MediaKeySystemRequest&);

    HashMap<String, String> m_ephemeralMediaKeysHashSalts;
};

#endif // ENABLE(ENCRYPTED_MEDIA)
