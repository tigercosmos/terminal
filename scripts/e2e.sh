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

# Opening a session is the other half of the pane check: a tab, not a split.
tabs_before=$(automate queryState | /usr/bin/python3 -c '
import json, sys
snapshot = json.load(sys.stdin)
print(len(snapshot["projects"][snapshot.get("selectedProjectIndex") or 0]["tabs"]))
')
automate runCommand new-session
sleep 1.2
tabs_after=$(automate queryState | /usr/bin/python3 -c '
import json, sys
snapshot = json.load(sys.stdin)
print(len(snapshot["projects"][snapshot.get("selectedProjectIndex") or 0]["tabs"]))
')
check "runCommand new-session adds a tab" "$(( tabs_before + 1 ))" "$tabs_after"

# --- what the shell is told it is running under -------------------------------

# TERM_PROGRAM is a capability hint, so both backends claim the Ghostty
# protocols this app implements; TERMINAL_TERM is the surface actually driving
# the pane. A tool reading either is reading these exact values.
automate sendText 'printf "TERM_ENV term=[%s] program=[%s]\n" "$TERMINAL_TERM" "$TERM_PROGRAM"
'
sleep 1.5
env_line=$(automate readScreen | grep 'TERM_ENV term=' | tail -1)
check "the session exports TERMINAL_TERM" "term=[alacritty]" "$env_line"
check "TERM_PROGRAM advertises the Ghostty protocols" "program=[ghostty]" "$env_line"

# --- OSC sequences the host intercepts ----------------------------------------

# These check that the host-owned sequences leave the stream intact, not that
# they were intercepted. Whether the interceptor takes one is NOT observable
# here: an OSC the emulator does not implement is swallowed silently, so an
# un-intercepted 777 looks exactly like an intercepted one on the grid. That
# behaviour is pinned by the bridge's own tests (`make test-rust`), which do
# fail when the parsing is removed — verified by removing it.
#
# What is left is still worth running. A sequence mis-parsed at the PTY
# boundary eats the bytes after it, and this is where that shows up: the marker
# printed in the same write simply never arrives.
osc_leaves_the_stream_intact() {
    local what=$1 payload=$2 marker=$3
    automate sendText "printf '$payload'
"
    sleep 1.5
    # The shell echoes the command back at its prompt, and that echo contains
    # the payload as typed; drop it so only real output is examined.
    check "text written after $what still arrives" \
          "$marker" "$(automate readScreen | grep -v 'printf')"
}

osc_leaves_the_stream_intact "an OSC 777 desktop notification" \
    '\033]777;notify;NoticeTitle;NoticeBody\007OSC777MARKER\n' OSC777MARKER

osc_leaves_the_stream_intact "an OSC 22 pointer shape" \
    '\033]22;pointer\007OSC22MARKER\n' OSC22MARKER

osc_leaves_the_stream_intact "an OSC 9 notification" \
    '\033]9;NineBody\007OSC9MARKER\n' OSC9MARKER

# A sequence split across two writes exercises the interceptor's cross-chunk
# state, which a single write never reaches.
automate sendText 'printf "\033]777;notify;Split" ; printf "Title;SplitBody\007SPLITMARKER\n"
'
sleep 1.5
check "a sequence split across two writes does not eat what follows" \
      "SPLITMARKER" "$(automate readScreen | grep -v 'printf')"

# --- the Git panel ------------------------------------------------------------

# Mounting the panel starts a status snapshot: resolving the repository,
# reading the log, counting untracked lines. A hang or a crash in any of that
# shows up as the window no longer answering.
automate runCommand toggle-git
sleep 2
check "the window survives opening the Git panel" '"projects"' "$(automate queryState)"
automate runCommand toggle-git
sleep 1
check "the window survives closing it again" '"projects"' "$(automate queryState)"

# An action the app does not offer is refused rather than run.
if automate eval "rm -rf /" 2>/dev/null; then
    fail "an unknown automation action was accepted"
fi
print "  ok   an unknown action is refused"
(( passed += 1 ))

print "e2e: $passed checks passed"
