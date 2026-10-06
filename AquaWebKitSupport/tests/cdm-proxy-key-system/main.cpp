// Drives WebCore's GStreamer decryptor elements directly: each one is handed a drm-cdm-proxy context
// whose CDMProxy belongs to another key system, the way MediaPlayerPrivateGStreamer::cdmInstanceAttached
// hands one to an already-plugged decryptor when a page swaps MediaKeys mid-playback.
//
// A decryptor must refuse such a proxy and log "ignoring a <key system> CDM proxy". The ClearKey and
// Widevine decryptors are then made to decrypt one protected buffer and must fail with "CDMProxy was
// not retrieved in time", which is the element having kept no proxy, instead of decrypting through one
// cast to the wrong type.
//
// A timed check follows on webkitclearkey: a decrypt waiting for a proxy wakes as soon as setContext()
// delivers one. The proxy belongs to no CDMInstance (the state a proxy is left in once its MediaKeys
// are collected), so no key can ever reach it and the decrypt ends there, well inside the 5 s proxy
// wait, rather than waiting for a key.

#include "config.h"

#include "CDMProxy.h"
#include "GStreamerCommon.h"
#include <wtf/MainThread.h>
#include <gst/base/gstbasetransform.h>
#include <gst/gst.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace WebCore;

// WebCore exports none of the three functions below (upstream declares them without WEBCORE_EXPORT).
// The harness finds them in the symbol table of the WebCore image it runs against, as a debugger does.
static void* webCoreFunction(const char* symbol)
{
    for (uint32_t image = 0; image < _dyld_image_count(); ++image) {
        const char* path = _dyld_get_image_name(image);
        size_t length = strlen(path);
        if (length < sizeof("/WebCore") - 1 || strcmp(path + length - (sizeof("/WebCore") - 1), "/WebCore"))
            continue;
        auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(image));
        intptr_t slide = _dyld_get_image_vmaddr_slide(image);
        const segment_command_64* linkedit = nullptr;
        const symtab_command* symtab = nullptr;
        auto* command = reinterpret_cast<const load_command*>(header + 1);
        for (uint32_t i = 0; i < header->ncmds; ++i) {
            if (command->cmd == LC_SEGMENT_64 && !strcmp(reinterpret_cast<const segment_command_64*>(command)->segname, SEG_LINKEDIT))
                linkedit = reinterpret_cast<const segment_command_64*>(command);
            else if (command->cmd == LC_SYMTAB)
                symtab = reinterpret_cast<const symtab_command*>(command);
            command = reinterpret_cast<const load_command*>(reinterpret_cast<const char*>(command) + command->cmdsize);
        }
        if (!linkedit || !symtab)
            break;
        uintptr_t linkeditBase = slide + linkedit->vmaddr - linkedit->fileoff;
        auto* symbols = reinterpret_cast<const nlist_64*>(linkeditBase + symtab->symoff);
        auto* strings = reinterpret_cast<const char*>(linkeditBase + symtab->stroff);
        for (uint32_t i = 0; i < symtab->nsyms; ++i) {
            if (!(symbols[i].n_type & N_STAB) && (symbols[i].n_type & N_TYPE) == N_SECT && !strcmp(strings + symbols[i].n_un.n_strx, symbol))
                return reinterpret_cast<void*>(symbols[i].n_value + slide);
        }
    }
    printf("FAIL: %s is not in the symbol table of a loaded WebCore\n", symbol);
    exit(1);
}

namespace WebCore {

bool ensureGStreamerInitialized()
{
    static auto function = reinterpret_cast<bool (*)()>(webCoreFunction("__ZN7WebCore26ensureGStreamerInitializedEv"));
    return function();
}

void registerWebKitGStreamerElements()
{
    static auto function = reinterpret_cast<void (*)()>(webCoreFunction("__ZN7WebCore31registerWebKitGStreamerElementsEv"));
    function();
}

KeyStoreIDType keyStoreBaseNextID()
{
    static auto function = reinterpret_cast<KeyStoreIDType (*)()>(webCoreFunction("__ZN7WebCore18keyStoreBaseNextIDEv"));
    return function();
}

} // namespace WebCore

