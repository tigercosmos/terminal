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
xcodebuild -project terminal.xcodeproj -scheme terminal -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Prefix that with `DEVELOPER_DIR=...` as above if Xcode 27 is not the selected
toolchain.

## Verifying a change

Build, run the app, and exercise the change itself — a green build is not
evidence that a feature works. Also run the Rust bridge's tests when you touch
`Vendor/alacritty-bridge`:

```sh
cd Vendor/alacritty-bridge && cargo test
```

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
