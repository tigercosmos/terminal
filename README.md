# Terminal

A native macOS terminal workspace built for supervising coding agents: the shell
stays primary, and the project's files, Git state, and a full diff and compare
view are one pane away.

Terminal is a fork of [Kero](https://kero.sh/). It builds from source only —
there is no `brew install`, tap, or prebuilt download for this fork.

**[tigercosmos.github.io/terminal](https://tigercosmos.github.io/terminal/)** —
the full feature list, every keyboard shortcut, and the changelog.

![preview](web/public/terminal-screenshot.png)

## Features

- **Terminal first** — libghostty by default, with an optional Alacritty
  backend, split panes, tabs, and a command palette.
- **The project alongside it** — a file tree, an editor with syntax
  highlighting and find, and a diff viewer, in panes beside the shell instead
  of in a second app.
- **Git in the sidebar** — working-tree status, per-file diffs, and per-line
  blame, without dropping to a Git GUI.
- **The session, at a glance** — the focused shell's working directory, the
  processes it is running, and the ports they are listening on.
- **Grouped by project** — shells, panes, and tabs stay with the repository
  they belong to, and come back with it.
- **Native and localized** — macOS appearance and keyboard conventions, in
  English, Simplified Chinese, and Japanese.

## Beyond Kero

What this fork adds on top of [Kero](https://github.com/egoist/kero):

- **Compare against any branch or commit** — ⇧⌘C opens a Compare panel: pick a
  target by searching branches and recent commits, or type any revision Git
  understands, and every file that differs is listed. Opening one gives the
  target on the left, read-only, and your live file on the right, still
  editable and saveable. Each line shows who last changed it, and any file can
  be reverted to the target.
- **Faster files** — switching back to an already-open file is instant and
  keeps its undo history, instead of rebuilding and reparsing the editor. Large
  files no longer stall while scrolled away from the top: the gutter numbers
  what is on screen rather than walking the whole document on every scroll tick.
- **Hardened against untrusted input** — opening a folder no longer lets that
  repository's own Git configuration run commands on your machine. Terminal
  links that would leave your browser and launch an application ask first,
  showing where the link really leads. Editing a symlinked file writes through
  the link, saving a file that changed on disk offers to overwrite or reload
  rather than silently discarding the other change, the CLI bridge signs its
  requests, and saved terminal history is readable only by your user account.
- **Build from source without ceremony** — a Makefile covers the common tasks
  (`make build`, `run`, `test`, `install`), and installs are unsigned by
  default so the app launches without a Developer ID.
- **Written-down conventions** — [STYLE.md](STYLE.md) for how the code is
  written, and `.claude/` skills and hooks shared by Claude Code, Codex, and
  Cursor.

## Install

No `brew install` and no prebuilt downloads for now — this fork has no release
host, Homebrew tap, or update-signing key of its own. Build it from source:

```sh
git clone --recurse-submodules https://github.com/tigercosmos/terminal.git
cd terminal
make run
```

Building needs **Xcode 27** — the project uses the macOS 27 SDK and a file
format earlier versions refuse to open — plus a Rust toolchain for the
Alacritty backend's bridge. The built app itself runs on macOS 15.6 or later.
`make install` puts a Release build in `/Applications`, and `make` on its own
lists the rest. [CONTRIBUTING.md](CONTRIBUTING.md) covers the details,
including how to point builds at a beta Xcode.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3 — see [LICENSE](LICENSE). Terminal is forked from
[Kero](https://kero.sh/), and the copyright on the inherited work remains with
EGOIST.
