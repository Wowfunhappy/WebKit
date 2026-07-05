/*
 * no-op stub for the 8 gst_vulkan_* symbols libgstapplemedia.dylib imports.
 *
 * The vendored GStreamer applemedia plugin (avfvideosrc / avfdeviceprovider -- the macOS camera-capture
 * elements) is built on the modern host with the Vulkan/Metal zero-copy video path enabled, so it links
 * libgstvulkan-1.0.0 (-> libMoltenVK -> Metal.framework). Metal is absent on 10.9, so the real Vulkan
 * path can never run here; AVFoundation camera capture (avfvideosrc -> appsink) does not use it. These
 * stubs only need to let the plugin LOAD -- they are never called during capture.
 *
 * Built by build-applemedia-compat.sh, which replaces the real (Metal-linked) libgstvulkan-1.0.0.dylib
 * with this stub. The -compatibility_version must match the real lib (2607.0.0) so dyld accepts it.
 */
unsigned long gst_vulkan_device_get_type(void) { return 0; }
void* gst_vulkan_device_get_physical_device(void* a) { (void)a; return 0; }
int gst_vulkan_ensure_element_data(void* a, void* b, void* c) { (void)a; (void)b; (void)c; return 0; }
int gst_vulkan_ensure_element_device(void* a, void* b, void* c) { (void)a; (void)b; (void)c; return 0; }
void* gst_vulkan_error_to_g_error(void* a, void* b) { (void)a; (void)b; return 0; }
int gst_vulkan_handle_set_context(void* a, void* b, void* c, void* d) { (void)a; (void)b; (void)c; (void)d; return 0; }
unsigned long gst_vulkan_image_memory_allocator_get_type(void) { return 0; }
void gst_vulkan_image_memory_init(void) {}
