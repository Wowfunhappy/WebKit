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

// MAVERICKS_BACKPORT: extra includes for the restored legacy WKSerializedScriptValue support
// (API::Object base, JavaScriptEvaluationResult value transfer, JSContextRef conversions).
#include "APIObject.h"
#include "JavaScriptEvaluationResult.h"
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSRetainPtr.h>

namespace API {

// MAVERICKS_BACKPORT: legacy WKSerializedScriptValue support.
//
// Upstream removed the WKSerializedScriptValue implementation (the C API
// functions were gutted to return null), but Safari 7 still round-trips
// JavaScript values through it: results of WKPageRunJavaScriptInMainFrame
// are handed to WKSerializedScriptValueDeserialize, and values are
// serialized with WKSerializedScriptValueCreate (e.g. for extension
// messaging). This class wraps the modern value-transfer representation,
// WebKit::JavaScriptEvaluationResult, in an API::Object so the legacy C
// functions can carry it across the API boundary (and over IPC) and convert
// it to/from a JSValueRef in the caller's JSContext.
class SerializedScriptValue final : public ObjectImpl<Object::Type::SerializedScriptValue> {
public:
    // MAVERICKS_BACKPORT: legacy WKSerializedScriptValue support.
    // Used by the GLib ports only (APISerializedScriptValue.cpp is not built on Mac).
    static JSRetainPtr<JSGlobalContextRef> deserializationContext();

    // MAVERICKS_BACKPORT: factory wrapping WebKit::JavaScriptEvaluationResult for the legacy C API.
    static Ref<SerializedScriptValue> create(WebKit::JavaScriptEvaluationResult&& result)
    {
        return adoptRef(*new SerializedScriptValue(WTF::move(result)));
    }

    static RefPtr<SerializedScriptValue> createFromJS(JSContextRef context, JSValueRef value)
    {
        if (!context || !value)
            return nullptr;
        auto result = WebKit::JavaScriptEvaluationResult::extract(JSContextGetGlobalContext(context), value);
        if (!result)
            return nullptr;
        return create(WTF::move(*result));
    }

    // Converts the held value into the given context. This consumes the held
    // value (JavaScriptEvaluationResult::toJS is one-shot); a second call
    // returns undefined. Callers (Safari) deserialize exactly once.
    JSValueRef deserialize(JSContextRef context)
    {
        if (!context)
            return nullptr;
        return m_result.toJS(JSContextGetGlobalContext(context)).get();
    }

    const WebKit::JavaScriptEvaluationResult& result() const LIFETIME_BOUND { return m_result; }

private:
    explicit SerializedScriptValue(WebKit::JavaScriptEvaluationResult&& result)
        : m_result(WTF::move(result))
    {
    }

    // MAVERICKS_BACKPORT: held value backing the restored legacy WKSerializedScriptValue API.
    WebKit::JavaScriptEvaluationResult m_result;
};
    
}

// MAVERICKS_BACKPORT: type-traits specialization for the restored API::SerializedScriptValue
// (legacy WKSerializedScriptValue support); absent upstream where the class was a bare struct.
SPECIALIZE_TYPE_TRAITS_API_OBJECT(SerializedScriptValue);
