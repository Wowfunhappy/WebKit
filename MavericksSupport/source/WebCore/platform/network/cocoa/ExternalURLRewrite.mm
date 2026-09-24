/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "config.h"
#import "ExternalURLRewrite.h"

#import "HTTPHeaderMap.h"
#import <atomic>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mutex>
#import <wtf/Lock.h>
#import <wtf/RetainPtr.h>

namespace WebCore {

using ExternalURLRewriteFunction = CFURLRef (*)(CFURLRef, CFMutableDictionaryRef);

// Each added image bumps addedGeneration; a search covers every image up to the generation it read.
static std::atomic<uint64_t> addedGeneration;
static std::atomic<uint64_t> searchedGeneration;
static std::atomic<ExternalURLRewriteFunction> foundFunction;
static Lock searchLock;

static void imageAdded(const struct mach_header*, intptr_t)
{
    addedGeneration.fetch_add(1, std::memory_order_acq_rel);
}

static ExternalURLRewriteFunction externalURLRewriteFunction()
{
    if (auto function = foundFunction.load(std::memory_order_acquire))
        return function;

    static std::once_flag once;
    // Registration reports every image already loaded.
    std::call_once(once, [] {
        _dyld_register_func_for_add_image(imageAdded);
    });
    if (searchedGeneration.load(std::memory_order_acquire) == addedGeneration.load(std::memory_order_acquire))
        return nullptr;

    Locker locker { searchLock };
    auto generation = addedGeneration.load(std::memory_order_acquire);
    if (auto function = foundFunction.load(std::memory_order_acquire))
        return function;
    if (searchedGeneration.load(std::memory_order_acquire) == generation)
        return nullptr;

    ExternalURLRewriteFunction function = nullptr;
    Dl_info info;
    // The handle is never closed, so the function's image stays loaded.
    if (auto* symbol = dlsym(RTLD_DEFAULT, "WKExternalURLRewrite"); symbol && dladdr(symbol, &info) && info.dli_fname && dlopen(info.dli_fname, RTLD_NOLOAD))
        function = reinterpret_cast<ExternalURLRewriteFunction>(symbol);
    if (function)
        foundFunction.store(function, std::memory_order_release);
    searchedGeneration.store(generation, std::memory_order_release);
    return function;
}

// Header names compare ignoring ASCII case, as HTTP and HTTPHeaderMap compare them.
static Boolean headerNamesEqual(const void* a, const void* b)
{
    if (CFGetTypeID(a) != CFStringGetTypeID() || CFGetTypeID(b) != CFStringGetTypeID())
        return CFEqual(a, b);
    auto first = static_cast<CFStringRef>(a);
    auto second = static_cast<CFStringRef>(b);
    CFIndex length = CFStringGetLength(first);
    if (length != CFStringGetLength(second))
        return false;
    for (CFIndex i = 0; i < length; ++i) {
        if (toASCIILower(CFStringGetCharacterAtIndex(first, i)) != toASCIILower(CFStringGetCharacterAtIndex(second, i)))
            return false;
    }
    return true;
}

static CFHashCode headerNameHash(const void* value)
{
    if (CFGetTypeID(value) != CFStringGetTypeID())
        return CFHash(value);
    auto name = static_cast<CFStringRef>(value);
    CFHashCode hash = 0;
    for (CFIndex i = 0, length = CFStringGetLength(name); i < length; ++i)
        hash = hash * 31 + toASCIILower(CFStringGetCharacterAtIndex(name, i));
    return hash;
}

static RetainPtr<CFMutableDictionaryRef> createHeaderDictionary(const HTTPHeaderMap& fields)
{
    auto keyCallBacks = kCFTypeDictionaryKeyCallBacks;
    keyCallBacks.equal = headerNamesEqual;
    keyCallBacks.hash = headerNameHash;
    auto headers = adoptCF(CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallBacks, &kCFTypeDictionaryValueCallBacks));
    for (auto& field : fields)
        CFDictionarySetValue(headers.get(), field.key.createCFString().get(), field.value.createCFString().get());
    return headers;
}

// Makes the request's header fields those in headers; a field it keeps stays where it was. Only string
// names and values are header fields.
static void applyHeaders(ResourceRequest& request, CFDictionaryRef headers)
{
    for (auto& field : HTTPHeaderMap { request.httpHeaderFields() }) {
        auto value = static_cast<CFTypeRef>(CFDictionaryGetValue(headers, field.key.createCFString().get()));
        if (!value || CFGetTypeID(value) != CFStringGetTypeID())
            request.removeHTTPHeaderField(field.key);
    }
    auto count = CFDictionaryGetCount(headers);
    Vector<const void*> names(count);
    Vector<const void*> values(count);
    CFDictionaryGetKeysAndValues(headers, names.mutableSpan().data(), values.mutableSpan().data());
    for (CFIndex i = 0; i < count; ++i) {
        if (CFGetTypeID(names[i]) != CFStringGetTypeID() || CFGetTypeID(values[i]) != CFStringGetTypeID())
            continue;
        String name { static_cast<CFStringRef>(names[i]) };
        String value { static_cast<CFStringRef>(values[i]) };
        if (auto existing = request.httpHeaderField(name); !existing.isNull() && existing == value)
            continue;
        request.setHTTPHeaderField(name, value);
    }
}

URL applyExternalURLRewrite(ResourceRequest& request)
{
    auto function = externalURLRewriteFunction();
    if (!function)
        return { };
    auto url = request.url().createCFURL();
    if (!url)
        return { };
    auto headers = createHeaderDictionary(request.httpHeaderFields());
    auto connectionCFURL = adoptCF(function(url.get(), headers.get()));
    applyHeaders(request, headers.get());
    if (!connectionCFURL)
        return { };
    URL connectionURL { connectionCFURL.get() };
    if (connectionURL == request.url())
        return { };
    return connectionURL;
}

} // namespace WebCore
