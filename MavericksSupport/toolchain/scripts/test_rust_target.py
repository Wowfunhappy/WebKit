#!/usr/bin/env python3
"""Exercise the rebuilt target standard library after deps publishes its gap archive."""
import hashlib
import os
from pathlib import Path
import shutil

import build_rust as host


def main():
    fixture = host.TOOLCHAIN / 'tests/rust-target'
    work = host.WORK / 'target-check'
    compiler = host.TOOLCHAIN / 'build/rust-mavericks/bin/rustc'
    archive = host.REPO / 'MavericksSupport/deps/work/trees/gap/libmavericks_gap.a'
    if not compiler.is_file() or not archive.is_file():
        raise RuntimeError('Build the Mavericks Rust compiler and dependency gap archive first')
    work.mkdir(parents=True, exist_ok=True)
    for source in fixture.rglob('*'):
        if source.is_file():
            target = work / source.relative_to(fixture)
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or source.read_bytes() != target.read_bytes():
                shutil.copy2(source, target)
    environment = os.environ.copy()
    environment['RUSTC'] = str(compiler)
    environment['RUSTC_WRAPPER'] = str(host.SCRIPTS / 'rustc-wrapper.sh')
    environment['CARGO_HOME'] = str(host.PREFIX / 'cargo-home')
    environment['MACOSX_DEPLOYMENT_TARGET'] = '10.9'
    sdk = Path(environment.get('MAVERICKS_SDK', host.REPO.parent / 'MacOSX26.1.sdk'))
    key = hashlib.sha256((host.digest(archive) + (host.WORK / '.compiler-verified').read_text()).encode()).hexdigest()
    flags = ['-C', 'linker=' + str(host.CLANG), '-C', 'link-arg=--no-default-config',
             '-C', 'link-arg=-fuse-ld=lld', '-C', 'link-arg=-isysroot', '-C', 'link-arg=' + str(sdk),
             '-C', 'link-arg=-mmacosx-version-min=10.9', '-C', 'link-arg=-Wl,-force_load,' + str(archive),
             '-C', 'link-arg=-framework', '-C', 'link-arg=CoreFoundation', '-Cmetadata=mavericks-target-' + key]
    environment.pop('RUSTFLAGS', None)
    environment['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(flags)
    host.run(host.PREFIX / 'bin/cargo', 'build', '--offline', '--release', '--lib',
             '--manifest-path', work / 'Cargo.toml', '--target=x86_64-apple-darwin',
             '-Zbuild-std=std,panic_unwind', env=environment)
    library = work / 'target/x86_64-apple-darwin/release/librust_target_smoke.dylib'
    host.verify_deployment(library)
    host.run(host.NM, '-um', library)
    loader = work / 'load'
    host.run(host.CLANG, '--no-default-config', '-isysroot', '/', '-mmacosx-version-min=10.9',
             fixture / 'load.c', '-o', loader)
    host.run(loader, library)


if __name__ == '__main__':
    main()
