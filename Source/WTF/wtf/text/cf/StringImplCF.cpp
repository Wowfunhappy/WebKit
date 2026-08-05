/*
 * Copyright (C) 2006, 2009, 2012 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#include "config.h"
#include <wtf/text/StringImpl.h>

#if USE(CF)

#include <CoreFoundation/CoreFoundation.h>
// MAVERICKS_BACKPORT: for the dlsym that reads the Objective-C GC flag below.
#include <dlfcn.h>
#include <wtf/DebugHeap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>
#include <wtf/Threading.h>

namespace WTF {

// MAVERICKS_BACKPORT: whether this process runs Objective-C garbage collection — see the
// note in RetainPtr.h. Resolved through dlsym because the modern SDK's <objc/objc-auto.h>
// inlines objc_collectingEnabled() to a hard NO, and so that binaries that do not link
// libobjc (the build-time tools) still link this file. In a process without libobjc the
// lookup fails and the flag stays false, which is also correct.
bool g_objCGCIsEnabled = false;

// Priority 101 (the lowest an application may use) so this runs before every
// default-priority initializer in the image. Ordering matters: a RetainPtr constructed
// before the flag is read would take a no-op [retain] and later be released with a real
// CFRelease, underflowing the collector's external reference count.
static void initializeObjCGCIsEnabled() __attribute__((constructor(101)));
static void initializeObjCGCIsEnabled()
{
    if (auto collectingEnabled = reinterpret_cast<signed char (*)()>(dlsym(RTLD_DEFAULT, "objc_collectingEnabled")))
        g_objCGCIsEnabled = collectingEnabled();
}

namespace StringWrapperCFAllocator {

    DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER_AND_EXPORT(StringWrapperCFAllocator, WTF_INTERNAL);
    DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(StringWrapperCFAllocator);

    static RefPtr<StringImpl>& NODELETE currentString()
    {
        static NeverDestroyed<RefPtr<StringImpl>> currentString;
        return currentString;
    }

    struct StringImplWrapper {
        RefPtr<StringImpl> m_stringImpl;
    };

    static const void* NODELETE retain(const void* info)
    {
        return info;
    }

    NO_RETURN_DUE_TO_ASSERT
    static void NODELETE release(const void*)
    {
        ASSERT_NOT_REACHED();
    }

    static CFStringRef NODELETE copyDescription(const void*)
    {
        return CFSTR("WTF::String-based allocator");
    }

    static void* allocate(CFIndex size, CFOptionFlags, void*)
    {
        RefPtr<StringImpl> underlyingString;
        if (isMainThread())
            underlyingString = std::exchange(currentString(), nullptr);

        auto [ wrapper, trailingBytes ] = createWithTrailingBytes<StringImplWrapper, StringWrapperCFAllocatorMalloc>(size, StringImplWrapper { WTF::move(underlyingString) });
        return trailingBytes;
    }

    static void* reallocate(void* pointer, CFIndex newSize, CFOptionFlags, void*)
    {
        auto [ prevWrapper, prevTrailingBytes ] = fromTrailingBytes<StringImplWrapper>(pointer);
        auto [ wrapper, trailingBytes ] = reallocWithTrailingBytes<StringImplWrapper, StringWrapperCFAllocatorMalloc>(prevWrapper, newSize);
        ASSERT(!wrapper->m_stringImpl);
        return trailingBytes;
    }

    static void deallocate(void* pointer, void*)
    {
        auto [ wrapper, trailingBytes ] = fromTrailingBytes<StringImplWrapper>(pointer);
        if (!wrapper->m_stringImpl)
            destroyWithTrailingBytes<StringImplWrapper, StringWrapperCFAllocatorMalloc>(wrapper);
        else {
            ensureOnMainThread([wrapper = wrapper] {
                destroyWithTrailingBytes<StringImplWrapper, StringWrapperCFAllocatorMalloc>(wrapper);
            });
        }
    }

    static CFIndex NODELETE preferredSize(CFIndex size, CFOptionFlags, void*)
    {
        // FIXME: If FastMalloc provided a "good size" callback, we'd want to use it here.
        // Note that this optimization would help performance for strings created with the
        // allocator that are mutable, and those typically are only created by callers who
        // make a new string using the old string's allocator, such as some of the call
        // sites in CFURL.
        return size;
    }

    static CFAllocatorRef allocatorSingleton()
    {
        ASSERT(isMainThread());
        static NeverDestroyed allocator = [] {
            initializeMainThread();
            CFAllocatorContext context = { 0, nullptr, retain, release, copyDescription, allocate, reallocate, deallocate, preferredSize };
            return adoptCF(CFAllocatorCreate(nullptr, &context));
        }();
        return allocator.get().get();
    }

}

RetainPtr<CFStringRef> StringImpl::createCFString()
{
    // MAVERICKS_BACKPORT: a custom CFAllocator yields non-collectable objects, which must
    // not enter a garbage-collected process's object graph (CF logs "storing a non-GC
    // object in a GC collection" and the collector cannot manage their lifetime) — take
    // the default-allocator copying path instead, as WebKit did in its own -fobjc-gc era.
    if (!m_length || !isMainThread() || objCGCIsEnabled()) {
        if (is8Bit()) {
            auto characters = span8();
            return adoptCF(CFStringCreateWithBytes(nullptr, byteCast<UInt8>(characters.data()), characters.size(), kCFStringEncodingISOLatin1, false));
        }
        auto characters = span16();
        return adoptCF(CFStringCreateWithCharacters(nullptr, reinterpret_cast<const UniChar*>(characters.data()), characters.size()));
    }

    // Put pointer to the StringImpl in a global so the allocator can store it with the CFString.
    ASSERT(!StringWrapperCFAllocator::currentString());
    StringWrapperCFAllocator::currentString() = this;

    RetainPtr<CFStringRef> string;
    if (is8Bit()) {
        auto characters = span8();
        string = adoptCF(CFStringCreateWithBytesNoCopy(StringWrapperCFAllocator::allocatorSingleton(), byteCast<UInt8>(characters.data()), characters.size(), kCFStringEncodingISOLatin1, false, kCFAllocatorNull));
    } else {
        auto characters = span16();
        string = adoptCF(CFStringCreateWithCharactersNoCopy(StringWrapperCFAllocator::allocatorSingleton(), reinterpret_cast<const UniChar*>(characters.data()), characters.size(), kCFAllocatorNull));
    }
    // CoreFoundation might not have to allocate anything, we clear currentString() in case we did not execute allocate().
    StringWrapperCFAllocator::currentString() = nullptr;

    return string;
}

// On StringImpl creation we could check if the allocator is the StringWrapperCFAllocator.
// If it is, then we could find the original StringImpl and just return that. But to
// do that we'd have to compute the offset from CFStringRef to the allocated block;
// the CFStringRef is *not* at the start of an allocated block. Testing shows 1000x
// more calls to createCFString than calls to the create functions with the appropriate
// allocator, so it's probably not urgent optimize that case.

}

#endif // USE(CF)
