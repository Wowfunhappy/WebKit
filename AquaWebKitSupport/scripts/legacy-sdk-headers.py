#!/usr/bin/env python3
"""legacy-sdk-headers.py — makes staged developer headers compile against the macOS 10.9 and
10.10 SDKs with the compilers Xcode ships for them, as well as against a modern SDK.

    legacy-sdk-headers.py --prelude <prelude.h> --sdk <modern SDK> [--base <header>]...
                          [-D<macro>=<value>]... <header>...

Each header is rewritten in place, and each base header gets the prelude after its include guard.
In code (not in comments or string literals):
  - each -D macro, one the old SDKs' TargetConditionals.h lacks, takes its value in #if and #elif;
  - type arguments of NSArray, NSDictionary and NSSet become WK_ARRAY(...), WK_DICTIONARY(...),
    WK_SET(...);
  - a nullability attribute of a property becomes a WK_..._PROPERTY prefix of its attribute list,
    and a nullability qualifier of a method type becomes WK_NULLABLE, WK_NONNULL or
    WK_NULL_UNSPECIFIED;
  - a class property gets the class methods it declares as the alternative for compilers without
    class properties;
  - NS_DEPRECATED_MAC, NS_ENUM_DEPRECATED_MAC and NS_CLASS_DEPRECATED_MAC become their WK_ forms,
    which spell the releases they name in dotted form;
  - _Pragma("clang assume_nonnull begin"/"end") becomes WK_ASSUME_NONNULL_BEGIN/END.
Anything of these kinds left in a form an old compiler cannot read is an error: a -D macro outside
#if and #elif, type arguments of any other class the modern SDK's Foundation or AppKit
parameterizes, or of a class that takes pointer type arguments, and a nullability keyword or
__kindof the rewrites do not place.
"""
import argparse
import glob
import os
import re
import sys

GENERIC_MACROS = {"NSArray": "WK_ARRAY", "NSDictionary": "WK_DICTIONARY", "NSSet": "WK_SET"}
PROPERTY_NULLABILITY = {
    "nullable": "WK_NULLABLE_PROPERTY",
    "nonnull": "WK_NONNULL_PROPERTY",
    "null_unspecified": "WK_NULL_UNSPECIFIED_PROPERTY",
    "null_resettable": "WK_NULL_RESETTABLE_PROPERTY",
}
TYPE_NULLABILITY = {"nullable": "WK_NULLABLE", "nonnull": "WK_NONNULL", "null_unspecified": "WK_NULL_UNSPECIFIED"}

MASKABLE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', re.S)
PLACEHOLDER = re.compile(r"\x01(\d+)\x02")


class HeaderError(Exception):
    pass


def mask(text):
    """Comments and literals replaced by placeholders, and the replaced spans."""
    spans = []

    def keep(m):
        spans.append(m.group(0))
        return "\x01%d\x02" % (len(spans) - 1)

    return MASKABLE.sub(keep, text), spans


def unmask(text, spans):
    return PLACEHOLDER.sub(lambda m: spans[int(m.group(1))], text)


def matching_angle(code, start):
    """The index just past the '>' that closes the '<' at start."""
    depth = 0
    for i in range(start, len(code)):
        c = code[i]
        if c == "<":
            depth += 1
        elif c == ">":
            depth -= 1
            if depth == 0:
                return i + 1
        elif c in ";{}":
            break
    raise HeaderError("unbalanced type arguments: %r" % code[start:start + 80])


GENERIC_USE = re.compile(r"\b(%s)\s*<" % "|".join(GENERIC_MACROS))
CLASS_ARGUMENTS = re.compile(r"\b([A-Z]\w*)\s*<")
PARAMETERIZED_DECLARATION = re.compile(
    r"@interface\s+(\w+)\s*<\s*(?:__(?:co|contra)variant\s+)?[A-Z]\w*\s*(?:,\s*(?:__(?:co|contra)variant\s+)?[A-Z]\w*\s*)*>\s*[:(]")


