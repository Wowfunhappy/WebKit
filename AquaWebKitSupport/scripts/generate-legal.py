#!/usr/bin/env python3
# generate-legal.py -- write the Legal file that accompanies a distributed build:
# AquaWebKitSupport/NOTICE, then the license text of everything the installed product contains.
#
#   AquaWebKitSupport/toolchain/build/python3/bin/python3 \
#       AquaWebKitSupport/scripts/generate-legal.py [output]
#
# The output defaults to WebKitBuild/Release/Legal.txt. Every Mach-O image of the staged product is
# traced, by its UUID, to the build that linked it: a ninja build (WebKit's, or one in
# deps/work/trees), a make build in deps/work/trees, a link deps/build_deps.sh records, the polyfill
# build, or a Rust target; the stock OS X 10.9.5 i386 slices of the images the NOTICE names are
# traced to the stock binaries. From the build, the image is traced to the sources and headers it
# compiled, through ninja's deps logs, make depfiles, the polyfill build's source records and, for
# the trees deps/build_deps.sh deletes, the manifests scripts/compiled_sources.py writes; a file
# JavaScriptCore's builtins generator writes is traced to the files the generator reads. Each archive
# a link names is traced the same way, by the content of its members. Every other staged file is
# traced to the files it comes from (Resources), which count as compiled files of the images that
# carry it; a file of a stock framework the NOTICE names adds its notices to the stock code's. The
# texts are then:
#   - this port: AquaWebKitSupport/LICENSE and the polyfill layer's shared/LICENSE and APSL-2.0.txt;
#   - WebKit: the license files in the Source/ directories that hold a compiled file;
#   - the stock i386 slices: the license files of the release they were built from, the repository's
#     STOCK_TAG;
#   - each library deps/build_deps.sh fetches, read from its tarball in deps/work/tarballs, and for
#     each single file it fetches into the product, the license text it fetches beside that file;
#   - the notices compiled files open with that their section's texts do not already carry, and the
#     SPDX license list's text of a GNU license such a notice names that its library does not carry;
#   - the Rust crates the closed-caption plug-in and the PDF library link, standard library included
#     with the features those builds compiled it with, found through `cargo metadata`, and the notices
#     the Rust source tree's license-metadata.json gives for the library/ sources they compiled.
# A compiled file under the GPL alone must be in an image the NOTICE's GPL sentence names, and what the
# NOTICE quotes must be a heading's title or label. It needs a completed build and deps build, and fails
# on anything it cannot trace or place.

import functools
import glob
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compiled_sources  # noqa: E402

SUPPORT = os.path.dirname(HERE)
REPO = os.path.dirname(SUPPORT)
SOURCE = os.path.join(REPO, 'Source')
BUILD = os.path.join(REPO, 'WebKitBuild', 'Release')
STAGED = os.path.join(BUILD, 'staged')
DEPS = os.path.join(SUPPORT, 'deps')
TARBALLS = os.path.join(DEPS, 'work', 'tarballs')
TREES = os.path.join(DEPS, 'work', 'trees')
MANIFESTS = os.path.join(TREES, 'manifests')
LINKS = os.path.join(TREES, 'links')
STAGE = os.path.join(TREES, 'install')
TOOLCHAIN = os.path.join(SUPPORT, 'toolchain', 'build')
POLYFILL_BUILD = os.path.join(SUPPORT, 'polyfill', 'build')
SHARED = os.path.join(SUPPORT, 'polyfill', 'polyfills', 'shared')
SDK = os.path.join(os.path.dirname(REPO), 'MacOSX26.1.sdk')
# Stock OS X 10.9.5's WebKit binaries, whose i386 slices staging grafts into the product (the
# directory scripts/framework-layout.sh names by default), and the tag of the WebKit release they were
# built from.
STOCK = os.path.join(os.path.dirname(REPO), 'stock-webkit-backup')
STOCK_TAG = 'Safari-537.78.2'
STOCK_TITLE = 'OS X 10.9.5 WebKit (32-bit code)'
CPU_I386 = 7

# The line between sections. No license text contains it.
RULE = '~' * 78
AQUA = 'Aqua WebKit'
POLYFILL = 'Polyfill layer (MacPorts legacy support)'

# License texts by name; a .json of that name is machine-readable license data.
LICENSE_NAME = re.compile(r'^((COPYING|LICEN[CS]E|COPYRIGHT|NOTICE|PATENTS|UNLICENSE)(?!.*\.json$)'
                          r'|[\w-]+\.LICEN[CS]E$)', re.IGNORECASE)
SPDX_OPERATORS = {'AND', 'OR', 'WITH'}

# The libraries the product ships, by a pattern on their build_deps.sh URL, with any file of their
# tarball whose name does not mark it a license text that is one. Every URL in build_deps.sh must match
# one of these, SHIPPED_FILES, LICENSE_TEXTS, PART_OF or NOT_HERE.
SHIPPED = [
    ('LLVM runtime libraries (libc++, libc++abi, libc, libunwind)', r'/llvm/llvm-project/', []),
    ('ICU', r'/apple-oss-distributions/ICU/', []),
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
    ('libpsl', r'/libpsl-', []),
    ('zlib', r'/madler/zlib/', []),
    ('bzip2', r'/bzip2-', []),
    ('Zstandard', r'/zstd-', []),
    ('curl', r'/curl-', []),
    ('GLib', r'/glib-', []),
    ('PCRE2', r'/pcre2-', []),
    ('libffi', r'/libffi/libffi/', []),
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
    ('x264', r'/videolan/x264/', []),
    ('Fraunhofer FDK AAC', r'/mstorsjo/fdk-aac/', []),
    ('libavif', r'/libavif/', []),
    ('libjxl', r'/libjxl/libjxl/', []),
    ('Highway', r'/google/highway/', []),
    ('GStreamer', r'/gstreamer-', []),
    ('GStreamer Base Plugins', r'/gst-plugins-base-', []),
    ('GStreamer Good Plugins', r'/gst-plugins-good-', []),
    ('GStreamer Bad Plugins', r'/gst-plugins-bad-', []),
    ('GStreamer Ugly Plugins', r'/gst-plugins-ugly-', []),
    ('GStreamer FFmpeg plug-in (gst-libav)', r'/gst-libav-', []),
    ('GStreamer RTSP Server', r'/gst-rtsp-server-', []),
    ('FFmpeg', r'/ffmpeg-', []),
    ('libheif', r'/libheif-', []),
    ('Readability', r'/@mozilla/readability/', []),
]
# Top-level license files of a library above that cover none of what it ships, as its README states.
# Each is checked against the library's compiled sources: none may need the license it carries. A
# compiled file that offers a choice of licenses and takes that one brings it back.
NOT_GOVERNING = {
    'libgpg-error': {'COPYING': 'GPL; build scripts whose output the library carries under the LGPL'},
    'libgcrypt': {'COPYING': 'GPL; the helper programs and the documentation'},
    'libtasn1': {'COPYING': 'GPL; the tools, tests and examples'},
    'libffi': {'LICENSE-BUILDTOOLS': 'GPL; the build and test tools'},
    'FLAC': {'COPYING.GPL': 'the programs and plug-ins', 'COPYING.LGPL': 'the programs and plug-ins',
             'COPYING.FDL': 'the documentation'},
    'Zstandard': {'COPYING': 'GPL; the alternative to the BSD license under LICENSE'},
}
# FFmpeg's license texts, by the license its configure selected (config.h's FFMPEG_LICENSE).
FFMPEG_LICENSES = {'LGPL version 2.1 or later': ['COPYING.LGPLv2.1'],
                   'LGPL version 3 or later': ['COPYING.LGPLv3', 'COPYING.GPLv3'],
                   'GPL version 2 or later': ['COPYING.GPLv2'],
                   'GPL version 3 or later': ['COPYING.GPLv3']}
# Libraries whose LICENSES/ directory also covers files they do not ship; the SPDX identifiers their
# compiled sources name pick the texts that apply.
REUSE = {'GLib'}
# The single files the product contains, by a pattern on their URL, with the name build_deps.sh caches
# their license text under in deps/work/tarballs, the text's name, and the names build_deps.sh caches
# the files under there.
SHIPPED_FILES = [
    ('SQLite', r'/sqlite-autoconf-', 'sqlite-{SQLITE_VERSION}-LICENSE.md', 'LICENSE.md', None),
    ('Firefox Readerable.js', r'/toolkit/components/reader/Readerable\.js$', 'spdx-{SPDX_RELEASE}-MPL-2.0.txt',
     'Mozilla Public License 2.0', 'firefox-Readerable-*.js'),
    ('Chromium CDM interface headers', r'/chromium/cdm/', 'chromium-{CHROMIUM_LICENSE_TAG}-LICENSE', 'Chromium LICENSE',
     'cdm-{CDM_API_REV}-*'),
]
# Files compiled into a library above, under the license text that library's section carries: ICU's
# time zone update, whose terms are ICU's LICENSE.
PART_OF = [r'/unicode-org/icu-data/']
LICENSE_TEXTS = [r'/spdx/license-list-data/', r'/chromium/src/.*/LICENSE', r'/v8/v8/.*/LICENSE',
                 r'/dart-lang/sdk/.*/LICENSE$', r'/golang/go/.*/LICENSE$', r'/sqlite/sqlite/.*/LICENSE\.md$']
# Build tools, the layout tests' Apache and the PCRE2 it links, and the Meson build files of two
# subprojects; gst-plugins-rs is among the Rust crates.
NOT_HERE = [r'/pkgconf-', r'/bison-', r'/httpd-', r'/apr-', r'/PhilipHazel/pcre2/', r'/gst-plugins-rs/',
            r'wrapdb\.mesonbuild\.com/']

# Files that only name another license file, by section and label, with the file they name.
# WebRTC's third-party code carries its license files in its own directories, and webrtc/ has no
# LICENSE_THIRD_PARTY.
POINTERS = {
    ('WebKit', 'ThirdParty/libwebrtc/Source/LICENSE'): 'ThirdParty/libwebrtc/Source/webrtc/LICENSE',
    ('WebKit', 'ThirdParty/libwebrtc/Source/PATENTS'): 'ThirdParty/libwebrtc/Source/webrtc/PATENTS',
    ('WebKit', 'ThirdParty/libwebrtc/Source/LICENSE_THIRD_PARTY'): None,
    ('PCRE2', 'COPYING'): 'LICENCE.md',
}

# License files of projects whose code a section's files carry, which those files' notices name and
# the section's tree lacks, by section, with the name build_deps.sh caches each under and the text's
# name: V8's, for the code JavaScriptCore and WTF take from V8; Chromium's, for the code ANGLE and
# libwebrtc's third-party directories take from Chromium; Dart's and Go's, for JSBigInt.cpp's; and the
# PSF License Agreement, for the code StableSort.h takes from CPython. Each must carry or be named by
# a notice.
UPSTREAM_TEXTS = [
    ('WebKit', 'v8-{V8_LICENSE_TAG}-LICENSE', 'V8 LICENSE'),
    ('WebKit', 'chromium-{CHROMIUM_LICENSE_TAG}-LICENSE', 'Chromium LICENSE'),
    ('WebKit', 'dart-{DART_LICENSE_TAG}-LICENSE', 'Dart LICENSE'),
    ('WebKit', 'go-{GO_LICENSE_TAG}-LICENSE', 'Go LICENSE'),
    ('WebKit', 'spdx-{SPDX_RELEASE}-PSF-2.0.txt', 'Python Software Foundation License 2.0'),
]
# The licenses notices name by an SPDX identifier, a name or a URL, as (SPDX identifier, how a notice
# names it, how its text reads, its name). A notice that names one finds its text in its section,
# else in the SPDX license list's text build_deps.sh caches as spdx-<SPDX_RELEASE>-<identifier>.txt.
STANDARD_LICENSES = [
    ('Apache-2.0', r'apache license,? v(ersion)? ?2\.0|apache-2\.0|apache\.org/licenses/license-2\.0',
     r'apache license version 2\.0, january 2004', 'Apache License 2.0'),
    ('MIT', r'(?-i:\bMIT\b)', r'permission is hereby granted, free of charge, to any person obtaining a copy',
     'MIT License'),
    ('BSD-2-Clause', r'bsd[- ]2[- ]clause', r'redistribution and use in source and binary forms',
     'BSD 2-Clause License'),
    ('BSD-3-Clause', r'bsd[- ]3[- ]clause', r'redistribution and use in source and binary forms.*neither the name',
     'BSD 3-Clause License'),
    ('ISC', r'(?-i:\bISC\b)', r'permission to use, copy, modify, and(/or)? distribute this software for any purpose',
     'ISC License'),
    ('BSL-1.0', r'bsl-1\.0|boost software license|license_1_0\.txt', r'boost software license - version 1\.0',
     'Boost Software License 1.0'),
    ('MPL-2.0', r'mpl-2\.0|mozilla\.org/mpl/2\.0', r'mozilla public license version 2\.0',
     'Mozilla Public License 2.0'),
    ('MPL-1.1', r'\bmpl[- ]1\.1\b|mozilla\s+public\s+license,?\s+(version\s+|v\.\s*)1\.1\b',
     r'mozilla public license version 1\.1 1\. definitions', 'Mozilla Public License 1.1'),
    ('Unicode-3.0', r'unicode\.org/copyright\.html|unicode-3\.0|unicode-dfs',
     r'unicode license v3|unicode, inc\. license agreement', 'Unicode License v3'),
    ('ICU', r'\bicu license\b', r'icu license - icu 1\.8\.1', 'ICU License'),
    ('APSL-2.0', r'opensource\.apple\.com/apsl|apple public source license',
     r'apple public source license version 2\.0 - august', 'Apple Public Source License 2.0'),
    ('curl', r'spdx-license-identifier:[^\n]*\bcurl\b',
     r'copyright and permission notice copyright \(c\) [^.]*daniel stenberg', 'curl License'),
    ('CC0-1.0', r'\bcc0\b', r'cc0 1\.0 universal.*statement of purpose', 'CC0 1.0 Universal'),
]
# The GNU licenses a notice offers or states whose text neither its section nor its library carries,
# as the SPDX identifier of the text build_deps.sh caches and its heading.
GNU_TEXTS = [('GPL-2.0-only', 'GNU General Public License, version 2')]
# A license text's lines that hold template fields in place of a copyright notice's.
TEMPLATE = re.compile(r'<(year|owner|copyright holders?|name of author)>|\[(yyyy|name of copyright owner)\]',
                      re.IGNORECASE)

# Trees in deps/work/trees that are a copy of WebKit's source, by the Source/ directory each copies
# (BoringSSL, patched for curl and WebCore's libssl and libcrypto).
SOURCE_COPIES = {'boringssl-src': 'ThirdParty/libwebrtc/Source/third_party/boringssl/src'}
# Names a license-file pattern matches that are not license texts.
NOT_LICENSE_TEXTS = re.compile(r'(^license_template\.txt$|\.(py|h|c|cc|cpp|gn|gni|dat|dict)$)')
# Directories of deps/work/trees that hold no build.
NOT_TREES = {'install', 'manifests', 'links', 'stamps', 'tools', 'mesonenv', 'vanilla-bin', 'run', 'httpd-install'}

RUST_PLUGIN = 'gst-plugin-closedcaption'
# The PDF library's crate, under the Aqua WebKit section's license.
PDF_CRATE = os.path.join(SUPPORT, 'source', 'WebCore', 'platform', 'graphics', 'hayro')
PDF_CRATE_NAME = 'wk_pdf'
# The Cargo target directories of the closed-caption plug-in and the PDF library.
RUST_TARGETS = [os.path.join(TREES, 'build-gstclosedcaption', 'target'), os.path.join(TREES, 'build-wk-pdf', 'target')]
# Crates published without their repository's license file, by the crate published from the same
# repository that carries it.
RUST_LICENSE_FROM = {'alloc-stdlib': 'alloc-no-stdlib'}

# Phrases of a notice that grants permission on conditions, which a binary's documentation repeats,
# matched in whitespace-normalized text.
GRANT = re.compile(r'redistribution and (use|modification)|permission is hereby granted|permission to use,? copy|'
                   r'permission is granted to anyone|permission to copy, use|hereby granted,? free of charge|'
                   r'(is|are) permitted,? provided that|you may use,? copy', re.IGNORECASE)
# A copyright line, which a file's name or a dash may open ("tramp.c - Copyright (c) 2020 ...").
NAMED_BY = r'(([\w.+/-]+\s+)?-\s+)?'
COPYRIGHT_LINE = re.compile(r'^\s*' + NAMED_BY + r'(portions\s+)?(copyright\b|\(c\)\s|©|spdx-filecopyrighttext:)',
                            re.IGNORECASE)
# What makes a comment a notice.
NOTICE = re.compile(r'copyright|spdx-license-identifier|redistribute it|free software', re.IGNORECASE)
# Words of a notice that points at its license.
REFERENCE = re.compile(r'licen[cs]|public domain|SPDX-License-Identifier|\b(?-i:COPYING)\b|'
                       r'conditions of (distribution|use)|'
                       r'terms of use', re.IGNORECASE)
# Words of a comment's paragraph that states license terms or points at them, and words of the
# paragraphs that continue such terms.
TERMS = re.compile(GRANT.pattern + '|' + REFERENCE.pattern + r'|warrant|liabl|liability|disclaim|redistribut|'
                   r'under the terms of|\b(?-i:MPL|L?GPL)\b', re.IGNORECASE)
MORE_TERMS = re.compile(TERMS.pattern + r'|merchantab|permission|permitted|endorse|\bas[ -]is\b|misrepresent|'
                        r'this notice', re.IGNORECASE)
# Words of the paragraphs of a license that continue its terms, beyond those its own sentences use.
LICENSE_PROSE = re.compile(MORE_TERMS.pattern + r'|the original code is|initial developer|contributor\(s\)|'
                           r'retains certain rights', re.IGNORECASE)
