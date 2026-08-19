# CMake toolchain file for building this WebKit fork with the in-tree clang-22 /
# macOS 10.9 (Mavericks) toolchain.
#
# Native build (host == target == x86_64-apple-darwin13 / 10.9), so we do NOT
# set CMAKE_SYSTEM_NAME -- doing so switches CMake into cross-compile mode and
# breaks discovery of the system OpenGL/OpenAL frameworks.
#
# REPRODUCIBILITY: every build input is resolved RELATIVE to this file's location
# (CMAKE_CURRENT_LIST_DIR == <repo>/MavericksSupport/cmake), never an absolute path, so a
# fresh clone builds anywhere for any user. The compiler lives in-tree:
# toolchain/vendor/clang holds the committed binaries (clang/lld bzip2-compressed),
# and toolchain/bootstrap.sh assembles the usable toolchain at toolchain/build/clang
# and builds nasm/python3/cmake/ninja from source there. The macOS SDK is the ONE
# external input: it is NOT
# redistributable, so it is expected as a sibling of the checkout
# (<repo>/../MacOSX26.1.sdk). Override any of these with the MAVERICKS_* env vars.
#   cmake -DCMAKE_TOOLCHAIN_FILE=MavericksSupport/cmake/mac10.9-toolchain.cmake ...

# --- clang-22 toolchain (in-tree) ---------------------------------------------
if (DEFINED ENV{MAVERICKS_CLANG})
    set(_TC "$ENV{MAVERICKS_CLANG}")
else ()
    get_filename_component(_TC "${CMAKE_CURRENT_LIST_DIR}/../toolchain/build/clang" ABSOLUTE)
endif ()
if (NOT EXISTS "${_TC}/bin/clang-22")
    message(FATAL_ERROR
        "clang not found at ${_TC}/bin/clang-22 -- run MavericksSupport/toolchain/bootstrap.sh "
        "first (it assembles toolchain/build/ from toolchain/vendor/: bzip2-decompresses the "
        "compiler and builds the helper tools).")
endif ()

set(CMAKE_C_COMPILER   ${_TC}/bin/clang)
set(CMAKE_CXX_COMPILER ${_TC}/bin/clang++)

# --- ccache (in-tree) ---------------------------------------------------------
# Launch the compiler through the in-tree ccache so incremental AND reconfigured
# builds reuse the object cache. Wiring this in the TOOLCHAIN (not just leaving it
# as a CMakeCache launcher var) is deliberate: a `cmake --fresh` or fresh clone
# wipes cache-only launchers, after which the build silently compiles with raw
# clang and caches NOTHING (0 hits, cache never grows) until someone notices. The
# compiler stays the real clang above; ccache masquerades via CMAKE_*_LAUNCHER.
# build.sh pins CCACHE_DIR to WebKitBuild/ccache; ccache reads it from the env at
# compile time. Override _CCACHE with MAVERICKS_CCACHE (set it empty to disable).
if (DEFINED ENV{MAVERICKS_CCACHE})
    set(_CCACHE "$ENV{MAVERICKS_CCACHE}")
else ()
    get_filename_component(_CCACHE "${CMAKE_CURRENT_LIST_DIR}/../toolchain/build/ccache/bin/ccache" ABSOLUTE)
endif ()
if (_CCACHE AND EXISTS "${_CCACHE}")
    set(CMAKE_C_COMPILER_LAUNCHER   "${_CCACHE}" CACHE FILEPATH "ccache compiler launcher")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${_CCACHE}" CACHE FILEPATH "ccache compiler launcher")
endif ()

set(CMAKE_AR      ${_TC}/bin/llvm-ar      CACHE FILEPATH "")
set(CMAKE_RANLIB  ${_TC}/bin/llvm-ranlib  CACHE FILEPATH "")
set(CMAKE_LINKER  ${_TC}/bin/ld64.lld     CACHE FILEPATH "")
set(CMAKE_NM      ${_TC}/bin/llvm-nm      CACHE FILEPATH "")

# --- nasm (in-tree, built by toolchain/scripts/build_nasm.sh) -----------------
# libwebrtc/libvpx assemble x86 .asm via nasm (macho64). The system CommandLineTools
# nasm is ancient (no macho64, no -MD); use the modern nasm built into the toolchain.
get_filename_component(_NASM "${CMAKE_CURRENT_LIST_DIR}/../toolchain/build/nasm/bin/nasm" ABSOLUTE)
if (DEFINED ENV{MAVERICKS_NASM})
    set(_NASM "$ENV{MAVERICKS_NASM}")
endif ()
if (EXISTS "${_NASM}")
    set(CMAKE_ASM_NASM_COMPILER "${_NASM}" CACHE FILEPATH "")
endif ()

# --- macOS SDK (external sibling of the checkout; NOT redistributable) ---------
# Build against a modern SDK (declares post-10.9 APIs) but deploy to 10.9, so the
# binaries bind against 10.9's real frameworks at runtime.
if (DEFINED ENV{MAVERICKS_SDK})
    set(_SDK "$ENV{MAVERICKS_SDK}")
else ()
    get_filename_component(_SDK "${CMAKE_CURRENT_LIST_DIR}/../../../MacOSX26.1.sdk" ABSOLUTE)
endif ()
if (NOT EXISTS "${_SDK}/SDKSettings.plist")
    message(FATAL_ERROR
        "macOS SDK not found at ${_SDK}. It is Apple-proprietary and not shipped in this repo; "
        "place a MacOSX26.1.sdk next to the checkout (a sibling directory) or set MAVERICKS_SDK.")
endif ()
set(CMAKE_OSX_DEPLOYMENT_TARGET "10.9" CACHE STRING "")
set(CMAKE_OSX_SYSROOT "${_SDK}" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "")

# --- python3 (in-tree, built by toolchain/scripts/build_python3.sh) -----------
# WebKit's build-time code generators need python3 (the 10.9 system only has 2.7).
if (DEFINED ENV{MAVERICKS_PYTHON3})
    set(_PY3 "$ENV{MAVERICKS_PYTHON3}")
else ()
    get_filename_component(_PY3 "${CMAKE_CURRENT_LIST_DIR}/../toolchain/build/python3/bin/python3" ABSOLUTE)
endif ()
set(Python_EXECUTABLE  "${_PY3}" CACHE FILEPATH "")
set(Python3_EXECUTABLE "${_PY3}" CACHE FILEPATH "")
set(PYTHON_EXECUTABLE  "${_PY3}" CACHE FILEPATH "")

# --- RTTI ---------------------------------------------------------------------
# WebKit builds without RTTI; the CMake port spells that only for CXX, leaving ObjC++
# with RTTI on. A .mm then references C++ typeinfos that the -fno-rtti .cpp definitions
# never emit, and every WebKit process aborts at dyld load on the undefined symbols.
set(CMAKE_OBJCXX_FLAGS "-fno-rtti" CACHE STRING "" FORCE)
