// The "resume exactly once per object" rule behind the dispatch_activate polyfill, as ONE static
// definition shared by the polyfill body (system-spi.m) and its probe (tests/wk_dispatch_activate.m)
// — the same arrangement scrollview-inset-tile.h uses, so the probe exercises the shipped logic
// rather than a copy of it.
//
// 10.9 has no dispatch_activate, only dispatch_resume. On a freshly-created object the two are
// equivalent, but activate is defined to be idempotent and resume is not: a second resume on an
// active object is an over-resume, and on a source it starts delivering events nobody asked for.
// So the polyfill has to remember which objects it has already resumed.
//
// That memory MUST be keyed to the object, not to its address. dispatch_source_create() returns a
// SUSPENDED source and the allocator hands a released source's address straight back, so an
// address-keyed table sees a recycled address, concludes "already activated", and never resumes the
// new source — its timer silently never fires. An earlier version of this polyfill did exactly that
// and wedged 196 of 200 sources. An associated object is destroyed with the object it hangs off, so
// a recycled address arrives unmarked.

#ifndef WK_DISPATCH_ACTIVATE_ONCE_H
#define WK_DISPATCH_ACTIVATE_ONCE_H

#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <stdbool.h>

// Which objects "activate" actually has to start. dispatch_activate's contract is "make this
// object active, and do nothing if it already is" -- so what matters is which 10.9 objects are born
// inactive. Exactly one kind is: dispatch_source_create() returns a SUSPENDED source. Queues,
// groups and semaphores are all born active (10.9 has no DISPATCH_QUEUE_*_INACTIVE), and
// dispatch_resume() on an already-active object is an over-resume -- which is not a subtle
// mis-accounting but an immediate SIGILL. Measured on this OS: resuming a dispatch_queue_create()
// queue kills the process on the spot.
//
// So resume sources, and no-op everything else, which is what the real dispatch_activate does for
// an already-active object. Discriminating on the object rather than on "WebKit only passes
// sources" is the whole point: the callers that make this file's claim true must be any callers,
// not today's two.
// Pure <objc/runtime.h>: no Foundation, and no message sends to an object whose class is exactly
// what is in question. Walks the ancestry rather than comparing one class, so a subclass of
// OS_dispatch_source still counts as a source.
static inline bool wkDispatchObjectIsBornSuspended(id object)
{
    Class sourceClass = objc_getClass("OS_dispatch_source");
    if (!sourceClass)
        return false;
    for (Class candidate = object_getClass(object); candidate; candidate = class_getSuperclass(candidate)) {
        if (candidate == sourceClass)
            return true;
    }
    return false;
}

static const void* const wkDispatchActivatedKey = &wkDispatchActivatedKey;

// True the first time it is asked about a given object, false every time after. Serialized on the
// object, so concurrent activations of the same object still resume it exactly once.
static inline bool wkMarkDispatchObjectActivated(id object)
{
    bool isFirstActivation = false;
    @synchronized (object) {
        if (!objc_getAssociatedObject(object, wkDispatchActivatedKey)) {
            // The value is only ever tested for non-nil, so associate the key itself under
            // OBJC_ASSOCIATION_ASSIGN: nothing retains, releases or messages it, which keeps this
            // header free of any Foundation dependency. The association still dies with the object,
            // which is the whole point of using one.
            objc_setAssociatedObject(object, wkDispatchActivatedKey, (id)wkDispatchActivatedKey, OBJC_ASSOCIATION_ASSIGN);
            isFirstActivation = true;
        }
    }
    return isFirstActivation;
}

// dispatch objects are ObjC objects when OS_OBJECT_USE_OBJC is on, which is what makes per-object
// storage available. This port always compiles with it on. There is no fallback for the other case
// on purpose: without per-object storage the only options are an over-resume or an address-keyed
// mark, and both are defects. Fail the build instead of shipping a path known to be wrong.
#if !defined(OS_OBJECT_USE_OBJC) || !OS_OBJECT_USE_OBJC
#error "dispatch_activate's exactly-once mark needs OS_OBJECT_USE_OBJC; see the note above."
#endif

static inline void wkDispatchActivateOnce(dispatch_object_t object)
{
    if (!object)
        return;
    // Already active on this OS: activating is defined to do nothing, and resuming would crash.
    if (!wkDispatchObjectIsBornSuspended((id)object))
        return;
    if (wkMarkDispatchObjectActivated((id)object))
        dispatch_resume(object);
}

#endif // WK_DISPATCH_ACTIVATE_ONCE_H
