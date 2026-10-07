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

// AQUAWEBKIT: Safari 7 uses this API for extension messaging and "do JavaScript" results,
// backed by API::SerializedScriptValue.
#include "APISerializedScriptValue.h"
#include "WKSharedAPICast.h"

// AQUAWEBKIT: API::SerializedScriptValue's type id.
WKTypeID WKSerializedScriptValueGetTypeID()
{
    // return 0;
    return WebKit::toAPI(API::SerializedScriptValue::APIType);
}

// WKSerializedScriptValueRef WKSerializedScriptValueCreate(JSContextRef, JSValueRef, JSValueRef*)
// AQUAWEBKIT: serializes into an API::SerializedScriptValue.
WKSerializedScriptValueRef WKSerializedScriptValueCreate(JSContextRef context, JSValueRef value, JSValueRef* exception)
{
    // return nullptr;
    auto serializedValue = API::SerializedScriptValue::create(context, value, exception);
    return WebKit::toAPI(serializedValue.leakRef());
}

// JSValueRef WKSerializedScriptValueDeserialize(WKSerializedScriptValueRef, JSContextRef, JSValueRef*)
// AQUAWEBKIT: deserializes the API::SerializedScriptValue into the given context.
JSValueRef WKSerializedScriptValueDeserialize(WKSerializedScriptValueRef scriptValueRef, JSContextRef contextRef, JSValueRef* exception)
{
    // return nullptr;
    return WebKit::toImpl(scriptValueRef)->deserialize(contextRef, exception);
}
