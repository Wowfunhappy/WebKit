#pragma once

// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE flipped to 0 (in
// PlatformEnableCocoa.h). The full 742-line isolated-tree definition is compiled out, but several files
// include this header unconditionally and name the type, so keep a minimal stub class. Scaffolding for the
// keystone flag; feature-disable, not an SDK gap.
#include <wtf/RefCounted.h>

namespace WebCore {

// MAVERICKS_BACKPORT: minimal stub replacing the compiled-out isolated-tree definition (feature off).
class AXIsolatedTree : public RefCounted<AXIsolatedTree> {
public:
    // MAVERICKS_BACKPORT: only member needed by callers that include this header with the feature off.
    void updateNodeProperties(std::initializer_list<void*>) { }
};

} // namespace WebCore
