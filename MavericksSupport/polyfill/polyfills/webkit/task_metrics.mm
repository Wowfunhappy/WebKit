/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
 */

// NSURLSession task metrics (10.12+) for 10.9's NSURLSession, which keeps no record of a task's
// transactions. A task's NSURLSessionTaskMetrics (polyfills/classes/Foundation.m) is started when the task
// is first resumed and filled in from the events its session delivers: every session WebKit creates gets a
// delegate relay that notes a redirect, the response and the completion before handing each to WebKit's
// delegate, and gives that delegate -URLSession:task:didFinishCollectingMetrics: immediately before
// -URLSession:task:didCompleteWithError:, the order NSURLSession uses. -[NSURLSessionTask
// _incompleteTaskMetrics] reports the record while the task runs.
//
// A transaction's fetch start is the resume (first hop) or the redirect that began it; its response start
// the delivery of its response; its response end the redirect or completion that ended it. The body byte
// counts are the task's own count of bytes delivered.

#import "wk_selref_scope.h"
#import <CFNetwork/CFNetwork.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef const struct _CFURLResponse* CFURLResponseRef;
@interface NSURLResponse (WKTaskMetricsCFNetworkSPI)
- (CFURLResponseRef)_CFURLResponse;
@end
extern "C" CFHTTPMessageRef CFURLResponseGetHTTPResponse(CFURLResponseRef);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// One key for every image carrying this layer: a registered selector.
static const void *wkTaskMetricsKey()
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_urlSessionTaskMetrics");
    return key;
}

static NSURLSessionTaskMetrics *wkTaskMetrics(id task)
{
    return objc_getAssociatedObject(task, wkTaskMetricsKey());
}

static NSURLSessionTaskTransactionMetrics *wkBeginTransaction(NSURLSessionTaskMetrics *metrics, NSURLRequest *request)
{
    NSURLSessionTaskTransactionMetrics *transaction = [[NSURLSessionTaskTransactionMetrics alloc] init];
    [transaction setValue:request forKey:@"request"];
    [transaction setValue:[NSDate date] forKey:@"fetchStartDate"];
    @synchronized (metrics) {
        NSArray *transactions = metrics.transactionMetrics ?: @[];
        [metrics setValue:[transactions arrayByAddingObject:transaction] forKey:@"transactionMetrics"];
    }
    return transaction;
}

