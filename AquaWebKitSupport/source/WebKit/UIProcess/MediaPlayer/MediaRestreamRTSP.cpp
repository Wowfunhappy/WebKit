#include "config.h"
#include "MediaRestreamRTSP.h"

#include <gst/app/gstappsrc.h>
#include <gst/rtp/gstrtpbuffer.h>
#include <gst/video/video-color.h>
#include <gst/rtsp-server/rtsp-server.h>
#include <wtf/JSONValues.h>
#include <wtf/MainThread.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/MakeString.h>
#include <atomic>
#include <array>
#include <vector>

namespace WebKit {
struct MediaRestreamRTSP::Impl : std::enable_shared_from_this<Impl> {
    struct Track {
        GstCaps* caps { nullptr };
        GstAppSrc* source { nullptr };
        std::atomic<bool> wanted { false };
        bool pending { false };
        uint16_t sequence { static_cast<uint16_t>(arc4random()) };
        uint32_t ssrc { arc4random() };
        uint32_t timestamp { arc4random() };
        std::vector<uint8_t> description;
        ~Track() { if (caps) gst_caps_unref(caps); if (source) gst_object_unref(source); }
    };
    std::array<Track, 2> tracks;
    GstRTSPServer* server { nullptr };
    GMainContext* context { g_main_context_new() };
    GMainLoop* loop { g_main_loop_new(context, false) };
    GSource* listener { nullptr };
    Read read;
    URL url;
    std::atomic<bool> stopped { false };

