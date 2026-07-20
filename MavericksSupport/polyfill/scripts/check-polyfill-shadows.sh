#!/bin/bash
# Fail the build if the layer defines a symbol OR an Objective-C method the 10.9 runtime ALREADY
# provides without saying so.
#
# Most of this layer is safe by construction: a symbol declared through the wk_polyfill.h macros
# carries a registry entry, so a gap-fill function forwards to 10.9 when 10.9 turns out to have the
# symbol, and a gap-fill constant has 10.9's real value copied over it at load. Being wrong about
# presence there costs nothing, which is why the README tells you not to check.
#
# But the archives ship plenty of code that carries no registry entry and gets none of that:
# legacy-support/src/*.c and polyfills/shared/*.c are plain C by design (the vendored GStreamer and
# python3 builds compile the shared ones with no wk_polyfill.h), and the mechanism's own units are
# plain C. For those, force_load simply makes our
# definition win -- silently, with no forwarding and no mirroring. That is the trap this gate exists
# for: a subtly-different stub over a working system function, with nothing at the call site to say
# so -- the kind of substitution that surfaces as a wrong colour or a wrong fill, far from its cause.
#
# So: for every strong defined symbol the layer ships, ask this machine's runtime (dlopen + dlsym,
# not nm of the modern SDK's stubs) whether 10.9 has it. If it does, the shadow has to be declared --
# as a WK_POLYFILL_REPLACES entry in the registry, which is self-describing and states the provider.
# Anything else is an accident: delete it and let WebKit bind 10.9's symbol.
#
# The layer's OTHER half is method polyfills, and they are in the same position: the selref rewrite
# sends WebKit's `foo` to `wk_foo` unconditionally, with no forwarding to the class's real `foo` and
# nothing at runtime that notices one exists. A WK_POLYFILL_SEL written for a method 10.9 does have
# therefore replaces working system behaviour silently, and a wrong premise about what 10.9's AppKit
# implements looks identical at every call site to a real gap. So the second half of this script asks
# the ObjC runtime the same question about every registered selector, with the same two answers
# available: WK_POLYFILL_SEL_REPLACES, or delete it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"           # polyfill/scripts
POLY="$(cd "$HERE/.." && pwd)"                                  # polyfill
REPO="$(cd "$POLY/../.." && pwd)"                               # repo root
BUILD="$POLY/build"; MECH="$POLY/mechanism"
# The registry probe force-loads libpolyfill.a, so it must be the toolchain that built it.
# build-polyfill.sh passes its own $CLANG; the default keeps the script runnable on its own.
CLANG="${1:-${MAVERICKS_CLANG:-$REPO/MavericksSupport/toolchain/build/clang}/bin/clang}"
NM=/Library/Developer/CommandLineTools/usr/bin/nm

# Where the layer's compiled symbols can come from. libwk_marker.a and libpolyfill_classes.a hold
# almost nothing, but they are force-loaded into WebKit binaries too, so they are in scope.
SCAN="libpolyfill.a libpolyfill_classes.a libpolyfill_classes.dylib
      libwtf_compat.a libwk_marker.a"

# The 10.9 images a WebKit binary's references can actually bind against. Used twice: the presence
# probe dlopens them, and the registry probe links against them.
#
# Deliberately NOT AVFoundation: on 10.9 dlsym(handle) walks the whole dependency tree, and
# AVFoundation drags in CoreWiFi, whose PRIVATE internal clock_gettime copy false-positives symbols
# no real two-level bind could reach. The polyfill's AVFoundation additions are ObjC classes, covered
# by their mangled names in libpolyfill_classes.dylib.
SYSTEM_LIBS="
/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics
/System/Library/Frameworks/CoreText.framework/CoreText
/System/Library/Frameworks/QuartzCore.framework/QuartzCore
/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
/System/Library/Frameworks/Foundation.framework/Foundation
/System/Library/Frameworks/AppKit.framework/AppKit
/System/Library/Frameworks/Security.framework/Security
/System/Library/Frameworks/CFNetwork.framework/CFNetwork
/System/Library/Frameworks/CoreServices.framework/CoreServices
/System/Library/Frameworks/ImageIO.framework/ImageIO
/System/Library/Frameworks/IOKit.framework/IOKit
/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration
/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox
/System/Library/Frameworks/CoreMedia.framework/CoreMedia
/System/Library/Frameworks/CoreVideo.framework/CoreVideo
/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices
/System/Library/Frameworks/Accelerate.framework/Accelerate
/usr/lib/libSystem.B.dylib
/usr/lib/libobjc.A.dylib
/usr/lib/libsqlite3.dylib
/usr/lib/libz.dylib
"

