# Terminal

A native terminal workspace for macOS.

![preview](web/public/terminal-screenshot.png)

## Features

- Swift + libghostty by default, with an optional Alacritty backend
- Native design
- Split panes
- Git integration
- Group by projects
- File tree

## Beyond Kero

Terminal is a fork of [Kero](https://github.com/egoist/kero). What this fork
adds on top of it:

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

No prebuilt downloads yet — this fork has no release host, Homebrew tap, or
update-signing key of its own. Build it from source:

```sh
git clone --recurse-submodules https://github.com/tigercosmos/terminal.git
```

Then follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3 — see [LICENSE](LICENSE). Terminal is forked from
[Kero](https://github.com/egoist/kero), and the copyright on the inherited work
remains with EGOIST.
