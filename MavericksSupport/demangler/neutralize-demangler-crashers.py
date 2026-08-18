#!/usr/bin/python
# MAVERICKS_BACKPORT: neutralize symbols that crash the 10.9 libc++abi demangler.
#
# The 10.9 __cxa_demangle (the old fixed-arena demangler in /usr/lib/libc++abi.dylib)
# corrupts its heap on certain modern-C++ mangled names -- notably the local symbols
# clang emits for generic lambdas inside variadic member-function templates
# instantiated with an empty parameter pack (WebCore::Style::CSSValueCreation /
# ToCSS emit ~2 dozen of these). ReportCrash demangles EVERY nlist symbol of every
# image mapped by a crashing process (CoreSymbolication create_symbol_owner_data),
# so one such symbol in an installed WebKit binary makes ReportCrash itself die
# mid-report: no .crash is ever written for any WebKit process, and sample /
# spindump break the same way.
#
# Fix: empirically test every mangled symbol of the binaries we install against
# the HOST demangler and rename each crasher in the Mach-O string table from
# "_Z..." to "_z..." (one byte, in place). Symbolication then treats it as a plain
# non-C++ name and never demangles it. Only LOCAL (non-exported) symbols may be
# patched -- nothing binds to them at runtime, so the rename is ABI-inert; if a
# CONFIRMED crasher is an exported symbol this script aborts loudly instead.
#
# Detection is inherently probabilistic: the demangler bug reads uninitialized
# stack (its arena), so whether a given bad symbol visibly misbehaves depends on
# stack garbage, environment size, and prior heap use. The scanner therefore
# (a) runs the compiled demangler-crash-scan.cpp worker (fork-isolated, bisecting)
# several times with a varied environment -- trials under the freecheck
# interposer (traps wild free() of unallocated pointers, the bug's primary
# signature) plus one under Guard Malloc (traps heap overruns; the two
# detectors cannot coexist in one process) -- unioning the results, and (b) generalizes
# each confirmed crasher to its whole template FAMILY (every local symbol sharing
# the same family-head prefix, e.g. all _ZZN7WebCore5Style16CSSValueCreationI...
# symbols) so family members whose corruption merely stayed silent in this run's
# layout are neutralized too. Detection integrity is fail-loud: every trial first
# proves the wild-free interposer is live (worker --selftest-wildfree must exit
# 42), and a worker range that fails without attributable crashers (UNATTRIBUTED)
# forces a retry and ultimately an abort, never a silent pass.
#
# Even so, the scan is only as good as this host's memory layout: a family in
# which NO member happens to misbehave here ships unpatched and can still crash
# a differently-laid-out symbolication host (a spindump on other hardware died
# in exactly this way, expanding a Style::CSSValueConversion local this scan
# had certified). So in addition to the empirical scan, every local symbol
# whose mangling matches the crash-prone STRUCTURAL shape itself -- an
# operator() instantiated with an empty parameter pack ("clIJEE"), a
# pack-expansion parameter ("DpOT_"), and a generic lambda ("Ul...E_") -- is
# neutralized unconditionally, no confirmation needed. That predicate is
# layout-independent, and over-matching is harmless: only local symbols are
# patched, and the sole cost is that reports show those locals mangled.
#
# The scan is empirical rather than a hardcoded symbol list because the set of
# offending symbols drifts with every rebuild (new template instantiations).
# Re-running on an already-patched binary is a no-op ("_z" names are skipped).
#
# Usage: neutralize-demangler-crashers.py <macho-binary>...
#        (fat binaries: every x86_64 slice is processed; other slices untouched)

import os
import struct
import subprocess
import sys
import tempfile
import traceback

MH_MAGIC_64 = 0xfeedfacf
MH_MAGIC_32 = 0xfeedface
FAT_MAGIC = 0xcafebabe
CPU_TYPE_X86_64 = 0x01000007
LC_SYMTAB = 0x2
N_STAB = 0xe0
N_EXT = 0x01

GMALLOC = "/usr/lib/libgmalloc.dylib"
SUPPORT_DIR = os.path.dirname(os.path.abspath(__file__))

