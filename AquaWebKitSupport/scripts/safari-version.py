#!/usr/bin/env python3
"""Print the Safari release a WebKit version shipped in.

Usage: safari-version.py <MAJOR.MINOR.TINY.MICRO.NANO>

Two Apple records pair Safari releases with WebKit builds, each build being the system version prefix
followed by the WebKit version's components:
- the Safari Release Notes index, one entry per release with notes (27.2 (20625.2.8)), and
- the software update catalog's Safari packages, whose distributions name the release (SU_VERS) and
  the WebKit build that satisfies it (20624.5.1.18.3). Their fourth component is the build's
  per-OS branch, so only the first three identify the release.
The release is the non-beta one whose identifying components are the longest prefix of the WebKit
version; among those, the highest. It is printed as Safari's CFBundleShortVersionString spells it, at
least major.minor.
"""

import gzip
import plistlib
import re
import subprocess
import sys

INDEX_URL = "https://developer.apple.com/documentation/safari-release-notes.md"
CATALOG_URL = ("https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-"
               "10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz")
INDEX_ENTRY = re.compile(r"^Released .*—\s+(?:Version\s+)?(\d+(?:\.\d+)*)\s+\((\d+(?:\.\d+)*)\)\s*$")
SAFARI_PACKAGE = re.compile(r"/Safari\d[^/]*\.pkg$")
DISTRIBUTION_RELEASE = re.compile(r'^"SU_VERS" = "(\d+(?:\.\d+)*)";$', re.MULTILINE)
DISTRIBUTION_BUILD = re.compile(r"compareVersions\(\w+, '(\d+(?:\.\d+)*)'\)")


def fetch(url):
    result = subprocess.run(["/usr/bin/curl", "-fsSL", "--max-time", "120", url], capture_output=True)
    if result.returncode:
        sys.exit("safari-version.py: fetching %s failed: %s" % (url, result.stderr.decode(errors="replace").strip()))
    return result.stdout


def index_releases(index_text):
    for line in index_text.splitlines():
        match = INDEX_ENTRY.match(line.strip())
        if match:
            yield match.group(1), match.group(2).split(".")


def catalog_releases(catalog):
    for product in plistlib.loads(catalog)["Products"].values():
        if not any(SAFARI_PACKAGE.search(package.get("URL", "")) for package in product.get("Packages", [])):
            continue
        distribution = fetch(product["Distributions"]["English"]).decode()
        release = DISTRIBUTION_RELEASE.search(distribution)
        if not release:
            continue
        for build in set(DISTRIBUTION_BUILD.findall(distribution)):
            yield release.group(1), build.split(".")[:3]


def release_for(webkit_version, releases):
    webkit = webkit_version.split(".")
    best_length, best = 0, set()
    for release, build in releases:
        if "." not in release:
            release += ".0"
        if not (build[0].endswith(webkit[0]) and len(build[0]) > len(webkit[0])):
            continue
        components = [webkit[0]] + build[1:]
        if len(components) > len(webkit) or webkit[:len(components)] != components:
            continue
        if len(components) > best_length:
            best_length, best = len(components), {release}
        elif len(components) == best_length:
            best.add(release)
    candidates = sorted(best, key=lambda release: [int(part) for part in release.split(".")])
    return (candidates[-1] if candidates else None), candidates


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"\d+(\.\d+){4}", sys.argv[1]):
        sys.exit("usage: safari-version.py <MAJOR.MINOR.TINY.MICRO.NANO>")
    releases = list(index_releases(fetch(INDEX_URL).decode()))
    releases += catalog_releases(gzip.decompress(fetch(CATALOG_URL)))
    release, candidates = release_for(sys.argv[1], releases)
    if release is None:
        sys.exit("safari-version.py: Apple lists no Safari release built from WebKit %s." % sys.argv[1])
    if len(candidates) > 1:
        print("safari-version.py: Safari %s list the same build; WebKit %s is taken as %s."
              % (" and ".join(candidates), sys.argv[1], release), file=sys.stderr)
    print(release)


if __name__ == "__main__":
    main()
