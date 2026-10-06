// Mozilla's Readability, substituted for the page under Safari 7's Reader.
//
// Safari 7's Reader examines a page with its article finder: a heuristic script, embedded in
// Safari.framework, that Safari evaluates in an isolated world of the page through JSScriptEvaluate
// and then reaches through the ReaderArticleFinderJS global it defines. Safari's script is left as it
// is; in a page's main frame it runs instead against a document built from Readability, and the
// page's global in Safari's world gets the finder object built there.
//
// - Deciding whether to offer Reader, which Safari does from a timer after each load: Firefox's own
//   Reader View availability test (Readerable.js, with Readability-readerable.js) decides, and
//   Safari's finder examines a stub that carries the verdict (stubFrameForSafariReaderDetection).
// - Showing the page in Reader, and saving it to the Reading List, which Safari does while handling a
//   message from the UI process or a finished load (SafariReaderMozillaReadabilityArticleScope): Safari's
//   finder examines the article Readability extracts (SafariReaderMozillaReadability.js), rendered in a page
//   of its own at the page's URL and width (mozillaReadabilityArticleFrameForSafariReader). A page
//   Readability finds no article in is examined as itself.

#include "config.h"
#include "SafariReaderMozillaReadability.h"

#include "CommonVM.h"
#include "DOMWrapperWorld.h"
#include "Document.h"
#include "DocumentLoader.h"
#include "DocumentView.h"
#include "DocumentWriter.h"
#include "EmptyClients.h"
#include "FrameLoader.h"
#include "HTMLBodyElement.h"
#include "JSDOMWindowBase.h"
#include "LocalDOMWindow.h"
#include "LocalFrame.h"
#include "LocalFrameView.h"
#include "Page.h"
#include "PageConfiguration.h"
#include "SafariReaderMozillaReadabilityScriptSource.h"
#include "SafariReaderFirefoxReaderableScriptSource.h"
#include "ScriptController.h"
#include "Settings.h"
#include "SharedBuffer.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSScriptRefPrivate.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/SetForScope.h>
#include <wtf/WeakHashMap.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#include <wtf/text/StringBuilder.h>

