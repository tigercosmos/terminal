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

### 2026-09-07 — `kero/main` at `50f7302`

Eleven upstream commits after `7268a31`, spanning 0.1.46–0.1.48. **Not a
merge**, for the same reason as the last two entries: those passes applied
their commits by hand, so nothing in this range is an ancestor and
`git merge kero/main` would replay all of it. Each commit below was applied by
hand.

**Read the next sync's commit list against `50f7302`.**

Taken:

| Commit | What it brought |
| --- | --- |
| `06dad48` | The Git panel survives a file removed from the index but left on disk |
| `96cde14` | The Ghostty backend stops leaking two descriptors per screen export |
| `c73544a` | Dictation and other assistive tools can type into a terminal pane |
| `c49fe51` | A block, bar or underline cursor, blinking or steady |

`06dad48` landed verbatim in intent: this fork had the same
`Dictionary(uniqueKeysWithValues:)` trap fed by the same double-reported path,
and the app died on every Git refresh until the file was committed or
restored. `GitStatusModel` lives in the `TerminalCore` package here rather than
the app target, so the guard is covered by a package test upstream did not
write.

`96cde14` is the one that needed deciding rather than porting. The fix is not
in the commit — `ec1ab90` adds only a patch source file, and the working code
ships inside the prebuilt `storage.1.3.6` xcframework that `3a930fd` pins — so
cherry-picking the commit alone would have changed nothing in the built app.
The submodule moves `43f8f45` → `ce74e0a` instead. `43f8f45` was the unmerged
side of libghostty-spm's PR #5 with the same tree as its merge, so this is a
fast-forward, and `9a943a9`'s renderer change rides along because it is
compiled into the same artifact.

**Upstream reverted this bump itself**, in `8cdfe12`, an hour after taking it,
and shipped 0.1.46 with a release note describing a fix its binary does not
contain. Nothing explains the revert, so the leak was measured here rather
than trusted — 200 screen exports over the automation channel on the Ghostty
backend, counting open descriptors before and after:

| libghostty | before → after | leaked |
| --- | --- | --- |
| `storage.1.3.3` (`43f8f45`) | 423 → 823, every one a `DIR` | +2 per export |
| `storage.1.3.6` (`ce74e0a`) | 371 → 371 | none |

This fork leaks harder than upstream does: `TerminalHistory` exports the
screen for the Ctrl-Tab thumbnail and the scrollback when a pane parks, so
ordinary tab switching walks the process to its descriptor limit.

`c49fe51` was re-implemented rather than line-translated. Upstream ships the
controls as a 173-line AppKit file with its own row types; this fork's
Settings is a plain SwiftUI Form, so the setting arrives as a Picker and a
Toggle in the section's existing idiom. The bridge's snapshot cursor mapping
was extracted into `snapshot_cursor_shape` so the integer the Metal renderer
draws from can be asserted — upstream leaves that untested, and this fork
draws the Alacritty cursor itself rather than letting the emulator do it.

Not taken:

- `2371dcf`, `51d0cf7`, `50f7302` — `[release] 0.1.46`, `0.1.47`, `0.1.48`.
  Version bumps and numbered headings, per [RELEASING.md](RELEASING.md). Each
  was read for a real change riding along; none carried one. Their notes are
  folded into `## [unrelease]` for the commits taken above.
- `8cdfe12` — upstream putting the `libghostty-spm` pointer back to `9a943a9`,
  undoing `96cde14`. Not a change to port; it is the reason the bump above was
  measured instead of trusted.
- `d964ad2` — upstream changelog wording only.
- `0f68de9` — reapplying the saved appearance override from
  `applicationWillFinishLaunching`. **This fork does not have the bug.**
  Upstream's premise is that `AppSettings` is first touched from SwiftUI's
  `App.init()` while `NSApp` is still nil, making the initial
  `applyAppearance()` a silent no-op through its `NSApp?` chain. Here nothing
  in `terminalApp.init()` reads `AppSettings` — not
  `TerminalFont.registerBundledFonts`, `TerminalNotificationService.configure`,
  or `PointerRegionTracker.start` — so the first access happens once AppKit is
  up. Confirmed twice: a cold launch with `theme = "light"` against a Dark
  system comes up light (the screen export reports an `ff/ff/ff` background),
  and a temporary probe in `applyAppearance` recorded `NSApp=present` on the
  first call. Porting it would have added a comment asserting something false
  of this fork.
- `fd2fbbd` — "Stop inferring agent progress from terminal text": −354 lines of
  `AgentAutomation.swift` plus `KeroAgentIntegrations`,
  `KeroAutomationCommandLine`, the bundled skill, and six `web/content/docs/`
  pages. This refines the 0.1.45 automation feature the 2026-08-10 sync left
  outstanding over the `TERMINAL_AUTOMATION` collision. Still nothing to port
  until that is settled; the standing note below is unchanged.

**Noticed, not this sync's doing.** `sendText` over the automation channel
does not reach the shell on the libghostty backend — the text never lands,
while the same call works on Alacritty (`make e2e`, 15 checks). It fails
identically on `43f8f45` and `ce74e0a`, so the submodule bump did not cause it.
Left for its own investigation; `scripts/e2e.sh` only ever drives the default
backend, which is why it went unnoticed.

