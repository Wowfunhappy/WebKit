// MAVERICKS_BACKPORT: this header does not exist in the upstream base; the build's source list (PlatformMac.cmake /
// SourcesCocoa.txt) references PlaybackSessionInterfaceAVKit, but the modern AVKit playback-session interface has no
// 10.9 backend, so an empty placeholder header is provided here to satisfy those references.
#pragma once
