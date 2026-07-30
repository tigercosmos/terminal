---
name: create-pr
description: Open a Terminal pull request that follows the project protocol (subject and body that state what a user can now do, how it was verified, draft by default, no version bump). Use when the user asks to create, open, or draft a pull request.
---

# Create Pull Request (Terminal)

`CONTRIBUTING.md` ("Pull requests") is canonical; this file is the working
protocol built on top of it. Flag any drift between the two.

## Protocol the PR must satisfy

1. **Subject** -- concise and informative, in the imperative, describing the
   outcome rather than the mechanism.
2. **Description** -- short prose a person would actually want to read. Say
   what a user can now do that they could not before, or what stopped going
   wrong -- not which files moved. State how the change was verified, and call
   out anything that could not be verified. Prefer one to three paragraphs;
   fall back to a bulleted list only when prose would genuinely be unreadable
   (a long enumeration, a benchmark matrix).
   **Do not hard-wrap paragraphs.** Each paragraph is a single unbroken line,
   separated by one blank line. GitHub reflows to the viewer's width, and
   mid-sentence breaks at 79 columns render as ragged prose. The source-code
   wrap limit does not apply to a PR body.
3. **Issue reference** -- when the work has an issue, end with
   `Related to #xxx.` Ask the user before using a closing keyword
   (`fixes #xxx`): whether a merge should close an issue is the maintainer's
   call, not the PR text's.
4. **Draft by default** -- open as draft unless the user explicitly says it is
   ready for review.
5. **Never bump the version.** `MARKETING_VERSION` and numbered `CHANGELOG.md`
   headings belong to the release, not the PR (`RELEASING.md`). If the branch
   carries one, stop and tell the user.
6. **CHANGELOG entry when, and only when, users see the change.** It describes
   the final shipped outcome under `## [unrelease]`, not the development
   history (`CLAUDE.md`).
7. **Inline annotations** -- guide the reviewer through the diff unless it is
   one-liner-ish. The skill reminds the user; it does not write them.
8. **Human authorship** -- the user must know what the text says. Present the
   draft for review and edits before posting.

## Workflow

1. **Confirm scope with the user.** Ask directly when unclear from context:
   - Which issue does this PR relate to, if any?
   - Draft, or ready for review?
   - One-line gist of the change.

2. **Verify branch state.** The main branch is `main`. Run in parallel:
   - `git status --porcelain` -- staged, unstaged, and untracked files.
   - `git log --oneline origin/main..HEAD` -- the commits the PR will carry.
   - `git diff --stat origin/main...HEAD` -- the diff (three-dot uses the
     merge base).
   - `git rev-parse --abbrev-ref --symbolic-full-name @{u}` -- whether the
     branch tracks a remote.

   If `git status --porcelain` shows output, the working tree is not clean.
   Show the user the three groups separately and ask how to proceed: stage and
   commit selected files, stash, or abort. Never run `git add -A` or
   `git add .` without confirmation -- `Config/Local.xcconfig`, build output,
   and `.claude/settings.local.json` must not be pulled in.

   If the branch has no commits ahead of `origin/main`, abort -- the PR would
   be empty. If the branch is not pushed (or is behind its remote), push after
   confirming with the user.

3. **Draft the subject and body.** Read the diff and the user's gist, then
   propose both. Ground every claim about verification in what actually ran
   this session. End with `Related to #xxx.` when there is an issue.

   **Write each paragraph as one continuous line** -- in the draft you show
   the user and in `$body_file` in step 4 alike.

4. **Open the PR.** Load the approved title and body with **quoted heredocs**
   so backticks, `$`, quotes, and apostrophes need no escaping, then pass the
   body through a temp file:

   ```bash
   title=$(cat <<'TITLE'
   <approved subject>
   TITLE
   )

   body_file=$(mktemp)
   trap 'rm -f "$body_file"' EXIT
   cat >"$body_file" <<'BODY'
   <approved body, already ending with "Related to #xxx." when there is one>
   BODY

   gh pr create --draft --base main \
     --title "$title" \
     --body-file "$body_file"
   ```

   Drop `--draft` only when the user has explicitly said the PR is ready. The
   `trap` removes the temp file on any exit path. If the body itself contains
   the literal token `BODY` on its own line, swap the delimiter for something
   unique (e.g. `BODY_EOF_811`).

   This repository is a fork; `gh pr create` defaults to the parent
   repository. Confirm the target with `gh repo view --json nameWithOwner` and
   pass `--repo tigercosmos/terminal` unless the user is deliberately opening
   the PR upstream.

5. **After creation.** Report the PR URL. Then remind the user to add inline
   annotations on the diff, focusing on what helps a reviewer most:
   - non-obvious design choices and the alternatives considered;
   - subtle logic, invariants, or ordering constraints a reader might
     overlook;
   - changes that look like dead code or accidental edits but are intentional;
   - known limitations, follow-up work, and test-coverage gaps;
   - tricky diffs (large reformatting beside substantive edits, cross-file
     renames) where the reviewer needs to know what is mechanical.

   Skip the reminder when the diff is genuinely one-liner-ish.

## Guardrails

- **Version bump.** Before `gh pr create`, confirm the branch does not touch
  the version:

  ```bash
  git diff origin/main...HEAD -- terminal.xcodeproj/project.pbxproj \
      | grep -E '^\+[[:space:]]*MARKETING_VERSION'
  git diff origin/main...HEAD -- CHANGELOG.md | grep -E '^\+##[[:space:]]+\[[0-9]'
  ```

  Any hit blocks the PR: the bump belongs to a release, not here.

- **Hard-wrapped prose.** The source wrap limit does NOT apply to a PR body;
  each paragraph must be one unbroken line. This is easy to violate by reflex
  after a session of editing wrapped source, so treat it as a mechanical gate.
  After writing `$body_file` but **before** `gh pr create`, scan for a
  paragraph split across lines -- any two consecutive non-blank prose lines:

  ```bash
  awk '
    /^```/            { fence = !fence; prev = 0; next }
    fence             { next }
    /^[[:space:]]*$/  { prev = 0; next }
    /^[[:space:]]*([-*+>|]|[0-9]+\.)/ { prev = 0; next }
    { if (prev) { print "hard-wrap at line " NR ": " $0; hit = 1 }
      prev = 1 }
    END { exit hit }
  ' "$body_file"
  ```

  A non-zero exit means a paragraph was wrapped. Rejoin it into a single line
  (fenced blocks, list items, and table rows are exempt and skipped) and
  re-run.

- **Branch protection.** Never push directly to `main`, never `--no-verify`.
  If `gh pr create` fails, surface the error and stop -- do not work around
  it.

- **No fabricated context.** Do not invent verification claims, benchmark
  numbers, or test results. Only what the user stated or what ran this
  session.

- **Diff accuracy.** Before presenting the draft, re-read
  `git diff origin/main...HEAD` and confirm every claim corresponds to a hunk.
  Drop claims about behavior the diff does not change.

## Output

- Show the draft subject and body in a fenced block before calling
  `gh pr create`, so it is easy to edit.
- After creation, output a single line: `opened: <PR URL> (draft|ready)`.
- If a guardrail blocks the action (version bump, dirty tree, unpushed
  branch), output `blocked: <reason>` and stop. Do not retry silently.