namespace {

// A proxy of a key system no decryptor here serves; only its key system is ever read.
class ForeignKeySystemProxy final : public CDMProxy {
public:
    explicit ForeignKeySystemProxy(const String& keySystem)
        : CDMProxy(keySystem) { }
};

std::mutex s_logLock;
std::vector<std::string> s_log;

void captureLog(GstDebugCategory* category, GstDebugLevel, const gchar*, const gchar*, gint, GObject*, GstDebugMessage* message, gpointer)
{
    std::lock_guard<std::mutex> locker(s_logLock);
    s_log.push_back(std::string(gst_debug_category_get_name(category)) + ": " + gst_debug_message_get(message));
}

bool logContains(const std::string& text)
{
    std::lock_guard<std::mutex> locker(s_logLock);
    for (auto& line : s_log) {
        if (line.find(text) != std::string::npos)
            return true;
    }
    return false;
}

void clearLog()
{
    std::lock_guard<std::mutex> locker(s_logLock);
    s_log.clear();
}

void setProxyContext(GstElement* element, CDMProxy* proxy)
{
    GRefPtr<GstContext> context = adoptGRef(gst_context_new("drm-cdm-proxy", FALSE));
    gst_structure_set(gst_context_writable_structure(context.get()), "cdm-proxy", G_TYPE_POINTER, proxy, nullptr);
    gst_element_set_context(element, context.get());
}

GstBuffer* protectedBuffer()
{
    GstBuffer* buffer = gst_buffer_new_allocate(nullptr, 32, nullptr);
    gst_buffer_memset(buffer, 0, 0xAB, 32);
    GstBuffer* keyID = gst_buffer_new_allocate(nullptr, 16, nullptr);
    gst_buffer_memset(keyID, 0, 0x11, 16);
    GstBuffer* iv = gst_buffer_new_allocate(nullptr, 8, nullptr);
    gst_buffer_memset(iv, 0, 0x22, 8);
    gst_buffer_add_protection_meta(buffer, gst_structure_new("application/x-cenc",
        "iv_size", G_TYPE_UINT, 8, "encrypted", G_TYPE_BOOLEAN, TRUE,
        "kid", GST_TYPE_BUFFER, keyID, "iv", GST_TYPE_BUFFER, iv,
        "subsample_count", G_TYPE_UINT, 0, nullptr));
    gst_buffer_unref(keyID);
    gst_buffer_unref(iv);
    return buffer;
}

// Decrypts one protected buffer and answers the error the element posted, if any.
std::string decryptOnce(GstElement* element)
{
    GRefPtr<GstBus> bus = adoptGRef(gst_bus_new());
    gst_element_set_bus(element, bus.get());
    if (gst_element_set_state(element, GST_STATE_PAUSED) == GST_STATE_CHANGE_FAILURE)
        return "could not reach PAUSED";

    GstBuffer* buffer = protectedBuffer();
    GstFlowReturn flow = GST_BASE_TRANSFORM_GET_CLASS(element)->transform_ip(GST_BASE_TRANSFORM(element), buffer);
    gst_buffer_unref(buffer);
    gst_element_set_state(element, GST_STATE_NULL);

    std::string result = std::string("flow=") + gst_flow_get_name(flow);
    if (GstMessage* message = gst_bus_pop_filtered(bus.get(), GST_MESSAGE_ERROR)) {
        GError* error = nullptr;
        gst_message_parse_error(message, &error, nullptr);
        result += std::string(" error=\"") + (error ? error->message : "") + "\"";
        g_clear_error(&error);
        gst_message_unref(message);
    }
    gst_element_set_bus(element, nullptr);
    return result;
}

struct TimedDecrypt {
    GstFlowReturn flow { GST_FLOW_OK };
    double seconds { 0 };
    std::string error;
};

// Runs one decrypt on its own thread, as a streaming thread would, while |steps| act on the element
// from this one; the last step is expected to end the decrypt.
TimedDecrypt decryptWhile(GstElement* element, const std::vector<std::function<void()>>& steps)
{
    GRefPtr<GstBus> bus = adoptGRef(gst_bus_new());
    gst_element_set_bus(element, bus.get());
    gst_element_set_state(element, GST_STATE_PAUSED);

    TimedDecrypt result;
    std::thread streaming([&] {
        GstBuffer* buffer = protectedBuffer();
        auto start = std::chrono::steady_clock::now();
        result.flow = GST_BASE_TRANSFORM_GET_CLASS(element)->transform_ip(GST_BASE_TRANSFORM(element), buffer);
        result.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        gst_buffer_unref(buffer);
    });
    for (auto& step : steps) {
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        step();
    }
    streaming.join();
    if (GstMessage* message = gst_bus_pop_filtered(bus.get(), GST_MESSAGE_ERROR)) {
        GError* error = nullptr;
        gst_message_parse_error(message, &error, nullptr);
        result.error = std::string(" error=\"") + (error ? error->message : "") + "\"";
        g_clear_error(&error);
        gst_message_unref(message);
    }

    GRefPtr<GstPad> sinkPad = adoptGRef(gst_element_get_static_pad(element, "sink"));
    gst_pad_send_event(sinkPad.get(), gst_event_new_flush_stop(TRUE));
    gst_element_set_state(element, GST_STATE_NULL);
    gst_element_set_bus(element, nullptr);
    return result;
}

int s_failures = 0;

void expect(bool condition, const std::string& description)
{
    printf("  %s  %s\n", condition ? "ok  " : "FAIL", description.c_str());
    fflush(stdout);
    if (!condition)
        ++s_failures;
}

} // namespace

