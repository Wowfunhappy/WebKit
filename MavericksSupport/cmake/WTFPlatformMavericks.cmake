# The entries this port adds to / removes from upstream's list in
# Source/WTF/wtf/CMakeLists.txt. Keeping them here, out of tree, is what lets that file stay
# byte-identical to upstream -- the same arrangement the polyfill layer uses for code, and the one
# already used for WebCore and WebKit (see WebCorePlatformMavericks.cmake).

list(REMOVE_ITEM WTF_PUBLIC_HEADERS
    spi/darwin/ReasonSPI.h
)

# Headers added to WTF_PUBLIC_HEADERS so they are installed for the 10.9 build.
list(APPEND WTF_PUBLIC_HEADERS
    MachSendRightAnnotated.h
    SequenceLocked.h
    SwiftCXXThunk.h
    cf/CFTypeTraits.h
    cocoa/AuditToken.h
    cocoa/NSStringExtras.h
    cocoa/SpanCocoa.h
    darwin/LibraryPathDiagnostics.h
    darwin/TypeCastsOSObject.h
    darwin/XPCObjectPtr.h
    spi/cf/CFPrivSPI.h
    spi/cf/CFRunLoopSPI.h
    spi/cocoa/BOMSPI.h
    spi/cocoa/IOReturnSPI.h
    spi/cocoa/IOTypesSPI.h
    spi/cocoa/OSLogSPI.h
    spi/cocoa/XTSPI.h
    spi/darwin/DispatchSPI.h
    spi/darwin/MemoryStatusSPI.h
    spi/darwin/ReasonSPI.h # alphabetized into this position (moved from above CodeSignSPI.h in the base commit).
    text/cf/TextBreakIteratorCFCharacterCluster.h
    text/cf/TextBreakIteratorCFStringTokenizer.h
    text/cocoa/ContextualizedCFString.h
    text/cocoa/ContextualizedNSString.h
    posix/SocketPOSIX.h
    unix/UnixFileDescriptor.h
)

# Sources added to and swapped in upstream's Mac list (Source/WTF/wtf/PlatformMac.cmake), which
# WEBKIT_INCLUDE_CONFIG_FILES_IF_EXISTS pulls in just above this include.
list(REMOVE_ITEM WTF_SOURCES
    # Built as Objective-C++ here; the tree carries the .mm, not upstream's .cpp.
    cocoa/RuntimeApplicationChecksCocoa.cpp
)

list(APPEND WTF_SOURCES
    ObjCRuntimeExtras.mm
    cocoa/RuntimeApplicationChecksCocoa.mm
    # WTF::dispatch_data_apply_span, a wrapper over the 10.9-available dispatch_data_apply used by
    # WebKit's NetworkCache and NetworkRTC.
    cocoa/SpanCocoa.mm
    # WTF::UUID::createNSUUID/fromNSUUID, used by WebKit (WebPushMessage, model element).
    cocoa/UUIDCocoa.mm
)

# The WTF GLib HELPER layer the upstream GStreamer media player needs. Only the smart-pointer / type
# helpers (GRefPtr/GMallocString/GSpanExtras + header-only GUniquePtr/WTFGType/...), not the GLib
# platform replacements (RunLoopGLib/FileSystemGlib/URLGLib), which would collide with the Cocoa run
# loop and file system. glib headers come from MavericksSupport/deps/build.
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