namespace WebCore {

// Safari's finder hit-tests points down to y=1200 and takes candidates that start above y=1300.
static constexpr int offscreenViewHeight = 1400;
// The stub's width only needs to give its paragraphs the area Safari's finder requires of an article.
static constexpr int stubViewWidth = 1024;
// Safari's finder requires an article of 170000 square pixels; at this width, the 300px-tall
// container SafariReaderMozillaReadability.js gives a short article has them.
static constexpr int minimumArticleViewWidth = 600;

// The global through which Safari reaches the finder object its script creates.
static constexpr auto finderObjectName = "ReaderArticleFinderJS";

static unsigned requestScopeCount;
static bool isRunningSafariReaderFinderInDocument;

SafariReaderMozillaReadabilityArticleScope::SafariReaderMozillaReadabilityArticleScope()
{
    ++requestScopeCount;
}

SafariReaderMozillaReadabilityArticleScope::~SafariReaderMozillaReadabilityArticleScope()
{
    --requestScopeCount;
}

static DOMWrapperWorld& mozillaReadabilityWorld()
{
    static NeverDestroyed<Ref<DOMWrapperWorld>> world = DOMWrapperWorld::create(commonVM(), DOMWrapperWorld::Type::Internal, "SafariReaderMozillaReadability"_s);
    return world.get();
}

static JSObjectRef globalFunction(JSGlobalContextRef context, const char* functionName)
{
    JSRetainPtr name = adopt(JSStringCreateWithUTF8CString(functionName));
    JSValueRef function = JSObjectGetProperty(context, JSContextGetGlobalObject(context), name.get(), nullptr);
    if (!JSValueIsObject(context, function) || !JSObjectIsFunction(context, const_cast<JSObjectRef>(function)))
        return nullptr;
    return const_cast<JSObjectRef>(function);
}

// The function a script embedded in WebCore defines in frame's global in the extraction world,
// evaluating the script there first if need be.
static JSObjectRef mozillaReadabilityWorldFunction(LocalFrame& frame, const char* functionName, std::span<const unsigned char> scriptSource)
{
    JSGlobalContextRef context = toGlobalRef(frame.script().globalObject(mozillaReadabilityWorld()));
    if (JSObjectRef function = globalFunction(context, functionName))
        return function;
    auto source = String::fromUTF8(scriptSource);
    JSEvaluateScript(context, OpaqueJSString::tryCreate(source).get(), nullptr, nullptr, 0, nullptr);
    return globalFunction(context, functionName);
}

// Whether Firefox would offer Reader View for the page in frame (SafariReaderFirefoxReaderable.js).
static bool firefoxReaderViewIsAvailable(LocalFrame& frame)
{
    JSObjectRef function = mozillaReadabilityWorldFunction(frame, "firefoxReaderViewIsAvailable", std::span { SafariReaderFirefoxReaderableScriptSource });
    if (!function)
        return false;
    JSGlobalContextRef context = toGlobalRef(frame.script().globalObject(mozillaReadabilityWorld()));
    JSValueRef result = JSObjectCallAsFunction(context, function, nullptr, 0, nullptr, nullptr);
    return result && JSValueToBoolean(context, result);
}

// The markup of the article document for the page in frame, or a null string when it holds no article.
static String mozillaReadabilityArticleHTML(LocalFrame& frame)
{
    JSObjectRef function = mozillaReadabilityWorldFunction(frame, "mozillaReadabilityArticleHTMLForSafariReader", std::span { SafariReaderMozillaReadabilityScriptSource });
    if (!function)
        return { };
    JSGlobalContextRef context = toGlobalRef(frame.script().globalObject(mozillaReadabilityWorld()));
    JSValueRef result = JSObjectCallAsFunction(context, function, nullptr, 0, nullptr, nullptr);
    if (!result || !JSValueIsString(context, result))
        return { };
    JSRetainPtr string = adopt(JSValueToStringCopy(context, result, nullptr));
    return string ? string->string() : String();
}

static Ref<Page> createOffscreenPage(const Settings& settings, PAL::SessionID sessionID)
{
    Ref articlePage = Page::create(pageConfigurationWithEmptyClients(std::nullopt, sessionID));
    articlePage->settings().setScriptEnabled(false);
    articlePage->settings().setLoadsImagesAutomatically(false);
    articlePage->settings().setAcceleratedCompositingEnabled(false);
#if ENABLE(VIDEO)
    articlePage->settings().setMediaEnabled(false);
#endif
    articlePage->settings().fontGenericFamilies() = settings.fontGenericFamilies();

    RefPtr frame = articlePage->localMainFrame();
    frame->setView(LocalFrameView::create(*frame));
    frame->init();
    protect(frame->view())->setCanHaveScrollbars(false);
    return articlePage;
}

static void loadOffscreenDocument(LocalFrame& frame, const URL& url, const String& html, int width)
{
    protect(frame.view())->resize(width, offscreenViewHeight);
    RefPtr documentLoader = frame.loader().activeDocumentLoader();
    auto& writer = documentLoader->writer();
    writer.setMIMEType("text/html"_s);
    writer.begin(url);
    writer.setEncoding("UTF-8"_s, DocumentWriter::IsEncodingUserChosen::No);
    writer.addData(SharedBuffer::create(html.utf8().span()));
    writer.end();
    protect(frame.document())->updateLayoutIgnorePendingStylesheets();
}

// The document a page is examined as when Safari decides whether to offer Reader: for a page Firefox
// would offer Reader View for, a stand-in article whose title and twelve paragraphs are sized to pass
// Safari's finder; for any other page, an empty body. Safari's finder marks the elements
// it examines, so each examination gets a body of its own.
static LocalFrame& stubFrameForSafariReaderDetection(Page& page, bool firefoxOffersReaderView)
{
    static NeverDestroyed<RefPtr<Page>> stubPage;
    static NeverDestroyed<RefPtr<Node>> stubArticleBody;
    static NeverDestroyed<RefPtr<Node>> stubEmptyBody;
    if (!stubPage.get()) {
        stubPage.get() = createOffscreenPage(page.settings(), page.sessionID());
        StringBuilder html;
        html.append("<!DOCTYPE html><title></title><h1>Article</h1><div>"_s);
        for (unsigned i = 0; i < 12; ++i)
            html.append("<p>This paragraph stands in for the text of an article, written in sentences of ordinary length, with commas, clauses and the occasional aside, so that every paragraph of it fills several lines of the page and reads, line after line, in the one style of an article's body.</p>"_s);
        html.append("</div>"_s);
        loadOffscreenDocument(*stubPage.get()->localMainFrame(), aboutBlankURL(), html.toString(), stubViewWidth);
        Ref body = *stubPage.get()->localMainFrame()->document()->body();
        stubArticleBody.get() = body->cloneNode(true);
        stubEmptyBody.get() = body->cloneNode(false);
    }

    Ref frame = *stubPage.get()->localMainFrame();
    Ref document = *frame->document();
    if (RefPtr body = document->body())
        protect(document->documentElement())->replaceChild((firefoxOffersReaderView ? stubArticleBody : stubEmptyBody).get()->cloneNode(true), *body);
    document->updateLayoutIgnorePendingStylesheets();
    return frame;
}

static WeakHashMap<Document, Ref<Page>, WeakPtrImplWithEventTargetData>& articlePages()
{
    static NeverDestroyed<WeakHashMap<Document, Ref<Page>, WeakPtrImplWithEventTargetData>> pages;
    return pages;
}

// The frame holding the article Readability extracts from the page in frame, or null when it holds none.
static RefPtr<LocalFrame> mozillaReadabilityArticleFrameForSafariReader(LocalFrame& frame)
{
    RefPtr document = frame.document();
    RefPtr page = frame.page();
    RefPtr view = frame.view();
    if (!document || !page || !view)
        return nullptr;

    auto html = mozillaReadabilityArticleHTML(frame);
    if (html.isNull())
        return nullptr;

    Ref articlePage = articlePages().ensure(*document, [&] {
        return createOffscreenPage(page->settings(), page->sessionID());
    }).iterator->value;
    RefPtr articleFrame = articlePage->localMainFrame();
    loadOffscreenDocument(*articleFrame, document->url(), html, std::max(view->visibleContentRect().width(), minimumArticleViewWidth));
    return articleFrame;
}

// Evaluates Safari's finder script in documentFrame, in the world of pageWindow, and gives
// pageWindow's global the finder object it creates there: Safari takes the finder from that global.
static void runSafariReaderFinderInDocument(JSScriptRef script, LocalFrame& documentFrame, JSDOMWindowBase& pageWindow, JSValueRef* exception)
{
    JSGlobalContextRef documentContext = toGlobalRef(documentFrame.script().globalObject(pageWindow.world()));
    JSValueRef documentException = nullptr;
    {
        SetForScope scope(isRunningSafariReaderFinderInDocument, true);
        JSScriptEvaluate(documentContext, script, nullptr, &documentException);
    }
    if (documentException) {
        if (exception)
            *exception = documentException;
        return;
    }

    JSRetainPtr name = adopt(JSStringCreateWithUTF8CString(finderObjectName));
    JSValueRef finder = JSObjectGetProperty(documentContext, JSContextGetGlobalObject(documentContext), name.get(), nullptr);
    JSGlobalContextRef pageContext = toGlobalRef(&pageWindow);
    JSObjectSetProperty(pageContext, JSContextGetGlobalObject(pageContext), name.get(), finder, kJSPropertyAttributeNone, exception);
}

// The evaluator JSScriptEvaluate hands Safari's finder script: a page's main frame is examined as a
// document of WebKit's making (see the top of this file), any other frame as itself.
static bool runSafariReaderOnMozillaReadabilityDocument(JSContextRef context, JSScriptRef script, JSValueRef* exception)
{
    if (isRunningSafariReaderFinderInDocument)
        return false;

    auto* window = dynamicDowncast<JSDOMWindowBase>(toJS(context));
    if (!window)
        return false;
    RefPtr localWindow = dynamicDowncast<LocalDOMWindow>(window->wrapped());
    RefPtr frame = localWindow ? localWindow->frame() : nullptr;
    if (!frame || !frame->isMainFrame() || !frame->document() || !frame->page())
        return false;

    RefPtr<LocalFrame> articleFrame;
    if (requestScopeCount)
        articleFrame = mozillaReadabilityArticleFrameForSafariReader(*frame);
    else
        articleFrame = &stubFrameForSafariReaderDetection(*protect(frame->page()), firefoxReaderViewIsAvailable(*frame));
    if (!articleFrame)
        return false;

    runSafariReaderFinderInDocument(script, *articleFrame, *window, exception);
    return true;
}

void installMozillaReadabilityForSafariReader()
{
    if (WTF::MacApplication::isSafari())
        JSScriptSetSafariReaderFinderEvaluator(runSafariReaderOnMozillaReadabilityDocument);
}

} // namespace WebCore
