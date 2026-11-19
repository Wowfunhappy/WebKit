#!/usr/bin/env python3
# compiled_sources.py -- what a build tree compiled: each object file, the source and headers it was
# compiled from, and the leading comments of those files, where license notices sit. Shared by
# generate-legal.py and deps/build_deps.sh, which records a tree it deletes:
#
#   python3 compiled_sources.py manifest <tree> <output.json>
#
# A tree's objects come from its ninja deps log where it has a build.ninja, else from the depfiles its
# build wrote beside them: <stem>.d (clang -MD, FFmpeg, ICU, libvpx), .deps/<stem>.Po or .Plo
# (automake), or a .depend at the tree's top (x264). An object with no record, or an empty one, fails.

import hashlib
import json
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NINJA = os.path.join(os.path.dirname(HERE), 'toolchain', 'build', 'ninja', 'bin', 'ninja')
# Lines of an assembly file that are preprocessor directives, not comments.
DIRECTIVE = re.compile(r'#\s*(include|define|undef|if|ifdef|ifndef|elif|else|endif|pragma|error|line)\b')


def fail(message):
    sys.exit('compiled_sources: ' + message)


def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def sha256(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def is_object(path):
    # A Mach-O relocatable object (MH_OBJECT), thin.
    try:
        with open(path, 'rb') as f:
            header = f.read(16)
    except OSError:
        return False
    return len(header) == 16 and struct.unpack('<I', header[:4])[0] in (0xfeedface, 0xfeedfacf) \
        and struct.unpack('<I', header[12:16])[0] == 1


def leading_comments(path, text=None):
    # The comment lines and blank lines a file opens with, up to its first line of code; `text` is
    # the file's content, read from `path` when not given.
    if text is None:
        try:
            text = read(path)
        except OSError:
            fail('cannot read %s' % path)
    # A binary file, one with a NUL byte, has no comments.
    if '\0' in text:
        return ''
    lines = text.split('\n')
    # Assembly comments with ;, as does an assembly include file, whatever its name.
    assembly = path.endswith(('.asm', '.nasm')) or text.lstrip().startswith(';')
    # Assembly, and the scripts and inputs code generators read, comment with #.
    hash_comments = path.endswith(('.s', '.S', '.asm', '.nasm', '.pl', '.pm', '.py', '.rb', '.sh', '.in', '.txt',
                                   '.make', '.gperf')) or '.' not in os.path.basename(path) or text.startswith('#!')
    kept, in_block = [], False
    for line in lines:
        stripped = line.strip()
        if in_block:
            kept.append(line)
            in_block = '*/' not in stripped
            continue
        if not stripped or stripped.startswith('//') \
                or (assembly and stripped.startswith(';')) \
                or (hash_comments and stripped.startswith('#') and not DIRECTIVE.match(stripped)):
            kept.append(line)
            continue
        if stripped.startswith('/*'):
            kept.append(line)
            in_block = '*/' not in stripped[2:]
            continue
        break
    return '\n'.join(kept).strip('\n')


def depfile_rules(path):
    # Make-format dependency rules: target -> prerequisites.
    text = read(path).replace('\\\r\n', ' ').replace('\\\n', ' ')
    rules = {}
    for line in text.split('\n'):
        if line.startswith('#') or ':' not in line:
            continue
        match = re.match(r'^(.*?):(?:\s|$)(.*)$', line)
        if not match:
            continue
        prerequisites = [p.replace('\\ ', ' ') for p in re.split(r'(?<!\\)\s+', match.group(2).strip()) if p]
        for target in re.split(r'(?<!\\)\s+', match.group(1).strip()):
            rules.setdefault(target.replace('\\ ', ' '), []).extend(prerequisites)
    return rules


def ninja(directory, *arguments):
    return subprocess.check_output([NINJA, '-C', directory] + list(arguments)).decode('utf-8', 'replace')


def ninja_targets(directory):
    targets = {}
    for line in ninja(directory, '-t', 'targets', 'all').splitlines():
        target, rule = line.rsplit(': ', 1)
        targets[target] = rule
    return targets


def ninja_query(directory, targets):
    # Each target's explicit and implicit inputs; `ninja -t query` lists order-only ones after "||".
    inputs, current, section = {}, None, None
    targets = list(targets)
    for start in range(0, len(targets), 500):
        for line in ninja(directory, '-t', 'query', *targets[start:start + 500]).splitlines():
            if not line.startswith(' '):
                current = line[:-1]
                inputs[current] = []
            elif not line.startswith('    '):
                section = line.strip().split(':')[0]
            elif section == 'input' and not line.strip().startswith('||'):
                inputs[current].append(line.strip().lstrip('| '))
    return inputs


def ninja_object_sources(directory, objects):
    # The files each object's deps log record names; real paths.
    objects = set(objects)
    sources, found = {}, set()
    process = subprocess.Popen([NINJA, '-C', directory, '-t', 'deps'], stdout=subprocess.PIPE)
    record = None
    for line in process.stdout:
        line = line.decode('utf-8', 'replace').rstrip('\n')
        if line.startswith('    '):
            if record:
                sources[record].append(line.strip())
        elif line:
            target, state = line.split(': #deps ', 1)
            record = target if target in objects else None
            if record:
                if not state.endswith('(VALID)') or state.startswith('0,'):
                    fail('%s in %s has a stale or empty deps record' % (target, directory))
                found.add(target)
                sources[record] = []
    if process.wait():
        fail('ninja -t deps failed in %s' % directory)
    if objects - found:
        fail('%s has no deps record for %s' % (directory, ', '.join(sorted(objects - found)[:5])))
    real = {}
    for files in sources.values():
        for f in files:
            if f not in real:
                real[f] = os.path.realpath(os.path.join(directory, f))
    return {o: sorted({real[f] for f in files}) for o, files in sources.items()}


def ninja_directories(tree):
    found = []
    for directory, subdirectories, files in os.walk(tree):
        if 'build.ninja' in files:
            found.append(directory)
            subdirectories[:] = []
        subdirectories[:] = [d for d in subdirectories if not d.startswith('.')]
    return found


def make_object_sources(tree, path, makefile_directories):
    # An object's prerequisites by the depfile its make build wrote. A depfile names paths relative to
    # the directory the compiler ran in, and ccache's base_dir makes even absolute ones relative. That
    # directory is the one from which every prerequisite exists: first among those from which the
    # depfile's target names the object, then the tree's top and each directory above it.
    relative = os.path.relpath(path, tree)
    logical = os.path.normpath(relative.replace('.libs/', '') if relative.startswith('.libs/')
                               else relative.replace('/.libs/', '/'))
    directory, name = os.path.split(logical)
    stem = os.path.splitext(name)[0]
    candidates = [os.path.join(directory, stem + '.d'), os.path.join(directory, name + '.d'),
                  os.path.splitext(relative)[0] + '.d',
                  os.path.join(directory, '.deps', stem + '.Plo'), os.path.join(directory, '.deps', stem + '.Po'),
                  '.depend']
    ancestors = [directory]
    while ancestors[-1]:
        ancestors.append(os.path.dirname(ancestors[-1]))
    above = [tree]
    while above[-1] != os.path.dirname(above[-1]):
        above.append(os.path.dirname(above[-1]))
    for candidate in candidates:
        depfile = os.path.join(tree, candidate)
        if not os.path.isfile(depfile):
            continue
        for target, prerequisites in depfile_rules(depfile).items():
            # The rule for the object itself: libtool names a PIC object by its .lo.
            if not prerequisites or os.path.basename(target) not in (name, stem + '.lo'):
                continue
            if os.path.isabs(target):
                if os.path.splitext(os.path.normpath(target))[0] not in \
                        (os.path.join(tree, os.path.splitext(logical)[0]), os.path.join(tree, os.path.splitext(relative)[0])):
                    continue
                cwds = above
            else:
                cwds = [os.path.join(tree, c) for c in ancestors + makefile_directories
                        if os.path.splitext(os.path.normpath(os.path.join(c, target)))[0] == os.path.splitext(logical)[0]]
                if not cwds:
                    continue
                cwds += above
            for cwd in cwds:
                paths = [os.path.join(cwd, p) for p in prerequisites]
                if all(os.path.exists(p) for p in paths):
                    return sorted({os.path.realpath(p) for p in paths})
            fail('no directory holds every prerequisite %s names for %s' % (depfile, path))
    fail('no depfile names %s' % path)


def tree_objects(tree):
    # {real path of each object the tree compiled: [real paths of its sources and headers]}.
    tree = os.path.realpath(tree)
    objects = {}
    builds = ninja_directories(tree)
    for build in builds:
        targets = ninja_targets(build)
        names = [t for t in targets if t.endswith(('.o', '.obj')) and targets[t] != 'phony'
                 and os.path.isfile(os.path.join(build, t))]
        for target, sources in ninja_object_sources(build, names).items():
            objects[os.path.realpath(os.path.join(build, target))] = sources
    found, makefile_directories = [], []
    for directory, subdirectories, files in os.walk(tree):
        if any(directory == b or directory.startswith(b + os.sep) for b in builds):
            subdirectories[:] = []
            continue
        if 'Makefile' in files:
            makefile_directories.append(os.path.relpath(directory, tree).replace('.', '', 1)
                                        if directory == tree else os.path.relpath(directory, tree))
        for name in files:
            path = os.path.join(directory, name)
            if not os.path.islink(path) and is_object(path) and os.path.realpath(path) not in objects:
                found.append(path)
    for path in found:
        objects[os.path.realpath(path)] = make_object_sources(tree, path, makefile_directories)
    return objects


def manifest(tree, output):
    # The record of a tree about to be deleted: each object by content hash, with its sources, and the
    # content hash and leading comments of every source, files inside the tree named relative to it.
    tree = os.path.realpath(tree)
    objects = tree_objects(tree)
    if not objects:
        fail('%s compiled nothing' % tree)

    def key(path):
        return 'tree:' + os.path.relpath(path, tree) if path.startswith(tree + os.sep) else path

    files = {}
    record = {'objects': {}, 'files': files}
    for path, sources in sorted(objects.items()):
        record['objects'][sha256(path)] = {'object': os.path.relpath(path, tree),
                                           'sources': [key(s) for s in sources]}
        for source in sources:
            if key(source) not in files:
                files[key(source)] = {'sha256': sha256(source), 'leading': leading_comments(source)}
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output + '.tmp', 'w') as f:
        json.dump(record, f, indent=0, sort_keys=True)
    os.rename(output + '.tmp', output)


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'manifest':
        sys.exit('usage: compiled_sources.py manifest <tree> <output.json>')
    manifest(sys.argv[2], sys.argv[3])
