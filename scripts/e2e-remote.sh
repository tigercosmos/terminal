#!/bin/zsh
# Run the e2e suite on another Mac against a Debug build made here.
#
# The suite needs a GUI session and a console user, which the machine that
# builds does not always have: a laptop with only the Command Line Tools and no
# Xcode can still host the app under test. So the build stays local, the bundle
# and the driver travel over rsync, and scripts/e2e.sh runs on the other side
# through ssh with the same per-backend loop as `make e2e`.
#
#   make e2e-remote E2E_HOST=air
#   scripts/e2e-remote.sh air "/path/to/Terminal Debug.app" alacritty libghostty
#
# The remote user must be logged in at the console: `open` from an ssh session
# only reaches that session's window server. The bundle lands under
# ~/Library/Caches/terminal-e2e on the remote, keeping its "Terminal Debug.app"
# name because the driver's pkill pattern and the app's own config lookup both
# depend on it.

set -u
setopt err_return

host=${1:?usage: e2e-remote.sh HOST "/path/to/Terminal Debug.app" [backend...]}
app=${2:?usage: e2e-remote.sh HOST "/path/to/Terminal Debug.app" [backend...]}
shift 2
backends=("$@")
(( ${#backends} )) || backends=(alacritty libghostty)

fail() { print -u2 "e2e-remote: $*"; exit 1; }

[[ -x "$app/Contents/MacOS/terminal" ]] || fail "no terminal CLI inside $app"
name=${app:t}
remote_dir='Library/Caches/terminal-e2e'

print "Syncing $name -> $host:~/$remote_dir/"
ssh "$host" "mkdir -p ~/$remote_dir"
# `--delete` keeps a stale framework or resource from an earlier build out of
# the bundle under test; the trailing slash on the source keeps the name. The
# remote side parses its path with a shell, so the space in the bundle name is
# escaped rather than quoted; macOS's rsync has no --protect-args.
rsync -a --delete "$app/" "$host:~/$remote_dir/${name// /\\ }/"
rsync -a "${0:h}/e2e.sh" "$host:~/$remote_dir/e2e.sh"

# A login shell on the remote, so `open` and the CLI see the user's
# environment rather than ssh's minimal one; the driver reads $TMPDIR, which
# only a session-aware shell sets to the per-user confstr path.
for backend in "${backends[@]}"; do
    print "== $backend on $host"
    ssh "$host" "zsh -lc 'cd ~/$remote_dir && ./e2e.sh \"\$PWD/$name\" $backend'" \
        || fail "$backend failed on $host"
done
