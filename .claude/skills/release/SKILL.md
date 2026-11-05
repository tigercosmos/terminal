---
name: release
description: Cut a Terminal release -- pick the next version, finalize CHANGELOG.md, bring README.md and the website up to date, bump MARKETING_VERSION and the build number, then push a tag so CI publishes the GitHub Release with its .dmg. Use when the user asks to cut, ship, or publish a release, make a new version, or bump the version for a release. Ordinary pull requests never bump the version, so this is not for those.
---

# Release (Terminal)

`RELEASING.md` ("The GitHub Release `.dmg`") is canonical; this file is the
working protocol on top of it. Flag any drift between the two.

This skill takes the tag path. `bun scripts/release.ts` (`bun run release`) is
the signed Sparkle path and needs a Developer ID, a Sparkle key, and an archive
host that this fork does not have, so do not run it despite the name.

Pushing the tag is what publishes: anyone can download the result, and a tag
people have seen cannot be quietly taken back. Everything before step 6 is local
and easy to undo, so do it freely. **Step 6 waits for the user's go-ahead, even
when they asked for the release by name**, because that is the first time they
see the version, the notes, and the doc edits together.

Below, `X.Y.Z` is the new version. Pass `--repo tigercosmos/terminal` to every
`gh` command: this repository is a fork, and `gh` can resolve to the parent.

## 1. Preflight

```sh
git fetch origin --tags
git status --porcelain                         # must be empty
git rev-parse --abbrev-ref HEAD                # must be main
git rev-list --left-right --count origin/main...HEAD   # must be 0 0
last=$(git describe --tags --abbrev=0 --match 'v*')
git log --format='%h %s' "$last"..HEAD
grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' terminal.xcodeproj/project.pbxproj
gh run list --repo tigercosmos/terminal --workflow tests.yml --branch main -L 1 \
  --json conclusion,headSha,databaseId
```

Stop and report rather than work around any of these:

- A dirty tree, another branch, or `main` out of step with `origin`. A stash or
  an unpushed commit would change what ships without anyone choosing that.
- `MARKETING_VERSION` not matching `$last`, or the two build settings disagreeing
  between their Debug and Release lines. Something already moved the version.
- No commits since `$last`. There is nothing to release.
- Tests not green at `HEAD`. Read the jobs before calling it a failure: the run
  can report `failure` with a job `cancelled` and no failed step, which says
  nothing about the code. Rerun it with `gh run rerun`. A real failure blocks the
  release until the user decides.

## 2. Pick the version

Use the version the user named. Otherwise propose one from what is shipping:
`Z + 1` when it is only fixes (0.9.0 to 0.9.1), `Y + 1` with `Z` reset when it
adds something a user can do (0.8.0 to 0.9.0). The build number is always the
current `CURRENT_PROJECT_VERSION` plus one: Sparkle compares it to decide what is
newer, so it must rise even though this path has no updater yet.

Confirm the tag is free: `git rev-parse -q --verify refs/tags/vX.Y.Z` and
`gh release view vX.Y.Z --repo tigercosmos/terminal` should both fail.

## 3. Finalize the changelog

These notes become the GitHub Release body and the website's changelog page, and
they are the only account of the release most people read.

Compare the `## [unrelease]` bullets against every commit since `$last`, reading
the commit bodies rather than the subjects:

- A user-visible change with no bullet gets one. This is the common gap: 0.9.1
  shipped a fix that had no entry until the release itself added it.
- Commits a user cannot feel (tests, CI, refactors, automation for drivers) get
  none. Thread what they enable into the feature's bullet if it matters.
- Something introduced and fixed inside this range is folded into its feature's
  bullet, not listed. `CLAUDE.md` is firm on this: a product changelog, not a
  development log.

Write each bullet as the shipped outcome, in the voice of the bullets around it.
Do not claim anything the commits do not support.

Then retitle the section, and leave no empty `## [unrelease]` behind (the next
change that needs one adds it):

```sh
sed -i '' 's/^## \[unrelease\]$/## [X.Y.Z]/' CHANGELOG.md
bun scripts/changelog.ts X.Y.Z   # must print the notes
```

That check matters because the script treats a missing section as normal, and
the workflow would publish a release with no notes rather than fail.

## 4. Update the README and the website

Go through the finished bullets and ask of each whether these still tell the
truth and still mention what a new reader would want to know. Most fixes change
nothing here; a new capability usually does.

- `README.md`: the highlights list, and "Beyond Kero" for work this fork adds.
- `web/src/routes/index.tsx`: `FEATURES` (its `beyond kero` group should match
  the README section), `SHORTCUTS` (spelled out, `Cmd+Shift+C`), and `FAQ` when
  an answer stopped being true.
- `FALLBACK` in that same file: move `version` and the `.dmg` URL to `X.Y.Z`,
  every release. It is shown when the GitHub lookup fails, so leaving it behind
  hands those visitors the previous build. `minSystem` follows the app's
  deployment target and rarely moves.