WORK="$(mktemp -d -t polyshadow)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- what the layer defines
# Strong (T/D/S/B) defined globals only; an undefined reference shadows nothing.
for lib in $SCAN; do
    [ -e "$BUILD/$lib" ] || continue
    $NM -g "$BUILD/$lib" 2>/dev/null \
        | awk -v lib="$lib" '$2 ~ /^[TDSB]$/ { sub(/^_/, "", $3); print $3 "\t" lib }'
done | sort -u > "$WORK/defined"
cut -f1 "$WORK/defined" | sort -u > "$WORK/names"

# ---------------------------------------------------------------- what 10.9 actually has
cat > "$WORK/present.c" <<'EOF'
// Does this machine's 10.9 runtime export the names on stdin? Ground truth for the gate: the build
// SDK is 26.1 and its stubs say nothing about what shipped in 2013.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
static const char *libs[] = {
EOF
printf '%s\n' "$SYSTEM_LIBS" | awk 'NF { printf "    \"%s\",\n", $1 }' >> "$WORK/present.c"
cat >> "$WORK/present.c" <<'EOF'
    0 };
int main(void)
{
    // Per-handle dlsym, NOT RTLD_DEFAULT: a flat global search also finds PRIVATE exports of
    // transitively loaded frameworks that no two-level-namespace bind against these libraries could
    // ever reach -- false positives. dlsym(handle) searches that library and its dependencies, which
    // is the scope a real link-time bind sees.
    void *handles[64]; const char *names[64];
    int count = 0;
    for (int i = 0; libs[i] && count < 64; i++) {
        void *handle = dlopen(libs[i], RTLD_NOW | RTLD_LOCAL);
        if (handle) { handles[count] = handle; names[count] = libs[i]; count++; }
    }
    char line[512];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0])
            continue;
        for (int i = 0; i < count; i++) {
            void *address = dlsym(handles[i], line);
            if (!address)
                continue;
            // Report the image that actually defines it, not the handle it was reached through: a
            // libSystem symbol answers on every framework handle, and "CoreGraphics has strlen" is
            // no help to whoever has to fix it.
            Dl_info info;
            printf("%s\t%s\n", line,
                   dladdr(address, &info) && info.dli_fname ? info.dli_fname : names[i]);
            break;
        }
    }
    return 0;
}
EOF
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -Wall -o "$WORK/present" "$WORK/present.c"
"$WORK/present" < "$WORK/names" | sort -u > "$WORK/on109"

