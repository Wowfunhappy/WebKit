#!/usr/bin/env python3
"""Bootstrap the native Rust host without changing the deployed target runtime."""
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

SCRIPTS = Path(__file__).resolve().parent
TOOLCHAIN = SCRIPTS.parent
REPO = TOOLCHAIN.parent.parent
SHARED = REPO / 'MavericksSupport/polyfill/polyfills/shared'
PREFIX = Path(os.environ.get('MAVERICKS_RUST_PREFIX', TOOLCHAIN / 'build/rust'))
WORK = TOOLCHAIN / 'build/rust-bootstrap'
DOWNLOADS = WORK / 'downloads'
CLANG = TOOLCHAIN / 'build/clang/bin/clang'
AR = TOOLCHAIN / 'build/clang/bin/llvm-ar'
OTOOL = TOOLCHAIN / 'build/cctools/bin/otool'
NM = TOOLCHAIN / 'build/cctools/bin/nm'
INSTALL_NAME_TOOL = TOOLCHAIN / 'build/cctools/bin/install_name_tool'
INPUTS_PATH = SCRIPTS / 'rust-bootstrap-inputs.json'
INPUTS = json.loads(INPUTS_PATH.read_text())
HOST_SOURCES = ('ccrandom', 'getentropy', 'os_unfair_lock', 'time', 'atcalls',
                'statxx', 'fdopendir', 'pthread_chdir', 'utimensat', 'clonefile', 'pthread_qos', 'pthread_stack')


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(temporary, destination):
    if destination.exists() and digest(temporary) == digest(destination):
        temporary.unlink()
    else:
        temporary.replace(destination)


def verify_deployment(path):
    command = None
    versions = []
    for line in output(OTOOL, '-l', path).splitlines():
        fields = line.strip().split()
        if fields[:1] == ['cmd']:
            command = fields[1]
        elif fields and ((command == 'LC_VERSION_MIN_MACOSX' and fields[0] == 'version')
                         or (command == 'LC_BUILD_VERSION' and fields[0] == 'minos')):
            version = tuple(int(part) for part in fields[1].split('.'))
            versions.append(version + (0,) * (3 - len(version)))
    if versions != [(10, 9, 0)]:
        raise RuntimeError(str(path) + ': expected macOS 10.9 deployment, got ' + str(versions))
    print('### macOS 10.9 deployment verified:', path, flush=True)


def fetch(url, path, expected):
    if path.exists() and digest(path) == expected:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.download')
    run('curl', '--fail', '--location', '--retry', '3', '--output', temporary, url)
    if digest(temporary) != expected:
        raise RuntimeError('SHA256 mismatch: ' + url)
    temporary.replace(path)


def installed_stamp(name, value):
    stamp = PREFIX / name
    return stamp.exists() and stamp.read_text() == value


def write_stamp(name, value):
    temporary = PREFIX / (name + '.tmp')
    temporary.write_text(value)
    temporary.replace(PREFIX / name)


def bind_host_runtime(root, shim, prefer_native=False):
    """Select and audit each Mach-O image's native or shared host provider."""
    runtime = ctypes.CDLL(str(shim))
    native = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    patched = 0
    for directory, subdirs, filenames in os.walk(root):
        subdirs[:] = [name for name in subdirs if name not in
                      ('src', 'share', 'include', 'compiler-rt', 'cargo-home', 'host-check')]
        for name in filenames:
            path = Path(directory) / name
            if path.is_symlink() or path == shim:
                continue
            with path.open('rb') as stream:
                if stream.read(4) != b'\xcf\xfa\xed\xfe':
                    continue
            dependencies = output(OTOOL, '-L', path)
            symbols = []
            needs_replacement = False
            for line in output(NM, '-um', path).splitlines():
                if not re.search(r'\(from (?:@loader_path/)?libSystem(?:Rust)?\)', line):
                    continue
                symbol = line.split('external ', 1)[1].split()[0]
                needs_replacement |= symbol == '_pthread_get_stacksize_np'
                if symbol != 'dyld_stub_binder' and 'weak' not in line:
                    symbols.append(symbol)
            use_native = prefer_native and not needs_replacement and all(hasattr(native, symbol[1:]) for symbol in symbols)
            provider = native if use_native else runtime
            replacement = '/usr/lib/libSystem.B.dylib' if use_native else '@loader_path/libSystem'
            for line in dependencies.splitlines()[1:]:
                original = line.strip().split(' (compatibility version', 1)[0]
                if original not in ('/usr/lib/libSystem.B.dylib', '@loader_path/libSystem') and not original.endswith('/libSystemRust.dylib'):
                    continue
                if not use_native:
                    alias = path.parent / 'libSystem'
                    destination = os.path.relpath(shim, alias.parent)
                    if alias.is_symlink():
                        if alias.resolve() != shim.resolve():
                            raise RuntimeError('Conflicting host runtime symlink: ' + str(alias))
                    elif alias.exists():
                        raise RuntimeError('Host runtime alias conflicts with an existing artifact: ' + str(alias))
                    else:
                        alias.symlink_to(destination)
                if original != replacement:
                    run(INSTALL_NAME_TOOL, '-change', original, replacement, path)
                    patched += 1
            for symbol in symbols:
                if not hasattr(provider, symbol[1:]):
                    raise RuntimeError(str(path) + ': missing strong host runtime symbol ' + symbol)
    print('### Rust host libSystem import substitutions:', patched, flush=True)


