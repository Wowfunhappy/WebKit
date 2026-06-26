// MAVERICKS_BACKPORT: empty placeholder header for the cocoa WebProcess include path.
// The real WKVideoView lives at UIProcess/ios/WKVideoView.{h,mm}; on 10.9 the fullscreen
// video presentation path it backs is disabled, so this stub only satisfies includes
// without pulling in the iOS view.
#pragma once