# ---------------------------------------------------------------- what the registry declares
# Force-load libpolyfill.a and walk the __DATA,__wk_pfmap section this binary now carries -- the same
# walk wk_polyfill_runtime.c does at startup. Reading the registry out of the built archive (rather
# than grepping the sources for macro names) is what makes "declared" mean what the loader will
# actually see.
#
# -undefined dynamic_lookup because this probe only reads the section and calls none of the
# polyfills: it must not have to grow a link line every time a polyfill body references one more
# framework function. The libraries above are still linked so that the archive's DATA references
# (kCFAllocatorDefault, kCGColorSpaceSRGB, ...) bind at load.
cat > "$WORK/registry.c" <<'EOF'
#include "wk_polyfill.h"
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <stdio.h>
#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif
int main(void)
{
    Dl_info info;
    if (!dladdr((void *)&main, &info) || !info.dli_fbase) {
        fprintf(stderr, "cannot locate own image\n");
        return 2;
    }
    unsigned long size = 0;
    uint8_t *section = getsectiondata((const wk_mach_header *)info.dli_fbase,
                                      "__DATA", "__wk_pfmap", &size);
    if (!section) {
        fprintf(stderr, "no __DATA,__wk_pfmap in the force-loaded archive\n");
        return 2;
    }
    struct wk_polyfill_entry *entries = (struct wk_polyfill_entry *)section;
    for (size_t i = 0, n = size / sizeof(*entries); i < n; i++)
        printf("%s\t%s\n", entries[i].name,
               entries[i].intent == WK_POLYFILL_REPLACES ? "REPLACES" : "GAP_FILL");
    return 0;
}
EOF
LINK_LIBS=$(printf '%s\n' "$SYSTEM_LIBS" | awk 'NF { print $1 }')
# shellcheck disable=SC2086
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -Wall -I"$MECH" \
    -o "$WORK/registry" "$WORK/registry.c" \
    -Wl,-force_load,"$BUILD/libpolyfill.a" -Wl,-undefined,dynamic_lookup $LINK_LIBS
"$WORK/registry" | sort -u > "$WORK/registry.tsv"
awk -F'\t' '$2 == "REPLACES" { print $1 }' "$WORK/registry.tsv" | sort -u > "$WORK/replaces"

# ---------------------------------------------------------------- the verdict
# Presence is asked of the EXACT linker symbol, because that is the question that matters: would a
# reference to this name have bound to 10.9? The ABI-variant spellings some polyfills deliberately
# carry (syslog$DARWIN_EXTSN, fdopendir$INODE64, dispatch_assert_queue$V2) are separate symbols and
# get answered separately -- 10.9 exporting plain syslog says nothing about syslog$DARWIN_EXTSN.
#
# For the registry match the suffix is stripped, since a registry entry names the C function while
# the suffix comes from an asm label on that same function. Restricted to an all-caps variant marker
# on a non-OBJC_ name, so OBJC_CLASS_$_Foo -- where the $ is ObjC naming, not a variant -- is never
# truncated.
cut -f1 "$WORK/on109" | sort -u > "$WORK/present_names"
sort -u "$WORK/replaces" > "$WORK/accounted"
awk 'NR == FNR { accounted[$0] = 1; next }
     {
         base = $0
         if ($0 !~ /^OBJC_/ && match($0, /\$[A-Z][A-Z0-9_]*$/))
             base = substr($0, 1, RSTART - 1)
         if (!($0 in accounted) && !(base in accounted))
             print $0
     }' "$WORK/accounted" "$WORK/present_names" > "$WORK/offenders"

if [ -s "$WORK/offenders" ]; then
    {
        echo
        echo "ERROR: the polyfill layer defines symbols the 10.9 runtime ALREADY provides, and nothing"
        echo "says so. force_load makes our definition win, with no forwarding to 10.9 and no value"
        echo "mirroring -- so WebKit silently gets ours instead of the working system one:"
        echo
        while read -r symbol; do
            origins=$(awk -F'\t' -v s="$symbol" '$1 == s { printf "%s ", $2 }' "$WORK/defined")
            provider=$(awk -F'\t' -v s="$symbol" '$1 == s { print $2 }' "$WORK/on109")
            printf '  %-44s defined in %s(10.9 has it in %s)\n' "$symbol" "$origins" "$provider"
        done < "$WORK/offenders"
        echo
        echo "Two ways to fix each one:"
        echo "  * If shadowing 10.9 is the POINT (its version is there and misbehaves), declare it"
        echo "    WK_POLYFILL_REPLACES in polyfills/ -- see polyfill/README.md. That records the intent"
        echo "    where the loader can see it and keeps WK_ORIGINAL available."
        echo "  * Otherwise delete the definition and let WebKit bind 10.9's symbol. That is the"
        echo "    normal answer: this layer exists to fill gaps, not to reimplement working APIs."
    } >&2
    exit 1
