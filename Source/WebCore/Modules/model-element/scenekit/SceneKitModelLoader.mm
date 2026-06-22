// MAVERICKS_BACKPORT: runtime-absent frameworks — the <model> SceneKit USD loader path needs SceneKit USD
// support (10.13+), absent on 10.9, so loadSceneKitModel stays stubbed. But the SceneKitModelLoaderClient
// out-of-line virtual destructor anchors the client vtable (referenced by SceneKitModelPlayer) and has no
// SceneKit dependency, so define it here.
#include "config.h"
#include "SceneKitModelLoaderClient.h"

namespace WebCore {

SceneKitModelLoaderClient::~SceneKitModelLoaderClient() = default;

} // namespace WebCore
