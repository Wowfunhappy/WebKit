# CMake toolchain file for building this WebKit fork with the clang-22 /
# macOS 10.9 (Mavericks) toolchain.
#
# Native build (host == target == x86_64-apple-darwin13 / 10.9), so we do NOT
# set CMAKE_SYSTEM_NAME -- doing so switches CMake into cross-compile mode and
# breaks discovery of the system OpenGL/OpenAL frameworks.
#
# The clang-22 wrapper auto-includes the 10.9 compat header and links the
# polyfill + MacPorts legacy-support archives (see its clang.cfg/clang++.cfg),
# so nothing extra is needed here for those.
#
# The toolchain location defaults to where it currently lives on the VM but can
# be overridden with the MAVERICKS_CLANG environment variable.
#   cmake -DCMAKE_TOOLCHAIN_FILE=MavericksSupport/mac10.9-toolchain.cmake ...

if (DEFINED ENV{MAVERICKS_CLANG})
    set(_TC "$ENV{MAVERICKS_CLANG}")
else ()
    set(_TC /Users/jonathan/Desktop/Compilers/toolchains/clang-22)
endif ()

set(CMAKE_C_COMPILER   ${_TC}/bin/clang)
set(CMAKE_CXX_COMPILER ${_TC}/bin/clang++)

set(CMAKE_AR      ${_TC}/bin/llvm-ar      CACHE FILEPATH "")
set(CMAKE_RANLIB  ${_TC}/bin/llvm-ranlib  CACHE FILEPATH "")
set(CMAKE_LINKER  ${_TC}/bin/ld.lld       CACHE FILEPATH "")
set(CMAKE_NM      ${_TC}/bin/llvm-nm      CACHE FILEPATH "")

set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9" CACHE STRING "")
set(CMAKE_OSX_SYSROOT ""  CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "")
