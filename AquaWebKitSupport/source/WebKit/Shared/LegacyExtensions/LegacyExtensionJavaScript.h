// Installs LegacyExtensionAPI.js, the `browser` namespace of Safari 7 legacy extensions, into one JavaScript
// global object, and delivers router messages to it.

#pragma once

#include <JavaScriptCore/JSObjectRef.h>
#include <wtf/Forward.h>

namespace JSC {
class JSGlobalObject;
}

namespace WebKit::LegacyExtensions {

enum class ContextKind : bool { Host, Content };

// `nativeClass` supplies the functions LegacyExtensionAPI.js calls on its `native` argument; `nativeData`
// becomes the private data of that object and is released by the class's finalizer.
bool installAPI(JSC::JSGlobalObject&, ContextKind, JSClassRef nativeClass, void* nativeData);

// Hands one JSON message to the receiver installAPI stored on the global object. Returns false when the
// global object has none.
bool deliver(JSC::JSGlobalObject&, const String& message);

bool hasAPI(JSC::JSGlobalObject&);

// The JSON string argument of a native function, or a null String.
String stringArgument(JSContextRef, size_t argumentCount, const JSValueRef arguments[], size_t index);

} // namespace WebKit::LegacyExtensions
