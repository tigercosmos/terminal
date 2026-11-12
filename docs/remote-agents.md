# Show agents in SSH panes

Connect with `ssh` and start your coding agent in that pane. Terminal lists
recognized foreground agents in the Agents sidebar, with their host name.
The remote host needs Python 3.8 or later and either Linux or macOS.

Terminal automatically installs lifecycle hooks when it detects Claude Code
or Codex. You do not need an installation command or a special launch flag.
Claude Code loads the plugin from its skills directory. Codex installs it
through its own plugin CLI. Terminal leaves the provider's other settings alone.

## Activate hooks in an existing session

An agent already open when setup finishes can need a restart. The sidebar
shows **setting up**, **restart agent**, or **waiting for hooks** until
lifecycle events arrive. Codex can ask you to approve the hooks at startup.
Terminal does not approve them or restart an active agent for you.

Once the hooks load, their events report working, blocked, finished, and
subagents. Other supported agents still show **unknown** activity when no
lifecycle integration is available.

## Retry setup manually

Terminal shares installation work across panes using the same remote profile.
It records successful setup and backs off for five minutes after a failure.
Subsequent probes do not repeatedly install the same hooks. A helper update
keeps matching Codex hooks in its cache, preserving their approval.

For an immediate retry, run this in a local pane on the Mac running Terminal:

```sh
terminal +agent remote-install codex -- user@host
terminal +agent remote-install claude -- user@host
```

Use the same SSH options as your remote pane. For example:

```sh
terminal +agent remote-install codex -- -p 2222 -i ~/.ssh/work_key user@host
```

## Disable setup or remove hooks

Disable **Settings → Agents → Show agents in SSH panes** to stop discovery
and further automatic installation. The matching configuration key is
`agents.remote-discovery = false`. Disabling discovery leaves installed
plugins in place.

With discovery disabled, remove Claude Code's managed link on the remote host:

```sh
rm ~/.claude/skills/terminal-remote-agent-state
```

Use the profile's directory if you set `CLAUDE_CONFIG_DIR`.
For Codex, run these commands on the remote host:

```sh
codex plugin remove terminal-remote-agent-state@terminal-remote-agents
codex plugin marketplace remove terminal-remote-agents
```

After stopping agents that use the hooks, remove the helper and state files:

```sh
rm -r ~/.local/share/terminal/remote-agents
```

## Connection limits

Terminal follows the foreground agent of each open SSH pane. It does not
list every background agent on the host. Clicking a row focuses its pane.
Remote sessions are not saved as local resumable conversations.

SSH probes use batch authentication and never open a password prompt.
A host that needs another password, lacks Python, or becomes unreachable
cannot provide status. One failed probe preserves the last answer;
consecutive failures show unknown and retries slow down. Authentication
failures or missing Python suspend probes until you reconnect or toggle discovery.

Sessions inside tmux or screen, multiple interactive terminals sharing one
multiplexed SSH transport, and unidentifiable proxies can have no agent row.
Separate SSH connections avoid transport ambiguity:

```sh
ssh -o ControlMaster=no -o ControlPath=none host
```

The hooks write private state files on the remote host. Terminal reads them
over SSH; it does not forward the Mac's automation socket or credentials.
