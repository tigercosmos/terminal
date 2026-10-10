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
