#!/usr/bin/python
# build-localized-strings.py -- build WebCore.framework's LOCALIZED Localizable.strings tables.
#
# Every user-facing WebCore string goes through WEB_UI_STRING, which looks the string up in the
# WebCore bundle keyed by its ENGLISH text (LocalizedStrings.cpp: copyLocalizedString ->
# CFBundleCopyLocalizedString). The open-source build ships exactly one table,
# en.lproj/Localizable.strings, because Apple's localized WebCore tables are not part of the
# open-source tree. On a non-English system that leaves every WebCore-owned context menu item,
# panel and validation message in English, sitting right beside the Safari-owned items in the
# same menu, which Safari.app localizes itself (issue #105: "Open Link in New Window" /
# "Download Linked File" / "Copy Link" / "Inspect Element" in English inside an otherwise
# Spanish menu). Stock 10.9 WebCore shipped 32 localized tables; this rebuilds them from the
# stock backup so the same menu reads in one language again.
#
# Merge, not copy. CFBundleCopyLocalizedString resolves ONE table -- the preferred
# localization's -- and hands back the caller's fallback string for any key that table lacks;
# there is no per-key fallback to the development region. copyLocalizedString passes
# "localized string not found" as that fallback, so a table holding only the 2013 key set would
# render that placeholder for every string added since. Each table therefore carries EVERY key
# the current en.lproj has: the stock translation where one is admissible, the English text
# everywhere else.
#
# A 2013 translation is admissible only under two gates, both enforced here rather than trusted:
#
#   Provenance. Key equality is NOT meaning equality. WEB_UI_STRING_KEY lets the lookup key stay
#   fixed while the displayed English is reworded, so a key that still matches can name text that
#   has changed since 2013 -- adopting the old translation would ship a translation of a string
#   nobody displays any more. Stock's own English.lproj records what each key MEANT in 2013, so a
#   translation is adopted only where that English still matches ours, and every rejection is
#   named on stdout rather than quietly lowering a count.
#
#   Format safety. These strings reach CFStringCreateWithFormatAndArguments (formatLocalizedString).
#   A translation whose conversion specifiers disagree with the English in count or type makes it
#   read varargs that were never passed -- a memory-safety bug in WebContent, not a cosmetic one.
#   Positional reordering (%1$@ / %2$@) is normal localization practice and is compared by
#   position, so it passes; anything else fails the build.
#
# Every shortfall below is a hard failure. The stock backup is already a hard build dependency
# (stage-frameworks.sh exits non-zero without it), and a table set that is silently short
# is issue #105 shipped again with a WARN nobody reads.
#
# Usage: build-localized-strings.py <en-strings> <stock-resources-dir> <out-resources-dir>

import os
import re
import sys

from Foundation import NSDictionary, NSPropertyListBinaryFormat_v1_0, NSPropertyListSerialization

# Our own en.lproj is the authoritative English table, so stock's 2013 English one is not a
# translation target -- CFBundle resolves an English user to en.lproj. It is still READ, as the
# provenance gate's record of what each key meant in 2013.
STOCK_ENGLISH = "English.lproj"
SKIP_LPROJ = frozenset([STOCK_ENGLISH, "en.lproj"])

# The localizations stock 10.9 WebCore shipped. Named in full so a backup that is missing one
# fails by name instead of quietly producing a product that is localized in 31 languages.
EXPECTED_LPROJ = frozenset([
    "Dutch.lproj", "French.lproj", "German.lproj", "Italian.lproj", "Japanese.lproj",
    "Spanish.lproj", "ar.lproj", "ca.lproj", "cs.lproj", "da.lproj", "el.lproj", "fi.lproj",
    "he.lproj", "hr.lproj", "hu.lproj", "id.lproj", "ko.lproj", "ms.lproj", "no.lproj",
    "pl.lproj", "pt.lproj", "pt_PT.lproj", "ro.lproj", "ru.lproj", "sk.lproj", "sv.lproj",
    "th.lproj", "tr.lproj", "uk.lproj", "vi.lproj", "zh_CN.lproj", "zh_TW.lproj",
])

# One printf/CFString conversion: optional %n$ position, flags, width, precision, length, type.
CONVERSION = re.compile(r"%(?:(\d+)\$)?[#0\- +']*[0-9]*(?:\.[0-9]+)?(hh|h|ll|l|q|L|z|t|j)?"
                        r"([@dDiuUxXoOfeEgGcCsSpaAn%])")


