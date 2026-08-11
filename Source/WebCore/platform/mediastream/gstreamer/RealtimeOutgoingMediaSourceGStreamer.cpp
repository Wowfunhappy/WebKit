/*
 *  Copyright (C) 2017-2022 Igalia S.L. All rights reserved.
 *  Copyright (C) 2022 Metrological Group B.V.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "config.h"
#include "RealtimeOutgoingMediaSourceGStreamer.h"

#if USE(GSTREAMER_WEBRTC)

#include "GStreamerCommon.h"
#include "GStreamerMediaStreamSource.h"
#include "MediaStreamTrack.h"

#define GST_USE_UNSTABLE_API
#include <gst/webrtc/webrtc.h>
#undef GST_USE_UNSTABLE_API

// MAVERICKS_BACKPORT: <limits> for std::numeric_limits used by the stable send-SSRC normalization in initialize().
#include <limits>
#include <wtf/UUID.h>
#include <wtf/glib/GMallocString.h>
#include <wtf/glib/WTFGType.h>
#include <wtf/text/StringToIntegerConversion.h>

GST_DEBUG_CATEGORY(webkit_webrtc_outgoing_media_debug);
#define GST_CAT_DEFAULT webkit_webrtc_outgoing_media_debug

namespace WebCore {

RealtimeOutgoingMediaSourceGStreamer::RealtimeOutgoingMediaSourceGStreamer(Type type, const RefPtr<UniqueSSRCGenerator>& ssrcGenerator, const String& mediaStreamId, MediaStreamTrack& track)
    : m_type(type)
    , m_mediaStreamId(mediaStreamId)
    , m_trackId(track.id())
    , m_ssrcGenerator(ssrcGenerator)
{
    initialize();

    m_track = track.privateTrack();
    m_outgoingSource = webkitMediaStreamSrcNew();
    GST_DEBUG_OBJECT(m_bin.get(), "Created outgoing source %" GST_PTR_FORMAT, m_outgoingSource.get());
    gst_bin_add(GST_BIN_CAST(m_bin.get()), m_outgoingSource.get());
    webkitMediaStreamSrcAddTrack(WEBKIT_MEDIA_STREAM_SRC(m_outgoingSource.get()), m_track.get());
}

RealtimeOutgoingMediaSourceGStreamer::RealtimeOutgoingMediaSourceGStreamer(Type type, const RefPtr<UniqueSSRCGenerator>& ssrcGenerator)
    : m_type(type)
    , m_mediaStreamId(createVersion4UUIDString())
    , m_trackId(emptyString())
    , m_ssrcGenerator(ssrcGenerator)
{
    initialize();
}

RealtimeOutgoingMediaSourceGStreamer::~RealtimeOutgoingMediaSourceGStreamer()
{
    stopUpdatingStats();
    if (m_transceiver)
        g_signal_handlers_disconnect_by_data(m_transceiver.get(), this);

    if (m_track)
        m_track->removeObserver(*this);
}

void RealtimeOutgoingMediaSourceGStreamer::initialize()
{
    static std::once_flag debugRegisteredFlag;
    std::call_once(debugRegisteredFlag, [] {
        GST_DEBUG_CATEGORY_INIT(webkit_webrtc_outgoing_media_debug, "webkitwebrtcoutgoingmedia", 0, "WebKit WebRTC outgoing media");
    });

    // MAVERICKS_BACKPORT: allocate the stable send SSRC up front (see the header). Used both by
    // the RTP packetizer and, via codec-preferences, by webrtcbin's offer so advertised == sent.
    // generateSSRC() returns UINT32_MAX when it can't find a free value; normalize that to 0 so
    // the guards below fall back to letting each packetizer/webrtcbin pick its own SSRC.
    m_ssrc = m_ssrcGenerator->generateSSRC();
    if (m_ssrc == std::numeric_limits<uint32_t>::max())
        m_ssrc = 0;

    m_bin = gst_bin_new(nullptr);
    m_inputSelector = gst_element_factory_make("input-selector", nullptr);
    g_object_set(m_inputSelector.get(), "sync-streams", FALSE, nullptr);
    m_tee = gst_element_factory_make("tee", nullptr);

    m_rtpFunnel = gst_element_factory_make("rtpfunnel", nullptr);
    if (gstObjectHasProperty(m_rtpFunnel.get(), "forward-unknown-ssrc"_s))
        g_object_set(m_rtpFunnel.get(), "forward-unknown-ssrc", TRUE, nullptr);

    m_rtpCapsfilter = gst_element_factory_make("capsfilter", nullptr);
    gst_bin_add_many(GST_BIN_CAST(m_bin.get()), m_inputSelector.get(), m_tee.get(), m_rtpFunnel.get(), m_rtpCapsfilter.get(), nullptr);
    gst_element_link(m_rtpFunnel.get(), m_rtpCapsfilter.get());

    auto srcPad = adoptGRef(gst_element_get_static_pad(m_rtpCapsfilter.get(), "src"));
    gst_element_add_pad(m_bin.get(), gst_ghost_pad_new("src", srcPad.get()));
}

const GRefPtr<GstCaps>& RealtimeOutgoingMediaSourceGStreamer::allowedCaps() const
{
    if (m_allowedCaps)
        return m_allowedCaps;

    auto sdpMsIdLine = makeString(m_mediaStreamId, ' ', m_trackId);
    m_allowedCaps = capsFromRtpCapabilities(m_rtpHeaderExtensionMapping, rtpCapabilities(), [&sdpMsIdLine](GstStructure* structure) {
        gst_structure_set(structure, "a-msid", G_TYPE_STRING, sdpMsIdLine.utf8().data(), nullptr);
    });

    GST_DEBUG_OBJECT(m_bin.get(), "Allowed caps: %" GST_PTR_FORMAT, m_allowedCaps.get());
    return m_allowedCaps;
}

GRefPtr<GstCaps> RealtimeOutgoingMediaSourceGStreamer::rtpCaps() const
{
    GRefPtr<GstCaps> caps;
    g_object_get(m_rtpCapsfilter.get(), "caps", &caps.outPtr(), nullptr);
    return caps;
}

void RealtimeOutgoingMediaSourceGStreamer::start()
{
    if (!m_isStopped) {
        GST_DEBUG_OBJECT(m_bin.get(), "Source already started");
        return;
    }

    GST_DEBUG_OBJECT(m_bin.get(), "Starting outgoing source");
    if (m_track)
        m_track->addObserver(*this);
    m_isStopped = false;

    if (m_transceiver) {
        auto pad = outgoingSourcePad();
        if (!gst_pad_is_linked(pad.get())) {
            GST_DEBUG_OBJECT(m_bin.get(), "Codec preferences haven't changed before startup, ensuring source is linked");
            codecPreferencesChanged();
        }
    }

    gst_element_sync_state_with_parent(m_bin.get());

    startUpdatingStats();
}

void RealtimeOutgoingMediaSourceGStreamer::stop(StoppedCallback&& callback)
{
    if (m_isStopped) {
        callback();
        return;
    }

    GST_DEBUG_OBJECT(m_bin.get(), "Stopping outgoing source");
    m_isStopped = true;
    stopOutgoingSource(WTF::move(callback));
}

struct ProbeData {
    ThreadSafeWeakPtr<RealtimeOutgoingMediaSourceGStreamer> source;
    RealtimeOutgoingMediaSourceGStreamer::StoppedCallback callback;
};
WEBKIT_DEFINE_ASYNC_DATA_STRUCT(ProbeData);

void RealtimeOutgoingMediaSourceGStreamer::stopOutgoingSource(StoppedCallback&& callback)
{
    GST_DEBUG_OBJECT(m_bin.get(), "Stopping outgoing source %" GST_PTR_FORMAT, m_outgoingSource.get());

    if (!m_outgoingSource && !m_fallbackSource) {
        callback();
        return;
    }

    auto data = createProbeData();
    data->source = this;
    data->callback = WTF::move(callback);

    auto pad = adoptGRef(gst_element_get_static_pad(m_inputSelector.get(), "src"));
    gst_pad_add_probe(pad.get(), GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, reinterpret_cast<GstPadProbeCallback>(+[](GstPad*, GstPadProbeInfo* info, gpointer userData) -> GstPadProbeReturn {
        auto event = GST_PAD_PROBE_INFO_EVENT(info);
        if (GST_EVENT_TYPE(event) != GST_EVENT_EOS)
            return GST_PAD_PROBE_OK;

        auto data = reinterpret_cast<ProbeData*>(userData);
        auto self = data->source.get();
        if (!self) {
            data->callback();
            return GST_PAD_PROBE_REMOVE;
        }

        callOnMainThread([weakSelf = WTF::move(self), callback = WTF::move(data->callback)] {
            auto self = weakSelf.get();
            if (!self) {
                callback();
                return;
            }
            self->removeOutgoingSource();
            callback();
        });
        return GST_PAD_PROBE_REMOVE;
    }), data, reinterpret_cast<GDestroyNotify>(destroyProbeData));

    if (WEBKIT_IS_MEDIA_STREAM_SRC(m_outgoingSource.get()))
        webkitMediaStreamSrcSignalEndOfStream(WEBKIT_MEDIA_STREAM_SRC_CAST(m_outgoingSource.get()));

    if (m_fallbackSource)
        gst_element_send_event(m_fallbackSource.get(), gst_event_new_eos());
}

void RealtimeOutgoingMediaSourceGStreamer::removeOutgoingSource()
{
    if (m_track)
        m_track->removeObserver(*this);

    if (!m_outgoingSource)
        return;

    gstElementLockAndSetState(m_outgoingSource.get(), GST_STATE_NULL);
    gst_element_unlink(m_outgoingSource.get(), m_inputSelector.get());
    gst_bin_remove(GST_BIN_CAST(m_bin.get()), m_outgoingSource.get());
    m_outgoingSource.clear();

    // MAVERICKS_BACKPORT: the fallback becomes the active branch again, so release it if a codec
    // re-negotiation parked it (see reconfigureForNegotiatedCaps).
    if (m_fallbackSource && gst_element_is_locked_state(m_fallbackSource.get())) {
        gst_element_set_locked_state(m_fallbackSource.get(), FALSE);
        gst_element_sync_state_with_parent(m_fallbackSource.get());
    }
}

void RealtimeOutgoingMediaSourceGStreamer::sourceMutedChanged()
{
    if (!m_track)
        return;
    ASSERT(m_muted != m_track->muted());
    m_muted = m_track->muted();
    GST_DEBUG_OBJECT(m_bin.get(), "Mute state changed to %s", boolForPrinting(m_muted));
}

void RealtimeOutgoingMediaSourceGStreamer::sourceEnabledChanged()
{
    if (!m_track)
        return;

    m_enabled = m_track->enabled();
    GST_DEBUG_OBJECT(m_bin.get(), "Enabled state changed to %s", boolForPrinting(m_enabled));
    if (m_enabled)
        startUpdatingStats();
    else
        stopUpdatingStats();
}

void RealtimeOutgoingMediaSourceGStreamer::initializeSourceFromTrackPrivate()
{
    if (!m_track)
        return;
    m_muted = m_track->muted();
    m_enabled = m_track->enabled();
    GST_DEBUG_OBJECT(m_bin.get(), "Initializing from track, muted: %s, enabled: %s", boolForPrinting(m_muted), boolForPrinting(m_enabled));
}

void RealtimeOutgoingMediaSourceGStreamer::link()
{
    GST_DEBUG_OBJECT(m_bin.get(), "Linking webrtcbin pad %" GST_PTR_FORMAT, m_webrtcSinkPad.get());

    auto srcPad = adoptGRef(gst_element_get_static_pad(m_bin.get(), "src"));
    gst_pad_link(srcPad.get(), m_webrtcSinkPad.get());
}

void RealtimeOutgoingMediaSourceGStreamer::setSinkPad(GRefPtr<GstPad>&& pad)
{
    GST_DEBUG_OBJECT(m_bin.get(), "Associating with webrtcbin pad %" GST_PTR_FORMAT, pad.get());
    m_webrtcSinkPad = WTF::move(pad);

    if (m_transceiver)
        g_signal_handlers_disconnect_by_data(m_transceiver.get(), this);

    g_object_get(m_webrtcSinkPad.get(), "transceiver", &m_transceiver.outPtr(), nullptr);

    g_signal_connect_swapped(m_transceiver.get(), "notify::codec-preferences", G_CALLBACK(+[](RealtimeOutgoingMediaSourceGStreamer* source) {
        source->codecPreferencesChanged();
    }), this);
    g_object_get(m_transceiver.get(), "sender", &m_sender.outPtr(), nullptr);

    checkMid();
    g_signal_connect_swapped(m_transceiver.get(), "notify::mid", G_CALLBACK(+[](RealtimeOutgoingMediaSourceGStreamer* source) {
        source->checkMid();
    }), this);
}

void RealtimeOutgoingMediaSourceGStreamer::checkMid()
{
    GUniqueOutPtr<char> midChars;
    g_object_get(m_transceiver.get(), "mid", &midChars.outPtr(), nullptr);
    auto mid = GMallocString::unsafeAdoptFromUTF8(WTF::move(midChars));
    if (!mid)
        return;

    if (equal(m_mid, mid.span()))
        return;

    m_mid = mid.span();
    for (auto& packetizer : m_packetizers)
        packetizer->ensureMidExtension(m_mid);

    GRefPtr<GstCaps> rtpCaps;
    g_object_get(m_rtpCapsfilter.get(), "caps", &rtpCaps.outPtr(), nullptr);
    if (gst_caps_is_any(rtpCaps.get()) || !gst_caps_get_size(rtpCaps.get()))
        return;

    GUniquePtr<GstStructure> structure(gst_structure_copy(gst_caps_get_structure(rtpCaps.get(), 0)));
    auto lookupResults = lookupRtpExtensions(structure.get());
    if (lookupResults.hasMidExtension)
        return;

    lookupResults.lastIdentifier++;
    auto extensionIdentifier = makeString("extmap-"_s, lookupResults.lastIdentifier);
    gst_structure_set(structure.get(), extensionIdentifier.ascii().data(), G_TYPE_STRING, GST_RTP_HDREXT_BASE "sdes:mid", nullptr);

    auto newCaps = adoptGRef(gst_caps_new_full(structure.release(), nullptr));
    GST_DEBUG_OBJECT(m_bin.get(), "Setting RTP funnel caps to %" GST_PTR_FORMAT, newCaps.get());
    g_object_set(m_rtpCapsfilter.get(), "caps", newCaps.get(), nullptr);
}

GUniquePtr<GstStructure> RealtimeOutgoingMediaSourceGStreamer::parameters()
{
    if (!m_parameters)
        return nullptr;
    return GUniquePtr<GstStructure>(gst_structure_copy(m_parameters.get()));
}

void RealtimeOutgoingMediaSourceGStreamer::codecPreferencesChanged()
{
    if (GST_STATE(m_bin.get()) > GST_STATE_READY) {
        GST_WARNING_OBJECT(m_bin.get(), "Changing codec preferences on an ongoing connection is not supported");
        return;
    }

    GRefPtr<GstCaps> codecPreferences;
    g_object_get(m_transceiver.get(), "codec-preferences", &codecPreferences.outPtr(), nullptr);
    GST_DEBUG_OBJECT(m_bin.get(), "Codec preferences changed on transceiver %" GST_PTR_FORMAT " to: %" GST_PTR_FORMAT, m_transceiver.get(), codecPreferences.get());

    HashMap<int, unsigned> payloaderStates;
    while (!m_packetizers.isEmpty()) {
        RefPtr packetizer = m_packetizers.takeLast();

        auto payloadType = packetizer->payloadType();
        if (!payloadType)
            continue;

        unsigned sequenceNumber = packetizer->currentSequenceNumberOffset();
        payloaderStates.add(*payloadType, sequenceNumber);

        auto bin = packetizer->bin();
        auto binSinkPad = adoptGRef(gst_element_get_static_pad(bin, "sink"));
        auto teeSrcPad = adoptGRef(gst_pad_get_peer(binSinkPad.get()));
        auto binSrcPad = adoptGRef(gst_element_get_static_pad(bin, "src"));
        auto funnelSinkPad = adoptGRef(gst_pad_get_peer(binSrcPad.get()));
        gst_element_set_state(bin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN_CAST(m_bin.get()), bin);
        gst_element_release_request_pad(m_tee.get(), teeSrcPad.get());
        gst_element_release_request_pad(m_rtpFunnel.get(), funnelSinkPad.get());
    }

    if (!configurePacketizers(WTF::move(codecPreferences))) {
        GST_ERROR_OBJECT(m_bin.get(), "Unable to link encoder to webrtcbin");
        return;
    }

    for (auto& packetizer : m_packetizers) {
        auto payloadType = packetizer->payloadType();
        if (!payloadType)
            continue;
        if (!payloaderStates.contains(*payloadType))
            continue;
        packetizer->setSequenceNumberOffset(payloaderStates.get(*payloadType));
    }

    gst_bin_sync_children_states(GST_BIN_CAST(m_bin.get()));
    gst_element_sync_state_with_parent(m_bin.get());
    dumpBinToDotFile(m_bin, "outgoing-media-new-codec-prefs"_s);
    m_isStopped = false;
}

// MAVERICKS_BACKPORT: rebuild the packetizers when the description being set no longer allows the
// codec they were built for. Google Meet answers our H264-first offer with a VP8/VP9-only video
// section; without this the sender keeps emitting the offer's codec on a payload type the remote
// never accepted, the SFU discards every packet, and the other party never sees our video.
//
// This is codecPreferencesChanged()'s rebuild, driven by the negotiated m-section instead of the
// transceiver's static preferences. It reuses that function's precondition rather than working
// around it: the packetizer chain carries the video encoder, and re-plugging it while the bin is
// PLAYING leaves the raw side unable to renegotiate (observed as not-negotiated on the capture
// appsrc, which kills capture and makes Meet report a blocked camera). So the bin is brought down to
// READY for the swap and synced back up afterwards.
void RealtimeOutgoingMediaSourceGStreamer::reconfigureForNegotiatedCaps(GRefPtr<GstCaps>&& negotiatedCaps)
{
    if (m_isStopped || m_packetizers.isEmpty())
        return;
    if (!negotiatedCaps || gst_caps_is_empty(negotiatedCaps.get()) || gst_caps_is_any(negotiatedCaps.get())) [[unlikely]]
        return;

    // The active codec is identified by encoding-name + payload of the current RTP caps.
    auto currentCaps = rtpCaps();
    if (!currentCaps || !gst_caps_get_size(currentCaps.get()))
        return;
    const auto currentStructure = gst_caps_get_structure(currentCaps.get(), 0);
    auto currentEncoding = gstStructureGetString(currentStructure, "encoding-name"_s);
    auto currentPayload = gstStructureGet<int>(currentStructure, "payload"_s);
    if (!currentEncoding || !currentPayload)
        return;

    unsigned totalNegotiated = gst_caps_get_size(negotiatedCaps.get());
    for (unsigned i = 0; i < totalNegotiated; i++) {
        const auto structure = gst_caps_get_structure(negotiatedCaps.get(), i);
        if (gstStructureGetString(structure, "encoding-name"_s) == currentEncoding
            && gstStructureGet<int>(structure, "payload"_s) == currentPayload)
            return; // The active codec is still negotiated, nothing to do.
    }

    GST_INFO_OBJECT(m_bin.get(), "Negotiated caps %" GST_PTR_FORMAT " exclude the active codec %s/%d, rebuilding packetizers", negotiatedCaps.get(), currentEncoding.utf8(), *currentPayload);

    // The fallback black-frame source feeds the input-selector's INACTIVE pad while a real track is
    // attached, so nothing downstream consumes it — but it is a live source with its own streaming
    // task, so it would renegotiate against the new codec's raw format as the packetizers are
    // re-plugged and fail (not-negotiated posted on the pipeline bus). Park it BEFORE the swap, with
    // its state kept locked so neither the state change below nor the later sync-children pass can
    // restart it; removeOutgoingSource() releases it when the fallback becomes the active branch.
    if (m_outgoingSource && m_fallbackSource) {
        gst_element_set_locked_state(m_fallbackSource.get(), TRUE);
        gst_element_set_state(m_fallbackSource.get(), GST_STATE_NULL);
        // Wait it out: the state change is asynchronous and this is a live source, so its streaming
        // task can otherwise still be inside a buffer push while the packetizers are re-plugged.
        gst_element_get_state(m_fallbackSource.get(), nullptr, nullptr, GST_CLOCK_TIME_NONE);
    }

    auto previousState = GST_STATE(m_bin.get());
    if (previousState > GST_STATE_READY) {
        gst_element_set_state(m_bin.get(), GST_STATE_READY);
        // set_state is asynchronous for a bin; the packetizer swap below re-plugs the encoder, so
        // the transition has to have completed before it runs.
        gst_element_get_state(m_bin.get(), nullptr, nullptr, GST_CLOCK_TIME_NONE);
    }

    // Payload type keyed in a Vector: 0 is a valid payload type (PCMU), which an integer-keyed
    // HashMap reserves as its empty sentinel.
    Vector<std::pair<int, unsigned>> payloaderStates;
    while (!m_packetizers.isEmpty()) {
        RefPtr packetizer = m_packetizers.takeLast();

        // The live sequence number, not the configured offset: the default offset is -1 (pick a
        // random base), so carrying it would restart the stream at an unrelated sequence.
        auto payloadType = packetizer->payloadType();
        if (payloadType)
            payloaderStates.append({ *payloadType, (packetizer->currentSequenceNumber() + 1) & 0xFFFF });

        auto bin = packetizer->bin();
        auto binSinkPad = adoptGRef(gst_element_get_static_pad(bin, "sink"));
        auto teeSrcPad = adoptGRef(gst_pad_get_peer(binSinkPad.get()));
        auto binSrcPad = adoptGRef(gst_element_get_static_pad(bin, "src"));
        auto funnelSinkPad = adoptGRef(gst_pad_get_peer(binSrcPad.get()));
        gst_element_set_state(bin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN_CAST(m_bin.get()), bin);
        gst_element_release_request_pad(m_tee.get(), teeSrcPad.get());
        gst_element_release_request_pad(m_rtpFunnel.get(), funnelSinkPad.get());
    }

    // configurePacketizers() expects codec-preferences-shaped caps, which is what upstream's
    // codecPreferencesChanged() feeds it. An SDP m-section additionally carries attribute fields
    // (a-*, extmap-*, rtcp-fb-*, ssrc-*) describing the remote side; built into the packetizer
    // capsfilter they can never match what our payloader produces — the remote's extension
    // identifiers differ from the ones configureExtensions() assigns — so every buffer would fail
    // caps negotiation. Keep only the codec identity and its format parameters, and carry the
    // extmap-* fields over from the caps the packetizer produced so far: RTP header-extension
    // identifiers are session-wide (BUNDLE funnels every m-line into one RTP session), and
    // webrtcbin's send funnel rejects caps whose identifiers contradict its other pads.
    auto sanitizedCaps = adoptGRef(gst_caps_new_empty());
    unsigned totalStructures = gst_caps_get_size(negotiatedCaps.get());
    for (unsigned i = 0; i < totalStructures; i++) {
        GUniquePtr<GstStructure> copy(gst_structure_copy(gst_caps_get_structure(negotiatedCaps.get(), i)));
        Vector<CString> fieldsToRemove;
        gstStructureForeach(copy.get(), [&](auto id, const GValue*) -> bool {
            auto name = gstIdToString(id);
            if (name.startsWith("a-"_s) || name.startsWith("extmap-"_s) || name.startsWith("rtcp-fb-"_s) || name.startsWith("ssrc-"_s))
                fieldsToRemove.append(name.utf8());
            return true;
        });
        for (auto& field : fieldsToRemove)
            gst_structure_remove_field(copy.get(), field.data());
        gstStructureForeach(currentStructure, [&](auto id, const GValue* value) -> bool {
            auto name = gstIdToString(id);
            if (name.startsWith("extmap-"_s))
                gstStructureIdSetValue(copy.get(), id, value);
            return true;
        });
        gst_caps_append_structure(sanitizedCaps.get(), copy.release());
    }

    if (!configurePacketizers(WTF::move(sanitizedCaps))) {
        // Do not fall back to the old packetizers: they emit a payload type the remote discards.
        // Stop the source so the failure is local, instead of leaving a live tee with no src pads,
        // which would return GST_FLOW_NOT_LINKED and error the whole pipeline.
        GST_ERROR_OBJECT(m_bin.get(), "Unable to build a packetizer for the negotiated caps, stopping this source");
        stopOutgoingSource([] { });
        m_isStopped = true;
        return;
    }

    for (auto& packetizer : m_packetizers) {
        // checkMid() already ran for this mid and early-returns when it is unchanged, so it will not
        // re-apply the extension to a packetizer built afterwards. Meet's SFU demultiplexes on the
        // MID header extension and discards RTP without it.
        if (!m_mid.isEmpty())
            packetizer->ensureMidExtension(m_mid);
        // The rebuilt packetizer keeps sending on the same SSRC (configurePacketizers stamps
        // m_ssrc), so the RTP sequence numbering must continue where the old packetizer left off:
        // the receiver's SRTP replay protection is keyed by SSRC and silently discards packets that
        // jump to an unrelated sequence range. A codec change also changes the payload type, so a
        // single stream carries its one offset over directly; only a multi-stream (simulcast)
        // rebuild, which keeps its payload types, can and does match by payload type.
        auto payloadType = packetizer->payloadType();
        if (payloaderStates.size() == 1 && m_packetizers.size() == 1)
            packetizer->setSequenceNumberOffset(payloaderStates[0].second);
        else if (payloadType) {
            for (auto& [previousPayloadType, sequenceNumber] : payloaderStates) {
                if (previousPayloadType == *payloadType) {
                    packetizer->setSequenceNumberOffset(sequenceNumber);
                    break;
                }
            }
        }
    }

    // Refresh the transceiver's codec-preferences BEFORE restarting the bin: webrtcbin answers its
    // sink pad's caps queries from them, so the rebuilt packetizer's caps event — which flows the
    // moment the bin comes back up — is rejected as long as they still describe the previous codec
    // (the not-negotiated latches in the packetizer queue and errors the whole source). requestPad()
    // stamped them from the pre-rebuild rtpCaps(); webrtcbin's _create_sdp_task also intersects the
    // sink pad caps against them on every later offer. The notify handler is blocked because it
    // would run codecPreferencesChanged(), rebuilding once more from the same caps.
    if (m_transceiver) {
        auto newRtpCaps = rtpCaps();
        g_signal_handlers_block_matched(m_transceiver.get(), G_SIGNAL_MATCH_DATA, 0, 0, nullptr, nullptr, this);
        g_object_set(m_transceiver.get(), "codec-preferences", newRtpCaps.get(), nullptr);
        g_signal_handlers_unblock_matched(m_transceiver.get(), G_SIGNAL_MATCH_DATA, 0, 0, nullptr, nullptr, this);
    }

    gst_bin_sync_children_states(GST_BIN_CAST(m_bin.get()));
    if (previousState > GST_STATE_READY)
        gst_element_sync_state_with_parent(m_bin.get());

    // The swapped-out packetizers carried the stats pad probes; give the new ones theirs, so
    // outbound-rtp stats keep reporting (Meet's bandwidth adaptation reads them).
    startUpdatingStats();

    dumpBinToDotFile(m_bin, "outgoing-media-negotiated-codec"_s);
}

void RealtimeOutgoingMediaSourceGStreamer::replaceTrack(const RefPtr<MediaStreamTrack>& newTrack)
{
    if (m_track)
        m_track->removeObserver(*this);

    RefPtr<MediaStreamTrackPrivate> trackPrivate;
    if (newTrack)
        trackPrivate = newTrack->privateTrack();

    if (m_outgoingSource)
        webkitMediaStreamSrcReplaceTrack(WEBKIT_MEDIA_STREAM_SRC_CAST(m_outgoingSource.get()), RefPtr(trackPrivate));
    else {
        if (trackPrivate) {
            m_outgoingSource = webkitMediaStreamSrcNew();
            gst_bin_add(GST_BIN_CAST(m_bin.get()), m_outgoingSource.get());
            webkitMediaStreamSrcAddTrack(WEBKIT_MEDIA_STREAM_SRC_CAST(m_outgoingSource.get()), trackPrivate.get());
            gst_element_link(m_outgoingSource.get(), m_inputSelector.get());
            gst_element_sync_state_with_parent(m_outgoingSource.get());
        }
        auto srcPad = outgoingSourcePad();
        auto activePad = adoptGRef(gst_pad_get_peer(srcPad.get()));
        g_object_set(m_inputSelector.get(), "active-pad", activePad.get(), nullptr);
    }
    if (!newTrack) {
        m_isStopped = true;
        m_track = nullptr;
        return;
    }

    m_track = WTF::move(trackPrivate);
    start();
}

void RealtimeOutgoingMediaSourceGStreamer::setInitialParameters(GUniquePtr<GstStructure>&& parameters)
{
    m_parameters = WTF::move(parameters);
    GST_DEBUG_OBJECT(m_bin.get(), "Initial encoding parameters: %" GST_PTR_FORMAT, m_parameters.get());
}

void RealtimeOutgoingMediaSourceGStreamer::configure(GRefPtr<GstCaps>&& allowedCaps)
{
    if (m_parameters) {
        auto encodings = gstStructureGetList<const GstStructure*>(m_parameters.get(), "encodings"_s);
        if (encodings.isEmpty()) [[unlikely]] {
            GST_WARNING_OBJECT(m_bin.get(), "Encodings list is empty, cancelling configuration");
            return;
        }
    }

    configurePacketizers(WTF::move(allowedCaps));
}

void RealtimeOutgoingMediaSourceGStreamer::setParameters(GUniquePtr<GstStructure>&& parameters)
{
    GST_DEBUG_OBJECT(m_bin.get(), "New encoding parameters: %" GST_PTR_FORMAT, parameters.get());
    auto encodings = gstStructureGetList<const GstStructure*>(parameters.get(), "encodings"_s);
    if (encodings.isEmpty()) [[unlikely]] {
        GST_WARNING_OBJECT(m_bin.get(), "Encodings list is empty, cancelling re-configuration");
        return;
    }

    for (const auto& encoding : encodings) {
        GUniquePtr<GstStructure> encodingParameters(gst_structure_copy(encoding));
        auto rid = gstStructureGetString(encodingParameters.get(), "rid"_s);
        if (!rid)
            continue;

        auto packetizer = getPacketizerForRid(rid.span());
        if (!packetizer)
            continue;

        packetizer->reconfigure(WTF::move(encodingParameters));
    }
    m_parameters = WTF::move(parameters);
}

RefPtr<GStreamerRTPPacketizer> RealtimeOutgoingMediaSourceGStreamer::getPacketizerForRid(const String& rid)
{
    for (auto& packetizer : m_packetizers) {
        if (packetizer->rtpStreamId() == rid)
            return packetizer;
    }
    return nullptr;
}

bool RealtimeOutgoingMediaSourceGStreamer::linkPacketizer(RefPtr<GStreamerRTPPacketizer>&& packetizer)
{
    auto packetizerBin = packetizer->bin();
    gst_bin_add(GST_BIN_CAST(m_bin.get()), packetizerBin);

    GST_DEBUG_OBJECT(m_bin.get(), "Linking packetizer %" GST_PTR_FORMAT " to RTP funnel", packetizerBin);
    if (!gst_element_link_many(m_tee.get(), packetizerBin, m_rtpFunnel.get(), nullptr)) {
        GST_ERROR_OBJECT(m_bin.get(), "Unable to link packetizer to RTP funnel");
        gst_bin_remove(GST_BIN_CAST(m_bin.get()), packetizerBin);
        return false;
    }
    m_packetizers.append(WTF::move(packetizer));
    return true;
}

bool RealtimeOutgoingMediaSourceGStreamer::configurePacketizers(GRefPtr<GstCaps>&& codecPreferences)
{
    GST_DEBUG_OBJECT(m_bin.get(), "Configuring packetizers for caps %" GST_PTR_FORMAT, codecPreferences.get());
    if (gst_caps_is_empty(codecPreferences.get()) || gst_caps_is_any(codecPreferences.get())) [[unlikely]]
        return false;

    // MAVERICKS_BACKPORT: stamp our stable send SSRC onto every codec structure so each RTP
    // packetizer built below sends with it (the packetizers keep a pre-set "ssrc" instead of
    // generating their own). GStreamerMediaEndpoint stamps the SAME value onto the transceiver's
    // codec-preferences at add-transceiver time, so webrtcbin advertises a=ssrc/a=ssrc-group:FID for
    // exactly this SSRC — which Google Meet's Safari path requires. Simulcast (multiple encodings,
    // one packetizer per layer) needs a distinct SSRC per layer, so it is left to webrtcbin.
    bool hasMultipleEncodings = false;
    if (m_parameters) {
        auto encodings = gstStructureGetList<const GstStructure*>(m_parameters.get(), "encodings"_s);
        hasMultipleEncodings = encodings.size() > 1;
    }
    if (m_ssrc && !hasMultipleEncodings) {
        codecPreferences = adoptGRef(gst_caps_make_writable(codecPreferences.leakRef()));
        unsigned totalStructures = gst_caps_get_size(codecPreferences.get());
        for (unsigned i = 0; i < totalStructures; i++)
            gst_structure_set(gst_caps_get_structure(codecPreferences.get(), i), "ssrc", G_TYPE_UINT, m_ssrc, nullptr);
        GST_DEBUG_OBJECT(m_bin.get(), "Stamped send SSRC %u onto packetizer caps", m_ssrc);
    }

    auto inputSelectorSrcPad = adoptGRef(gst_element_get_static_pad(m_inputSelector.get(), "src"));
    if (!gst_pad_is_linked(inputSelectorSrcPad.get()) && !gst_element_link(m_inputSelector.get(), m_tee.get()))
        return false;

    auto srcPad = outgoingSourcePad();
    if (m_outgoingSource) {
        if (!gst_pad_is_linked(srcPad.get()) && !gst_element_link(m_outgoingSource.get(), m_inputSelector.get()))
            return false;

    }
    auto activePad = adoptGRef(gst_pad_get_peer(srcPad.get()));
    g_object_set(m_inputSelector.get(), "active-pad", activePad.get(), nullptr);

    auto rtpCaps = adoptGRef(gst_caps_new_empty());
    unsigned totalCodecs = gst_caps_get_size(codecPreferences.get());
    for (unsigned i = 0; i < totalCodecs; i++) {
        const auto codecParameters = gst_caps_get_structure(codecPreferences.get(), i);

        if (m_parameters) {
            auto encodings = gstStructureGetList<const GstStructure*>(m_parameters.get(), "encodings"_s);
            if (encodings.isEmpty()) [[unlikely]] {
                auto packetizer = createPacketizer(m_ssrcGenerator, codecParameters, nullptr);
                if (!packetizer)
                    continue;

                if (linkPacketizer(WTF::move(packetizer))) {
                    gst_caps_append_structure(rtpCaps.get(), gst_structure_copy(codecParameters));
                    break;
                }
            }

            bool codecIsValid = false;
            for (const auto& encoding : encodings) {
                GUniquePtr<GstStructure> encodingParameters(gst_structure_copy(encoding));
                auto packetizer = createPacketizer(m_ssrcGenerator, codecParameters, WTF::move(encodingParameters));
                if (!packetizer)
                    continue;

                auto rtpParameters = packetizer->rtpParameters();
                if (!rtpParameters) [[unlikely]]
                    continue;

                codecIsValid = linkPacketizer(WTF::move(packetizer));
                if (!codecIsValid)
                    break;

                gst_caps_append_structure(rtpCaps.get(), rtpParameters.release());
            }

            // TODO: Check optional "codecs" field.

            if (codecIsValid)
                break;

        } else {
            auto packetizer = createPacketizer(m_ssrcGenerator, codecParameters, nullptr);
            if (!packetizer)
                continue;

            auto rtpParameters = packetizer->rtpParameters();
            if (!rtpParameters) [[unlikely]]
                continue;
            if (linkPacketizer(WTF::move(packetizer))) {
                gst_caps_append_structure(rtpCaps.get(), rtpParameters.release());
                break;
            }
        }
    }
    if (m_packetizers.isEmpty()) {
        GST_ERROR_OBJECT(m_bin.get(), "Unable to link any packetizer");
        return false;
    }

    auto structure = gst_caps_get_structure(rtpCaps.get(), 0);

    auto payloadType = gstStructureGet<int>(structure, "payload"_s);
    if (!payloadType) {
        auto& firstPacketizer = m_packetizers.first();
        if (auto pt = firstPacketizer->payloadType())
            gst_structure_set(structure, "payload", G_TYPE_INT, *pt, nullptr);
    }

    StringBuilder simulcastBuilder;
    auto direction = "send"_s;
    simulcastBuilder.append(direction);
    simulcastBuilder.append(' ');
    unsigned totalStreams = 0;
    for (auto& packetizer : m_packetizers) {
        auto rtpStreamId = packetizer->rtpStreamId();
        if (rtpStreamId.isEmpty())
            continue;

        if (totalStreams > 0)
            simulcastBuilder.append(';');
        simulcastBuilder.append(rtpStreamId);
        gst_structure_set(structure, makeString("rid-"_s, rtpStreamId).ascii().data(), G_TYPE_STRING, direction.characters(), nullptr);
        packetizer->configureExtensions();
        totalStreams++;
    }

    auto lookupResults = lookupRtpExtensions(structure);
    if (totalStreams) {
        if (!lookupResults.hasRtpStreamIdExtension) {
            lookupResults.lastIdentifier++;
            auto extensionIdentifier = makeString("extmap-"_s, lookupResults.lastIdentifier);
            gst_structure_set(structure, extensionIdentifier.ascii().data(), G_TYPE_STRING, GST_RTP_HDREXT_BASE "sdes:rtp-stream-id", nullptr);
        }
        if (!lookupResults.hasRtpRepairedStreamIdExtension) {
            lookupResults.lastIdentifier++;
            auto extensionIdentifier = makeString("extmap-"_s, lookupResults.lastIdentifier);
            gst_structure_set(structure, extensionIdentifier.ascii().data(), G_TYPE_STRING, GST_RTP_HDREXT_BASE "sdes:repaired-rtp-stream-id", nullptr);
        }

        gst_structure_set(structure, "a-simulcast", G_TYPE_STRING, simulcastBuilder.toString().ascii().data(), nullptr);
        GST_DEBUG_OBJECT(m_bin.get(), "Simulcast parameters: %" GST_PTR_FORMAT, structure);
    }
    if (!lookupResults.hasMidExtension) {
        lookupResults.lastIdentifier++;
        auto extensionIdentifier = makeString("extmap-"_s, lookupResults.lastIdentifier);
        gst_structure_set(structure, extensionIdentifier.ascii().data(), G_TYPE_STRING, GST_RTP_HDREXT_BASE "sdes:mid", nullptr);
    }

    GST_DEBUG_OBJECT(m_bin.get(), "Setting RTP funnel caps to %" GST_PTR_FORMAT, rtpCaps.get());
    g_object_set(m_rtpCapsfilter.get(), "caps", rtpCaps.get(), nullptr);
    return true;
}

RealtimeOutgoingMediaSourceGStreamer::ExtensionLookupResults RealtimeOutgoingMediaSourceGStreamer::lookupRtpExtensions(const GstStructure* structure)
{
    ExtensionLookupResults lookupResults;
    gstStructureForeach(structure, [&](auto id, const auto value) -> bool {
        auto name = gstIdToString(id);
        if (!name.startsWith("extmap-"_s))
            return true;

        auto identifier = WTF::parseInteger<int>(name.substring(7)).value_or(0);
        if (!identifier) [[unlikely]]
            return true;

        lookupResults.lastIdentifier = std::max(lookupResults.lastIdentifier, identifier);

        StringView uri;
        if (G_VALUE_HOLDS_STRING(value))
            uri = StringView::fromLatin1(g_value_get_string(value));
        else if (GST_VALUE_HOLDS_ARRAY(value)) {
            const auto uriValue = gst_value_array_get_value(value, 1);
            uri = StringView::fromLatin1(g_value_get_string(uriValue));
        } else
            return true;

        if (uri == GST_RTP_HDREXT_BASE "sdes:rtp-stream-id"_s)
            lookupResults.hasRtpStreamIdExtension = true;
        if (uri == GST_RTP_HDREXT_BASE "sdes:repaired-rtp-stream-id"_s)
            lookupResults.hasRtpRepairedStreamIdExtension = true;
        if (uri == GST_RTP_HDREXT_BASE "sdes:mid"_s)
            lookupResults.hasMidExtension = true;

        return true;
    });
    return lookupResults;
}

GUniquePtr<GstStructure> RealtimeOutgoingMediaSourceGStreamer::stats()
{
    GUniquePtr<GstStructure> stats(gst_structure_new_empty("outgoing-media-stats"));
    for (auto& packetizer : m_packetizers) {
        auto packetizerStats = packetizer->stats();
        if (!packetizerStats)
            continue;

        auto [ssrc, structure] = *packetizerStats;
        auto ssrcString = makeString(ssrc);
        gst_structure_set(stats.get(), ssrcString.ascii().data(), GST_TYPE_STRUCTURE, structure, nullptr);
    }
    return stats;
}

GUniquePtr<GstStructure> RealtimeOutgoingMediaSourceGStreamer::mediaCaptureStats()
{
    GUniquePtr<GstStructure> stats(gst_structure_new_empty("media-capture-stats"));

    if (!m_outgoingSource)
        return stats;

    auto type = makeString(m_type == Type::Audio ? "audio"_s : "video"_s, "-source-stats"_s);
    auto id = makeString("track-"_s, m_trackId, "-stats"_s);
    auto timestamp = MonotonicTime::now().secondsSinceEpoch().microsecondsAs<int64_t>();
    gst_structure_set(stats.get(), "webkit-stats-type", G_TYPE_STRING, type.ascii().data(),
        "id", G_TYPE_STRING, id.utf8().data(), "timestamp", G_TYPE_DOUBLE, static_cast<double>(timestamp),
        "kind", G_TYPE_STRING, m_type == Type::Audio ? "audio" : "video", "track-identifier", G_TYPE_STRING, m_trackId.utf8().data(), nullptr);
    auto query = adoptGRef(gst_query_new_custom(GST_QUERY_CUSTOM, gst_structure_new_empty("webkit-media-source-stats")));
    auto srcPad = outgoingSourcePad();
    if (gst_pad_query(srcPad.get(), query.get())) {
        gstStructureForeach(gst_query_get_structure(query.get()), [&](auto id, const auto* value) -> bool {
            gstStructureIdSetValue(stats.get(), id, value);
            return true;
        });
    }

    return stats;
}

void RealtimeOutgoingMediaSourceGStreamer::startUpdatingStats()
{
    GST_DEBUG_OBJECT(m_bin.get(), "Starting buffer monitoring for stats gathering");
    for (auto& packetizer : m_packetizers)
        packetizer->startUpdatingStats();
}

void RealtimeOutgoingMediaSourceGStreamer::stopUpdatingStats()
{
    GST_DEBUG_OBJECT(m_bin.get(), "Stopping buffer monitoring for stats gathering");
    for (auto& packetizer : m_packetizers)
        packetizer->stopUpdatingStats();
}

void RealtimeOutgoingMediaSourceGStreamer::teardown()
{
    GST_DEBUG_OBJECT(m_bin.get(), "Tearing down");
    if (m_transceiver)
        g_signal_handlers_disconnect_by_data(m_transceiver.get(), this);

    stopOutgoingSource([&] {
        stopUpdatingStats();

        if (GST_IS_PAD(m_webrtcSinkPad.get())) {
            auto srcPad = adoptGRef(gst_element_get_static_pad(m_bin.get(), "src"));
            if (gst_pad_unlink(srcPad.get(), m_webrtcSinkPad.get())) {
                GST_DEBUG_OBJECT(m_bin.get(), "Removing webrtcbin pad %" GST_PTR_FORMAT, m_webrtcSinkPad.get());
                if (auto parent = adoptGRef(gst_pad_get_parent_element(m_webrtcSinkPad.get())))
                    gst_element_release_request_pad(parent.get(), m_webrtcSinkPad.get());
            }
        }

        gstElementLockAndSetState(m_bin.get(), GST_STATE_NULL);

        if (auto pipeline = adoptGRef(gst_element_get_parent(m_bin.get())))
            gst_bin_remove(GST_BIN_CAST(pipeline.get()), m_bin.get());

        m_packetizers.clear();

        m_bin.clear();
        m_inputSelector.clear();
        m_tee.clear();
        m_rtpFunnel.clear();
        m_allowedCaps.clear();
        m_transceiver.clear();
        m_sender.clear();
        m_webrtcSinkPad.clear();
        m_parameters.reset();
    });
}

RealtimeMediaSource::Type RealtimeOutgoingMediaSourceGStreamer::type() const
{
    if (m_type == Type::Video)
        return RealtimeMediaSource::Type::Video;

    return RealtimeMediaSource::Type::Audio;
}

#undef GST_CAT_DEFAULT

} // namespace WebCore

#endif // USE(GSTREAMER_WEBRTC)
