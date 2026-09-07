#!/usr/bin/env bash
# List upstream (Kero) commits newer than the last synced marker, flagging the
# ones SYNC.md already accounts for.
#
# Past syncs were applied by hand rather than merged, so upstream commits that
# were already taken are still not ancestors here: `git log HEAD..kero/main`
# lists them forever. The subjects are reworded on the way in, so the only
# reliable record of what has been dealt with is the SHAs written into the
# SYNC.md log — taken and not-taken alike.
#
# Usage: .claude/skills/sync-upstream/list-new.sh [marker]
#   marker defaults to the SHA in the newest "kero/main at" heading in SYNC.md.
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

marker=${1:-}
if [ -z "$marker" ]; then
  marker=$(grep -m1 -E '^### .*kero/main.* at ' SYNC.md \
    | grep -o '`[0-9a-f]\{7,40\}`' | head -1 | tr -d '`')
fi
if [ -z "$marker" ]; then
  echo "could not determine marker from SYNC.md; pass one explicitly" >&2
  exit 1
fi

git fetch kero --no-tags --quiet

if ! git rev-parse --verify --quiet "$marker^{commit}" >/dev/null; then
  echo "marker $marker is not a commit in this repository" >&2
  exit 1
fi

# Every SHA the SYNC.md log names, resolved to full SHAs. Entries record both
# what was taken and what was deliberately skipped; both count as handled.
recorded=$(grep -o '`[0-9a-f]\{7,40\}`' SYNC.md | tr -d '`' | sort -u \
  | while read -r sha; do
      git rev-parse --verify --quiet "$sha^{commit}" || true
    done)

total=$(git rev-list --count "$marker"..kero/main)
echo "marker: $marker   range: $marker..kero/main   ($total commits)"
echo

new=0
while IFS=$'\t' read -r sha subject; do
  full=$(git rev-parse "$sha")
  if printf '%s\n' "$recorded" | grep -qxF "$full"; then
    printf '%s\t%s\t[in SYNC.md]\n' "$sha" "$subject"
  else
    new=$((new + 1))
    printf '%s\t%s\n' "$sha" "$subject"
  fi
done < <(git log --reverse --format='%h%x09%s' "$marker"..kero/main)

echo
echo "$new commits not accounted for in SYNC.md (of $total in range)"
echo
echo "Next: triage by message, NOT by diff —"
echo "  git log --format='%h %s%n%b%n---' $marker..kero/main"
echo "  git show --stat <sha>"
