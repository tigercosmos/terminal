# Show agents in SSH panes

Connect with `ssh` and start your coding agent in that pane. Terminal lists
recognized foreground agents in the Agents sidebar, with their host name.
The remote host needs Python 3.8 or later and either Linux or macOS.

Without lifecycle hooks, the row says **unknown**: Terminal knows the agent
exists but cannot tell whether it is working or waiting for input.

## Enable Claude Code activity

Run this command on your Mac. Use the same SSH options and host as your pane:

```sh
terminal +agent remote-install claude -- user@host
# With an SSH port or identity file:
terminal +agent remote-install claude -- -p 2222 -i ~/.ssh/work_key user@host
```

The command prints a `claude --plugin-dir ...` command. Run that command in
your remote pane to load the lifecycle hooks. Append your usual Claude Code
arguments. The hooks report working, blocked, finished, and subagents.

## Enable Codex activity

Run this command on your Mac:

```sh
terminal +agent remote-install codex -- user@host
```

Codex must be on the remote login shell's `PATH`. The installer asks Codex
to install Terminal's plugin from a local marketplace on that host. Restart
Codex in the remote pane and approve its hooks when asked.

## Remove remote hooks

For Claude Code, stop passing `--plugin-dir` when you start it.
For Codex, run these commands on the remote host:

```sh
codex plugin remove terminal-remote-agent-state@terminal-remote-agents
codex plugin marketplace remove terminal-remote-agents
```

After stopping agents that use the hooks, remove their helper and state files:

```sh
rm -r ~/.local/share/terminal/remote-agents
```

## Connection limits

Terminal follows the foreground agent of each open SSH pane. It does not
list every background agent on the host. Clicking a row focuses its pane.
Remote sessions are not saved as local resumable conversations.

SSH probes use batch authentication and never open a password prompt.
A host that needs another password, lacks Python, or becomes unreachable
cannot provide status. A previously detected agent then shows **unknown**.
Leaving SSH removes its remote row. One failed probe preserves the last
answer; consecutive failures show unknown and retries slow down. Authentication
failures or missing Python suspend probes until you reconnect or toggle discovery.

Disable discovery in **Settings → Agents → Show agents in SSH panes**.
The matching configuration key is `agents.remote-discovery = false`.

Terminal refuses ambiguous attribution. Sessions inside tmux or screen,
multiple shells sharing one multiplexed SSH transport, and connections through
an unidentifiable proxy can therefore have no agent row. Separate SSH
connections avoid transport ambiguity; `ssh -o ControlMaster=no -o ControlPath=none host`
starts one without sharing a master.

The hooks write private state files on the remote host. Terminal reads them
over SSH; it does not forward the Mac's automation socket or credentials.
