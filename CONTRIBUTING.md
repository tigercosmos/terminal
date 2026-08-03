# Contributing to Terminal

For anything larger than a fix, open an issue first —
Terminal says no to features that fit some other tool better, and it's kinder to find
that out before the work.

## Setup and build

```bash
git clone --recurse-submodules https://github.com/tigercosmos/terminal.git
```

Already cloned? `git submodule update --init --recursive`. Bun is also needed for
`web/` and `scripts/`.

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. Building for a second architecture needs its target
installed too — `rustup target add x86_64-apple-darwin`.

**Xcode 27 is required.** The project is saved in a format (`objectVersion`
110) that earlier Xcode versions refuse to open, and the app target needs the
macOS 27 SDK. Xcode 27 is currently a beta, so install it alongside a release
Xcode and point builds at it with
`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer` (or
`xcode-select` it).

Open `terminal.xcodeproj` and run the `terminal` scheme, or:

```bash
make build       # or: make run, to build and launch it
```

`make` lists the rest (`test`, `install`, `web`, …). Pass
`DEVELOPER_DIR=...` as above if Xcode 27 is not the selected toolchain:
`make build DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.4.app/Contents/Developer`.

The underlying command, if you'd rather run it directly:

```bash
xcodebuild -project terminal.xcodeproj -scheme terminal -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Verifying a change

A change is verified when the layer that covers it has run, and most changes
have one that is not "launch it and look":

| What changed | How it is verified |
| --- | --- |
| Logic that needs no window | `make test-swift` — a test in `TerminalCore` |
| Grid content, reflow, selection | `make test-rust` — a test in the bridge |
| A feature flow through the real app | `make e2e` — a check in `scripts/e2e.sh` |
| Rendering, layout, chrome, feel | Build, run, and look |

Build and run the app either way — a green suite says the logic holds, not that
the feature works. But a behavior a suite could cover should arrive with the
test rather than with a description of what was clicked.

```sh
make test        # every suite below
make test-swift  # TerminalCore, headless: no Xcode, no signing, seconds
make test-rust   # cargo test for the Alacritty backend's bridge
make test-web    # the website's type-check
make e2e         # launch a Debug build and drive it over the CLI channel
```

`make e2e` needs a GUI session, so it is not part of `make test`. It arms the
build with `TERMINAL_AUTOMATION=1` and drives the running app through the same
channel the `terminal` CLI uses: input goes in through the backend's own
`sendText` and state comes back as text, so neither Screen Recording nor
Accessibility is ever requested — which matters because debug builds are
unsigned and lose a TCC grant on every rebuild.

Logic that needs no window lives in the `TerminalCore` package and is covered
by `make test-swift`. When a change belongs there, a test is the verification —
and it keeps working after the next person changes something nearby, which
driving the app by hand does not.

## Website

The site at [tigercosmos.github.io/terminal](https://tigercosmos.github.io/terminal/)
is built from `web/` and deploys on every push to `main` that touches it. It is
hand-written, not generated, so it goes stale unless a change updates it.

When a change adds, removes, or renames something a user can see, update
`web/src/routes/index.tsx` in the same pull request:

- `FEATURES` — the feature rows, grouped. Work the fork adds on top of Kero
  goes in the `beyond kero` group, and should match the "Beyond Kero" section
  of [README.md](README.md).
- `SHORTCUTS` — every binding, spelled out (`Cmd+Shift+C`, not `⇧⌘C`; the
  comment above the list says why).
- `FAQ` — when the answer to one of them stops being true.

The changelog page needs nothing: it reads [CHANGELOG.md](CHANGELOG.md) at
build time. `bun run typecheck` in `web/`, or `make test-web`, catches the
mechanical mistakes; [web/README.md](web/README.md) covers running and
deploying the site.

## Code style

[STYLE.md](STYLE.md) is the style guide: naming, comments, Swift concurrency
and localization conventions, the Rust bridge's obligations, and the commit
message format. The rule that outranks all of it — read the code nearby and
follow it.

## Pull requests

Say what a user can now do that they could not before, or what stopped going
wrong — not which files moved. State how you verified it, and call out anything
you could not verify. Never bump the version; see [RELEASING.md](RELEASING.md).

## Localization

Terminal’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.
