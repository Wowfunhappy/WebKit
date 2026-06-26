#pragma once
// Minimal stub for MAVERICKS_BACKPORT

#if ENABLE(PDF_PLUGIN)

#include "PDFPluginIdentifier.h"
// MAVERICKS_BACKPORT: include set reduced to what the stubbed (download-only) PDF base needs.
#include <WebCore/FrameIdentifier.h>
#include <wtf/CompletionHandler.h>
// MAVERICKS_BACKPORT: include set reduced to what the stubbed (download-only) PDF base needs.
#include <wtf/Forward.h>
#include <wtf/Identified.h>
#include <wtf/ThreadSafeRefCounted.h>
// MAVERICKS_BACKPORT: include set reduced to what the stubbed (download-only) PDF base needs.
#include <wtf/URL.h>
#include <wtf/WeakPtr.h>
// MAVERICKS_BACKPORT: include set reduced to what the stubbed (download-only) PDF base needs.
#include <wtf/CheckedPtr.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

// MAVERICKS_BACKPORT: pared-down base class for the stubbed (download-only) PDF path; keeps the identity/refcount bases other code links against, drops the full ScrollableArea/plugin surface.
class PDFPluginBase : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<PDFPluginBase, WTF::DestructionThread::Main>, public CanMakeWeakPtr<PDFPluginBase>, public CanMakeThreadSafeCheckedPtr<PDFPluginBase>, public Identified<PDFPluginIdentifier> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(PDFPluginBase);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(PDFPluginBase);
public:
    // MAVERICKS_BACKPORT: inline PDFs DOWNLOAD on 10.9; only the minimal API surface still referenced elsewhere is kept as no-op stubs.
    virtual ~PDFPluginBase() = default;
    virtual void zoomIn() { }
    virtual void zoomOut() { }
    virtual void save(CompletionHandler<void(const String&, const URL&, std::span<const uint8_t>)>&& completionHandler) { completionHandler({ }, { }, { }); }
};

} // namespace WebKit

#endif // ENABLE(PDF_PLUGIN)
