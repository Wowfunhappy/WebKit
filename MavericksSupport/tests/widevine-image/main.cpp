// Runs WebCore's Widevine work over one file, so each pass can be exercised against real bytes on
// this host: `image` prepares a Mach-O the way an installed module is prepared
// (Source/WebCore/platform/graphics/gstreamer/eme/WidevineCdmImage.cpp), and `archive` takes the
// module out of a CRX3 the way a downloaded one is opened (WidevineCdmArchive.mm). run.sh builds
// this and drives it.

#include "config.h"
#include "WidevineCdmArchive.h"
#include "WidevineCdmImage.h"
#include <stdio.h>
#include <string.h>
#include <wtf/FileSystem.h>
#include <wtf/MainThread.h>

int main(int argc, char** argv)
{
    if (argc < 4) {
        printf("usage: %s image <in.dylib> <out.dylib> <gap.dylib>\n"
               "       %s archive <in.crx3> <out.dylib>\n", argv[0], argv[0]);
        return 2;
    }
    WTF::initializeMainThread();

    bool isArchive = !strcmp(argv[1], "archive");
    auto input = FileSystem::readEntireFile(String::fromUTF8(argv[2]));
    if (!input) {
        printf("cannot read %s\n", argv[2]);
        return 1;
    }

    if (isArchive) {
        auto module = WebCore::extractWidevineCdmModule(input->span());
        if (!module) {
            printf("REFUSED: %s\n", module.error().utf8().data());
            return 1;
        }
        if (!FileSystem::overwriteEntireFile(String::fromUTF8(argv[3]), module->span())) {
            printf("cannot write %s\n", argv[3]);
            return 1;
        }
        printf("extracted %s (%zu bytes)\n", argv[3], module->size());
        return 0;
    }

    if (argc != 5) {
        printf("image takes <in.dylib> <out.dylib> <gap.dylib>\n");
        return 2;
    }
    auto prepared = WebCore::prepareWidevineCdmImage(*input, "@loader_path/libwidevinegap.dylib"_s, String::fromUTF8(argv[4]));
    if (!prepared) {
        printf("REFUSED: %s\n", prepared.error().utf8().data());
        return 1;
    }
    if (!FileSystem::overwriteEntireFile(String::fromUTF8(argv[3]), input->span())) {
        printf("cannot write %s\n", argv[3]);
        return 1;
    }
    printf("prepared %s (%zu bytes)\n", argv[3], input->size());
    return 0;
}
