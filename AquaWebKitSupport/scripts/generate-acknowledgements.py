#!/usr/bin/env python3
# generate-acknowledgements.py -- write the Acknowledgements file that accompanies a distributed
# build: AquaWebKitSupport/NOTICE, then the license text of everything the installed product contains.
#
#   AquaWebKitSupport/toolchain/build/python3/bin/python3 \
#       AquaWebKitSupport/scripts/generate-acknowledgements.py [output]
#
# The output defaults to WebKitBuild/Release/Acknowledgements.txt. The texts come from:
#   - this port: AquaWebKitSupport/LICENSE and the polyfill layer's shared/LICENSE and APSL-2.0.txt;
#   - WebKit: the license files under the Source/ directories the build compiles;
#   - LLVM: toolchain/vendor/clang/LICENSE.TXT, for the C++ runtime in JavaScriptCore.framework;
#   - each library deps/build_deps.sh fetches, read from its tarball in deps/work/tarballs, and for
#     each single file it fetches into the product, the license text it fetches beside that file;
#   - the Rust crates the closed-caption plug-in links, standard library included, found through
#     `cargo metadata` on its tree in deps/work/trees.
# It needs a completed deps build, and fails on anything it cannot find.

import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUPPORT = os.path.dirname(HERE)
REPO = os.path.dirname(SUPPORT)
DEPS = os.path.join(SUPPORT, 'deps')
TARBALLS = os.path.join(DEPS, 'work', 'tarballs')
TOOLCHAIN = os.path.join(SUPPORT, 'toolchain', 'build')

LICENSE_NAME = re.compile(r'^(COPYING|LICEN[CS]E|COPYRIGHT|NOTICE|PATENTS|UNLICENSE)', re.IGNORECASE)

# The libraries the product ships, by a pattern on their build_deps.sh URL, with any license file
# below the top of their tarball. Every URL in build_deps.sh must match one of these, SHIPPED_FILES,
# LICENSE_TEXTS or NOT_HERE.
SHIPPED = [
    ('ICU', r'/icu4c-', []),
    ('libgpg-error', r'/libgpg-error-', []),
    ('libgcrypt', r'/libgcrypt-', []),
    ('libtasn1', r'/libtasn1-', []),
    ('Brotli', r'/google/brotli/', []),
    ('WOFF2', r'/google/woff2/', []),
    ('OpenType Sanitizer', r'/ots-', []),
    ('libwebp', r'/libwebp-', []),
    ('libpng', r'/libpng-', []),
    ('libjpeg-turbo', r'/libjpeg-turbo-', ['README.ijg']),
    ('Little CMS', r'/lcms2-', []),
    ('LibTIFF', r'/tiff-', []),
    ('nghttp2', r'/nghttp2-', []),
    ('libpsl', r'/libpsl-', ['src/LICENSE.chromium']),
    ('Zstandard', r'/zstd-', []),
    ('curl', r'/curl-', []),
    ('GLib', r'/glib-', []),
    ('PCRE2', r'/pcre2-', []),
    ('GVDB', r'/gvdb/', []),
    ('libffi', r'/meson-ports/libffi/', []),
    ('proxy-libintl', r'/proxy-libintl/', []),
    ('ORC', r'/orc-', []),
    ('libogg', r'/libogg-', []),
    ('libvorbis', r'/libvorbis-', []),
    ('mpg123', r'/mpg123-', []),
    ('Opus', r'/opus-', []),
    ('FLAC', r'/flac-', []),
    ('libvpx', r'/webmproject/libvpx/', []),
    ('libxml2', r'/libxml2-', []),
    ('libxslt', r'/libxslt-', []),
    ('dav1d', r'/dav1d-', []),
    ('Fraunhofer FDK AAC', r'/mstorsjo/fdk-aac/', []),
    ('libavif', r'/libavif/', []),
    ('GStreamer', r'/gstreamer-', []),
    ('GStreamer Base Plugins', r'/gst-plugins-base-', []),
    ('GStreamer Good Plugins', r'/gst-plugins-good-', []),
    ('GStreamer Bad Plugins', r'/gst-plugins-bad-', []),
    ('GStreamer FFmpeg plug-in (gst-libav)', r'/gst-libav-', []),
    ('FFmpeg', r'/ffmpeg-', []),
    ('libheif', r'/libheif-', []),
    ('Readability', r'/@mozilla/readability/', []),
]
# The single files the product contains, by a pattern on their URL, with the name build_deps.sh caches
# their license text under in deps/work/tarballs.
SHIPPED_FILES = [
    ('Firefox Readerable.js', r'/toolkit/components/reader/Readerable\.js$', 'spdx-{MPL_TEXT_SPDX_RELEASE}-MPL-2.0.txt'),
    ('Chromium CDM interface headers', r'/chromium/cdm/', 'chromium-{CHROMIUM_LICENSE_TAG}-LICENSE'),
]
LICENSE_TEXTS = [r'/spdx/license-list-data/', r'/chromium/src/.*/LICENSE']
# Build tools, the layout tests' Apache, the zlib GLib finds on 10.9 instead, and the Meson build
# files of two subprojects; gst-plugins-rs is among the Rust crates.
NOT_HERE = [r'/pkgconf-', r'/bison-', r'/httpd-', r'/apr-', r'/zlib-', r'/gst-plugins-rs/', r'wrapdb\.mesonbuild\.com/']

