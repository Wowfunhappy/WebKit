// Draining a resource-loader-backed AVURLAsset into a local file, for the AVAssetReader polyfill in
// methods/AVFoundation.m.
//
// 10.9's -[AVAssetReader initWithAsset:error:] raises NSInvalidArgumentException for an asset at any
// non-local URL, and 10.9's AVURLAsset types a local file by filename extension alone. A resource
// loader delegate already holds the bytes, so this asks it for them through synthetic request objects
// and writes them to a file named for the content type the delegate declares.
//
// The request objects are real subclasses of the three AVAssetResourceLoading* classes, created at
// runtime because this layer does not link AVFoundation, and instantiated with class_createInstance so
// no AVFoundation initializer runs. A delegate's isKindOfClass: and every accessor the protocol
// exposes therefore answer as they would for AVFoundation's own requests. -finishLoading and
// -finishLoadingWithError: signal a semaphore, so a delegate that answers on another thread is served
// as well as one that answers inline.

#ifndef WK_AVF_RESOURCE_LOADER_DRAIN_H
#define WK_AVF_RESOURCE_LOADER_DRAIN_H

#import <AVFoundation/AVFoundation.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

// One drain's state, shared by the three synthetic request objects that carry it.
@interface WKAVFDrain : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableData *received;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic) long long contentLength;
@property (nonatomic) BOOL byteRangeAccessSupported;
@property (nonatomic) long long requestedOffset;
@property (nonatomic) long long requestedLength;
@property (nonatomic) BOOL finished;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) id infoRequest;
@property (nonatomic, strong) id dataRequest;
@property (nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation WKAVFDrain
@end

static const void * const wkAVFDrainKey = &wkAVFDrainKey;

static WKAVFDrain *wkAVFDrainOf(id request)
{
    return objc_getAssociatedObject(request, wkAVFDrainKey);
}

// A file that lives as long as the object it is attached to.
@interface WKAVFTemporaryFile : NSObject
@property (nonatomic, copy) NSString *path;
@end

@implementation WKAVFTemporaryFile
- (void)dealloc
{
    if (_path)
        [[NSFileManager defaultManager] removeItemAtPath:_path error:nil];
}
@end

static const void * const wkAVFTemporaryFileKey = &wkAVFTemporaryFileKey;
static const void * const wkAVFAssetOptionsKey = &wkAVFAssetOptionsKey;

// The UTI 10.9's AVFoundation expects wherever modern AVFoundation also accepts a MIME type.
static NSString *wkAVFContentTypeAsUTI(NSString *type)
{
    if (![type isKindOfClass:[NSString class]] || [type rangeOfString:@"/"].location == NSNotFound)
        return type;
    CFStringRef identifier = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)type, NULL);
    if (!identifier)
        return type;
    return CFBridgingRelease(identifier);
}

static Class wkAVFSubclass(const char *superclassName, const char *name, void (^addMethods)(Class))
{
    Class existing = objc_getClass(name);
    if (existing)
        return existing;
    Class superclass = objc_getClass(superclassName);
    if (!superclass)
        return Nil;
    Class subclass = objc_allocateClassPair(superclass, name, 0);
    if (!subclass)
        return objc_getClass(name);
    addMethods(subclass);
    objc_registerClassPair(subclass);
    return subclass;
}

#define WK_AVF_ADD(cls, sel, types, block) \
    class_addMethod((cls), @selector(sel), imp_implementationWithBlock(block), (types))

static Class wkAVFInfoRequestClass(void)
{
    return wkAVFSubclass("AVAssetResourceLoadingContentInformationRequest", "WKAVFContentInformationRequest", ^(Class c) {
        WK_AVF_ADD(c, contentType, "@@:", ^NSString *(id self) { return wkAVFDrainOf(self).contentType; });
        WK_AVF_ADD(c, setContentType:, "v@:@", ^(id self, NSString *type) { wkAVFDrainOf(self).contentType = type; });
        WK_AVF_ADD(c, contentLength, "q@:", ^long long(id self) { return wkAVFDrainOf(self).contentLength; });
        WK_AVF_ADD(c, setContentLength:, "v@:q", ^(id self, long long length) { wkAVFDrainOf(self).contentLength = length; });
        WK_AVF_ADD(c, isByteRangeAccessSupported, "c@:", ^BOOL(id self) { return wkAVFDrainOf(self).byteRangeAccessSupported; });
        WK_AVF_ADD(c, setByteRangeAccessSupported:, "v@:c", ^(id self, BOOL supported) { wkAVFDrainOf(self).byteRangeAccessSupported = supported; });
        WK_AVF_ADD(c, renewalDate, "@@:", ^NSDate *(id self) { return nil; });
        WK_AVF_ADD(c, setRenewalDate:, "v@:@", ^(id self, NSDate *date) { });
    });
}

