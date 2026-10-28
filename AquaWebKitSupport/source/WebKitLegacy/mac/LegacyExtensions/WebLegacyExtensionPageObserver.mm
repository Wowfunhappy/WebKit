#import "config.h"
#import "WebLegacyExtensionPageObserver.h"

#import "WebFrameInternal.h"
#import "WebPreferenceKeysPrivate.h"
#import "StorageNamespaceImpl.h"
#import "WebView.h"
#import <JavaScriptCore/APICast.h>
#import <WebCore/BroadcastChannelRegistry.h>
#import <WebCore/DOMWrapperWorld.h>
#import <WebCore/Document.h>
#import <WebCore/DatabaseProvider.h>
#import <WebCore/JSDOMWindow.h>
#import <WebCore/LocalFrameInlines.h>
#import <WebCore/Page.h>
#import <WebCore/PageConfiguration.h>
#import <WebCore/ScriptController.h>
#import <WebCore/StorageNamespaceProvider.h>
#import <WebCore/StorageMap.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/WeakHashMap.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

static const WebLegacyExtensionPageObserver* observer;

static bool isExtensionView(WebView *view)
{
    NSString *identifier = [view preferencesIdentifier];
    return [identifier isEqualToString:@"ExtensionGlobalPage"] || [identifier isEqualToString:@"ExtensionPopover"]
        || [identifier isEqualToString:@"ExtensionBar"] || [identifier isEqualToString:@"ExtensionDevToolsPage"];
}

static RefPtr<WebCore::DatabaseProvider>& extensionDatabaseProvider()
{
    static NeverDestroyed<RefPtr<WebCore::DatabaseProvider>> provider;
    return provider;
}

static RefPtr<WebCore::StorageNamespaceProvider>& extensionStorageProvider()
{
    static NeverDestroyed<RefPtr<WebCore::StorageNamespaceProvider>> provider;
    return provider;
}

void WebSetLegacyExtensionStorageProviders(WebCore::DatabaseProvider& databaseProvider, WebCore::StorageNamespaceProvider& storageProvider)
{
    extensionDatabaseProvider() = databaseProvider;
    extensionStorageProvider() = storageProvider;
}

class ExtensionViewDatabaseProvider final : public WebCore::DatabaseProvider {
public:
    ExtensionViewDatabaseProvider(WebView *view, WebCore::DatabaseProvider& legacyProvider)
        : m_view(view)
        , m_legacyProvider(legacyProvider)
    {
    }

    WebCore::IDBClient::IDBConnectionToServer& idbConnectionToServerForSession(PAL::SessionID sessionID) final
    {
        auto& extensionProvider = extensionDatabaseProvider();
        auto& provider = extensionProvider && sessionID == PAL::SessionID::defaultSessionID() && isExtensionView(m_view.get().get()) ? *extensionProvider : m_legacyProvider.get();
        return provider.idbConnectionToServerForSession(sessionID);
    }

private:
    WeakObjCPtr<WebView> m_view;
    Ref<WebCore::DatabaseProvider> m_legacyProvider;
};

// Preferences identify the view before its first document runs script. Session storage belongs to each Page.
class ExtensionViewStorageProvider final : public WebCore::StorageNamespaceProvider {
public:
    ExtensionViewStorageProvider(WebView *view, WebCore::StorageNamespaceProvider& legacyProvider)
        : m_view(view)
        , m_legacyProvider(legacyProvider)
    {
    }

private:
    WebCore::StorageNamespaceProvider& provider(PAL::SessionID sessionID) const
    {
        auto& extensionProvider = extensionStorageProvider();
        return extensionProvider && sessionID == PAL::SessionID::defaultSessionID() && isExtensionView(m_view.get().get()) ? *extensionProvider : m_legacyProvider.get();
    }

    Ref<WebCore::StorageNamespace> createLocalStorageNamespace(unsigned, PAL::SessionID sessionID) final
    {
        return provider(sessionID).localStorageNamespace(sessionID);
    }

    Ref<WebCore::StorageNamespace> createTransientLocalStorageNamespace(WebCore::SecurityOrigin& origin, unsigned, PAL::SessionID sessionID) final
    {
        return provider(sessionID).transientLocalStorageNamespace(origin, sessionID);
    }

