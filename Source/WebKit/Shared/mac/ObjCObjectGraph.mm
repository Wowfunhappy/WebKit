/*
 * Copyright (C) 2012-2023 Apple Inc. All rights reserved.
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

// MAVERICKS_BACKPORT: see ObjCObjectGraph.h.

#import "config.h"
#import "ObjCObjectGraph.h"

#import "ArgumentCodersCocoa.h"
#import "Decoder.h"
#import "Encoder.h"
#import "GeneratedSerializers.h"
#import "UserData.h"
#import "WKAPICast.h"
#import "WKBrowsingContextHandleInternal.h"
#import "WKTypeRefWrapper.h"
#import <wtf/EnumTraits.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

namespace WebKit {

static bool shouldTransformGraph(id object, const ObjCObjectGraph::Transformer& transformer)
{
    if (NSArray *array = dynamic_objc_cast<NSArray>(object)) {
        for (id element in array) {
            if (shouldTransformGraph(element, transformer))
                return true;
        }
    }

    if (NSDictionary *dictionary = dynamic_objc_cast<NSDictionary>(object)) {
        bool result = false;
        [dictionary enumerateKeysAndObjectsUsingBlock:[&transformer, &result](id key, id object, BOOL* stop) {
            if (shouldTransformGraph(object, transformer)) {
                result = true;
                *stop = YES;
            }
        }];

        return result;
    }

    return transformer.shouldTransformObject(object);
}

static RetainPtr<id> transformGraph(id object, const ObjCObjectGraph::Transformer& transformer)
{
    if (NSArray *array = dynamic_objc_cast<NSArray>(object)) {
        auto result = adoptNS([[NSMutableArray alloc] initWithCapacity:array.count]);
        for (id element in array)
            [result addObject:transformGraph(element, transformer).get()];

        return result;
    }

    if (NSDictionary *dictionary = dynamic_objc_cast<NSDictionary>(object)) {
        auto result = adoptNS([[NSMutableDictionary alloc] initWithCapacity:dictionary.count]);
        [dictionary enumerateKeysAndObjectsUsingBlock:[&result, &transformer](id key, id object, BOOL*) {
            [result setObject:transformGraph(object, transformer).get() forKey:key];
        }];

        return result;
    }

    return transformer.transformObject(object);
}

RetainPtr<id> ObjCObjectGraph::transform(id object, const Transformer& transformer)
{
    if (!object)
        return nullptr;

    if (!shouldTransformGraph(object, transformer))
        return object;

    return transformGraph(object, transformer);
}

enum class ObjCType : uint8_t {
    Null,

    NSArray,
    NSData,
    NSDate,
    NSDictionary,
    NSNumber,
    NSString,

    WKBrowsingContextHandle,
    WKTypeRefWrapper,
};

} // namespace WebKit

namespace WTF {

// MAVERICKS_BACKPORT: WTF validates decoded enums through an explicit isValidEnum specialization.
template<> bool isValidEnum<WebKit::ObjCType>(std::underlying_type_t<WebKit::ObjCType> value)
{
    switch (static_cast<WebKit::ObjCType>(value)) {
    case WebKit::ObjCType::Null:
    case WebKit::ObjCType::NSArray:
    case WebKit::ObjCType::NSData:
    case WebKit::ObjCType::NSDate:
    case WebKit::ObjCType::NSDictionary:
    case WebKit::ObjCType::NSNumber:
    case WebKit::ObjCType::NSString:
    case WebKit::ObjCType::WKBrowsingContextHandle:
    case WebKit::ObjCType::WKTypeRefWrapper:
        return true;
    }
    return false;
}

} // namespace WTF

namespace WebKit {

static std::optional<ObjCType> typeFromObject(id object)
{
    ASSERT(object);

    if (dynamic_objc_cast<NSArray>(object))
        return ObjCType::NSArray;
    if (dynamic_objc_cast<NSData>(object))
        return ObjCType::NSData;
    if (dynamic_objc_cast<NSDate>(object))
        return ObjCType::NSDate;
    if (dynamic_objc_cast<NSDictionary>(object))
        return ObjCType::NSDictionary;
    if (dynamic_objc_cast<NSNumber>(object))
        return ObjCType::NSNumber;
    if (dynamic_objc_cast<NSString>(object))
        return ObjCType::NSString;

    if (dynamic_objc_cast<WKBrowsingContextHandle>(object))
        return ObjCType::WKBrowsingContextHandle;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (dynamic_objc_cast<WKTypeRefWrapper>(object))
        return ObjCType::WKTypeRefWrapper;
ALLOW_DEPRECATED_DECLARATIONS_END

    return std::nullopt;
}

void ObjCObjectGraph::encode(IPC::Encoder& encoder, id object)
{
    if (!object) {
        // MAVERICKS_BACKPORT: encoded at ObjCType's own width, which is what decode() reads.
        // encoder << static_cast<uint32_t>(ObjCType::Null);
        encoder << ObjCType::Null;
        return;
    }

    auto type = typeFromObject(object);
    if (!type)
        [NSException raise:NSInvalidArgumentException format:@"Can not encode objects of class type '%@'", static_cast<NSString *>(NSStringFromClass([object class]))];

    encoder << *type;

    switch (type.value()) {
    case ObjCType::Null:
        return;

    case ObjCType::NSArray: {
        NSArray *array = object;

        encoder << static_cast<uint64_t>(array.count);
        for (id element in array)
            encode(encoder, element);
        return;
    }

    case ObjCType::NSData: {
        // MAVERICKS_BACKPORT: the RetainPtr coder is the one decode() below reads with.
        encoder << RetainPtr { static_cast<NSData *>(object) };
        return;
    }

    case ObjCType::NSDate: {
        // MAVERICKS_BACKPORT: the RetainPtr coder is the one decode() below reads with.
        encoder << RetainPtr { static_cast<NSDate *>(object) };
        return;
    }

    case ObjCType::NSDictionary: {
        NSDictionary *dictionary = object;

        encoder << static_cast<uint64_t>(dictionary.count);
        [dictionary enumerateKeysAndObjectsUsingBlock:[&encoder](id key, id object, BOOL *stop) {
            encode(encoder, key);
            encode(encoder, object);
        }];
        return;
    }

    case ObjCType::NSNumber: {
        // MAVERICKS_BACKPORT: the RetainPtr coder is the one decode() below reads with.
        encoder << RetainPtr { static_cast<NSNumber *>(object) };
        return;
    }

    case ObjCType::NSString: {
        // MAVERICKS_BACKPORT: the RetainPtr coder is the one decode() below reads with.
        encoder << RetainPtr { static_cast<NSString *>(object) };
        return;
    }

    case ObjCType::WKBrowsingContextHandle: {
        // MAVERICKS_BACKPORT: the handle holds its page proxy ID as a Markable and its web page ID as a raw uint64_t.
        encoder << *static_cast<WKBrowsingContextHandle *>(object).pageProxyID;
        encoder << ObjectIdentifier<WebCore::PageIdentifierType>(static_cast<WKBrowsingContextHandle *>(object).webPageID);
        return;
    }

    case ObjCType::WKTypeRefWrapper: {
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        // MAVERICKS_BACKPORT: the wrapped API object travels through UserData's generated coder.
        encoder << UserData(RefPtr { toImpl(static_cast<WKTypeRefWrapper *>(object).object) });
ALLOW_DEPRECATED_DECLARATIONS_END
        return;
    }
    }

    ASSERT_NOT_REACHED();
}

bool ObjCObjectGraph::decode(IPC::Decoder& decoder, RetainPtr<id>& result)
{
    // MAVERICKS_BACKPORT: IPC::Decoder decodes into std::optional.
    auto type = decoder.decode<ObjCType>();
    if (!type)
        return false;

    switch (*type) {
    case ObjCType::Null: {
        result = nil;
        return true;
    }

    case ObjCType::NSArray: {
        // MAVERICKS_BACKPORT: IPC::Decoder decodes into std::optional.
        auto size = decoder.decode<uint64_t>();
        if (!size)
            return false;

        auto array = adoptNS([[NSMutableArray alloc] init]);
        for (uint64_t i = 0; i < *size; ++i) {
            RetainPtr<id> element;
            if (!decode(decoder, element))
                return false;
            [array addObject:element.get()];
        }

        result = WTF::move(array);
        return true;
    }

    case ObjCType::NSData: {
        std::optional<RetainPtr<NSData>> data = decoder.decode<RetainPtr<NSData>>();
        if (!data)
            return false;

        result = WTF::move(*data);
        return true;
    }

    case ObjCType::NSDate: {
        std::optional<RetainPtr<NSDate>> date = decoder.decode<RetainPtr<NSDate>>();
        if (!date)
            return false;

        result = WTF::move(*date);
        return true;
    }

    case ObjCType::NSDictionary: {
        // MAVERICKS_BACKPORT: IPC::Decoder decodes into std::optional.
        auto size = decoder.decode<uint64_t>();
        if (!size)
            return false;

        auto dictionary = adoptNS([[NSMutableDictionary alloc] init]);
        for (uint64_t i = 0; i < *size; ++i) {
            RetainPtr<id> key;
            if (!decode(decoder, key))
                return false;

            RetainPtr<id> object;
            if (!decode(decoder, object))
                return false;

            @try {
                [dictionary setObject:object.get() forKey:key.get()];
            } @catch (id) {
                return false;
            }
        }

        result = WTF::move(dictionary);
        return true;
    }

    case ObjCType::NSNumber: {
        std::optional<RetainPtr<NSNumber>> number = decoder.decode<RetainPtr<NSNumber>>();
        if (!number)
            return false;

        result = WTF::move(*number);
        return true;
    }

    case ObjCType::NSString: {
        std::optional<RetainPtr<NSString>> string = decoder.decode<RetainPtr<NSString>>();
        if (!string)
            return false;

        result = WTF::move(*string);
        return true;
    }

    case ObjCType::WKBrowsingContextHandle: {
        std::optional<WebPageProxyIdentifier> pageProxyID;
        decoder >> pageProxyID;
        if (!pageProxyID)
            return false;
        std::optional<WebCore::PageIdentifier> webPageID;
        decoder >> webPageID;
        if (!webPageID)
            return false;

        result = adoptNS([[WKBrowsingContextHandle alloc] _initWithPageProxyID:*pageProxyID andWebPageID:*webPageID]);
        return true;
    }

    case ObjCType::WKTypeRefWrapper: {
        // MAVERICKS_BACKPORT: the wrapped API object travels through UserData's generated coder.
        auto userData = decoder.decode<UserData>();
        if (!userData)
            return false;

ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        result = adoptNS([[WKTypeRefWrapper alloc] initWithObject:toAPI(userData->object())]);
ALLOW_DEPRECATED_DECLARATIONS_END
        return true;
    }
    }

    ASSERT_NOT_REACHED();
    return false;
}

} // namespace WebKit

namespace IPC {

std::optional<Ref<WebKit::ObjCObjectGraph>> ArgumentCoder<WebKit::ObjCObjectGraph>::decode(IPC::Decoder& decoder)
{
    RetainPtr<id> rootObject;
    if (!WebKit::ObjCObjectGraph::decode(decoder, rootObject))
        return std::nullopt;

    return WebKit::ObjCObjectGraph::create(rootObject.get());
}

void ArgumentCoder<WebKit::ObjCObjectGraph>::encode(IPC::Encoder& encoder, const WebKit::ObjCObjectGraph& object)
{
    WebKit::ObjCObjectGraph::encode(encoder, object.rootObject());
}

} // namespace IPC
