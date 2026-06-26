#pragma once
// MAVERICKS_BACKPORT: empty stub header that exists only in the backport. WebProcess/WebCoreSupport is on the WebKit include path, so a bare-name `#import "PlaybackSessionInterfaceAVKit.h"` (which on iOS resolves to Platform/ios/PlaybackSessionInterfaceAVKit.h) resolves here on the Mac/10.9 build, making the include a harmless no-op so the iOS/AVKit-only PlaybackSessionInterfaceAVKit type is not pulled into the Mac path.
// stubbed