# The WebKit directories the build compiles into the product, and what under them is not.
WEBKIT_DIRS = ['WTF', 'JavaScriptCore', 'WebCore', 'WebKit', 'WebKitLegacy', 'bmalloc',
               'ThirdParty/ANGLE', 'ThirdParty/libwebrtc']
WEBKIT_SKIP_DIRS = {'test', 'tests', 'testing', 'doc', 'docs', 'tool', 'tools', 'yasm', 'json'}
WEBKIT_SKIP_NAMES = re.compile(r'(^license_template\.txt$|\.(py|h|c|cc|cpp|gn|gni)$)')

RUST_PLUGIN = 'gst-plugin-closedcaption'


def fail(message):
    sys.exit('generate-acknowledgements: ' + message)


def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def build_deps_script():
    script = read(os.path.join(DEPS, 'build_deps.sh'))
    variables = dict(re.findall(r'^([A-Z][A-Z0-9_]*)=([^\s$"]+)$', script, re.MULTILINE))
    return script, variables


def build_deps_urls():
    script, variables = build_deps_script()
    urls = []
    for url in re.findall(r'https?://[^\s"]+', script):
        url = url.replace('${GLIB_VER%.*}', variables['GLIB_VER'].rsplit('.', 1)[0])
        for name, value in sorted(variables.items(), key=lambda item: -len(item[0])):
            url = url.replace('${%s}' % name, value).replace('$' + name, value)
        if url not in urls:
            urls.append(url)
    return urls


def is_tarball(url):
    return re.search(r'\.(tar\.(gz|xz|bz2)|tgz)$', url)


def cached_tarball(url):
    # build_deps.sh's get() caches by basename, fetch_cached() by a prefix of the URL's SHA-1.
    plain = os.path.join(TARBALLS, os.path.basename(url))
    if os.path.isfile(plain):
        return plain
    prefix = hashlib.sha1(url.encode()).hexdigest()[:12] + '-'
    for name in sorted(os.listdir(TARBALLS)):
        if name.startswith(prefix):
            return os.path.join(TARBALLS, name)
    fail('no tarball for %s in %s; run AquaWebKitSupport/deps/build_deps.sh' % (url, TARBALLS))


