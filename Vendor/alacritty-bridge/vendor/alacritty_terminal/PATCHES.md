# Patches to alacritty_terminal

The source is crates.io `alacritty_terminal` 0.26.0 with the `tests/` tree
left out. Each change is listed here so a version bump can carry it forward.

## `Grid::scroll_up` keeps a scrolled-back viewport still for lower regions

`src/grid/mod.rs`. Upstream bumps `display_offset` on every scroll-up before
checking whether the scroll region starts at the top, yet only a top-anchored
region pushes rows into history. A TUI scrolling a region lower down (Codex
and Claude Code redraw their transcript this way) therefore moved a
scrolled-back viewport one row per redraw and eventually past `history_size`,
where the ring buffer wraps and repeats rows of the live screen. The offset
update now lives inside the `region.start == 0` branch.

## `Term::clear_line` and partial `Term::clear_screen` keep the selection

`src/term/mod.rs`. Upstream drops a selection that intersects a line erased
with EL (`CSI K`) or a region erased with ED above or below the cursor. A TUI
such as Claude Code redraws its frame on every spinner tick by erasing its rows
and writing them again, so a selection anywhere in the frame vanished within a
fraction of a second and ⌘C copied nothing. The selection now stays, as a
range of cells that covers whatever is drawn there next, matching Terminal.app
and Ghostty. A full-screen erase (`ED 2`) and a scrollback erase (`ED 3`) still
clear it as upstream does.

## `Grid::shrink_columns` grows the screen into blank rows below the cursor

`src/grid/resize.rs`. Upstream keeps the bottom of the screen fixed when a
narrowing reflows rows onto more lines, so every added row pushes the top of
the screen into history even when blank rows sit below the cursor. Claude Code
answers a resize by erasing the screen from its top row and painting its frame
again, so each narrowing left a copy of the frame's top in the scrollback, one
per step of a dragged divider. The rows the reflow adds to what was on screen
now take up trailing blank rows below the cursor first, keeping what was on
screen in place, as Terminal.app, iTerm2, Ghostty and kitty do. A screen with
no blank rows left still pushes its top into history. The saved cursor now
follows the row it was saved on through the reflow; upstream left its line
alone, so a DECRC after a narrowing wrote over whatever had moved into it.

## Fixes backported from upstream master

Upstream fixed these after 0.26.0 but has not released them yet. Each change
matches the upstream commit, so drop it from this list when a release that
includes it replaces the vendored copy.

- `src/term/mod.rs`, alacritty/alacritty@542147067. `push_keyboard_mode`
  removed the oldest entry of the title stack, not the keyboard mode stack,
  once the keyboard stack was full. If the title stack was empty, this
  panicked, and the bridge's `panic = "abort"` closed the whole app. Terminal
  leaves `kitty_keyboard` off, so only a build that turns it on can reach this.
- `src/term/cell.rs` and `Cargo.toml`, alacritty/alacritty@ede2ac144. A cell
  keeps at most nine zerowidth characters (`MAX_ZEROWIDTH_CHARS`, stored in an
  `ArrayVec`) and drops the rest. Before this, a program could stack combining
  marks onto one cell until memory ran out. Here `arrayvec/serde` is
  enabled only with the crate's `serde` feature, because the bridge builds
  without serde.
- `src/tty/unix.rs`, alacritty/alacritty@985394dd4. If the PTY cannot be put in
  non-blocking mode, `tty::new` now returns an error. It no longer panics on
  an `assert_eq!`. This copy differs from upstream in one way: the `Pty` is
  built before that call. Upstream returns the error before the `Pty` exists,
  so the spawned shell is never hung up or reaped and the SIGCHLD pipe stays
  registered. Here, dropping the `Pty` cleans up all three. Keep this
  ordering if a later release still has upstream's version.
