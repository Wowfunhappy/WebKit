// Stubbed for MAVERICKS_BACKPORT
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "ScrollingTreePluginScrollingNodeRemoteMac.h"

#if PLATFORM(MAC)

#include "RemoteScrollingTree.h"
#include <WebCore/ScrollingStatePluginScrollingNode.h>
#include <WebCore/ScrollingTreeScrollingNodeDelegate.h>

namespace WebKit {
using namespace WebCore;

Ref<ScrollingTreePluginScrollingNodeRemoteMac> ScrollingTreePluginScrollingNodeRemoteMac::create(ScrollingTree& tree, ScrollingNodeID nodeID)
{
    return adoptRef(*new ScrollingTreePluginScrollingNodeRemoteMac(tree, nodeID));
}

ScrollingTreePluginScrollingNodeRemoteMac::ScrollingTreePluginScrollingNodeRemoteMac(ScrollingTree& tree, ScrollingNodeID nodeID)
    : ScrollingTreePluginScrollingNodeMac(tree, nodeID)
{
    m_delegate->initScrollbars();
}

ScrollingTreePluginScrollingNodeRemoteMac::~ScrollingTreePluginScrollingNodeRemoteMac() = default;

void ScrollingTreePluginScrollingNodeRemoteMac::repositionRelatedLayers()
{
    ScrollingTreePluginScrollingNodeMac::repositionRelatedLayers();
    m_delegate->updateScrollbarLayers();
}

void ScrollingTreePluginScrollingNodeRemoteMac::handleWheelEventPhase(const PlatformWheelEventPhase phase)
{
    m_delegate->handleWheelEventPhase(phase);
}

String ScrollingTreePluginScrollingNodeRemoteMac::scrollbarStateForOrientation(ScrollbarOrientation orientation) const
{
    return m_delegate->scrollbarStateForOrientation(orientation);
}

}

#endif
MAVERICKS_BACKPORT */
