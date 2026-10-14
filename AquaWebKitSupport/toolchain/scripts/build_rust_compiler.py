#!/usr/bin/env python3
"""Build the pinned compiler with the Mavericks deployment floor."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

import build_rust as host

WORK = host.WORK
SOURCE = WORK / 'rustc-nightly-src'
LLVM = WORK / 'rust-dev-nightly-x86_64-apple-darwin/rust-dev'
BUILD = WORK / 'compiler-build'
STAGE = BUILD / 'x86_64-apple-darwin/stage1'
COMPILER_PREFIX = host.TOOLCHAIN / 'build/rust-mavericks'
PATCH = host.TOOLCHAIN / 'patches/rust-macos-deployment-floor.patch'
INPUTS = host.INPUTS['source_compiler']


def prepare():
    identity = hashlib.sha256((json.dumps(INPUTS, sort_keys=True) + host.digest(PATCH)).encode()).hexdigest()
    marker = WORK / '.compiler-source'
    if marker.exists() and marker.read_text() == identity:
        return
    for kind in ('source', 'llvm'):
        item = INPUTS[kind]
        archive = host.DOWNLOADS / item['name']
        host.fetch(item['url'], archive)
        # The matching prebuilt LLVM supplies headers, libraries and tools.
        # Excluding its unused source avoids over a gigabyte of extra storage.
        arguments = ['tar', '-xJf', archive, '-C', WORK]
        if kind == 'source':
            arguments += ['--exclude', 'rustc-nightly-src/src/llvm-project']
        host.run(*arguments)
    host.run('patch', '--batch', '-p1', '-i', PATCH, cwd=SOURCE)
    # llvm-strip is the upstream llvm-objcopy multi-call executable. The CI
    # rust-dev component omits this symlink; external-LLVM bootstrap expects it.
    strip = LLVM / 'bin/llvm-strip'
    if not strip.exists():
        strip.symlink_to('llvm-objcopy')
    marker.write_text(identity)


def configuration():
    settings = '''change-id = "ignore"
[build]
submodules = false
vendor = true
jobs = 4
docs = false
optimized-compiler-builtins = false
build = "x86_64-apple-darwin"
host = ["x86_64-apple-darwin"]
target = ["x86_64-apple-darwin"]
'''
    for name, path in [('build-dir', BUILD), ('rustc', host.PREFIX / 'bin/rustc'),
                       ('cargo', host.PREFIX / 'bin/cargo'), ('rustdoc', host.PREFIX / 'bin/rustdoc')]:
        settings += name + ' = ' + json.dumps(str(path)) + '\n'
    settings += '''[llvm]
download-ci-llvm = false
link-shared = true
[rust]
download-rustc = false
channel = "nightly"
optimize = 2
debug = false
debuginfo-level = 0
incremental = false
lto = "off"
[target.x86_64-apple-darwin]
llvm-has-rust-patches = true
'''
    for name, path in [('llvm-config', LLVM / 'bin/llvm-config'), ('cc', host.CLANG),
                       ('cxx', host.CLANG.with_name('clang++')), ('linker', host.CLANG),
                       ('ar', host.AR), ('ranlib', host.AR.with_name('llvm-ranlib'))]:
        settings += name + ' = ' + json.dumps(str(path)) + '\n'
    return settings


def bind_runtime(root, shim):
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\xcf\xfa\xed\xfe':
                continue
        if '\t@rpath/libLLVM.dylib (' not in host.output(host.OTOOL, '-L', path):
            continue
        paths = re.findall(r'^\s*path (.*?) \(offset \d+\)$', host.output(host.OTOOL, '-l', path), re.MULTILINE)
        if str(LLVM / 'lib') not in paths:
            host.run(host.INSTALL_NAME_TOOL, '-add_rpath', LLVM / 'lib', path)
    host.bind_host_runtime(root, shim, prefer_native=True)


def main():
    prepare()
    shim = host.PREFIX / 'lib/libSystemRust.dylib'
    archive = host.PREFIX / 'lib/libRustHostSupport.a'
    wrapper = host.SCRIPTS / 'rustc-wrapper.sh'
    bind_runtime(LLVM, shim)
    settings = configuration()
    build_identity = hashlib.sha256()
    for value in (settings, host.digest(PATCH), host.digest(archive), host.digest(wrapper),
                  json.dumps(INPUTS, sort_keys=True)):
        build_identity.update(value.encode())
    build_fingerprint = build_identity.hexdigest()
    identity = hashlib.sha256()
    for value in (build_fingerprint, host.digest(Path(__file__))):
        identity.update(value.encode())
    fingerprint = identity.hexdigest()
    stamp = WORK / '.compiler-built'
    compiler_exists = (STAGE / 'bin/rustc').is_file()
    host_libraries = STAGE / 'lib/rustlib/x86_64-apple-darwin/lib'
    host_std_exists = all(any(host_libraries.glob('lib' + name + '-*.rlib')) for name in ('std', 'core', 'proc_macro'))
    selected_stage = COMPILER_PREFIX.is_symlink() and COMPILER_PREFIX.resolve() == STAGE.resolve()
    if not stamp.exists() or stamp.read_text() != fingerprint or not compiler_exists or not host_std_exists or not selected_stage:
        # x.py delegates to our wrapper through RUSTC_WRAPPER_REAL. Cargo sees
        # x.py's wrapper path, so its host artifacts need our own input identity.
        build_stamp = WORK / '.compiler-build-inputs'
        if not build_stamp.exists() or build_stamp.read_text() != build_fingerprint:
            if BUILD.exists():
                shutil.rmtree(BUILD)
            build_stamp.write_text(build_fingerprint)
        (SOURCE / 'bootstrap.toml').write_text(settings)
        environment = os.environ.copy()
        sdk = Path(os.environ.get('AQUAWEBKIT_SDK', host.REPO.parent / 'MacOSX26.1.sdk'))
        environment['PATH'] = ':'.join(str(host.TOOLCHAIN / ('build/' + tool + '/bin'))
                                       for tool in ('python3', 'ninja', 'cmake', 'clang')) + ':' + environment['PATH']
        # This compiler is a host tool built by the prebuilt 10.12 compiler.
        environment['MACOSX_DEPLOYMENT_TARGET'] = '10.12'
        flags = ['-C', 'linker=' + str(host.CLANG), '-C', 'link-arg=--no-default-config',
                 '-C', 'link-arg=-fuse-ld=lld', '-C', 'link-arg=-isysroot', '-C', 'link-arg=' + str(sdk),
                 '-C', 'link-arg=-mmacosx-version-min=10.9',
                 '-C', 'link-arg=-Wl,-rpath,' + str(LLVM / 'lib'),
                 '-C', 'link-arg=-Wl,-force_load,' + str(archive),
                 '-Cmetadata=mavericks-host-' + host.digest(archive)]
        environment['RUSTFLAGS'] = ' '.join(flags)
        environment['CFLAGS'] = '--no-default-config -isysroot ' + str(sdk) + ' -mmacosx-version-min=10.9'
        environment['CXXFLAGS'] = environment['CFLAGS']
        environment['CARGO_PROFILE_DEV_DEBUG'] = '0'
        environment['CARGO_PROFILE_DEV_INCREMENTAL'] = 'false'
        environment['RUSTC'] = str(host.PREFIX / 'bin/rustc')
        environment['RUSTC_WRAPPER'] = str(wrapper)
        host.run(host.TOOLCHAIN / 'build/python3/bin/python3', 'x.py', 'build', '--stage', '1',
                 'compiler/rustc', cwd=SOURCE, env=environment)
        bind_runtime(STAGE, shim)
        host.run(host.TOOLCHAIN / 'build/python3/bin/python3', 'x.py', 'build', '--stage', '1',
                 'library', cwd=SOURCE, env=environment)
        bind_runtime(STAGE, shim)
        # Cargo -Zbuild-std expects source under the compiler's actual sysroot.
        rust_sources = STAGE / 'lib/rustlib/src/rust'
        rust_sources.parent.mkdir(parents=True, exist_ok=True)
        if not rust_sources.exists():
            rust_sources.symlink_to(os.path.relpath(host.PREFIX / 'lib/rustlib/src/rust', rust_sources.parent))
        if COMPILER_PREFIX.is_symlink():
            COMPILER_PREFIX.unlink()
        elif COMPILER_PREFIX.exists():
            raise RuntimeError('Compiler prefix conflicts with an existing directory: ' + str(COMPILER_PREFIX))
        COMPILER_PREFIX.symlink_to(os.path.relpath(STAGE, COMPILER_PREFIX.parent))
        stamp.write_text(fingerprint)
    else:
        print('### Mavericks source compiler is current', flush=True)


if __name__ == '__main__':
    WORK.mkdir(parents=True, exist_ok=True)
    host.PREFIX.mkdir(parents=True, exist_ok=True)
    # Compiler construction consumes the host runtime for its entire duration.
    # Use the host bootstrap's lock to keep that prefix immutable as well.
    with (host.PREFIX / '.bootstrap-lock').open('a') as host_lock:
        fcntl.flock(host_lock, fcntl.LOCK_EX)
        with (WORK / '.compiler-lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            main()
