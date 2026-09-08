#!/bin/zsh
# End-to-end checks against a running Terminal, with no pixels read and no
# input synthesized from outside the app.
#
# The app injects its own input and reports its own state over the CLI channel
# it already has, so neither Screen Recording nor Accessibility is ever asked
# for — which matters because debug builds are unsigned and lose a TCC grant on
# every rebuild.
#
#   make e2e                      every backend, in turn
#   make e2e E2E_BACKENDS=alacritty
#
# Runs the checks against one backend; `make e2e` invokes it once per backend,
# because Terminal's two surfaces are separate implementations of one protocol
# and a divergence between them is invisible to a run that only drives the
# default. `sendText` meant "paste" on one and "type" on the other for as long
# as this script tested Alacritty alone, which is how **cd Here** came to do
# nothing on Ghostty.
#
# Launches a debug build with TERMINAL_AUTOMATION=1, drives it, and leaves it
# running. Requires a GUI session; this cannot run on a headless runner.

set -u
setopt err_return
# The state directory appears a moment after launch; a glob that matches
# nothing yet is expected, not an error.
setopt null_glob

app=${1:?usage: e2e.sh /path/to/Terminal Debug.app [backend]}
backend=${2:-alacritty}

fail() { print -u2 "e2e: $*"; exit 1; }

cli="$app/Contents/MacOS/terminal"
[[ -x $cli ]] || fail "no terminal CLI inside $app"

# --- the backend under test --------------------------------------------------

# Debug builds read this file; see `AppSettings.configURL`. The developer's own
# copy is put back on the way out, including when a check fails and exits.
config="$HOME/.config/terminal-dev/config.toml"
config_backup=$(mktemp)
had_config=false
if [[ -f $config ]]; then
    cp "$config" "$config_backup"
    had_config=true
fi
restore_config() {
    if [[ $had_config == true ]]; then
        cp "$config_backup" "$config"
    else
        rm -f "$config"
    fi
    rm -f "$config_backup"
}
trap restore_config EXIT INT TERM

mkdir -p "${config:h}"
if [[ $had_config == true ]]; then
    grep -v '^terminal.backend' "$config_backup" > "$config" || true
else
    : > "$config"
fi
print "terminal.backend = \"$backend\"" >> "$config"

# --- launch, armed -----------------------------------------------------------

# An app that is already up has read its config, and `open` would only activate
# it — so without this the backend under test would silently be whichever one
# launched first.
pkill -f 'Terminal Debug.app/Contents/MacOS/terminal' 2>/dev/null || true
sleep 2
rm -rf "${TMPDIR%/}"/terminal-cli-* 2>/dev/null || true

# The bridge in this shell's environment, if any, belongs to whichever build
# opened it; dropping it makes `open` start the app rather than talk to one.
env -u TERMINAL_CLI_STATE -u TERMINAL_CLI_TOKEN -u TERMINAL_CLI_BUNDLE \
    open -a "$app" --env TERMINAL_AUTOMATION=1

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

# The first shell has to reach its prompt before anything is typed at it.
sleep 3

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

print "e2e: driving $app on the $backend backend"

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
sleep 2
# The prompt echoes the command, and that echo contains the format string —
# which matches this grep, and wraps across two rows in a narrow pane. Drop the
# echoed line so only the expanded values are read.
env_line=$(automate readScreen | grep -v 'printf' | grep 'TERM_ENV term=' | tail -1)
# `TerminalBackend.environmentName`: the libghostty surface calls itself
# ghostty, which is also what both backends report for TERM_PROGRAM below.
[[ $backend == libghostty ]] && term_name=ghostty || term_name=$backend
check "the session exports TERMINAL_TERM" "term=[$term_name]" "$env_line"
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

# --- the FPS badge ------------------------------------------------------------

# Showing the badge starts a display link on the main run loop. The badge's own
# reading is a rendering detail this channel cannot see; what it can see is that
# the counter runs and stops without taking the window's main thread with it.
automate runCommand toggle-fps-counter
sleep 2
check "the window survives showing the FPS counter" '"projects"' "$(automate queryState)"
automate runCommand toggle-fps-counter
sleep 1
check "the window survives hiding it again" '"projects"' "$(automate queryState)"

# An action the app does not offer is refused rather than run.
if automate eval "rm -rf /" 2>/dev/null; then
    fail "an unknown automation action was accepted"
fi
print "  ok   an unknown action is refused"
(( passed += 1 ))

print "e2e: $passed checks passed on the $backend backend"
