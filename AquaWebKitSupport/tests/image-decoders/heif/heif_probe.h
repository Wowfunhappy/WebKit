#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

struct HEIFProbeResult {
    bool ok { false };
    int width { 0 };
    int height { 0 };
    int hasAlpha { 0 };
    int premultiplied { 0 };
    int lumaBits { 0 };
    int isGrid { 0 };
    int transformed { 0 };
    uint32_t checksum { 0 };
    std::string profile;
    std::string itemTypes;
    std::string error;
};

HEIFProbeResult heif_probe_decode(const uint8_t* data, size_t size);