int main()
{
    // The harness is an application process, as a WebKitLegacy host is, and sets up WTF's main thread
    // and main RunLoop as one does before WebCore runs.
    WTF::initializeMainThread();
    if (!ensureGStreamerInitialized()) {
        printf("FAIL: GStreamer did not initialize\n");
        return 1;
    }
    registerWebKitGStreamerElements();

    gst_debug_remove_log_function(gst_debug_log_default);
    gst_debug_add_log_function(captureLog, nullptr, nullptr);
    gst_debug_set_active(TRUE);
    for (const char* category : { "webkitclearkey", "webkitwidevine", "webkitwidevinevideodec", "webkitcenc" })
        gst_debug_set_threshold_for_name(category, GST_LEVEL_DEBUG);

    RefPtr<CDMProxy> clearKeyProxy = CDMProxyFactory::createCDMProxyForKeySystem("org.w3.clearkey"_s);
    if (!clearKeyProxy) {
        printf("FAIL: no ClearKey CDMProxy factory is registered\n");
        return 1;
    }
    auto widevineKeyedProxy = adoptRef(*new ForeignKeySystemProxy("com.widevine.alpha"_s));

    printf("### webkitclearkey: a ClearKey proxy, then a Widevine one (the MediaKeys swap)\n");
    {
        GRefPtr<GstElement> element = gst_element_factory_make("webkitclearkey", nullptr);
        expect(element, "webkitclearkey is registered");
        if (element) {
            clearLog();
            setProxyContext(element.get(), clearKeyProxy.get());
            expect(logContains("received new CDMInstance"), "the log hook sees the element take the context");
            expect(!logContains("ignoring a"), "its own key system's proxy is accepted");
            setProxyContext(element.get(), widevineKeyedProxy.ptr());
            bool refused = logContains("ignoring a com.widevine.alpha CDM proxy");
            expect(refused, "the Widevine proxy is refused");
            if (refused) {
                std::string result = decryptOnce(element.get());
                expect(result.find("CDMProxy was not retrieved in time") != std::string::npos, "a decrypt after the refusal finds no proxy: " + result);
            }
        }
    }

    printf("### webkitwidevine: a ClearKey proxy\n");
    {
        GRefPtr<GstElement> element = gst_element_factory_make("webkitwidevine", nullptr);
        expect(element, "webkitwidevine is registered");
        if (element) {
            clearLog();
            setProxyContext(element.get(), clearKeyProxy.get());
            expect(logContains("received new CDMInstance"), "the log hook sees the element take the context");
            bool refused = logContains("ignoring a org.w3.clearkey CDM proxy");
            expect(refused, "the ClearKey proxy is refused");
            if (refused) {
                std::string result = decryptOnce(element.get());
                expect(result.find("CDMProxy was not retrieved in time") != std::string::npos, "a decrypt after the refusal finds no proxy: " + result);
            }
        }
    }

    printf("### webkitwidevinevideodec: a ClearKey proxy\n");
    {
        GRefPtr<GstElement> element = gst_element_factory_make("webkitwidevinevideodec", nullptr);
        expect(element, "webkitwidevinevideodec is registered");
        if (element) {
            clearLog();
            setProxyContext(element.get(), clearKeyProxy.get());
            expect(logContains("attaching CDMProxy"), "the log hook sees the element take the context");
            expect(logContains("ignoring a org.w3.clearkey CDM proxy"), "the ClearKey proxy is refused");
        }
    }

    printf("### webkitclearkey: a proxy delivered to a decrypt waiting for one wakes it\n");
    {
        GRefPtr<GstElement> element = gst_element_factory_make("webkitclearkey", nullptr);
        auto decrypt = decryptWhile(element.get(), {
            [&] { setProxyContext(element.get(), clearKeyProxy.get()); },
        });
        char description[256];
        snprintf(description, sizeof(description), "the decrypt woke and ended on the instance-less proxy: %s after %.2f s%s",
            gst_flow_get_name(decrypt.flow), decrypt.seconds, decrypt.error.c_str());
        expect(decrypt.flow == GST_FLOW_NOT_SUPPORTED && decrypt.error.empty() && decrypt.seconds < 2.5, description);
    }

    printf(s_failures ? "### FAIL (%d)\n" : "### PASS\n", s_failures);
    return s_failures ? 1 : 0;
}
