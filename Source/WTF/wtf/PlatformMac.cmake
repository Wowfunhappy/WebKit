find_library(COCOA_LIBRARY Cocoa)
find_library(COREFOUNDATION_LIBRARY CoreFoundation)
find_library(READLINE_LIBRARY Readline)
find_library(SECURITY_LIBRARY Security)
list(APPEND WTF_LIBRARIES
    ${COREFOUNDATION_LIBRARY}
    ${COCOA_LIBRARY}
    ${READLINE_LIBRARY}
    ${SECURITY_LIBRARY}
)

list(APPEND WTF_SOURCES
    BlockObjCExceptions.mm
    # MAVERICKS_BACKPORT: build ObjCRuntimeExtras.mm here (not in upstream's Mac WTF source list).
ObjCRuntimeExtras.mm
    ProcessPrivilege.cpp
    TranslatedProcess.cpp

    cf/CFURLExtras.cpp
    cf/FileSystemCF.cpp
    cf/LanguageCF.cpp
    cf/RunLoopCF.cpp
    cf/SchedulePairCF.cpp
    cf/URLCF.cpp

    cocoa/AutodrainedPool.cpp
    cocoa/CrashReporter.cpp
    cocoa/Entitlements.mm
    cocoa/FileSystemCocoa.mm
    cocoa/LanguageCocoa.mm
    cocoa/LoggingCocoa.mm
    cocoa/MachSendRight.cpp
    cocoa/MainThreadCocoa.mm
    cocoa/MemoryFootprintCocoa.cpp
    cocoa/MemoryPressureHandlerCocoa.mm
    cocoa/NSURLExtras.mm
    cocoa/ResourceUsageCocoa.cpp
    # MAVERICKS_BACKPORT: .mm (not upstream's .cpp) — this file is built as Objective-C++ here.
    cocoa/RuntimeApplicationChecksCocoa.mm
    cocoa/SchedulePairCocoa.mm
    # MAVERICKS_BACKPORT: absent from upstream WTF cmake list; defines WTF::dispatch_data_apply_span
    # (a wrapper over the 10.9-available dispatch_data_apply) used by WebKit NetworkCache/NetworkRTC.
    cocoa/SpanCocoa.mm
    cocoa/SystemTracingCocoa.cpp
    cocoa/URLCocoa.mm
    # MAVERICKS_BACKPORT: absent from upstream WTF cmake list; defines WTF::UUID::createNSUUID/fromNSUUID
    # used by WebKit (WebPushMessage, model element, etc.).
    cocoa/UUIDCocoa.mm
    cocoa/WorkQueueCocoa.cpp

    darwin/LibraryPathDiagnostics.mm

    mac/FileSystemMac.mm

    posix/CPUTimePOSIX.cpp
    posix/FileHandlePOSIX.cpp
    posix/FileSystemPOSIX.cpp
    posix/MappedFileDataPOSIX.cpp
    posix/OSAllocatorPOSIX.cpp
    posix/ThreadingPOSIX.cpp

    text/cf/AtomStringImplCF.cpp
    text/cf/StringCF.cpp
    text/cf/StringImplCF.cpp
    text/cf/StringViewCF.cpp

    text/cocoa/ASCIILiteralCocoa.mm
    text/cocoa/ContextualizedCFString.mm
    text/cocoa/ContextualizedNSString.mm
    text/cocoa/StringCocoa.mm
    text/cocoa/StringImplCocoa.mm
    text/cocoa/StringViewCocoa.mm
    text/cocoa/TextBreakIteratorInternalICUCocoa.cpp
)

list(APPEND WTF_PUBLIC_HEADERS
    cf/CFTypeTraits.h
    cf/CFURLExtras.h
    cf/NotificationCenterCF.h
    cf/TypeCastsCF.h
    cf/VectorCF.h

    cocoa/CrashReporter.h
    cocoa/Entitlements.h
    cocoa/NSURLExtras.h
    cocoa/RuntimeApplicationChecksCocoa.h
    cocoa/SoftLinking.h
    cocoa/TollFreeBridging.h
    cocoa/TypeCastsCocoa.h
    cocoa/VectorCocoa.h

    darwin/OSLogPrintStream.h
    darwin/WeakLinking.h
    darwin/XPCExtras.h

    spi/cf/CFBundleSPI.h
    spi/cf/CFStringSPI.h

    spi/cocoa/CFXPCBridgeSPI.h
    spi/cocoa/CrashReporterClientSPI.h
    spi/cocoa/IOSurfaceSPI.h
    spi/cocoa/MachVMSPI.h
    spi/cocoa/NSLocaleSPI.h
    spi/cocoa/NSObjCRuntimeSPI.h
    spi/cocoa/SecuritySPI.h
    spi/cocoa/objcSPI.h

    spi/darwin/ReasonSPI.h
    spi/darwin/CodeSignSPI.h
    spi/darwin/DataVaultSPI.h
    spi/darwin/MemoryStatusSPI.h
    spi/darwin/OSVariantSPI.h
    spi/darwin/ProcessMemoryFootprint.h
    spi/darwin/SandboxSPI.h
    spi/darwin/XPCSPI.h
    spi/darwin/dyldSPI.h

    spi/mac/MetadataSPI.h

    text/cf/StringConcatenateCF.h
    text/cf/TextBreakIteratorCF.h
)

file(COPY mac/MachExceptions.defs DESTINATION ${WTF_DERIVED_SOURCES_DIR})

add_custom_command(
    OUTPUT
        ${WTF_DERIVED_SOURCES_DIR}/MachExceptionsServer.h
        ${WTF_DERIVED_SOURCES_DIR}/mach_exc.h
        ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
        ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
    MAIN_DEPENDENCY mac/MachExceptions.defs
    WORKING_DIRECTORY ${WTF_DERIVED_SOURCES_DIR}
    COMMAND mig -DMACH_EXC_SERVER_TASKIDTOKEN_STATE -sheader MachExceptionsServer.h MachExceptions.defs
    VERBATIM)
list(APPEND WTF_SOURCES
    ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
    ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
)

# MAVERICKS_BACKPORT: WTF GLib HELPER layer needed by the upstream GStreamer media player. Only the
# smart-pointer / type helpers (GRefPtr/GMallocString/GSpanExtras + header-only GUniquePtr/WTFGType/…),
# NOT the GLib platform replacements (RunLoopGLib/FileSystemGlib/URLGLib), which would collide with the
# Cocoa run loop and file system. glib headers come from MavericksSupport/deps/build.
if (USE_GLIB)
    list(APPEND WTF_SOURCES
        glib/GMallocString.cpp
        glib/GRefPtr.cpp
        glib/GSpanExtras.cpp
    )
    list(APPEND WTF_PUBLIC_HEADERS
        glib/GMallocString.h
        glib/GMutexLocker.h
        glib/GRefPtr.h
        glib/GSpanExtras.h
        glib/GThreadSafeWeakPtr.h
        glib/GTypedefs.h
        glib/GUniquePtr.h
        glib/GWeakPtr.h
        glib/RunLoopSourcePriority.h
        glib/WTFGType.h
    )
    list(APPEND WTF_SYSTEM_INCLUDE_DIRECTORIES
        "${MAVERICKS_DEPS}/include/glib-2.0"
        "${MAVERICKS_DEPS}/lib/glib-2.0/include"
        "${MAVERICKS_DEPS}/include/gio-unix-2.0"
    )
    list(APPEND WTF_LIBRARIES GLib::GLib GLib::Object GLib::Gio)
endif ()
