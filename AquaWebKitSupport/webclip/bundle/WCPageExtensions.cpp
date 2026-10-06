#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>
#include <wtf/text/WTFString.h>

#include "WCPageExtensions.h"

#include <JavaScriptCore/JSStringRefCF.h>
#include <JavaScriptCore/JavaScript.h>
#include <WebKit/WKArray.h>
#include <WebKit/WKBundle.h>
#include <WebKit/WKBundleFrame.h>
#include <WebKit/WKBundlePage.h>
#include <WebKit/WKBundleScriptWorld.h>
#include <WebKit/WKDictionary.h>
#include <WebKit/WKMutableDictionary.h>
#include <WebKit/WKRetainPtr.h>
#include <WebKit/WKSerializedScriptValue.h>
#include <WebKit/WKString.h>
#include <WebKit/WKStringCF.h>
#include <WebCore/LocalFrame.h>
#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <memory>

namespace WebClip {

static constexpr auto messageFromContent = "WebClipSafariMessage";
static constexpr auto canLoadFromContent = "WebClipSafariCanLoad";
static constexpr auto messageToContent = "WebClipSafariMessage";

static WKBundleRef extensionsBundle;

static String stringFromWK(WKTypeRef value)
{
    if (!value || WKGetTypeID(value) != WKStringGetTypeID())
        return { };
    return String(adoptCF(WKStringCopyCFString(kCFAllocatorDefault, static_cast<WKStringRef>(value))).get());
}

static WKRetainPtr<WKStringRef> wkString(const String& string)
{
    return adoptWK(WKStringCreateWithCFString(string.createCFString().get()));
}

// A message crosses as a dictionary: its description, JSON text, and the extension's message, a structured
// clone as Safari's are. A content script's message also carries its page, which reaches the plug-in as the
// page's WKPageRef.
static constexpr auto descriptionKey = "description";
static constexpr auto messageKey = "message";
static constexpr auto pageKey = "page";

static WKRetainPtr<WKMutableDictionaryRef> messageBody(const String& description, WKSerializedScriptValueRef message, WKBundlePageRef page)
{
    auto body = adoptWK(WKMutableDictionaryCreate());
    WKDictionarySetItem(body.get(), wkString(String::fromLatin1(descriptionKey)).get(), wkString(description).get());
    WKDictionarySetItem(body.get(), wkString(String::fromLatin1(messageKey)).get(), message);
    WKDictionarySetItem(body.get(), wkString(String::fromLatin1(pageKey)).get(), page);
    return body;
}

static WKTypeRef messageBodyItem(WKTypeRef body, const char* key)
{
    if (!body || WKGetTypeID(body) != WKDictionaryGetTypeID())
        return nullptr;
    return WKDictionaryGetItemForKey(static_cast<WKDictionaryRef>(body), wkString(String::fromLatin1(key)).get());
}

static WKSerializedScriptValueRef serializedValue(WKTypeRef value)
{
    return value && WKGetTypeID(value) == WKSerializedScriptValueGetTypeID() ? static_cast<WKSerializedScriptValueRef>(value) : nullptr;
}

static JSValueRef deserialize(WKSerializedScriptValueRef message, JSContextRef context)
{
    JSValueRef value = message ? WKSerializedScriptValueDeserialize(message, context, nullptr) : nullptr;
    return value ? value : JSValueMakeUndefined(context);
}

// The plug-in names an extension's content world after the extension's files' root,
// safari-extension://<key>/<token>/, the base URI its content gets.
static String rootOfWorld(WKBundleScriptWorldRef world)
{
    auto root = stringFromWK(adoptWK(WKBundleScriptWorldCopyName(world)).get());
    return root.startsWith("safari-extension://"_s) ? root : String();
}

void initializeExtensions(WKBundleRef bundle)
{
    extensionsBundle = bundle;
}

static void forEachFrame(WKBundleFrameRef frame, NOESCAPE const Function<void(WKBundleFrameRef)>& function)
{
    function(frame);
    auto children = adoptWK(WKBundleFrameCopyChildFrames(frame));
    for (size_t index = 0; children && index < WKArrayGetSize(children.get()); ++index)
        forEachFrame(static_cast<WKBundleFrameRef>(WKArrayGetItemAtIndex(children.get(), index)), function);
}

static JSValueRef jsString(JSContextRef context, const String& string)
{
    auto jsString = JSStringCreateWithCFString(string.createCFString().get());
    JSValueRef value = JSValueMakeString(context, jsString);
    JSStringRelease(jsString);
    return value;
}

// The function that receives an extension's messages in a frame's context in the extension's world, which
// the bundle holds until the frame has another such context or goes away.
struct Receiver {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(Receiver);
    WTF_MAKE_NONCOPYABLE(Receiver);
public:
    Receiver(WKBundlePageRef page, JSGlobalContextRef context, JSObjectRef function)
        : page(page)
        , context(JSGlobalContextRetain(context))
        , function(function)
    {
        JSValueProtect(context, function);
    }
    ~Receiver()
    {
        JSValueUnprotect(context, function);
        JSGlobalContextRelease(context);
    }

