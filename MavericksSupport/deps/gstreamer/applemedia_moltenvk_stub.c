/*
 * no-op stub for the 8 Vulkan/MoltenVK symbols libgstapplemedia.dylib imports.
 *
 * Companion to applemedia_vulkan_stub.c -- see that file for the rationale. The real libMoltenVK is a
 * full Vulkan-on-Metal implementation that cannot load on 10.9 (no Metal), so it is dead weight here;
 * AVFoundation camera capture never calls these. The stub only lets libgstapplemedia LOAD.
 *
 * Built by build-applemedia-compat.sh, which replaces the real (Metal-linked) libMoltenVK.dylib.
 */
unsigned int mvkMTLPixelFormatFromVkFormat(unsigned int f) { (void)f; return 0; }
unsigned int mvkMTLTextureTypeFromVkImageType(unsigned int t) { (void)t; return 0; }
unsigned int mvkSampleCountFromVkSampleCountFlagBits(unsigned int s) { (void)s; return 1; }
int vkCreateImage(void* a, void* b, void* c, void* d) { (void)a; (void)b; (void)c; (void)d; return -1; }
void vkGetImageMemoryRequirements(void* a, void* b, void* c) { (void)a; (void)b; (void)c; }
void* vkGetMTLDeviceMVK(void* a) { (void)a; return 0; }
int vkGetPhysicalDeviceImageFormatProperties(void* a, void* b, void* c, void* d, void* e, void* f, void* g)
    { (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; return -1; }
void vkSetMTLTextureMVK(void* a, void* b) { (void)a; (void)b; }
