/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT (#137): see WKConnection.h. Body coding mirrors the removed legacy ObjCObjectGraph:
// a recursive WK-API-object graph. Container/value types map to WKDictionary/WKArray/WKString/WKDouble/
// WKData (which cross the bundle<->app IPC natively). The one non-codable type Mail puts in a body is the
// page controller (WKWebProcessPlugInBrowserContextController / WKBrowsingContextController); it is encoded
// as the page's cross-process WebPageProxyIdentifier and re-resolved on the far side to that process's
// controller for the same page (registered at controller-creation time). Any other NSCoding object falls
// back to an NSKeyedArchiver blob.

#import "config.h"
#import "WKConnectionInternal.h"

#import "WKArray.h"
#import "WKData.h"
#import "WKDictionary.h"
#import "WKMutableArray.h"
#import "WKMutableDictionary.h"
#import "WKNumber.h"
#import "WKString.h"
#import "WKStringCF.h"
#import "WKType.h"
#import <objc/runtime.h>

static NSString * const kWKConnectionControllerKey = @"$WKConnectionControllerPageID";
static NSString * const kWKConnectionArchiveKey = @"$WKConnectionArchive";

// pageProxyID(NSNumber) -> controller (weak, per-process). Reverse via an associated object on the
// controller so the encoder can recognise a registered controller without knowing its concrete class.
static NSMapTable *controllerRegistry()
{
    static NSMapTable *table = nil;
    if (!table)
        table = [[NSMapTable strongToWeakObjectsMapTable] retain];
    return table;
}

static const void* pageIDAssociationKey = &pageIDAssociationKey;

void WKConnectionRegisterController(uint64_t pageProxyID, id controller)
{
    if (!controller || !pageProxyID)
        return;
    [controllerRegistry() setObject:controller forKey:@(pageProxyID)];
    objc_setAssociatedObject(controller, pageIDAssociationKey, @(pageProxyID), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static WKStringRef createWKString(NSString *string)
{
    return WKStringCreateWithCFString((__bridge CFStringRef)string);
}

static WKTypeRef encodeObjC(id object)
{
    if (!object || object == [NSNull null])
        return nullptr;

    if (NSNumber *pageID = objc_getAssociatedObject(object, pageIDAssociationKey)) {
        WKMutableDictionaryRef dictionary = WKMutableDictionaryCreate();
        WKStringRef key = createWKString(kWKConnectionControllerKey);
        WKUInt64Ref value = WKUInt64Create([pageID unsignedLongLongValue]);
        WKDictionarySetItem(dictionary, key, value);
        WKRelease(key);
        WKRelease(value);
        return dictionary;
    }

    if ([object isKindOfClass:[NSString class]])
        return createWKString((NSString *)object);

    if ([object isKindOfClass:[NSNumber class]])
        return WKDoubleCreate([(NSNumber *)object doubleValue]);

    if ([object isKindOfClass:[NSData class]])
        return WKDataCreate(static_cast<const unsigned char*>([(NSData *)object bytes]), [(NSData *)object length]);

    if ([object isKindOfClass:[NSArray class]]) {
        WKMutableArrayRef array = WKMutableArrayCreate();
        for (id element in (NSArray *)object) {
            WKTypeRef encoded = encodeObjC(element);
            if (encoded) {
                WKArrayAppendItem(array, encoded);
                WKRelease(encoded);
            }
        }
        return array;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        WKMutableDictionaryRef dictionary = WKMutableDictionaryCreate();
        for (id key in (NSDictionary *)object) {
            if (![key isKindOfClass:[NSString class]])
                continue;
            WKTypeRef encoded = encodeObjC([(NSDictionary *)object objectForKey:key]);
            if (encoded) {
                WKStringRef wkKey = createWKString((NSString *)key);
                WKDictionarySetItem(dictionary, wkKey, encoded);
                WKRelease(wkKey);
                WKRelease(encoded);
            }
        }
        return dictionary;
    }

    // Fallback: any other NSCoding object travels as a keyed-archive blob.
    NSError *archiveError = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:&archiveError];
    if (!data) {
        NSLog(@"WKConnection: cannot encode message body component (%@): %@", [object class], archiveError);
        return nullptr;
    }
    WKMutableDictionaryRef dictionary = WKMutableDictionaryCreate();
    WKStringRef key = createWKString(kWKConnectionArchiveKey);
    WKDataRef value = WKDataCreate(static_cast<const unsigned char*>([data bytes]), [data length]);
    WKDictionarySetItem(dictionary, key, value);
    WKRelease(key);
    WKRelease(value);
    return dictionary;
}

static id decodeWK(WKTypeRef type)
{
    if (!type)
        return nil;

    WKTypeID typeID = WKGetTypeID(type);

    if (typeID == WKStringGetTypeID()) {
        CFStringRef cfString = WKStringCopyCFString(kCFAllocatorDefault, static_cast<WKStringRef>(type));
        return cfString ? [(__bridge NSString *)cfString autorelease] : nil;
    }

    if (typeID == WKDoubleGetTypeID())
        return [NSNumber numberWithDouble:WKDoubleGetValue(static_cast<WKDoubleRef>(type))];

    if (typeID == WKUInt64GetTypeID())
        return [NSNumber numberWithUnsignedLongLong:WKUInt64GetValue(static_cast<WKUInt64Ref>(type))];

    if (typeID == WKDataGetTypeID())
        return [NSData dataWithBytes:WKDataGetBytes(static_cast<WKDataRef>(type)) length:WKDataGetSize(static_cast<WKDataRef>(type))];

    if (typeID == WKArrayGetTypeID()) {
        WKArrayRef array = static_cast<WKArrayRef>(type);
        size_t count = WKArrayGetSize(array);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
        for (size_t i = 0; i < count; ++i) {
            id element = decodeWK(WKArrayGetItemAtIndex(array, i));
            [result addObject:element ? element : [NSNull null]];
        }
        return result;
    }

    if (typeID == WKDictionaryGetTypeID()) {
        WKDictionaryRef dictionary = static_cast<WKDictionaryRef>(type);

        WKStringRef controllerKey = createWKString(kWKConnectionControllerKey);
        WKTypeRef controllerValue = WKDictionaryGetItemForKey(dictionary, controllerKey);
        WKRelease(controllerKey);
        if (controllerValue && WKGetTypeID(controllerValue) == WKUInt64GetTypeID())
            return [controllerRegistry() objectForKey:@(WKUInt64GetValue(static_cast<WKUInt64Ref>(controllerValue)))];

        WKStringRef archiveKey = createWKString(kWKConnectionArchiveKey);
        WKTypeRef archiveValue = WKDictionaryGetItemForKey(dictionary, archiveKey);
        WKRelease(archiveKey);
        if (archiveValue && WKGetTypeID(archiveValue) == WKDataGetTypeID()) {
            NSData *data = [NSData dataWithBytes:WKDataGetBytes(static_cast<WKDataRef>(archiveValue)) length:WKDataGetSize(static_cast<WKDataRef>(archiveValue))];
            NSError *unarchiveError = nil;
            id unarchived = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:&unarchiveError];
            if (!unarchived)
                NSLog(@"WKConnection: cannot decode archived message body component: %@", unarchiveError);
            return unarchived;
        }

        WKArrayRef keys = WKDictionaryCopyKeys(dictionary);
        size_t count = WKArrayGetSize(keys);
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:count];
        for (size_t i = 0; i < count; ++i) {
            WKStringRef key = static_cast<WKStringRef>(WKArrayGetItemAtIndex(keys, i));
            CFStringRef cfKey = WKStringCopyCFString(kCFAllocatorDefault, key);
            id value = decodeWK(WKDictionaryGetItemForKey(dictionary, key));
            if (value && cfKey)
                [result setObject:value forKey:(__bridge NSString *)cfKey];
            if (cfKey)
                CFRelease(cfKey);
        }
        WKRelease(keys);
        return result;
    }

    return nil;
}

