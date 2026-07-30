---
name: verify-change
description: Verify a Terminal change the way the project requires -- build, launch the app, exercise the behavior itself, and run the suites the diff touches. Use before committing, before opening a PR, or whenever a change needs to be shown to actually work.
---

# Verify a Change (Terminal)

`CLAUDE.md` and `CONTRIBUTING.md` state the rule this skill implements: a
successful build says nothing about whether the change works. Verification
means the behavior was exercised, not that the compiler was satisfied.

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
make test        # everything: Rust bridge tests plus the website type-check
make test-rust   # cargo test for Vendor/alacritty-bridge
make test-web    # web/ type-check
make lint        # cargo clippy on the bridge, warnings denied
make fmt-check   # rustfmt, without writing
```

`make test-rust` and `make lint` are required when the diff touches
`Vendor/alacritty-bridge`; `make test-web` when it touches `web/`. There is no
Swift test suite -- Swift changes are verified in the running app, which is
why step 2 is not optional.

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
