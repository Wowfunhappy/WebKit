#!/bin/bash
# Build the Mavericks WebKit backport: polyfill archives, ninja (configuring first if the build dir is
# new), staging into WebKitBuild/Release/staged, then the post-build audits. Everything logs to
# /tmp/wk_build.log. "REBUILD DONE (rc=0)" is printed once, at the very end, and is the signal that the
# staged product is complete and installable (sudo bash MavericksSupport/install.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/MavericksSupport/toolchain/build"
NINJA="$TC/ninja/bin/ninja"
CMAKE="$TC/cmake/bin/cmake"
CCACHE="${MAVERICKS_CCACHE:-$TC/ccache/bin/ccache}"   # the same resolution as cmake/mac10.9-toolchain.cmake
BUILD="$ROOT/WebKitBuild/Release"
LOG=/tmp/wk_build.log

# --- What this build links against ------------------------------------------------------------
# deps/build_deps.sh replaces deps/build/{include,lib,bin} wholesale when it finishes, and every
# link below reads from there. It force-loads the polyfill's shared/ sources into the whole media
# runtime as well, and nothing here relinks that: an edit to one of them parts those dylibs from the
# copy libpolyfill.a gives the frameworks. The audit at the end proves that over the staged product;
# the source half below reads only the sources and the deps build's manifest.
DEPS_LOCK="$ROOT/MavericksSupport/deps/.build-tree/.lock"
DEPS_PID="$(cat "$DEPS_LOCK/pid" 2>/dev/null || true)"
if [ -n "$DEPS_PID" ] && kill -0 "$DEPS_PID" 2>/dev/null; then
    echo "==================== A DEPS BUILD IS RUNNING — ABORTING ===================="
    echo "### $DEPS_LOCK is held by pid $DEPS_PID; rerun when it is done."
    exit 1
fi
echo "### gap archive currency (MavericksSupport/scripts/check-gap-archive-current.sh --sources-only)"
if ! bash "$ROOT/MavericksSupport/scripts/check-gap-archive-current.sh" --sources-only; then
    echo "==================== GAP SOURCES ARE AHEAD OF THE DEPS BUILD — ABORTING ===================="
    exit 1
fi

# --- Take over from an in-flight build --------------------------------------------------------
# One build dir, one log, one build at a time. A running cmake configure is waited out (it rewrites
# build.ninja in place, and a half-written manifest kills every later build); ninja, the polyfill
# compile and staging are interruptible, so they are stopped with SIGTERM, parent first.
_ancestry() { local _p="$1"; while [ "${_p:-0}" -gt 1 ] 2>/dev/null; do echo "$_p"; _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' '); done; }
_family()   { local _c; echo "$1"; for _c in $(pgrep -P "$1" 2>/dev/null); do _family "$_c"; done; }
_is_ours()  { local _a; for _a in $(_ancestry "$1"); do [ "$_a" = "$$" ] && return 0; done
              for _a in $(_ancestry $$); do [ "$_a" = "$1" ] && return 0; done; return 1; }
