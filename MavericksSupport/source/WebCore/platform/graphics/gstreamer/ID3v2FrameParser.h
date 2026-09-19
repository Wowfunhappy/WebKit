// Reads the frames of the ID3v2 tags HLS carries as timed metadata (MPEG-TS stream type 0x15), for the metadata
// text track HLSTimedMetadataGStreamer builds. Every read is bounded by the input; a fuzzing harness lives in
// MavericksSupport/tests/id3v2-frame-parser.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace WebCore {

// One frame of an ID3v2.3 or ID3v2.4 tag, in the shape AVFoundation gives an ID3 AVMetadataItem: the frame
// identifier as the key, a MIME type and other attributes (the description as "info", a GEOB file name as
// "name"), and the frame's value as UTF-8 text or as bytes.
struct ID3v2Frame {
    enum class ValueKind : uint8_t { None, Text, Bytes };

    std::string key;
    std::string type;
    std::vector<std::pair<std::string, std::string>> otherAttributes;
    ValueKind valueKind { ValueKind::None };
    std::string text;
    std::vector<uint8_t> bytes;
};

// Parses the frames of the ID3v2 tag at the start of data. Every read is bounded by size; malformed input
// yields the frames that parsed before it.
std::vector<ID3v2Frame> parseID3v2Frames(const uint8_t* data, size_t size);

} // namespace WebCore
