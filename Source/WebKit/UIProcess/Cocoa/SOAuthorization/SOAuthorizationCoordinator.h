#pragma once
// Stubbed for macOS 10.9 backport - SOAuthorization not available
#include <wtf/FastMalloc.h>
namespace WebKit {
class SOAuthorizationCoordinator {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(SOAuthorizationCoordinator);
public:
    SOAuthorizationCoordinator() = default;
    ~SOAuthorizationCoordinator() = default;
};
}