# A line that introduces what follows it: one that ends in a colon ("libjpeg-turbo Modifications:").
LEAD_IN = re.compile(r'\s*(?!copyright\b)\S.*:\s*$', re.IGNORECASE)
# A paragraph that says where a file's code comes from.
PROVENANCE = re.compile(r'^\s*(based on|derived from|taken from|copied from|ported from|adapted from)\b|'
                        r'\b(code|implementation|file|algorithm|version|port)\b[^\n]*?\b(is|are|was|were)\s+'
                        r'(based on|derived from|taken from|copied from|ported from|adapted from|coming from)\b',
                        re.IGNORECASE)
# A paragraph a license's text does not hold: who wrote a file, the project it is part of, that a
# tool generated it, or its history.
NOT_TERMS = re.compile(r'^\s*((@?authors?|contact)\s*:|this file is part of\b|date\s+name\s+description|'
                       r'(modification|revision|change) history|change ?log\b)|'
                       r'\b(do not (modify|edit)|auto-?generated|this (entire )?(file|header) is generated)\b|'
                       r'^\s*\d{1,2}/\d{1,2}/\d{2,4}\s', re.IGNORECASE | re.MULTILINE)
LGPL_NAME = re.compile(r'(lesser|library)\s+general\s+public\s+licen[cs]e|\blgpl', re.IGNORECASE)
# The GPL as the terms a notice states, not a mention of it.
GPL_NAME = re.compile(r'(terms\s+of|under|licensed\s+under)\s+(the\s+)?(gnu\s+)?(general\s+public\s+licen[cs]e|gpl)\b|'
                      r'general\s+public\s+licen[cs]e\s+as\s+published|\bgpl-?[23]|\bgplv[23]', re.IGNORECASE)
FDL_NAME = re.compile(r'free\s+documentation\s+licen[cs]e', re.IGNORECASE)
# Any naming of a GNU license, and the version and "or later" that follow a name.
GNU_ANY_NAME = re.compile(r'(?P<lgpl>(lesser|library)\s+general\s+public\s+licen[cs]e|\blgpl)|'
                          r'(?P<gpl>general\s+public\s+licen[cs]e|\bgpl(?=\b|v[123]))|'
                          r'(?P<fdl>free\s+documentation\s+licen[cs]e)', re.IGNORECASE)
GNU_VERSION = r'version\s+([123](?:\.[01])?)\b|gplv?[- ]?([123](?:\.[01])?)\b'
GNU_LATER = re.compile(r'any later version|or later|-or-later|\d\+', re.IGNORECASE)
# A notice that offers another license beside a GNU one: dual-license wording or an SPDX OR.
ALTERNATIVE = re.compile(r'dual[- ]licen[cs]|licensed under (both|either)|at your option,? (one|either) of|'
                         r'you may (choose|select) (either|one)|under the terms of (either|any one of)|'
                         r'alternatively,? (the (\w+ )*?(contents|portions) of this file|this \w+) may (also )?be '
                         r'(used|distributed|licensed)',
                         re.IGNORECASE)
SPDX_OR = re.compile(r'SPDX-License-Identifier:[^\n]*\bOR\b')
# An exception to the GPL: its own wording, the Bison skeleton's, GCC's runtime and Autoconf's, or an SPDX WITH.
GPL_EXCEPTION = re.compile(r'as a special exception|bison parser skeleton|gcc runtime library exception|'
                           r'autoconf (configure script )?exception', re.IGNORECASE)
SPDX_WITH = re.compile(r'SPDX-License-Identifier:[^\n]*\bWITH\b')


def fail(message):
    sys.exit('generate-legal: ' + message)


def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def normalize(text):
    return ' '.join(text.split())


def under(path, directory):
    return path.startswith(directory + os.sep)


# --- Mach-O images and archives ------------------------------------------------------------------

def macho_images(path):
    # (LC_UUID, __TEXT,__text size, CPU type) of each linked image a Mach-O file holds, one per
    # architecture.
    try:
        f = open(path, 'rb')
    except OSError:
        return []
    with f:
        def image(offset):
            f.seek(offset)
            header = f.read(32)
            if len(header) < 28:
                return []
            magic, cputype, _, filetype, ncmds, size = struct.unpack_from('<IiiIII', header)
            if magic not in (0xfeedface, 0xfeedfacf) or filetype == 1:
                return []
            wide = magic == 0xfeedfacf
            f.seek(offset + (32 if wide else 28))
            commands = f.read(size)
            uuid, text, position = None, 0, 0
            for _ in range(ncmds):
                command, length = struct.unpack_from('<II', commands, position)
                if command == 0x1b:
                    uuid = commands[position + 8:position + 24]
                elif command in (0x19, 0x1):
                    count = struct.unpack_from('<I', commands, position + (64 if wide else 48))[0]
                    first, step = position + (72 if wide else 56), (80 if wide else 68)
                    for i in range(count):
                        section = first + i * step
                        if commands[section:section + 16].rstrip(b'\0') == b'__text' \
                                and commands[section + 16:section + 32].rstrip(b'\0') == b'__TEXT':
                            text += struct.unpack_from('<Q' if wide else '<I', commands,
                                                       section + (40 if wide else 36))[0]
                position += length
            return [(uuid, text, cputype)] if uuid else []
        start = f.read(8)
        if len(start) == 8 and struct.unpack('>I', start[:4])[0] == 0xcafebabe:
            count = struct.unpack('>I', start[4:])[0]
            architectures = f.read(20 * count)
            return [i for n in range(count) for i in image(struct.unpack_from('>I', architectures, 20 * n + 8)[0])]
        return image(0)


def image_uuids(path):
    return {image[0] for image in macho_images(path)}


def staged_images():
    # {UUID: [staged paths]} of the staged images that carry code, and {UUID: CPU type}.
    if not os.path.isfile(os.path.join(STAGED, '.build-complete')):
        fail('%s holds no complete staged product; run AquaWebKitSupport/build.sh' % STAGED)
    images, cpus = {}, {}
    for directory, _, files in os.walk(STAGED):
        for name in files:
            path = os.path.join(directory, name)
            if not os.path.islink(path):
                for uuid, text, cpu in macho_images(path):
                    if text:
                        images.setdefault(uuid, []).append(os.path.relpath(path, STAGED))
                        cpus[uuid] = cpu
    return images, cpus


def archive_members(path):
    # (name, content) of each member of an ar archive, short of its symbol table.
    with open(path, 'rb') as f:
        data = f.read()
    if not data.startswith(b'!<arch>\n'):
        fail('%s is not an ar archive' % path)
    members, position = [], 8
    while position + 60 <= len(data):
        header = data[position:position + 60]
        name = header[:16].decode('ascii', 'replace').strip()
        size = int(header[48:58].decode('ascii').strip())
        body = data[position + 60:position + 60 + size]
        position += 60 + size + (size & 1)
        if name.startswith('#1/'):
            length = int(name[3:])
            name, body = body[:length].rstrip(b'\0').decode('utf-8', 'replace'), body[length:]
        if not (name.startswith('__.SYMDEF') or name in ('/', '//', '/SYM64/')):
            members.append((name, body))
    return members


# --- build_deps.sh --------------------------------------------------------------------------------

def build_deps_script():
    script = read(os.path.join(DEPS, 'build_deps.sh'))
    variables = dict(re.findall(r'^([A-Z][A-Z0-9_]*)=([^\s$"]+)$', script, re.MULTILINE))
    return script, variables


def expand(url, variables):
    url = url.replace('${GLIB_VER%.*}', variables['GLIB_VER'].rsplit('.', 1)[0])
    for name, value in sorted(variables.items(), key=lambda item: -len(item[0])):
        url = url.replace('${%s}' % name, value).replace('$' + name, value)
    return url


def build_deps_urls():
    script, variables = build_deps_script()
    urls = []
    for url in re.findall(r'https?://[^\s"]+', script):
        url = expand(url, variables)
        if url not in urls:
            urls.append(url)
    return urls


def tree_urls():
    # {label: URL} of each tree build_deps.sh's get() unpacks into deps/work/trees/build-<label>.
    script, variables = build_deps_script()
    labels, last = {}, None
    for line in script.split('\n'):
        assignment = re.match(r'\s*u=(https?://\S+)\s*$', line)
        if assignment:
            last = expand(assignment.group(1), variables)
        call = re.search(r'\$\(get\s+("\$u"|\$u|https?://\S+)\s+([\w.-]+)\)', line)
        if call:
            labels[call.group(2)] = last if call.group(1).strip('"') == '$u' else expand(call.group(1), variables)
    return labels


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


def tarball_member(path, name, raw=False):
    # A member's content, through the symbolic and hard links tar extracts as nothing.
    for _ in range(8):
        content = subprocess.check_output(['tar', '-xOf', path, name])
        if content:
            return content if raw else content.decode('utf-8', 'replace')
        listing = subprocess.check_output(['tar', '-tvf', path, name]).decode('utf-8', 'replace')
        link = re.search(re.escape(name) + r' (->|link to) (.+)$', listing, re.MULTILINE)
        if not link:
            return b'' if raw else ''
        name = os.path.normpath(os.path.join(os.path.dirname(name), link.group(2))) \
            if link.group(1) == '->' else link.group(2)
    fail('%s in %s links in a loop' % (name, path))


def tarball_licenses(path, extras):
    # The tarball's names and top-level license files. The system tar, as build_deps.sh unpacks with:
    # it reads every compression the tarballs use.
    names = subprocess.check_output(['tar', '-tf', path]).decode('utf-8', 'replace').splitlines()
    texts = []
    for name in sorted(n for n in names if not n.endswith('/')):
        parts = name.split('/')[1:]
        if not parts:
            continue
        relative = '/'.join(parts)
        if (len(parts) == 1 and LICENSE_NAME.match(parts[0])) \
                or (len(parts) == 2 and parts[0] == 'LICENSES') or relative in extras:
            texts.append((relative, tarball_member(path, name)))
            extras = [e for e in extras if e != relative]
    if extras:
        fail('%s has no %s' % (path, ', '.join(extras)))
    return names, texts


# --- what each staged image compiled -------------------------------------------------------------

class Compiled:
    # The files compiled into each staged image. A file is its real path, or, inside a tree a
    # manifest records, 'manifest:<label>:<path in the tree>'.

    def __init__(self, staged, cpus):
        self.staged = staged
        self.cpus = cpus
        self.images = {}            # UUID -> set of files
        self.stored = {}            # manifest file -> its leading comments
        self.hashes = {}            # manifest file -> its content hash
        self.leading = {}
        self.objects = None         # object content hash -> files
        self.polyfill = {}
        self.archives = {}
        self.trees = {}

    def leading_comments(self, key):
        if key in self.stored:
            return self.stored[key]
        if key not in self.leading:
            self.leading[key] = compiled_sources.leading_comments(key)
        return self.leading[key]

    def object_index(self):
        # Every object the manifests record, and the gap archive's live objects, by content hash.
        if self.objects is None:
            self.objects = {}
            for path in sorted(glob.glob(os.path.join(MANIFESTS, '*.json'))):
                label = os.path.basename(path)[:-len('.json')]
                record = json.loads(read(path))

                def key(name):
                    return 'manifest:%s:%s' % (label, name[len('tree:'):]) if name.startswith('tree:') \
                        else os.path.realpath(name)
                for name, entry in record['files'].items():
                    if name.startswith('tree:'):
                        self.stored[key(name)] = entry['leading']
                        self.hashes[key(name)] = entry['sha256']
                for digest, entry in record['objects'].items():
                    self.objects[digest] = {key(s) for s in entry['sources']}
            for path, sources in compiled_sources.tree_objects(os.path.join(TREES, 'gap')).items():
                self.objects[compiled_sources.sha256(path)] = set(sources)
        return self.objects

    def polyfill_record(self, product):
        if product not in self.polyfill:
            record = os.path.join(POLYFILL_BUILD, 'sources', product + '.d')
            if not os.path.isfile(record):
                fail('%s is missing; run AquaWebKitSupport/polyfill/build-polyfill.sh' % record)
            self.polyfill[product] = {os.path.realpath(p) for prerequisites in
                                      compiled_sources.depfile_rules(record).values() for p in prerequisites}
        return self.polyfill[product]

    def archive_files(self, path):
        # The files compiled into an archive's members: by the polyfill build's record for its
        # archives, else by each member's content, which an object a manifest or the gap build
        # records must match. llvm-ar pads a member to 8 bytes.
        path = os.path.realpath(path)
        if under(path, POLYFILL_BUILD):
            return self.polyfill_record(os.path.basename(path))
        if path in self.archives:
            return self.archives[path]
        index, files = self.object_index(), set()
        for name, body in archive_members(path):
            for pad in range(8):
                if pad and body[len(body) - pad] not in (0, 10, 32):
                    break
                digest = hashlib.sha256(body[:len(body) - pad]).hexdigest()
                if digest in index:
                    files |= index[digest]
                    break
            else:
                fail('member %s of %s matches no object a manifest or build records' % (name, path))
        self.archives[path] = files
        return files

    def link_libraries(self, directory, target):
        # The archives and dylibs a ninja link edge's command names, with -l resolved as ld does.
        command = compiled_sources.ninja(directory, '-t', 'commands', '-s', target).strip().split('\n')[-1]
        tokens, expanded = shlex.split(command), []
        for token in tokens:
            if token.startswith('@') and os.path.isfile(os.path.join(directory, token[1:])):
                expanded += shlex.split(read(os.path.join(directory, token[1:])))
            elif token.startswith('-Wl,'):
                expanded += token[4:].split(',')
            else:
                expanded.append(token)
        search, found, sysroot = [], [], SDK
        for i, token in enumerate(expanded):
            if token.startswith('-L') and len(token) > 2:
                search.append(os.path.join(directory, token[2:]))
            elif token in ('-L', '-isysroot', '-syslibroot') and i + 1 < len(expanded):
                if token == '-L':
                    search.append(os.path.join(directory, expanded[i + 1]))
                else:
                    sysroot = expanded[i + 1]
        search += [os.path.join(sysroot, 'usr', 'lib'), '/usr/lib']
        for token in expanded:
            if token.startswith('-l') and len(token) > 2:
                for d in search:
                    hits = [os.path.join(d, 'lib%s%s' % (token[2:], s)) for s in ('.tbd', '.dylib', '.a')
                            if os.path.exists(os.path.join(d, 'lib%s%s' % (token[2:], s)))]
                    if hits:
                        found.append(hits[0])
                        break
                else:
                    fail('%s links %s, which no library directory of its link holds' % (target, token))
            elif token.endswith(('.a', '.dylib', '.tbd')) and os.path.isfile(os.path.join(directory, token)) \
                    and os.path.realpath(os.path.join(directory, token)) != os.path.realpath(os.path.join(directory, target)):
                found.append(os.path.join(directory, token))
        return found

    def check_dylib(self, path, image):
        # A dylib a link names is the SDK's or the system's, or one of the builds' here.
        path = os.path.realpath(path)
        if not any(under(path, d) for d in (os.path.realpath(SDK), '/usr/lib', '/System/Library', BUILD, TREES,
                                            os.path.join(DEPS, 'build'), POLYFILL_BUILD, TOOLCHAIN)):
            fail('%s links %s, which is neither the system\'s nor a build\'s here' % (image, path))

    def builtins_inputs(self, directory, targets, files):
        # {file of `files` that JavaScriptCore's generate-js-builtins.py writes: the files its edge
        # reads}. The file is the scripts it embeds and the generator's wrapper code, under a header
        # that merges the scripts' copyright lines by holder, so the edge's inputs are its sources: the
        # scripts, the generator's Python files and, in their place, the builtins files it reads.
        edges, pending = {}, {os.path.relpath(f, directory) for f in files if under(f, directory)}
        while pending:
            query = [t for t in pending if targets.get(t) == 'CUSTOM_COMMAND' and t not in edges]
            pending = set()
            for target, inputs in compiled_sources.ninja_query(directory, query).items():
                edges[target] = None
                if not any(i.endswith('.js') for i in inputs):
                    continue
                command = shlex.split(compiled_sources.ninja(directory, '-t', 'commands', '-s', target).strip().split('\n')[-1])
                if any(os.path.basename(token) == 'generate-js-builtins.py' for token in command):
                    edges[target] = inputs
                    pending |= set(inputs)

        def sources(target):
            found = set()
            for i in edges[target]:
                found |= sources(i) if edges.get(i) else {os.path.realpath(os.path.join(directory, i))}
            return found
        return {os.path.realpath(os.path.join(directory, t)): sorted(sources(t)) for t in edges if edges[t]}

    def ninja_build(self, directory, pending):
        targets = compiled_sources.ninja_targets(directory)
        roots = {t: image_uuids(os.path.join(directory, t)) & pending for t, rule in targets.items() if rule != 'phony'}
        roots = {t: u for t, u in roots.items() if u}
        if not roots:
            return set()
        inputs = compiled_sources.ninja_query(directory, roots)
        # A link has objects or archives among its inputs; a target that copies an image does not.
        roots = {t: u for t, u in roots.items() if any(i.endswith(('.o', '.obj', '.a')) for i in inputs[t])}
        if not roots:
            return set()
        archives = [i for v in inputs.values() for i in v if i.endswith('.a') and i in targets]
        while archives:
            inputs.update(compiled_sources.ninja_query(directory, set(archives) - set(inputs)))
            archives = [i for v in inputs.values() for i in v
                        if i.endswith('.a') and i in targets and i not in inputs]
        objects = {i for v in inputs.values() for i in v if i.endswith(('.o', '.obj')) and i in targets}
        sources = compiled_sources.ninja_object_sources(directory, objects)
        embedded = self.builtins_inputs(directory, targets, {f for files in sources.values() for f in files})
        sources = {o: sorted({s for f in files for s in embedded.get(f, [f])}) for o, files in sources.items()}
        matched = set()
        for root, uuids in roots.items():
            files, seen, stack = set(), set(), [root]
            while stack:
                for item in inputs.get(stack.pop(), []):
                    if item in seen:
                        continue
                    seen.add(item)
                    if item in sources:
                        files.update(sources[item])
                    elif item.endswith('.a'):
                        if item in targets:
                            stack.append(item)
                        else:
                            files |= self.archive_files(os.path.join(directory, item))
                    elif item.endswith(('.dylib', '.tbd')):
                        self.check_dylib(os.path.join(directory, item), root)
            for library in self.link_libraries(directory, root):
                relative = os.path.relpath(os.path.realpath(library), os.path.realpath(directory))
                if library.endswith('.a') and relative not in targets and relative not in seen:
                    files |= self.archive_files(library)
                elif library.endswith(('.dylib', '.tbd')):
                    self.check_dylib(library, root)
            for uuid in uuids:
                self.images.setdefault(uuid, set()).update(files)
            matched |= uuids
        return matched

    def tree_objects(self, tree):
        if tree not in self.trees:
            self.trees[tree] = compiled_sources.tree_objects(tree)
        return self.trees[tree]

    def libtool_objects(self, library):
        # The objects of a libtool library, by automake's <name>_la_OBJECTS and the convenience
        # libraries its <name>_la_LIBADD names, in the Makefile, the library's or an enclosing
        # directory's, that defines them.
        directory = os.path.dirname(library)
        while True:
            variable = re.sub(r'[^A-Za-z0-9_]', '_', os.path.relpath(library, directory))
            makefile = os.path.join(directory, 'Makefile')
            if os.path.isfile(makefile) and re.search(r'^%s_OBJECTS\s*=' % variable, read(makefile), re.MULTILINE):
                break
            if directory == os.path.dirname(directory):
                fail('no Makefile defines the objects of %s' % library)
            directory = os.path.dirname(directory)
        rule = 'aquawebkit-objects:\n\t@echo $(%s_OBJECTS) $(%s_LIBADD)\n' % (variable, variable)
        listed = subprocess.run(['make', '-s', '-C', directory, '-f', 'Makefile', '-f', '-', 'aquawebkit-objects'],
                                input=rule.encode(), stdout=subprocess.PIPE, check=True).stdout.decode().split()
        objects = []
        for item in listed:
            path = os.path.join(directory, item)
            if item.endswith('.lo'):
                pic = re.search(r"^pic_object='(.*)'$", read(path), re.MULTILINE)
                if not pic or pic.group(1) == 'none':
                    fail('%s names no PIC object' % path)
                objects.append(os.path.realpath(os.path.join(os.path.dirname(path), pic.group(1))))
            elif item.endswith('.la') and re.search(r"^library_names=''$", read(path), re.MULTILINE):
                objects += self.libtool_objects(path)
        if not objects:
            fail('%s lists no objects for %s' % (os.path.join(directory, 'Makefile'), library))
        return objects

    def make_tree(self, tree, images):
        # A make build's images: a libtool library's, its objects; any other's, every object the tree
        # compiled.
        objects = self.tree_objects(tree)
        for path, uuids in images.items():
            libraries = [l for l in glob.glob(os.path.join(os.path.dirname(os.path.dirname(path)), '*.la'))
                         if os.path.basename(os.path.dirname(path)) == '.libs'
                         and "dlname='%s'" % os.path.basename(path) in read(l)]
            if libraries:
                files = set()
                for object in self.libtool_objects(libraries[0]):
                    if object not in objects:
                        fail('%s, an object of %s, is not among what %s compiled' % (object, libraries[0], tree))
                    files.update(objects[object])
            else:
                files = set().union(*objects.values())
            if not files:
                fail('%s compiled nothing for %s' % (tree, path))
            for uuid in uuids:
                self.images.setdefault(uuid, set()).update(files)

    def linked_by_recipe(self, pending):
        # The images build_deps.sh links itself, by the inputs its link_record names.
        matched = set()
        for record in sorted(glob.glob(os.path.join(LINKS, '*.txt'))):
            uuids = image_uuids(os.path.join(STAGE, 'lib', os.path.basename(record)[:-len('.txt')])) & pending
            if not uuids:
                continue
            files = set()
            for path in read(record).split('\n'):
                if path.endswith('.a'):
                    files |= self.archive_files(path)
                elif path:
                    tree = os.path.join(TREES, os.path.relpath(os.path.realpath(path), os.path.realpath(TREES)).split(os.sep)[0])
                    objects = self.tree_objects(tree)
                    if os.path.realpath(path) not in objects:
                        fail('%s names %s, which no tree compiled' % (record, path))
                    files.update(objects[os.path.realpath(path)])
            for uuid in uuids:
                self.images.setdefault(uuid, set()).update(files)
            matched |= uuids
        return matched

    def trace(self, stock_names):
        # Trace every staged image; fails on one no build accounts for. A stock i386 slice accounts
        # for itself only in an image of `stock_names`.
        pending = set(self.staged)
        pending -= self.ninja_build(BUILD, pending)
        trees = sorted(d for d in os.listdir(TREES) if d not in NOT_TREES and os.path.isdir(os.path.join(TREES, d)))
        ninja_trees = set()
        for tree in trees:
            for directory in compiled_sources.ninja_directories(os.path.join(TREES, tree)):
                ninja_trees.add(directory)
                pending -= self.ninja_build(directory, pending)
        pending -= self.linked_by_recipe(pending)
        for path in os.listdir(POLYFILL_BUILD):
            for uuid in image_uuids(os.path.join(POLYFILL_BUILD, path)) & pending:
                self.images[uuid] = set(self.polyfill_record(path))
                pending.discard(uuid)
        rust = set()
        for target in RUST_TARGETS:
            for path in glob.glob(os.path.join(target, 'x86_64-apple-darwin', 'release', '*.dylib')):
                rust |= image_uuids(path) & pending
        pending -= rust
        stock = set()
        for directory, _, files in os.walk(STOCK):
            for name in files:
                stock |= {image[0] for image in macho_images(os.path.join(directory, name)) if image[2] == CPU_I386}
        for uuid in pending & stock:
            if self.cpus[uuid] == CPU_I386 and all(os.path.basename(p) in stock_names for p in self.staged[uuid]):
                pending.discard(uuid)
        for tree in trees:
            root, found = os.path.join(TREES, tree), {}
            for directory, subdirectories, files in os.walk(root):
                if directory in ninja_trees or any(under(directory, t) for t in RUST_TARGETS) \
                        or os.path.basename(directory) == 'target':
                    subdirectories[:] = []
                    continue
                for name in files:
                    if (name.endswith(('.dylib', '.so')) or '.' not in name) \
                            and not os.path.islink(os.path.join(directory, name)):
                        uuids = image_uuids(os.path.join(directory, name)) & pending
                        if uuids:
                            found[os.path.join(directory, name)] = uuids
            if found:
                self.make_tree(root, found)
                for uuids in found.values():
                    pending -= uuids
        if pending:
            fail('no build accounts for the staged images %s'
                 % ', '.join(sorted(p for u in pending for p in self.staged[u])))
        return rust