WKTypeRef WKConnectionCreateSerializedBody(id body)
{
    return encodeObjC(body);
}

id WKConnectionBodyFromSerialized(WKTypeRef serialized)
{
    return decodeWK(serialized);
}

@implementation WKConnection {
    WKConnectionSendBlock _sender;
}

@synthesize delegate = _delegate;

- (instancetype)initWithSender:(WKConnectionSendBlock)sender
{
    self = [super init];
    if (!self)
        return nil;
    _sender = [sender copy];
    return self;
}

- (void)dealloc
{
    [_sender release];
    [super dealloc];
}

- (void)sendMessageWithName:(NSString *)messageName body:(id)messageBody
{
    if (!_sender || !messageName)
        return;
    WKTypeRef serialized = WKConnectionCreateSerializedBody(messageBody);
    _sender(messageName, serialized);
    if (serialized)
        WKRelease(serialized);
}

- (void)_dispatchDidReceiveMessageWithName:(NSString *)messageName serializedBody:(WKTypeRef)serializedBody
{
    if ([_delegate respondsToSelector:@selector(connection:didReceiveMessageWithName:body:)])
        [_delegate connection:self didReceiveMessageWithName:messageName body:WKConnectionBodyFromSerialized(serializedBody)];
}

- (void)_dispatchDidClose
{
    if ([_delegate respondsToSelector:@selector(connectionDidClose:)])
        [_delegate connectionDidClose:self];
}

@end