def parameterized_classes(sdk):
    """The classes the SDK's Foundation and AppKit declare with type parameters."""
    classes = set()
    for framework in ("Foundation", "AppKit"):
        for path in glob.glob(os.path.join(sdk, "System/Library/Frameworks/%s.framework/Headers/*.h" % framework)):
            with open(path, errors="replace") as f:
                classes.update(PARAMETERIZED_DECLARATION.findall(f.read()))
    if "NSArray" not in classes:
        raise SystemExit("legacy-sdk-headers.py: no parameterized classes found in %s" % sdk)
    return classes


def check_type_arguments(code, parameterized):
    code = re.sub(r"(?m)^[ \t]*#.*$", "", code)
    for m in CLASS_ARGUMENTS.finditer(code):
        name = m.group(1)
        if name in GENERIC_MACROS:
            continue
        arguments = code[m.end():matching_angle(code, m.end() - 1) - 1]
        if name in parameterized or "*" in arguments:
            raise HeaderError("type arguments of %s: %s<%s>" % (name, name, arguments.strip()))


def rewrite_generics(code):
    out = []
    pos = 0
    for m in GENERIC_USE.finditer(code):
        if m.start() < pos:
            continue
        open_at = m.end() - 1
        close_at = matching_angle(code, open_at)
        arguments = rewrite_generics(code[open_at + 1:close_at - 1]).strip()
        out.append(code[pos:m.start()])
        out.append("%s(%s)" % (GENERIC_MACROS[m.group(1)], arguments))
        pos = close_at
    out.append(code[pos:])
    return "".join(out)


PROPERTY = re.compile(r"@property\s*\(([^)]*)\)")
CLASS_PROPERTY = re.compile(r"^([ \t]*)@property\s*\(([^)]*\bclass\b[^)]*)\)([^;]*);[ \t]*(?:\x01\d+\x02)?[ \t]*$", re.M)
DECLARATOR = re.compile(r"^(.*?[\s*])([A-Za-z_]\w*)((?:\s+[A-Z_][A-Z0-9_]*(?:\([^;]*\))?)*)\s*$", re.S)


def attributes(text):
    return [a.strip() for a in text.split(",") if a.strip()]


def class_methods(m):
    """The original class property, and the class methods it declares for compilers without them."""
    indent, attrs, declaration = m.group(1), attributes(m.group(2)), m.group(3)
    d = DECLARATOR.match(declaration.strip())
    if not d:
        raise HeaderError("cannot read class property: %r" % m.group(0))
    type_, name, decl_attrs = d.group(1).strip(), d.group(2), d.group(3)
    qualifiers = [TYPE_NULLABILITY[a] + " " for a in attrs if a in TYPE_NULLABILITY]
    if "null_resettable" in attrs:
        raise HeaderError("null_resettable class property: %r" % m.group(0))

    def accessor(kind):
        return next((a.split("=", 1)[1].strip() for a in attrs if re.match(r"%s\s*=" % kind, a)), None)

    getter = accessor("getter") or name
    methods = ["%s+ (%s%s)%s%s;" % (indent, "".join(qualifiers), type_, getter, decl_attrs)]
    if "readonly" not in attrs:
        setter = accessor("setter") or "set%s%s:" % (name[0].upper(), name[1:])
        methods.append("%s+ (void)%s(%s%s)%s%s;" % (indent, setter, "".join(qualifiers), type_, name, decl_attrs))
    original = m.group(0).rstrip()
    return "#if __has_feature(objc_class_property)\n%s\n#else\n%s\n#endif" % (original, "\n".join(methods))


def rewrite_property(m):
    attrs = attributes(m.group(1))
    prefix = [PROPERTY_NULLABILITY[a] + " " for a in attrs if a in PROPERTY_NULLABILITY]
    if not prefix:
        return m.group(0)
    rest = [a for a in attrs if a not in PROPERTY_NULLABILITY] or ["readwrite"]
    return "@property (%s%s)" % ("".join(prefix), ", ".join(rest))


TYPE_QUALIFIER = re.compile(r"\(\s*(%s)\b" % "|".join(TYPE_NULLABILITY))
ATTRIBUTE_OPEN = re.compile(r"__attribute__\s*\($")
GNU_NONNULL = re.compile(r"__attribute__\s*\(\s*\(\s*nonnull\b")
LEFT_KEYWORD = re.compile(r"\b(%s)\b" % "|".join(list(PROPERTY_NULLABILITY) + ["__kindof"]))
DEPRECATION = re.compile(r"\bNS_((?:ENUM_|CLASS_)?DEPRECATED_MAC)\b")
ASSUME_NONNULL = re.compile(r"_Pragma\(\x01(\d+)\x02\)")