# --- the staged product's other files ------------------------------------------------------------

STAMP = '.build-complete'
PLACEHOLDER = re.compile(r'\$\{[^}]*\}|@[A-Za-z_][A-Za-z0-9_]*@')
# The inputs stage-frameworks.sh gives build-localized-strings.py: WebCore's English table and the
# stock WebCore resources, whose tables it merges over it.
LOCALIZED_STRINGS = (os.path.join(SUPPORT, 'scripts', 'build-localized-strings.py'),
                     os.path.join(SOURCE, 'WebCore', 'en.lproj', 'Localizable.strings'),
                     os.path.join(STOCK, 'WebKit.framework', 'Versions', 'A', 'Frameworks', 'WebCore.framework',
                                  'Versions', 'A', 'Resources'))


def plist_matches(data, template, free=()):
    # Whether property list data is the template's, each ${VAR} and @VAR@ of its strings filled in,
    # but for the values of the top-level keys `free` names.
    if isinstance(template, dict):
        keys = (set(data) | set(template)) - set(free) if isinstance(data, dict) else None
        return keys is not None and all(k in data and k in template and plist_matches(data[k], template[k])
                                        for k in keys)
    if isinstance(template, list):
        return isinstance(data, list) and len(data) == len(template) \
            and all(plist_matches(d, t) for d, t in zip(data, template))
    if isinstance(template, str) and PLACEHOLDER.search(template):
        parts = re.split('(%s)' % PLACEHOLDER.pattern, template)
        return isinstance(data, str) and bool(re.fullmatch(
            ''.join('.*' if n % 2 else re.escape(p) for n, p in enumerate(parts)), data, re.DOTALL))
    return type(data) is type(template) and data == template


class Resources:
    # The origins of each staged file that is not a Mach-O image, {staged path: [real paths]}; a
    # Mach-O file is the image trace's, and one without code carries none. A file's origins are, the
    # first that apply:
    #   - the files of its name and content in WebKit's source, the port's files or the deps trees,
    #     else in the stock backup;
    #   - those of a file of its name and content in WebKit's build: the inputs of the ninja edge that
    #     writes it, traced the same way, or, for an edge that declares none, the files of the
    #     repository its command names; or, for a property list CMake configures, its template;
    #   - for a property list, the templates CMake read, and the stock property lists of its name,
    #     that it fills in but for the keys stage-frameworks.sh sets;
    #   - none for a code signature's CodeResources, beside a traced executable;
    #   - the stock file of its name and the patch in AquaWebKitSupport that makes it from that file;
    #   - for a table build-localized-strings.py rebuilds the same, the tables it reads;
    #   - for a header, the source header of its name whose leading comments it holds, the stock
    #     header of its name, which it holds whole, or both, as its i386 branch says;
    #   - for a module map, the source module map stage-headers.sh copies, which it opens with.
    # A file with no origin fails.

    def __init__(self, staged):
        images = {p for paths in staged.values() for p in paths}
        self.images, self.files, self.digests = images, [], {}
        for directory, _, files in os.walk(STAGED):
            for name in files:
                path = os.path.join(directory, name)
                relative = os.path.relpath(path, STAGED)
                if not os.path.islink(path) and relative != STAMP and relative not in images \
                        and not macho_images(path):
                    self.files.append(relative)
        names = {os.path.basename(f) for f in self.files}
        names |= {n + '.patch' for n in names}
        self.by_name = {}
        skip = {TOOLCHAIN, POLYFILL_BUILD, os.path.join(DEPS, 'build'), STAGE, TARBALLS, STAGED}
        for root in (SOURCE, SUPPORT, STOCK, BUILD):
            for directory, subdirectories, files in os.walk(root):
                subdirectories[:] = [d for d in subdirectories
                                     if d != '.git' and os.path.join(directory, d) not in skip]
                for name in files:
                    path = os.path.join(directory, name)
                    if name in names and os.path.isfile(path):
                        self.by_name.setdefault(name, set()).add(os.path.realpath(path))
        self.targets = compiled_sources.ninja_targets(BUILD)
        templates = [i for i in compiled_sources.ninja_query(BUILD, ['build.ninja'])['build.ninja']
                     if re.search(r'\.plist(\.in)?$', i)]
        self.templates = [(t, self.plist(t)) for t in templates if self.plist(t) is not None]
        script = re.sub(r'\\\n', ' ', read(os.path.join(HERE, 'stage-frameworks.sh')))
        self.free = {k for line in script.split('\n') if 'PlistBuddy' in line
                     for k in re.findall(r'["\'](?:Set|Add) :(\w+)', line)}
        self.module_maps = [os.path.join(SOURCE, p) for p in re.findall(
            r'cp "\$SRC/([^"]+\.modulemap)"', read(os.path.join(HERE, 'stage-headers.sh')))]
        self.localized = None

    def digest(self, path):
        if path not in self.digests:
            self.digests[path] = compiled_sources.sha256(path)
        return self.digests[path]

    def named(self, name, root):
        return sorted(p for p in self.by_name.get(name, ()) if under(p, root))

    @staticmethod
    def plist(path):
        try:
            with open(path, 'rb') as f:
                return plistlib.loads(f.read())
        except Exception:
            return None

    def trace(self):
        try:
            return self.traced()
        finally:
            if self.localized is not None:
                shutil.rmtree(self.localized)

    def traced(self):
        origins, missing = {}, []
        for relative in sorted(self.files):
            found = self.origins(os.path.join(STAGED, relative), relative)
            if found is None:
                missing.append(relative)
            else:
                origins[relative] = found
        if missing:
            fail('no origin accounts for the staged files %s' % ', '.join(missing))
        return origins

    def candidates(self, path):
        # The origins of the files of its name and content, outside the staged tree.
        same = [c for c in self.by_name.get(os.path.basename(path), ()) if c != os.path.realpath(path)
                and self.digest(c) == self.digest(path)]
        primary = [c for c in same if not under(c, BUILD) and not under(c, STOCK)]
        stock = [c for c in same if under(c, STOCK)]
        if primary or stock:
            return primary or stock
        for built in sorted(c for c in same if under(c, BUILD)):
            found = self.built(built)
            if found is not None:
                return found
        return None

    def built(self, path):
        # The origins of a file of WebKit's build.
        target = os.path.relpath(path, BUILD)
        if self.targets.get(target, 'phony') == 'phony':
            return self.configured(path) if self.plist(path) is not None else None
        inputs = compiled_sources.ninja_query(BUILD, [target])[target]
        if not inputs:
            command = shlex.split(compiled_sources.ninja(BUILD, '-t', 'commands', '-s', target).strip().split('\n')[-1])
            inputs = [t for t in command if os.path.isabs(t) and os.path.isfile(t) and not under(t, TOOLCHAIN)
                      and (under(t, SOURCE) or under(t, SUPPORT))]
        found = []
        for i in inputs:
            full = os.path.realpath(os.path.join(BUILD, i))
            if not under(full, BUILD):
                more = [full]
            elif self.targets.get(os.path.relpath(full, BUILD), 'phony') != 'phony':
                more = self.built(full)
            else:
                more = self.candidates(full)
                more = self.built(full) if more is None else more
            if more is None:
                return None
            found += more
        return found or None

    def configured(self, path, free=()):
        # The templates CMake read, and the stock property lists of its name, that a property list
        # fills in.
        data = self.plist(path)
        stock = [(s, self.plist(s)) for s in self.named(os.path.basename(path), STOCK)]
        return [t for t, template in self.templates + stock
                if template is not None and plist_matches(data, template, free)] or None

    def origins(self, path, relative):
        found = self.candidates(path)
        if found is None and self.plist(path) is not None:
            found = self.configured(path, self.free)
        if found is None and relative.endswith('/_CodeSignature/CodeResources'):
            contents = os.path.dirname(os.path.dirname(relative))
            found = [] if any(i.startswith(contents + '/MacOS/') for i in self.images) else None
        if found is None:
            found = self.patched(path)
        if found is None:
            found = self.localized_table(path, relative)
        text = read(path)
        if found is None and path.endswith('.h') and '/Headers/' in relative:
            found = self.header(path, text)
        if found is None and path.endswith('.modulemap'):
            found = [m for m in self.module_maps if read(m).rstrip().endswith('}')
                     and text.startswith(read(m).rstrip()[:-1].rstrip())] or None
        return found

    def patched(self, path):
        name = os.path.basename(path)
        with tempfile.TemporaryDirectory() as scratch:
            for stock in self.named(name, STOCK):
                for patch in self.named(name + '.patch', SUPPORT):
                    output = os.path.join(scratch, name)
                    if subprocess.run(['patch', '-s', '-o', output, stock, patch]).returncode == 0 \
                            and compiled_sources.sha256(output) == self.digest(path):
                        return [stock, patch]
        return None

    def localized_table(self, path, relative):
        script, english, stock = LOCALIZED_STRINGS
        within = relative.split('/WebCore.framework/Versions/A/Resources/', 1)
        if len(within) != 2 or os.path.basename(path) != 'Localizable.strings':
            return None
        if self.localized is None:
            self.localized = tempfile.mkdtemp()
            subprocess.run(['/usr/bin/python', script, english, stock, self.localized], stdout=subprocess.DEVNULL,
                           check=True)
        built = os.path.join(self.localized, within[1])
        if not os.path.isfile(built) or compiled_sources.sha256(built) != self.digest(path):
            return None
        return [english] + [os.path.join(stock, within[1])] * os.path.isfile(os.path.join(stock, within[1]))

    def header(self, path, text):
        ours = [s for s in self.named(os.path.basename(path), SOURCE)
                if compiled_sources.leading_comments(s) and compiled_sources.leading_comments(s) in text]
        stock = [s for s in self.named(os.path.basename(path), STOCK) if read(s).rstrip('\n') in text]
        i386 = not text.startswith('#ifdef __LP64__') or '\n#else /* the i386 slice' in text
        if (text.startswith('#ifdef __LP64__') and not ours) or (i386 and not stock):
            return None
        return ours + stock


# --- notices --------------------------------------------------------------------------------------

