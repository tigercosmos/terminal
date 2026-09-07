---
name: sync-upstream
description: Take new work from Kero (egoist/kero) into this fork -- triage the range down to what belongs here, confirm the shortlist with the user, port it in the fork's own idiom, and record the pass in SYNC.md. Use when asked to "sync upstream", "check upstream", "sync from Kero", "what's new upstream", or "port the latest upstream changes".
---

# Upstream sync (Kero)

`SYNC.md` at the repo root is canonical: the remote, the mechanics, what
conflicts and why, and a log of every past sync with what it took and what it
refused. Read it first — this skill adds the curation around it and does not
restate it.

A sync is curated, not mechanical: the fork has its own name, its own release
schedule, and subsystems it has replaced outright, so an upstream commit is a
proposal rather than a patch. **The triage is the work, and it is gated —
never edit before the user has confirmed the shortlist.** Do the pass in a
worktree (`worktree` skill).

## 1. Enumerate

```sh
.claude/skills/sync-upstream/list-new.sh            # marker read from SYNC.md
.claude/skills/sync-upstream/list-new.sh <marker>   # or pass one explicitly
```

It fetches, lists the range from the last marker, and flags the commits SYNC.md
already names. That flag is the only reliable "already handled" signal: recent
syncs applied commits **by hand rather than merging**, so commits already taken
are still not ancestors and `git log HEAD..kero/main` lists them forever, under
subjects that were reworded on the way in. Range membership is not evidence a
commit is unported.

## 2. Triage — by message, not by diff

```sh
git log --format='%h %s%n%b%n---' <marker>..kero/main
git show --stat <sha>                                 # size and shape only
gh pr view <n> --repo egoist/kero --json title,body   # thin message
```

`--stat` settles most of it: a commit confined to `docs/`, `web/`, or the
release script is out by definition; one touching `kero/` source, the Rust
bridge, or the Xcode project needs reading.

**In scope:** terminal correctness (escape sequences, key encoding, OSC,
selection, reflow), bug fixes, performance, security hardening, and panel and
pane work on surfaces the fork has not replaced.

**Out of scope, but say so and why for each one:**

- `[release] …` commits — version bumps and numbered headings belong to
  `RELEASING.md`. Their notes still fold into `## [unrelease]`, and a release
  commit sometimes carries a real change beside the bump; read it before
  skipping it.
- Upstream's `/docs` site and `web/` rework — this fork's site is hand-written
  and `index.tsx` has diverged badly.
- Upstream's `CLAUDE.md` / `AGENTS.md` guidance — the fork's lives in
  `STYLE.md`.
- Upstream release tooling and CI, and changelog-wording-only commits.

Borderline commits go on the shortlist marked `?`. Nothing is dropped
silently — a commit not taken belongs in the SYNC.md log with its reason, which
is what makes the next sync tractable.

Delegate the reading if the range is large; keep the decision.

## 3. Check with the user — REQUIRED GATE

A compact table: theme, upstream SHA, one-line intent, why it matters *here*,
rough size, and whether it lands as a port or as an idea to re-implement. Then
the skipped list grouped by reason. **Wait** for confirmation.

### Take the idea, not the code

Where upstream develops a subsystem this fork replaced, the commit is neither
skipped nor ported — it is re-decided against what this fork built:

- **The diff viewer.** Upstream improves a WKWebView renderer deleted here with
  `DiffViewerView.swift` and PierreDiffsSwift; diffs are the native Compare
  view (`CompareSides`). Ask what the change is *for*, then decide whether
  Compare should do it.
- **The backend.** Alacritty's core with Terminal's own Metal renderer is the
  default; upstream's `Vendor/libghostty-spm` bumps and renderer fixes reach
  only the alternative backend.
- **Automation.** Upstream's `KERO_AUTOMATION` renames onto
  `TERMINAL_AUTOMATION`, already spent on the DEBUG-only e2e channel. Settle
  the collision with the user before porting any of that work; SYNC.md has the
  standing note.
- **Panels over ssh.** Files, Git and Compare describe the connected host — an
  upstream panel change assuming the local filesystem needs that path thought
  through, not just compiled.

## 4. Port

Merge only when the previous sync was itself a merge; otherwise it replays
everything the last passes applied by hand. Check the newest SYNC.md entry,
then follow "Doing a sync" and "What conflicts, and why" there for the
mechanics — path mapping, the rename translation and its `[Kk]ero` grep, the
version revert, the changelog fold, the quiet `Localizable.xcstrings` merge.
On top of those:

- Read the commit message and its PR before the diff. Upstream subjects carry
  `(#NNN)`.
- Re-implement a large or heavily-refactored diff in this fork's idiom rather
  than line-translating it: match the surrounding file, and keep the fork's
  design language rather than importing a second one into the same sidebar.
- A hunk whose context names something this fork removed on purpose is not
  missing it.
- A synced change a user can see updates `web/src/routes/index.tsx` in the same
  pass (`CONTRIBUTING.md`).
- Commit one concern at a time in this repo's format (`commit-code` skill):
  an imperative subject saying what a user can now do — never
  `merge(upstream): …` — crediting the upstream SHA in the body and saying
  what was adapted and why.

## 5. Verify

`verify-change` skill, same bar as any other change. An upstream commit that
builds here has not been shown to work here. Additionally, for a sync:

- **Baseline first**, on the pre-sync HEAD, so "was that already failing?" has
  an answer rather than a guess.
- Exercise each ported behavior in the app, on both backends when it is
  anywhere near the terminal surface.
- Port the upstream tests that came with the fixes taken — a fix without its
  guard is half-ported — and write the layer's own where this fork's code has
  diverged enough that upstream's would not cover it.

## 6. Record

A new entry at the top of the SYNC.md log, in the shape of the ones there:
the marker, whether it was a merge or applied by hand, a table of what was
taken and what it brought in user-facing terms, every skipped commit with its
reason, and anything deferred with what must be decided first. The helper reads
those SHAs next time.

## Anti-patterns

- Editing before the user approves the shortlist.
- `git merge kero/main` when the last sync was applied by hand.
- Treating "it is in `HEAD..kero/main`" as "it is unported".
- Line-translating a large diff instead of implementing its intent.
- Letting an upstream name, version bump or numbered heading through.
- Dropping a commit without recording why — a silent skip costs the next sync
  the whole triage again.
- Calling a port done because it compiled.
