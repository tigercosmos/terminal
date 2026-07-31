# Coding Style Guide

A style guide exists so that code written by different people, at different
times, reads as one codebase. Consistency costs a little when writing and pays
back every time someone reads, reviews, or debugs — and reading happens far
more often than writing.

Terminal is Swift and SwiftUI over libghostty and an Alacritty backend, with a
Rust bridge in `Vendor/alacritty-bridge`, TypeScript in `web/` and `scripts/`,
and a hand-maintained C header at the FFI boundary. The rules of thumb:

1. **Read the code nearby and follow it.** Start with the function and type
   you are editing, then the file, then the directory. This guide loses to the
   surrounding file whenever the two disagree — matching what is there beats
   matching this document.
2. **Keep the checks clean.** `make lint` (clippy, warnings denied) and
   `make fmt-check` (rustfmt) cover the Rust bridge; `make test` runs the
   bridge's tests and the website type-check. Swift has no formatter or linter
   configured, which is exactly why the written conventions below matter.
3. **A green build is not verification.** Build, run the app, and exercise the
   change — see [CONTRIBUTING.md](CONTRIBUTING.md).

`Vendor/` is third-party. Patch it only when necessary, and then follow its
upstream style rather than this guide.

## Line economy and breathing room

Two forces balance here, and they do not conflict. Line economy keeps a single
thought on as few lines as it honestly needs. Breathing room separates
distinct thoughts with a blank line so a reader can see the structure. Economy
fights spreading one idea across many lines; breathing room fights packing
many ideas into one unbroken block. Both serve the same goal: code a human can
scan.

### Keep one thought compact

- Prefer compact forms over spread-out forms when both are equally clear.
- Do not pad a short block: a three-line function body needs no internal blank
  lines.
- Never sacrifice readability for a lower line count, and never put two
  executable statements on one line separated by `;` — debuggers and stack
  traces need line granularity. A single-expression body on one line, such as
  `var id: String { rawValue }`, is one statement and stays the preferred
  accessor form.

### Let the code breathe

A long body packed edge to edge is hard to read even when every line is
necessary. Keep consecutive statements of the same construct together, then
put one blank line at the seam between groups so each reads as a unit. Let the
blank line mark the seam; do not reach for a narrating comment to do it (see
"Comments").

Where a blank line earns its place:

- Between type, function, and property definitions (required).
- Between the logical sections of a longer body, one blank line per seam.
- Before a concluding `return` or a multi-line expression that wants setting
  off from the work above it.
- Around a `// MARK:` divider in a long Swift file.

Where it does not:

- Inside a short block that is already a single thought.
- More than one consecutive blank line.
- Right after an opening brace or right before a closing brace.

## Indentation and file format

- **Four spaces** in Swift, Rust, and C. **Two spaces** in `web/` and
  `scripts/` TypeScript, matching the surrounding files. Never a tab.
- **UTF-8, UNIX line endings.** Typographic characters are fine in comments,
  string literals, and localized text — the codebase already uses em dashes
  and curly quotes, and the localizations are Japanese and Simplified Chinese.
  Keep identifiers ASCII.
- **No vim modelines.** The tree does not carry them; do not add any.
- **Line width is a guideline, not a limit.** Rust is whatever rustfmt
  produces (100 columns). Swift has no enforced limit, but the tree sits under
  100 columns almost everywhere; treat a line past ~100 as a prompt to
  reconsider the expression, not as an error, and never wrap in a way that
  makes the code harder to read.
- **Leave whitespace alone outside your change.** There is no whitespace
  checker, and much of the tree carries trailing spaces; do not strip or
  reflow lines your change does not otherwise touch. A whitespace-only diff
  buries the real one.

### Swift file headers

Every Swift file under `terminal/` opens with the Xcode header block, and
imports follow after one blank line:

```swift
//
//  ContentView.swift
//  terminal
//

import SwiftUI
```

The Rust bridge uses a `//!` module comment instead, and the hand-maintained
C header uses a `//` block. Both should say what the file is for, not just
name it.

## Naming

Do not use a one-character name, and do not abbreviate past the point of
recognition. A clear name removes the need for a comment.

