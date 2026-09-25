// Page-visible bindings Safari 7's injected bundle adds to the standard world, brought to what
// Safari 17 exposes.
//
// Safari::BrowserBundlePageLoaderClient::globalObjectIsAvailableForFrame defines, through
// JSObjectSetProperty on the global object:
//   safari                            ReadOnly | DontDelete             main frame, http(s)
//   doNotTrack                        ReadOnly | DontDelete             every frame
//   getSearchEngine, setSearchEngine  ReadOnly | DontEnum | DontDelete  main frame, search provider pages
// Safari 17's callback defines safari with no attributes and defines none of the others, so once the
// bundle returns, safari takes no attributes and the others are removed. Each is matched by the
// attributes Safari 7 gives it.

#include "config.h"
#include "Safari7StandardWorldBindings.h"

#include "WebFrame.h"
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/PropertyDescriptor.h>
#include <JavaScriptCore/StructureInlines.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/JSDOMGlobalObject.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/ScriptController.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

namespace WebKit {

using JSC::PropertyAttribute;

static constexpr unsigned readOnlyDontDelete = PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete;
static constexpr unsigned readOnlyDontEnumDontDelete = readOnlyDontDelete | PropertyAttribute::DontEnum;

void applyModernSafariStandardWorldBindings(WebFrame& frame, WebCore::DOMWrapperWorld& world)
{
    if (!world.isNormal() || !WTF::MacApplication::isSafari())
        return;

    RefPtr coreFrame = frame.coreLocalFrame();
    if (!coreFrame)
        return;

    auto* globalObject = coreFrame->script().globalObject(world);
    auto& vm = globalObject->vm();
    JSC::JSLockHolder lock(vm);

    auto safari7Binding = [&](ASCIILiteral name, unsigned safari7Attributes) -> std::optional<std::pair<JSC::Identifier, JSC::JSValue>> {
        auto identifier = JSC::Identifier::fromString(vm, name);
        JSC::PropertyDescriptor descriptor;
        if (!globalObject->getOwnPropertyDescriptor(globalObject, identifier, descriptor) || descriptor.attributes() != safari7Attributes)
            return std::nullopt;
        return { { WTF::move(identifier), descriptor.value() } };
    };

    if (auto binding = safari7Binding("safari"_s, readOnlyDontDelete))
        globalObject->putDirect(vm, binding->first, binding->second, static_cast<unsigned>(PropertyAttribute::None));

    static constexpr std::pair<ASCIILiteral, unsigned> removedBindings[] = {
        { "doNotTrack"_s, readOnlyDontDelete },
        { "getSearchEngine"_s, readOnlyDontEnumDontDelete },
        { "setSearchEngine"_s, readOnlyDontEnumDontDelete },
    };
    for (auto& [name, safari7Attributes] : removedBindings) {
        auto binding = safari7Binding(name, safari7Attributes);
        if (!binding)
            continue;
        JSC::VM::DeletePropertyModeScope scope(vm, JSC::VM::DeletePropertyMode::IgnoreConfigurable);
        JSC::DeletePropertySlot slot;
        JSC::JSObject::deleteProperty(globalObject, globalObject, binding->first, slot);
    }
}

}
