#!/usr/bin/env python3
"""SSH agent discovery, state cleanup, and opt-in lifecycle plugins (Python 3, Linux/macOS)."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path.home() / '.local/share/terminal/remote-agents'
MAX_STATE = 32768


def output(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=3).decode(errors='replace')


def age_seconds(value):
    days, _, clock = value.rpartition('-')
    parts = [int(part) for part in clock.split(':')]
    return int(days or 0) * 86400 + sum(part * 60 ** index for index, part in enumerate(reversed(parts)))


def processes():
    rows = {}
    for line in output('ps', '-U', str(os.getuid()), '-o', 'pid=,ppid=,pgid=,tpgid=,etime=,tty=,comm=').splitlines():
        fields = line.split(None, 6)
        if len(fields) != 7:
            continue
        try:
            pid, parent, group, foreground = map(int, fields[:4])
            if sys.platform.startswith('linux'):
                if os.stat('/proc/%d' % pid).st_uid != os.getuid():
                    continue
                stat = Path('/proc/%d/stat' % pid).read_text().rsplit(') ', 1)[1].split()
                start = stat[19]
                arguments = Path('/proc/%d/cmdline' % pid).read_bytes().decode(errors='replace').strip('\0').split('\0')
                executable = os.readlink('/proc/%d/exe' % pid)
            else:
                # lstart is stable across polls; etime is not a process identity.
                start = ''
                arguments = [fields[6]]
                executable = fields[6]
            rows[pid] = dict(pid=pid, parent=parent, group=group, foreground=foreground,
                             age=age_seconds(fields[4]), tty=fields[5], start=start,
                             executable=executable, arguments=arguments[:10])
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    return rows


def connection_ports(pid):
    try:
        if sys.platform.startswith('linux'):
            entries = Path('/proc/%d/environ' % pid).read_bytes().split(b'\0')
            value = next(entry.decode() for entry in entries if entry.startswith(b'SSH_CONNECTION='))
            fields = value.split('=', 1)[1].split()
            return int(fields[1]), int(fields[3])
        text = output('ps', 'eww', '-p', str(pid), '-o', 'command=')
        match = re.search(r'(?:^| )SSH_CONNECTION=\S+ (\d+) \S+ (\d+)(?: |$)', text)
        return (int(match[1]), int(match[2])) if match else None
    except (OSError, ValueError, IndexError, StopIteration, subprocess.SubprocessError):
        return None


def belongs(pid, ancestor, rows):
    visited = set()
    while pid in rows and pid not in visited:
        if pid == ancestor:
            return True
        visited.add(pid)
        pid = rows[pid]['parent']
    return False


def select_processes(rows, connections, max_age, ports_for_pid=connection_ports, excluded=None):
    excluded = excluded or set()
    matches = {pid for pid, row in rows.items()
               if pid not in excluded and row['age'] <= max_age and ports_for_pid(pid) in connections}
    roots = set()
    for pid in matches:
        # macOS shells can erase their initial environment from ps. A native
        # child's inherited connection still identifies the controlling tty;
        # climb that tty back to its login process before choosing a job.
        visited = set()
        while pid not in visited:
            visited.add(pid)
            parent = rows[pid]['parent']
            tty = rows[pid].get('tty')
            if parent not in rows or rows[parent]['age'] > max_age:
                break
            if parent not in matches and (tty in (None, '?', '??') or rows[parent].get('tty') != tty):
                break
            pid = parent
        roots.add(pid)
    # A multiplexed transport can carry multiple shells. A host-wide guess
    # would attribute one pane's agent to another, so refuse ambiguity.
    if len(roots) != 1:
        return []
    root = next(iter(roots))
    descendants = [row for pid, row in rows.items() if belongs(pid, root, rows)]
    if any(Path(row['executable']).name.startswith(('tmux', 'screen')) for row in descendants):
        return []
    foreground = rows[root]['foreground']
    return sorted((row for row in descendants if foreground > 0 and row['group'] == foreground),
                  key=lambda row: sum(belongs(row['pid'], other['pid'], rows) for other in descendants))[:32]


def details(row):
    if not sys.platform.startswith('linux'):
        row['start'] = output('ps', '-p', str(row['pid']), '-o', 'lstart=').strip()
        # ps prints flattened argv, not shell source: prompt apostrophes are data.
        row['arguments'] = output('ps', '-ww', '-p', str(row['pid']), '-o', 'command=').split()[:10]
        if not row['start'] or not row['arguments']:
            raise ValueError('process exited during inspection')
    return row


def identity(row):
    return '%d-%s' % (row['pid'], hashlib.sha256(row['start'].encode()).hexdigest()[:24])


def read_state(row):
    try:
        with (ROOT / 'state' / (identity(row) + '.json')).open('rb') as stream:
            state = json.loads(stream.read(MAX_STATE + 1))
        return state if isinstance(state, dict) and state.get('identity') == identity(row) else None
    except (OSError, ValueError):
        return None


def prune_state(rows):
    directory = ROOT / 'state'
    if not directory.is_dir():
        return
    for path in directory.glob('*.json'):
        match = re.fullmatch(r'(\d+)-[a-f0-9]{24}', path.stem)
        if not match:
            continue
        pid = int(match[1])
        try:
            if pid in rows:
                if identity(details(dict(rows[pid]))) == path.stem:
                    continue
            else:
                # A snapshot can omit a process that ps could not read. Only
                # ESRCH proves it dead; an inaccessible live process stays.
                try:
                    os.kill(pid, 0)
                    continue
                except ProcessLookupError:
                    pass
            lock_path = path.with_suffix('.lock')
            if lock_path.exists():
                with lock_path.open('r+') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    path.unlink(missing_ok=True)
                    lock_path.unlink(missing_ok=True)
            else:
                path.unlink(missing_ok=True)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    # A hook interrupted before replace can leave only its lock. The lock's
    # process identity gives it the same liveness check as a state file.
    for path in directory.glob('*.lock'):
        if path.with_suffix('.json').exists():
            continue
        match = re.fullmatch(r'(\d+)-[a-f0-9]{24}', path.stem)
        if not match:
            continue
        try:
            pid = int(match[1])
            if pid in rows and identity(details(dict(rows[pid]))) == path.stem:
                continue
            if pid not in rows:
                try:
                    os.kill(pid, 0)
                    continue
                except ProcessLookupError:
                    pass
            with path.open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                path.unlink(missing_ok=True)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue


def probe(max_age, pairs):
    rows = processes()
    prune_state(rows)
    # A probe sharing the user's master inherits the very ports being queried.
    # Its command/session ancestors are evidence of the probe, not a second pane.
    excluded = set()
    pid = os.getpid()
    while pid in rows and pid not in excluded:
        excluded.add(pid)
        pid = rows[pid]['parent']
    ports = connection_ports
    if not sys.platform.startswith('linux'):
        table = {}
        for line in output('ps', 'eww', '-U', str(os.getuid()), '-o', 'pid=,command=').splitlines():
            match = re.search(r'^\s*(\d+).*? SSH_CONNECTION=\S+ (\d+) \S+ (\d+)(?: |$)', line)
            if match:
                table[int(match[1])] = (int(match[2]), int(match[3]))
        ports = table.get
    selected = select_processes(rows, {tuple(map(int, pair.split(':'))) for pair in pairs}, max_age, ports, excluded=excluded)
    records = []
    for row in selected:
        try:
            details(row)
            records.append(dict(identity=identity(row), pid=row['pid'], parent=row['parent'], executable=row['executable'],
                                arguments=row['arguments'], state=read_state(row)))
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    print(json.dumps(dict(version=1, processes=records)))


def agent_process(kind, rows):
    pid = os.getppid()
    visited = set()
    while pid in rows and pid not in visited:
        visited.add(pid)
        try:
            row = details(rows[pid])
        except (OSError, ValueError, subprocess.SubprocessError):
            pid = rows[pid]['parent']
            continue
        values = [row['executable']] + row['arguments'][:3]
        if any(Path(value).name.rsplit('.js', 1)[0] == kind for value in values):
            return row
        pid = row['parent']
    return None


def normalized_id(value):
    return str(value)[:256] if value is not None else ''


def apply_event(state, event, fields):
    subagents = state.setdefault('subagents', [])
    agent_id = normalized_id(fields.get('agent_id'))
    if event == 'SubagentStart':
        if agent_id and fields.get('agent_type'):
            subagents[:] = [item for item in subagents if item['id'] != agent_id]
            subagents.append(dict(id=agent_id, type=str(fields['agent_type'])[:80]))
            state['phase'] = 'working'
    elif event == 'SubagentStop':
        subagents[:] = [item for item in subagents if item['id'] != agent_id]
        if not subagents and state.pop('deferred_idle', False):
            state['phase'] = 'idle'
    elif event == 'Notification':
        notification = fields.get('notification_type')
        if notification in ('permission_prompt', 'elicitation_dialog', 'elicitation_url_dialog'):
            state['phase'] = 'blocked'
        elif notification == 'idle_prompt':
            state['phase'] = 'idle'
    elif event in ('PermissionRequest', 'StopFailure'):
        state['phase'] = 'blocked'
    elif event in ('UserPromptSubmit', 'PostToolUse', 'PostToolUseFailure'):
        state['phase'] = 'working'
        state['deferred_idle'] = False
        if event == 'UserPromptSubmit':
            state['turn'] = time.time_ns()
    elif event in ('Stop', 'Interrupt'):
        if event == 'Interrupt':
            subagents.clear()
        tasks = fields.get('background_tasks')
        awaited = False
        if isinstance(tasks, list):
            active = [task for task in tasks if isinstance(task, dict)]
            ids = {normalized_id(task.get('id')) for task in active if task.get('type') in ('subagent', 'teammate')
                   and task.get('id') is not None}
            subagents[:] = [item for item in subagents if item['id'] in ids]
            awaited = any(task.get('type') in ('subagent', 'teammate', 'workflow') for task in active)
        state['deferred_idle'] = bool(subagents)
        state['phase'] = 'working' if subagents or awaited else 'idle'
    state['subagents'] = subagents[:64]
    if state.get('phase') in ('working', 'blocked'):
        state.setdefault('turn', time.time_ns())
    return state


def hook(kind, event):
    fields = json.loads(sys.stdin.buffer.read(4 * 1024 * 1024))
    if not isinstance(fields, dict):
        return
    row = agent_process(kind, processes())
    if row is None:
        return
    directory = ROOT / 'state'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = identity(row)
    # Multiple hooks can finish at once. Lock the read/modify/replace, and
    # bind each file to a process start time so PID reuse cannot revive it.
    with (directory / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(row) or dict(identity=key, phase='idle')
        state = apply_event(state, event, fields)
        state['revision'] = time.time_ns()
        descriptor, name = tempfile.mkstemp(dir=directory)
        try:
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(state, stream)
            os.replace(name, directory / (key + '.json'))
        finally:
            if os.path.exists(name):
                os.unlink(name)


def run_codex(arguments):
    result = subprocess.run(['codex'] + arguments, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or
                           'codex plugin command failed (exit %d)' % result.returncode)


def install(kind):
    # Only Terminal's own plugin folders are written. Provider settings stay
    # with the provider; Codex installs and approves its plugin itself.
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    helper = ROOT / 'terminal_remote_agent.py'
    helper.write_text(Path(__file__).read_text())
    helper.chmod(0o700)
    plugin = ROOT / kind
    manifest_dir = plugin / ('.claude-plugin' if kind == 'claude' else '.codex-plugin')
    manifest_dir.mkdir(parents=True, exist_ok=True)
    events = ['UserPromptSubmit', 'PostToolUse', 'PermissionRequest', 'Stop', 'SubagentStart', 'SubagentStop']
    events += ['PostToolUseFailure', 'Notification', 'StopFailure'] if kind == 'claude' else ['Interrupt']
    hooks = {event: [dict(hooks=[dict(type='command', timeout=5,
              command=shlex.join([sys.executable, str(helper), 'hook', kind, event]))])] for event in events}
    manifest = dict(name='terminal-remote-agent-state', version='1.0.0',
                    description='Reports remote agent activity to Terminal over SSH.')
    if kind == 'claude':
        manifest['hooks'] = hooks
    else:
        hook_dir = plugin / 'hooks'
        hook_dir.mkdir(exist_ok=True)
        (hook_dir / 'hooks.json').write_text(json.dumps(dict(hooks=hooks), indent=2))
        manifest['hooks'] = './hooks/hooks.json'
    (manifest_dir / 'plugin.json').write_text(json.dumps(manifest, indent=2))
    if kind == 'claude':
        print(shlex.join(['claude', '--plugin-dir', str(plugin)]))
    else:
        market = ROOT / '.agents/plugins'
        market.mkdir(parents=True, exist_ok=True)
        (market / 'marketplace.json').write_text(json.dumps(dict(name='terminal-remote-agents', plugins=[dict(
            name=manifest['name'], source=dict(source='local', path='./codex'), description=manifest['description'])])))
        provider_home = Path(os.environ.get('CODEX_HOME') or str(Path.home() / '.codex')).expanduser()
        config = provider_home / 'config.toml'
        configured = config.read_text() if config.exists() else ''
        if re.search(r'^\s*\[marketplaces\.(?:terminal-remote-agents|"terminal-remote-agents")\]\s*$', configured, re.MULTILINE):
            run_codex(['plugin', 'marketplace', 'remove', 'terminal-remote-agents'])
        run_codex(['plugin', 'marketplace', 'add', str(ROOT)])
        run_codex(['plugin', 'add', 'terminal-remote-agent-state@terminal-remote-agents'])
        print('codex')


def main():
    command = sys.argv[1]
    if command == 'probe':
        probe(int(sys.argv[2]), sys.argv[3:])
    elif command == 'hook' and sys.argv[2] in ('claude', 'codex'):
        # Hooks must never print into the agent's context or block its turn.
        try:
            hook(sys.argv[2], sys.argv[3])
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            pass
    elif command == 'install' and sys.argv[2] in ('claude', 'codex'):
        try:
            install(sys.argv[2])
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            raise SystemExit(str(error))
    else:
        raise SystemExit('Usage: terminal_remote_agent.py install claude|codex')


if __name__ == '__main__':
    main()
