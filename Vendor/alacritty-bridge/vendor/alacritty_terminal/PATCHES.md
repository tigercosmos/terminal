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