static NSURLSessionTaskMetrics *wkStartTaskMetrics(NSURLSessionTask *task)
{
    NSURLSessionTaskMetrics *metrics = [[NSURLSessionTaskMetrics alloc] init];
    objc_setAssociatedObject(task, wkTaskMetricsKey(), metrics, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    wkBeginTransaction(metrics, task.currentRequest);
    return metrics;
}

static NSURLSessionTaskTransactionMetrics *wkCurrentTransaction(NSURLSessionTask *task)
{
    NSURLSessionTaskMetrics *metrics = wkTaskMetrics(task) ?: wkStartTaskMetrics(task);
    @synchronized (metrics) {
        return metrics.transactionMetrics.lastObject;
    }
}

// The response's own status-line version, lowercased to the ALPN spelling ("http/1.1").
static NSString *wkProtocolName(NSURLResponse *response)
{
    if (![response isKindOfClass:[NSHTTPURLResponse class]])
        return nil;
    CFURLResponseRef cfResponse = [response _CFURLResponse];
    CFHTTPMessageRef message = cfResponse ? CFURLResponseGetHTTPResponse(cfResponse) : nullptr;
    NSString *version = message ? CFBridgingRelease(CFHTTPMessageCopyVersion(message)) : nil;
    return version.lowercaseString;
}

static void wkRecordResponse(NSURLSessionTaskTransactionMetrics *transaction, NSURLResponse *response)
{
    [transaction setValue:response forKey:@"response"];
    [transaction setValue:wkProtocolName(response) forKey:@"networkProtocolName"];
}

static void wkNoteResponse(NSURLSessionTaskTransactionMetrics *transaction, NSURLResponse *response)
{
    if (!transaction.responseStartDate)
        [transaction setValue:[NSDate date] forKey:@"responseStartDate"];
    wkRecordResponse(transaction, response);
}

@interface WKMavURLSessionMetricsRelay : NSObject
- (instancetype)initWithDelegate:(id)delegate;
@property (nonatomic, readonly) id wkRelayedDelegate;
@end

@implementation WKMavURLSessionMetricsRelay {
    id _delegate;
}

- (instancetype)initWithDelegate:(id)delegate
{
    if ((self = [super init]))
        _delegate = delegate;
    return self;
}

- (id)wkRelayedDelegate
{
    return _delegate;
}

// The session asks once, when it is created, which callbacks to make. Every callback a transaction is
// timed from is answered here whatever the delegate implements, since a redirect hop and a response
// are part of the metrics the session reports and not of the delegate's own interest; the rest are
// the delegate's own answers.
- (BOOL)respondsToSelector:(SEL)selector
{
    if (selector == @selector(URLSession:task:didCompleteWithError:)
        || selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
        || selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:))
        return YES;
    return [super respondsToSelector:selector] || [_delegate respondsToSelector:selector];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    return [_delegate conformsToProtocol:protocol];
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    return _delegate;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    NSURLSessionTaskTransactionMetrics *transaction = wkCurrentTransaction(task);
    wkNoteResponse(transaction, response);
    [transaction setValue:[NSDate date] forKey:@"responseEndDate"];
    NSURLSessionTaskMetrics *metrics = wkTaskMetrics(task);
    [metrics setValue:@(metrics.redirectCount + 1) forKey:@"redirectCount"];
    wkBeginTransaction(metrics, request);
    if ([_delegate respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)]) {
        [_delegate URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:completionHandler];
        return;
    }
    // What the session does for a delegate that does not answer: follow the redirect.
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    wkNoteResponse(wkCurrentTransaction(dataTask), response);
    if ([_delegate respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)]) {
        [_delegate URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
        return;
    }
    // What the session does for a delegate that does not answer: take the body.
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSURLSessionTaskTransactionMetrics *transaction = wkCurrentTransaction(task);
    // A download or upload task, and a data task whose delegate takes its response through a completion
    // handler, reaches completion with the transaction's response still unset; the task carries it.
    if (!transaction.response && task.response)
        wkRecordResponse(transaction, task.response);
    if (!transaction.responseEndDate)
        [transaction setValue:[NSDate date] forKey:@"responseEndDate"];
    [transaction setValue:@(task.countOfBytesReceived) forKey:@"countOfResponseBodyBytesReceived"];
    [transaction setValue:@(task.countOfBytesReceived) forKey:@"countOfResponseBodyBytesAfterDecoding"];
    if ([_delegate respondsToSelector:@selector(URLSession:task:didFinishCollectingMetrics:)])
        [_delegate URLSession:session task:task didFinishCollectingMetrics:wkTaskMetrics(task)];
    if ([_delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
        [_delegate URLSession:session task:task didCompleteWithError:error];
}

@end

// On 10.9 NSURLSession's superclass is __NSCFURLSession, which implements the creator; NSURLSession
// inherits this body.
WK_POLYFILL_REPLACE_METHODS_ON(NSURLSession, "__NSCFURLSession")
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue
{
    id relay = delegate ? [[WKMavURLSessionMetricsRelay alloc] initWithDelegate:delegate] : nil;
    return WK_ORIGINAL_METHOD(NSURLSession *, (NSURLSessionConfiguration *, id, NSOperationQueue *), configuration, relay, queue);
}

// -delegate answers the object the caller handed to the creator above, not the relay standing in for it.
- (id<NSURLSessionDelegate>)delegate
{
    id delegate = WK_ORIGINAL_METHOD(id, ());
    if ([delegate isKindOfClass:[WKMavURLSessionMetricsRelay class]])
        return [(WKMavURLSessionMetricsRelay *)delegate wkRelayedDelegate];
    return delegate;
}
@end

// __NSCFLocalSessionTask overrides -resume from __NSCFURLSessionTask; every local data, upload and download
// task is one.
WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "__NSCFLocalSessionTask")
- (void)resume
{
    if (!wkTaskMetrics(self))
        wkStartTaskMetrics((NSURLSessionTask *)self);
    WK_ORIGINAL_METHOD(void, ());
}
@end

WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSURLSessionTask", "__NSCFURLSessionTask")
- (NSURLSessionTaskMetrics *)_incompleteTaskMetrics
{
    return wkTaskMetrics(self);
}
@end

#pragma clang diagnostic pop