static Class wkAVFDataRequestClass(void)
{
    return wkAVFSubclass("AVAssetResourceLoadingDataRequest", "WKAVFDataRequest", ^(Class c) {
        WK_AVF_ADD(c, requestedOffset, "q@:", ^long long(id self) { return wkAVFDrainOf(self).requestedOffset; });
        WK_AVF_ADD(c, requestedLength, "q@:", ^NSInteger(id self) { return (NSInteger)wkAVFDrainOf(self).requestedLength; });
        WK_AVF_ADD(c, currentOffset, "q@:", ^long long(id self) {
            WKAVFDrain *drain = wkAVFDrainOf(self);
            return drain.requestedOffset + (long long)drain.received.length;
        });
        WK_AVF_ADD(c, requestsAllDataToEndOfResource, "c@:", ^BOOL(id self) { return NO; });
        WK_AVF_ADD(c, respondWithData:, "v@:@", ^(id self, NSData *data) {
            if (data)
                [wkAVFDrainOf(self).received appendData:data];
        });
    });
}

static Class wkAVFLoadingRequestClass(void)
{
    return wkAVFSubclass("AVAssetResourceLoadingRequest", "WKAVFLoadingRequest", ^(Class c) {
        WK_AVF_ADD(c, request, "@@:", ^NSURLRequest *(id self) {
            return [NSURLRequest requestWithURL:wkAVFDrainOf(self).url];
        });
        WK_AVF_ADD(c, contentInformationRequest, "@@:", ^id(id self) { return wkAVFDrainOf(self).infoRequest; });
        WK_AVF_ADD(c, dataRequest, "@@:", ^id(id self) { return wkAVFDrainOf(self).dataRequest; });
        WK_AVF_ADD(c, isFinished, "c@:", ^BOOL(id self) { return wkAVFDrainOf(self).finished; });
        WK_AVF_ADD(c, isCancelled, "c@:", ^BOOL(id self) { return NO; });
        WK_AVF_ADD(c, redirect, "@@:", ^NSURLRequest *(id self) { return nil; });
        WK_AVF_ADD(c, setRedirect:, "v@:@", ^(id self, NSURLRequest *redirect) { });
        WK_AVF_ADD(c, response, "@@:", ^NSURLResponse *(id self) { return nil; });
        WK_AVF_ADD(c, setResponse:, "v@:@", ^(id self, NSURLResponse *response) { });
        WK_AVF_ADD(c, finishLoading, "v@:", ^(id self) {
            WKAVFDrain *drain = wkAVFDrainOf(self);
            if (drain.finished)
                return;
            drain.finished = YES;
            dispatch_semaphore_signal(drain.done);
        });
        WK_AVF_ADD(c, finishLoadingWithError:, "v@:@", ^(id self, NSError *error) {
            WKAVFDrain *drain = wkAVFDrainOf(self);
            if (drain.finished)
                return;
            drain.error = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil];
            drain.finished = YES;
            dispatch_semaphore_signal(drain.done);
        });
    });
}

// One round trip through the delegate. Answers the drain it filled, or nil.
static WKAVFDrain *wkAVFAsk(AVAssetResourceLoader *resourceLoader, id delegate, NSURL *url, BOOL wantsInfo, long long offset, long long length)
{
    Class loadingRequestClass = wkAVFLoadingRequestClass();
    Class dataRequestClass = wkAVFDataRequestClass();
    Class infoRequestClass = wkAVFInfoRequestClass();
    if (!loadingRequestClass || !dataRequestClass || !infoRequestClass)
        return nil;

    WKAVFDrain *drain = [[WKAVFDrain alloc] init];
    drain.url = url;
    drain.received = [NSMutableData data];
    drain.requestedOffset = offset;
    drain.requestedLength = length;
    drain.done = dispatch_semaphore_create(0);

    id loadingRequest = class_createInstance(loadingRequestClass, 0);
    id dataRequest = class_createInstance(dataRequestClass, 0);
    id infoRequest = wantsInfo ? class_createInstance(infoRequestClass, 0) : nil;
    if (!loadingRequest || !dataRequest || (wantsInfo && !infoRequest))
        return nil;

    drain.dataRequest = dataRequest;
    drain.infoRequest = infoRequest;
    objc_setAssociatedObject(loadingRequest, wkAVFDrainKey, drain, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(dataRequest, wkAVFDrainKey, drain, OBJC_ASSOCIATION_RETAIN);
    if (infoRequest)
        objc_setAssociatedObject(infoRequest, wkAVFDrainKey, drain, OBJC_ASSOCIATION_RETAIN);

    SEL shouldWait = @selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:);
    void (^ask)(void) = ^{
        ((BOOL (*)(id, SEL, id, id))objc_msgSend)(delegate, shouldWait, resourceLoader, loadingRequest);
    };
    dispatch_queue_t queue = resourceLoader.delegateQueue;
    if (queue)
        dispatch_sync(queue, ask);
    else
        ask();

    // AVFoundation waits for the delegate to finish the request it was handed; so does this.
    dispatch_semaphore_wait(drain.done, DISPATCH_TIME_FOREVER);
    if (drain.error)
        return nil;
    return drain;
}