def tarball_licenses(path, extras):
    # The system tar, as build_deps.sh unpacks with: it reads every compression the tarballs use.
    names = subprocess.check_output(['tar', '-tf', path]).decode('utf-8', 'replace').splitlines()
    texts = []
    for name in sorted(n for n in names if not n.endswith('/')):
        parts = name.split('/')[1:]
        if not parts:
            continue
        relative = '/'.join(parts)
        if (len(parts) == 1 and LICENSE_NAME.match(parts[0])) \
                or (len(parts) == 2 and parts[0] == 'LICENSES') or relative in extras:
            texts.append((relative, subprocess.check_output(['tar', '-xOf', path, name]).decode('utf-8', 'replace')))
            if relative in extras:
                extras = [e for e in extras if e != relative]
    if extras:
        fail('%s has no %s' % (path, ', '.join(extras)))
    if not texts:
        fail('%s has no license file' % path)
    return texts


def third_party_sections():
    _, variables = build_deps_script()
    found = {}
    for url in build_deps_urls():
        if any(re.search(pattern, url) for pattern in NOT_HERE + LICENSE_TEXTS):
            continue
        matches = [entry for entry in SHIPPED if is_tarball(url) and re.search(entry[1], url)]
        if matches:
            name, _, extras = matches[0]
            if name not in found:
                found[name] = tarball_licenses(cached_tarball(url), list(extras))
            continue
        matches = [entry for entry in SHIPPED_FILES if re.search(entry[1], url)]
        if not matches:
            fail('%s matches nothing in SHIPPED, SHIPPED_FILES, LICENSE_TEXTS or NOT_HERE' % url)
        name, _, license_name = matches[0]
        if name not in found:
            path = os.path.join(TARBALLS, license_name.format(**variables))
            if not os.path.isfile(path):
                fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
            found[name] = [(os.path.basename(path), read(path))]
    entries = SHIPPED + SHIPPED_FILES
    missing = [entry[0] for entry in entries if entry[0] not in found]
    if missing:
        fail('no build_deps.sh URL for ' + ', '.join(missing))
    return [(name, found[name]) for name, _, _ in entries]


def webkit_sections():
    texts = []
    source = os.path.join(REPO, 'Source')
    for top in WEBKIT_DIRS:
        for directory, subdirectories, files in os.walk(os.path.join(source, top)):
            subdirectories[:] = sorted(d for d in subdirectories
                                       if d not in WEBKIT_SKIP_DIRS and not d.startswith(('fuzz', 'example')))
            for name in sorted(files):
                if LICENSE_NAME.match(name) and not WEBKIT_SKIP_NAMES.search(name):
                    path = os.path.join(directory, name)
                    texts.append((os.path.relpath(path, source), read(path)))
    return [('WebKit', texts)]


def rust_license_files(directory):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    return [os.path.join(directory, n) for n in names
            if LICENSE_NAME.match(n) and os.path.isfile(os.path.join(directory, n))]


def rust_crates(cargo, manifest, roots, cargo_args, fallback, environment):
    # The roots and every crate they reach through normal dependencies, short of proc-macro crates,
    # which run in the compiler and link into nothing. A crate's license files are those in its
    # package directory, else in the nearest enclosing one up to its workspace root, else, inside
    # the workspace, those in `fallback`.
    metadata = json.loads(subprocess.check_output(
        [cargo, 'metadata', '--format-version', '1', '--locked', '--manifest-path', manifest,
         '--filter-platform', 'x86_64-apple-darwin'] + cargo_args,
        cwd=os.path.dirname(manifest), env=environment))
    packages = {p['id']: p for p in metadata['packages']}
    nodes = {n['id']: n for n in metadata['resolve']['nodes']}
    workspace_root = os.path.realpath(metadata['workspace_root'])
    pending = [i for i, p in packages.items() if p['name'] in roots and i in nodes]
    reached = set()
    while pending:
        node = nodes[pending.pop()]
        package = packages[node['id']]
        if node['id'] in reached or any('proc-macro' in t['kind'] for t in package['targets']):
            continue
        reached.add(node['id'])
        pending += [d['pkg'] for d in node['deps'] if any(k['kind'] is None for k in d['dep_kinds'])]
    sections = []
    for package in sorted((packages[i] for i in reached), key=lambda p: (p['name'], p['version'])):
        directory = os.path.realpath(os.path.dirname(package['manifest_path']))
        in_workspace = directory.startswith(workspace_root + os.sep)
        files = rust_license_files(directory)
        while not files and directory.startswith(workspace_root + os.sep):
            directory = os.path.dirname(directory)
            files = rust_license_files(directory)
        if not files and in_workspace:
            files = fallback
        if not files:
            fail('no license file for Rust crate %s %s' % (package['name'], package['version']))
        title = 'Rust crate %s %s (%s)' % (package['name'], package['version'],
                                           package.get('license') or 'license unstated')
        sections.append((title, [(os.path.basename(f), read(f)) for f in files]))
    return sections


