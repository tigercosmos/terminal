#!/bin/bash
# .claude/hooks/check-version-bump.sh
#
# PreToolUse hook for Bash (Claude Code); also wired for Codex via
# .codex/hooks.json. Blocks a `git commit` that stages a version bump.
#
# Releases are cut by `scripts/release.ts` and are maintainers-only
# (RELEASING.md); CLAUDE.md states the version is never bumped in a PR. Two
# things carry a version: MARKETING_VERSION in the Xcode project, and a
# `## [x.y.z]` release heading in CHANGELOG.md. Editing the `## [unrelease]`
# section is normal work and is not blocked.
#
# Exit 2 with the offending paths on stderr to block the command.

input=$(cat)

if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
    cmd=$(printf '%s' "$input" \
        | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)"[^"]*}.*/\1/p' \
        | head -1)
fi

[ -z "$cmd" ] && exit 0

# Only gate the command that checks work in.
case "$cmd" in
    *"git commit"*) ;;
    *) exit 0 ;;
esac

staged=$(git diff --cached 2>/dev/null)
[ -z "$staged" ] && exit 0

findings=""

printf '%s\n' "$staged" | grep -qE '^\+[[:space:]]*MARKETING_VERSION[[:space:]]*=' \
    && findings="${findings}  terminal.xcodeproj/project.pbxproj -- MARKETING_VERSION changed"$'\n'

printf '%s\n' "$staged" | grep -qE '^\+##[[:space:]]+\[[0-9]' \
    && findings="${findings}  CHANGELOG.md -- new numbered release heading (write under \`## [unrelease]\` instead)"$'\n'

[ -z "$findings" ] && exit 0

{
    echo "Hook violation: a version bump is staged for commit."
    printf '%s' "$findings"
    echo "Releases come from \`bun scripts/release.ts\` and are maintainer-only"
    echo "(RELEASING.md). Never bump the version in a PR. Unstage these"
    echo "(\`git restore --staged <path>\`) and commit the change itself."
} >&2
exit 2

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
