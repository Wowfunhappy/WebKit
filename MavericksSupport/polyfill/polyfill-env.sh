# Compiler paths and flag sets shared by the polyfill builder and behaviour tests.
POLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$POLY/../.." && pwd)"
TC="${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}"
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"
CLANG="$TC/bin/clang"
CLANGXX="$TC/bin/clang++"
AR="$TC/bin/llvm-ar"

PF="$POLY/polyfills"
MECH="$POLY/mechanism"
OUT="$POLY/build"

WARN='-Wall -Wextra -Wno-unused-command-line-argument -Werror=unguarded-availability -Werror=unguarded-availability-new'
INC="-I$MECH"
HOST="--no-default-config -mmacosx-version-min=10.9 -O2 $WARN"
MODERN="--no-default-config -isysroot $SDK -mmacosx-version-min=10.9 -O2 -Wno-deprecated-declarations $WARN"
HIDDEN='-fvisibility=hidden'
BLOCKCF='-Wno-objc-designated-initializers'
MINC="$INC -I$PF/c"

methods_unitinc() {
    case "$(basename "$1")" in
        Foundation.m) echo "$MINC -I$REPO/MavericksSupport/deps/build/include -DU_DISABLE_RENAMING=1" ;;
        CryptoKitPrivate.m) echo "$MINC -I$REPO/MavericksSupport/deps/build/include" ;;
        *) echo "$MINC" ;;
    esac
}
