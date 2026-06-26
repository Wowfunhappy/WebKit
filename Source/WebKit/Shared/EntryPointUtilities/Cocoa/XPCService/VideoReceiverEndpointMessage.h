#pragma once

// MAVERICKS_BACKPORT: empty stub header that exists only for the 10.9 Mac build. XPCEndpointMessages.mm imports
// "VideoReceiverEndpointMessage.h" unconditionally, but the real VideoReceiverEndpointMessage class lives in
// Source/WebKit/Platform/ios/VideoReceiverEndpointMessage.h, gated by ENABLE(LINEAR_MEDIA_PLAYER) (an iOS LinearMediaKit
// feature that is off here) and not on the Mac include path. Every use of the class in XPCEndpointMessages.mm is itself
// behind ENABLE(LINEAR_MEDIA_PLAYER), so this empty header just satisfies the unconditional #import on 10.9.