**Still outstanding.** The 0.1.45 pane and agent automation
(`4433b6f`, `692a59e`, `a7f2990`, `38d197f`, `38a5e8d`) and its refinement
`fd2fbbd`. The two questions the 2026-08-10 entry raises — the
`TERMINAL_AUTOMATION` name collision and whether the two automation surfaces
stay separate — are unchanged and still have to be answered before any of it
is ported.

### 2026-08-10 — `kero/main` at `7268a31`

Eight upstream commits after `ae67b6f`, spanning 0.1.45. **Not a merge**, for
the reason the entry below gives: the previous sync's commits are still not
ancestors here, so `git merge kero/main` would replay all 52 of them. The one
commit taken was applied by hand.

**Read the next sync's commit list against `7268a31`.** Same caveat as last
time, one range further along: use both entries to tell what has already been
taken.

Taken:

| Commit | What it brought |
| --- | --- |
| `7fd3616` | An FPS badge in the sidebar header, toggled from the command palette |

The badge counts `CADisplayLink` callbacks, so it reports the cadence the
window actually presents at rather than elapsed time. Upstream shipped its
three catalog keys untranslated; `ja` and `zh-Hans` were written here, and
`%lld fps` is marked `shouldTranslate: false` — a count and a unit symbol, the
way `%lld` beside it already is. `scripts/e2e.sh` gained a check that the
window survives the counter starting and stopping, which is as far as a
channel that reads no pixels can go.

Not taken:

- `ac0bb3d` — `[release] 0.1.45`. Version bump and a numbered heading for
  upstream's release, per [RELEASING.md](RELEASING.md). Its one note describes
  the automation work below, which this fork has not taken, so there was
  nothing to fold into `## [unrelease]`.
- `7268a31` — upstream's `/docs` site: fumadocs, a `home-page.tsx` split out
  of `index.tsx`, and 14 pages written twice, in English and Chinese. This
  fork's site is hand-written on purpose ([CLAUDE.md](CLAUDE.md)) and its
  `index.tsx` has diverged 286 lines of 602, so taking this would overwrite
  the home page and leave 28 files describing upstream's product to rewrite.
  Terminal's own docs are a project of their own, not a sync.

**Outstanding, deliberately.** Upstream's 0.1.45 headline is guarded pane and
agent automation — `4433b6f`, then `692a59e`, `a7f2990`, `38d197f`, `38a5e8d`
refining it. Roughly 5,400 lines: a project-scoped CLI (`+pane`, `+agent`),
agent integrations for OpenCode, Pi and Grok Build, status badges, completion
notifications, and an agent skill shipped in the bundle. It was not taken this
round, and nothing about it is resolved by waiting. Two things a future sync
has to settle first:

- **The env var collides.** Upstream's `KERO_AUTOMATION` renames onto
  `TERMINAL_AUTOMATION`, which this fork already spends on the DEBUG-only e2e
  channel (`TerminalCLIService+Automation.swift`). One of the two needs a
  different name, and the fork's is the one `scripts/e2e.sh` and
  [CONTRIBUTING.md](CONTRIBUTING.md) already document.
- **Two automation surfaces.** The fork's channel is debug-only and drives the
  app for tests; upstream's is a shipped, authenticated, project-scoped feature
  for agents. They are different products that happen to share a word. Decide
  whether they stay separate or one grows into the other before porting either.

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

**Read the next sync's commit list against `ae67b6f`, not against the merge
base.** Nothing here records these 44 commits as ancestors, so
`git log HEAD..kero/main` still lists every one of them and will keep doing so.
Step 1 of the procedure above will look like a much larger sync than it is —
start from the first commit after `ae67b6f`, and use this log to tell what has
already been taken.

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

**Taken as the idea, not the code.** Upstream's diff-viewer work all improves
its WKWebView renderer, which this fork no longer has:

- `dd14529`, `17bb787`, `db9a061`, `0a253ba`, `1da3345` — editing live worktree
  changes in the diff view, remembered Review/Edit and Unified/Split controls,
  diff appearance following the system theme, and keeping visited diffs
  mounted. Upstream was converging its read-only web diff on what this fork's
  Compare view already did natively, and porting it would have left two
  editable diff surfaces on two rendering stacks. Instead the Git panel's
  diffs now open in the Compare renderer against `HEAD` and the index (see
  `CompareSides`), which gets editing, blame, and ssh support for free and
  deletes `DiffViewerView.swift` and the PierreDiffsSwift dependency. The
  always-mounted diff stack and the "a diff is always its own tab" rule went
  with it — both existed only because a WKWebView cannot be unmounted.
  Upstream's unified layout is the one thing lost; side-by-side is now the
  only diff layout.

**Taken last, in the panel's own idiom:**

- `212ea0a`, `17caef1` — the Recent Commits rework. Split into three commits
  here, because upstream's one bundles three separable things: Git command
  timeouts and a refresh watchdog; the richer commit records (first parent,
  refs, per-file rows from `--name-status -z`) with 30-commit paging; and the
  view. Opening a commit's file reuses `CompareSides` rather than adding
  machinery, so it arrives in the same diff view as everything else.
  Upstream's version is a 770-line view with its own commit graph; this is the
  same capability in the section header, row spacing, and type scale the panel
  already uses, rather than a second design language inside one sidebar.
- `dae03e9` — Git operation progress and error feedback, including moving
  branch creation from an inline row to a sheet.

Nothing from this range is now outstanding.

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
