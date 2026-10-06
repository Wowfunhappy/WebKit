// Page-visible bindings Safari 7's injected bundle adds to the standard world. Safari 26 exposes none
// of them.
//
// Safari::BrowserBundlePageLoaderClient::globalObjectIsAvailableForFrame defines, through
// JSObjectSetProperty on the global object:
//   safari                            ReadOnly | DontDelete             main frame, http(s)
//   doNotTrack                        ReadOnly | DontDelete             every frame
//   getSearchEngine, setSearchEngine  ReadOnly | DontEnum | DontDelete  main frame, search provider pages
// Once the bundle returns, each property that still has the attributes Safari 7 gave it is deleted.

#include "config.h"
#include "Safari7StandardWorldBindings.h"

#include "WebFrame.h"
#include <JavaScriptCore/DeletePropertySlot.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/PropertyDescriptor.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/JSDOMGlobalObject.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/ScriptController.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

namespace WebKit {

using JSC::PropertyAttribute;

static constexpr unsigned readOnlyDontDelete = PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete;
static constexpr unsigned readOnlyDontEnumDontDelete = readOnlyDontDelete | PropertyAttribute::DontEnum;

void removeSafari7StandardWorldBindings(WebFrame& frame, WebCore::DOMWrapperWorld& world)
{
    if (!world.isNormal() || !WTF::MacApplication::isSafari())
        return;

    RefPtr coreFrame = frame.coreLocalFrame();
    if (!coreFrame)
        return;

    auto* globalObject = coreFrame->script().globalObject(world);
    auto& vm = globalObject->vm();
    JSC::JSLockHolder lock(vm);

    static constexpr std::pair<ASCIILiteral, unsigned> safari7Bindings[] = {
        { "safari"_s, readOnlyDontDelete },
        { "doNotTrack"_s, readOnlyDontDelete },
        { "getSearchEngine"_s, readOnlyDontEnumDontDelete },
        { "setSearchEngine"_s, readOnlyDontEnumDontDelete },
    };
    for (auto& [name, safari7Attributes] : safari7Bindings) {
        auto identifier = JSC::Identifier::fromString(vm, name);
        JSC::PropertyDescriptor descriptor;
        if (!globalObject->getOwnPropertyDescriptor(globalObject, identifier, descriptor) || descriptor.attributes() != safari7Attributes)
            continue;
        JSC::VM::DeletePropertyModeScope scope(vm, JSC::VM::DeletePropertyMode::IgnoreConfigurable);
        JSC::DeletePropertySlot slot;
        JSC::JSObject::deleteProperty(globalObject, globalObject, identifier, slot);
    }
}

}
