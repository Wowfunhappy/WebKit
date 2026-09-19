// A scheduler can finish retiring after its session pool's last owner releases it.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <dispatch/dispatch.h>
#include <wtf/MainThread.h>
#include <cstdio>

using namespace WebCore;

int main()
{
    WTF::initializeMainThread();
    auto ready = dispatch_semaphore_create(0);
    auto retire = dispatch_semaphore_create(0);
    auto completed = dispatch_semaphore_create(0);
    RefPtr pool = CocoaCurlConnectionPool::create();
    Ref worker = pool->runLoop();
    worker->dispatch([owner = pool.get(), ready, retire, completed] {
        RefPtr<CocoaCurlScheduler> scheduler = &owner->scheduler();
        dispatch_semaphore_signal(ready);
        dispatch_semaphore_wait(retire, DISPATCH_TIME_FOREVER);
        scheduler = nullptr;
        dispatch_semaphore_signal(completed);
    });
    RELEASE_ASSERT(!dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    pool = nullptr;
    dispatch_semaphore_signal(retire);
    RELEASE_ASSERT(!dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    dispatch_release(ready);
    dispatch_release(retire);
    dispatch_release(completed);
    puts("PASS scheduler retirement after pool release");
    return 0;
}
