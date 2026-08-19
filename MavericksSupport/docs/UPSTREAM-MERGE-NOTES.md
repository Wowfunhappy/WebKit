# Notes for merging from upstream WebKit

When merging from upstream, pay attention to the following.

## `MAVERICKS_BACKPORT` comments

```
git grep -n MAVERICKS_BACKPORT
```

Each marker is a deliberate divergence in `Source/`. A three-way merge will silently drop or mangle these wherever upstream also touched the file. Walk the list; re-apply each by hand, then run `MavericksSupport/scripts/check-backport-markers.sh` against the new base — it reports every divergent hunk that lost its marker, every upstream line that was deleted rather than commented out, and every upstream file the tree no longer has.

## New `USE(GLIB)` blocks that assume GLib *is* the platform

We define `USE(GLIB)` for gstreamer, but mostly use Cocoa APIs. Be mindful of any new or changed `#if USE(GLIB)` blocks which activate on Cocoa and either won't compile or displace a Cocoa subsystem we need.

```
git diff <base>..<merge> -- Source/WTF Source/WebCore/platform | grep -nE 'USE\(GLIB\)'
```

Some instances will be harmless or even correct; others will cause problems. Where appropriate, change to `#if USE(GLIB) && !PLATFORM(COCOA)`