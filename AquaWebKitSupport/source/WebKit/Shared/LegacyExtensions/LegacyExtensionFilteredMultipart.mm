#include "config.h"
#include "LegacyExtensionFilteredMultipart.h"

#include <Foundation/NSURLError.h>
#include <WebCore/CocoaCurlMultipartHandle.h>

namespace WebKit {

using namespace WebCore;

RefPtr<LegacyExtensionFilteredMultipart> LegacyExtensionFilteredMultipart::create(const ResourceResponse& response, PartResponse&& partResponse, PartData&& partData, End&& end)
{
    Ref multipart = adoptRef(*new LegacyExtensionFilteredMultipart(response, WTF::move(partResponse), WTF::move(partData), WTF::move(end)));
    multipart->m_parser = createCocoaCurlMultipartHandle(multipart.get(), response);
    if (!multipart->m_parser)
        return nullptr;
    return multipart;
}

LegacyExtensionFilteredMultipart::LegacyExtensionFilteredMultipart(const ResourceResponse& response, PartResponse&& partResponse, PartData&& partData, End&& end)
    : m_response(response)
    , m_partResponse(WTF::move(partResponse))
    , m_partData(WTF::move(partData))
    , m_end(WTF::move(end))
{
}

void LegacyExtensionFilteredMultipart::receive(const SharedBuffer& data)
{
    if (m_hasEnded)
        return;
    Ref protectedThis { *this };
    m_parser->didReceiveMessage(data.span());
    didParse();
}

void LegacyExtensionFilteredMultipart::finish()
{
    if (m_hasEnded)
        return;
    Ref protectedThis { *this };
    m_parser->didCompleteMessage();
    didParse();
}

void LegacyExtensionFilteredMultipart::didParse()
{
    if (m_hasEnded)
        return;
    if (m_parser->hasError())
        return end(ResourceError(NSURLErrorDomain, NSURLErrorCannotParseResponse, m_response.url(), "Invalid multipart response"_s));
    auto header = std::exchange(m_pendingHeader, std::nullopt);
    if (!header)
        return;
    m_partResponse(cocoaCurlMultipartPartResponse(m_response, *header), [protectedThis = Ref { *this }](bool proceed) {
        if (protectedThis->m_hasEnded)
            return;
        if (!proceed) {
            protectedThis->m_hasEnded = true;
            return;
        }
        protectedThis->m_parser->completeHeaderProcessing();
        protectedThis->didParse();
    });
}

void LegacyExtensionFilteredMultipart::end(const ResourceError& error)
{
    m_hasEnded = true;
    m_pendingHeader = std::nullopt;
    m_end(error);
}

void LegacyExtensionFilteredMultipart::didReceiveHeaderFromMultipart(Vector<String>&& header)
{
    m_pendingHeader = WTF::move(header);
}

void LegacyExtensionFilteredMultipart::didReceiveDataFromMultipart(std::span<const uint8_t> data)
{
    if (!m_hasEnded)
        m_partData(SharedBuffer::create(data));
}

void LegacyExtensionFilteredMultipart::didCompleteFromMultipart()
{
    if (!m_hasEnded)
        end({ });
}

} // namespace WebKit