def rust_sections():
    tree = os.path.join(DEPS, 'work', 'trees', 'build-gstclosedcaption')
    cargo = os.path.join(TOOLCHAIN, 'rust', 'bin', 'cargo')
    rustc = os.path.join(TOOLCHAIN, 'rust-mavericks', 'bin', 'rustc')
    for path in (tree, cargo, rustc):
        if not os.path.exists(path):
            fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
    environment = dict(os.environ, CARGO_HOME=os.path.join(TOOLCHAIN, 'rust', 'cargo-home'), RUSTC=rustc)
    fallback = rust_license_files(os.path.join(TOOLCHAIN, 'rust-bootstrap', 'rustc-nightly-src'))
    if not fallback:
        fail('no Rust source license files under %s' % os.path.join(TOOLCHAIN, 'rust-bootstrap'))
    sysroot = subprocess.check_output([rustc, '--print', 'sysroot'], env=environment).decode().strip()
    plugin = rust_crates(cargo, os.path.join(tree, 'video', 'closedcaption', 'Cargo.toml'), [RUST_PLUGIN],
                         ['--no-default-features'], [], environment)
    std = rust_crates(cargo, os.path.join(sysroot, 'lib', 'rustlib', 'src', 'rust', 'library', 'Cargo.toml'),
                      ['std', 'panic_unwind'], [], fallback, environment)
    seen = {title for title, _ in plugin}
    return plugin + [section for section in std if section[0] not in seen]


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, 'WebKitBuild', 'Release', 'Acknowledgements.txt')
    shared = os.path.join(SUPPORT, 'polyfill', 'polyfills', 'shared')
    sections = [('Aqua WebKit', [('AquaWebKitSupport/LICENSE', read(os.path.join(SUPPORT, 'LICENSE')))]),
                ('Polyfill layer (MacPorts legacy support)', [('LICENSE', read(os.path.join(shared, 'LICENSE'))),
                                                              ('APSL-2.0.txt', read(os.path.join(shared, 'APSL-2.0.txt')))])]
    sections += webkit_sections()
    sections.append(('LLVM C++ runtime (libc++, libc++abi)',
                     [('LICENSE.TXT', read(os.path.join(SUPPORT, 'toolchain', 'vendor', 'clang', 'LICENSE.TXT')))]))
    sections += third_party_sections()
    sections += rust_sections()

    rule = '=' * 78
    out = [read(os.path.join(SUPPORT, 'NOTICE')).rstrip('\n')]
    first_seen = {}
    for title, texts in sections:
        for label, text in texts:
            heading = '%s -- %s' % (title, label)
            digest = hashlib.sha256(text.encode()).hexdigest()
            body = text.rstrip('\n') if digest not in first_seen else '(The same text as "%s".)' % first_seen[digest]
            first_seen.setdefault(digest, heading)
            out += ['', rule, heading, rule, '', body]
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote %s (%d license texts)' % (output, sum(len(t) for _, t in sections)))


if __name__ == '__main__':
    main()
