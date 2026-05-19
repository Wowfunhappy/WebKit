#pragma once

#include <wtf/RefCounted.h>

namespace WebCore {

class AXIsolatedTree : public RefCounted<AXIsolatedTree> {
public:
    void updateNodeProperties(std::initializer_list<void*>) { }
};

} // namespace WebCore
