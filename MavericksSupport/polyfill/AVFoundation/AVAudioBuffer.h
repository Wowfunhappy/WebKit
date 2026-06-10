// 10.9 backport stub. AVAudioBuffer / AVAudioPCMBuffer (AVFoundation audio-engine) are macOS 10.10+;
// the 10.9 SDK has no AVFoundation/AVAudioBuffer.h. WebKit's MockAudioCaptureUnit.mm #imports this
// header but does its audio work through CoreAudio (AudioBufferList), not AVAudioBuffer, so an empty
// declaration is enough to satisfy the import on 10.9.
#pragma once
