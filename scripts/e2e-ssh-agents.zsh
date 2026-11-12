# Sourced by e2e.sh after its local agent checks. A private loopback sshd and
# temporary HOME exercise the real SSH transport without changing user keys,
# known hosts, provider settings, or any remote account.
remote_agent_checks() {
    setopt localtraps
    local scratch=$(mktemp -d)
    local daemon=""
    local port=$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    ssh-keygen -q -t ed25519 -N '' -f "$scratch/key"
    mkdir -p "$scratch/home"
    cat > "$scratch/force" <<FORCE
#!/bin/sh
export HOME='$scratch/home'
if [ -f '$scratch/offline' ]; then
    case "\$SSH_ORIGINAL_COMMAND" in *probe*) exit 1;; esac
fi
if [ -n "\$SSH_ORIGINAL_COMMAND" ]; then
    exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"
fi
exec /bin/zsh -f
FORCE
    chmod +x "$scratch/force"
    cat > "$scratch/sshd_config" <<CONFIG
ListenAddress 127.0.0.1
Port $port
HostKey $scratch/key
AuthorizedKeysFile $scratch/key.pub
PidFile $scratch/pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
ForceCommand $scratch/force
LogLevel ERROR
CONFIG
    /usr/sbin/sshd -D -e -f "$scratch/sshd_config" > "$scratch/sshd.log" 2>&1 &
    daemon=$!
    trap "pkill -P $daemon 2>/dev/null; kill $daemon 2>/dev/null; rm -rf ${(q)scratch}" EXIT
    local -a options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
        -o "UserKnownHostsFile=$scratch/known_hosts" -o ControlMaster=no -o ControlPath=none
        -i "$scratch/key" -p "$port")
    local connected=false
    for _ in {1..25}; do
        if ssh "${options[@]}" 127.0.0.1 true 2>/dev/null; then
            connected=true
            break
        fi
        sleep 0.2
    done
    if [[ $connected != true ]]; then
        print "  skip private SSH server unavailable: $(cat "$scratch/sshd.log")"
        return 0
    fi
    [[ ! -e "$scratch/home/.local/share/terminal/remote-agents/terminal_remote_agent.py" ]] \
        || fail "remote helper already exists before agent discovery"
    mkfifo "$scratch/events"
    cat > "$scratch/claude" <<'AGENT'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
fifo = os.open(sys.argv[1], os.O_RDWR)
with os.fdopen(fifo) as stream:
    for line in stream:
        event, _, payload = line.strip().partition(' ')
        if event == 'Exit':
            break
        subprocess.run([sys.executable, str(pathlib.Path.home() / '.local/share/terminal/remote-agents/terminal_remote_agent.py'),
                        'hook', 'claude', event], input=payload.encode(), check=True)
        with open(sys.argv[1] + '.done', 'a') as done:
            done.write(event + '\n')
AGENT
    chmod +x "$scratch/claude"
    # A separate pane keeps completion unseen while the control shell checks it.
    local remote_pane=$(in_shell remote-pane.json terminal +pane split --right | json_field pane_id)
    # The probe must share this explicit master without mistaking its own
    # remote channel for a second interactive pane.
    local -a argv=(ssh "${options[@]}" -M -S "$scratch/master" -tt 127.0.0.1 "$scratch/claude" "$scratch/events")
    local command="${(j: :)${(@q)argv}}"
    in_shell remote-run.json terminal +pane run --pane "$remote_pane" -- "$command" >/dev/null
    remote_field() {
        in_shell remote-get.json terminal +pane get --pane "$remote_pane" | /usr/bin/python3 -c '
import json,sys
agent=json.load(sys.stdin).get("agent") or {}
print(json.dumps(agent.get(sys.argv[1])))
' "$1"
    }
    wait_remote() {
        local field=$1 expected=$2 value
        for _ in {1..35}; do
            value=$(remote_field "$field")
            [[ $value == *"$expected"* ]] && return
            sleep 0.3
        done
        fail "remote $field expected $expected, got $value"
    }
    remote_hook() {
        local event=$1 payload=${2:-'{}'}
        print -r -- "$event $payload" 1<> "$scratch/events"
    }
    wait_remote remote_host 127.0.0.1
    check "SSH presence shows its host and unknown activity" 'unknown' "$(remote_field state)"
    wait_remote integration_status ready
    check "remote hooks install automatically on agent discovery" 'true' "$([[ -f "$scratch/home/.local/share/terminal/remote-agents/terminal_remote_agent.py" && -L "$scratch/home/.claude/skills/terminal-remote-agent-state" ]] && print true)"
    rm "$scratch/home/.claude/skills/terminal-remote-agent-state"
    for _ in {1..50}; do
        [[ -L "$scratch/home/.claude/skills/terminal-remote-agent-state" ]] && break
        sleep 0.3
    done
    check "remote setup repairs a removed provider registration" 'true' "$([[ -L "$scratch/home/.claude/skills/terminal-remote-agent-state" ]] && print true)"
    wait_remote integration_status ready
    automate remoteAgentDiscovery 0
    wait_remote state null
    check "remote discovery can be disabled while SSH stays open" 'null' "$(remote_field state)"
    automate remoteAgentDiscovery 1
    wait_remote remote_host 127.0.0.1
    remote_hook UserPromptSubmit
    wait_remote state working
    remote_hook SubagentStart '{"agent_id":"remote-1","agent_type":"worker"}'
    wait_remote subagents worker
    remote_hook PermissionRequest
    wait_remote state blocked
    remote_hook Stop
    wait_remote state working
    remote_hook SubagentStop '{"agent_id":"remote-1"}'
    wait_remote state done
    check "a remote completion stays unseen across polls" 'done' "$(remote_field state)"
    # Render the actual sidebar while its remote agent and host are visible.
    automate snapshotWindow "$work/remote-agents.png" >/dev/null
    check "remote sidebar snapshot is rendered" 'PNG image' "$(file "$work/remote-agents.png")"
    touch "$scratch/offline"
    wait_remote state unknown
    rm "$scratch/offline"
    wait_remote state done
    check "remote polling recovers after an unavailable host" 'done' "$(remote_field state)"
    automate focusNextAgentAttention
    sleep 1
    automate runCommand focus-pane-left
    wait_remote state idle
    check "focusing a remote agent acknowledges completion" 'idle' "$(remote_field state)"
    remote_hook Exit
    for _ in {1..35}; do
        [[ $(remote_field state) == *null* ]] && break
        sleep 0.3
    done
    check "leaving SSH removes the remote agent" 'null' "$(remote_field state)"
    print "  ok   remote SSH lifecycle, subagents, completion and exit"
}
remote_agent_checks