# MAVERICKS_BACKPORT: resolve a working compiler WITHOUT routing through the
# /usr/bin/cc xcrun shim. That shim asks `xcodebuild -find <tool>`, which on 10.9
# crashes when a modern Xcode.app is present and errors out when no Xcode/CLT is
# installed at all -- either way the shim never yields a compiler. The real toolchain
# binaries are directly invocable, so prefer them (env override, then the Xcode
# default toolchain, then the /usr/bin shim as a last resort). The cctools lookup in
# MavericksSupport/scripts/framework-layout.sh probes around the same shim.
_XCODE_TC_BIN = ("/Applications/Xcode.app/Contents/Developer/Toolchains/"
                 "XcodeDefault.xctoolchain/usr/bin")

def resolve_compiler(basename, env_key):
    candidates = [os.environ.get(env_key),
                  os.path.join(_XCODE_TC_BIN, basename),
                  os.path.join("/usr/bin", basename)]
    for cc in candidates:
        if not cc or not os.path.exists(cc):
            continue
        try:
            devnull = open(os.devnull, "wb")
            rc = subprocess.call([cc, "--version"], stdout=devnull, stderr=devnull)
            devnull.close()
        except OSError:
            continue
        if rc == 0:
            return cc
    sys.stderr.write("ERROR: no working compiler found for %s (tried %s)\n"
                     % (basename, ", ".join(c for c in candidates if c)))
    sys.exit(1)

# (environment-padding size, worker batch size, detector): varied to shift
# the stack garbage and heap state the demangler bug is sensitive to.
# "gmalloc" (Guard Malloc, catches heap-overrun-class corruption) is ~10x
# slower, so only one trial runs under it; the "freecheck" wild-free trap
# alone catches the bug's dominant signature at full speed. The two
# detectors cannot be combined in one process (see demangler-crash-scan.cpp).
# Exactly which subset of a bad template family each trial detects varies
# with layout, but the family closure below patches the whole family either
# way, so the final patch set is insensitive to the trial mix.
SCAN_TRIALS = [(0, 2000, "gmalloc"), (1024, 2000, "freecheck"),
               (7777, 701, "freecheck"), (300, 149, "freecheck")]

# Extra re-runs of a trial that reported an UNATTRIBUTED range (a batch died
# but bisection could not reproduce the crash on any individual symbol).
UNATTRIBUTED_RETRIES = 3


def build_scan_tools(workdir):
    worker = os.path.join(workdir, "demangler-crash-scan")
    freecheck = os.path.join(workdir, "freecheck.dylib")
    cxx = resolve_compiler("clang++", "WK_DEMANGLER_CXX")
    cc = resolve_compiler("clang", "WK_DEMANGLER_CC")
    subprocess.check_call([cxx, "-O2",
                           "-mmacosx-version-min=10.9", "-o", worker,
                           os.path.join(SUPPORT_DIR, "demangler-crash-scan.cpp")])
    subprocess.check_call([cc, "-dynamiclib",
                           "-mmacosx-version-min=10.9", "-o", freecheck,
                           os.path.join(SUPPORT_DIR,
                                        "demangler-crash-scan-freecheck.c")])
    return worker, freecheck


def trial_env(freecheck, pad, detector):
    if detector == "gmalloc" and not os.path.exists(GMALLOC):
        sys.stderr.write("ERROR: %s missing -- overrun detection unavailable\n"
                         % GMALLOC)
        sys.exit(1)
    env = dict(os.environ)
    env["DYLD_INSERT_LIBRARIES"] = (GMALLOC if detector == "gmalloc"
                                    else freecheck)
    env["DEMANGLER_SCAN_PAD"] = "x" * pad
    return env