Leave alone: the site's changelog page (it reads `CHANGELOG.md` at build time)
and `v1.1` in `RELEASING.md` (a placeholder, not a stale version). The README
may rightly stay unchanged; say so rather than padding it.

## 5. Bump and verify

```sh
sed -i '' -E 's/(MARKETING_VERSION = )[^;]+;/\1X.Y.Z;/; s/(CURRENT_PROJECT_VERSION = )[^;]+;/\1BUILD;/' \
  terminal.xcodeproj/project.pbxproj
git diff --stat terminal.xcodeproj/project.pbxproj   # 4 lines changed each way, nothing else

make build-release
make test-web

settings=$(xcodebuild -project terminal.xcodeproj -scheme terminal -configuration Release -showBuildSettings 2>/dev/null)
app="$(printf '%s\n' "$settings" | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')/$(printf '%s\n' "$settings" | sed -n 's/^ *WRAPPER_NAME = //p')"
plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist"   # X.Y.Z
plutil -extract CFBundleVersion raw "$app/Contents/Info.plist"              # BUILD
```

The tag check in CI would catch a version mismatch, but only after the tag is
public. Build failures found here cost nothing.

## 6. Get the go-ahead

Show the user, in one message: `vX.Y.Z` and the build number, the release notes
as they will read, the README and website edits (or that there were none), what
ran in step 5, and the commit message. Wait for their answer before going on.

## 7. Commit, tag, push

Stage exact paths, only the ones that changed. Unlike all other work, a release
commit goes straight on `main` with no pull request, so that the tag sits on
`main`'s history.

The message follows `STYLE.md` and past releases (`git log --grep '^Release '`):
subject `Release X.Y.Z`, then what users get, the build number, why the docs
moved, and how it was verified. Saying each change was verified in the app on its
own branch is only true if the commit bodies say so; report what they show.

```sh
git add CHANGELOG.md terminal.xcodeproj/project.pbxproj web/src/routes/index.tsx README.md
git diff --cached --stat
git commit -F - <<'MSG'
Release X.Y.Z

<approved body wrapped at 79, ending with the attribution lines in force>
MSG
git tag vX.Y.Z
git push --atomic origin main vX.Y.Z
```

`--atomic` means the tag cannot land without its commit. Push to `origin` only;
`kero` is the upstream project. Do not run `gh release create` yourself: the
workflow writes the notes, including the quarantine line, only when it creates
the release. If one already exists it just uploads the `.dmg`.

## 8. Watch it publish

The run appears a few seconds after the push and took about six minutes on recent
releases. Watch it in the background rather than polling:

```sh
gh run list --repo tigercosmos/terminal --workflow release.yml --branch vX.Y.Z -L 1 --json databaseId,status
gh run watch <id> --repo tigercosmos/terminal --exit-status
```

Then confirm what people will actually get:

```sh
gh release view vX.Y.Z --repo tigercosmos/terminal --json name,isDraft,url,assets,body
gh release list --repo tigercosmos/terminal -L 1             # this release is Latest
gh run list --repo tigercosmos/terminal --workflow pages.yml -L 1 --json event,status,conclusion
curl -s https://tigercosmos.github.io/terminal/ | grep -oE 'terminal-[0-9.]+\.dmg' | sort -u
```

Expect the title `terminal X.Y.Z`, the asset `terminal-X.Y.Z.dmg`, notes that end
with the `xattr` line, and a site naming `X.Y.Z` once the `workflow_dispatch`
Pages run finishes. If the site lags, `gh workflow run pages.yml --ref main --repo
tigercosmos/terminal` rebuilds it.

## When the run does not finish

**The job cannot start.** `xcode-27` is GitHub's preview image and can queue or
go missing. If it has sat queued for about half an hour, ask the user, then build
here:

```sh
gh run cancel <id> --repo tigercosmos/terminal   # or it may later overwrite the .dmg
bun scripts/build-dmg.ts --expect X.Y.Z
```

The job never reached its publish step, so no release exists yet and `gh release
upload` has nothing to attach to. Run the commands from the "Publish the release"
step of `.github/workflows/release.yml` by hand, with the tag for
`$GITHUB_REF_NAME`, so the notes match every other release. Then run the Pages
workflow as above. Note in the report that the `.dmg` was built locally.

**The build fails.** Read the log and tell the user what broke. No release exists,
but the tag is public. Do not move or delete it without asking. Fixing forward
with the next patch version is the clean answer; retagging is theirs to choose.

## Output

- End with one line: `released: <release URL> (vX.Y.Z, build N)`.
- List anything skipped or not verified, such as a `.dmg` built locally, or a site
  still showing the old version.
- If a preflight check or gate stops the release, output `blocked: <reason>` and
  stop. Nothing after step 5 has happened at that point, so say which local edits
  remain in the tree.