# Only THIS script counts as a build to take over: the candidate's build.sh argument, resolved against its
# cwd, must be this file (the tree has other build.sh scripts, and so may the machine). This script never
# changes directory, so a running instance's cwd is the one it was launched from.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/build.sh"
_script_of() {
    local _tok _cwd
    _tok=$(ps -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | grep -E '(^|/)build\.sh$' | head -1)
    [ -n "$_tok" ] || return 1
    case "$_tok" in
        /*) ;;
        *)  _cwd=$(lsof -a -d cwd -Fn -p "$1" 2>/dev/null | sed -n 's/^n//p' | head -1); _tok="$_cwd/$_tok";;
    esac
    (cd "$(dirname "$_tok")" 2>/dev/null && echo "$(pwd -P)/$(basename "$_tok")")
}
# Candidates come from ps -axo pid=,command=, which lists every process with its full command line.
# _pids_running takes those whose program is <name>; _pids_running_script those whose command ends in
# a build.sh, which _script_of below holds to this file.
_pids_running() { ps -axo pid=,command= | awk -v n="$1" '{ p = $2; sub(/.*\//, "", p); if (p == n) print $1 }'; }
_pids_running_script() { ps -axo pid=,command= | awk '$0 !~ / -c / && $NF ~ /(^|\/)build\.sh$/ { print $1 }'; }
_stale_builds() {
    local _p
    for _p in $(_pids_running_script); do
        _is_ours "$_p" && continue
        [ "$(_script_of "$_p")" = "$SELF" ] && echo "$_p"
    done
    # A ninja is this build's only when it runs in $BUILD (ninja -C chdirs there); deps/build_deps.sh's
    # meson builds and other trees run their own.
    for _p in $(_pids_running ninja); do
        _is_ours "$_p" && continue
        [ -n "$BUILD_P" ] && [ "$(lsof -a -d cwd -Fn -p "$_p" 2>/dev/null | sed -n 's/^n//p' | head -1)" = "$BUILD_P" ] && echo "$_p"
    done
}
BUILD_P="$(cd "$BUILD" 2>/dev/null && pwd -P)"
# A configure of THIS tree: cmake itself, naming $BUILD. The `cmake -E <tool>` helpers and `-P` install
# steps ninja runs inside build steps are not configures, and other trees' configures (deps/build_deps.sh)
# are not this build's.
_configuring() {
    local _p
    for _p in $(_pids_running cmake); do
        case "$(ps -o command= -p "$_p" 2>/dev/null)" in
            *" -E "*|*" -P "*) ;;
            *"$BUILD"*) return 0;;
            *"$BUILD_P"*) [ -n "$BUILD_P" ] && return 0;;
        esac
    done
    return 1
}
_waited=0; _tries=0; _stopped=""; TAKEOVER=""
while :; do
    _stale="$(_stale_builds | sort -un)"
    [ -n "$_stale" ] || break
    if [ -z "$_stopped" ]; then
        echo "### a build is already running (pids: $(echo $_stale)) -> stopping it first"
        _stopped="$(echo $_stale)"
    fi
    if _configuring && [ "$_waited" -lt 1200 ]; then
        [ $((_waited % 30)) = 0 ] && echo "###   cmake configure in flight — waiting it out (${_waited}s)"
        sleep 5; _waited=$((_waited + 5)); continue
    fi
    for _p in $_stale; do kill $(_family "$_p") 2>/dev/null; done
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 30 ]; then
        echo "==================== COULD NOT STOP THE RUNNING BUILD (pids: $(echo $_stale)) — ABORTING ===================="
        exit 1
    fi
    sleep 2
done
if [ -n "$_stopped" ]; then
    echo "###   in-flight build stopped"
    TAKEOVER="### took over from the build already running (pids: $_stopped)"
    [ "$_waited" -gt 0 ] && TAKEOVER="$TAKEOVER, after waiting ${_waited}s for its cmake configure"
fi
: > "$LOG"   # the one truncation of the run; everything below appends
[ -n "$TAKEOVER" ] && echo "$TAKEOVER"

# One ccache for every build of this checkout, and direct mode: WebKit regenerates DerivedSources
# headers with fresh timestamps every build, so trusting include content over mtime is what lets
# direct hits engage.
export CCACHE_DIR="$ROOT/WebKitBuild/ccache"
export CCACHE_SLOPPINESS="include_file_mtime,include_file_ctime,time_macros,pch_defines"

# --- Configure (fresh build dir) ---------------------------------------------------------------
CACHE_FILE="$BUILD/CMakeCache.txt"
if [ ! -f "$CACHE_FILE" ]; then
    echo "### no build dir -> configuring $BUILD"
    if ! "$CMAKE" -S "$ROOT" -B "$BUILD" -G Ninja \
            -DCMAKE_MAKE_PROGRAM="$NINJA" \
            -DCMAKE_TOOLCHAIN_FILE="$ROOT/MavericksSupport/cmake/mac10.9-toolchain.cmake" \
            -DPORT=Mac -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DCMAKE_NINJA_FORCE_RESPONSE_FILE=1 >> "$LOG" 2>&1; then
        echo "==================== CONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi

# --- Re-derive feature options when their defaults change -------------------------------------
# CMake's option() keeps an existing cache entry, so an edited WEBKIT_OPTION_DEFAULT_PORT_VALUE in an
# Options*.cmake is ignored by an incremental configure. When the option files' CONTENT changes (hashed,
# so a mere mtime bump from git does not fire it), every WebKit option's cache entry is unset with
# `cmake -U` and the configure re-applies the port defaults.
OPT_HASH_FILE="$BUILD/.wk-option-defaults.sha256"
_opt_files=$(ls "$ROOT"/Source/cmake/Options*.cmake "$ROOT"/Source/cmake/WebKitFeatures.cmake \
    "$ROOT"/MavericksSupport/cmake/OptionsMac*.cmake 2>/dev/null | sort)
_opt_hash=$(shasum -a 256 $_opt_files 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [ -f "$OPT_HASH_FILE" ] && [ "$_opt_hash" != "$(cat "$OPT_HASH_FILE")" ]; then
    _names=$(grep -rhoE 'WEBKIT_OPTION_(DEFINE|DEFAULT_PORT_VALUE)\([[:space:]]*[A-Z0-9_]+' $_opt_files 2>/dev/null \
        | grep -oE '[A-Z0-9_]+$' | sort -u)
    echo "### option file content changed -> re-deriving $(echo $_names | wc -w | tr -d ' ') feature options from port defaults"
    _uargs=""; for _n in $_names; do _uargs="$_uargs -U $_n"; done
    if ! "$CMAKE" $_uargs "$BUILD" >> "$LOG" 2>&1; then
        echo "==================== RECONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi
[ "$_opt_hash" = "$(cat "$OPT_HASH_FILE" 2>/dev/null)" ] || echo "$_opt_hash" > "$OPT_HASH_FILE"

# --- Polyfill archives (not in the ninja graph) ----------------------------------------------
# The archives are force-loaded through raw -Wl,-force_load flags ninja does not track, so they are
# rebuilt here every time and, when an archive's bytes change (llvm-ar is deterministic), the
# binaries that consume it are removed so ninja relinks them:
#   libpolyfill.a, libwk_marker.a  -> all four frameworks (WEBKIT_FRAMEWORK in WebKitMacros.cmake)
#   libpolyfill_methods.a          -> WebCore          libwtf_compat.a -> JavaScriptCore
#   libpolyfill_webkit.a           -> WebKit
POLY_OUT="$ROOT/MavericksSupport/polyfill/build"
poly_hash() { shasum -a 256 "$POLY_OUT/$1" 2>/dev/null | awk '{print $1}'; }
PRE_ALL="$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)"
PRE_WEBCORE="$(poly_hash libpolyfill_methods.a)"
PRE_JSC="$(poly_hash libwtf_compat.a)"
PRE_WEBKIT="$(poly_hash libpolyfill_webkit.a)"
echo "### building polyfill archives (MavericksSupport/polyfill/build-polyfill.sh)"
if bash "$ROOT/MavericksSupport/polyfill/build-polyfill.sh" > /tmp/wk_polyfill.log 2>&1; then
    RELINK=""
    if [ "$PRE_ALL" != "$(poly_hash libpolyfill.a)$(poly_hash libwk_marker.a)" ]; then
        RELINK="JavaScriptCore WebCore WebKit WebKitLegacy"
    else
        [ "$PRE_WEBCORE" != "$(poly_hash libpolyfill_methods.a)" ] && RELINK="$RELINK WebCore"
        [ "$PRE_JSC" != "$(poly_hash libwtf_compat.a)" ] && RELINK="$RELINK JavaScriptCore"
        [ "$PRE_WEBKIT" != "$(poly_hash libpolyfill_webkit.a)" ] && RELINK="$RELINK WebKit"
    fi
    if [ -n "$RELINK" ]; then
        echo "###   polyfill archives changed -> forcing relink:$RELINK"
        for fw in $RELINK; do rm -f "$BUILD/lib/$fw.framework/Versions/A/$fw"; done
    else
        echo "###   polyfill unchanged"
    fi
else
    # A stale archive would link a call site against an old selector map and crash at runtime.
    echo "==================== POLYFILL BUILD FAILED — ABORTING (would link a STALE polyfill) ===================="
    echo "### see /tmp/wk_polyfill.log:"
    grep -nE "error:|warning:.*wk_|undefined" /tmp/wk_polyfill.log | head -20
    tail -20 /tmp/wk_polyfill.log
    exit 1
fi

# --- Recover an unusable build.ninja ---------------------------------------------------------
# ninja regenerates build.ninja itself (its RERUN_CMAKE rule lists every CMake file), but only if it
# can parse the manifest it has. A configure that wrote an unparsable or truncated manifest leaves
# every later run dead at the same error; heal that with a plain reconfigure.
if [ ! -f "$BUILD/build.ninja" ] || ! "$NINJA" -C "$BUILD" -t targets >/dev/null 2>&1; then
    echo "### build.ninja is missing or does not parse -> reconfiguring to recover"
    if ! "$CMAKE" "$BUILD" >> "$LOG" 2>&1; then
        echo "==================== RECOVERY RECONFIGURE FAILED — ABORTING ===================="
        tail -20 "$LOG"; exit 1
    fi
fi

[ -x "$CCACHE" ] && "$CCACHE" -z >/dev/null   # per-build ccache stats

# -k 0: keep going after the first failure so a link stage surfaces ALL undefined symbols at once.
"$NINJA" -C "$BUILD" -k 0 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}

echo "==================== COMPILE/LINK PHASE DONE (rc=$RC) — staging still to run ===================="
echo "$(grep -oE '^\[[0-9]+/[0-9]+\]' "$LOG" | tail -1)  FAILED=$(grep -c '^FAILED:' "$LOG")"
echo "dups=$(grep -c 'duplicate symbol' "$LOG")  undefined=$(grep -c 'undefined symbol' "$LOG")"
echo "--- frameworks built (binary present = linked) ---"
for fw in JavaScriptCore WebCore WebKit WebKitLegacy; do
    [ -e "$BUILD/lib/$fw.framework/$fw" ] && echo "  LINKED  $fw" || echo "  ------  $fw  (no binary)"
done
echo "--- distinct undefined symbols (if any) ---"
grep 'undefined symbol' "$LOG" | sed -E 's/.*undefined symbol:? *//' | sort -u | head -40
echo "--- distinct error lines ---"
grep -E 'error:|file not found|FAILED:' "$LOG" | grep -vE 'warning:' | sed -E 's/^[0-9]+\.[0-9]+ //' | sort -u | head -40

# --- Staging + audits -------------------------------------------------------------------------
# stage-frameworks.sh turns the linked frameworks into the complete installable product under
# WebKitBuild/Release/staged; install.sh copies that tree onto the system. The audits need the FINAL
# binaries, which exist only once staging has run:
#   check-absent-references.sh  a reference to a symbol 10.9 lacks binds to 0 and faults on first use
#   check-sandbox-profiles.sh   a profile 10.9's sandbox cannot compile CRASH()es WebContent at launch
#   check-abi-gap.sh            every symbol Safari 7 binds from our frameworks must be exported
if [ "$RC" = 0 ]; then
    echo "==================== STAGING ===================="
    bash "$ROOT/MavericksSupport/scripts/stage-frameworks.sh" || RC=$?
else
    echo "### staging skipped: the link failed, so there is nothing complete to stage"
fi
for audit in scripts/check-absent-references.sh scripts/check-gap-archive-current.sh sandbox/scripts/check-sandbox-profiles.sh host-abi/check-abi-gap.sh; do
    [ "$RC" = 0 ] || break
    echo "### $audit"
    bash "$ROOT/MavericksSupport/$audit" || RC=$?
done

echo "==================== REBUILD DONE (rc=$RC) ===================="
if [ "$RC" = 0 ]; then
    echo "### the staged product is complete and installable: sudo bash MavericksSupport/install.sh"
else
    echo "### NOT installable — see the errors above"
fi
exit $RC
