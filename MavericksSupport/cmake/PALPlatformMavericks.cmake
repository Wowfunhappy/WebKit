# MAVERICKS_BACKPORT: PAL entries this port adds on top of upstream's Mac list. They live here,
# out of tree, so Source/WebCore/PAL/pal/PlatformMac.cmake stays byte-identical to upstream — the
# same arrangement the polyfill layer uses for code, and the one PlatformMac.cmake already uses for
# WebCore and WebKit (see MavericksSupport/cmake/WebCorePlatformMavericks.cmake).
#
# Appending rather than interleaving is safe here: PAL is built by WEBKIT_FRAMEWORK from a plain
# set(PAL_SOURCES ...) and never goes through WEBKIT_COMPUTE_SOURCES, so every source compiles as its
# own translation unit and list order carries no meaning. Header and include-directory order likewise
# does not.

# WebCrypto runs on libgcrypt here (USE_GCRYPT), so the CommonCrypto digest is not built — it needs
# Apple Swift CryptoKit symbols and CCECCryptor SPI that 10.9 does not ship. Dropping it from the list
# rather than editing upstream's is what lets PlatformMac.cmake stay byte-identical; the gcrypt
# replacement is appended below.
list(REMOVE_ITEM PAL_SOURCES
    crypto/commoncrypto/CryptoDigestCommonCrypto.mm
)

# PALSwift.h has to be installed for WebCore to compile: crypto/keys/CryptoKeyEC.cpp (Sources.txt:871,
# built inside a unified bundle) includes <pal/PALSwift.h> under `#if OS(DARWIN) && !PLATFORM(GTK)`,
# which holds here. Upstream's Mac build installs it as a side effect of the Swift CryptoKit shim
# target, which this port does not build, so the port has to name it directly.
#
# It is listed here rather than in upstream's PAL/pal/CMakeLists.txt, and the consumer above is the
# REAL one: the previous in-tree entry justified itself by "CryptoDigestCommonCrypto.cpp can include
# it" and called the header hand-written. Both were false — that .cpp is not built (gcrypt replaces
# it) and PALSwift.h is byte-identical to upstream. The entry survived only because the wrong reason
# happened to sit next to a real need.
list(APPEND PAL_PUBLIC_HEADERS
    PALSwift.h
)

list(APPEND PAL_PUBLIC_HEADERS
    crypto/gcrypt/Handle.h
    crypto/gcrypt/Initialization.h
    crypto/gcrypt/Utilities.h
    crypto/tasn1/Utilities.h
    cf/CoreAudioExtras.h
    cocoa/AVFAudioSoftLink.h
    cocoa/AccessibilitySoftLink.h
    cocoa/ContactsSoftLink.h
    cocoa/EnhancedSecurityCocoa.h
    cocoa/LockdownModeCocoa.h
    cocoa/WebContentAnalysisSoftLink.h
    cocoa/WebContentRestrictionsSoftLink.h
    mac/ScreenCaptureKitSoftLink.h
    spi/cf/VideoToolboxSPI.h
    spi/cocoa/ARKitSPI.h
    spi/cocoa/AVStreamDataParserSPI.h
    spi/cocoa/AudioToolboxCoreSPI.h
    spi/cocoa/ContactsSPI.h
    spi/cocoa/CoreCryptoSPI.h
    spi/cocoa/CoreMotionSPI.h
    spi/cocoa/FoundationSPI.h
    spi/cocoa/NSKeyedUnarchiverSPI.h
    spi/cocoa/TranslationUIServicesSPI.h
    spi/cocoa/UIFoundationSPI.h
    spi/cocoa/UniformTypeIdentifiersSPI.h
    spi/cocoa/WebContentRestrictionsSPI.h
    spi/cocoa/WebPrivacySPI.h
    spi/cocoa/WritingToolsSPI.h
    spi/cocoa/WritingToolsUISPI.h
    spi/ios/AXRuntimeSPI.h
    spi/ios/BarcodeSupportSPI.h
    spi/ios/BrowserEngineKitSPI.h
    spi/ios/CelestialSPI.h
    spi/ios/CoreUISPI.h
    spi/ios/DataDetectorsUISoftLink.h
    spi/ios/IOKitSPIIOS.h
    spi/ios/ManagedConfigurationSPI.h
    spi/ios/MediaPlayerSPI.h
    spi/ios/MobileGestaltSPI.h
    spi/ios/MobileKeyBagSPI.h
    spi/ios/OpenGLESSPI.h
    spi/ios/QuickLookSPI.h
    spi/ios/SBSStatusBarSPI.h
    spi/ios/SystemPreviewSPI.h
    spi/ios/UIKitSPI.h
    spi/mac/NSSearchFieldCellSPI.h
    spi/mac/NSTextFieldCellSPI.h
    spi/mac/PowerLogSPI.h
    spi/mac/QuarantineSPI.h
    ios/AVRoutingSoftLink.h
    ios/ManagedConfigurationSoftLink.h
    ios/QuickLookSoftLink.h
    ios/SystemStatusSoftLink.h
    ios/UIKitSoftLink.h
    system/ios/UserInterfaceIdiom.h
)

list(APPEND PAL_SOURCES
    cocoa/ContactsSoftLink.mm
    cocoa/EnhancedSecurityCocoa.mm
    cocoa/LockdownModeCocoa.mm
    cocoa/AccessibilitySoftLink.mm
    cocoa/VisionSoftLink.mm
    crypto/gcrypt/CryptoDigestGCrypt.cpp
    crypto/tasn1/Utilities.cpp
)

list(APPEND PAL_PRIVATE_INCLUDE_DIRECTORIES
    "${MAVERICKS_DEPS}/include"
)

