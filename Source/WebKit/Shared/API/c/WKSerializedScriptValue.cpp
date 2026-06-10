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

#include "config.h"
#include "WKSerializedScriptValue.h"

#include "APISerializedScriptValue.h"
#include "WKSharedAPICast.h"

// 10.9 backport: upstream gutted these functions to return null, but Safari 7
// still uses them — WKPageRunJavaScriptInMainFrame results are handed to
// WKSerializedScriptValueDeserialize ("do JavaScript" returned "missing value"
// with the null stub), and WKSerializedScriptValueCreate serializes values for
// injected-bundle/extension messaging. Reimplemented on top of
// WebKit::JavaScriptEvaluationResult (see APISerializedScriptValue.h).

WKTypeID WKSerializedScriptValueGetTypeID()
{
    return WebKit::toAPI(API::SerializedScriptValue::APIType);
}

WKSerializedScriptValueRef WKSerializedScriptValueCreate(JSContextRef context, JSValueRef value, JSValueRef*)
{
    auto serializedValue = API::SerializedScriptValue::createFromJS(context, value);
    if (!serializedValue)
        return nullptr;
    return WebKit::toAPI(&serializedValue.releaseNonNull().leakRef());
}

JSValueRef WKSerializedScriptValueDeserialize(WKSerializedScriptValueRef valueRef, JSContextRef context, JSValueRef*)
{
    // Be liberal in what we accept: Safari treats whatever WKTypeRef arrives in
    // the WKPageRunJavaScriptInMainFrame callback as a WKSerializedScriptValueRef,
    // so verify the dynamic type before downcasting.
    auto* object = WebKit::toImpl(reinterpret_cast<WKTypeRef>(valueRef));
    if (!object || object->type() != API::Object::Type::SerializedScriptValue)
        return nullptr;
    return static_cast<API::SerializedScriptValue*>(object)->deserialize(context);
}