def comment_blocks(text):
    # The comments of a file's leading comment text, one per /* */ block, run of one-line /* */
    # comments, or run of line comments (blank lines included), without their comment markers, the
    # right edge of a comment box, editor mode lines, interpreter lines and version-control keywords.
    # A /* */ block's lines open with an asterisk marker only when most of its inner lines of text do;
    # otherwise a leading asterisk is a bullet of the text. A line whose text directly follows its
    # marker keeps its place when the others set their text off from theirs.
    blocks, current, kind = [], [], None
    for line in text.split('\n'):
        stripped = line.strip()
        if kind == 'line' and not stripped:
            current.append('')
            continue
        if kind == 'block':
            current.append(line)
            if '*/' in stripped:
                blocks.append(current)
                current, kind = [], None
            continue
        if stripped.startswith('/*'):
            one_line = '*/' in stripped[2:]
            if current and not (one_line and kind == 'single'):
                blocks.append(current)
                current = []
            current.append(line)
            kind = 'single' if one_line else 'block'
        elif stripped.startswith(('//', ';', '#')):
            if current and kind != 'line':
                blocks.append(current)
                current = []
            current.append(line)
            kind = 'line'
        elif current:
            blocks.append(current)
            current, kind = [], None
    if current:
        blocks.append(current)
    cleaned = []
    for block in blocks:
        # A box's right edge: most of its lines of text end with an asterisk.
        box = sum(bool(re.search(r'[^/*\s]\s*\*+\s*$', l)) for l in block) * 2 \
            > sum(bool(re.search(r'\w', l)) for l in block)
        inner = [l.strip() for l in block[1:] if re.search(r'\w', l) and not l.strip().startswith(('/*', '*/'))]
        starred = sum(l.startswith('*') for l in inner) * 2 > len(inner)
        lines, tight = [], []
        for line in block:
            line = line.rstrip()
            if re.match(r'\s*#!|\s*(\*|//|#|;)?\s*(@[A-Z_]+@|@\(#\)|\$Id[:$])', line):
                lines.append('')
                continue
            marker = re.match(r'\s*(/\*+|\*+/|\*+|//+|;+|#+)', line)
            if marker and (starred or not marker.group(1).startswith('*') or marker.group(1).startswith('*/')):
                line = line[marker.end():]
                if not marker.group(1).startswith('*'):
                    line = re.sub(r'^\*(?=\s|$)', '', line)
                if re.match(r'\w', line):
                    tight.append(len(lines))
            line = re.sub(r'\s*\*+/\s*$', '', line)
            line = re.sub(r'\s*\*+$' if box else r'\s+\*+$', '', line)
            line = re.sub(r'-\*-.*?-\*-', '', line)
            lines.append('' if re.match(r'^[\s*=#~_/-]*$', line) else line)
        text_lines = [i for i, l in enumerate(lines) if l.strip()]
        loose = [i for i in text_lines if i not in tight]
        measured = loose if len(loose) > len(text_lines) - len(loose) else text_lines
        indent = min([len(lines[i]) - len(lines[i].lstrip()) for i in measured] or [0])
        text = '\n'.join(l[min(indent, len(l) - len(l.lstrip())):] for l in lines).strip('\n')
        if text:
            cleaned.append(text)
    return cleaned


def holder(notice):
    # The holder a copyright notice names, without its years and the sentences that follow the name:
    # the one its copyright line names, else the one its lines name together.
    statements = [l for l in notice.split('\n') if is_copyright(l)]
    named = statements and statement_holder(statements[0])
    return named or statement_holder(notice)


def statement_holder(notice):
    line = re.sub(r'^\s*' + NAMED_BY + r'(portions\s+)?((copyright\b|spdx-filecopyrighttext:|©|\(c\))\s*)+', '',
                  normalize(notice), flags=re.IGNORECASE)
    line = re.sub(r'\(c\)|©', '', line, flags=re.IGNORECASE)
    line = re.sub(r'\b\d{4}\b(\s*[-–]\s*\d{2,4})?(\s+and\s+(later|onwards))?[\s,:]*', ' ', line)
    line = re.sub(r'all rights reserved\.?', '', line, flags=re.IGNORECASE)
    line = re.split(r'(?<=[a-z0-9)])\.\s+(?=[A-Z])', line)[0]
    return normalize(line.strip(' ,.;:-')).lower()


def is_copyright(line):
    # A copyright line, not a line of license text that starts with the word.
    return bool(COPYRIGHT_LINE.match(line)) and not re.match(
        r'\s*' + NAMED_BY + r'copyright(\s*:?\s*$|\s*[).,;]|\s+(notices?|holders?|owners?|law|statement|and|or|in|'
        r'to|of|this|license)\b)', line, re.IGNORECASE)


def continues(previous, line, deeper=False):
    # Whether a line continues the copyright notice whose last line is `previous`: the rest of its
    # holder's name, more years or holders, an address, or the reservation of rights; or a line set in
    # further than the copyright line (`deeper`) that is not a sentence of its own.
    if is_copyright(line) or MORE_TERMS.search(line) or line.startswith('@') or re.match(r'[\w ]+:', line) \
            or re.match(r'(written|created|modified|ported|based|contributed|originally|derived)\b', line,
                        re.IGNORECASE):
        return False
    if re.search(r'([,&(]|\band|\bby)$', previous) or not holder(previous):
        return True
    if re.match(r'(.*all rights? reserved\.?$|\(?<?\d{4}\b|and\s|<[^<>\s]+@)', line, re.IGNORECASE):
        return True
    if re.match(r'(inc|ltd|llc|corp(oration)?|gmbh|s\.[al]|b\.v|ab|ag)\b', line, re.IGNORECASE):
        return True
    if deeper and not re.match(r'(this|the|you|it|see|for|use|under)\b', line, re.IGNORECASE):
        return True
    # The rest of a name in capitals: "Commonwealth Scientific and Industrial Research" over
    # "Organisation (CSIRO) Australia".
    if re.search(r'[A-Za-z]$', previous) and len(line.split()) <= 8 and all(
            re.match(r"\(?[A-Z0-9][\w.&,'-]*\)?,?$", w) or w in ('of', 'and', 'for', 'the', 'de', 'du', '&')
            for w in line.split()):
        return True
    return bool(re.search(r'[<(][^<>()\s]+(@| at )', line)) and len(line.split()) <= 8


def another_statement(previous, line):
    # Whether a line set under a complete copyright statement starts another one with the same
    # "Copyright": its own years and holder ("2009 Torch Mobile Inc.").
    return bool(re.match(r'\(?<?\d{4}\b', line) and re.search(r'[.>)]$', previous) and holder(previous)
                and holder(line))


def paragraph_notices(lines, whole=False, upto=None):
    # ([(index, copyright notice)], [(index, line)] of the other lines) of a paragraph's lines. A
    # notice is its copyright line, with the lines that continue it on that line, and below it each
    # line that starts another statement under the same "Copyright". A line that introduces a
    # copyright line, ending in a colon ("These changes are:"), opens its notice, as do the lines
    # directly above a notice that names no holder ("University of Edinburgh, UK" over "Copyright (c)
    # 1999"). With `whole`, every other line of text before line `upto` goes with the notice above
    # it, else with the one below it, among those before `upto`.
    notices, rest, current, indent, last = [], [], None, 0, None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if is_copyright(stripped) or (current and stripped and another_statement(last, stripped)):
            current, indent, last = [stripped], len(line) - len(line.lstrip()), stripped
            first = index
            if rest and rest[-1][0] == index - 1 and LEAD_IN.match(rest[-1][1]):
                current.insert(0, rest.pop()[1].strip())
                first -= 1
            notices.append([index, current, first, index])
        elif current and stripped and continues(last, stripped, len(line) - len(line.lstrip()) > indent):
            current[-1] += ' ' + stripped
            last = stripped
            notices[-1][3] = index
        else:
            current = None
            rest.append((index, line))
    for notice in [n for n in notices if not holder('\n'.join(n[1]))]:
        while True:
            above = [n for n, (i, l) in enumerate(rest) if i == notice[2] - 1 and l.strip() and not MORE_TERMS.search(l)]
            if not above:
                break
            notice[1].insert(0, rest.pop(above[0])[1].strip())
            notice[2] -= 1
    if whole:
        within = [n for n in notices if upto is None or n[0] < upto]
        kept, before = [], []
        for index, line in rest:
            above = [n for n in within if n[3] < index]
            if not line.strip() or (upto is not None and index >= upto) or not within:
                kept.append((index, line))
            elif above:
                above[-1][1].append(line.strip())
                above[-1][3] = index
            else:
                before.append(line.strip())
        if within:
            within[0][1][:0] = before
        rest = kept
    return [(n[0], '\n'.join(n[1])) for n in notices], rest


def parse_block(block, where=''):
    # (copyright notices, terms) of a comment. Its terms are its paragraphs from the first that
    # states or points at license terms through those that continue them, or hold only copyright
    # notices, or lead to another that states terms in at most two paragraphs or in paragraphs of at
    # most two lines, but for those NOT_TERMS describes; from the line the first sentence starts on.
    # A notice whose terms ask for "this entire notice" runs to the comment's end. One with a
    # copyright notice opened by a line ending in a colon ("These changes are:") after a paragraph of
    # prose starts at that paragraph, which the line scopes, and keeps the notice in place. A comment
    # with no terms that says where its code comes from has that paragraph as its terms, with the
    # paragraphs of license prose that directly follow it. Its
    # copyright notices are those outside its terms, those its terms open with, and the paragraphs of
    # its terms that hold only copyright notices; the others are part of the terms. A notice outside
    # the terms takes the other lines of its paragraph (paragraph_notices' `whole`); every line of such
    # a paragraph but one that only reserves rights must be in the notices or the terms (`where` names
    # the comment's file when one is not).
    paragraphs = [p.split('\n') for p in re.split(r'\n[ \t]*\n', block.strip('\n'))]
    found = [paragraph_notices(lines) for lines in paragraphs]
    covered = []

    def whole(i, upto=None):
        notices = [n for index, n in paragraph_notices(paragraphs[i], True, upto)[0] if upto is None or index < upto]
        if notices:
            covered.append(paragraphs[i][:upto])
        return notices
    parts = [rest for _, rest in found]
    texts = [normalize(' '.join(l for _, l in rest)) for rest in parts]
    with_terms = [i for i, text in enumerate(texts) if TERMS.search(text)]
    scoped = []
    if not with_terms:
        after = [i for i, text in enumerate(texts) if PROVENANCE.search(text)
                 and not NOT_TERMS.search('\n'.join(l for _, l in parts[i]))
                 and any(notices for notices, _ in found[:i + 1])]
        if not after:
            notices = [n for i in range(len(paragraphs)) for n in whole(i)]
            check_notices(covered, notices, '', where)
            return notices, ''
        start, end, opening = after[0], after[0] + 1, 0
        while end < len(parts) and texts[end] and LICENSE_PROSE.search(texts[end]):
            end += 1
    else:
        more = [i for i, text in enumerate(texts) if not text or LICENSE_PROSE.search(text)]
        start, end = with_terms[0], with_terms[0] + 1
        while end < len(parts):
            if end in more:
                end += 1
            else:
                following = [i for i in with_terms if i > end]
                if not following or (following[0] - end > 2
                                     and any(len(parts[i]) > 2 for i in range(end, following[0]))):
                    break
                end = following[0] + 1
        if re.search(r'\bthis entire notice\b', normalize(block), re.IGNORECASE):
            end = len(parts)
        while not parts[end - 1]:
            end -= 1
        rest = parts[start]
        first = next(n for n, (index, l) in enumerate(rest) if TERMS.search(l) or (
            n + 1 < len(rest) and rest[n + 1][0] == index + 1 and not TERMS.search(rest[n + 1][1])
            and TERMS.search(normalize(l + ' ' + rest[n + 1][1]))))
        while first > 0 and rest[first - 1][0] == rest[first][0] - 1 \
                and not re.search(r'[.:;!?]$', rest[first - 1][1].strip()):
            first -= 1
        opening = rest[first][0]
        scoped = [i for i, (notices, _) in enumerate(found[:start + 1])
                  if i and not found[i - 1][0] and len(paragraphs[i - 1]) > 1
                  and any(LEAD_IN.match(n.split('\n')[0]) for _, n in notices)]
        if scoped:
            start, opening = scoped[0] - 1, 0
    notices, terms = [], []
    for i, (lines, (paragraph, rest)) in enumerate(zip(paragraphs, found)):
        if i in scoped:
            terms.append('\n'.join(lines))
        elif i < start or i >= end or (not rest and i != start):
            notices += whole(i)
        elif i == start:
            notices += whole(i, opening)
            terms.append('\n'.join(lines[opening:]))
        elif (with_terms and i in more) or not NOT_TERMS.search('\n'.join(l for _, l in rest)):
            terms.append('\n'.join(lines))
        else:
            notices += whole(i)
    lines = '\n\n'.join(t for t in terms if t.strip()).split('\n')
    indent = min([len(l) - len(l.lstrip()) for l in lines if l.strip()] or [0])
    terms = re.sub(r'\n{3,}', '\n\n', '\n'.join(l[indent:].rstrip() for l in lines).strip('\n'))
    check_notices(covered, notices, terms, where)
    return notices, terms


def check_notices(paragraphs, notices, terms, where):
    # Fails on a line of the copyright paragraphs that neither the notices nor the terms hold.
    held = normalize('\n'.join(notices) + '\n' + terms)
    for line in [l for p in paragraphs for l in p if l.strip()]:
        if normalize(line) not in held and not re.match(r'\s*all rights reserved\.?\s*$', line, re.IGNORECASE):
            fail('%s: the copyright line "%s" is in no notice and no terms' % (where or 'a comment', line.strip()))


def GNU_NAME(block):
    text = normalize(block)
    return LGPL_NAME.search(text) or GPL_NAME.search(text) or FDL_NAME.search(text)


def gnu_terms(block, context=''):
    # What a notice requires of the GNU licenses, as [(family, minimum version, or later)], and whether
    # it puts the file under the GPL alone. A comment that is not a notice requires nothing. Neither
    # does a notice that offers another license beside the GNU one, or that grants terms of its own.
    text = normalize(block)
    if not NOTICE.search(text) or ALTERNATIVE.search(text) or SPDX_OR.search(block) or GRANT.search(text):
        return [], False
    return gnu_licenses(block, context)


def gnu_licenses(block, context=''):
    # The GNU licenses a notice names, as [(family, minimum version, or later)], and whether it names
    # the GPL alone: not when the file's leading comments (`context`) grant an exception to it.
    text = normalize(block)
    exception = GPL_EXCEPTION.search(normalize(block + '\n' + context)) or SPDX_WITH.search(block + '\n' + context)
    requirements, gpl_only = [], False
    lgpl = LGPL_NAME.search(text)
    gpl = GPL_NAME.search(LGPL_NAME.sub(' ', text))
    later = bool(GNU_LATER.search(text))
    for family, match in (('LGPL', lgpl), ('GPL', gpl if not lgpl and not exception else None)):
        if match:
            version = re.search(GNU_VERSION, text[match.start():match.start() + 400], re.IGNORECASE)
            number = float((version.group(1) or version.group(2)) if version else 2)
            requirements.append((family, number, later or not version))
            gpl_only = gpl_only or family == 'GPL'
    if FDL_NAME.search(text):
        requirements.append(('FDL', 0.0, True))
    return requirements, gpl_only


def offered_gnu_licenses(block):
    # Every GNU license a notice that offers a choice of licenses names, as [(family, minimum version,
    # or later)], each with the version and "or later" between its name and the next license's name. A
    # family it names only without a version is version 2 or later.
    text = normalize(block)
    matches = list(GNU_ANY_NAME.finditer(text))
    names = sorted({m.start() for m in matches} | {m.start() for p in [e[1] for e in STANDARD_LICENSES]
                                                   + [r'mozilla\s+public\s+licen[cs]e|\bmpl\b']
                                                   for m in re.finditer(p, text, re.IGNORECASE)})
    found, versionless = set(), set()
    for match in matches:
        window = text[match.start():min([n for n in names if n > match.start()] + [len(text), match.start() + 400])]
        family = match.lastgroup.upper()
        version = re.search(GNU_VERSION, window, re.IGNORECASE)
        if family == 'FDL':
            found.add(('FDL', 0.0, True))
        elif version:
            found.add((family, float(version.group(1) or version.group(2)), bool(GNU_LATER.search(window))))
        else:
            versionless.add(family)
    found |= {(family, 2.0, True) for family in versionless - {f for f, _, _ in found}}
    return sorted(found)


def gnu_texts(text):
    # The GNU licenses a license text carries, as (family, version).
    found = set()
    for kind, version in re.findall(r'GNU\s+(LESSER\s+GENERAL|LIBRARY\s+GENERAL|GENERAL|FREE\s+DOCUMENTATION)'
                                    r'\s+(?:PUBLIC\s+)?LICEN[CS]E\s+Version\s+(\d(?:\.\d)?)', text, re.IGNORECASE):
        kind = kind.upper().split()[0]
        found.add(({'LESSER': 'LGPL', 'LIBRARY': 'LGPL', 'GENERAL': 'GPL', 'FREE': 'FDL'}[kind], float(version)))
    return found


def satisfies(texts, requirement):
    family, minimum, later = requirement
    return any(f == family and (v == minimum or (later and v >= minimum) or family == 'FDL') for f, v in texts)


def file_notice(blocks, where=''):
    # A file's notice as its parts, [(copyright notices, terms, kind)]: one for each comment that
    # grants terms ('grant') or points at them ('reference'), other than GNU terms; for each that
    # states GNU terms ('gnu'), or puts the file under the GPL alone ('gpl'); and for each that says
    # where code comes from without terms ('none'). Each takes the copyright notices of the comments
    # before it that hold nothing else; the last takes those after it, and in a file with no other
    # part they form a 'none' part with no text. A file under GNU terms that grants no others has only
    # its 'gpl' parts and those that name sections of a file: the GNU texts carry the rest, and the
    # license its other comments point at is the GNU one.
    parts, pending, gnu = [], [], False
    context = '\n'.join(blocks)
    for block in blocks:
        notices, terms = parse_block(block, where)
        text = normalize(block)
        if GNU_NAME(block) and not (GRANT.search(text) or ALTERNATIVE.search(text) or SPDX_OR.search(block)):
            gnu = True
            parts.append((pending + notices, terms, 'gpl' if gnu_terms(block, context)[1] else 'gnu'))
        elif terms:
            kind = 'none' if not TERMS.search(normalize(terms)) else 'grant' if GRANT.search(normalize(terms)) \
                else 'reference'
            parts.append((pending + notices, terms, kind))
        else:
            pending += notices
            continue
        pending = []
    if pending and parts:
        parts[-1] = (parts[-1][0] + pending, parts[-1][1], parts[-1][2])
        pending = []
    if gnu and not any(kind == 'grant' for _, _, kind in parts):
        return [part for part in parts if part[2] == 'gpl' or named_sections(part[1])]
    return parts + ([(pending, '', 'none')] if pending else [])


