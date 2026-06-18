# CMake toolchain file for building this WebKit fork with the clang-22 /
# macOS 10.9 (Mavericks) toolchain.
#
# Native build (host == target == x86_64-apple-darwin13 / 10.9), so we do NOT
# set CMAKE_SYSTEM_NAME -- doing so switches CMake into cross-compile mode and
# breaks discovery of the system OpenGL/OpenAL frameworks.
#
# The clang-22 wrapper (clang.cfg/clang++.cfg) provides libc++/libobjc and a few
# base frameworks only; it does NOT impose the MavericksLegacySupport include
# overlay or archive (those assume the 10.9 SDK and collide with a modern one).
# WebKit vendors the missing-on-10.9 implementations it needs under
# MavericksSupport/legacy-polyfills (wired in OptionsMac.cmake).
#
# Builds against a modern macOS SDK (which declares the post-10.9 APIs WebKit calls)
# with the deployment target pinned to 10.9, so the binary binds against 10.9's real
# frameworks at runtime. Override the SDK with MAVERICKS_SDK.
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

# 10.9 backport: libwebrtc/libvpx assemble x86 .asm via nasm (macho64). The
# system CommandLineTools nasm is ancient (no macho64, no -MD); use the modern
# nasm 2.16 built in-tree (MavericksSupport/build_nasm.sh). It supports macho64,
# GNU-style -MD/-MT depfiles, and @response-files (needed with
# CMAKE_NINJA_FORCE_RESPONSE_FILE), so no wrapper is required.
if (EXISTS /Users/jonathan/Desktop/Compilers/toolchains/tools/nasm/bin/nasm)
    set(CMAKE_ASM_NASM_COMPILER /Users/jonathan/Desktop/Compilers/toolchains/tools/nasm/bin/nasm CACHE FILEPATH "")
endif ()

# Build against a modern SDK (declares post-10.9 APIs) but deploy to 10.9.
if (DEFINED ENV{MAVERICKS_SDK})
    set(_SDK "$ENV{MAVERICKS_SDK}")
else ()
    set(_SDK /Users/jonathan/Desktop/MacOSX26.1.sdk)
endif ()
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9" CACHE STRING "")
set(CMAKE_OSX_SYSROOT "${_SDK}" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "")

# WebKit's build-time code generators need python3 (the 10.9 system only has
# 2.7). Built by MavericksSupport/build_python3.sh and installed to /usr/local.
# Pin both the new (Python_EXECUTABLE) and legacy (PYTHON_EXECUTABLE) variables.
if (DEFINED ENV{MAVERICKS_PYTHON3})
    set(_PY3 "$ENV{MAVERICKS_PYTHON3}")
else ()
    set(_PY3 /usr/local/bin/python3)
endif ()
set(Python_EXECUTABLE  "${_PY3}" CACHE FILEPATH "")
set(Python3_EXECUTABLE "${_PY3}" CACHE FILEPATH "")
set(PYTHON_EXECUTABLE  "${_PY3}" CACHE FILEPATH "")
