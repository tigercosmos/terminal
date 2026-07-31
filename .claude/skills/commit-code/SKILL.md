---
name: commit-code
description: Commit changes the Terminal way -- one concern per commit, verified before staging, with a message that says what a user can now do and why the change looks the way it does. Use when the user asks to commit, split work into commits, organize or rewrite commit history, or write a commit message.
---

# Commit Code (Terminal)

The "Commit log" section of `STYLE.md` at the repo root is canonical for the
message format, and `CONTRIBUTING.md` ("Verifying a change") for what a change
must satisfy before it is committed; `create-pr` covers pull requests. This
skill adds the surrounding workflow and the conventions that differ from
default git habits.

## Workflow

1. **Survey.** Run `git status --porcelain` and `git diff --stat` to see what
   changed. Group the changes into one-concern commits. Ask before staging
   when a file's grouping is unclear or it looks unrelated to the task.
2. **Verify.** A green build is not evidence that a feature works: build, run
   the app, and exercise the change itself (`make run`, or the `verify-change`
   skill for the full loop). Run `make test-rust` and `make lint` when the
   diff touches `Vendor/alacritty-bridge`, `make test-web` when it touches
   `web/`. Never commit a change you have not exercised, and never claim in
   the message that you did.
3. **Commit each concern.** Stage the exact paths (`git add <path>`), confirm
   `git diff --cached --stat` shows only that concern, draft the message,
   present the subject (and body, when non-trivial) for review, then commit
   with a quoted heredoc so backticks, `$`, and quotes survive unescaped:

   ```bash
   git commit -F - <<'MSG'
   <approved subject>

   <approved body wrapped at 79, if any>
   MSG
   ```
4. **Verify the history.** Run `git log --oneline` and report the commits
   created.

## Message format

Follow `STYLE.md` "Commit log" -- do not restate it here. In brief: imperative
subject (capitalized, no period, aim 50 / 72 hard limit), one blank line, then
a body wrapped at 79 that says what a user can now do that they could not
before -- or what stopped going wrong -- and why the change looks the way it
does. Explain the reasoning a reader could not recover from the diff: the
mechanism behind a bug, the alternative that was rejected, the constraint that
forced the shape. Backtick-quote code tokens, not ordinary nouns. Close with
how the change was verified. A one-line subject suffices for a trivial change.

`git log` in this repository is the working reference; read a few recent
bodies before writing one.

## Conventions that differ from default git habits

These contradict common defaults, so apply them deliberately:

- **No semantic prefixes.** Never use `feat:`, `fix:`, `docs:`, etc.
- **One concern per commit.** Each commit stands on its own. Do not pad:
  trivial, tightly-coupled edits belong together.
- **Stage exact paths.** Never `git add -A` / `git add .`; never
  `--no-verify`. Stray files (`Config/Local.xcconfig`, build artifacts,
  `.claude/settings.local.json`) must not ride along.
- **Topic branch only.** Never commit directly on `main`; branch first (the
  `worktree` skill isolates the work when the main checkout should stay
  clean).
- **Never bump the version** unless the task is cutting a release.
  `MARKETING_VERSION` and numbered `CHANGELOG.md` headings are maintainer-only
  (`RELEASING.md`) — ordinary work writes under `## [unrelease]` and leaves the
  version alone. A release commits the bump on its own, ahead of the tag.
- **CHANGELOG.md is a product changelog, not a development log.** Only add an
  entry when the change alters what a user experiences, and write it as the
  final shipped outcome. Fold refinements into the existing bullet of an
  unreleased feature rather than adding entries for incremental fixes,
  refactors, or regressions introduced and resolved on the branch.

## Rewriting history

When asked to organize or clean up commits, recreate them rather than patching
messages one by one:

1. Soft-reset to the merge base: `git reset --soft <base>`, then
   `git restore --staged .`.
2. Recommit by concern as in the workflow above, in an order that reads as a
   coherent progression.
3. Before pushing, confirm the rewritten tree is identical to the prior tip:
   `git diff <old-tip> HEAD` must be empty.
4. Push with `git push --force-with-lease`, never a bare `--force`.

## Guardrail: unverified claims

A commit body in this repository usually ends by stating how the change was
verified. Include that line only for checks that actually ran in the session,
naming what was exercised. Never write "verified in the app" for a change that
was only compiled, and say plainly what could not be verified.