def files_named(labels, every=False):
    # The files of a group, by name when there are few or `every` asks, else by count and directories:
    # the deepest directories, at most four where their top directories allow, that hold them all
    # (the top directory standing for the files directly in it), those of generated files marked so.
    labels = sorted(labels)
    if len(labels) <= 3 or every:
        return labels[0] if len(labels) == 1 else ', '.join(labels[:-1]) + ' and ' + labels[-1]
    marker = ' (generated)'
    directories = {os.path.dirname(l[:-len(marker)] if l.endswith(marker) else l) for l in labels}
    while len(directories) > 4 and any('/' in d for d in directories):
        deepest = max(d.count('/') for d in directories)
        directories = {os.path.dirname(d) if d.count('/') == deepest else d for d in directories}
    directories = {d for d in directories if not any(o and o != d and d.startswith(o + '/') for o in directories)}

    def named(directory):
        inside = [l for l in labels if ((l + '/').startswith(directory + '/') if directory else '/' not in l)]
        return (directory + '/' if directory else 'the top directory') \
            + (marker if all(l.endswith(marker) for l in inside) else '')
    names = sorted(named(d) for d in directories)
    return '%d files in %s' % (len(labels), ', '.join(names[:-1]) + ' and ' + names[-1] if len(names) > 1 else names[0])


def named_licenses(terms):
    # The license files a notice's terms name, by name or as the last component of a URL; the source
    # files whose notice they name; and the standard licenses they name.
    text = normalize(terms)
    names = re.findall(r'([\w.-]*(?:LICEN[CS]E|COPYING|COPYRIGHT|README)[\w.-]*)\s+file\b', text, re.IGNORECASE)
    names += re.findall(r'\bfile,?\s+([\w.-]*(?:LICEN[CS]E|COPYING|COPYRIGHT|README)[\w.-]*)', text, re.IGNORECASE)
    names += re.findall(r'https?://[^\s<>]*/((?:LICEN[CS]E|COPYING)(?:\.\w+)?)(?=[\s>)"\']|$)', text, re.IGNORECASE)
    sources = re.findall(r'\b(?:notice|license) in ([\w-]+\.(?:h|inc|c))\b', text)
    standard = [entry[0] for entry in STANDARD_LICENSES if re.search(entry[1], terms, re.IGNORECASE)]
    return {n.strip('.').lower() for n in names}, set(sources), standard


def named_sections(terms):
    # The sections of files a notice's terms name, as [(file name, [section])]: "read the WARNING,
    # DISCLAIMER and PATENTS sections in the README file".
    found = []
    for sections, name in re.findall(r'\b(?:read|see)\s+the\s+((?:[A-Z]{2,}(?:,\s*|\s+and\s+))*[A-Z]{2,})\s+'
                                     r'sections?\s+(?:in|of)\s+the\s+([\w.-]+)\s+file', normalize(terms)):
        found.append((name, re.split(r',\s*|\s+and\s+', sections)))
    return found


def file_sections(text, sections):
    # The named sections of a text, each from its heading, a line of capitals alone, to the next; None
    # unless every named section is present and has text below its heading.
    heading = re.compile(r'^[A-Z][^a-z(]*?\s*(\(.*\))?\s*[:?]?\s*$')
    found, current = {}, None
    for line in text.split('\n'):
        if heading.match(line) and re.search(r'[A-Z]{2,}', line):
            name = line.strip().rstrip(':?').strip()
            current = name if name in sections else None
            if current:
                found.setdefault(current, [])
                found[current].append(line)
                continue
        if current:
            found[current].append(line)
    if set(found) != set(sections) or any(not '\n'.join(found[s][1:]).strip() for s in found):
        return None
    return '\n\n'.join('\n'.join(found[s]).strip('\n') for s in sections)


def above(path, label):
    # Whether a text at `path` is in the directory of the file at `label` or one above it.
    return (label + '/').startswith(os.path.dirname(path) + '/') if os.path.dirname(path) else True


def called(path, name):
    # Whether a text's file is the one a notice calls `name`: of that name, or with an extension, a
    # prefix or a project's name to it.
    base = os.path.basename(path.split(' -- ')[-1]).lower()
    return base == name or base.startswith(name + '.') or base.endswith(('-' + name, ' ' + name))


@functools.lru_cache(maxsize=None)
def copyright_holders(text):
    # The holders a text's copyright lines name.
    lines = [re.sub(r'^[\s*/#;•-]+', '', l) for l in text.split('\n')]
    return frozenset(holder(n) for _, n in paragraph_notices(lines)[0])


def holds(holders, name):
    # Whether a text whose copyright lines name `holders` names the holder `name`, as a whole name.
    pattern = re.compile(r'(?<!\w)%s(?!\w)' % re.escape(name)) if name else None
    return not name or any(name == h or pattern.search(h) for h in holders)


def template_copyright(text):
    # Whether a license text has a copyright line of template fields before its terms begin.
    for line in text.split('\n'):
        if TEMPLATE.search(line):
            return True
        if GRANT.search(normalize(line).lower()) or re.search(r'warrant|liabl', line, re.IGNORECASE):
            return False
    return False


def notice_texts(title, labelled, texts, everything, spdx, optional=(), member=lambda name, label: None,
                 withheld={}, gnu_standard=(), *, unnamed):
    # The notices of a section's compiled files that its texts do not carry, the standard license
    # texts they need, what the notices that grant no terms name that Legal.txt lacks, the labels of
    # the `optional` texts that carry a part the others do not, or that a part finds, and the
    # headings of the `gnu_standard` texts the notices find. `unnamed` gives the images holding a
    # file, by label, that the NOTICE's GPL sentence does not name.
    #
    # A part of a file's notice is carried when one text's copyright lines name every holder its
    # copyright notices, and those in its terms, name, the text holds each of its notices' lines that
    # is not a copyright statement and, for granted or GPL terms, each paragraph of the terms. A GNU part goes with the file's other parts. Each license a part
    # names is found:
    # - a license file of the name a paragraph gives, for the holders of the copyright notices in it
    #   (else the part's): in the file's own directory; else in the nearest directory above it naming
    #   one of them; else, for a part that names no standard license, the one in any section
    #   (`everything`, as (heading, text)) whose copyright lines name the most of them; else, but for
    #   granted terms, in the nearest directory above the file's. In each, holding the standard
    #   license the part names, if any. A text of the section that names the part's file stands for
    #   them.
    # - a standard license: in the part's own terms or a found file, else a text of the section,
    #   else the SPDX text (`spdx`, by identifier), which follows the terms when it opens with a
    #   template copyright line.
    # - a source file of the section: the text or group that carries its notice.
    # - sections of a file (`member` finds it, by name, at or above the file's): those sections.
    # - a GNU license: the GNU text among the section's texts, else among those its library leaves out
    #   (`withheld`, {label: text}), which the section then carries, else among `gnu_standard`, as
    #   (heading, text); for a notice that offers it, the one text that carries every version it
    #   names, and the GNU text stands for the file of its name.
    # A notice that offers a choice of licenses finds one of them: the first it names that a text of
    # the section governing it carries, else the first it names, its own granted terms among them. A
    # file that takes the GPL so must be in images only the NOTICE's GPL sentence names.
    # A part with no terms of its own falls under an `optional` text that names a holder of it, else
    # under the license files of the nearest directory at or above the file's, else under the texts
    # of the section nearest its top whose copyright lines name all its holders. A text of the
    # section that grants nothing and only names standard licenses needs them as a notice does: from
    # the section, else the SPDX text, which the section then carries. Files whose uncarried parts
    # state the same terms and find the same texts group: each part its files' copyright notices over
    # its terms. A group is (label, text, (key, [notices], [terms], [found headings])), the key naming
    # its terms and kinds; a text the notices find is (label, text, None).
    carried = [(label, normalize(t).lower(), copyright_holders(t)) for label, t in texts]
    others = [(heading, normalize(t).lower(), copyright_holders(t)) for heading, t in everything]
    compiled = {os.path.basename(label) for label, _ in labelled}
    gnu_of = [(l, gnu_texts(t)) for l, t in texts] + [(l, gnu_texts(t)) for l, t in sorted(withheld.items())] \
        + [(h, gnu_texts(t)) for h, t in gnu_standard]
    gnu = set().union(*[g for _, g in gnu_of])
    groups, unresolved, added, used, carrier, standard_used = {}, [], {}, set(), {}, set()

    def gnu_text(index):
        # The heading of the GNU text at `index` of gnu_of, as (heading, {label: text} the section then
        # carries, {heading} of gnu_standard).
        name = gnu_of[index][0]
        if index < len(texts):
            return '%s -- %s' % (title, name), {}, set()
        if index < len(texts) + len(withheld):
            return '%s -- %s' % (title, name), {name: withheld[name]}, set()
        return name, {}, {name}

    def nearest(candidates):
        deepest = max([l.count('/') for l in candidates] or [0])
        return [l for l in candidates if l.count('/') == deepest]

    def topmost(candidates):
        shallowest = min([l.count('/') for l in candidates] or [0])
        return [l for l in candidates if l.count('/') == shallowest]
    signatures_of = dict((e[0], e[2]) for e in STANDARD_LICENSES)
    for label, text in texts:
        if label in optional or GRANT.search(normalize(text)):
            continue
        parts = file_notice([text], '%s -- %s' % (title, label))
        if not parts or any(kind != 'reference' for _, _, kind in parts):
            continue
        for identifier in sorted({i for _, terms, _ in parts for i in named_licenses(terms)[2]}):
            if any(re.search(signatures_of[identifier], t) for _, t, _ in carried):
                continue
            if identifier in spdx and not template_copyright(spdx[identifier][1]):
                added[spdx[identifier][0]] = spdx[identifier][1]
            else:
                unresolved.append('%s -- %s names the %s text, which build_deps.sh\'s SPDX_TEXTS lacks'
                                  % (title, label, identifier))
    for label, blocks in labelled:
        parts = []
        for notices, terms, kind in file_notice(blocks, '%s -- %s' % (title, label)):
            inner = [n for _, n in paragraph_notices(terms.split('\n'))[0]]
            needed = [holder(n) for n in notices + inner]
            paragraphs = [normalize(p).lower() for p in re.split(r'\n\s*\n', terms) if p.strip()]
            attributions = [normalize(l).lower() for n in notices for l in n.split('\n')
                            if not is_copyright(l) and not re.match(r'\(?<?\d{4}\b', l)]
            carriers = [l for l, t, h in sorted(carried, key=lambda c: c[0] in optional)
                        if all(holds(h, n) for n in needed) and all(o in t for o in attributions)
                        and (kind in ('reference', 'none') or all(p in t for p in paragraphs))]
            if carriers and kind != 'gnu' and not named_sections(terms):
                used.add(carriers[0])
                carrier.setdefault(os.path.basename(label), '%s -- %s' % (title, carriers[0]))
                continue
            names, sources, standard = named_licenses(terms)
            holders = [h for h in needed if h]
            alternative = ALTERNATIVE.search(normalize(terms)) or SPDX_OR.search(terms)
            found, missing, absent, section_found = [], [], [], []
            for name, sections in named_sections(terms):
                file = member(name, label)
                body = file and file_sections(file[1], sections)
                if not body:
                    absent.append('the %s sections of %s' % (', '.join(sections), name))
                    continue
                shown = '%s (%s)' % (file[0], ', '.join(sections))
                added[shown] = body
                section_found.append('%s -- %s' % (title, shown))
            if kind == 'none':
                found = ['%s -- %s' % (title, l) for l, t, _ in carried
                         if l in optional and any(h in t for h in holders)] or \
                        ['%s -- %s' % (title, l) for l in nearest(
                            [l for l, _, _ in carried if above(l, label) and l not in optional
                             and re.match(r'(licen[cs]e|copying)', os.path.basename(l), re.IGNORECASE)])] or \
                        ['%s -- %s' % (title, l) for l in topmost(
                            [l for l, _, h in carried if holders and l not in optional
                             and all(holds(h, n) for n in holders)])]
            elif kind in ('gnu', 'gpl'):
                requirements = gnu_licenses(terms)[0]
                fitting = [n for n, (_, g) in enumerate(gnu_of) if any(satisfies(g, r) for r in requirements)]
                if fitting:
                    heading, carries, standards = gnu_text(fitting[0])
                    found, standard_used = [heading], standard_used | standards
                    added.update(carries)
                else:
                    unresolved.append('%s -- %s names a GNU license no text here or in GNU_TEXTS carries'
                                      % (title, label))
            else:
                text = normalize(terms)
                signatures = [dict((e[0], e[2]) for e in STANDARD_LICENSES)[i] for i in standard]
                # The licenses the part names, each as [where the terms first name it, found headings,
                # what it lacks, {label: text} and gnu_standard headings it adds, terms it appends, and
                # whether one of the section's governing texts carries it, and whether it is the GPL].
                options = []

                def option(position, headings=(), lacks=(), carries=None, standards=(), appended='',
                           governing=False, gpl=False):
                    options.append([position, list(headings), list(lacks), dict(carries or {}), set(standards),
                                    appended, governing, gpl])

                def governs(heading):
                    return heading.startswith(title + ' -- ') and heading.split(' -- ', 1)[1] in dict(texts) \
                        and heading.split(' -- ', 1)[1] not in optional

                gnu_names = list(GNU_ANY_NAME.finditer(text)) if alternative else []
                for family in sorted({f for f, _, _ in offered_gnu_licenses(terms)} if alternative else []):
                    requirements = [r for r in offered_gnu_licenses(terms) if r[0] == family]
                    position = min(m.start() for m in gnu_names if m.lastgroup.upper() == family)
                    every = [n for n, (_, g) in enumerate(gnu_of) if all(satisfies(g, r) for r in requirements)]
                    picked = [[n for n, (_, g) in enumerate(gnu_of) if satisfies(g, r)][:1] for r in requirements] \
                        if not every else [every[:1]]
                    lacks = ['the %s %s%s, which no text here or in GNU_TEXTS carries'
                             % (r[0], r[1], ' or later' if r[2] else '')
                             for r, n in zip(requirements, picked) if not n and not every]
                    chosen = [gnu_text(n[0]) for n in picked if n]
                    option(position, [h for h, _, _ in chosen], lacks,
                           dict(i for _, c, _ in chosen for i in c.items()), set().union(*[s for _, _, s in chosen]),
                           governing=bool(chosen) and all(n[0] < len(texts) for n in picked if n) and not lacks,
                           gpl=family == 'GPL')
                if alternative and kind == 'grant':
                    option(GRANT.search(text).start())

                def fitting(text):
                    return not signatures or any(re.search(p, text) for p in signatures)
                listing = [l for l, _, _ in carried if names and '/' in label and label in dict(texts)[l]]
                found += ['%s -- %s' % (title, l) for l in listing]
                sectioned = {name.lower() for name, _ in named_sections(terms)}
                for paragraph in [] if listing else re.split(r'\n\s*\n', terms):
                    near = [holder(n) for _, n in paragraph_notices(paragraph.split('\n'))[0]] or holders
                    for name in sorted(named_licenses(paragraph)[0] - sectioned):
                        if gnu_names and any(called(l, name) for l, g in gnu_of if g):
                            continue
                        local = [l for l, t, _ in carried if called(l, name) and above(l, label) and l not in optional
                                 and fitting(t)]
                        naming = [l for l in nearest(local) if any(holds(dict((c[0], c[2]) for c in carried)[l], n)
                                                                   for n in near)]
                        across = sorted((-sum(holds(h, n) for n in near), '/' in heading.split(' -- ', 1)[1],
                                         not heading.startswith(title + ' -- '), heading)
                                        for heading, t, h in others
                                        if not standard and called(heading, name) and any(holds(h, n) for n in near))
                        here = [l for l in local if os.path.dirname(l) == os.path.dirname(label)]
                        named = re.search(r'(?<![\w.-])%s\s+file\b|\bfile,?\s+%s(?![\w.-])|/%s(?![\w.-])'
                                          % ((re.escape(name),) * 3), text, re.IGNORECASE)
                        position = named.start() if named else len(text)
                        if here:
                            headings = ['%s -- %s' % (title, l) for l in here]
                        elif naming:
                            headings = ['%s -- %s' % (title, l) for l in naming]
                        elif across:
                            headings = [across[0][3]]
                        elif local and kind != 'grant':
                            headings = ['%s -- %s' % (title, l) for l in nearest(local)]
                        else:
                            headings = []
                        if headings or not standard:
                            option(position, headings, [] if headings else [name],
                                   governing=bool(headings) and all(governs(h) for h in headings))
                texts_of = dict((h, t) for h, t, _ in others)
                for identifier, signature in zip(standard, signatures):
                    entry = [e for e in STANDARD_LICENSES if e[0] == identifier][0]
                    named = re.search(entry[1], text, re.IGNORECASE)
                    position = named.start() if named else len(text)
                    own = [l for l, t, _ in carried if re.search(signature, t) and l not in optional]
                    holding = [o for o in options if any(re.search(signature, texts_of.get(f, '')) for f in o[1])]
                    if re.search(signature, text.lower()) or any(re.search(signature, texts_of.get(f, '')) for f in found):
                        option(position)
                    elif holding:
                        holding[0][0] = min(holding[0][0], position)
                    elif own:
                        option(position, ['%s -- %s' % (title, min(own, key=lambda l: (
                            not above(l, label), -l.count('/') if above(l, label) else l.count('/'), l)))],
                               governing=True)
                    elif identifier in spdx and template_copyright(spdx[identifier][1]):
                        option(position, appended='\n\n' + '\n'.join(
                            l for l in spdx[identifier][1].split('\n') if not TEMPLATE.search(l)).strip('\n'))
                    elif identifier in spdx:
                        option(position, ['%s -- %s' % (title, spdx[identifier][0])],
                               carries={spdx[identifier][0]: spdx[identifier][1]})
                    else:
                        option(position, lacks=['the %s text, which build_deps.sh\'s SPDX_TEXTS lacks' % identifier])
                if alternative and options:
                    options = [min([o for o in options if o[6]] or options, key=lambda o: o[0])]
                    unresolved.extend('%s -- %s names %s' % (title, label, lack) for lack in options[0][2])
                    if options[0][7] and unnamed(label):
                        fail('%s -- %s takes the GPL among the licenses it offers and is in %s, which the GPL '
                             'sentence of AquaWebKitSupport/NOTICE does not name'
                             % (title, label, ', '.join(unnamed(label))))
                for _, headings, lacks, carries, standards, appended, _, _ in options:
                    found += headings
                    missing += [] if alternative else lacks
                    added.update(carries)
                    standard_used |= standards
                    terms += appended
                found += ['\0' + source for source in sorted(sources & compiled)]
                missing += sorted(sources - compiled)
            found += section_found
            if missing and kind != 'grant':
                unresolved.append('%s -- %s names %s' % (title, label, ', '.join(missing)))
            if absent:
                unresolved.append('%s -- %s names %s' % (title, label, ', '.join(absent)))
            parts.append((notices, terms, kind, tuple(sorted(set(found)))))
        if all(kind == 'gnu' for _, _, kind, _ in parts):
            continue
        key = tuple((normalize(terms).lower(), kind, found) for _, terms, kind, found in parts)
        group = groups.setdefault(key, [[[] for _ in parts], [terms for _, terms, _, _ in parts], set()])
        for index, (notices, _, _, _) in enumerate(parts):
            group[0][index] += [n for n in notices]
        group[2].add(label)
    # Each group's files, by count and directories, and by name where two groups would read alike.
    names = {key: files_named(labels) for key, (_, _, labels) in groups.items()}
    for key, (_, _, labels) in groups.items():
        if list(names.values()).count(names[key]) > 1:
            names[key] = files_named(labels, every=True)
    headings = {}
    for key, (_, _, labels) in groups.items():
        for name in labels:
            headings.setdefault(os.path.basename(name), '%s -- notices in %s' % (title, names[key]))
    found = []
    for key, (notices, terms, labels) in groups.items():
        under = sorted({headings.get(f[1:]) or carrier.get(f[1:]) if f.startswith('\0') else f
                        for _, _, named in key for f in named} - {None})
        used |= {u.split(' -- ', 1)[1] for u in under if u.startswith(title + ' -- ')}
        found.append(('notices in %s' % names[key] + (', under ' + ', '.join('"%s"' % u for u in under)
                                                      if under else ''), notice_text(notices, terms),
                      (tuple(k[:2] for k in key), notices, terms, under)))
    return [(l, t, None) for l, t in sorted(added.items())] + sorted(found, key=lambda f: f[:2]), unresolved, \
        used & set(optional), standard_used


