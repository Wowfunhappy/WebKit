// MAVERICKS_BACKPORT: WebTransport requires Network.framework features (nw_connection_group_t)
// from 10.14+. Provide minimal stubs so NetworkConnectionToWebProcess::initializeWebTransportSession
// links cleanly. WebTransport unsupported in this build — initialize calls back nullopt and create
// returns nullptr; NetworkConnectionToWebProcess handles those cases.
// MAVERICKS_BACKPORT: stub translation unit replaces the Network.framework implementation.

#include "config.h"
#include "NetworkTransportSession.h"

// MAVERICKS_BACKPORT: only the connection-info / completion-handler headers are needed for the stubs.
#include <WebCore/WebTransportConnectionInfo.h>
#include <wtf/CompletionHandler.h>

namespace WebKit {

// MAVERICKS_BACKPORT: WebTransport unsupported on 10.9; create returns nullptr.
RefPtr<NetworkTransportSession> NetworkTransportSession::create(NetworkConnectionToWebProcess&, WebTransportSessionIdentifier, URL&&, WebCore::WebTransportOptions&&, WebKit::WebPageProxyIdentifier&&, WebCore::ClientOrigin&&)
{
    return nullptr;
}

void NetworkTransportSession::initialize(CompletionHandler<void(std::optional<WebCore::WebTransportConnectionInfo>&&)>&& completionHandler)
{
// MAVERICKS_BACKPORT: WebTransport unsupported on 10.9; initialize calls back nullopt.
    completionHandler(std::nullopt);
}

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
void NetworkTransportSession::setupConnectionHandler()
{
    nw_connection_group_set_new_connection_handler(m_connectionGroup.get(), makeBlockPtr([weakThis = WeakPtr { *this }] (nw_connection_t inboundConnection) mutable {
        ASSERT(inboundConnection);
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis) {
            nw_connection_cancel(inboundConnection);
            return;
        }

        Ref stream = NetworkTransportStream::create(*protectedThis, inboundConnection);
        auto identifier = stream->identifier();
        ASSERT(!protectedThis->m_streams.contains(identifier));
        protectedThis->m_streams.set(identifier, stream.copyRef());
        stream->start([weakThis = WeakPtr { *protectedThis }, identifier] (std::optional<NetworkTransportStreamType> streamType) mutable {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis)
                return;
            if (!streamType) {
                protectedThis->destroyStream(identifier, std::nullopt);
                return;
            }
            if (*streamType == NetworkTransportStreamType::IncomingUnidirectional)
                protectedThis->receiveIncomingUnidirectionalStream(identifier);
            else
                protectedThis->receiveBidirectionalStream(identifier);
        });
    }).get());
}

void NetworkTransportSession::createStream(NetworkTransportStreamType streamType, CompletionHandler<void(std::optional<WebCore::WebTransportStreamIdentifier>)>&& completionHandler)
{
    if (!canLoad_Network_nw_webtransport_create_options())
        return completionHandler(std::nullopt);

    ASSERT(streamType != NetworkTransportStreamType::IncomingUnidirectional);
    RetainPtr webtransportOptions = adoptNS(softLink_Network_nw_webtransport_create_options());
    if (!webtransportOptions) {
        ASSERT_NOT_REACHED();
        return completionHandler(std::nullopt);
    }
    softLink_Network_nw_webtransport_options_set_is_unidirectional(webtransportOptions.get(), streamType != NetworkTransportStreamType::Bidirectional);
    softLink_Network_nw_webtransport_options_set_is_datagram(webtransportOptions.get(), false);
    if (canLoad_Network_nw_webtransport_options_set_allow_joining_before_ready())
        softLink_Network_nw_webtransport_options_set_allow_joining_before_ready(webtransportOptions.get(), true);
    RetainPtr connection = adoptNS(nw_connection_group_extract_connection(m_connectionGroup.get(), nil, webtransportOptions.get()));
    if (!connection) {
        ASSERT_NOT_REACHED();
        return completionHandler(std::nullopt);
    }

    Ref stream = NetworkTransportStream::create(*this, connection.get());
    auto identifier = stream->identifier();
    ASSERT(!m_streams.contains(identifier));
    m_streams.set(identifier, stream.copyRef());
    stream->start([weakThis = WeakPtr { *this }, identifier, completionHandler = WTF::move(completionHandler)] (std::optional<NetworkTransportStreamType> streamType) mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return completionHandler(std::nullopt);
        if (!streamType) {
            protectedThis->destroyStream(identifier, std::nullopt);
            return completionHandler(std::nullopt);
        }
        completionHandler(identifier);
    });
}

void NetworkTransportSession::receiveDatagramLoop()
{
    ASSERT(m_datagramConnection);
    nw_connection_receive(m_datagramConnection.get(), 1, std::numeric_limits<uint32_t>::max(), makeBlockPtr([weakThis = WeakPtr { *this }] (dispatch_data_t content, nw_content_context_t, bool withFin, nw_error_t error) {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        if (error) {
            if (nw_error_get_error_domain(error) != nw_error_domain_posix || nw_error_get_error_code(error) != ECANCELED)
                protectedThis->receiveDatagram({ }, false, WebCore::Exception(WebCore::ExceptionCode::NetworkError));
            return;
        }

        ASSERT(content || withFin);

        // FIXME: Not only is this an unnecessary string copy, but it's also something that should probably be in WTF or FragmentedSharedBuffer.
        auto vectorFromData = [](dispatch_data_t content) {
            Vector<uint8_t> request;
            if (content) {
                dispatch_data_apply_span(content, [&](std::span<const uint8_t> buffer) {
                    request.append(buffer);
                    return true;
                });
            }
            return request;
        };

        bool completed = !content && withFin;
        protectedThis->receiveDatagram(vectorFromData(content).span(), completed, std::nullopt);
        if (!completed)
            protectedThis->receiveDatagramLoop();
    }).get());
}

void NetworkTransportSession::terminate(WebCore::WebTransportSessionErrorCode code, CString&& message)
{
    if (m_sessionMetadata) {
        if (canLoad_Network_nw_webtransport_metadata_set_session_error_code())
            softLink_Network_nw_webtransport_metadata_set_session_error_code(m_sessionMetadata.get(), code);
        if (canLoad_Network_nw_webtransport_metadata_set_session_error_message())
            softLink_Network_nw_webtransport_metadata_set_session_error_message(m_sessionMetadata.get(), message.data());
    }

    if (m_datagramConnection)
        nw_connection_cancel(m_datagramConnection.get());

    auto streams = std::exchange(m_streams, { });
    for (auto& stream : streams.values())
        stream->cancel(code);

    nw_connection_group_cancel(m_connectionGroup.get());
}

bool NetworkTransportSession::isSessionClosed() const
{
    if (m_sessionMetadata && canLoad_Network_nw_webtransport_metadata_get_session_closed())
        return softLink_Network_nw_webtransport_metadata_get_session_closed(m_sessionMetadata.get());
    return false;
}
MAVERICKS_BACKPORT */
}
