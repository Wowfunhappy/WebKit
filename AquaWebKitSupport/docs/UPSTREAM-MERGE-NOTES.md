# Notes for merging from upstream WebKit

When merging from upstream, pay attention to the following.

## Use the toolchain's git

`AquaWebKitSupport/toolchain/build/git/bin/git` is git 2.45.4; the host's `/usr/bin/git` is
1.9.5. The merge itself is the reason: 1.9.5 predates the `ort` merge engine and its rename
detection, `git merge-tree`, and wire protocol v2. Put it first on `PATH` for the duration:

```
export PATH="$PWD/AquaWebKitSupport/toolchain/build/git/bin:$PATH"
```

## Merge the commit Apple shipped

Merge the `.11` sub-branch commit of the Safari build the current macOS ships, not a branch tip that
has moved past it. [SAFARI-RELEASE-BRANCHES.md](SAFARI-RELEASE-BRANCHES.md) describes the branches and
how to find that commit.

## `AQUAWEBKIT` comments

```
git grep -n -w AQUAWEBKIT
```

Each marker is a deliberate divergence in `Source/`. A three-way merge will silently drop or mangle these wherever upstream also touched the file. Walk the list; re-apply each by hand, then run `AquaWebKitSupport/scripts/check-backport-markers.sh` against the new base — it reports every divergent hunk that lost its marker, every upstream line that was deleted rather than commented out, and every upstream file the tree no longer has.

## SDK-aligned behavior names

`sdkAlignedBehaviorNames` in `AquaWebKitSupport/polyfill/headers/WebKitAdditions/RuntimeApplicationChecksCocoaAdditions.cpp`
lists every `SDKAlignedBehavior` in enum order, for apps' Info.plist overrides
([SDK-ALIGNED-BEHAVIORS.md](SDK-ALIGNED-BEHAVIORS.md)). A `static_assert` fails the build when upstream adds,
removes or reorders an entry. Update the table to match the enum, and gate any new upstream behavior that
Apple's internal additions hold in the same file.

## The user agent's Safari version

The user agent names the Safari release that shipped the merged WebKit version. The first configure after
a merge changes `Configurations/Version.xcconfig`, so `AquaWebKitSupport/scripts/safari-version.py`
looks the new version up in Apple's [Safari Release Notes](https://developer.apple.com/documentation/safari-release-notes)
index and in the Safari packages of Apple's software update catalog, and rewrites
`AquaWebKitSupport/cmake/SafariVersion.txt`; commit that file with the merge. The catalog keeps only each
OS's newest Safari, and that file keeps a past lookup. Configure fails while neither record lists a
release for the version, so merge a release line once Apple has shipped it. When two releases list the
same build, the script prints both and takes the higher.

## New `USE(GLIB)` blocks that assume GLib *is* the platform

We define `USE(GLIB)` for gstreamer, but mostly use Cocoa APIs. Be mindful of any new or changed `#if USE(GLIB)` blocks which activate on Cocoa and either won't compile or displace a Cocoa subsystem we need.

```
git diff <base>..<merge> -- Source/WTF Source/WebCore/platform | grep -nE 'USE\(GLIB\)'
```

Some instances will be harmless or even correct; others will cause problems. Where appropriate, change to `#if USE(GLIB) && !PLATFORM(COCOA)`