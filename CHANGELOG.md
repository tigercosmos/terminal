# Changelog

All notable changes to terminal. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

Write release notes for the final product users receive, not the development
history. When a feature is still unreleased, fold its fixes and refinements into
the original feature bullet instead of adding separate entries for them.

## [unrelease]

- Choose the terminal cursor in Settings → Terminal: block, bar, or underline,
  blinking or steady. It reaches terminals that are already open, and steps
  aside for programs that ask for a cursor of their own
- Dictation and other assistive tools can enter text in a terminal pane. Panes
  are text areas to VoiceOver now, and only the focused, visible one accepts
  what is typed into it
- Fixed a crash on every Git refresh once a file had been removed from the
  index but left on disk, as `git rm --cached` leaves it
- Fixed new panes failing to start a shell after a long session on the Ghostty
  backend. Every tab switch exported the screen, and each export leaked two
  file descriptors, so a day's work could exhaust the process's table
- Fixed **cd Here** in the Files panel doing nothing on the Ghostty backend:
  the command was typed at the prompt but never ran until you pressed Return
  yourself
- **Never read protected folders** in Settings → Privacy keeps Terminal's own
  file, Git, and search panels out of Desktop, Documents, Downloads, your
  media folders, iCloud Drive, and mounted volumes, so macOS stops asking for
  access on their behalf when a terminal cd's into one. Those folders show as
  locked in the file panel until you turn it back off. Commands you run in a
  terminal are unaffected — macOS asks about those itself

## [0.7.0]

- The command palette can put a frames-per-second badge in the sidebar
  header, for seeing how fast a window is really redrawing. It counts the
  frames the display presented rather than the time that passed, and stops
  counting while Terminal is in the background so a window you switched away
  from does not read as slow
- Panes no longer freeze on the last frame before a TUI stops to ask you
  something — Claude Code's selection menus being the everyday case. The
  Alacritty backend misread multibyte characters such as ❯ as control codes,
  lost track of the frame the program was drawing atomically, and kept
  holding presentation until the next keystroke produced output

## [0.6.0]

- Recent Commits in the Git panel opens: each commit shows the files it
  touched, and clicking one shows that file as it changed in that commit.
  Branch and tag names appear beside the commits they point at, and history
  loads 30 at a time instead of stopping at eight
- Git operations now show their progress on the control you used — the branch
  menu, Commit, Sync — instead of a banner at the top of the panel, and only
  failures interrupt you. Creating a branch asks in a dialog rather than a row
  that pushed the file list down
- The Git panel can no longer be left spinning by a repository that never
  answers — a disconnected volume, or a credential helper waiting on a prompt.
  It gives up and offers a retry instead
- Clicking a changed file in the Git panel now opens it in the same
  side-by-side view Compare uses. An unstaged change sits beside your live
  file, so you can read it and fix it in the same place and press ⌘S — and it
  follows a terminal over ssh the way the panels do. A staged change shows
  what you staged against the last commit, without folding in edits you have
  made since. Diffs are ordinary panes now: split them, or drag one into a
  split. The separate diff layout is gone, so diffs no longer offer a unified
  view
- A toolbar under the active tab shows the repository the terminal is working
  in: its branch, and the lines added and deleted so far — or a green Clean
  when there is nothing pending. The branch opens a searchable switcher that
  floats the current branch to the top and marks the remote's default; the
  counts open the Git panel, and include untracked files the way `git diff`
  does not. Right-click the toolbar to hide it, or choose in Settings →
  Appearance → Toolbar whether it appears in every project, only in Git
  repositories, or never. It follows a terminal onto a host it has `ssh`'d
  into, like the panels do, and it starts out hidden
- File names carry their own icons — 300 of them, from the Material Icon
  Theme — in the file tree, the Git panel, tab labels, pane headers, the pane
  switcher, and ⌘P results
- Drag a tab down onto the current tab's content to turn it into a split pane.
  A tab that is already split keeps its panes and their proportions
- Command-click a file path in a terminal to reveal it in Finder, or
  Command-right-click a path or URL to open it as a file or browser tab or
  pane. Paths are resolved against the terminal's own directory, and the
  `file:12:5` suffixes compilers print are understood
- Terminal notifications play the system sound, and clicking one brings
  Terminal forward and jumps to the session that posted it. Notifications from
  Grok and other OSC 777 programs now arrive in Alacritty panes too
- Alacritty panes take modified keys the way Ghostty panes do: Shift-Return
  inserts a newline in Claude Code instead of submitting, Ctrl with the number
  row sends the right control codes, and the numeric keypad works in
  application mode. Programs can also set the mouse pointer's shape, and
  mouse-reporting apps show the arrow
- Close Files and Close Diffs in the tab context menu clear those panes
  everywhere without touching terminals
- With the left sidebar hidden, its toggle stays reachable in the header, and
  a strip beside the tabs is always free to drag the window by
- Selecting a tab now scrolls it clear of the strip's fade instead of leaving
  it half-covered
