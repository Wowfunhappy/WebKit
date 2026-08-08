# MAVERICKS_BACKPORT: the entries this port adds to / removes from upstream's list in
# Source/WTF/wtf/CMakeLists.txt. Keeping them here, out of tree, is what lets that file stay
# byte-identical to upstream -- the same arrangement the polyfill layer uses for code, and the one
# already used for WebCore and WebKit (see WebCorePlatformMavericks.cmake).

list(REMOVE_ITEM WTF_PUBLIC_HEADERS
    spi/darwin/ReasonSPI.h
)

list(APPEND WTF_PUBLIC_HEADERS
    MachSendRightAnnotated.h
    SequenceLocked.h
    SwiftCXXThunk.h
    cf/CFTypeTraits.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    cocoa/AuditToken.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    cocoa/NSStringExtras.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    cocoa/SpanCocoa.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    darwin/LibraryPathDiagnostics.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    darwin/TypeCastsOSObject.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    darwin/XPCObjectPtr.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/cf/CFPrivSPI.h
    spi/cf/CFRunLoopSPI.h
    spi/cocoa/BOMSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/cocoa/IOReturnSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/cocoa/IOTypesSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/cocoa/OSLogSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/cocoa/XTSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/darwin/DispatchSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/darwin/MemoryStatusSPI.h # MAVERICKS_BACKPORT: missing from the base commit's WTF_PUBLIC_HEADERS list; restored so it is installed for the 10.9 build.
    spi/darwin/ReasonSPI.h # MAVERICKS_BACKPORT: alphabetized into this position (moved from above CodeSignSPI.h in the base commit).
    text/cf/TextBreakIteratorCFCharacterCluster.h
    text/cf/TextBreakIteratorCFStringTokenizer.h
    text/cocoa/ContextualizedCFString.h
    text/cocoa/ContextualizedNSString.h
    posix/SocketPOSIX.h
    unix/UnixFileDescriptor.h
)