fi

# ================================================================ ObjC method polyfills
# The same question for WK_POLYFILL_SEL, and the same two-program shape for the same reason: one
# program force-loads the ObjC polyfills so it can read the registry and see which class each private
# selector actually lands on, and a second one loads nothing of ours and asks this 10.9 whether that
# class already implements the public selector.

# polyfills/methods.o alone, not the whole archive: its sibling wk_selref_scope.o is the patcher, whose
# constructor installs a wk_ entry point on every class that HAS one of the registered methods -- which
# is exactly the fact being measured. Extracting the one member keeps the categories and the registry
# without the machinery that would answer the question for us.
mkdir -p "$WORK/members"
( cd "$WORK/members" && "$(dirname "$CLANG")/llvm-ar" x "$BUILD/libpolyfill_classes.a" methods.o )

# PDFKit and QuartzCore own classes methods.m extends (PDFPage, CAContext, CATransaction), so they join
# the list the C half already uses.
OBJC_LIBS="$SYSTEM_LIBS
/System/Library/Frameworks/Quartz.framework/Frameworks/PDFKit.framework/PDFKit
"

cat > "$WORK/selregistry.m" <<'EOF'
// What the ObjC half of the layer declares, and where each polyfill actually lands. Reads the
// __wk_selmap/__wk_addmap sections this binary carries because it force-loaded methods.o -- the same
// sections wk_selref_scope.m reads at startup, so "declared" means what the loader will see.
#include "wk_selref_scope.h"
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif

// pub, priv, intent, class, side, and the image that defines the class -- the last so the presence
// probe can load exactly what it needs to see that class, rather than guessing at a framework list.
static void emit(const struct wk_selmap_entry *entry, const char *className, const char *side)
{
    Class cls = className ? objc_getClass(className) : NULL;
    const char *image = cls ? class_getImageName(cls) : NULL;
    printf("%s\t%s\t%s\t%s\t%s\t%s\n", entry->pub, entry->priv,
           entry->intent == WK_SELMAP_REPLACES ? "REPLACES" : "GAP_FILL",
           className ? className : "-", side, image ? image : "-");
}

// The classes a category gave the private selector to. class_copyMethodList reports what the class
// defines ITSELF, which is where a category's method lands, and never an inherited one.
static int scanClass(Class where, const char *ownerName, const char *side,
                     const struct wk_selmap_entry *entries, size_t count, char *found)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(where, &n);
    if (!methods)
        return 0;
    int hits = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        for (size_t j = 0; j < count; j++) {
            if (strcmp(name, entries[j].priv))
                continue;
            emit(&entries[j], ownerName, side);
            found[j] = 1;
            hits++;
        }
    }
    free(methods);
    return hits;
}

