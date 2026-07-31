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