    RefPtr<WebCore::StorageNamespace> sessionStorageNamespace(const WebCore::SecurityOrigin& origin, WebCore::Page& page, ShouldCreateNamespace shouldCreate) final
    {
        if (m_sessionNamespaces.find(page) == m_sessionNamespaces.end()) {
            if (shouldCreate == ShouldCreateNamespace::No)
                return nullptr;
            m_sessionNamespaces.set(page, HashMap<WebCore::SecurityOriginData, Ref<WebCore::StorageNamespace>> { });
        }
        auto& namespaces = m_sessionNamespaces.find(page)->value;
        auto namespaceIterator = namespaces.find(origin.data());
        if (namespaceIterator != namespaces.end())
            return namespaceIterator->value.ptr();
        if (shouldCreate == ShouldCreateNamespace::No)
            return nullptr;
        return namespaces.add(origin.data(), WebKit::StorageNamespaceImpl::createSessionStorageNamespace(sessionStorageQuota(), page.sessionID())).iterator->value.ptr();
    }

    void cloneSessionStorageNamespaceForPage(WebCore::Page& source, WebCore::Page& destination) final
    {
        auto& sourceProvider = static_cast<ExtensionViewStorageProvider&>(source.storageNamespaceProvider());
        auto iterator = sourceProvider.m_sessionNamespaces.find(source);
        if (iterator == sourceProvider.m_sessionNamespaces.end())
            return;
        HashMap<WebCore::SecurityOriginData, Ref<WebCore::StorageNamespace>> namespaces;
        for (auto& [origin, storageNamespace] : iterator->value)
            namespaces.add(origin, storageNamespace->copy(destination));
        auto& destinationProvider = static_cast<ExtensionViewStorageProvider&>(destination.storageNamespaceProvider());
        destinationProvider.m_sessionNamespaces.set(destination, WTF::move(namespaces));
    }

    WeakObjCPtr<WebView> m_view;
    Ref<WebCore::StorageNamespaceProvider> m_legacyProvider;
    WeakHashMap<WebCore::Page, HashMap<WebCore::SecurityOriginData, Ref<WebCore::StorageNamespace>>> m_sessionNamespaces;
};

void WebConfigureLegacyExtensionStorage(WebView *view, WebCore::PageConfiguration& configuration)
{
    if (!WTF::MacApplication::isSafari())
        return;
    configuration.databaseProvider = adoptRef(*new ExtensionViewDatabaseProvider(view, *configuration.databaseProvider));
    configuration.storageNamespaceProvider = adoptRef(*new ExtensionViewStorageProvider(view, *configuration.storageNamespaceProvider));
}

// The preference identifiers of the extension views: Safari 7's global page, popovers and extension bars, and
// the router's devtools pages (LegacyExtensionDevTools). As extension pages, they have the async clipboard API,
// BroadcastChannel, SharedWorker and Web Locks a WebKit 2 view has by default, and write the clipboard whenever
// they ask, as a WebExtension's pages with clipboardWrite do.
static void registerExtensionViewPreferenceDefaults()
{
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (NSString *identifier in @[ @"ExtensionGlobalPage", @"ExtensionPopover", @"ExtensionBar", @"ExtensionDevToolsPage" ]) {
        defaults[[identifier stringByAppendingString:WebKitAsyncClipboardAPIEnabledPreferenceKey]] = @YES;
        defaults[[identifier stringByAppendingString:WebKitJavaScriptCanAccessClipboardPreferenceKey]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitBroadcastChannelEnabled"]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitSharedWorkerEnabled"]] = @YES;
        defaults[[identifier stringByAppendingString:@"WebKitWebLocksAPIEnabled"]] = @YES;
    }
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

static RefPtr<WebCore::BroadcastChannelRegistry>& broadcastChannelRegistry()
{
    static NeverDestroyed<RefPtr<WebCore::BroadcastChannelRegistry>> registry;
    return registry;
}

void WebSetLegacyExtensionBroadcastChannelRegistry(WebCore::BroadcastChannelRegistry& registry)
{
    broadcastChannelRegistry() = &registry;
}

WebCore::BroadcastChannelRegistry* WebLegacyExtensionBroadcastChannelRegistry()
{
    return broadcastChannelRegistry().get();
}

void WebSetLegacyExtensionPageObserver(const WebLegacyExtensionPageObserver* newObserver)
{
    if (newObserver && !observer)
        registerExtensionViewPreferenceDefaults();
    observer = newObserver;
}

void WebLegacyExtensionPageObserverDidClearWindowObject(WebFrame *webFrame)
{
    if (!observer)
        return;
    RefPtr frame = core(webFrame);
    if (!frame)
        return;
    RefPtr document = frame->document();
    if (!document)
        return;
    auto* globalObject = frame->script().globalObject(WebCore::mainThreadNormalWorldSingleton());
    observer->didClearWindowObject((__bridge const void*)webFrame, toGlobalRef(globalObject), document->url().createCFURL().get());
}

void WebLegacyExtensionPageObserverFrameWillBeDestroyed(WebFrame *webFrame)
{
    if (observer)
        observer->frameWillBeDestroyed((__bridge const void*)webFrame);
}
