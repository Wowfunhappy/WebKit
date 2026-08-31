list(APPEND ImageDiff_SOURCES
    cg/PlatformImageCG.cpp
)

list(APPEND ImageDiff_LIBRARIES
    Apple::CoreFoundation
    Apple::CoreGraphics
    Apple::CoreText
    # MAVERICKS_BACKPORT: PlatformImageCG.cpp reads/writes PNGs via ImageIO (CGImageSource/CGImageDestination);
    # the upstream CMake list omits it (the Apple build gets it from the CoreGraphics umbrella's module map).
    Apple::ImageIO
)
