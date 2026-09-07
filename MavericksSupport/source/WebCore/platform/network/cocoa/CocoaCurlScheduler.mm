/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlScheduler.h"
#include <wtf/TZoneMallocInlines.h>

// session pools own curl handles through a transport-specific client contract.
namespace WebCore {
WTF_MAKE_TZONE_ALLOCATED_IMPL(CocoaCurlScheduler);

struct CocoaCurlScheduler::Socket {
    CocoaCurlScheduler* scheduler;
    curl_socket_t descriptor;
    CFOptionFlags events { 0 };
    // socket readiness must survive curl removing/reinstalling
    // watches while decoded data is paused. Map curl interests to native socket
    // callbacks and leave descriptor ownership with libcurl.
    RetainPtr<CFSocketRef> socket;
    RetainPtr<CFRunLoopSourceRef> source;

    ~Socket()
    {
        if (source)
            CFRunLoopSourceInvalidate(source.get());
        if (socket)
            CFSocketInvalidate(socket.get());
    }
};

Ref<CocoaCurlScheduler> CocoaCurlScheduler::create()
{
    return adoptRef(*new CocoaCurlScheduler);
}

CocoaCurlScheduler::CocoaCurlScheduler()
    : m_runLoop(RunLoop::currentSingleton())
    , m_timer(m_runLoop.get(), "CocoaCurlScheduler timer"_s, this, &CocoaCurlScheduler::timeout)
{
    ASSERT(m_runLoop->isCurrent());
    // libcurl global state lives for the process; multi handles and sockets live for the session.
    static const auto initialization = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (initialization != CURLE_OK)
        return;
    m_multi = curl_multi_init();
    if (!m_multi)
        return;
    // The connection limits upstream's curl port applies (CurlDefaultMaxTotalConnections,
    // CurlDefaultMaxHostConnections in platform/network/curl/CurlContext.h): without them a page's
    // subresources open a connection each, and every one pays a fresh handshake.
    if (curl_multi_setopt(m_multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, 17L) != CURLM_OK
        || curl_multi_setopt(m_multi, CURLMOPT_MAX_HOST_CONNECTIONS, 6L) != CURLM_OK
        || curl_multi_setopt(m_multi, CURLMOPT_SOCKETFUNCTION, socketCallback) != CURLM_OK
        || curl_multi_setopt(m_multi, CURLMOPT_SOCKETDATA, this) != CURLM_OK
        || curl_multi_setopt(m_multi, CURLMOPT_TIMERFUNCTION, timerCallback) != CURLM_OK
        || curl_multi_setopt(m_multi, CURLMOPT_TIMERDATA, this) != CURLM_OK) {
        curl_multi_cleanup(m_multi);
        m_multi = nullptr;
    }
}

CocoaCurlScheduler::~CocoaCurlScheduler()
{
    ASSERT(m_runLoop->isCurrent());
    ASSERT(m_tasks.isEmpty());
    m_timer.stop();
    if (m_multi)
        curl_multi_cleanup(m_multi);
    m_sockets.clear();
}

bool CocoaCurlScheduler::add(CocoaCurlSchedulerClient& task)
{
    ASSERT(m_runLoop->isCurrent());
    if (!m_multi || m_invalidated)
        return false;
    m_tasks.add(task.curlHandle(), Ref { task });
    if (curl_multi_add_handle(m_multi, task.curlHandle()) != CURLM_OK) {
        m_tasks.remove(task.curlHandle());
        return false;
    }
    return true;
}

void CocoaCurlScheduler::remove(CURL* easy)
{
    ASSERT(m_runLoop->isCurrent());
    if (!m_tasks.contains(easy))
        return;
    curl_multi_remove_handle(m_multi, easy);
    m_tasks.remove(easy);
}

void CocoaCurlScheduler::unpause(CocoaCurlSchedulerClient& task)
{
    Ref protectedThis { *this };
    Ref protectedTask { task };
    if (!m_tasks.contains(task.curlHandle()) || m_invalidated)
        return;
    auto result = curl_easy_pause(task.curlHandle(), CURLPAUSE_CONT);
    if (result != CURLE_OK) {
        remove(task.curlHandle());
        task.curlDidComplete(result);
        return;
    }
    drain();
}

void CocoaCurlScheduler::invalidate()
{
    ASSERT(m_runLoop->isCurrent());
    m_invalidated = true;
    m_timer.stop();
    while (!m_tasks.isEmpty()) {
        Ref task = m_tasks.begin()->value;
        task->curlCancel();
    }
    // invalidation releases idle sockets and TLS sessions even while clients still retain the retired scheduler.
    if (auto* multi = std::exchange(m_multi, nullptr))
        curl_multi_cleanup(multi);
    m_sockets.clear();
}

int CocoaCurlScheduler::socketCallback(CURL*, curl_socket_t descriptor, int action, void* context, void*)
{
    return static_cast<CocoaCurlScheduler*>(context)->updateSocket(descriptor, action) ? 0 : -1;
}

bool CocoaCurlScheduler::updateSocket(curl_socket_t descriptor, int action)
{
    if (action == CURL_POLL_REMOVE) {
        m_sockets.remove(descriptor);
        return true;
    }
    auto iterator = m_sockets.find(descriptor);
    if (iterator == m_sockets.end()) {
        auto socket = std::make_unique<Socket>();
        socket->scheduler = this;
        socket->descriptor = descriptor;
        CFSocketContext context { 0, socket.get(), nullptr, nullptr, nullptr };
        socket->socket = adoptCF(CFSocketCreateWithNative(nullptr, descriptor, kCFSocketReadCallBack | kCFSocketWriteCallBack, ready, &context));
        if (!socket->socket)
            return false;
        CFSocketSetSocketFlags(socket->socket.get(), CFSocketGetSocketFlags(socket->socket.get()) & ~(kCFSocketCloseOnInvalidate | kCFSocketAutomaticallyReenableReadCallBack | kCFSocketAutomaticallyReenableWriteCallBack));
        socket->source = adoptCF(CFSocketCreateRunLoopSource(nullptr, socket->socket.get(), 0));
        if (!socket->source)
            return false;
        CFRunLoopAddSource(CFRunLoopGetCurrent(), socket->source.get(), kCFRunLoopCommonModes);
        iterator = m_sockets.add(descriptor, WTF::move(socket)).iterator;
    }
    auto& socket = *iterator->value;
    socket.events = 0;
    if (action == CURL_POLL_IN || action == CURL_POLL_INOUT)
        socket.events |= kCFSocketReadCallBack;
    if (action == CURL_POLL_OUT || action == CURL_POLL_INOUT)
        socket.events |= kCFSocketWriteCallBack;
    CFSocketDisableCallBacks(socket.socket.get(), kCFSocketReadCallBack | kCFSocketWriteCallBack);
    CFSocketEnableCallBacks(socket.socket.get(), socket.events);
    return true;
}

void CocoaCurlScheduler::ready(CFSocketRef nativeSocket, CFSocketCallBackType events, CFDataRef, const void*, void* context)
{
    auto& socket = *static_cast<Socket*>(context);
    Ref scheduler { *socket.scheduler };
    auto descriptor = socket.descriptor;
    RetainPtr protectedSocket = nativeSocket;
    int action = 0;
    if (events & kCFSocketReadCallBack)
        action |= CURL_CSELECT_IN;
    if (events & kCFSocketWriteCallBack)
        action |= CURL_CSELECT_OUT;
    scheduler->perform(descriptor, action);
    // perform may remove or replace the watch; never re-arm an old descriptor after fd reuse.
    auto iterator = scheduler->m_sockets.find(descriptor);
    if (iterator != scheduler->m_sockets.end() && iterator->value->socket.get() == nativeSocket)
        CFSocketEnableCallBacks(nativeSocket, iterator->value->events);
}

int CocoaCurlScheduler::timerCallback(CURLM*, long milliseconds, void* context)
{
    auto& scheduler = *static_cast<CocoaCurlScheduler*>(context);
    scheduler.m_timer.stop();
    if (milliseconds >= 0 && !scheduler.m_invalidated)
        scheduler.m_timer.startOneShot(Seconds::fromMilliseconds(milliseconds));
    return 0;
}

void CocoaCurlScheduler::timeout()
{
    perform(CURL_SOCKET_TIMEOUT, 0);
}

void CocoaCurlScheduler::perform(curl_socket_t descriptor, int events)
{
    Ref protectedThis { *this };
    if (m_invalidated || !m_multi)
        return;
    int running = 0;
    if (curl_multi_socket_action(m_multi, descriptor, events, &running) != CURLM_OK) {
        fail();
        return;
    }
    drain();
}

void CocoaCurlScheduler::drain()
{
    int remaining;
    while (auto* message = curl_multi_info_read(m_multi, &remaining)) {
        if (message->msg != CURLMSG_DONE)
            continue;
        auto iterator = m_tasks.find(message->easy_handle);
        if (iterator == m_tasks.end())
            continue;
        Ref task = iterator->value;
        auto result = message->data.result;
        remove(message->easy_handle);
        task->curlDidComplete(result);
    }
}

void CocoaCurlScheduler::fail()
{
    m_invalidated = true;
    m_timer.stop();
    while (!m_tasks.isEmpty()) {
        Ref task = m_tasks.begin()->value;
        remove(task->curlHandle());
        task->curlDidFail();
    }
    // a failed multi handle cannot retain an unused connection cache.
    if (auto* multi = std::exchange(m_multi, nullptr))
        curl_multi_cleanup(multi);
    m_sockets.clear();
}

} // namespace WebCore
