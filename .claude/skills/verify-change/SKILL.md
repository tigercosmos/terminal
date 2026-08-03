---
name: verify-change
description: Verify a Terminal change the way the project requires -- build, launch the app, exercise the behavior itself, and run the suites the diff touches. Use before committing, before opening a PR, or whenever a change needs to be shown to actually work.
---

# Verify a Change (Terminal)

`CLAUDE.md` and `CONTRIBUTING.md` state the rule this skill implements: a
successful build says nothing about whether the change works. Verification
means the behavior was exercised, not that the compiler was satisfied.

Which layer exercises it follows from what changed:

| What changed | How it is verified |
| --- | --- |
| Logic that needs no window | `make test-swift` -- a test in `TerminalCore` |
| Grid content, reflow, selection | `make test-rust` -- a test in the bridge |
| A feature flow through the real app | `make e2e` -- a check in `scripts/e2e.sh` |
| Rendering, layout, chrome, feel | Build, run, and look (steps 1 and 2) |

A behavior one of the first three could cover is expected to arrive with the
test. Reporting "I ran it and it worked" for something a suite could have
pinned down is the gap this table closes.

## 1. Build

```sh
make build      # Debug
```

Xcode 27 is required. If it is not the selected toolchain, pass it for the
whole run and keep passing it to every later command:

```sh
make build DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer
```

Check the toolchain in advance with `xcode-select -p`. A first build in a
fresh checkout or worktree needs `make deps` (submodules plus JS
dependencies); the Rust bridge in `Vendor/alacritty-bridge` is built by an
Xcode build phase, so it needs no separate step.

Treat a new warning in a file you touched as a defect. Pre-existing warnings
elsewhere are noise.

## 2. Run the app and exercise the change

```sh
make run        # builds Debug and launches it
```

Then drive the actual path the change affects and say what you observed. The
Debug product installs as "Terminal Debug.app", so it can run beside an
installed release build.

What "exercise it" means depends on the surface:

- **Terminal surfaces** (Ghostty and Alacritty backends) -- both backends can
  be selected in settings, and a change to shared behavior needs checking on
  the one it touches, at minimum.
- **Panes, projects, the file tree, the git panel, the editor, the diff
  viewer** -- open the real workspace state the change is about, not an empty
  window.
- **Untrusted input** -- terminal output, a repository's own Git
  configuration, and files an agent is writing are all untrusted here. For a
  change on those paths, verify the hostile case fires, and confirm the fix by
  reverting it and watching the behavior come back.
- **Localization** -- new user-facing text must appear in
  `Localizable.xcstrings` after a build. Switch the app language (Settings →
  Appearance → Language, or the scheme's App Language option) when the change
  is user-visible text.

State plainly what you could not exercise. An unverified claim is worse than
an acknowledged gap.

## 3. Run the suites the diff touches

```sh
make test        # everything below except lint and fmt-check
make test-swift  # swift test for the TerminalCore package
make test-rust   # cargo test for Vendor/alacritty-bridge
make test-web    # web/ type-check
make e2e         # drive a running Debug build over the CLI channel
make lint        # cargo clippy on the bridge, warnings denied
make fmt-check   # rustfmt, without writing
```

`make test-swift` is required when the diff touches `TerminalCore/`, and a
change to logic that lives there is expected to come with a test rather than
only a manual pass. `make test-rust` and `make lint` are required when the diff
touches `Vendor/alacritty-bridge`; `make test-web` when it touches `web/`.

`make e2e` is the way to exercise a feature flow without driving the UI by
hand: it launches a Debug build armed with `TERMINAL_AUTOMATION=1` and sends
input, reads the grid back, runs palette commands, and asks for the window's
state, all over the CLI channel. Add a check there when a change adds a flow.
It needs a GUI session, so it is not in `make test`.

Rendering, layout, and feel still have to be looked at -- which is why step 2
is not optional.

`make fmt` fixes what `fmt-check` reports. A few pre-existing rustfmt diffs
live in the bridge, so run it on the files you touched rather than reformatting
the tree in a behavior commit.

## 4. Report

Write down, in the terms a commit or PR body will use:

- what was built and with which toolchain;
- what was exercised in the running app, and what was observed;
- which suites ran and their result;
- what was not verified, and why.

Do not report "verified" for anything that only compiled.
