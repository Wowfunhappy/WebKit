#include "config.h"
#include "Encoder.h"
#include "NetworkProcessConnection.h"
#include "NetworkConnectionToWebProcessMessages.h"
#include "wk_symbols.h"
#include <cstdio>

static bool initializedAsNativeBundle;

extern "C" __attribute__((visibility("default"))) void WKBundleInitialize(const void*, const void*)
{
    initializedAsNativeBundle = true;
}

extern "C" __attribute__((visibility("default"))) int WKOriginAccessProbe(int operation, unsigned port, int expectsNativeBundle)
{
    if (initializedAsNativeBundle != !!expectsNativeBundle)
        return 102;
    wk_image image;
    if (!wk_find_image("/WebKit2.framework/Versions/A/WebKit2", &image))
        return 100;
    auto singleton = reinterpret_cast<void*(*)()>(wk_symbol_in_image(&image, "__ZN6WebKit10WebProcess9singletonEv"));
    auto network = reinterpret_cast<WebKit::NetworkProcessConnection&(*)(void*)>(wk_symbol_in_image(&image, "__ZN6WebKit10WebProcess30ensureNetworkProcessConnectionEv"));
    using Send = IPC::Error(*)(IPC::Connection*, WTF::UniqueRef<IPC::Encoder>&&, WTF::OptionSet<IPC::SendOption>, std::optional<WTF::ThreadQOS>);
    auto send = reinterpret_cast<Send>(wk_symbol_in_image(&image, "__ZN3IPC10Connection11sendMessageEON3WTF9UniqueRefINS_7EncoderEEENS1_9OptionSetINS_10SendOptionELNS1_14ConcurrencyTagE0EEENSt3__18optionalINS1_9ThreadQOSEEE"));
    auto encodeString = reinterpret_cast<void(*)(IPC::Encoder&, const WTF::String&)>(wk_symbol_in_image(&image, "__ZN3IPC13ArgumentCoderIN3WTF6StringEE6encodeINS_7EncoderEEEvRT_RKS2_"));
    if (!singleton || !network || !send || !encodeString)
        return 101;
    IPC::MessageName name = operation == 0 ? IPC::MessageName::NetworkConnectionToWebProcess_AddOriginAccessAllowListEntry
        : operation == 1 ? IPC::MessageName::NetworkConnectionToWebProcess_RemoveOriginAccessAllowListEntry
        : IPC::MessageName::NetworkConnectionToWebProcess_ResetOriginAccessAllowLists;
    auto encoder = WTF::makeUniqueRef<IPC::Encoder>(name, 0);
    if (operation != 2) {
        char source[80];
        std::snprintf(source, sizeof(source), "http://127.0.0.1:%u", port);
        encodeString(encoder.get(), WTF::String::fromUTF8(source));
        encodeString(encoder.get(), WTF::String::fromUTF8("http"));
        encodeString(encoder.get(), WTF::String::fromUTF8("localhost"));
        encoder.get() << false;
    }
    return static_cast<int>(send(&network(singleton()).connection(), WTF::move(encoder), { }, std::nullopt));
}