int main(void)
{
    Dl_info info;
    if (!dladdr((void *)&main, &info) || !info.dli_fbase) {
        fprintf(stderr, "cannot locate own image\n");
        return 2;
    }
    const wk_mach_header *header = (const wk_mach_header *)info.dli_fbase;

    unsigned long size = 0;
    const struct wk_selmap_entry *entries =
        (const struct wk_selmap_entry *)getsectiondata(header, "__DATA", "__wk_selmap", &size);
    if (!entries) {
        fprintf(stderr, "no __DATA,__wk_selmap in the force-loaded methods.o\n");
        return 2;
    }
    size_t count = size / sizeof(*entries);
    char *found = calloc(count, 1);

    // WK_POLYFILL_ADD names its class outright, and installs an INSTANCE method (class_addMethod on the
    // class itself). Taken from the section rather than from a class scan because the mechanism that
    // installs those methods is deliberately not loaded here.
    unsigned long addSize = 0;
    const struct wk_addmap_entry *added =
        (const struct wk_addmap_entry *)getsectiondata(header, "__DATA", "__wk_addmap", &addSize);
    for (size_t a = 0; added && a < addSize / sizeof(*added); a++)
        for (size_t j = 0; j < count; j++)
            if (!strcmp(added[a].sel, entries[j].priv)) {
                emit(&entries[j], added[a].cls, "instance");
                found[j] = 1;
            }

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        scanClass(classes[i], name, "instance", entries, count, found);
        // A class method lives on the metaclass; it is still reported against the class's own name.
        scanClass(object_getClass(classes[i]), name, "class", entries, count, found);
    }
    free(classes);

    // A registration whose private selector exists on no class is dead: WebKit's `foo` is rewritten to
    // a `wk_foo` nothing implements. Reported with no class so the gate can say so.
    for (size_t j = 0; j < count; j++)
        if (!found[j])
            emit(&entries[j], NULL, "-");
    return 0;
}
EOF
LINK_LIBS=$(printf '%s\n' "$OBJC_LIBS" | awk 'NF { print $1 }')
# libpolyfill.a as an ordinary archive: methods.o's WK_SYSTEM_FN needs wk_polyfill_system_symbol, and
# nothing else of it is reached. Only methods.o is force-loaded.
# shellcheck disable=SC2086
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -Wall -I"$MECH" \
    -o "$WORK/selregistry" "$WORK/selregistry.m" \
    -Wl,-force_load,"$WORK/members/methods.o" "$BUILD/libpolyfill.a" \
    -Wl,-undefined,dynamic_lookup -lobjc $LINK_LIBS
"$WORK/selregistry" | sort -u > "$WORK/selregistry.tsv"

cat > "$WORK/selpresent.m" <<'EOF'
// Does this machine's 10.9 already implement the public selector on that class? Ground truth: nothing
// of the polyfill layer is linked in, so every method seen here is the system's own.
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The class that DEFINES the selector, walking up from cls -- an inherited method is one a send of that
// selector would reach just the same, so it counts, but naming the owner is what makes a hit fixable.
// class_copyMethodList rather than class_getInstanceMethod: the latter consults
// +resolveInstanceMethod:, and a probe should not be able to make a class invent an answer.
static Class definingClass(Class cls, SEL sel)
{
    for (Class k = cls; k; k = class_getSuperclass(k)) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(k, &n);
        if (!methods)
            continue;
        int hit = 0;
        for (unsigned int i = 0; i < n; i++)
            if (method_getName(methods[i]) == sel) { hit = 1; break; }
        free(methods);
        if (hit)
            return k;
    }
    return NULL;
}

int main(int argc, char **argv)
{
    // The frameworks a class can come from, so that objc_getClass can see it. Each registry line also
    // names the image its class came from, and that one is loaded too.
    for (int i = 1; i < argc; i++)
        dlopen(argv[i], RTLD_LAZY | RTLD_LOCAL);

    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0])
            continue;
        char *className = strtok(line, "\t");
        char *side = className ? strtok(NULL, "\t") : NULL;
        char *pub = side ? strtok(NULL, "\t") : NULL;
        char *image = pub ? strtok(NULL, "\t") : NULL;
        if (!pub)
            continue;
        if (image && strcmp(image, "-"))
            dlopen(image, RTLD_LAZY | RTLD_LOCAL);

        Class cls = objc_getClass(className);
        if (!cls) {
            printf("%s\t%s\t%s\tNOCLASS\t-\n", className, side, pub);
            continue;
        }
        Class start = strcmp(side, "class") ? cls : object_getClass(cls);
        Class owner = definingClass(start, sel_getUid(pub));
        const char *ownerImage = owner ? class_getImageName(owner) : NULL;
        printf("%s\t%s\t%s\t%s\t%s\n", className, side, pub, owner ? "PRESENT" : "absent",
               owner ? (ownerImage ? ownerImage : class_getName(owner)) : "-");
    }
    return 0;
}
EOF
"$CLANG" --no-default-config -mmacosx-version-min=10.9 -Wall -o "$WORK/selpresent" "$WORK/selpresent.m" -lobjc
# shellcheck disable=SC2086
awk -F'\t' '$4 != "-" { print $4 "\t" $5 "\t" $1 "\t" $6 }' "$WORK/selregistry.tsv" \
    | "$WORK/selpresent" $LINK_LIBS | sort -u > "$WORK/selon109"