def assert_detection_live(worker, env, detector):
    """The scan is only meaningful if the inserted detector is actually
    loaded; a silently-failed DYLD insertion would report a clean scan on a
    broken detector. freecheck: freeing a known-garbage pointer must hit the
    interposer's _exit(42). gmalloc: writing past a malloc'd block must fault
    on the guard page -- exit 43 via the worker's quiet-death signal handler
    (or raw signal death if that handler is somehow not in place)."""
    if detector == "freecheck":
        rc = subprocess.call([worker, "--selftest-wildfree"], env=env,
                             stdout=open(os.devnull, "w"),
                             stderr=subprocess.STDOUT)
        ok = rc == 42
    else:
        rc = subprocess.call([worker, "--selftest-overrun"], env=env,
                             stdout=open(os.devnull, "w"),
                             stderr=subprocess.STDOUT)
        ok = rc == 43 or rc < 0
    if not ok:
        sys.stderr.write("ERROR: %s detection self-test failed (worker "
                         "exited %d) -- detector is not live\n"
                         % (detector, rc))
        sys.exit(1)


def run_worker(worker, env, symfile, batch):
    """One worker run; returns (crasher names, saw-unattributed-range)."""
    proc = subprocess.Popen([worker, symfile, str(batch)],
                            stdout=subprocess.PIPE,
                            stderr=open(os.devnull, "w"), env=env)
    out, _ = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError("demangler-crash-scan exited %d" % proc.returncode)
    crashers = set()
    unattributed = False
    for line in out.splitlines():
        if line.startswith(b"CRASHER "):
            crashers.add(line.split(b" ", 2)[2])
        elif line.startswith(b"UNATTRIBUTED "):
            unattributed = True
    return crashers, unattributed


def run_trial(tools, symfile, trial):
    """One SCAN_TRIALS entry over one symbol file, retried while it reports an
    UNATTRIBUTED range."""
    worker, freecheck = tools
    pad, batch, detector = trial
    crashers = set()
    for attempt in range(1 + UNATTRIBUTED_RETRIES):
        # retries shift the env padding: an identical environment
        # reproduces the identical stack layout, so re-running the same
        # config would repeat the same unattributable outcome forever
        env = trial_env(freecheck, pad + attempt * 131, detector)
        assert_detection_live(worker, env, detector)
        found, unattributed = run_worker(worker, env, symfile, batch)
        new = found - crashers
        crashers |= found
        if not unattributed:
            return crashers
        sys.stderr.write("  demangler-guard: UNATTRIBUTED range in trial "
                         "(pad=%d batch=%d detector=%s), attempt %d, "
                         "%d new crasher(s) -- retrying\n"
                         % (pad, batch, detector, attempt + 1, len(new)))
    sys.stderr.write("ERROR: a scan batch keeps dying without an "
                     "attributable crasher after %d retries -- "
                     "refusing to certify this binary\n"
                     % UNATTRIBUTED_RETRIES)
    sys.exit(1)


def scan_jobs():
    """How many scan processes run at once."""
    try:
        import multiprocessing
        return max(1, multiprocessing.cpu_count())
    except Exception:
        return 1