- Fix a rare crash while using the Ctrl-Tab switcher
- Fix browser panes reporting an outdated browser to sites such as Bilibili
- Fix the app hanging when a terminal sat in a directory outside any
  repository
- A new terminal opens in the project's pinned directory when it has one,
  rather than following the current session

## [0.5.0]

- Holding a key down in a terminal repeats it. Hold j or k to run through
  `git log`, a file in `less`, or anything else that scrolls a line at a time,
  instead of tapping the key
- Git and Compare follow a terminal onto the host it has connected to, the way
  the Files panel already did: `ssh` somewhere and they describe that machine's
  repository — its branch, tracking, history, changed files, and every diff and
  comparison, opened over the same connection. ⌘P searches that machine's files
  too. They are read-only there, so committing, staging, discarding, and
  reverting stay with the checkout on your Mac. All three panels follow the
  directory you `cd` to on that host with nothing to install or configure
  there, including on hosts that were previously stuck at your home directory
  because their shell reports nothing to terminals it doesn't recognize. Where
  the directory genuinely can't be established — a shell inside `screen` or
  `tmux` — the panel says so instead of claiming there is no repository

## [0.4.0]

- Cmd+Plus, Cmd+Minus, and Cmd+0 now resize whatever you last clicked into: the
  sidebars and panels when you are working there, the terminal text when you
  are in a pane, a web page in a browser pane. The interface and terminal sizes
  are remembered separately, and the interface now goes up to 24 pt

## [0.3.0]

- Scrolling the scrollback with a trackpad follows your fingers by the pixel
  instead of jumping a whole row at a time, and comes to rest wherever you let
  go. Scrolling inside a full-screen program is unchanged — those still read
  whole rows
- Terminal panes now use the Alacritty emulator core by default, drawn by
  Terminal's own renderer. That is what makes the scrolling above possible, and
  it uses less memory. If you prefer Ghostty's, Settings → Terminal → Backend
  switches back and remembers the choice. Sessions you have already opened keep
  their scrollback; the backend applies to panes opened after the switch

## [0.2.0]

- Terminal is now a download: every release attaches a `.dmg` you can drag to
  Applications instead of building from source. It is unsigned, so macOS
  quarantines it until you run
  `xattr -dr com.apple.quarantine /Applications/Terminal.app` once
- The Files panel follows a terminal onto the host it has connected to: `ssh`
  somewhere and the file tree shows that machine's files, browsable and
  openable read-only over the same connection you are already using. Git and
  Compare still describe your Mac, which is where the checkout is
- Compare your working tree against any branch or commit and keep editing: the
  target sits read-only beside your live file, a Compare panel lists every file
  that differs, each line shows who last changed it, and any file can be
  reverted to the target
- Opening files is much faster: switching back to an open file is now instant
  (keeping its undo history), and large files no longer stall while scrolled
  away from the top
- Add per-pane live titles and split controls in split layouts, where splitting
  divides only the focused pane and leaves its neighbors at the size you gave
  them
- The Files panel now shows repository status with colored filenames and
  badges, including dimmed Git-ignored files
- Zoom the terminal text with Cmd+Plus (or Cmd+=) and Cmd+Minus, or Cmd+0 for
  the default size, without opening Settings — in a browser pane the same keys
  zoom the page
- Switch directly to tabs with Ctrl+1–9, without also holding Shift
- The Ctrl-Tab switcher now lists tabs in the order you last used them and opens
  already pointing at the previous tab, so a quick Ctrl-Tab flips between the
  two tabs you're working in
- Opening a folder no longer lets that repository's own Git configuration run
  commands on your machine
- Terminal links that would leave your browser and launch an application now ask
  first, showing where the link really leads
- Editing a symlinked file writes through the link instead of replacing it
- Saving a file that changed on disk since you opened it now offers to overwrite
  or reload instead of silently discarding the other change
- Saved terminal history is now readable only by your user account

## [0.1.34]

- Show terminal titles verbatim while keeping sidebar project rows stable as titles update or hover controls appear
- Follow the terminal's foreground job into another checkout: when an agent
  switches to its own git worktree, Files, Git and Info re-root to it
- Settings font preview now reflects “Thicken font strokes”
- Prevent terminal tabs from crashing after switching sessions or resizing during a partial redraw
- Files created in a terminal now use your system's default permissions instead of being made private to your user

## [0.1.33]

- Fix: never set `LANG` env for the terminal session

## [0.1.32]

- Add native English, Simplified Chinese, and Japanese localization throughout the app, with a language picker in Settings
- Search and open files from the project directory in the command palette
- Open native browser tabs and split panes from the command palette or terminal/editor context menus, with a combined address/search field, navigation controls, page sharing, and restored URLs

## [0.1.31]

- File previews now refresh after files are changed outside Terminal
- Option-key characters from macOS input sources such as Polish Pro now work in terminals; users who prefer terminal Meta bindings can opt in under Settings → Terminal

## [0.1.30]

- Fix Chinese IME under Alacritty backend
- Reduce hidden Ghostty tab renderer memory

