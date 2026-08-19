// No-op GPUProcessProxy stub class; the GPU process is not built on the 10.9 CMake build, so WebPageProxy.cpp includes this in its place to satisfy GPUProcessProxy references (singletonIfCreated/getOrCreate/send/releaseSnapshot) with inert no-ops.
// Stub for GPUProcessProxy (not available on macOS 10.9 CMake build)
#pragma once
#include <wtf/CanMakeWeakPtr.h>

namespace WebKit {
class GPUProcessProxy : public CanMakeWeakPtr<GPUProcessProxy> {
public:
    static GPUProcessProxy* singletonIfCreated() { return nullptr; }
    static GPUProcessProxy& getOrCreate() { static GPUProcessProxy s; return s; }
    template<typename... A> void setPresentingApplicationAuditToken(A&&...) {}
    bool hasConnection() { return false; }
    template<typename T, typename... A> void send(T&&, A&&...) {}
    template<typename... A> void updatePreferences(A&&...) {}
    template<typename... A> auto releaseSnapshot(A&&...) -> decltype(nullptr) { return nullptr; }
    template<typename... A> void sinkCompletedSnapshotToBitmap(A&&...) {}
    template<typename... A> void sinkCompletedSnapshotToPDF(A&&...) {}
    void ref() const {}
    void deref() const {}
};
} // namespace WebKit