def notice_text(notices, terms):
    # A group's text: each part's copyright notices over its terms.
    return '\n\n'.join('\n'.join(listed_notices(n)) + ('\n\n' if n and t else '') + t for n, t in zip(notices, terms))


def listed_notices(notices):
    # Copyright notices, once each, in order of holder.
    listed = []
    for notice in notices:
        if notice not in listed:
            listed.append(notice)
    return sorted(listed, key=lambda n: (holder(n), n))


# --- sections -------------------------------------------------------------------------------------

def not_governing():
    excluded = {name: dict(files) for name, files in NOT_GOVERNING.items()}
    config = os.path.join(TREES, 'build-ffmpeg', 'config.h')
    if not os.path.isfile(config):
        fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % config)
    license = re.search(r'^#define FFMPEG_LICENSE "(.*)"$', read(config), re.MULTILINE)
    if not license or license.group(1) not in FFMPEG_LICENSES:
        fail('%s names no license in FFMPEG_LICENSES' % config)
    excluded['FFmpeg'] = {name: 'another configuration than "%s"' % license.group(1)
                          for texts in FFMPEG_LICENSES.values() for name in texts
                          if name not in FFMPEG_LICENSES[license.group(1)]}
    return excluded


def third_party_sections():
    # {library: [(label, text)]}, {library: {label: text}} of the texts left out, {tarball top: library},
    # {tree label: library}, {library: (tarball, its names)} and {fetched file: library}.
    _, variables = build_deps_script()
    excluded_names = not_governing()
    found, excluded, tops, urls, tarballs, fetched = {}, {}, {}, {}, {}, {}
    for url in build_deps_urls():
        if any(re.search(pattern, url) for pattern in NOT_HERE + LICENSE_TEXTS + PART_OF):
            continue
        matches = [entry for entry in SHIPPED if is_tarball(url) and re.search(entry[1], url)]
        if matches:
            name, _, extras = matches[0]
            urls[url] = name
            if name not in found:
                names, texts = tarball_licenses(cached_tarball(url), list(extras))
                tops[names[0].split('/')[0]] = name
                tarballs[name] = (cached_tarball(url), names)
                labels = {label for label, _ in texts}
                missing = set(excluded_names.get(name, {})) - labels
                if missing:
                    fail('%s has no %s' % (name, ', '.join(sorted(missing))))
                excluded[name] = {l: t for l, t in texts if l in excluded_names.get(name, {})}
                found[name] = [(l, t) for l, t in texts if l not in excluded_names.get(name, {})]
            continue
        matches = [entry for entry in SHIPPED_FILES if re.search(entry[1], url)]
        if not matches:
            fail('%s matches nothing in SHIPPED, SHIPPED_FILES, LICENSE_TEXTS, PART_OF or NOT_HERE' % url)
        name, _, license_name, license_label, copies = matches[0]
        urls[url] = name
        if copies:
            for path in glob.glob(os.path.join(TARBALLS, copies.format(**variables))):
                fetched[os.path.realpath(path)] = name
        if name not in found:
            path = os.path.join(TARBALLS, license_name.format(**variables))
            if not os.path.isfile(path):
                fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
            found[name] = [(license_label, read(path))]
    missing = [entry[0] for entry in SHIPPED + SHIPPED_FILES if entry[0] not in found]
    if any(copies for _, _, _, _, copies in SHIPPED_FILES) and not fetched:
        fail('none of the files SHIPPED_FILES names is in %s' % TARBALLS)
    if missing:
        fail('no build_deps.sh URL for ' + ', '.join(missing))
    trees = {label: urls[url] for label, url in tree_urls().items() if url in urls}
    return found, excluded, tops, trees, tarballs, fetched


def tarball_paths(tarballs):
    # {path below a library tarball's top: the library}, for the paths only one tarball holds.
    owners = {}
    for name, (_, names) in tarballs.items():
        top = names[0].split('/')[0]
        for entry in names:
            relative = entry[len(top) + 1:]
            if relative and not relative.endswith('/'):
                owners[relative] = name if owners.get(relative, name) == name else None
    return owners


def section_of(key, tops, trees, owners, fetched={}):
    # (section, the file's name in it) of a compiled file, or None for a system or installed file. A
    # file of a tree unpacked under no label belongs to the library whose tarball holds its path.
    if key.startswith('manifest:'):
        _, label, name = key.split(':', 2)
        return (trees[label], name) if label in trees else None
    if key in fetched:
        return fetched[key], os.path.basename(key)
    if under(key, SOURCE):
        return 'WebKit', os.path.relpath(key, SOURCE)
    if under(key, SHARED):
        return POLYFILL, os.path.relpath(key, SHARED)
    if under(key, TREES):
        parts = os.path.relpath(key, TREES).split(os.sep)
        if parts[0] in SOURCE_COPIES:
            return 'WebKit', os.path.join(SOURCE_COPIES[parts[0]], *parts[1:])
        for i in range(len(parts) - 1, 0, -1):
            if parts[i] in tops:
                return tops[parts[i]], '/'.join(parts[i + 1:])
        if parts[0].startswith('build-') and parts[0][len('build-'):] in trees:
            return trees[parts[0][len('build-'):]], '/'.join(parts[1:])
        if owners.get('/'.join(parts[1:])):
            return owners['/'.join(parts[1:])], '/'.join(parts[1:])
        return None
    if under(key, SUPPORT) and not under(key, DEPS) and not under(key, TOOLCHAIN):
        return AQUA, os.path.relpath(key, REPO)
    if under(key, REPO) and not under(key, SUPPORT) and not under(key, os.path.join(REPO, 'WebKitBuild')):
        return 'WebKit', os.path.relpath(key, REPO)
    return None


class Placer:
    # The sections each compiled file belongs to, and its name in each. A file that no path rule places
    # is a copy of another file, found by name and content: in the WebKit source, the port's files, a
    # tree, or a manifest (manifests record the content of the trees they record). Failing that, it is
    # the library tarball file with the same last two path components, or else the same name: the one
    # library that has such a file or, when several have one of two components, the one whose file has
    # the same content (a header configured from a template, for example). A copy of files from
    # several sections belongs to each of them. Failing that, a file under WebKitBuild is the one
    # source file of its name with its leading comments, or else one WebKit's build generates; and a
    # file generated in a tree, or installed beside other files, belongs to the one library that the
    # other placed files of its tree or of its installed directory belong to. Any other file in the
    # repository outside the toolchain fails.

    def __init__(self, compiled, keys, tops, trees, owners, tarballs, fetched):
        self.places, self.digests = {}, {}
        pending = []
        for key in keys:
            if key.startswith('manifest:') or (under(key, REPO) and not under(key, TOOLCHAIN)):
                place = section_of(key, tops, trees, owners)
                if place:
                    self.places[key] = [place]
                else:
                    pending.append(key)
        names = {os.path.basename(k) for k in pending}
        candidates = {}
        skip = {DEPS, TOOLCHAIN, POLYFILL_BUILD}
        roots = [SOURCE, SUPPORT] + [os.path.join(TREES, d) for d in os.listdir(TREES)
                                     if d not in NOT_TREES and os.path.isdir(os.path.join(TREES, d))]
        for root in roots:
            for directory, subdirectories, files in os.walk(root):
                subdirectories[:] = [d for d in subdirectories if os.path.join(directory, d) not in skip]
                for name in files:
                    if name in names:
                        candidates.setdefault(name, []).append(os.path.realpath(os.path.join(directory, name)))
        for key, digest in compiled.hashes.items():
            name = os.path.basename(key.split(':', 2)[2])
            if name in names:
                candidates.setdefault(name, []).append(key)
                self.digests[key] = digest
        entries = {}
        for library, (path, names_in) in tarballs.items():
            for entry in names_in:
                if os.path.basename(entry) in names:
                    entries.setdefault(os.path.basename(entry), set()).add((library, path, entry))
        fetched_digests = {self.digest(path): name for path, name in fetched.items()}
        later = []
        for key in pending:
            digest = self.digest(key)
            if digest in fetched_digests:
                self.places[key] = [(fetched_digests[digest], os.path.basename(key))]
                continue
            origins = sorted({section_of(c, tops, trees, owners, fetched) for c in candidates.get(os.path.basename(key), [])
                              if c != key and self.digest(c) == digest} - {None})
            if not origins and not under(key, BUILD):
                # A library tarball's file of the same last two path components, else of the same name:
                # the one library's that holds one or, among several with two components, the one of
                # this content.
                parts = key.split(os.sep)
                for suffix in ('/'.join(parts[-2:]), parts[-1]):
                    named = sorted(n for n in entries.get(parts[-1], ()) if ('/' + n[2]).endswith('/' + suffix))
                    if len({n[0] for n in named}) > 1 and '/' in suffix:
                        named = [n for n in named
                                 if hashlib.sha256(tarball_member(n[1], n[2], raw=True)).hexdigest() == digest]
                    if len({n[0] for n in named}) == 1:
                        origins = [(n[0], n[2].split('/', 1)[1]) for n in named]
                        break
            if origins:
                self.places[key] = [o for o in origins if o[0] not in {p[0] for p in origins[:origins.index(o)]}]
            elif under(key, BUILD):
                # A copy WebKit's build makes of a source file, with its notice, else a file it generates.
                copies = [c for c in candidates.get(os.path.basename(key), []) if under(c, SOURCE)
                          and compiled.leading_comments(c) == compiled.leading_comments(key)]
                self.places[key] = [section_of(copies[0], tops, trees, owners) if len(copies) == 1
                                    else ('WebKit', os.path.relpath(key, BUILD) + ' (generated)')]
            elif under(key, TREES) and os.path.relpath(key, TREES).split(os.sep)[0] not in NOT_TREES:
                later.append((key, os.path.join(TREES, os.path.relpath(key, TREES).split(os.sep)[0])))
            else:
                later.append((key, os.path.dirname(key)))
        # A file generated in a tree, or installed beside others, belongs to the one library the other
        # placed files of its tree, or of its installed directory, belong to.
        for key, scope in later:
            libraries = {place[0] for k, places in self.places.items()
                         if (under(k, scope) if under(key, TREES) and scope != os.path.dirname(key)
                             else os.path.dirname(k) == scope) for place in places}
            if len(libraries) != 1:
                fail('%s is a compiled file no section holds: the files beside it belong to %s'
                     % (key, ', '.join(sorted(libraries)) or 'no library'))
            self.places[key] = [(libraries.pop(), os.path.relpath(key, scope) if under(key, TREES)
                                 and scope != os.path.dirname(key) else os.path.basename(key))]

    def digest(self, path):
        if path not in self.digests:
            self.digests[path] = compiled_sources.sha256(path)
        return self.digests[path]


def stock_names(notice):
    # The images whose i386 code the NOTICE's 32-bit sentences say is stock OS X 10.9.5's.
    return set(re.findall(r'[A-Za-z][\w]*', ' '.join(re.findall(r'[^.]*32-bit[^.]*\.', notice))))


def openstep_plist(text):
    # The value an old-style (OpenStep) property list holds, as an Xcode project file writes one.
    position, length = 0, len(text)
    token = re.compile(r'[^\s;,=(){}"]+')
    quoted = re.compile(r'"((?:[^"\\]|\\.)*)"', re.DOTALL)

    gap = re.compile(r'(?:\s+|/\*.*?\*/|//[^\n]*)*', re.DOTALL)

    def skip():
        nonlocal position
        position = gap.match(text, position).end()

    def value():
        nonlocal position
        skip()
        if text[position] == '{':
            position += 1
            result = {}
            while True:
                skip()
                if text[position] == '}':
                    position += 1
                    return result
                key = value()
                skip()
                position += 1
                result[key] = value()
                skip()
                position += 1
        if text[position] == '(':
            position += 1
            result = []
            while True:
                skip()
                if text[position] == ')':
                    position += 1
                    return result
                result.append(value())
                skip()
                if text[position] == ',':
                    position += 1
        if text[position] == '"':
            match = quoted.match(text, position)
            position = match.end()
            return re.sub(r'\\(.)', r'\1', match.group(1))
        match = token.match(text, position)
        position = match.end()
        return match.group(0)
    return value()


def xcode_sources(text, project):
    # What the Sources build phases of an Xcode project's framework and static-library targets compile:
    # the repository's files, as paths in it (`project` is the directory that holds the .xcodeproj),
    # and the files the build generates, as paths in its built-products directory. Fails on a
    # reference that is neither.
    root = openstep_plist(text)
    objects = root['objects']
    parents = {child: identifier for identifier, entry in objects.items()
               if entry.get('isa') in ('PBXGroup', 'PBXVariantGroup') for child in entry.get('children', [])}

    def path(identifier):
        # (base, path): base 'source' for the repository, 'built' for the built-products directory.
        entry = objects[identifier]
        tree = entry.get('sourceTree', '<group>')
        if tree == '<group>':
            base, parent = path(parents[identifier]) if identifier in parents else ('source', project)
            return base, os.path.normpath(os.path.join(parent, entry.get('path', '')))
        if tree == 'SOURCE_ROOT':
            return 'source', os.path.normpath(os.path.join(project, entry.get('path', '')))
        if tree == 'BUILT_PRODUCTS_DIR':
            return 'built', os.path.normpath(entry.get('path', ''))
        fail('%s in %s lies in %s, outside the project and its build' % (entry.get('path'), project, tree))
    sources, derived = set(), set()
    for target in objects[root['rootObject']]['targets']:
        entry = objects[target]
        if entry.get('productType') not in ('com.apple.product-type.framework', 'com.apple.product-type.library.static'):
            continue
        for phase in entry.get('buildPhases', []):
            if objects[phase].get('isa') == 'PBXSourcesBuildPhase':
                for build_file in objects[phase].get('files', []):
                    reference = objects[build_file].get('fileRef')
                    if not reference:
                        fail('a build file of %s in %s names no file' % (entry.get('name'), project))
                    base, found = path(reference)
                    (sources if base == 'source' else derived).add(found)
    return sources, derived


def xcconfig_value(text, name, settings):
    # A build setting an .xcconfig file defines, expanded against its others and `settings`.
    values = dict(settings)
    for key, value in re.findall(r'^\s*([A-Za-z_][\w]*)\s*=\s*(.*?);?\s*$', text, re.MULTILINE):
        values.setdefault(key, value)

    def expand(value, depth=0):
        if depth > 20:
            fail('%s does not resolve in an .xcconfig file' % name)
        return re.sub(r'\$\((\w+)\)', lambda m: expand(values.get(m.group(1), ''), depth + 1), value)
    return ' '.join(expand(values.get(name, '')).split())


