# Syncing from Kero

Terminal is a fork of [Kero](https://github.com/egoist/kero) and still takes
its upstream work. This file is the procedure and the log: how a sync is done,
what reliably gets in the way, and what each past sync brought in.

The fork keeps its own release schedule and its own name, so a sync is a merge
that has to be read, not a fast-forward. Nothing here is automated on purpose —
the conflicts are the interesting part.

## The remote

Upstream is not a default remote of a clone of this repository. Add it once:

```sh
git remote add kero https://github.com/egoist/kero
git fetch kero --no-tags
```

`--no-tags` matters: upstream tags every release, and those versions are not
this fork's versions. The fetch prints a warning about not being able to
access the `Vendor/libghostty-spm` submodule at some commit — that is upstream's
submodule pointer for branches you are not checking out, and it is harmless.

## Doing a sync

Work in a worktree; a sync touches enough files that you want the main checkout
left alone if it goes badly.

1. `git fetch kero --no-tags`, then read `git log --oneline HEAD..kero/main`.
   Skip nothing silently — a commit you decide not to take belongs in the log
   below with the reason.
2. `git merge kero/main`. Git's rename detection carries upstream's `kero/`
   edits onto this fork's `terminal/` files by itself; do not try to help it
   with `--no-renames` or a manual replay.
3. Resolve conflicts (see below), then confirm the merge reintroduced no
   upstream naming:

   ```sh
   git diff --cached HEAD | grep -n '^+.*[Kk]ero'
   ```

   Anything this prints is a string, identifier or path that has to be renamed
   the way [the rename commit](https://github.com/tigercosmos/terminal/commit/067b647)
   renamed it.
4. Build, run the app, and exercise what came in — the same bar as any other
   change ([CONTRIBUTING.md](CONTRIBUTING.md)). An upstream commit that builds
   here has not been shown to work here.
5. Record the sync in the log at the bottom.

## What conflicts, and why

**The rename.** This fork renamed the product, the source directory and ~450
identifiers. Rename detection handles the file moves, but any upstream hunk
that touches a name — a bundle identifier, a user-facing string, a path in the
Xcode project — lands with upstream's spelling and has to be translated by hand.

**The version.** Upstream's `[release] …` commits bump `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` and add a numbered `CHANGELOG.md` heading. This fork
releases on its own schedule, and [RELEASING.md](RELEASING.md) is
maintainer-only, so **revert both bumps out of the merge** and fold the
upstream release's notes into this fork's `## [unrelease]` section instead.

**The changelog.** Both sides edit the top of the file. Upstream's entries
describe upstream's releases; here they are all still unreleased, so they go
into `## [unrelease]` and get folded into an existing bullet when they refine a
feature this fork has not shipped yet — the rule in [CLAUDE.md](CLAUDE.md)
applies to inherited notes too.

**Features this fork added.** Where the fork extended something upstream then
reworked — a new `RightPanel` case, a new `PaneContent` case — the merge shows
both edits and neither is wholly right. Take upstream's rework and re-apply the
fork's addition on top.

**What does not conflict but should be checked.** `terminal/Localizable.xcstrings`
merges cleanly and quietly. Upstream usually ships `ja` and `zh-Hans` with a new
key; if it did not, [LOCALIZATION.md](LOCALIZATION.md) says what is owed.

## Log

### 2026-08-06 — `kero/main` at `ae67b6f`

Merge base `2163068`; 44 upstream commits spanning 0.1.36–0.1.44. **Not a
merge.** `git merge kero/main` was tried first and abandoned: it produced 22
content conflicts, and rename detection had by then failed on the files that
mattered most. `terminal/FileViewerView.swift` has diverged far enough from
upstream's that git paired it with nothing and left the upstream edits in a
stray `kero/FileViewerView.swift`, so a "resolved" merge would have silently
dropped them. The 334 files upstream added under `kero/` also have no rename
source, and landed as location conflicts. Every commit below was re-applied by
hand instead, which is what the fork's divergence now costs.

Taken:

| Commit | What it brought |
| --- | --- |
| `cc3a285` | Sidebar project rows scale from the file tree's designed 11.5pt |
| `0764bbd` | A minimum 100pt window-drag target beside the session tabs |
| `3907094` | The left sidebar's toggle moves into the header while it is hidden |
| `567ab96` | A modern Safari user agent for browser panes |
| `31d09ed`, `0785263` | Terminal notifications play the system sound, re-requesting the sound authorization existing installs never granted |
| `ac4ca58` | OSC 777 notifications in Alacritty panes; the backend advertises ghostty instead of WezTerm |
| `9ea40a6` | Clicking a notification jumps to the session that posted it |
| `0158396` | `assumeMainActor` replaces `MainActor.assumeIsolated` on the Ctrl-Tab switcher's structural-main-thread callbacks |
| `db0da69` | modifyOtherKeys, Ctrl-digit, and application-keypad input in Alacritty |
| `e74f2b0` | OSC 22 pointer shapes; the DEC 2026 tracker becomes a general `StreamScanner` |
| `b83f338` | Terminal links to local files, with Finder reveal and file tab/pane actions |
| `3f0cdd8` | The Git toolbar below the active tab, its branch switcher, and its setting |
| `45fa4d3` | Clean status and untracked line counts in that toolbar |
| `628dee2` | Close Files and Close Diffs in the tab context menu |
| `32af47a` | The Git panel drops Commit when nothing is staged and a sync is waiting |
| `8d4b0f2` | A new session prefers the pinned project directory |
| `90cd6bf` | The selected tab scrolls clear of the strip's overflow fades |
| `e56d624` | Material file icons: 330 vendored SVGs, the generated table, and the generator |
| `93b2b34` | Dragging a tab onto the content grafts its pane tree in as a split |
| `0590f15` | The `.git` walk ascends path strings, so a directory outside any repository no longer spins forever |
| `01566f9` | Git pipe readers match the calling thread's QoS instead of pinning to utility |

Not taken:

- The nine `[release] …` commits (`28004b5`, `be99423`, `72b4cd0`, `0785263`,
  `c315dd9`, `7c21a22`, `3425df1`, `9a5dd13`, `ae67b6f`) — version bumps and
  numbered headings for upstream's releases. Their notes are folded into
  `## [unrelease]`; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are
  untouched, per [RELEASING.md](RELEASING.md). `0785263` also carried a real
  notification change, which was taken.
- `09d2496`, `4fdbc99` — upstream changelog wording only.
- `83a3932` — upstream's `CLAUDE.md` AppKit-first guidance. This fork's
  equivalent lives in [STYLE.md](STYLE.md) and already says it.
- `9e1de54` — `BUILD_JOBS`/`BUILD_NICE` in upstream's release script. Maintainer
  tooling against a release flow this fork does not share.
- `a787cc8`, `09d860c` — upstream's `web/src/routes/changelog.tsx` contributor
  fetch. This fork's site is hand-written and has no such page.

**Deferred — still owed, and the reason.** These are the diff viewer and Git
panel reworks, which land in files this fork has rewritten rather than
extended. They need porting the same way the rest of this sync was, and are
listed here rather than dropped:

- `dd14529`, `17bb787`, `db9a061`, `0a253ba` — editing live worktree changes
  directly in the diff view, with remembered Review/Edit and Unified/Split
  controls, and diff appearance following the system theme. Needs
  PierreDiffsSwift 1.5.0 (the bump was reverted rather than left dangling
  without the feature that uses it). This fork's `DiffViewerView.swift` is 430
  lines against upstream's 580 and loads diffs through `TerminalCore` so they
  work over ssh, so upstream's ~300 added lines do not transplant.
- `1da3345` — keeping visited project diffs mounted. This fork already mounts
  unselected diffs from `ContentView`; upstream's version has to be reconciled
  with that rather than applied.
- `212ea0a`, `17caef1` — the reworked Recent Commits view (a new ~770-line
  file) and its page size of 30.
- `dae03e9` — Git operation progress and error feedback, ~460 lines into a
  `RightSidebarView.swift` that is 2,725 lines here.

### 2026-07-31 — `kero/main` at `2163068`

Merge base `3e2e826`; five upstream commits, all taken.

| Commit | What it brought |
| --- | --- |
| `285fb66` | Reworked the pane layout: splitting divides only the focused pane and leaves neighbors at their size |
| `cda42d5` | Ctrl-Tab switcher ordered by recency, opening on the previous tab |
| `f4829dc` | Upstream's 0.1.35 release — version bump reverted, notes folded into `[unrelease]` |
| `e08729b` | Git status decorations in the Files panel, including dimmed ignored files |
| `2163068` | Ctrl+1–9 switches tabs directly, without Shift |

Three conflicts:

- `CHANGELOG.md` — kept this fork's `[unrelease]` bullets, folded upstream's
  four new user-visible items in beside them, and dropped the `## [0.1.35]`
  heading along with the version bump in `terminal.xcodeproj/project.pbxproj`
  (0.1.35 → back to 0.1.34, build 40 → 39).
- `terminal/Panes.swift` — the doc comment on `PaneContent`. Took upstream's
  "recursive split layout" phrasing, kept this fork's `.compare` leaf in the
  list.
- `terminal/RightSidebarView.swift` — this fork guarded the command-completion
  resync to the Git and Compare panels; upstream removed the guard so the Files
  panel's new decorations refresh too. Took upstream's removal: with Files now
  reading Git status, `.info` was the only panel left to skip, and a finished
  command is exactly when its process list changes.
