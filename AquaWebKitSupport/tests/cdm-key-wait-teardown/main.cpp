#include "config.h"
#include "CDMProxy.h"
#include "CDMInstanceSession.h"
#include <wtf/MainThread.h>
#include <wtf/Threading.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/WTFString.h>
#include <atomic>
#include <cstdio>
#include <unistd.h>
namespace WTF::Detail { std::atomic<int> wtfStringCopyCount; }
using namespace WebCore;
class Proxy final : public CDMProxy {
public:
    static Ref<Proxy> create() { return adoptRef(*new Proxy); }
    bool wait(CDMProxyDecryptionClient& client) const
    {
        return !!getOrWaitForKeyHandle(KeyIDType { 1, 2, 3 }, WeakPtr { client, EnableWeakPtrThreadingAssertions::No });
    }
};

class Factory final : public CDMProxyFactory {
    RefPtr<CDMProxy> createCDMProxy(const String&) final { return Proxy::create(); }
    bool supportsKeySystem(const String& name) final { return name == "org.webkit.teardown-test"_s; }
};
namespace WebCore {
Vector<CDMProxyFactory*> CDMProxyFactory::platformRegisterFactories() { return { }; }
}
class Instance final : public CDMInstanceProxy {
    WTF_MAKE_TZONE_ALLOCATED(Instance);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(Instance);
public:
    static Ref<Instance> create() { return adoptRef(*new Instance); }
    ImplementationType implementationType() const final { return ImplementationType::Mock; }
    void initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers, AllowPersistentState, SuccessCallback&& callback) final { callback(SuccessValue::Succeeded); }
    void setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&& callback) final { callback(SuccessValue::Failed); }
    void setStorageDirectory(const String&) final { }
    const String& keySystem() const final { return m_keySystem; }
    RefPtr<CDMInstanceSession> createSession() final { return nullptr; }
private:
    Instance()
        : CDMInstanceProxy("org.webkit.teardown-test"_s)
    {
    }
    const String m_keySystem { "org.webkit.teardown-test"_s };
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(Instance);
class Client final : public CDMProxyDecryptionClient {
    WTF_MAKE_TZONE_ALLOCATED(Client);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(Client);
public:
    bool isAborting() final
    {
        entered = true;
        return false;
    }
    std::atomic<bool> entered { false };
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(Client);
int main()
{
    WTF::initializeMainThread();
    Factory factory;
    CDMProxyFactory::registerFactory(factory);
    for (unsigned pass = 0; pass < 100; ++pass) {
        RefPtr instance = Instance::create();
        Ref proxy = static_cast<Proxy&>(*instance->proxy());
        auto client = makeUnique<Client>();
        std::atomic<bool> result { true };
        auto thread = Thread::create("CDM teardown"_s, [&] { result = proxy->wait(*client); });
        for (unsigned count = 0; !client->entered && count < 10000; ++count)
            usleep(1000);
        if (!client->entered) {
            puts("FAIL: key wait did not start");
            return 1;
        }
        auto before = MonotonicTime::now();
        instance = nullptr;
        thread->waitForCompletion();
        if (result || MonotonicTime::now() - before >= 6_s) {
            puts("FAIL: teardown did not cancel key wait");
            return 1;
        }
        if (proxy->wait(*client)) {
            puts("FAIL: detached proxy returned a key");
            return 1;
        }
    }
    puts("PASS: 100 instance destructions cancel pending key waits; detached proxies fail immediately");
}