def fail(message):
    sys.stderr.write("ERROR: %s\n" % message)
    sys.exit(1)


def read_table(path):
    """Read a .strings table (binary plist or old-style text) as a dict of unicode->unicode."""
    table = NSDictionary.dictionaryWithContentsOfFile_(path)
    if table is None:
        return None
    return dict((unicode(k), unicode(table[k])) for k in table)


def read_table_or_fail(path, what):
    table = read_table(path)
    if table is None:
        fail("could not read the %s at %s" % (what, path))
    if not table:
        fail("the %s at %s is empty" % (what, path))
    return table


def format_signature(text):
    """Map each argument position to its conversion type, so %1$@/%2$@ reordering compares equal."""
    signature = {}
    for index, (position, length, conversion) in enumerate(CONVERSION.findall(text)):
        if conversion == "%":       # a literal "%%" consumes no argument
            continue
        signature[int(position) if position else index + 1] = length + conversion
    return signature


def merge(english, stock, stock_english, language, rejected):
    """English table with every admissible stock translation applied over it."""
    merged = {}
    for key, text in english.items():
        translation = stock.get(key)
        if translation is None:
            merged[key] = text
            continue
        # Provenance: adopt only where the 2013 English this was translated FROM still matches ours.
        if stock_english.get(key) != text:
            rejected.setdefault(key, (stock_english.get(key), text))
            merged[key] = text
            continue
        # Format safety: a specifier disagreement would feed CFStringCreateWithFormatAndArguments
        # arguments that were never passed. Never shipped, never downgraded to a warning.
        if format_signature(text) != format_signature(translation):
            fail("%s translates %r with mismatched format specifiers (%r) -- "
                 "CFStringCreateWithFormatAndArguments would read arguments that were never passed"
                 % (language, key, translation))
        merged[key] = translation
    return merged


def write_table(table, path):
    """Write a .strings table as a binary plist, the format stock 10.9 shipped."""
    data, error = NSPropertyListSerialization.dataWithPropertyList_format_options_error_(
        table, NSPropertyListBinaryFormat_v1_0, 0, None)
    if data is None:
        fail("could not serialize %s: %s" % (path, error))
    if not data.writeToFile_atomically_(path, True):
        fail("could not write %s" % path)


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: %s <en-strings> <stock-resources-dir> <out-resources-dir>\n" % argv[0])
        return 2
    en_path, stock_res, out_res = argv[1:4]

    english = read_table_or_fail(en_path, "English string table")
    if not os.path.isdir(stock_res):
        fail("no stock WebCore resources at %s -- the stock 10.9 backup supplies every WebCore\n"
             "       translation, so WebKit's own UI would ship English-only (issue #105). See\n"
             "       MavericksSupport/scripts/stage-frameworks.sh." % stock_res)
    stock_english = read_table_or_fail(
        os.path.join(stock_res, STOCK_ENGLISH, "Localizable.strings"),
        "stock 2013 English string table (the provenance record every translation is checked against)")

    built = {}
    rejected = {}
    for name in sorted(os.listdir(stock_res)):
        if not name.endswith(".lproj") or name in SKIP_LPROJ:
            continue
        stock = read_table_or_fail(os.path.join(stock_res, name, "Localizable.strings"),
                                   "stock %s string table" % name)
        merged = merge(english, stock, stock_english, name, rejected)
        out_dir = os.path.join(out_res, name)
        if not os.path.isdir(out_dir):
            os.makedirs(out_dir)
        write_table(merged, os.path.join(out_dir, "Localizable.strings"))
        built[name] = sum(1 for key in merged if merged[key] != english[key])

    missing = EXPECTED_LPROJ - set(built)
    if missing:
        fail("the stock backup at %s is missing %d of the %d localizations stock 10.9 WebCore\n"
             "       shipped: %s\n"
             "       Shipping the rest would leave those languages reading English (issue #105)."
             % (stock_res, len(missing), len(EXPECTED_LPROJ), " ".join(sorted(missing))))

    for key, (was, now) in sorted(rejected.items()):
        print("  reworded since 2013, keeping English: %r (2013: %r, now: %r)" % (key, was, now))
    print("  staged %d localized Localizable.strings (%d-%d of %d strings translated per language)"
          % (len(built), min(built.values()), max(built.values()), len(english)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
