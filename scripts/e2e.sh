#!/bin/zsh
# End-to-end checks against a running Terminal, with no pixels read and no
# input synthesized from outside the app.
#
# The app injects its own input and reports its own state over the CLI channel
# it already has, so neither Screen Recording nor Accessibility is ever asked
# for — which matters because debug builds are unsigned and lose a TCC grant on
# every rebuild.
#
#   make e2e
#
# Launches a debug build with TERMINAL_AUTOMATION=1, drives it, and leaves it
# running. Requires a GUI session; this cannot run on a headless runner.

set -u
setopt err_return
# The state directory appears a moment after launch; a glob that matches
# nothing yet is expected, not an error.
setopt null_glob

app=${1:?usage: e2e.sh /path/to/Terminal Debug.app}

fail() { print -u2 "e2e: $*"; exit 1; }

# --- launch, armed -----------------------------------------------------------

# The bridge in this shell's environment, if any, belongs to whichever build
# opened it; dropping it makes `open` start the app rather than talk to one.
env -u TERMINAL_CLI_STATE -u TERMINAL_CLI_TOKEN -u TERMINAL_CLI_BUNDLE \
    open -a "$app" --env TERMINAL_AUTOMATION=1

cli="$app/Contents/MacOS/terminal"
[[ -x $cli ]] || fail "no terminal CLI inside $app"

# The app writes its bridge once it has a state directory. Wait for the newest
# one to appear rather than guessing how long a launch takes.
bridge=""
for _ in {1..100}; do
    sleep 0.2
    bridge=$(print -rl -- "${TMPDIR%/}"/terminal-cli-*/automation.json(Nom[1]) 2>/dev/null) || true
    [[ -n $bridge ]] && break
done
[[ -n $bridge ]] || fail "the app did not arm; was it built with a debug configuration?"

eval "$(
    /usr/bin/python3 -c '
import json, shlex, sys
bridge = json.load(open(sys.argv[1]))
for key, value in {
    "TERMINAL_CLI_STATE": bridge["state"],
    "TERMINAL_CLI_TOKEN": bridge["token"],
    "TERMINAL_CLI_BUNDLE": bridge["bundle"],
}.items():
    print(f"export {key}={shlex.quote(value)}")
' "$bridge"
)"

automate() { "$cli" +automation "$@"; }

# --- checks ------------------------------------------------------------------

passed=0
check() {
    local what=$1 expected=$2 actual=$3
    if [[ $actual == *"$expected"* ]]; then
        print "  ok   $what"
        (( passed += 1 ))
    else
        print -u2 "  FAIL $what"
        print -u2 "       expected to contain: $expected"
        print -u2 "       got: $actual"
        exit 1
    fi
}

print "e2e: driving $app"

# A shell is there and answering: send a command and read the grid back. This
# is the loop every content-level check is built out of.
marker="e2e-$RANDOM"
automate sendText "printf '%s\\n' $marker
"
sleep 1.5
check "sendText reaches the shell and readScreen sees it" \
      "$marker" "$(automate readScreen)"

# The window's own state, in the shape a saved session is written in.
state=$(automate queryState)
check "queryState reports the window" '"projects"' "$state"

before=$(print -r -- "$state" | /usr/bin/python3 -c '
import json, sys
snapshot = json.load(sys.stdin)
tabs = snapshot["projects"][snapshot.get("selectedProjectIndex") or 0]["tabs"]
print(len(json.dumps(tabs).split("\"pane\"")) - 1)
')

# A palette command, run through the palette table the user would have used.
automate runCommand split-right
sleep 0.8
after=$(automate queryState | /usr/bin/python3 -c '
import json, sys
snapshot = json.load(sys.stdin)
tabs = snapshot["projects"][snapshot.get("selectedProjectIndex") or 0]["tabs"]
print(len(json.dumps(tabs).split("\"pane\"")) - 1)
')
check "runCommand split-right adds a pane" "$(( before + 1 ))" "$after"

# An action the app does not offer is refused rather than run.
if automate eval "rm -rf /" 2>/dev/null; then
    fail "an unknown automation action was accepted"
fi
print "  ok   an unknown action is refused"
(( passed += 1 ))

print "e2e: $passed checks passed"