def derived_inputs(tree, project, outputs):
    # {derived output: the files of the tag's tree that its DerivedSources.make rule reads}, by a dry
    # run of that makefile as the project's Xcode build runs it (`make -n -d` remakes only the
    # makefiles it includes): an output is the target of a rule, a file a rule's recipe names, or the
    # source its rule's header writes beside it. An output none of those names belongs to the explicit
    # rule whose recipe writes it when run, trying the rules that make the other outputs first. The
    # inputs are the rule's prerequisites, and theirs. Fails on an output no rule makes.
    name = os.path.basename(project)
    makefile = os.path.join(tree, project, 'DerivedSources.make')
    if not os.path.isfile(makefile):
        fail('%s at %s has no DerivedSources.make for %s' % (project, STOCK_TAG, ', '.join(sorted(outputs)[:3])))
    features = os.path.join(tree, project, 'Configurations', 'FeatureDefines.xcconfig')
    environment = dict(os.environ, OS='MACOS', PLATFORM_NAME='macosx', ACTION='build')
    environment[name] = os.path.join(tree, project)
    if os.path.isfile(features):
        environment['FEATURE_DEFINES'] = xcconfig_value(read(features), 'FEATURE_DEFINES',
                                                        {'PLATFORM_NAME': 'macosx', 'TARGET_MAC_OS_X_VERSION_MAJOR': '1090'})
    work = tempfile.mkdtemp()
    try:
        trace = subprocess.run(['make', '-n', '-k', '-d', '--no-builtin-rules', '-f', makefile, 'all']
                               + sorted({os.path.basename(o) for o in outputs}), cwd=work,
                               env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout
    finally:
        shutil.rmtree(work)
    lines = trace.decode('utf-8', 'replace').split('\n')
    debug = re.compile(r'^(\s|Reading|Updating|Considering|Must|Successfully|Finished|Pruning|File |Looking|'
                       r'Trying|Found|No |Avoiding|Rejecting|Stem|GNU Make|Built for|Copyright|This is free|'
                       r'There is NO|PARTICULAR|make)')
    quoted = re.compile(r"(?:Pruning file|Considering target file|as VPATH) `([^']+)'")
    rules, opened, implicit = {}, {}, set()
    for index, line in enumerate(lines):
        match = re.search(r"Considering target file `([^']+)'", line)
        if match:
            opened[match.group(1)] = index
        match = re.search(r"Found an implicit rule for `([^']+)'", line)
        if match:
            implicit.add(match.group(1))
        match = re.search(r"Finished prerequisites of target file `([^']+)'", line)
        if match:
            target = match.group(1)
            prerequisites = {m for l in lines[opened.get(target, index):index] for m in quoted.findall(l)} - {target}
            rules[target] = (prerequisites, rules.get(target, (None, ''))[1])
        match = re.search(r"Must remake target `([^']+)'", line)
        if match:
            commands = []
            for later in lines[index + 1:]:
                if debug.match(later):
                    break
                commands.append(later)
            target = match.group(1)
            rules[target] = (rules.get(target, (set(), ''))[0], ' '.join(commands))
    if not rules:
        fail('a dry run of %s remakes nothing' % makefile)

    def inputs(target, seen):
        # A relative prerequisite is generated, or one of the project's files the makefile's VPATH finds.
        found = set()
        for prerequisite in rules[target][0]:
            path = os.path.realpath(prerequisite if os.path.isabs(prerequisite) else os.path.join(tree, project, prerequisite))
            if under(path, os.path.realpath(tree)) and os.path.isfile(path):
                found.add(os.path.relpath(path, os.path.realpath(tree)))
            elif prerequisite in rules and prerequisite not in seen:
                found |= inputs(prerequisite, seen | {prerequisite})
        return found
    traced, makers, unnamed = {}, set(), []
    for output in outputs:
        base = os.path.basename(output)
        stem = os.path.splitext(base)[0]
        found = [t for t in rules if t == base and (rules[t][0] or rules[t][1])] \
            or [t for t, (_, command) in rules.items() if re.search(r'(^|[\s/])%s(\s|$)' % re.escape(base), command)] \
            or [t for t in rules if t == stem + '.h' and rules[t][1]]
        if found:
            traced[output] = inputs(found[0], {found[0]})
            makers.add(found[0])
        else:
            unnamed.append(output)
    if unnamed:
        work = tempfile.mkdtemp()
        try:
            for target, (_, command) in sorted(rules.items(), key=lambda rule: rule[0] not in makers):
                if not command or target in implicit or not unnamed:
                    continue
                before = set(os.listdir(work))
                subprocess.run(['/bin/sh', '-c', command], cwd=work, env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                written = set(os.listdir(work)) - before
                for output in [o for o in unnamed if os.path.basename(o) in written]:
                    traced[output] = inputs(target, {target})
                    unnamed.remove(output)
        finally:
            shutil.rmtree(work)
    if unnamed:
        fail('%s/DerivedSources.make at %s has no rule that makes %s' % (project, STOCK_TAG, ', '.join(sorted(unnamed))))
    return traced


def stock_sources(names):
    # The files of the release the stock i386 slices were built from (STOCK_TAG) that their code comes
    # from, by project directory, with the tag's file list and a reader of its files. The projects are
    # the frameworks of `names` and the static libraries their builds link. A project's files are those
    # its Xcode project's frameworks and static libraries compile, the inputs of the files their build
    # generates, the headers beside the compiled files, and the headers under the project's relative
    # header search paths. Each stock framework's version is the tag's, or a release whose tag differs
    # from it in that project only by its version.
    shown = {}

    def git(*arguments):
        if arguments not in shown:
            shown[arguments] = subprocess.check_output(['git', '-C', REPO] + list(arguments)).decode('utf-8', 'replace')
        return shown[arguments]
    if subprocess.call(['git', '-C', REPO, 'rev-parse', '-q', '--verify', STOCK_TAG + '^{commit}'],
                       stdout=subprocess.DEVNULL) != 0:
        fail('the repository has no tag %s, the release of the stock i386 slices' % STOCK_TAG)
    files = git('ls-tree', '-r', '--name-only', STOCK_TAG, '--', 'Source/').split('\n')
    present = set(files)
    projects = ['Source/' + n for n in sorted(names) if any(f.startswith('Source/%s/' % n) for f in files)]
    for name in [p[len('Source/'):] for p in projects]:
        bundles = [os.path.join(d, name + '.framework') for d, subdirectories, _ in os.walk(STOCK)
                   if name + '.framework' in subdirectories]
        for bundle in bundles:
            version = plistlib.loads(open(os.path.join(bundle, 'Versions', 'A', 'Resources', 'Info.plist'), 'rb')
                                     .read())['CFBundleVersion']
            release = 'Safari-' + version[1:]
            project = 'Source/' + name
            if release != STOCK_TAG and (subprocess.call(['git', '-C', REPO, 'rev-parse', '-q', '--verify',
                                                          release + '^{commit}'], stdout=subprocess.DEVNULL) != 0
                                         or any(not f.endswith('/Version.xcconfig') for f in git(
                                             'diff', '--name-only', release, STOCK_TAG, '--', project).split())):
                fail('stock %s is %s, which %s does not build' % (name, version, STOCK_TAG))
    pending = list(projects)
    while pending:
        project = pending.pop()
        linked = set()
        for path in files:
            if path.startswith(project + '/') and path.endswith(('.xcconfig', 'project.pbxproj')):
                text = git('show', '%s:%s' % (STOCK_TAG, path))
                linked |= set(re.findall(r'(?<![\w-])-l(\w+)', text))
                linked |= set(re.findall(r'\blib(\w+)\.a in Frameworks', text))
        for library in linked:
            for path in files:
                if path.endswith('project.pbxproj') and 'path = lib%s.a;' % library in git('show', '%s:%s' % (STOCK_TAG, path)):
                    owner = os.path.dirname(os.path.dirname(path))
                    if owner not in projects:
                        projects.append(owner)
                        pending.append(owner)
    compiled, tree = {}, None
    try:
        for project in projects:
            sources, derived = set(), set()
            for path in files:
                if path.startswith(project + '/') and path.endswith('.xcodeproj/project.pbxproj') \
                        and os.path.dirname(os.path.dirname(path)) == project:
                    compiled_here, generated = xcode_sources(git('show', '%s:%s' % (STOCK_TAG, path)), project)
                    missing = compiled_here - present
                    if missing:
                        fail('%s at %s compiles %s, which the tag lacks' % (project, STOCK_TAG, ', '.join(sorted(missing)[:3])))
                    sources |= compiled_here
                    derived |= generated
            if not sources:
                fail('%s at %s compiles nothing' % (project, STOCK_TAG))
            for directory in sorted({os.path.dirname(d) for d in derived}):
                owner = 'Source/' + os.path.basename(directory)
                if os.path.dirname(directory) != 'DerivedSources' or owner + '/DerivedSources.make' not in present:
                    fail('%s at %s compiles generated files in %s, which no DerivedSources.make makes'
                         % (project, STOCK_TAG, directory))
                if tree is None:
                    tree = tempfile.mkdtemp()
                    exported = subprocess.Popen(['git', '-C', REPO, 'archive', STOCK_TAG, 'Source/'], stdout=subprocess.PIPE)
                    if subprocess.call(['tar', '-x', '-C', tree], stdin=exported.stdout) or exported.wait():
                        fail('git archive %s failed' % STOCK_TAG)
                for inputs in derived_inputs(tree, owner, [d for d in derived if os.path.dirname(d) == directory]).values():
                    sources |= inputs
            directories = {os.path.dirname(s) for s in sources}
            searched = set()
            for path in files:
                if path.startswith(project + '/') and path.endswith('.xcconfig'):
                    for value in re.findall(r'^\s*HEADER_SEARCH_PATHS\s*=(.*)$', git('show', '%s:%s' % (STOCK_TAG, path)), re.MULTILINE):
                        searched |= {os.path.normpath(os.path.join(project, t.strip('"'))) for t in value.split()
                                     if not t.strip('"').startswith(('$', '/'))}
            compiled[project] = sorted(sources | {f for f in files if f.endswith('.h') and (
                os.path.dirname(f) in directories or any(f.startswith(d + '/') for d in searched))})
    finally:
        if tree:
            shutil.rmtree(tree)
    return compiled, files, git


def stock_texts(names):
    # The stock i386 slices' texts, and their compiled files' leading comments, by their paths in the
    # release's (STOCK_TAG) Source/ directory: the license files of each directory that holds a
    # compiled file and of its parents, and the files each selected project's property lists name as
    # its OpenSourceLicenseFile.
    compiled, files, git = stock_sources(names)
    leading = {}
    process = subprocess.Popen(['git', '-C', REPO, 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    wanted = sorted({f for paths in compiled.values() for f in paths})
    for path in wanted:
        process.stdin.write(('%s:%s\n' % (STOCK_TAG, path)).encode())
        process.stdin.flush()
        header = process.stdout.readline().split()
        if len(header) != 3:
            fail('git cannot read %s:%s' % (STOCK_TAG, path))
        content = process.stdout.read(int(header[2]))
        process.stdout.read(1)
        leading[path] = compiled_sources.leading_comments(path, content.decode('utf-8', 'replace'))
    process.stdin.close()
    if process.wait():
        fail('git cat-file failed on %s' % STOCK_TAG)
    directories = set()
    for path in wanted:
        directory = os.path.dirname(path)
        while directory not in directories and directory not in ('Source', ''):
            directories.add(directory)
            directory = os.path.dirname(directory)
    named = set()
    for project in compiled:
        for path in files:
            if path.startswith(project + '/') and path.endswith('.plist'):
                data = plistlib.loads(git('show', '%s:%s' % (STOCK_TAG, path)).encode())
                for entry in data if isinstance(data, list) else [data]:
                    if isinstance(entry, dict) and 'OpenSourceLicenseFile' in entry:
                        license = os.path.normpath(os.path.join(os.path.dirname(path), entry['OpenSourceLicenseFile']))
                        if license not in files:
                            fail('%s:%s names %s, which the tag has no file of' % (STOCK_TAG, path, license))
                        named.add(license)
    texts = [(path[len('Source/'):], git('show', '%s:%s' % (STOCK_TAG, path))) for path in files
             if (os.path.dirname(path) in directories and LICENSE_NAME.match(os.path.basename(path))
                 and not NOT_LICENSE_TEXTS.search(os.path.basename(path))) or path in named]
    return texts, {path[len('Source/'):]: text for path, text in leading.items()}


def webkit_texts(labels):
    # The license files of each Source/ directory that holds a compiled file, and of its parents.
    directories = set()
    for path in [os.path.join(SOURCE, l) for l in labels if os.path.isfile(os.path.join(SOURCE, l))]:
        directory = os.path.dirname(path)
        while under(directory, SOURCE) and directory not in directories:
            directories.add(directory)
            directory = os.path.dirname(directory)
    texts = []
    for directory in sorted(directories):
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
            if LICENSE_NAME.match(name) and not NOT_LICENSE_TEXTS.search(name) and os.path.isfile(path):
                texts.append((os.path.relpath(path, SOURCE), read(path)))
    return texts


def subdirectory_texts(tarball, labels):
    # The license files of each directory below the top of a library's tarball that holds a compiled
    # file, and of its parents.
    if not tarball:
        return []
    path, names = tarball
    top = names[0].split('/')[0]
    directories = set()
    for label in labels:
        directory = os.path.dirname(label)
        while directory and directory not in directories:
            directories.add(directory)
            directory = os.path.dirname(directory)
    texts = []
    for name in sorted(names):
        relative = name[len(top) + 1:]
        if os.path.dirname(relative) in directories and LICENSE_NAME.match(os.path.basename(relative)) \
                and not NOT_LICENSE_TEXTS.search(os.path.basename(relative)):
            texts.append((relative, tarball_member(path, name)))
    return texts


def spdx_identifiers(expression):
    return [i for i in re.findall(r'[\w.+-]+', expression) if i.upper() not in SPDX_OPERATORS]


def resolve_pointers(sections):
    # Each file that only names another stands for the file it names: dropped where that file is in
    # its section, else replaced by it.
    used = set()
    for title, texts in sections.items():
        labels = {label for label, _ in texts}
        kept = []
        for label, text in texts:
            if (title, label) not in POINTERS:
                kept.append((label, text))
                continue
            used.add((title, label))
            target = POINTERS[(title, label)]
            if target is None or target in labels:
                continue
            if title != 'WebKit' or not os.path.isfile(os.path.join(SOURCE, target)):
                fail('%s -- %s names %s, which is not in its section' % (title, label, target))
            kept.append((target, read(os.path.join(SOURCE, target))))
            labels.add(target)
        sections[title] = kept
    if set(POINTERS) - used:
        fail('POINTERS names files no section holds: %s'
             % ', '.join('%s -- %s' % p for p in sorted(set(POINTERS) - used)))


# --- Rust -----------------------------------------------------------------------------------------

def rust_license_files(directory):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    return [os.path.join(directory, n) for n in names
            if LICENSE_NAME.match(n) and os.path.isfile(os.path.join(directory, n))]


def rust_units(crate, single):
    # The build units of a crate in the shipped Rust builds; with `single`, failing on a target
    # directory that holds more than one, as Cargo leaves a stale unit behind.
    units = []
    for target in RUST_TARGETS:
        found = [d for d in glob.glob(os.path.join(target, 'x86_64-apple-darwin', 'release', 'build', crate, '*'))
                 if glob.glob(os.path.join(d, 'fingerprint', 'lib-*.json'))]
        if single and len(found) > 1:
            fail('%s holds %d build units of %s; remove the stale ones or the target directory'
                 % (target, len(found), crate))
        units += found
    return units


def rust_features(crate):
    # The features the shipped builds compiled the crate with, from Cargo's fingerprints.
    features, units = set(), rust_units(crate, True)
    if not units:
        fail('no Cargo build unit of %s under %s; run AquaWebKitSupport/deps/build_deps.sh'
             % (crate, ', '.join(RUST_TARGETS)))
    for unit in units:
        for path in glob.glob(os.path.join(unit, 'fingerprint', 'lib-*.json')):
            features.update(json.loads(json.loads(read(path))['features']))
    return sorted(features)


def rust_compiled_sources(crates):
    # The real paths of the sources the shipped builds compiled the crates from, by their dep-info.
    sources = set()
    for crate in crates:
        for unit in rust_units(crate, True):
            for path in glob.glob(os.path.join(unit, 'out', '*.d')):
                first = read(path).split('\n', 1)[0]
                for item in re.split(r'(?<!\\) ', first.split(': ', 1)[1] if ': ' in first else ''):
                    if item.startswith('/'):
                        sources.add(os.path.realpath(item.replace('\\ ', ' ')))
    return sources


def rust_crates(cargo, manifest, roots, cargo_args, fallback, environment, own=(), source_tree=None):
    # The roots and every crate they reach through normal dependencies, short of proc-macro crates,
    # which run in the compiler and link into nothing, and short of the `own` crates, which are this
    # port's. A crate's license files are those in its package directory, else those RUST_LICENSE_FROM
    # names, else those in the nearest enclosing directory up to its workspace root, else, inside the
    # workspace, those in `fallback`. A crate inside `source_tree` carries that tree's release, not a
    # version of its own. Returns the sections and {name of each crate reached: whether it is inside
    # `source_tree`}.
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
    sections, inside = [], {}
    for package in sorted((packages[i] for i in reached if packages[i]['name'] not in own),
                          key=lambda p: (p['name'], p['version'])):
        if 'GPL' in (package.get('license') or ''):
            fail('Rust crate %s %s is under %s' % (package['name'], package['version'], package['license']))
        directory = os.path.realpath(os.path.dirname(package['manifest_path']))
        in_workspace = directory.startswith(workspace_root + os.sep)
        files = rust_license_files(directory)
        if not files and package['name'] in RUST_LICENSE_FROM:
            sources = [p for p in packages.values() if p['name'] == RUST_LICENSE_FROM[package['name']]
                       and p['repository'] == package['repository']]
            if sources:
                files = rust_license_files(os.path.dirname(sources[0]['manifest_path']))
        while not files and directory.startswith(workspace_root + os.sep):
            directory = os.path.dirname(directory)
            files = rust_license_files(directory)
        if not files and in_workspace:
            files = fallback
        if not files:
            fail('no license file for Rust crate %s %s' % (package['name'], package['version']))
        name = package['name']
        inside[name] = bool(source_tree and package['source'] is None
                            and under(os.path.realpath(package['manifest_path']), source_tree))
        if not inside[name]:
            name += ' ' + package['version']
        title = 'Rust crate %s (%s)' % (name, package.get('license') or 'license unstated')
        sections.append((title, [(os.path.basename(f), read(f)) for f in files]))
    return sections, inside


def rust_library_notices(source, compiled):
    # The Rust source tree's REUSE data (license-metadata.json) names the sources under library/,
    # which the standard library builds from, whose notices differ from the tree's own. The notice of
    # each such path a compiled source lies at or under, then the text of each license those notices
    # name beyond the tree's own, from LICENSES/.
    metadata = json.loads(read(os.path.join(source, 'license-metadata.json')))
    top = metadata['files']['children']
    if len(top) != 1 or top[0].get('name') != '.':
        fail('unexpected layout in %s/license-metadata.json' % source)
    root = top[0]['license']
    covered = set(spdx_identifiers(root['spdx']))
    compiled = {os.path.relpath(p, source) for p in compiled if under(p, source)}
    notices, identifiers = [], []

    def join(path, name):
        return '%s/%s' % (path, name) if path else name

    def record(path, license):
        if license == root or not (path == 'library' or path.startswith('library/')):
            return
        if not any(c == path or c.startswith(path + '/') for c in compiled):
            return
        notices.append('%s\n%s\nSPDX-License-Identifier: %s' % (
            path, '\n'.join('Copyright %s' % c for c in license['copyright']), license['spdx']))
        for identifier in spdx_identifiers(license['spdx']):
            if identifier not in covered and identifier not in identifiers:
                identifiers.append(identifier)

    def walk(node, path):
        # A group names no path of its own; its license covers the files and directories it lists.
        if node.get('type') == 'group':
            for name in node.get('files', []) + node.get('directories', []):
                record(join(path, name), node['license'])
            return
        if node.get('name'):
            path = join(path, node['name'])
        if 'license' in node:
            record(path, node['license'])
        for child in node.get('children', []):
            walk(child, path)

    for child in top[0].get('children', []):
        walk(child, '')
    if not notices:
        return []
    texts = [('source files with their own notices', '\n\n'.join(notices))]
    for identifier in identifiers:
        path = os.path.join(source, 'LICENSES', identifier + '.txt')
        if not os.path.isfile(path):
            fail('%s is missing' % path)
        texts.append(('LICENSES/%s.txt' % identifier, read(path)))
    return [('Rust standard library', texts)]


def rust_sections():
    tree = os.path.join(TREES, 'build-gstclosedcaption')
    cargo = os.path.join(TOOLCHAIN, 'rust', 'bin', 'cargo')
    rustc = os.path.join(TOOLCHAIN, 'rust-mavericks', 'bin', 'rustc')
    for path in [tree, PDF_CRATE, cargo, rustc] + RUST_TARGETS:
        if not os.path.exists(path):
            fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
    environment = dict(os.environ, CARGO_HOME=os.path.join(TOOLCHAIN, 'rust', 'cargo-home'), RUSTC=rustc)
    source = os.path.realpath(os.path.join(TOOLCHAIN, 'rust-bootstrap', 'rustc-nightly-src'))
    fallback = rust_license_files(source)
    if not fallback:
        fail('no Rust source license files under %s' % os.path.join(TOOLCHAIN, 'rust-bootstrap'))
    sysroot = subprocess.check_output([rustc, '--print', 'sysroot'], env=environment).decode().strip()
    library = os.path.join(sysroot, 'lib', 'rustlib', 'src', 'rust', 'library')
    if os.path.realpath(library) != os.path.join(source, 'library'):
        fail('%s is not %s' % (library, os.path.join(source, 'library')))
    plugin, _ = rust_crates(cargo, os.path.join(tree, 'video', 'closedcaption', 'Cargo.toml'), [RUST_PLUGIN],
                            ['--no-default-features'], [], environment)
    pdf, _ = rust_crates(cargo, os.path.join(PDF_CRATE, 'Cargo.toml'), [PDF_CRATE_NAME], [], [], environment,
                         own=[PDF_CRATE_NAME])
    # The standard library, as the builds' -Zbuild-std=std,panic_unwind compiled it.
    roots = ['std', 'panic_unwind']
    features = ['%s/%s' % (root, feature) for root in roots for feature in rust_features(root)]
    std, crates = rust_crates(cargo, os.path.join(library, 'Cargo.toml'), roots,
                              ['--features', ','.join(features)] if features else [], fallback, environment,
                              source_tree=source)
    sections = []
    for section in plugin + pdf + std:
        if section[0] not in {title for title, _ in sections}:
            sections.append(section)
    return sections + rust_library_notices(source, rust_compiled_sources(c for c, i in crates.items() if i))


# --- main -----------------------------------------------------------------------------------------

def main():
    output = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BUILD, 'Legal.txt')
    notice = read(os.path.join(SUPPORT, 'NOTICE'))
    staged, cpus = staged_images()
    stock = stock_names(notice)
    compiled = Compiled(staged, cpus)
    compiled.trace(stock)
    libraries, excluded, tops, trees, tarballs, fetched = third_party_sections()
    owners = tarball_paths(tarballs)

    # Every compiled file, by section, with the images it is in.
    by_section, images_of = {}, {}
    for uuid, files in compiled.images.items():
        for key in files:
            images_of.setdefault(key, set()).update(staged[uuid])
    # The staged product's other files, by their origins. A file of a stock framework the NOTICE names
    # adds its notices to the stock code's; a toolchain origin, one of CMake's templates, has none.
    resources = Resources(staged).trace()
    stock_resources = sorted({o for found in resources.values() for o in found if under(o, STOCK)
                              and os.path.relpath(o, STOCK).split(os.sep)[0] in {n + '.framework' for n in stock}})
    for relative, found in resources.items():
        for key in found:
            if under(key, REPO) and not under(key, TOOLCHAIN):
                images_of.setdefault(key, set()).add(relative)
    compiled.object_index()
    placer = Placer(compiled, images_of, tops, trees, owners, tarballs, fetched)
    for key, places in placer.places.items():
        for place in places:
            by_section.setdefault(place[0], {})[key] = place[1]
    # A library's file that its tarball lacks is one its build generated, named by its path in the
    # build's output directory: below the top directory the tarball lacks.
    for name, (_, names) in tarballs.items():
        top = names[0].split('/')[0]
        members = {n[len(top) + 1:] for n in names}
        directories = {m.split('/')[0] for m in members if '/' in m}
        for key, label in by_section.get(name, {}).items():
            if label not in members:
                parts = label.split('/')
                by_section[name][key] = '/'.join(parts[1:] if len(parts) > 1 and parts[0] not in directories
                                                 else parts) + ' (generated)'
    unknown = sorted(set(by_section) - set(libraries) - {'WebKit', AQUA, POLYFILL})
    if unknown:
        fail('compiled files belong to no section: %s' % ', '.join(unknown))

    sections = {AQUA: [('AquaWebKitSupport/LICENSE', read(os.path.join(SUPPORT, 'LICENSE')))],
                POLYFILL: [('LICENSE', read(os.path.join(SHARED, 'LICENSE'))),
                           ('APSL-2.0.txt', read(os.path.join(SHARED, 'APSL-2.0.txt')))],
                'WebKit': webkit_texts(by_section.get('WebKit', {}).values())}
    sections[STOCK_TITLE], stock_leading = stock_texts(stock)
    stock_leading.update((os.path.relpath(path, STOCK), compiled_sources.leading_comments(path))
                         for path in stock_resources)
    for name in [entry[0] for entry in SHIPPED + SHIPPED_FILES]:
        sections[name] = libraries[name] + subdirectory_texts(tarballs.get(name), by_section.get(name, {}).values())
        if not sections[name]:
            fail('%s has no license file in its tarball or in a directory of its compiled files' % name)

    # A REUSE library's LICENSES/ texts are those its compiled files' SPDX identifiers name.
    blocks = {key: comment_blocks(compiled.leading_comments(key)) for key in images_of
              if key.startswith('manifest:') or (under(key, REPO) and not under(key, TOOLCHAIN))}
    for name in REUSE:
        identifiers = set()
        for key in by_section.get(name, {}):
            for expression in re.findall(r'SPDX-License-Identifier:\s*(.*?)\s*(?:\*/|-->)?\s*$',
                                         compiled.leading_comments(key), re.MULTILINE):
                identifiers.update(spdx_identifiers(expression))
        if not identifiers:
            fail('no SPDX identifier in the compiled files of %s' % name)
        labels = {label[len('LICENSES/'):-len('.txt')] for label, _ in sections[name] if label.startswith('LICENSES/')}
        if identifiers - labels:
            fail('%s has no LICENSES/ text for %s' % (name, ', '.join(sorted(identifiers - labels))))
        sections[name] = [(l, t) for l, t in sections[name]
                          if not l.startswith('LICENSES/') or l[len('LICENSES/'):-len('.txt')] in identifiers]
    resolve_pointers(sections)

    # The GNU licenses: a compiled file under the GPL alone must be in images the NOTICE's GPL sentence
    # names; every GNU license a compiled file needs must have its text here; and a library's left-out
    # text must be one no compiled file of the library needs.
    everything = set().union(*[gnu_texts(t) for texts in sections.values() for _, t in texts])
    named = set(re.findall(r'\b(lib[\w-]+)\b', ' '.join(l for l in notice.split('\n')
                                                        if 'General Public License (GPL)' in l)))
    for key, found in blocks.items():
        for block in found:
            requirements, gpl_only = gnu_terms(block, '\n'.join(found))
            for requirement in requirements:
                if not satisfies(everything, requirement):
                    fail('%s needs the %s %s%s, whose text Legal.txt lacks' % (
                        key, requirement[0], requirement[1], ' or later' if requirement[2] else ''))
                for place in placer.places.get(key, []):
                    own = set().union(*[gnu_texts(t) for _, t in sections[place[0]]])
                    for label, text in excluded.get(place[0], {}).items():
                        carried = gnu_texts(text)
                        if (requirement[0] == 'GPL' and any(f == 'GPL' for f, _ in carried)) \
                                or (satisfies(carried, requirement) and not satisfies(own, requirement)):
                            fail('%s needs %s -- %s, which NOT_GOVERNING leaves out' % (key, place[0], label))
            if gpl_only:
                unnamed = sorted(i for i in images_of[key] if os.path.splitext(os.path.basename(i))[0] not in named)
                if unnamed:
                    fail('%s is under the GPL alone and is in %s, which the GPL sentence of '
                         'AquaWebKitSupport/NOTICE does not name' % (key, ', '.join(unnamed)))

    # The stock code's GNU licenses: the GPL sentence names no stock image, and every GNU license a
    # stock file needs must have its text here.
    stock_blocks = {label: comment_blocks(text) for label, text in stock_leading.items()}
    for label, found in stock_blocks.items():
        for block in found:
            requirements, gpl_only = gnu_terms(block, '\n'.join(found))
            if gpl_only:
                fail('%s is under the GPL alone, in stock code the GPL sentence of AquaWebKitSupport/NOTICE '
                     'does not name' % label)
            for requirement in requirements:
                if not satisfies(everything, requirement):
                    fail('%s needs the %s %s, whose text Legal.txt lacks' % (label, requirement[0], requirement[1]))

    # The notices each section's texts do not carry, and the license texts they name.
    _, variables = build_deps_script()
    spdx = {}
    for identifier, _, _, license_label in STANDARD_LICENSES:
        name = 'spdx-%s-%s.txt' % (variables['SPDX_RELEASE'], identifier)
        if os.path.isfile(os.path.join(TARBALLS, name)):
            spdx[identifier] = (license_label, read(os.path.join(TARBALLS, name)))
    upstream = []
    for title, name, license_label in UPSTREAM_TEXTS:
        path = os.path.join(TARBALLS, name.format(**variables))
        if not os.path.isfile(path):
            fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
        upstream.append((title, license_label, read(path)))
    gnu_standard = []
    for identifier, heading in GNU_TEXTS:
        path = os.path.join(TARBALLS, 'spdx-%s-%s.txt' % (variables['SPDX_RELEASE'], identifier))
        if not os.path.isfile(path):
            fail('%s is missing; run AquaWebKitSupport/deps/build_deps.sh' % path)
        gnu_standard.append((heading, read(path)))
    inputs = {}
    for title in sections:
        files = by_section.get(title, {})
        labelled = sorted((files[k], blocks[k]) for k in files)
        if title == STOCK_TITLE:
            labelled = sorted(stock_blocks.items())

        def member(name, label, tarball=tarballs.get(title)):
            # The file of that name in the directory of the file at `label` or the nearest above it.
            if not tarball:
                return None
            top = tarball[1][0].split('/')[0]
            directory = os.path.dirname(label)
            while True:
                path = '/'.join([top] + ([directory] if directory else []) + [name])
                if path in tarball[1]:
                    return path[len(top) + 1:], tarball_member(tarball[0], path)
                if not directory:
                    return None
                directory = os.path.dirname(directory)

        def unnamed(label, title=title, files=files):
            # The images holding the file at `label` that the NOTICE's GPL sentence does not name; the
            # stock code's, which it names none of.
            if title == STOCK_TITLE:
                return [title]
            return sorted(i for k, l in files.items() if l == label for i in images_of[k]
                          if os.path.splitext(os.path.basename(i))[0] not in named)
        inputs[title] = (labelled, member, unnamed)
    write_legal(output, notice, sections, inputs, spdx, upstream, gnu_standard, excluded, rust_sections())


def write_legal(output, notice, sections, inputs, spdx, upstream, gnu_standard, excluded, rust):
    # Legal.txt from the NOTICE and the sections' texts: each section's texts, its UPSTREAM_TEXTS and
    # the notices of its compiled files (`inputs`, {title: (labelled leading comments, member, unnamed)})
    # its texts do not carry, with the texts those notices find; then the GNU_TEXTS the notices find,
    # and the Rust sections. Each of UPSTREAM_TEXTS and GNU_TEXTS must carry or be named by a notice.
    everything = [('%s -- %s' % (title, label), text) for title, texts in sections.items() for label, text in texts]
    everything += [('%s -- %s' % (title, label), text) for title, label, text in upstream]
    unresolved, standard_used, placed = [], set(), {}
    for title in list(sections):
        labelled, member, unnamed = inputs[title]
        own = [(label, text) for t, label, text in upstream if t == title]
        found, missing, used, standard = notice_texts(title, labelled, sections[title] + own, everything, spdx,
                                                      {label for label, _ in own}, member,
                                                      excluded.get(title, {}), gnu_standard, unnamed=unnamed)
        for label, _ in own:
            if label not in used:
                fail('%s -- %s carries no notice and no notice names it; take it out of UPSTREAM_TEXTS'
                     % (title, label))
        placed[title] = [(label, text, None) for label, text in sections[title] + own] + found
        standard_used |= standard
        unresolved += missing
    if unresolved:
        fail('notices name licenses Legal.txt lacks:\n  ' + '\n  '.join(unresolved))
    for heading, _ in gnu_standard:
        if heading not in standard_used:
            fail('%s carries no notice and no notice names it; take it out of GNU_TEXTS' % heading)

    # Groups of notices, in any sections, whose parts state the same terms and find the same texts are
    # one: their copyright notices pool, under each group's heading.
    texts_of = {'%s -- %s' % (title, label): normalize(text) for title, texts in placed.items()
                for label, text, group in texts if not group}
    texts_of.update((heading, normalize(text)) for heading, text in gnu_standard)
    pooled = {}
    for title, texts in placed.items():
        for index, (label, text, group) in enumerate(texts):
            if group:
                key = (group[0], frozenset(texts_of.get(u, u) for u in group[3]))
                if key in pooled:
                    first = pooled[key]
                    for part, notices in enumerate(group[1]):
                        first[0][part] += notices
                    first[2].append((title, index))
                else:
                    pooled[key] = ([list(n) for n in group[1]], group[2], [(title, index)])
    for notices, terms, members in pooled.values():
        text = notice_text(notices, terms)
        for title, index in members:
            placed[title][index] = (placed[title][index][0], text, None)

    ordered = [(title, placed[title]) for title in [AQUA, POLYFILL, 'WebKit', STOCK_TITLE]
               + [entry[0] for entry in SHIPPED + SHIPPED_FILES]]
    ordered += [(heading, [(None, text, None)]) for heading, text in gnu_standard]
    ordered += [(title, [(label, text, None) for label, text in texts]) for title, texts in rust]

    # Each distinct text once, headed by every file that carries it, in order of first appearance.
    # Texts that differ only in whitespace are one text. A text starts at its first line of text and
    # ends at its last.
    groups = {}
    for title, texts in ordered:
        for label, text, _ in texts:
            heading = title if label is None else '%s -- %s' % (title, label)
            if not text.strip():
                fail('%s is empty' % heading)
            if RULE in text:
                fail('%s contains the section rule' % heading)
            groups.setdefault(normalize(text), (text, []))[1].append(heading)
    # What the NOTICE quotes is a heading's title or label.
    parts = {part for _, headings in groups.values() for heading in headings for part in heading.split(' -- ', 1)}
    unknown = sorted({normalize(q) for q in re.findall(r'"([^"]+)"', notice)} - parts)
    if unknown:
        fail('AquaWebKitSupport/NOTICE quotes no heading\'s title or label: %s' % ', '.join('"%s"' % u for u in unknown))
    out = [notice.rstrip('\n')]
    for text, headings in groups.values():
        lines = text.split('\n')
        first = next(n for n, line in enumerate(lines) if line.strip())
        last = max(n for n, line in enumerate(lines) if line.strip())
        out += ['', RULE] + headings + [RULE, ''] + lines[first:last + 1]
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote %s (%d license texts, %d distinct)' % (output, sum(len(t) for _, t in ordered), len(groups)))


if __name__ == '__main__':
    main()