## [0.1.29]

- Add `terminal` command: run `terminal` in any Terminal terminal to create a project in the current directory, optionally with an argv to run directly (`terminal vim ~/foo.js`); `terminal +themes` browses themes with a live app-wide preview and saves the selection on Return
- The Git panel now refreshes after commands and when Terminal regains focus instead of polling continuously in the background

## [0.1.28]

- Tweak some UI colors

## [0.1.27]

- Choose which terminal emulator drives new panes in Settings → Terminal → Backend. Ghostty remains the default, with a new Alacritty backend
- Configure the left and right sidebar font size in Settings

## [0.1.26]

- Opening the Ctrl-Tab switcher no longer highlights whichever tab happens to be under the stationary pointer
- The Processes list no longer shows `<defunct>` entries: those are exited children waiting to be reaped, not something you can see output from or kill
- Opening a large diff no longer freezes the window: diffs render only the rows on screen and highlight them off the main thread
- The font setting now applies to the diff viewer too, so diffs match the terminal and the editor
- Sessions you never open no longer cost any GPU memory. Reopening a window used to draw every restored session straight away, holding a full-size buffer for each whether you looked at it or not; now a pane claims one only when you first view it, and claims one buffer less than before. A pane you have already viewed keeps its buffer until you close it — switching away stops it drawing, but does not hand the memory back.

## [0.1.25]

- Add a tab switcher (ctrl-tab) to switch between tabs
- Add audio input support for CLIs that might need it

## [0.1.24]

- set TERM_PROGRAM to ghostty to get image rendering support

## [0.1.23]

- Fix pasting clipboard images into image-aware TUIs such as Grok, and paste Finder-copied files as shell-safe absolute paths (#20)

## [0.1.22]

- Add “Open in Terminal” to Finder’s folder context menu, opening each selected folder as a project with its terminal started there
- Full-screen programs with their own background color (vim, htop, TUIs) now fill the terminal pane: the padding around the grid takes on the adjacent content's background instead of always showing the theme background, leaving only a hairline frame at the pane edges
- Fix non-ASCII rendering in git diff view
- Allow to rename session tabs

## [0.1.21]

- Anchor the file tree and Git panel to the project directory — the closest git repository containing the terminal's directory — so they no longer re-root every time you `cd` inside a repo; outside a repository they keep following the terminal as before
- Add "Set Project Directory…" to the project's context menu to pin a fixed directory for these panels ("Use Automatic Directory" reverts); the pin is remembered across relaunches
- Info panel: the Directory section is now split into Current Directory (the shell's live cwd, shown when it differs) and Project Directory, marked "(AUTO)" while derived automatically, with a "?" popover explaining both modes
- Remember sidebar layout across relaunches: each window restores whether the left and right sidebars were open and which right panel (Files/Git/Info) was selected

## [0.1.20]

- Security: stop terminal programs from silently reading your clipboard — an OSC 52 escape sequence (for example from a remote SSH host) could previously read the macOS clipboard without any prompt; terminal now asks for confirmation first, matching the Ghostty app default (#8)
- Warn before pasting text that looks like it could execute commands, matching Ghostty's paste protection
- Add color themes: Settings → Colors picks a theme per appearance — terminal's Default Light/Dark plus all 485 bundled Ghostty themes — recoloring the terminal, window chrome, sidebars, and editor live. The built-in Defaults keep the GitHub palette and translucent sidebar; every other theme colors the sidebar too
- Fix fuzzy-looking terminal text: font thickening was unintentionally always on, making glyphs heavier and softer than stock Ghostty
- Add a "Thicken font strokes" toggle in Settings → Font for those who prefer the heavier rendering

## [0.1.19]

- Fix a releasing signing issue

## [0.1.18]

- Fix max height of settings window

## [0.1.17]

- Add pane zoom: ⇧⌘↩ toggles the focused pane filling the tab, with a header button indicating the state and exiting zoom
- Add shortcuts to cycle pane focus (⌘[ / ⌘]), resize panes (⌃⌘ arrows) and equalize panes (⌃⌘=)

## [0.1.16]

- Tweaks shortcut description for toggling right sidebar

## [0.1.15]

- Fix potential memory leak

## [0.1.14]

- Add theme setting to force light or dark theme

## [0.1.13]

- Make editor full height
- Tweaks sidebar

## [0.1.12]

- Fix TSX highlight

## [0.1.10]

- fix git panel

## [0.1.9]

- Fix CPU usage spike due to libghostty intergration bug

## [0.1.8]

- Use libghostty

## [0.1.7]

- Remove GPU rendering temporarily

## [0.1.6]

- Fix window maximizing
- Shortcut for left sidebar: cmd-b

## [0.1.5]

- Double-click the title bar to zoom the window (honors the system "double-click a window's title bar to" setting)
- fix gpu rendering

## [0.1.4]

- Add "Session Contents Restored" divider to restored terminals
- set TERM_PROGRAM to Terminal
- fix embedded language highlighting in markdown

## [0.1]

### Added
- Initial release.