    WKBundlePageRef page;
    JSGlobalContextRef context;
    JSObjectRef function;
};

// By frame, then by the extension's root.
static HashMap<WKBundleFrameRef, HashMap<String, std::unique_ptr<Receiver>>>& receivers()
{
    static NeverDestroyed<HashMap<WKBundleFrameRef, HashMap<String, std::unique_ptr<Receiver>>>> receivers;
    return receivers;
}

// A message the extension's pages dispatched to the page reaches the receiver of each of its frames' contexts
// in the extension's world.
static void deliverToPage(WKBundlePageRef page, const String& root, const String& name, WKSerializedScriptValueRef message)
{
    forEachFrame(WKBundlePageGetMainFrame(page), [&](WKBundleFrameRef frame) {
        auto frameReceivers = receivers().find(frame);
        if (frameReceivers == receivers().end())
            return;
        // A context whose document the frame has navigated away from has no frame.
        auto* receiver = frameReceivers->value.get(root);
        if (!receiver || !WebCore::LocalFrame::fromJSContext(receiver->context))
            return;
        JSValueRef arguments[] = { jsString(receiver->context, name), deserialize(message, receiver->context) };
        JSObjectCallAsFunction(receiver->context, receiver->function, nullptr, 2, arguments, nullptr);
    });
}

void extensionsDidRemoveFrameFromHierarchy(WKBundleFrameRef frame)
{
    receivers().remove(frame);
}

void extensionsWillDestroyPage(WKBundlePageRef page)
{
    receivers().removeIf([&](auto& entry) {
        entry.value.removeIf([&](auto& receiver) {
            return receiver.value->page == page;
        });
        return entry.value.isEmpty();
    });
}

bool extensionsDidReceiveMessageToPage(WKBundlePageRef page, WKStringRef name, WKTypeRef body)
{
    if (!WKStringIsEqualToUTF8CString(name, messageToContent))
        return false;
    auto value = JSON::Value::parseJSON(stringFromWK(messageBodyItem(body, descriptionKey)));
    RefPtr description = value ? value->asObject() : nullptr;
    if (description)
        deliverToPage(page, description->getString("root"_s), description->getString("name"_s), serializedValue(messageBodyItem(body, messageKey)));
    return true;
}

// The native object the content API calls: it knows its extension by its root.
struct ContentNative {
    String root;
};

static String argumentString(JSContextRef context, size_t argumentCount, const JSValueRef arguments[], size_t index)
{
    if (index >= argumentCount || !JSValueIsString(context, arguments[index]))
        return { };
    auto string = JSValueToStringCopy(context, arguments[index], nullptr);
    RetainPtr cfString = adoptCF(JSStringCopyCFString(kCFAllocatorDefault, string));
    JSStringRelease(string);
    return String(cfString.get());
}

// The message as the plug-in receives it: the extension, the message's name and the message, from the page
// whose frame's context it comes from.
static WKRetainPtr<WKMutableDictionaryRef> messageFromContext(JSContextRef context, const ContentNative& native, const String& name, WKSerializedScriptValueRef message)
{
    auto description = JSON::Object::create();
    description->setString("root"_s, native.root);
    description->setString("name"_s, name);
    WKBundleFrameRef frame = WKBundleFrameForJavaScriptContext(context);
    return messageBody(description->toJSONString(), message, frame ? WKBundleFrameGetPage(frame) : nullptr);
}

// The extension's message as a structured clone; a value that cannot be cloned throws, as in Safari.
static WKRetainPtr<WKSerializedScriptValueRef> serializeArgument(JSContextRef context, size_t argumentCount, const JSValueRef arguments[], size_t index, JSValueRef* exception)
{
    JSValueRef value = index < argumentCount ? arguments[index] : JSValueMakeUndefined(context);
    return adoptWK(WKSerializedScriptValueCreate(context, value, exception));
}

// post(name, message): a message to the extension's pages.
static JSValueRef contentPost(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception)
{
    auto* native = static_cast<ContentNative*>(JSObjectGetPrivate(thisObject));
    auto name = argumentString(context, argumentCount, arguments, 0);
    if (!native || name.isNull())
        return JSValueMakeUndefined(context);
    auto message = serializeArgument(context, argumentCount, arguments, 1, exception);
    if (message)
        WKBundlePostMessage(extensionsBundle, wkString(String::fromLatin1(messageFromContent)).get(), messageFromContext(context, *native, name, message.get()).get());
    return JSValueMakeUndefined(context);
}

// canLoad(message): the message the extension's pages answer a canLoad message with, which the content
// script waits on.
static JSValueRef contentCanLoad(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception)
{
    auto* native = static_cast<ContentNative*>(JSObjectGetPrivate(thisObject));
    if (!native)
        return JSValueMakeUndefined(context);
    auto message = serializeArgument(context, argumentCount, arguments, 0, exception);
    if (!message)
        return JSValueMakeUndefined(context);
    WKTypeRef reply = nullptr;
    WKBundlePostSynchronousMessage(extensionsBundle, wkString(String::fromLatin1(canLoadFromContent)).get(), messageFromContext(context, *native, "canLoad"_s, message.get()).get(), &reply);
    JSValueRef value = deserialize(serializedValue(reply), context);
    if (reply)
        WKRelease(reply);
    return value;
}

static void contentFinalize(JSObjectRef object)
{
    delete static_cast<ContentNative*>(JSObjectGetPrivate(object));
}

static JSClassRef contentNativeClass()
{
    static JSClassRef nativeClass = [] {
        static const JSStaticFunction functions[] = {
            { "post", contentPost, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "canLoad", contentCanLoad, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { nullptr, nullptr, 0 },
        };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "WebClipSafariContent";
        definition.staticFunctions = functions;
        definition.finalize = contentFinalize;
        return JSClassCreate(&definition);
    }();
    return nativeClass;
}

// Safari 7's content API, given the native object and the extension's base URI; returns the function that
// receives the extension's messages.
static constexpr auto contentAPISource = R"JS((function (native, baseURI) {
"use strict";
const listenersKey = Symbol("listeners");
class SafariEventTarget {
    constructor() {
        this[listenersKey] = [];
    }
    addEventListener(type, listener, useCapture) {
        if (typeof listener !== "function" && !(listener && typeof listener.handleEvent === "function"))
            return;
        const capture = !!useCapture;
        if (!this[listenersKey].some(entry => entry.type === type && entry.listener === listener && entry.capture === capture))
            this[listenersKey].push({ type: String(type), listener, capture });
    }
    removeEventListener(type, listener, useCapture) {
        const capture = !!useCapture;
        const index = this[listenersKey].findIndex(entry => entry.type === type && entry.listener === listener && entry.capture === capture);
        if (index !== -1)
            this[listenersKey].splice(index, 1);
    }
}
const dispatch = (target, properties) => {
    let stopped = false;
    const event = Object.assign({
        target,
        currentTarget: target,
        eventPhase: 2,
        bubbles: true,
        cancelable: true,
        defaultPrevented: false,
        timeStamp: Date.now(),
        stopPropagation() { stopped = true; },
        preventDefault() { this.defaultPrevented = true; },
    }, properties);
    for (const { type, listener } of target[listenersKey].slice()) {
        if (stopped)
            break;
        if (type !== event.type)
            continue;
        try {
            if (typeof listener === "function")
                listener.call(target, event);
            else
                listener.handleEvent(event);
        } catch (error) {
            console.error(error);
        }
    }
};
const messageName = name => {
    const string = name === undefined || name === null ? "" : String(name);
    if (!string)
        throw "Message name cannot be empty.";
    return string;
};
const page = new SafariEventTarget();
page.tab = {
    dispatchMessage(name, message) {
        native.post(messageName(name), message);
    },
    canLoad(event, message) {
        if (!(event instanceof Object) || !("currentTarget" in event))
            throw "The first argument must be a beforeLoad event object.";
        return native.canLoad(message);
    },
    setContextMenuEventUserInfo() { },
};
Object.defineProperty(globalThis, "safari", { value: { self: page, extension: { baseURI } }, writable: true, configurable: true });
return (name, message) => dispatch(page, { type: "message", name, message });
}))JS";

