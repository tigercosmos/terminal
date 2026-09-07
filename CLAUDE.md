# AGENTS.md

<!-- Kept byte-identical to CLAUDE.md apart from this heading; edit both. -->

Terminal is a native macOS terminal workspace: SwiftUI around terminal surfaces — Alacritty's
emulator core by default, drawn by Terminal's own Metal renderer, with libghostty as an
alternative — plus projects, panes, a file tree, a git panel, an editor, and a diff viewer.
AppKit used over SwiftUI where performance matters.

- [PRODUCT.md](PRODUCT.md) — who Terminal is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- [STYLE.md](STYLE.md) — how the code is written. Canonical when this file only summarizes.
- [RELEASING.md](RELEASING.md) — maintainer-only. Never bump the version in a PR.
- [SYNC.md](SYNC.md) — how upstream Kero work is merged in, and a log of past syncs.

## Verify

A change is verified when the layer covering it has run: `make test-swift` for
logic that needs no window, `make test-rust` for grid content and reflow,
`make e2e` for a feature flow through the running app, and building and looking
for rendering and layout. Build and run either way — a green suite says the
logic holds, not that the feature works. Requires Xcode 27; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- [CHANGELOG.md](CHANGELOG.md) is the product changelog for end users, not a
  development log. Describe only the final user-visible outcome intended to
  ship. Never add or revise release notes for incremental fixes, refactors,
  implementation details, or regressions introduced and resolved while a
  feature is still in progress on an unreleased branch.
- The website in `web/` is hand-written and goes stale on its own. A change to
  a feature, a shortcut, or anything a user can see updates
  `web/src/routes/index.tsx` in the same PR — see "Website" in
  [CONTRIBUTING.md](CONTRIBUTING.md).

## Agent tooling

Shared by Claude Code, Codex, and Cursor; `.codex/` and `.cursor/` symlink
into `.claude/`.

- `.claude/skills/` — `verify-change` (build, run, exercise, test),
  `swift-style-review` (after editing Swift under `terminal/`), `commit-code`,
  `create-pr`, `worktree`, `sync-upstream` (take Kero's new work, see
  [SYNC.md](SYNC.md)).
- `.claude/hooks/check-source.sh` — reports rustfmt findings on an edited
  `.rs` file. Advisory; the bridge has a few pre-existing diffs.
- `.claude/settings.json` — permissions, hooks, status line. Machine-local
  overrides go in the git-ignored `settings.local.json`.
