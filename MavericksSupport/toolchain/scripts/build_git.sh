#!/bin/bash
# build_git.sh — build a modern git for working on this fork.
#
# The host's git is 1.9.5 (Apple Git-50.3, 2014). It predates the `ort` merge engine, the
# rename detection that engine brings, `git merge-tree`, and wire protocol v2, all of which
# an upstream WebKit merge leans on. WebKit itself does not need git to build; this is a
# developer tool, so it targets the 10.9 host directly rather than the modern SDK.
#
# Version: git 2.45.4 is the newest release that builds against 10.9's libcurl 7.30.0.
# 2.46 added an unguarded CURLOPT_PROXYHEADER (curl 7.37) to http.c's proxy-credential path,
# and 2.48 raised the documented floor to curl 7.61.0.
#
# Installs into the toolchain build tree (toolchain/build/git, gitignored). All paths are
# relative to this script -- no absolute/user-specific paths.
set -euo pipefail
LOG=/tmp/wk_build.log
# The one build log: this script routes its own output there, so a bare invocation fills it.
exec >> "$LOG" 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN="$(cd "$HERE/.." && pwd)"
CLANG="$TOOLCHAIN/build/clang"
PREFIX="${GIT_PREFIX_DIR:-$TOOLCHAIN/build/git}"
VERSION=2.45.4
export MACOSX_DEPLOYMENT_TARGET=10.9
WORK="$(mktemp -d -t git-build)"
trap 'rm -rf "$WORK"' EXIT

echo "### Downloading git ${VERSION}"
# kernel.org negotiates a TLS version 10.9's SecureTransport does not offer, so the source
# comes from GitHub. The tag archive carries no `version` file; GIT-VERSION-GEN's DEF_VER
# supplies the exact release number on a release tag.
curl -fsSL -o "$WORK/git.tar.gz" "https://codeload.github.com/git/git/tar.gz/refs/tags/v${VERSION}"
tar xzf "$WORK/git.tar.gz" -C "$WORK"

cd "$WORK/git-${VERSION}"
echo "### Patching"
# See the patch header: two FSEvents flag names the builtin FSMonitor's trace logging
# references are 10.10 additions, absent from 10.9's CoreServices headers.
patch -p1 < "$TOOLCHAIN/patches/git-fsevents-10.10-flags.patch"

# git is C and runs on the host, so it compiles against the host's own headers and links the
# host's own libraries -- `-isysroot /`, not the modern SDK. The SDK ships curl 8.7.1 headers
# and a libcurl.tbd to match; building the HTTP transport against those would bind symbols
# 10.9's libcurl 7.30 does not export, and git-remote-https would fail to load at runtime.
#
# RUNTIME_PREFIX makes git locate its exec path, templates and config relative to its own
# binary (via _NSGetExecutablePath), which keeps build/git relocatable like the rest of the
# toolchain. It requires the three dirs below to be spelled relative to the prefix.
MAKE_ARGS=(
    CC="$CLANG/bin/clang"
    CFLAGS="-O2 -isysroot /"
    LDFLAGS="-isysroot /"
    prefix="$PREFIX"
    gitexecdir=libexec/git-core
    template_dir=share/git-core/templates
    sysconfdir=etc
    RUNTIME_PREFIX=YesPlease
    CURL_CONFIG=/usr/bin/curl-config
    PERL_PATH=/usr/bin/perl
    SHELL_PATH=/bin/sh
    # Localization, the Tcl/Tk GUIs, and git-p4 pull in tools the host does not have. The two
    # remaining transports that would want them are gone with them: NO_OPENSSL drops imap-send's
    # direct TLS (the SDK carries no OpenSSL headers) and NO_EXPAT drops the obsolete dumb-HTTP
    # push. Fetch and push over https:// go through libcurl and are unaffected.
    NO_GETTEXT=1
    NO_TCLTK=1
    NO_PYTHON=1
    NO_OPENSSL=1
    NO_EXPAT=1
)

echo "### Building (prefix=$PREFIX)"
make -j"$(sysctl -n hw.ncpu)" "${MAKE_ARGS[@]}"
echo "### Installing"
make install "${MAKE_ARGS[@]}"

"$PREFIX/bin/git" --version
echo "### Verifying the HTTPS transport links 10.9's libcurl"
otool -L "$PREFIX/libexec/git-core/git-remote-http" | grep -q "/usr/lib/libcurl" \
    || { echo "FATAL: git-remote-http does not link the host libcurl"; exit 1; }
"$PREFIX/bin/git" ls-remote https://github.com/git/git.git HEAD > /dev/null \
    || { echo "FATAL: git cannot fetch over https"; exit 1; }
echo "### git OK -> $PREFIX/bin/git"
