#pragma once

// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE flipped to 0 (in
// PlatformEnableCocoa.h). The full 742-line isolated-tree definition is compiled out, but several files
// include this header unconditionally and name the type, so keep a minimal stub class. Scaffolding for the
// keystone flag; feature-disable, not an SDK gap.
#include <wtf/RefCounted.h>

namespace WebCore {

class AXIsolatedTree : public RefCounted<AXIsolatedTree> {
public:
    void updateNodeProperties(std::initializer_list<void*>) { }
};

} // namespace WebCore
