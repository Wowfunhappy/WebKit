/*
 * Copyright (C) 2010 Apple Inc. All rights reserved.
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

#pragma once

// MAVERICKS_BACKPORT: includes for the WKSerializedScriptValue carrier below.
#include "APIObject.h"
#include <JavaScriptCore/JSRetainPtr.h>
#include <WebCore/SerializedScriptValue.h>

namespace API {

// MAVERICKS_BACKPORT: Safari 7 carries extension messages and WKPageRunJavaScriptInMainFrame results
// as WKSerializedScriptValueRefs. This is upstream's carrier from before bug 277594 deprecated that C
// API: a WebCore::SerializedScriptValue structured clone, which deserializes into any number of
// contexts.
// struct SerializedScriptValue {
class SerializedScriptValue final : public ObjectImpl<Object::Type::SerializedScriptValue> {
public:
    static JSRetainPtr<JSGlobalContextRef> deserializationContext();

    // MAVERICKS_BACKPORT: the carrier's upstream interface (see above).
    static Ref<SerializedScriptValue> create(Ref<WebCore::SerializedScriptValue>&& serializedValue)
    {
        return adoptRef(*new SerializedScriptValue(WTF::move(serializedValue)));
    }

    static RefPtr<SerializedScriptValue> create(JSContextRef context, JSValueRef value, JSValueRef* exception)
    {
        RefPtr serializedValue = WebCore::SerializedScriptValue::create(context, value, exception);
        if (!serializedValue)
            return nullptr;
        return create(serializedValue.releaseNonNull());
    }

    JSValueRef deserialize(JSContextRef context, JSValueRef* exception)
    {
        return m_serializedScriptValue->deserialize(context, exception);
    }

    Ref<WebCore::SerializedScriptValue> internalRepresentation() const { return m_serializedScriptValue; }

private:
    explicit SerializedScriptValue(Ref<WebCore::SerializedScriptValue>&& serializedScriptValue)
        : m_serializedScriptValue(WTF::move(serializedScriptValue))
    {
    }

    const Ref<WebCore::SerializedScriptValue> m_serializedScriptValue;
};
    
}

// MAVERICKS_BACKPORT: type traits for the WKSerializedScriptValue carrier above.
SPECIALIZE_TYPE_TRAITS_API_OBJECT(SerializedScriptValue);
