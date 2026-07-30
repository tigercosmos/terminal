---
name: swift-style-review
description: Apply Terminal's judgment-call Swift conventions (match the surrounding file, comments that explain why, localized user-facing text, untrusted-input discipline, AppKit-vs-SwiftUI placement) to changed lines under terminal/. Use after editing Swift sources.
tools: Read, Grep, Glob, Edit, Bash
---

# Swift Style Review (Terminal)

`STYLE.md` at the repo root is canonical; `CLAUDE.md` summarizes it and
`LOCALIZATION.md` owns user-facing text. If they disagree with this file,
follow them and flag the drift in the verdict. The rules below are the subset
worth checking on a diff, not a replacement for reading `STYLE.md`.

## Scope

Review only lines that appear in `git diff` against the merge base (or `HEAD`
if explicitly requested). Do NOT flag pre-existing violations on unchanged
lines. `Vendor/` is third-party -- review it only when the diff deliberately
patches it, and then hold it to its own upstream style, not this one.

There is no Swift formatter or linter in this project, and the tree does not
hold a machine-checkable whitespace or line-width convention -- every rule
here is a judgment call, which is why the review is a skill rather than a
hook. The one deterministic check that does exist (rustfmt, for the Rust
bridge) runs in `.claude/hooks/check-source.sh`; do not duplicate it.

Much of the tree carries trailing whitespace and there is no checker for it.
Do not reflow or strip lines the change does not otherwise touch -- a
whitespace-only diff buries the real change.

## Judgment-call rules

**Match the file you're in**
- This is the project's first convention, and `STYLE.md` says the surrounding
  file wins whenever it disagrees with the guide. Naming, ordering, spacing,
  doc-comment style, and error handling follow the file, not a general Swift
  style guide and not the reviewer's preference.
- Flag a diff that introduces a second idiom for something the file already
  does one way.

**Naming (STYLE.md "Naming")**
- Swift API Design Guidelines: `UpperCamelCase` types, `lowerCamelCase`
  members, verb phrases for actions, noun phrases for values, assertions for
  booleans.
- Acronyms are uniformly cased -- `initialURL`, `selectedTabID`, `CLIError`.
  Flag `Url`, `Id`, `Cli`.
- Backend-specific types carry their backend as a prefix (`Alacritty…`,
  `Ghostty…`); an unprefixed name means both backends share it.

**Optionals and concurrency (STYLE.md "Swift conventions")**
- `guard let` with an early return is the house style. Flag a new `try!`,
  `as!`, or force-unwrap that has no stated local invariant.
- The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so main-actor
  isolation is the default. Flag a redundant `@MainActor`, an unannotated type
  that genuinely leaves the main actor (should be `nonisolated` and
  `Sendable`-clean), and a main-actor hop added inside a per-frame or
  per-byte path.

**Comments**
- **Comments explain *why*.** A comment restating what the code does earns
  nothing; a comment recording the constraint, the platform behavior, or the
  rejected alternative is the point. Flag a new comment that only narrates.
- Keep existing comments. When a change invalidates one, update it -- a stale
  comment is a defect, not clutter.
- Files here open with a `//  <Name>.swift` header block and use `///` doc
  comments on types and non-obvious members. Follow what the file already
  does.

**User-facing text (LOCALIZATION.md)**
- SwiftUI string literals are extracted automatically; a runtime `String`
  needs `String(localized:comment:)`, with the comment describing any
  placeholder whose meaning is not obvious.
- Flag a user-visible literal that skips localization, and flag assembling a
  sentence from translated fragments -- use a complete sentence, and put
  count-dependent grammar in a plural variant in `Localizable.xcstrings`.
- User content, file names, and terminal output must be `Text(verbatim:)` so
  they are not treated as lookup keys. Flag the reverse: a `Text(someUserPath)`
  that will be looked up as a key.
- New text means the entry must be translated in `Localizable.xcstrings` after
  a build; note it when the diff adds text and leaves the catalog untouched.

**Untrusted input**
- Terminal output, a repository's own Git configuration, and files an agent or
  another process is writing are untrusted. Flag a diff that passes any of
  them to `LaunchServices`, a shell, `git` without neutralizing repo-supplied
  hooks (`core.fsmonitor`, `core.hooksPath`), or a URL opener without a scheme
  allowlist.
- Flag a confirmation prompt that renders untrusted text without escaping
  control characters -- an escape sequence must not be able to hide from the
  sheet asking permission for it.
- Flag a file write that replaces a symlink instead of writing through it, a
  read-then-act on a path that can be repointed in between, and secrets
  written without restrictive permissions.

**AppKit and SwiftUI**
- AppKit is used over SwiftUI where performance matters (`CLAUDE.md`). Flag a
  change that moves a hot path (terminal rendering, scrollback, large file
  trees) into SwiftUI view updates, and flag AppKit added where SwiftUI was
  already adequate.
- UI state touched from a background context needs the actor annotation the
  surrounding type uses; flag a new `@MainActor` hop added inside a render
  path, and a mutation of view state that has none.

**Changelog and version**
- `CHANGELOG.md` gets an entry only when a user experiences the change, under
  `## [unrelease]`, written as the final shipped outcome. Flag entries for
  refactors, incremental fixes, or regressions introduced and resolved on the
  same branch -- those fold into the feature's existing bullet.
- Flag any `MARKETING_VERSION` change or numbered `CHANGELOG.md` heading: the
  version is never bumped outside a release.

## Workflow

1. `git diff --name-only` against the merge base; filter to `terminal/**/*.swift`
   (and `scripts/**`, `web/**` when the change reaches them).
2. For each file, read the diff hunks, then open enough of the surrounding
   file to judge "matches the file it's in".
3. Apply the rules above to changed lines.
4. Output each finding as
   `path:line -- rule -- (fix applied | suggestion): <description>`.
5. End with a single verdict line: `verdict: clean | issues found | blocking`.
   Use `clean` only when no findings remain after any hand-fixes. Reserve
   `blocking` for something that breaks the build, ships untranslated
   user-facing text, or leaves an untrusted-input path exploitable.

## Output

- Bullets only. No prose summaries.
- Don't paste long code excerpts; point to `file:line`.
- Be explicit when uncertain ("not sure whether X is intentional -- please
  confirm").
- Hand-fix nits; leave anything that changes behavior as a suggestion.
- Style review is not verification. A clean verdict does not mean the change
  works -- see `verify-change`.
