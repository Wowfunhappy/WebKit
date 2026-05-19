#pragma once
// Minimal stub for macOS 10.9 backport

#if ENABLE(PDF_PLUGIN)

#include "PDFPluginIdentifier.h"
#include <WebCore/FrameIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/Identified.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/URL.h>
#include <wtf/WeakPtr.h>
#include <wtf/CheckedPtr.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

class PDFPluginBase : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<PDFPluginBase, WTF::DestructionThread::Main>, public CanMakeWeakPtr<PDFPluginBase>, public CanMakeThreadSafeCheckedPtr<PDFPluginBase>, public Identified<PDFPluginIdentifier> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(PDFPluginBase);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(PDFPluginBase);
public:
    virtual ~PDFPluginBase() = default;
    virtual void zoomIn() { }
    virtual void zoomOut() { }
    virtual void save(CompletionHandler<void(const String&, const URL&, std::span<const uint8_t>)>&& completionHandler) { completionHandler({ }, { }, { }); }
};

} // namespace WebKit

#endif // ENABLE(PDF_PLUGIN)
