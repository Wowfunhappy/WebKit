// GLib's default main context, iterated from the main CFRunLoop.
//
// The GStreamer ports iterate the default GMainContext as the main thread's event loop, and GSources
// attached to it (bus signal watches, gst_bus_add_watch) are served there. A Cocoa main thread runs a
// CFRunLoop instead, so the context is driven through GLib's external-loop protocol from that run loop.

#pragma once

namespace WebCore {

// Callable from any thread; the context is attached to the main run loop once.
void attachGLibMainContextToMainRunLoop();

} // namespace WebCore