// The bytes behind a resource-loader-backed asset, written to a file AVFoundation can type. Answers the
// path, or nil when the asset carries no delegate or the delegate does not describe the resource.
static NSString *wkAVFDrainAssetToFile(AVAsset *asset)
{
    if (![asset isKindOfClass:[AVURLAsset class]])
        return nil;
    AVURLAsset *urlAsset = (AVURLAsset *)asset;
    NSURL *url = urlAsset.URL;
    if (!url || url.isFileURL)
        return nil;
    AVAssetResourceLoader *resourceLoader = urlAsset.resourceLoader;
    id delegate = resourceLoader.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:)])
        return nil;

    // AVFoundation opens a resource by asking what it is alongside its first bytes.
    WKAVFDrain *head = wkAVFAsk(resourceLoader, delegate, url, YES, 0, 2);
    if (!head || head.contentLength <= 0)
        return nil;

    NSMutableData *whole = [NSMutableData dataWithCapacity:(NSUInteger)head.contentLength];
    [whole appendData:head.received];
    const long long chunk = 1 << 20;
    while ((long long)whole.length < head.contentLength) {
        long long remaining = head.contentLength - (long long)whole.length;
        WKAVFDrain *next = wkAVFAsk(resourceLoader, delegate, url, NO, (long long)whole.length,
            remaining < chunk ? remaining : chunk);
        if (!next || !next.received.length)
            return nil;
        [whole appendData:next.received];
    }

    NSString *extension = nil;
    NSString *uti = wkAVFContentTypeAsUTI(head.contentType);
    if (uti)
        extension = CFBridgingRelease(UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)uti, kUTTagClassFilenameExtension));
    NSString *name = extension.length ? [@"wkavf-XXXXXX" stringByAppendingFormat:@".%@", extension] : @"wkavf-XXXXXX";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    char *templatePath = strdup(path.fileSystemRepresentation);
    int fd = extension.length ? mkstemps(templatePath, (int)extension.length + 1) : mkstemp(templatePath);
    if (fd < 0) {
        free(templatePath);
        return nil;
    }
    close(fd);
    path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:templatePath length:strlen(templatePath)];
    free(templatePath);
    if (![whole writeToFile:path atomically:NO]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
    return path;
}

// The local asset standing in for a resource-loader-backed one: drained once, then reused, so every
// track and reader that comes out of it belongs to the same asset.
static const void * const wkAVFLocalAssetKey = &wkAVFLocalAssetKey;

static AVURLAsset *wkAVFLocalAssetFor(AVAsset *asset)
{
    if (![asset isKindOfClass:[AVURLAsset class]] || ((AVURLAsset *)asset).URL.isFileURL)
        return nil;
    AVURLAsset *local = objc_getAssociatedObject(asset, wkAVFLocalAssetKey);
    if (local)
        return local;

    NSString *path = wkAVFDrainAssetToFile(asset);
    if (!path)
        return nil;
    WKAVFTemporaryFile *file = [[WKAVFTemporaryFile alloc] init];
    file.path = path;
    NSDictionary *options = objc_getAssociatedObject(asset, wkAVFAssetOptionsKey);
    local = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:path] options:options];
    objc_setAssociatedObject(local, wkAVFTemporaryFileKey, file, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(asset, wkAVFLocalAssetKey, local, OBJC_ASSOCIATION_RETAIN);
    return local;
}

// The same track on the local asset a reader was given, when there is one. Never creates it: only an
// asset a reader has already been asked to read has one, so nothing else is drawn into the drain.
static AVAssetTrack *wkAVFLocalTrackFor(AVAssetTrack *track)
{
    AVURLAsset *local = objc_getAssociatedObject(track.asset, wkAVFLocalAssetKey);
    if (!local)
        return nil;
    for (AVAssetTrack *candidate in local.tracks) {
        if (candidate.trackID == track.trackID)
            return candidate;
    }
    return nil;
}

#undef WK_AVF_ADD

#endif // WK_AVF_RESOURCE_LOADER_DRAIN_H
