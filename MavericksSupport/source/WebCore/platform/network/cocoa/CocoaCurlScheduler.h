/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// native Cocoa values share an event-driven curl connection pool across loader APIs.
#include <CoreFoundation/CFSocket.h>
#include <curl/curl.h>
#include <wtf/AbstractRefCounted.h>
#include <wtf/HashMap.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class CocoaCurlSchedulerClient : public AbstractRefCounted {
public:
    virtual CURL* curlHandle() const = 0;
    virtual void curlDidComplete(CURLcode) = 0;
    virtual void curlDidFail() = 0;
    virtual void curlCancel() = 0;
};

class WEBCORE_EXPORT CocoaCurlScheduler final : public RefCountedAndCanMakeWeakPtr<CocoaCurlScheduler> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(CocoaCurlScheduler, WEBCORE_EXPORT);
public:
    static Ref<CocoaCurlScheduler> create();
    ~CocoaCurlScheduler();
    RunLoop& runLoop() const { return m_runLoop; }
    bool add(CocoaCurlSchedulerClient&);
    void remove(CURL*);
    void unpause(CocoaCurlSchedulerClient&);
    void invalidate();

private:
    CocoaCurlScheduler();
    struct Socket;
    static int socketCallback(CURL*, curl_socket_t, int, void*, void*);
    static int timerCallback(CURLM*, long, void*);
    static void ready(CFSocketRef, CFSocketCallBackType, CFDataRef, const void*, void*);
    void timeout();
    void perform(curl_socket_t, int);
    void drain();
    void fail();
    bool updateSocket(curl_socket_t, int);

    Ref<RunLoop> m_runLoop;
    CURLM* m_multi { nullptr };
    HashMap<CURL*, Ref<CocoaCurlSchedulerClient>> m_tasks;
    HashMap<curl_socket_t, std::unique_ptr<Socket>, DefaultHash<curl_socket_t>, WTF::SignedWithZeroKeyHashTraits<curl_socket_t>> m_sockets;
    RunLoop::Timer m_timer;
    bool m_invalidated { false };
};

} // namespace WebCore