def main():
    PREFIX.mkdir(parents=True, exist_ok=True)
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    component_identity = json.dumps(INPUTS['components'], sort_keys=True)
    if not installed_stamp('.components', component_identity):
        for item in INPUTS['components']:
            archive = DOWNLOADS / item['name']
            fetch(item['url'], archive, item['sha256'])
            unpacked = WORK / item['name'].removesuffix('.tar.xz')
            if unpacked.exists():
                shutil.rmtree(unpacked)
            run('tar', '-xJf', archive, '-C', WORK)
            run('bash', unpacked / 'install.sh', '--prefix=' + str(PREFIX), '--disable-ldconfig')
        write_stamp('.components', component_identity)

    # The prebuilt std imports half conversions from libSystem. Build the exact
    # compiler-rt implementations with their x86_64 Float16 ABI and public
    # visibility; Clang's own archive deliberately hides these entry points.
    compiler_sources = WORK / 'compiler-rt-source'
    compiler_sources.mkdir(exist_ok=True)
    compiler_rt = INPUTS['compiler_rt']
    for name, checksum in compiler_rt['files'].items():
        url = ('https://raw.githubusercontent.com/llvm/llvm-project/' + compiler_rt['tag']
               + '/compiler-rt/lib/builtins/' + name)
        fetch(url, compiler_sources / name, checksum)

    identity = hashlib.sha256()
    sources = [SHARED / (name + '.c') for name in HOST_SOURCES]
    sources += list((SHARED / 'include').rglob('*'))
    sources += [SHARED / 'atcalls.h', SHARED / 'compiler.h', INPUTS_PATH, Path(__file__),
                SCRIPTS / 'rustc-wrapper.sh', SCRIPTS / 'rust-env.sh']
    sources += list((TOOLCHAIN / 'tests/rust-host').rglob('*'))
    for path in sorted(path for path in sources if path.is_file()):
        identity.update(str(path.relative_to(REPO)).encode())
        identity.update(path.read_bytes())
    identity.update(output(CLANG, '--version').encode())
    fingerprint = identity.hexdigest()
    if installed_stamp('.host-runtime', fingerprint):
        print('### Rust host runtime and build-script/proc-macro checks are current', flush=True)
        return

    objects = WORK / 'host'
    objects.mkdir(exist_ok=True)
    flags = ('--no-default-config', '-isysroot', '/', '-mmacosx-version-min=10.9', '-std=gnu11', '-O2')
    object_files = []
    for name in HOST_SOURCES:
        target = objects / (name + '.o')
        run(CLANG, *flags, '-I' + str(SHARED / 'include'), '-c', SHARED / (name + '.c'), '-o', target)
        object_files.append(target)
    for name in ('extendhfsf2', 'truncsfhf2'):
        target = objects / (name + '.o')
        run(CLANG, *flags, '-DCOMPILER_RT_HAS_FLOAT16', '-c', compiler_sources / (name + '.c'), '-o', target)
        object_files.append(target)
    shim = PREFIX / 'lib/libSystemRust.dylib'
    archive = PREFIX / 'lib/libRustHostSupport.a'
    temporary_shim = shim.with_name(shim.name + '.tmp')
    run(CLANG, *flags, '-dynamiclib', '-Wl,-reexport_library,/usr/lib/libSystem.B.dylib',
        '-Wl,-compatibility_version,1.0.0', '-Wl,-install_name,@rpath/libSystemRust.dylib',
        *object_files, '-o', temporary_shim)
    publish(temporary_shim, shim)
    temporary_archive = archive.with_name(archive.name + '.tmp')
    if temporary_archive.exists():
        temporary_archive.unlink()
    run(AR, 'rcs', temporary_archive, *object_files)
    publish(temporary_archive, archive)

    # Two-level imports require a provider substitution; the host shim reexports
    # native libSystem while supplying the APIs and corrections absent on 10.9.
    bind_host_runtime(PREFIX, shim)
    run(PREFIX / 'bin/rustc', '--version')
    run(PREFIX / 'bin/cargo', '--version')

    smoke = PREFIX / 'host-check'
    if smoke.exists():
        shutil.rmtree(smoke)
    shutil.copytree(TOOLCHAIN / 'tests/rust-host', smoke)
    # This performs actual host compilation, build-script execution and loading
    # of a proc macro, rather than relying on rustc/cargo --version alone.
    environment = os.environ.copy()
    environment['RUSTC'] = str(PREFIX / 'bin/rustc')
    run(PREFIX / 'bin/cargo', 'build', '--offline', '--manifest-path', smoke / 'Cargo.toml', env=environment)
    run(smoke / 'target/debug/rust-host-smoke')
    write_stamp('.host-runtime', fingerprint)


if __name__ == '__main__':
    # A direct bootstrap and build_deps may run concurrently. Serialize prefix
    # installation and runtime publication, then let the waiter reuse stamps.
    PREFIX.mkdir(parents=True, exist_ok=True)
    with (PREFIX / '.bootstrap-lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
