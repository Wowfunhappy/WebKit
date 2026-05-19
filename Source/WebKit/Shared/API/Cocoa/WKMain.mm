// Restored for macOS 10.9 WebContent XPC service
#import "config.h"
#import "WKMain.h"

#import <xpc/xpc.h>
#import <stdio.h>
#import <unistd.h>

namespace WebKit {
int XPCServiceMain(int argc, const char** argv);
}

int WKXPCServiceMain(int argc, const char** argv)
{
    return WebKit::XPCServiceMain(argc, argv);
}

// 10.9 backport: the system /System/Library/PrivateFrameworks/WebKit2.framework Networking
// xpc service stub looks up `WebKitEntryPoint` via CFBundleGetFunctionPointerForName on bundle
// "com.apple.WebKit2" and calls it with (connection, initializerMessage). Provide that entry
// point so the legacy stub can dispatch into modern WebKit. Loaded via dlsym(RTLD_DEFAULT)
// fallback in CFBundleGetFunctionPointerForName when the system WebKit2 binary fails to
// resolve it (because that binary is the OLD 10.9 WebKit2 — its symbols don't match modern).
extern "C" void NetworkServiceInitializer(xpc_connection_t, xpc_object_t);
extern "C" void WebContentServiceInitializer(xpc_connection_t, xpc_object_t);

extern "C" __attribute__((visibility("default")))
void WebKitEntryPoint(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    // 10.9 perf: removed debug fopen logging

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
