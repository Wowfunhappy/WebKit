// IOSurface: entry points and constants modern WebKit references that 10.9's IOSurface does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <mach/mach.h>

#pragma mark - IOSurface property keys (10.12+)
// kIOSurfaceName is the debug/identification name key IOSurface::optionsForSurface() adds to every
// surface-creation options dictionary (Source/WebCore/platform/graphics/cocoa/IOSurface.mm). It is
// 10.12+ and absent from 10.9's IOSurface.framework (every OTHER key that dictionary uses —
// kIOSurfaceWidth/Height/PixelFormat/BytesPerElement/BytesPerRow/AllocSize/ElementHeight — is present),
// so reading the absent extern under -undefined dynamic_lookup faulted on a null GOT load, SIGSEGVing
// WebContent inside WebGL/accelerated-canvas drawing-buffer allocation. It only labels the surface;
// IOSurfaceCreate ignores unknown keys on 10.9, so a valid CFString key restores creation with no
// behavioural change. The value matches the modern constant.
WK_POLYFILL_CONST("IOSurface", CFStringRef, kIOSurfaceName, CFSTR("IOSurfaceName"));

// IOSurfaceSetOwnershipIdentity (macOS 14.4) attributes an IOSurface's pages to another task's
// phys_footprint ledger. 10.9's IOSurface has no ledger-ownership call and no ledger to move pages
// into, so KERN_NOT_SUPPORTED is the honest answer -- the same one task_create_identity_token and
// mach_memory_entry_ownership in libSystem.m give, for the same absent-kernel-facility reason.
//
// IOSurface::setOwnershipIdentity (WebCore IOSurface.mm:791) reads the result and only
// RELEASE_LOG_ERRORs, and today it returns at :789 because a ProcessIdentity can never be non-empty
// on 10.9 (its constructor's task_create_identity_token fails). That value guard is why the call is
// unreachable now -- but it is a guard on a VALUE several frames from here, not a soft-link probe, so
// nothing about it is visible to the linker and nothing preserves it across a rebase. IOSurface.framework
// itself IS present on 10.9, but WebKit does not soft-link this symbol (no __TEXT,__cstring literal for
// it in WebCore), so there is no canLoad_ probe a gap-fill could flip.
WK_POLYFILL_ABSENT("IOSurface", kern_return_t, IOSurfaceSetOwnershipIdentity,
    (IOSurfaceRef buffer, task_id_token_t task_id_token, int newLedgerTag, uint32_t newLedgerOptions))
{
    (void)buffer; (void)task_id_token; (void)newLedgerTag; (void)newLedgerOptions;
    return KERN_NOT_SUPPORTED;
}