void extensionsDidClearWindowObjectForFrame(WKBundlePageRef page, WKBundleFrameRef frame, WKBundleScriptWorldRef world)
{
    auto root = rootOfWorld(world);
    if (root.isEmpty())
        return;
    JSGlobalContextRef context = WKBundleFrameGetJavaScriptContextForWorld(frame, world);
    if (!context)
        return;
    auto source = JSStringCreateWithUTF8CString(contentAPISource);
    JSValueRef factoryValue = JSEvaluateScript(context, source, nullptr, nullptr, 0, nullptr);
    JSStringRelease(source);
    JSObjectRef factory = factoryValue && JSValueIsObject(context, factoryValue) ? JSValueToObject(context, factoryValue, nullptr) : nullptr;
    if (!factory)
        return;
    JSValueRef arguments[] = { JSObjectMake(context, contentNativeClass(), new ContentNative { root }), jsString(context, root) };
    JSValueRef receiver = JSObjectCallAsFunction(context, factory, nullptr, 2, arguments, nullptr);
    JSObjectRef function = receiver && JSValueIsObject(context, receiver) ? JSValueToObject(context, receiver, nullptr) : nullptr;
    if (!function || !JSObjectIsFunction(context, function))
        return;
    receivers().ensure(frame, [] {
        return HashMap<String, std::unique_ptr<Receiver>> { };
    }).iterator->value.set(root, makeUnique<Receiver>(page, context, function));
}

} // namespace WebClip
