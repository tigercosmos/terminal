#!/bin/bash
# .claude/hooks/check-source.sh
#
# PostToolUse hook for Write|Edit on Terminal sources (Claude Code).
# PostToolUse hook for Edit|Write in Codex (via .codex/hooks.json).
# postToolUse / afterFileEdit hook for Cursor (via .cursor/hooks.json).
#
# Rust is the only language here with a formatter the project actually
# enforces (`make fmt` / `make fmt-check` wrap `cargo fmt`), so this hook
# reports rustfmt findings on the file that was just edited. Swift has no
# formatter configured and the tree does not hold a whitespace or line-width
# convention worth machine-checking -- style there is a judgment call, which
# is what the `swift-style-review` skill is for.
#
# Findings are advisory: a handful of pre-existing rustfmt diffs live in the
# bridge, so a blocking hook would stall on lines the edit never touched. The
# report goes back to the agent as context, never as a failure.

input=$(cat)

hook_event=""
files=""
if command -v jq >/dev/null 2>&1; then
    hook_event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
    files=$(printf '%s' "$input" | jq -r '
        .file_path //
        .tool_input.file_path //
        .tool_input.path //
        empty
    ')

    # Codex passes an apply_patch payload rather than a path; recover the
    # touched files from the patch header lines.
    if [ -z "$files" ]; then
        patch=$(printf '%s' "$input" | jq -r '
            .tool_input.patch //
            .tool_input.input //
            (if (.tool_input | type) == "string" then .tool_input
             else empty end) //
            empty
        ')
        files=$(printf '%s\n' "$patch" | sed -nE \
            -e 's/^\*\*\* (Add|Update) File: (.*)$/\2/p' \
            -e 's/^\*\*\* Move to: (.*)$/\1/p')
    fi
else
    files=$(printf '%s' "$input" \
        | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)
fi

[ -z "$files" ] && exit 0
command -v rustfmt >/dev/null 2>&1 || exit 0

violations=""
add() { violations="${violations}  $1"$'\n'; }

check_file() {
    file="$1"

    [ -f "$file" ] || return
    case "$file" in
        *.rs) ;;
        *) return ;;
    esac

    # rustfmt --check reports one "Diff in <path>:<line>:" header per hunk. It
    # follows `mod` declarations, so a check rooted at lib.rs reports the whole
    # crate; keep only the hunks in the file that was actually edited. The
    # bridge is edition 2021, and rustfmt assumes 2015 on a bare file.
    resolved=$(cd "$(dirname "$file")" && printf '%s/%s' "$PWD" "$(basename "$file")")
    lines=$(rustfmt --edition 2021 --check "$file" 2>/dev/null \
        | sed -nE 's/^Diff in (.+):([0-9]+):$/\1|\2/p' \
        | awk -F'|' -v want="$resolved" '$1 == want { print $2 }' \
        | head -5 | paste -sd, -)
    [ -n "$lines" ] && add "$file:$lines -- rustfmt would reformat -- run \`make fmt\` (or \`cargo fmt\`)"
}

while IFS= read -r file; do
    [ -n "$file" ] && check_file "$file"
done < <(printf '%s\n' "$files" | awk '!seen[$0]++')

[ -z "$violations" ] && exit 0

msg=$(printf 'Formatting notes (advisory):\n%s' "$violations")

case "$hook_event" in
    postToolUse)
        # Cursor postToolUse: JSON on stdout.
        command -v jq >/dev/null 2>&1 \
            && jq -n --arg ctx "$msg" '{additional_context: $ctx}'
        exit 0
        ;;
    afterFileEdit)
        # Cursor afterFileEdit: stderr only.
        printf '%s' "$msg" >&2
        exit 0
        ;;
esac

# Claude Code and Codex both accept JSON on stdout; Claude needs the finding
# inside hookSpecificOutput for the agent to see it without the call failing.
if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$msg" '{
        systemMessage: $ctx,
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $ctx
        }
    }'
else
    printf '%s' "$msg" >&2
fi
exit 0
