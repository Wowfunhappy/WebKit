// MAVERICKS_BACKPORT: file restored/rewritten for the macOS 10.9 WebContent XPC service; upstream
// routes through push/PCM daemon entry points that don't exist on 10.9.
// MAVERICKS_BACKPORT: include the raw xpc/stdio/unistd headers used by the 10.9 entry point instead
// of the upstream daemon-entry-point headers (PCMDaemonEntryPoint.h / WebPush*Main.h).
#import "config.h"
#import "WKMain.h"

#import <xpc/xpc.h>
#import <stdio.h>
#import <unistd.h>

// MAVERICKS_BACKPORT: forward-declare XPCServiceMain instead of pulling in XPCServiceEntryPoint.h.
namespace WebKit {
int XPCServiceMain(int argc, const char** argv);
}

int WKXPCServiceMain(int argc, const char** argv)
{
    return WebKit::XPCServiceMain(argc, argv);
}

// MAVERICKS_BACKPORT: the system /System/Library/PrivateFrameworks/WebKit2.framework Networking
// xpc service stub looks up `WebKitEntryPoint` via CFBundleGetFunctionPointerForName on bundle
// "com.apple.WebKit2" and calls it with (connection, initializerMessage). Provide that entry
// point so the legacy stub can dispatch into modern WebKit. Loaded via dlsym(RTLD_DEFAULT)
// fallback in CFBundleGetFunctionPointerForName when the system WebKit2 binary fails to
// resolve it (because that binary is the OLD 10.9 WebKit2 — its symbols don't match modern).
extern "C" void NetworkServiceInitializer(xpc_connection_t, xpc_object_t);
extern "C" void WebContentServiceInitializer(xpc_connection_t, xpc_object_t);

// MAVERICKS_BACKPORT: WebKitEntryPoint exported so the legacy WebKit2 xpc service stub can
// dispatch into modern WebKit (see block comment above).
extern "C" __attribute__((visibility("default")))
void WebKitEntryPoint(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    // MAVERICKS_BACKPORT, 10.9 perf: removed debug fopen logging

    // MAVERICKS_BACKPORT: dispatch the legacy WebKit2 entry point by service name to the
    // modern Network/WebContent service initializers.
    const char* serviceName = nullptr;
    if (initializerMessage)
        serviceName = xpc_dictionary_get_string(initializerMessage, "service-name");
    if (!serviceName)
        serviceName = "";
    // 10.9 perf: removed debug fopen logging

    if (strstr(serviceName, "Networking"))
        NetworkServiceInitializer(connection, initializerMessage);
    else if (strstr(serviceName, "WebContent"))
        WebContentServiceInitializer(connection, initializerMessage);
    else {
        // 10.9 perf: removed debug fopen logging
        NetworkServiceInitializer(connection, initializerMessage);
    }
}