def write_chunks(workdir, names, count):
    """Split the symbol list into at most `count` non-empty files."""
    per = max(1, (len(names) + count - 1) // count)
    paths = []
    for i in range(0, len(names), per):
        path = os.path.join(workdir, "syms.%d.txt" % len(paths))
        with open(path, "wb") as f:
            f.write(b"\n".join(names[i:i + per]) + b"\n")
        paths.append(path)
    return paths


def scan_names(tools, workdir, names):
    """Union of crashers over every (trial, symbol-range) pair.

    Both splits are unions of independent runs. A trial fixes its own
    environment padding, batch size and detector -- the variables the bug is
    sensitive to -- and none of them depends on what another process is doing,
    so the trials can run at the same time. A range is a slice of the symbol
    list handed to the same worker with the same trial settings, so splitting
    one only moves where a batch boundary falls, which the family closure below
    already absorbs (a family is patched whole from any one member).

    That matters because the trial mix is lopsided: the Guard Malloc trial is
    ~40x the wall time of the three wild-free trials put together, so scanning
    it in ranges is what takes the scan off the critical path of the build. The
    Guard Malloc trial is first in SCAN_TRIALS and its ranges are queued first,
    so the long pole starts on the first free processor."""
    if not names:
        return set()
    jobs = scan_jobs()
    chunks = write_chunks(workdir, names, jobs)
    pending = [(trial, chunk) for trial in SCAN_TRIALS for chunk in chunks]

    crashers = set()
    failed = False
    running = {}
    spawned = 0
    while pending or running:
        while pending and len(running) < jobs:
            trial, chunk = pending.pop(0)
            outfile = os.path.join(workdir, "crashers.%d" % spawned)
            spawned += 1
            pid = os.fork()
            if pid == 0:
                # os._exit throughout: fork() duplicates the parent's buffered
                # stdout into this child, and a normal exit would flush that
                # copy and print an earlier binary's summary line a second time.
                status = 0
                try:
                    with open(outfile, "wb") as f:
                        f.write(b"\n".join(sorted(run_trial(tools, chunk, trial))))
                except SystemExit as e:
                    status = e.code or 1
                except Exception:
                    traceback.print_exc()
                    status = 1
                os._exit(status)
            running[pid] = outfile
        pid, status = os.wait()
        outfile = running.pop(pid)
        if status != 0:
            failed = True          # the child already said why, on stderr
            pending = []           # nothing more to start; reap what is running
            continue
        with open(outfile, "rb") as f:
            crashers |= set(n for n in f.read().split(b"\n") if n)
        os.unlink(outfile)
    if failed:
        sys.exit(1)
    return crashers


# The mangling components of the demangler-crashing shape (see header): an
# empty-pack operator() instantiation, a pack-expansion parameter, and a
# generic lambda. All three must appear. Substring matching can over-match
# (e.g. "Ul" inside an identifier), which only neutralizes extra locals.
STRUCTURAL_MARKERS = (b"clIJEE", b"DpOT_", b"Ul")


def structurally_crash_prone(mangled):
    return all(m in mangled for m in STRUCTURAL_MARKERS)


def family_head(mangled):
    """Everything up to and including the first 'I' byte. This approximates
    the start of the first template-argument list; the 'I' can also land
    inside an identifier, which only makes the family LARGER -- safe, since
    closure members are patched only if local, and never smaller for true
    family members (their genuine template-args 'I' is at the same offset)."""
    i = mangled.find(b"I")
    if i < 8:  # no template args, or too generic to define a family
        return mangled
    return mangled[:i + 1]


def mangled_view(name):
    """(mangled-name-for-demangler, offset-of-'Z'-within-stored-name) or None."""
    if name.startswith(b"__Z"):
        return name[1:], 2  # stored C-underscore + "_Z..."
    if name.startswith(b"_Z"):
        return name, 1  # raw asm-level name
    return None


def slices_of(data):
    """Yield file offsets of every x86_64 Mach-O slice header."""
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be == FAT_MAGIC:
        nfat = struct.unpack_from(">I", data, 4)[0]
        for i in range(nfat):
            cputype, _, offset, _, _ = struct.unpack_from(">iiIII", data, 8 + 20 * i)
            if cputype == CPU_TYPE_X86_64:
                yield offset
        return
    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le == MH_MAGIC_64:
        cputype = struct.unpack_from("<i", data, 4)[0]
        if cputype == CPU_TYPE_X86_64:
            yield 0
        return
    if magic_le == MH_MAGIC_32:
        return  # 32-bit slice alone: stock code, nothing to do
    raise ValueError("not a Mach-O or fat binary")


def symtab_of_slice(data, base):
    """Return (symoff, nsyms, stroff, strsize) of the slice's LC_SYMTAB."""
    ncmds, = struct.unpack_from("<I", data, base + 16)
    off = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SYMTAB:
            return struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize
    return None


def walk_nlist_names(data, base, symtab):
    """Yield (strx, n_type, stored-name) for every named nlist entry."""
    symoff, nsyms, stroff, strsize = symtab
    str_abs = base + stroff
    for i in range(nsyms):
        strx, n_type = struct.unpack_from("<IB", data, base + symoff + 16 * i)[:2]
        if not strx:
            continue
        end = data.index(b"\0", str_abs + strx, str_abs + strsize)
        yield strx, n_type, bytes(data[str_abs + strx:end])


def process(path, tools, workdir):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    total_scanned = 0
    confirmed = 0
    patched_names = 0
    structural_only = 0   # patched by shape alone, no scan-confirmed family
    patches = []          # absolute file offsets of 'Z' bytes to flip
    prepatch_names = {}   # (base, strx) -> stored name before patching
    intended = set()      # (base, strx) keys we mean to change
    slice_symtabs = []
    for base in slices_of(data):
        symtab = symtab_of_slice(data, base)
        if not symtab:
            continue
        slice_symtabs.append((base, symtab))
        str_abs = base + symtab[2]

        # mangled name -> ({strx: stored-name-'Z'-offset}, all-local?). The
        # same mangled name can be stored both as "__Z..." and raw "_Z..."
        # (different strx, different Z offset), so the offset is per-strx.
        by_mangled = {}
        for strx, n_type, name in walk_nlist_names(data, base, symtab):
            prepatch_names[(base, strx)] = name
            view = mangled_view(name)
            if view is None:
                continue
            entry = by_mangled.setdefault(view[0], [{}, True])
            entry[0][strx] = view[1]
            if not (n_type & N_STAB) and (n_type & N_EXT):
                entry[1] = False

        names = sorted(by_mangled.keys())
        total_scanned += len(names)
        crashers = scan_names(tools, workdir, names)
        confirmed += len(crashers)
        for mangled in crashers:
            if not by_mangled[mangled][1]:
                sys.stderr.write(
                    "ERROR: %s: EXPORTED symbol crashes the 10.9 demangler; "
                    "renaming it would break linkage -- fix it at the source "
                    "instead: %s\n" % (path, mangled.decode("ascii", "replace")))
                sys.exit(1)

        heads = set(family_head(m) for m in crashers)
        for mangled in names:
            in_family = family_head(mangled) in heads
            if not in_family and not structurally_crash_prone(mangled):
                continue
            strx_zrel, all_local = by_mangled[mangled]
            if not all_local:
                # family/structural closure over-approximates; never touch
                # exports
                sys.stderr.write("  demangler-guard: WARNING: leaving exported "
                                 "%s unpatched: %s\n"
                                 % ("family member" if in_family
                                    else "structural match",
                                    mangled.decode("ascii", "replace")))
                continue
            patched_names += 1
            if not in_family:
                structural_only += 1
            for strx, zrel in strx_zrel.items():
                zoff = str_abs + strx + zrel
                assert data[zoff:zoff + 1] == b"Z"
                data[zoff:zoff + 1] = b"z"
                patches.append(zoff)
                intended.add((base, strx))

    # Safety re-walk before writing anything: an n_strx may point INSIDE
    # another symbol's string (suffix sharing), so a byte-level patch could
    # silently rename an unrelated -- possibly exported -- symbol. Re-read
    # every nlist name and require that exactly the intended entries changed,
    # each by the single Z->z byte.
    for base, symtab in slice_symtabs:
        for strx, n_type, name in walk_nlist_names(data, base, symtab):
            old = prepatch_names[(base, strx)]
            if (base, strx) in intended:
                if len(name) != len(old) or name.replace(b"z", b"Z", 1) != old:
                    sys.stderr.write("ERROR: %s: intended patch of strx %d "
                                     "did not produce a clean Z->z rename "
                                     "(%r -> %r); aborting without writing\n"
                                     % (path, strx, old, name))
                    sys.exit(1)
            elif name != old:
                sys.stderr.write("ERROR: %s: patch would corrupt unrelated "
                                 "symbol at strx %d (%r -> %r); aborting "
                                 "without writing\n" % (path, strx, old, name))
                sys.exit(1)

    if patches:
        with open(path, "r+b") as f:
            for off in patches:
                f.seek(off)
                f.write(b"z")
    print("  demangler-guard: %s: %d mangled symbols scanned, %d confirmed "
          "crasher(s), %d symbol name(s) neutralized (family closure; "
          "%d by structural shape alone)"
          % (os.path.basename(path), total_scanned, confirmed, patched_names,
             structural_only))


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: %s <macho-binary>...\n" % argv[0])
        return 2
    workdir = tempfile.mkdtemp(prefix="demangler-guard.")
    try:
        tools = build_scan_tools(workdir)
        for path in argv[1:]:
            process(path, tools, workdir)
    finally:
        for f in os.listdir(workdir):
            os.unlink(os.path.join(workdir, f))
        os.rmdir(workdir)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