**Swift** follows the [Swift API Design
Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
`UpperCamelCase` for types and protocols, `lowerCamelCase` for properties,
methods, cases, and locals. Methods that perform an action read as verb
phrases (`refreshStatus()`, `openProject(at:)`); those that return a value
read as noun phrases (`visibleRows`, `resolvedURL`). Booleans read as
assertions (`isDirty`, `hasFocus`).

**Acronyms are uniformly cased**, as Swift itself does it: `URL`, `ID`,
`UUID`, `PTY`, `OSC`, `CLI` — `initialURL`, `selectedTabID`, `CLIError`, not
`initialUrl` or `CliError`. When an acronym starts a lowerCamelCase name, it
is lowercased whole (`urlString`).

**Backend-specific types carry their backend as a prefix**: `AlacrittyFind`,
`AlacrittyTerminalView`, `GhosttyTerminalView`. A name without a prefix is
shared by both backends. Keep this — it is the fastest way to tell which
emulator a file belongs to.

**Rust** follows the standard conventions: `snake_case` for functions,
variables, and modules; `UpperCamelCase` for types; `SCREAMING_SNAKE_CASE` for
constants. Every exported C ABI symbol is prefixed `terminal_alacritty_`.

**TypeScript** in `web/` and `scripts/` follows the surrounding React and Bun
code: `camelCase` values, `PascalCase` components and types.

## Comments

Code says what happens. A comment says *why*, and what a reader must know but
cannot see. This is the project's stated convention ([CLAUDE.md](CLAUDE.md)):
comments explain why — keep them, add them.

The default is not "no comment"; it is "no comment that restates the code".
Add one whenever the reason for the code is not recoverable from reading it:
a platform behavior, a constraint that forced the shape, an alternative that
was tried and rejected, an ordering that looks arbitrary but is not. Those
comments are load-bearing, and this codebase has many of them by design.

Keep the two levels separate:

- **Interface comments** sit before a type, function, or property and describe
  how to use it: what it does, what the arguments mean, what the return value
  and any sentinel values signify, and the invariants a caller must uphold.
- **Implementation comments** sit inside the body and explain what reading it
  does not reveal. Do not repeat the interface comment.

**Never write a comment that only restates the code.** In particular:

- A paraphrase of the line below it: `// increment the counter` over
  `count += 1`.
- A label for self-evident structure: `// initializer`, `// the main loop`,
  `// imports`.
- A step narration that names the call: `// refresh the panel` over
  `panel.refresh()`.
- Prose repeating an already-clear name: `// the pane count` over `paneCount`.

If the only honest comment restates the code, write none. Rename rather than
annotate.

Further conventions:

- Keep the rationale next to the code, not only in a commit message or pull
  request. When you change the code, change the comment in the same edit — a
  stale comment is a defect, not clutter.
- Write comments as full sentences, capitalized, with a closing period.
- A comment describes the code, never the task or conversation that produced
  it. Do not write "as requested" or point at a review thread.
- State the facts the types do not encode: coordinate conventions and index
  bases in the grid and renderer, buffer ownership and lifetime across the
  FFI boundary, which thread or actor a value may be touched from, and the
  escape-sequence or protocol document a parser follows (with a URL).

### Swift comments

`///` doc comments on types and on members whose meaning is not obvious; `//`
inside a body. Use Swift's markup (`- Parameter`, `- Returns`) when a
signature genuinely needs it, not as boilerplate on every function.

```swift
/// The app-specific language macOS should use when Terminal next launches.
///
/// `AppleLanguages` is stored in Terminal's own defaults domain, matching the
/// per-app language preference managed by System Settings. Removing it returns
/// control to the user's system language order.
enum AppLanguage: String, CaseIterable, Identifiable {
```

`// MARK:` divides a long file into sections. Use it where a file has genuine
sections; do not sprinkle it over a short one.

### Rust comments

`//!` for the module or crate overview — `lib.rs` opens with one covering what
the crate owns, the threading model, and buffer lifetimes, which is the
contract Swift depends on. `///` for items. Anything crossing the FFI boundary
documents ownership, validity window, and thread affinity, because none of it
is expressible in the C ABI.

## Swift conventions

**Optionals.** Unwrap with `guard let` and an early return; the codebase uses
`guard` heavily and force-unwrapping almost nowhere. Do not use `try!`, `as!`,
or `!` on an optional unless the invariant is genuinely local and stated in a
comment.

**Concurrency.** The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` and approachable concurrency, so a type is main-actor-isolated
unless it says otherwise. This means:

- Do not decorate everything with `@MainActor` — it is already the default.
- Mark what genuinely leaves the main actor `nonisolated`, and keep those
  types `Sendable`-clean. The PTY read loop, the renderer, and the file-system
  watchers are the ones that do.
- A hop back to the main actor inside a per-frame or per-byte path is a
  performance defect; batch instead.

**AppKit and SwiftUI.** SwiftUI is the default; AppKit is used where
performance matters ([CLAUDE.md](CLAUDE.md)) — terminal rendering, scrollback,
large file trees. Do not move a hot path into SwiftUI view updates, and do not
reach for AppKit where SwiftUI was already adequate.

**Errors.** Throw typed errors that a caller can act on and surface them in
the UI as something a user can respond to. Do not swallow an error into a
`try?` without a comment saying why the failure is not worth reporting.

## User-facing text

Every string a user reads is localized; the development language is English,
with Japanese and Simplified Chinese maintained in String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) — in brief:

- SwiftUI string literals are extracted automatically. When an API needs a
  runtime `String`, use `String(localized:comment:)` and describe any
  placeholder whose meaning is not obvious.
- Write complete sentences. Never assemble one from translated fragments; put
  count-dependent grammar in a plural variant in `Localizable.xcstrings`.
- Mark user content, file names, and terminal output `Text(verbatim:)` so they
  are not treated as lookup keys.
- After adding text, build once, then translate the new entry.

## Untrusted input

Terminal output, a repository's own Git configuration, files another process
or agent is writing, and whatever a host reached over ssh sends back are all
untrusted — this is the project's stated security scope
([SECURITY.md](SECURITY.md)). Code on those paths carries obligations the
type system cannot express:

- **Never hand untrusted data to something that executes.** Read-only `git`
  invocations neutralize repository-supplied `core.fsmonitor` and
  `core.hooksPath`; only an explicit user action runs hooks.
- **Allowlist URL schemes.** Only `http`, `https`, and `mailto` open directly;
  anything else is confirmed against the URL that would really open.
- **Render control characters visibly** in any confirmation prompt. An escape
  sequence must not be able to hide from the sheet asking permission for it.
- **Write through symlinks, not over them**, resolve a path once and use the
  resolved handle for both the check and the action, and give files holding
  session data restrictive permissions.
- **Never let an answer from another machine name a path on this one.** A
  remote host is free to reply with anything, whatever command it was sent —
  including a name containing `/` or `..`. Validate entries where they arrive,
  and keep a path that came from elsewhere away from everything that would
  resolve it here: Finder, the Trash, a drag, the default application.

When you change one of these paths, verify the hostile case fires — and
confirm the fix by reverting it and watching the behavior come back.

## The Rust bridge and the C ABI

- `make fmt` before committing Rust; `make lint` must be clean (clippy runs
  with `-D warnings`). A few pre-existing rustfmt diffs live in the crate, so
  format the files you touched rather than reformatting the tree inside a
  behavior commit.
- `Cargo.lock` is tracked and every build passes `--locked`; a dependency bump
  is a deliberate, separate change.
- `include/terminal_alacritty.h` is hand-maintained against `#[repr(C)]`
  layouts in `src/lib.rs`. Changing either without the other is a silent ABI
  break — update both in the same commit and say so in the message.
- Anything answerable inside the crate (DSR, color queries, text-area size)
  is answered there rather than crossing the boundary twice.

## Testing

There is no Swift test suite. Swift changes are verified by building, running
the app, and exercising the behavior; that is not a shortcut but the actual
requirement, and a change described as "verified" must have been run.

The Rust bridge has `cargo test` suites colocated with the code in
`#[cfg(test)]` modules (`make test-rust`), and `web/` is type-checked
(`make test-web`). Add a Rust test whenever the bridge gains behavior that can
be exercised without a live PTY.

A test should encode why a behavior matters, not merely what it does. A test
that cannot fail when the logic it covers changes is not pulling its weight.

## Commit log

A commit message records why a change happened, which the diff cannot show.
Write it for the person running `git log` or `git blame` a year from now. We
do not use semantic (conventional) prefixes such as `feat:` or `fix:`.

- Write the subject in the imperative, completing "If applied, this commit
  will …" — "Install unsigned builds so the app launches without a Developer
  ID", not "Added …" or "Adds …".
- Capitalize the subject; do not end it with a period.
- Aim for 50 characters; treat 72 as the hard limit.
- Separate subject and body with one blank line, and wrap the body at 79.
- Backtick-quote tokens that are code rather than prose — paths, `make`
  targets, identifiers, flags, build settings, literal values. Ordinary nouns
  stay unquoted: the pane, the git panel, and the editor are prose. A subject
  has little room, so prefer wording that needs no identifier at all.

Use the body to say what changed and why, not how. Make it self-contained: a
reader should be able to judge the change without opening the patch. Describe
the behavior before the change, then why the new behavior is better; name any
alternative you considered and rejected. Where the change is a fix, explain
the mechanism — what actually went wrong, not just that it did.

Close with how the change was verified, in concrete terms: what was exercised
in the running app, which suites ran, and what could not be verified. Never
write a verification claim for something that only compiled.

One concern per commit. A one-line subject is enough for a trivial change.

## Changelog and version

[CHANGELOG.md](CHANGELOG.md) is the product changelog for end users, and the
source of truth for the release notes the in-app updater shows. Add an entry
only when a user experiences the change, write it as the final shipped
outcome under `## [unrelease]`, and fold later refinements into the existing
bullet rather than adding entries for incremental fixes, refactors, or
regressions introduced and resolved on the same branch.

Never bump the version. `MARKETING_VERSION` and numbered changelog headings
belong to `scripts/release.ts` and are maintainer-only; see
[RELEASING.md](RELEASING.md).