def resolve_platforms(code, defines):
    """The -D macros' values in #if and #elif, and an error for any use elsewhere."""
    if not defines:
        return code
    names = "|".join(map(re.escape, defines))
    defined = re.compile(r"\bdefined\s*(?:\(\s*(%s)\s*\)|(%s)\b)" % (names, names))
    use = re.compile(r"\b(%s)\b" % names)
    lines = code.split("\n")
    for i, line in enumerate(lines):
        if re.match(r"\s*#\s*(?:if|elif)\b", line):
            line = defined.sub("1", line)
            lines[i] = use.sub(lambda m: defines[m.group(1)], line)
        elif use.search(line):
            raise HeaderError("%s outside #if and #elif: %s" % (use.search(line).group(1), line.strip()))
    return "\n".join(lines)


def type_qualifier(code, m):
    if ATTRIBUTE_OPEN.search(code, max(0, m.start() - 64), m.start()):
        return m.group(0)
    return m.group(0)[:-len(m.group(1))] + TYPE_NULLABILITY[m.group(1)]


def rewrite(text, prelude, is_base, defines, parameterized):
    code, spans = mask(text)
    code = resolve_platforms(code, defines)
    code = CLASS_PROPERTY.sub(class_methods, code)
    check_type_arguments(code, parameterized)
    code = rewrite_generics(code)
    code = PROPERTY.sub(rewrite_property, code)
    code = TYPE_QUALIFIER.sub(lambda m: type_qualifier(code, m), code)
    code = DEPRECATION.sub(r"WK_\1", code)

    def assume_nonnull(m):
        pragma = spans[int(m.group(1))]
        macro = {'"clang assume_nonnull begin"': "WK_ASSUME_NONNULL_BEGIN",
                 '"clang assume_nonnull end"': "WK_ASSUME_NONNULL_END"}.get(pragma)
        return macro or m.group(0)

    code = ASSUME_NONNULL.sub(assume_nonnull, code)

    for line in code.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        left = LEFT_KEYWORD.search(GNU_NONNULL.sub("", line))
        if left:
            raise HeaderError("%s left in: %s" % (left.group(1), unmask(line, spans).strip()))

    if is_base:
        code = insert_prelude(code, prelude)
    return unmask(code, spans)


def insert_prelude(code, prelude):
    """The prelude after the include guard, or before the first directive without one."""
    lines = code.split("\n")
    i = 0
    while i < len(lines) and (not lines[i].strip() or PLACEHOLDER.fullmatch(lines[i].strip())):
        i += 1
    guard = re.match(r"#\s*ifndef\s+(\w+)\s*$", lines[i]) if i < len(lines) else None
    if guard and i + 1 < len(lines) and re.match(r"#\s*define\s+%s\b" % guard.group(1), lines[i + 1]):
        i += 2
    elif i < len(lines) and re.match(r"#\s*pragma\s+once\b", lines[i]):
        i += 1
    return "\n".join(lines[:i] + ["", prelude.rstrip("\n"), ""] + lines[i:])


def main(argv):
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument("--prelude", required=True)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--base", action="append", default=[])
    parser.add_argument("-D", dest="defines", action="append", default=[])
    parser.add_argument("headers", nargs="+")
    args = parser.parse_args(argv[1:])
    defines = dict(d.split("=", 1) for d in args.defines)
    parameterized = parameterized_classes(args.sdk)
    with open(args.prelude) as f:
        prelude = f.read()
    failed = False
    for path in args.headers:
        with open(path) as f:
            text = f.read()
        try:
            result = rewrite(text, prelude, path in args.base, defines, parameterized)
        except HeaderError as e:
            sys.stderr.write("legacy-sdk-headers.py: %s: %s\n" % (path, e))
            failed = True
            continue
        if result != text:
            with open(path, "w") as f:
                f.write(result)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main(sys.argv)
