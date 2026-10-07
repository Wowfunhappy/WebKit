#include "config.h"
#include <wtf/FileSystem.h>

#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

namespace WTF {
namespace FileSystemImpl {

// The Mach-O path of the running executable gives the name; getprogname() covers a path too long for the buffer.
CString currentExecutableName()
{
    char pathBuffer[PATH_MAX];
    uint32_t size = sizeof(pathBuffer);
    if (!_NSGetExecutablePath(pathBuffer, &size)) {
        if (const char* base = strrchr(pathBuffer, '/'))
            return CString(base + 1);
        return CString(pathBuffer);
    }
    return CString(getprogname());
}

} // namespace FileSystemImpl
} // namespace WTF