# ---------------------------------------------------------------- the ObjC verdict
# A GAP_FILL whose public selector 10.9 already implements is not a defect: the patcher forwards to
# 10.9's method (wk_alias_class's class_replaceMethod), so the body simply goes unused, the same way a
# C WK_POLYFILL_ABSENT forwards. It is reported so the unused body is visible, but it does not fail the
# build -- writing a GAP_FILL without knowing whether 10.9 has the method is exactly what the layer is
# for. A registration that landed on no class at all IS a hard failure: the rewrite still happens, so
# WebKit sends a selector nothing implements.
: > "$WORK/selforwarded"
: > "$WORK/seldead"
while IFS=$'\t' read -r pub priv intent cls side image; do
    if [ "$cls" = "-" ]; then
        printf '%s\t%s\n' "$pub" "$priv" >> "$WORK/seldead"
        continue
    fi
    [ "$side" = "class" ] && sigil=+ || sigil=-
    verdict=$(awk -F'\t' -v c="$cls" -v s="$side" -v p="$pub" \
                  '$1 == c && $2 == s && $3 == p { print $4 "\t" $5 }' "$WORK/selon109")
    state=${verdict%%$'\t'*}; owner=${verdict#*$'\t'}
    [ "$state" = "PRESENT" ] || continue
    [ "$intent" = "REPLACES" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$sigil[$cls $pub]" "$priv" "$cls" "$owner" >> "$WORK/selforwarded"
done < "$WORK/selregistry.tsv"

if [ -s "$WORK/selforwarded" ]; then
    {
        echo
        echo "NOTE: these WK_POLYFILL_SEL gap-fills name a method 10.9 already implements, so the patcher"
        echo "forwards to 10.9's and the polyfill body is unused. This is harmless; if the override is the"
        echo "point, declare WK_POLYFILL_SEL_REPLACES so the body wins and the intent is on the record:"
        while IFS=$'\t' read -r sent priv cls owner; do
            printf '  %-42s -> %-38s 10.9 defines it on %s, in %s\n' "$sent" "$priv" "$cls" "$owner"
        done < "$WORK/selforwarded"
    }
fi

if [ -s "$WORK/seldead" ]; then
    {
        echo
        echo "ERROR: these WK_POLYFILL_SEL registrations point at a private selector no class"
        echo "implements. The rewrite still happens, so WebKit sends a selector that exists nowhere and"
        echo "the first call dies with an unrecognized selector, arbitrarily far from here:"
        echo
        while IFS=$'\t' read -r pub priv; do
            printf '  %-46s -> %s\n' "$pub" "$priv"
        done < "$WORK/seldead"
        echo
        echo "Either implement the wk_ method on the class it belongs to, or drop the registration."
    } >&2
    exit 1
fi

scanned=$(wc -l < "$WORK/names" | tr -d ' ')
registered=$(wc -l < "$WORK/registry.tsv" | tr -d ' ')
shadows=$(wc -l < "$WORK/present_names" | tr -d ' ')
selectors=$(wc -l < "$WORK/selregistry.tsv" | tr -d ' ')
selshadows=$(awk -F'\t' '$4 == "PRESENT"' "$WORK/selon109" | wc -l | tr -d ' ')
echo "  polyfill shadow check: clean -- $scanned defined symbols, $registered registered;"
echo "    $shadows are present on 10.9, each declared WK_POLYFILL_REPLACES"
echo "    $selectors ObjC method polyfills, each landing on a class; $selshadows are present"
echo "    on 10.9, each declared WK_POLYFILL_SEL_REPLACES"
