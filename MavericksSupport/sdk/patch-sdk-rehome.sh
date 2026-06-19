#!/bin/bash
# patch-sdk-rehome.sh — re-home symbols the macOS 26.1 SDK declares in frameworks that, on the 10.9
# runtime, either (a) don't have them (they moved) or (b) we supply via the WebKit polyfill.
#
# Mechanism is REMOVAL: delete the named symbols from the SDK text-based stub(s) the linker reads, so
# the linker binds each to whatever OTHER image still offers it:
#   - URL-loading symbols removed from CFNetwork.tbd  -> bind to Foundation (where they live on 10.9).
#   - LaunchServices polyfill classes removed from CoreServices.tbd -> bind to our libpolyfill class
#     (force-loaded into JavaScriptCore), instead of the absent system class.
# Keeps two-level namespace intact (NOT -flat_namespace); correct for a 10.9 deployment.
#
# IMPORTANT: each framework has TWO tbds (top-level <F>.tbd and Versions/A/<F>.tbd); the linker reads
# the top-level for an explicit `-framework F` and Versions/A via a re-export chain — patch BOTH.
# Idempotent + reversible (*.pre-rehome-bak). Re-run whenever the SDK is re-extracted.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"                   # repo root
SDK="${MAVERICKS_SDK:-$(dirname "$REPO")/MacOSX26.1.sdk}"   # SDK is a sibling of the repo

remove_syms() {  # $1 = symbol-list file; $2.. = tbd files
    local syms="$1"; shift
    [ -f "$syms" ] || { echo "ERROR: $syms not found" >&2; exit 1; }
    for TBD in "$@"; do
        [ -f "$TBD" ] || { echo "ERROR: $TBD not found" >&2; exit 1; }
        if [ -f "$TBD.pre-rehome-bak" ]; then cp "$TBD.pre-rehome-bak" "$TBD"; else cp "$TBD" "$TBD.pre-rehome-bak"; fi
        python3 - "$TBD" "$syms" <<'PY'
import sys, re
tbd, symspath = sys.argv[1], sys.argv[2]
classes, consts = set(), set()
for line in open(symspath):
    s = line.strip()
    if not s: continue
    if s.startswith('_OBJC_CLASS_$_'):      classes.add(s[len('_OBJC_CLASS_$_'):])
    elif s.startswith('_OBJC_METACLASS_$_'): classes.add(s[len('_OBJC_METACLASS_$_'):])
    else: consts.add(s)
t = open(tbd).read(); removed = 0
for c in sorted(classes, key=len, reverse=True):
    t, n = re.subn(r'\b%s\b,?[ \t]*' % re.escape(c), '', t); removed += n
for c in sorted(consts, key=len, reverse=True):
    t, n = re.subn(r"'?%s'?,?[ \t]*" % re.escape(c), '', t); removed += n
open(tbd, 'w').write(t)
print("  %s: removed %d class + %d const (%d hits)" % (tbd.split('Frameworks/')[-1], len(classes), len(consts), removed))
PY
    done
}

# The SDK duplicates each framework's .tbd across top-level / Versions/A / Versions/Current (all real
# files, not symlinks), and umbrella frameworks (CoreServices) carry nested sub-framework tbds
# (LaunchServices) where the symbol actually lives. Patch EVERY .tbd under the framework dir.
echo "### CFNetwork URL-loading symbols -> Foundation"
remove_syms "$HERE/cfnetwork-rehome-symbols.txt" \
    $(find "$SDK/System/Library/Frameworks/CFNetwork.framework" -name '*.tbd' ! -name '*.pre-rehome-bak')

echo "### CoreServices/LaunchServices polyfill classes -> our JSC polyfill"
remove_syms "$HERE/coreservices-rehome-symbols.txt" \
    $(find "$SDK/System/Library/Frameworks/CoreServices.framework" -name '*.tbd' ! -name '*.pre-rehome-bak')

echo "Done. Force a WebKit relink (touch the polyfill archives or delete the framework binaries)."
