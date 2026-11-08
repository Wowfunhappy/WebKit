// The body a multipart/x-mixed-replace response's StreamFilters write, split into the parts the page receives as
// the network splits an unfiltered response's body. The filters read the body as the network sends it, boundaries
// and part headers included, as Firefox's StreamFilters read a channel's body, so each part's response reaches the
// page after the filtered body before it.

#pragma once

#include <WebCore/CurlMultipartHandle.h>
#include <WebCore/CurlMultipartHandleClient.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/CheckedPtr.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

// How a filtered response's body reaches its filters: whole, when it is not a multipart response or nothing below
// splits it; whole, with the filters' output split into its parts; or already split by the network load, so that
// no filter reads it.
enum class LegacyExtensionMultipartSplit : uint8_t { None, SplitsFilterOutput, SplitByNetworkLoad };

class LegacyExtensionFilteredMultipart final : public RefCounted<LegacyExtensionFilteredMultipart>, public WebCore::CurlMultipartHandleClient, public CanMakeCheckedPtr<LegacyExtensionFilteredMultipart> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(LegacyExtensionFilteredMultipart);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(LegacyExtensionFilteredMultipart);
public:
    // A part's response; the parts after it wait until the handler is called, with true to go on.
    using PartResponse = Function<void(WebCore::ResourceResponse&&, CompletionHandler<void(bool)>&&)>;
    using PartData = Function<void(Ref<WebCore::SharedBuffer>&&)>;
    // The end of the parts: a null error, or the error of a body that is not a multipart body.
    using End = Function<void(const WebCore::ResourceError&)>;

    // Null when the response is not a multipart/x-mixed-replace response.
    static RefPtr<LegacyExtensionFilteredMultipart> create(const WebCore::ResourceResponse&, PartResponse&&, PartData&&, End&&);

    void receive(const WebCore::SharedBuffer&);
    void finish();

private:
    LegacyExtensionFilteredMultipart(const WebCore::ResourceResponse&, PartResponse&&, PartData&&, End&&);

    uint32_t checkedPtrCount() const final { return CanMakeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    void incrementCheckedPtrCount() const final { CanMakeCheckedPtr::incrementCheckedPtrCount(); }
    void decrementCheckedPtrCount() const final { CanMakeCheckedPtr::decrementCheckedPtrCount(); }
    void setDidBeginCheckedPtrDeletion() final { CanMakeCheckedPtr::setDidBeginCheckedPtrDeletion(); }

    void didReceiveHeaderFromMultipart(Vector<String>&&) final;
    void didReceiveDataFromMultipart(std::span<const uint8_t>) final;
    void didCompleteFromMultipart() final;

    // A part's header the parser read is answered once the parser has returned, which it requires before
    // completeHeaderProcessing.
    void didParse();
    void end(const WebCore::ResourceError&);

    WebCore::ResourceResponse m_response;
    std::unique_ptr<WebCore::CurlMultipartHandle> m_parser;
    PartResponse m_partResponse;
    PartData m_partData;
    End m_end;
    std::optional<Vector<String>> m_pendingHeader;
    bool m_hasEnded { false };
};

} // namespace WebKit
