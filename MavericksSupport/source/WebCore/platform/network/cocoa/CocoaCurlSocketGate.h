/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// libcurl calls its progress callback only once a connection stands (lib/multi.c reaches
// Curl_pgrsUpdateX under Curl_conn_is_connected), so what interrupts a connect, a proxy tunnel or a
// handshake is the descriptor itself: closing its read side wakes curl -- at once wherever it is
// waiting on bytes, and within one of its own polls while a connect is outstanding. Name resolution
// runs before any descriptor exists, and is bounded by CURLOPT_CONNECTTIMEOUT instead. curl opens and
// closes its sockets through the callbacks below, and closes them when the handle is cleaned up --
// which happens after the object that opened the connection is gone, so the descriptor and the
// cancellation live here, held jointly by that object and by its curl handle.
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct CocoaCurlSocketGate {
    pthread_mutex_t lock;
    curl_socket_t descriptor;
    int cancelled;
    int references;
} CocoaCurlSocketGate;

static inline CocoaCurlSocketGate *cocoaCurlSocketGateCreate(void)
{
    CocoaCurlSocketGate *gate = (CocoaCurlSocketGate *)calloc(1, sizeof(CocoaCurlSocketGate));
    if (!gate)
        return NULL;
    pthread_mutex_init(&gate->lock, NULL);
    gate->descriptor = CURL_SOCKET_BAD;
    gate->references = 1;
    return gate;
}

static inline void cocoaCurlSocketGateRetain(CocoaCurlSocketGate *gate)
{
    pthread_mutex_lock(&gate->lock);
    ++gate->references;
    pthread_mutex_unlock(&gate->lock);
}

static inline void cocoaCurlSocketGateRelease(CocoaCurlSocketGate *gate)
{
    pthread_mutex_lock(&gate->lock);
    int remaining = --gate->references;
    pthread_mutex_unlock(&gate->lock);
    if (remaining)
        return;
    pthread_mutex_destroy(&gate->lock);
    free(gate);
}

// CURLOPT_OPENSOCKETFUNCTION, with the gate as CURLOPT_OPENSOCKETDATA.
static inline curl_socket_t cocoaCurlSocketGateOpen(void *gateData, curlsocktype purpose, struct curl_sockaddr *address)
{
    CocoaCurlSocketGate *gate = (CocoaCurlSocketGate *)gateData;
    curl_socket_t descriptor;
    int cancelled;
    (void)purpose;
    descriptor = socket(address->family, address->socktype, address->protocol);
    if (descriptor == CURL_SOCKET_BAD)
        return CURL_SOCKET_BAD;
    pthread_mutex_lock(&gate->lock);
    cancelled = gate->cancelled;
    if (!cancelled)
        gate->descriptor = descriptor;
    pthread_mutex_unlock(&gate->lock);
    // A cancel that arrived before this socket did is answered by opening none: curl fails the
    // connect, and the address is never reached.
    if (cancelled) {
        close(descriptor);
        return CURL_SOCKET_BAD;
    }
    return descriptor;
}

// CURLOPT_CLOSESOCKETFUNCTION. The lock is held across close(), so a descriptor read under it is
// still the one curl is using and never a number the system has since handed to something else.
static inline int cocoaCurlSocketGateClose(void *gateData, curl_socket_t descriptor)
{
    CocoaCurlSocketGate *gate = (CocoaCurlSocketGate *)gateData;
    pthread_mutex_lock(&gate->lock);
    if (gate->descriptor == descriptor)
        gate->descriptor = CURL_SOCKET_BAD;
    close(descriptor);
    pthread_mutex_unlock(&gate->lock);
    return 0;
}

static inline void cocoaCurlSocketGateCancel(CocoaCurlSocketGate *gate)
{
    pthread_mutex_lock(&gate->lock);
    gate->cancelled = 1;
    // The read side is what curl waits on, and it is the half a cancel can close whatever state the
    // connection has reached. The peer learns of the end from curl's own close of the descriptor.
    if (gate->descriptor != CURL_SOCKET_BAD)
        shutdown(gate->descriptor, SHUT_RD);
    pthread_mutex_unlock(&gate->lock);
}

static inline int cocoaCurlSocketGateCancelled(CocoaCurlSocketGate *gate)
{
    int cancelled;
    pthread_mutex_lock(&gate->lock);
    cancelled = gate->cancelled;
    pthread_mutex_unlock(&gate->lock);
    return cancelled;
}

// Once the connection stands, cancelling it means taking down an established connection through its
// owner's queue rather than interrupting a connect.
static inline void cocoaCurlSocketGateForget(CocoaCurlSocketGate *gate)
{
    pthread_mutex_lock(&gate->lock);
    gate->descriptor = CURL_SOCKET_BAD;
    pthread_mutex_unlock(&gate->lock);
}
