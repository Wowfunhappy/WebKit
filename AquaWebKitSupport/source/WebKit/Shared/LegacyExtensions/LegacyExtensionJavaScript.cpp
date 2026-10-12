#include "config.h"
#include "LegacyExtensionJavaScript.h"

#include "LegacyExtensionAPIScriptSource.h"
#include "Logging.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <JavaScriptCore/PrivateName.h>
#include <JavaScriptCore/WeakInlines.h>
#include <WebCore/EventLoop.h>
#include <WebCore/JSDOMGlobalObject.h>
#include <WebCore/TaskSource.h>
#include <WebCore/ScriptExecutionContext.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/StringImpl.h>

namespace WebKit::LegacyExtensions {

static JSC::Identifier receiverIdentifier(JSC::VM& vm)
{
    static NeverDestroyed<JSC::PrivateName> receiverName(JSC::PrivateName::Description, "LegacyExtensionAPIReceiver"_s);
    return JSC::Identifier::fromUid(receiverName.get());
}

static String exceptionDescription(JSContextRef context, JSValueRef exception)
{
    if (!exception)
        return { };
    RefPtr description = adoptRef(JSValueToStringCopy(context, exception, nullptr));
    return description ? description->string() : String();
}

bool installAPI(JSC::JSGlobalObject& globalObject, ContextKind kind, JSClassRef nativeClass, void* nativeData)
{
    auto& vm = globalObject.vm();
    JSC::JSLockHolder lock(vm);
    JSGlobalContextRef context = toGlobalRef(&globalObject);

    // The object owns nativeData from here on; its class's finalizer releases it.
    JSObjectRef native = JSObjectMake(context, nativeClass, nativeData);

    JSValueRef exception = nullptr;
    String source = StringImpl::createWithoutCopying(LegacyExtensionAPIScriptSource);
    JSValueRef factory = JSEvaluateScript(context, OpaqueJSString::tryCreate(source).get(), nullptr, nullptr, 0, &exception);
    if (exception || !factory || !JSValueIsObject(context, factory) || !JSObjectIsFunction(context, const_cast<JSObjectRef>(factory))) {
        RELEASE_LOG_ERROR(Extensions, "LegacyExtensionAPI.js did not evaluate to a function: %" PUBLIC_LOG_STRING, exceptionDescription(context, exception).utf8().data());
        return false;
    }

    JSValueRef arguments[] = {
        native,
        JSValueMakeString(context, OpaqueJSString::tryCreate(kind == ContextKind::Host ? "host"_s : "content"_s).get()),
    };
    JSValueRef receiver = JSObjectCallAsFunction(context, const_cast<JSObjectRef>(factory), nullptr, std::size(arguments), arguments, &exception);
    if (exception || !receiver || !JSValueIsObject(context, receiver) || !JSObjectIsFunction(context, const_cast<JSObjectRef>(receiver))) {
        RELEASE_LOG_ERROR(Extensions, "LegacyExtensionAPI.js did not install: %" PUBLIC_LOG_STRING, exceptionDescription(context, exception).utf8().data());
        return false;
    }

    JSC::PutPropertySlot slot(&globalObject);
    globalObject.methodTable()->put(&globalObject, &globalObject, receiverIdentifier(vm), toJS(&globalObject, receiver), slot);
    return true;
}

static JSC::JSValue receiver(JSC::JSGlobalObject& globalObject)
{
    auto& vm = globalObject.vm();
    auto identifier = receiverIdentifier(vm);
    if (!globalObject.hasProperty(&globalObject, identifier))
        return JSC::jsUndefined();
    return globalObject.get(&globalObject, identifier);
}

bool hasAPI(JSC::JSGlobalObject& globalObject)
{
    JSC::JSLockHolder lock(globalObject.vm());
    return receiver(globalObject).isCallable();
}

static void callReceiver(JSC::JSGlobalObject& globalObject, const String& message, RefPtr<WebCore::SharedBuffer>&& data)
{
    auto& vm = globalObject.vm();
    JSC::JSLockHolder lock(vm);
    auto callable = receiver(globalObject);
    if (!callable.isCallable())
        return;
    JSGlobalContextRef context = toGlobalRef(&globalObject);
    JSValueRef arguments[] = {
        JSValueMakeString(context, OpaqueJSString::tryCreate(message).get()),
        JSValueMakeUndefined(context),
    };
    if (RefPtr arrayBuffer = data ? data->tryCreateArrayBuffer() : nullptr)
        arguments[1] = toRef(&globalObject, JSC::JSArrayBuffer::create(vm, globalObject.arrayBufferStructure(arrayBuffer->sharingMode()), arrayBuffer.releaseNonNull()));
    JSValueRef exception = nullptr;
    JSObjectCallAsFunction(context, toRef(callable.getObject()), nullptr, std::size(arguments), arguments, &exception);
    if (exception)
        RELEASE_LOG_ERROR(Extensions, "LegacyExtensionAPI.js receiver threw an exception: %" PUBLIC_LOG_STRING, exceptionDescription(context, exception).utf8().data());
}

// Each message is a task of the context's event loop, as a posted message is: it runs after whatever
// script is running, is followed by a microtask checkpoint, and waits while the document is suspended.
bool deliver(JSC::JSGlobalObject& globalObject, const String& message, RefPtr<WebCore::SharedBuffer>&& data)
{
    if (!hasAPI(globalObject))
        return false;
    auto* domGlobalObject = dynamicDowncast<WebCore::JSDOMGlobalObject>(&globalObject);
    RefPtr scriptExecutionContext = domGlobalObject ? domGlobalObject->scriptExecutionContext() : nullptr;
    if (!scriptExecutionContext)
        return false;
    scriptExecutionContext->eventLoop().queueTask(WebCore::TaskSource::PostedMessageQueue, [globalObject = JSC::Weak<JSC::JSGlobalObject> { &globalObject }, message = message.isolatedCopy(), data = WTF::move(data)] mutable {
        if (auto* target = globalObject.get())
            callReceiver(*target, message, WTF::move(data));
    });
    return true;
}

String stringArgument(JSContextRef context, size_t argumentCount, const JSValueRef arguments[], size_t index)
{
    if (index >= argumentCount || !JSValueIsString(context, arguments[index]))
        return { };
    RefPtr string = adoptRef(JSValueToStringCopy(context, arguments[index], nullptr));
    return string ? string->string() : String();
}

RefPtr<WebCore::SharedBuffer> bufferArgument(JSContextRef context, size_t argumentCount, const JSValueRef arguments[], size_t index)
{
    if (index >= argumentCount)
        return nullptr;
    auto* globalObject = toJS(context);
    auto& vm = globalObject->vm();
    JSC::JSLockHolder lock(vm);
    auto value = toJS(globalObject, arguments[index]);
    if (auto* view = value.isCell() ? dynamicDowncast<JSC::JSArrayBufferView>(value.asCell()) : nullptr)
        return WebCore::SharedBuffer::create(view->span());
    if (RefPtr buffer = JSC::toPossiblySharedArrayBuffer(vm, value))
        return WebCore::SharedBuffer::create(buffer->span());
    return nullptr;
}

} // namespace WebKit::LegacyExtensions
