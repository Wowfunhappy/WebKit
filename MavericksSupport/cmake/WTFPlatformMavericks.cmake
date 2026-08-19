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

