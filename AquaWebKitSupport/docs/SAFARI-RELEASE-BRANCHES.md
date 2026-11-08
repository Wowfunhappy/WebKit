# Safari release branches

This fork follows the WebKit Apple shipped in a Safari release, taken from the release branches Apple
publishes in [WebKit/WebKit](https://github.com/WebKit/WebKit). Apple does not document how those
branches are organized. This file describes what their history and Apple's shipped builds show.

## Version numbers

`Configurations/Version.xcconfig` holds a five-part version, `MAJOR.MINOR.TINY.MICRO.NANO`, such as
`625.2.8.11.9`. A shipped binary's bundle version puts a prefix for the target OS in front of it.
`SYSTEM_VERSION_PREFIX_macosx_NN` in the same file picks the prefix from the SDK being built against:
22 for macOS 27, 21 for macOS 26, 20 for macOS 15. Safari 27.2 in macOS 27 is `22625.2.8.11.9`.
One source tree therefore builds once for each supported macOS, and the prefix tells those builds apart.

## Branches

- **`safari-7625-branch`**: the branch for the year's Safari (`MAJOR` 625). It is cut from `main` once
  and afterwards only takes cherry-picks.
- **`safari-7625.2.8-branch`**: a release line, named after `7MAJOR.MINOR.TINY`, cut from
  `safari-7625-branch` at its `Versioning.` commit. Each line is cut at a different point and then takes
  cherry-picks of its own, so a newer line is not a descendant of an older one, and merging the next
  line is a real merge.
- **`safari-7625.2.8.SS-branch`**: the line's sub-branches. Their names add the `MICRO` component:

  | `SS` | Builds |
  |---|---|
  | `.11` | The Safari bundled in the current macOS. Branches from the line. |
  | `.18` | The standalone Safari update for the older macOS versions. Branches from `.11`. |
  | `.10`, `.12`, `.13`, `.14` | Apple's other platforms. Each branches from the line. |

  `.18` starts as a copy of a commit on `.11`, renumbered `MICRO = 18`. It then takes the same
  cherry-picks as `.11`, usually a day later, and stops taking them sooner. Its code is the macOS code;
  one `.18` tag is built for every older macOS through the prefix above. The Safari 26.6.1 update for
  Sonoma and Sequoia was `624.5.1.18.3`, and Sequoia's Safari 26.3.1 was `20623.2.7.18.3`. Out-of-band
  releases also use one-off sub-branches, such as `.111` for a Background Security Improvement
  (`21623.2.7.111.2`).

A release branch carries three kinds of commit:

- `Cherry-pick <sha>. rdar://…`: a fix that has already landed on `main`.
- `Versioning.`: a change to `Version.xcconfig` that starts the next submission. Its subject usually
  names the new version (`Versioning. WebKit-7625.2.8.11.9`). When it does not, read the version from
  the file at that commit.
- Build fixes for the branch.

New features do not arrive on a release branch. Preference defaults (`status:` in
`Source/WTF/Scripts/Preferences/*.yaml`) set which features are on, the same on every branch.

**This fork follows `.11`.** `.18` holds the same code with fewer cherry-picks, and GitHub's copy of it is
incomplete.

## Finding the latest stable release

1. **Find the Safari build the current macOS ships.** Apple's
   [Safari Release Notes](https://developer.apple.com/documentation/safari-release-notes) index gives
   each release's first three components (`27.2 (20625.2.8)`). The full build comes from Safari's
   About window on the current macOS, or from the release posts at [eclecticlight.co](https://eclecticlight.co)
   and [mrmacintosh.com](https://mrmacintosh.com), which list the bundled Safari build
   (`Safari 27.2 (22625.2.8.11.9)`). macOS point releases do not all exist: macOS 27 went from 27.0.1
   to 27.2.

2. **Turn the build into a branch and version.** Remove the prefix and put `7` in front:
   `22625.2.8.11.9` is version `625.2.8.11.9` on `safari-7625.2.8.11-branch`.

3. **Find that version's last commit.** A version covers its `Versioning.` commit and the
   cherry-picks after it, up to the next `Versioning.` commit:

   ```
   git fetch https://github.com/WebKit/WebKit \
       safari-7625.2.8.11-branch:refs/remotes/upstream/safari-7625.2.8.11-branch
   git log --oneline upstream/safari-7625.2.8.11-branch -- Configurations/Version.xcconfig
   git show <sha>:Configurations/Version.xcconfig | grep -E '^(MICRO|NANO)_VERSION'
   ```

   The shipped version's last commit is the parent of the next `Versioning.` commit, or the branch tip
   when no later one exists. Safari 27.2's `625.2.8.11.9` ends at the branch tip, `d8d69da3c7`.

   Without a clone, list a line's sub-branches and their commits through the GitHub API:

   ```
   gh api repos/WebKit/WebKit/git/matching-refs/heads/safari-7625.2.8 --jq '.[].ref'
   gh api "repos/WebKit/WebKit/compare/safari-7625.2.8-branch...safari-7625.2.8.11-branch" \
       --jq '.commits[] | "\(.sha[0:10]) \(.commit.message | split("\n")[0])"'
   ```

4. **Merge that commit** as [UPSTREAM-MERGE-NOTES.md](UPSTREAM-MERGE-NOTES.md) describes. A tag from
   the middle of a branch may be a beta seed, and a later tag on the same branch only adds fixes, so
   merge the version that shipped.

GitHub does not have every release branch. Some lines never appear there (no `safari-7623.2.7-*`
branch is published), and some sub-branches stop before the last build Apple shipped from them.
When the shipped build's branch is missing, the newest published line that Apple has shipped is the
one to merge.
