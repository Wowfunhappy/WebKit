#include "config.h"
#include "GStreamerPackagingMavericks.h"

#if USE(GSTREAMER)

#include <gst/gst.h>
#include <wtf/FileSystem.h>
#include <wtf/text/WTFString.h>

#if PLATFORM(COCOA)
#include <dlfcn.h>
#endif

namespace WebCore {

// this port ships GStreamer's plugins inside WebCore.framework, while libgstreamer
// carries the plugin directory of the tree it was compiled in -- a path under the building user's home.
// A sandboxed WebContent process is denied that path, so every plugin fails to load and elements as
// basic as appsink and autoaudiosink are "not found". Point GStreamer at the plugins that ship beside
// the WebCore being run, which the process can always reach. Runs before gst_init(), which is when the
// plugin path is read.
void configureGStreamerPluginPath()
{
#if PLATFORM(COCOA)
    if (g_getenv("GST_PLUGIN_SYSTEM_PATH"))
        return;

    Dl_info info;
    if (!dladdr(reinterpret_cast<const void*>(&configureGStreamerPluginPath), &info) || !info.dli_fname)
        return;

    // .../WebCore.framework/Versions/A/WebCore -> .../Versions/A/Frameworks/gstreamer/lib/gstreamer-1.0
    auto versionDirectory = FileSystem::parentPath(String::fromUTF8(info.dli_fname));
    auto pluginDirectory = FileSystem::pathByAppendingComponents(versionDirectory,
        std::array<StringView, 4> { "Frameworks"_s, "gstreamer"_s, "lib"_s, "gstreamer-1.0"_s });
    if (!FileSystem::fileExists(pluginDirectory))
        return;

    g_setenv("GST_PLUGIN_SYSTEM_PATH", pluginDirectory.utf8().data(), FALSE);
#endif
}

// GStreamer caches its plugin scan in $XDG_CACHE_HOME/gstreamer-1.0, which on this platform is
// ~/.cache/gstreamer-1.0 -- inside the home directory, which a sandboxed WebContent process cannot
// write and should not be able to. Left alone, every launch is denied both the read and the write,
// so the plugin registry is rescanned from scratch on each one.
//
// The registry is a cache, and a sandboxed Cocoa process already has a per-user cache directory it
// owns: _CS_DARWIN_USER_CACHE_DIR, which the profiles grant in full and which survives across
// launches. Point GStreamer at it. This runs before gst_init(), which is when GST_REGISTRY is read.
//
// Registry scanning also forks a helper by default; the sandbox denies process-fork (correctly --
// nothing here needs to spawn), so ask GStreamer to scan in-process rather than have it attempt a
// fork that cannot succeed.
void configureGStreamerCacheLocation()
{
#if PLATFORM(COCOA)
    gst_registry_fork_set_enabled(FALSE);

    if (g_getenv("GST_REGISTRY"))
        return;

    std::array<char, PATH_MAX> cacheDirectory;
    if (confstr(_CS_DARWIN_USER_CACHE_DIR, cacheDirectory.data(), cacheDirectory.size()) <= 0)
        return;

    auto registryDirectory = FileSystem::pathByAppendingComponent(String::fromUTF8(cacheDirectory.data()), "gstreamer-1.0"_s);
    if (!FileSystem::makeAllDirectories(registryDirectory))
        return;

    // Architecture-tagged, the way GStreamer names it itself, so a registry written by one process
    // is only ever reused by another of the same architecture.
#if CPU(X86_64)
    static constexpr auto registryFileName = "registry.x86_64.bin"_s;
#elif CPU(ARM64)
    static constexpr auto registryFileName = "registry.arm64.bin"_s;
#else
    static constexpr auto registryFileName = "registry.bin"_s;
#endif
    auto registryPath = FileSystem::pathByAppendingComponent(registryDirectory, registryFileName);
    g_setenv("GST_REGISTRY", registryPath.utf8().data(), FALSE);
#endif
}

} // namespace WebCore

#endif // USE(GSTREAMER)