    ~Impl()
    {
        if (listener) g_source_unref(listener);
        if (server) gst_object_unref(server);
        g_main_loop_unref(loop);
        g_main_context_unref(context);
    }
    void stop()
    {
        stopped = true;
        if (listener) g_source_destroy(listener);
        if (server) {
            auto* clients = gst_rtsp_server_client_filter(server, [](GstRTSPServer*, GstRTSPClient*, gpointer) { return GST_RTSP_FILTER_REF; }, nullptr);
            for (auto* item = clients; item; item = item->next)
                gst_rtsp_client_close(GST_RTSP_CLIENT(item->data));
            g_list_free_full(clients, g_object_unref);
        }
        // Dispatch shutdown on the loop, including when its worker has not
        // started yet: quitting before g_main_loop_run would lose the request.
        auto* quit = g_idle_source_new();
        g_source_set_callback(quit, [](gpointer loop) -> gboolean {
            g_main_loop_quit(static_cast<GMainLoop*>(loop));
            return G_SOURCE_REMOVE;
        }, g_main_loop_ref(loop), [](gpointer loop) { g_main_loop_unref(static_cast<GMainLoop*>(loop)); });
        g_source_attach(quit, context);
        g_source_unref(quit);
    }
    bool makeDescription(Track& track)
    {
        auto* caps = gst_caps_get_structure(track.caps, 0);
        int width, height;
        if (!gst_structure_get_int(caps, "width", &width) || !gst_structure_get_int(caps, "height", &height) || width < 1 || height < 1 || width > 16384 || height > 16384)
            return false;
        bool utvideo = gst_structure_has_name(caps, "video/x-utvideo");
        if (!utvideo && !gst_structure_has_name(caps, "image/jpeg"))
            return false;
        auto* value = gst_structure_get_value(caps, "codec_data");
        GstBuffer* extra = value && GST_VALUE_HOLDS_BUFFER(value) ? gst_value_get_buffer(value) : nullptr;
        auto extraSize = extra ? gst_buffer_get_size(extra) : 0;
        if (utvideo && (extraSize != 16))
            return false;
        int parN = 1, parD = 1;
        gst_structure_get_fraction(caps, "pixel-aspect-ratio", &parN, &parD);
        if (parN < 1 || parD < 1)
            return false;
        GstVideoColorimetry color;
        auto* colorName = gst_structure_get_string(caps, "colorimetry");
        bool hasColor = utvideo && colorName && gst_video_colorimetry_from_string(&color, colorName);
        auto extensions = 86 + (extraSize ? 8 + extraSize : 0);
        track.description.assign(extensions + 16 + (hasColor ? 18 : 0), 0);
        auto* bytes = track.description.data();
        GST_WRITE_UINT32_BE(bytes, track.description.size());
        memcpy(bytes + 4, utvideo ? (hasColor && color.matrix == GST_VIDEO_COLOR_MATRIX_BT709 ? "ULH0" : "ULY0") : "jpeg", 4);
        GST_WRITE_UINT16_BE(bytes + 14, 1);
        memcpy(bytes + 20, "appl", 4);
        GST_WRITE_UINT32_BE(bytes + 24, 512);
        GST_WRITE_UINT32_BE(bytes + 28, 512);
        GST_WRITE_UINT16_BE(bytes + 32, width);
        GST_WRITE_UINT16_BE(bytes + 34, height);
        GST_WRITE_UINT32_BE(bytes + 36, 72 << 16);
        GST_WRITE_UINT32_BE(bytes + 40, 72 << 16);
        GST_WRITE_UINT16_BE(bytes + 48, 1);
        GST_WRITE_UINT16_BE(bytes + 82, 24);
        GST_WRITE_UINT16_BE(bytes + 84, 0xffff);
        if (extraSize) {
            GST_WRITE_UINT32_BE(bytes + 86, 8 + extraSize);
            memcpy(bytes + 90, "glbl", 4);
            gst_buffer_extract(extra, 0, bytes + 94, extraSize);
        }
        auto* aspect = bytes + extensions;
        GST_WRITE_UINT32_BE(aspect, 16);
        memcpy(aspect + 4, "pasp", 4);
        GST_WRITE_UINT32_BE(aspect + 8, parN);
        GST_WRITE_UINT32_BE(aspect + 12, parD);
        if (hasColor) {
            auto* atom = aspect + 16;
            GST_WRITE_UINT32_BE(atom, 18);
            memcpy(atom + 4, "colrnclc", 8);
            GST_WRITE_UINT16_BE(atom + 12, gst_video_color_primaries_to_iso(color.primaries));
            GST_WRITE_UINT16_BE(atom + 14, gst_video_transfer_function_to_iso(color.transfer));
            GST_WRITE_UINT16_BE(atom + 16, gst_video_color_matrix_to_iso(color.matrix));
        }
        return true;
    }
    bool pushVideo(Track& track, const WebCore::SharedBuffer& buffer, uint64_t time, uint64_t duration)
    {
        auto bytes = buffer.span();
        for (size_t offset = 0; offset < bytes.size();) {
            auto amount = std::min<size_t>(1200, bytes.size() - offset);
            auto descriptionSize = 16 + track.description.size();
            auto header = 4 + (offset ? 0 : (descriptionSize + 3) & ~3);
            auto* packet = gst_rtp_buffer_new_allocate(header + amount, 0, 0);
            GstRTPBuffer rtp = GST_RTP_BUFFER_INIT;
            if (!gst_rtp_buffer_map(packet, GST_MAP_WRITE, &rtp)) {
                gst_buffer_unref(packet);
                return false;
            }
            gst_rtp_buffer_set_payload_type(&rtp, 96);
            gst_rtp_buffer_set_seq(&rtp, track.sequence++);
            gst_rtp_buffer_set_timestamp(&rtp, track.timestamp + gst_util_uint64_scale(time, 90000, GST_SECOND));
            gst_rtp_buffer_set_ssrc(&rtp, track.ssrc);
            gst_rtp_buffer_set_marker(&rtp, offset + amount == bytes.size());
            auto* payload = static_cast<uint8_t*>(gst_rtp_buffer_get_payload(&rtp));
            memset(payload, 0, header);
            // QuickTime generic RTP v1, fragmented sample, inline uncached description.
            payload[0] = offset ? 0x1e : 0x1f;
            payload[2] = 0x80;
            payload[3] = 1;
            if (!offset) {
                payload[4] = 0xb0;
                GST_WRITE_UINT16_BE(payload + 6, descriptionSize);
                memcpy(payload + 8, "vide", 4);
                GST_WRITE_UINT32_BE(payload + 12, 90000);
                GST_WRITE_UINT16_BE(payload + 16, track.description.size());
                memcpy(payload + 18, "sd", 2);
                memcpy(payload + 20, track.description.data(), track.description.size());
            }
            memcpy(payload + header, bytes.data() + offset, amount);
            gst_rtp_buffer_unmap(&rtp);
            GST_BUFFER_PTS(packet) = time;
            GST_BUFFER_DURATION(packet) = duration;
            if (gst_app_src_push_buffer(track.source, packet) != GST_FLOW_OK)
                return false;
            offset += amount;
        }
        return true;
    }
    void request(bool video)
    {
        ASSERT(isMainThread());
        auto& track = tracks[video ? 0 : 1];
        if (stopped || !track.wanted || track.pending || !track.source)
            return;
        track.pending = true;
        read(video, [self = shared_from_this(), video](String&& capsString, uint64_t time, uint64_t duration, RefPtr<WebCore::SharedBuffer>&& data) {
            auto& track = self->tracks[video ? 0 : 1];
            track.pending = false;
            if (self->stopped || !track.source)
                return;
            if (!data || data->size() > 64 * 1024 * 1024 || capsString.length() > 16384) {
                track.wanted = false;
                gst_app_src_end_of_stream(track.source);
                return;
            }
            auto* caps = gst_caps_from_string(capsString.utf8().data());
            bool same = caps && gst_caps_is_equal(caps, track.caps);
            if (caps && !same && video) {
                gst_caps_unref(track.caps);
                track.caps = gst_caps_ref(caps);
                same = self->makeDescription(track);
            }
            if (caps) gst_caps_unref(caps);
            if (!same) {
                track.wanted = false;
                gst_app_src_end_of_stream(track.source);
                return;
            }
            bool pushed;
            if (video)
                pushed = self->pushVideo(track, *data, time, duration);
            else {
                auto* buffer = gst_buffer_new_allocate(nullptr, data->size(), nullptr);
                gst_buffer_fill(buffer, 0, data->span().data(), data->size());
                GST_BUFFER_PTS(buffer) = time;
                GST_BUFFER_DURATION(buffer) = duration;
                pushed = gst_app_src_push_buffer(track.source, buffer) == GST_FLOW_OK;
            }
            if (pushed)
                self->request(video);
        });
    }
    void configure(GstRTSPMedia* media)
    {
        auto* element = gst_rtsp_media_get_element(media);
        for (bool video : { true, false }) {
            auto& track = tracks[video ? 0 : 1];
            if (!track.caps)
                continue;
            auto* source = gst_bin_get_by_name_recurse_up(GST_BIN(element), video ? "video" : "audio");
            if (video) {
                auto* caps = gst_caps_from_string("application/x-rtp,media=video,payload=96,clock-rate=90000,encoding-name=X-QT");
                gst_app_src_set_caps(GST_APP_SRC(source), caps);
                gst_caps_unref(caps);
            } else
                gst_app_src_set_caps(GST_APP_SRC(source), track.caps);
            g_object_set(source, "max-bytes", static_cast<guint64>(4 * 1024 * 1024), "block", FALSE, nullptr);
            struct Feed { std::weak_ptr<Impl> owner; bool video; };
            GstAppSrcCallbacks callbacks { };
            callbacks.need_data = [](GstAppSrc*, guint, gpointer pointer) {
                auto& feed = *static_cast<Feed*>(pointer);
                if (auto self = feed.owner.lock()) {
                    self->tracks[feed.video ? 0 : 1].wanted = true;
                    callOnMainThread([self, video = feed.video] { self->request(video); });
                }
            };
            callbacks.enough_data = [](GstAppSrc*, gpointer pointer) {
                auto& feed = *static_cast<Feed*>(pointer);
                if (auto self = feed.owner.lock())
                    self->tracks[feed.video ? 0 : 1].wanted = false;
            };
            gst_app_src_set_callbacks(GST_APP_SRC(source), &callbacks, new Feed { weak_from_this(), video }, [](gpointer pointer) { delete static_cast<Feed*>(pointer); });
            callOnMainThread([self = shared_from_this(), source, video] {
                auto& track = self->tracks[video ? 0 : 1];
                if (track.source) gst_object_unref(track.source);
                track.source = GST_APP_SRC(source);
                self->request(video);
            });
        }
        gst_object_unref(element);
    }
};

std::shared_ptr<MediaRestreamRTSP> MediaRestreamRTSP::create(const String& description, const String& path, Read&& read)
{
    if (description.length() > 32768 || !gst_init_check(nullptr, nullptr, nullptr))
        return nullptr;
    auto value = JSON::Value::parseJSON(description);
    auto object = value ? value->asObject() : nullptr;
    if (!object)
        return nullptr;
    auto impl = std::make_shared<Impl>();
    impl->read = WTF::move(read);
    std::string pipeline = "( ";
    for (bool video : { true, false }) {
        auto text = object->getString(video ? "video"_s : "audio"_s);
        if (text.length() > 16384)
            return nullptr;
        if (text.isEmpty())
            continue;
        auto& track = impl->tracks[video ? 0 : 1];
        track.caps = gst_caps_from_string(text.utf8().data());
        if (!track.caps || !gst_caps_is_fixed(track.caps) || (video && !impl->makeDescription(track)))
            return nullptr;
        if (!video) {
            auto* audio = gst_caps_get_structure(track.caps, 0);
            int channels, rate;
            if (!gst_structure_has_name(audio, "audio/mpeg") || !gst_structure_get_int(audio, "channels", &channels) || channels < 1 || channels > 8
                || !gst_structure_get_int(audio, "rate", &rate) || rate != 48000 || g_strcmp0(gst_structure_get_string(audio, "stream-format"), "raw"))
                return nullptr;
        }
        if (video)
            pipeline += "appsrc name=video format=time ! rtppassthroughpay name=pay0 pt=96 ";
        else
            // An AAC-hbr access unit is at most 8191 bytes. The loopback
            // transport can carry a complete unit without RTP fragmentation.
            pipeline += impl->tracks[0].caps ? "appsrc name=audio format=time ! rtpmp4gpay name=pay1 pt=97 mtu=9000 " : "appsrc name=audio format=time ! rtpmp4gpay name=pay0 pt=97 mtu=9000 ";
    }
    pipeline += ')';
    if (!impl->tracks[0].caps && !impl->tracks[1].caps)
        return nullptr;
    impl->server = gst_rtsp_server_new();
    gst_rtsp_server_set_address(impl->server, "127.0.0.1");
    gst_rtsp_server_set_service(impl->server, "0");
    auto* factory = gst_rtsp_media_factory_new();
    gst_rtsp_media_factory_set_launch(factory, pipeline.c_str());
    gst_rtsp_media_factory_set_shared(factory, TRUE);
    g_signal_connect_data(factory, "media-configure", G_CALLBACK(+[](GstRTSPMediaFactory*, GstRTSPMedia* media, gpointer pointer) {
        if (auto self = static_cast<std::weak_ptr<Impl>*>(pointer)->lock())
            self->configure(media);
    }), new std::weak_ptr<Impl>(impl), [](gpointer pointer, GClosure*) { delete static_cast<std::weak_ptr<Impl>*>(pointer); }, G_CONNECT_DEFAULT);
    auto* mounts = gst_rtsp_server_get_mount_points(impl->server);
    auto mount = makeString('/', path).utf8();
    gst_rtsp_mount_points_add_factory(mounts, mount.data(), factory);
    gst_object_unref(mounts);
    impl->listener = gst_rtsp_server_create_source(impl->server, nullptr, nullptr);
    if (!impl->listener)
        return nullptr;
    g_source_attach(impl->listener, impl->context);
    impl->url = URL { makeString("rtsp://127.0.0.1:"_s, gst_rtsp_server_get_bound_port(impl->server), '/', path) };
    auto* loop = g_main_loop_ref(impl->loop);
    WorkQueue::create("Media RTSP server"_s)->dispatch([loop] {
        g_main_context_push_thread_default(g_main_loop_get_context(loop));
        g_main_loop_run(loop);
        g_main_context_pop_thread_default(g_main_loop_get_context(loop));
        g_main_loop_unref(loop);
    });
    return std::shared_ptr<MediaRestreamRTSP>(new MediaRestreamRTSP(WTF::move(impl)));
}
MediaRestreamRTSP::MediaRestreamRTSP(std::shared_ptr<Impl>&& impl) : m_impl(WTF::move(impl)) { }
MediaRestreamRTSP::~MediaRestreamRTSP() { m_impl->stop(); }
URL MediaRestreamRTSP::url() const { return m_impl->url; }
}
