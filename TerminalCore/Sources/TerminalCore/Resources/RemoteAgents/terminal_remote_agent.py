#!/usr/bin/env python3
"""SSH agent discovery, state cleanup, and opt-in lifecycle plugins (Python 3, Linux/macOS)."""
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(os.environ.get('TERMINAL_REMOTE_AGENT_ROOT') or str(Path.home() / '.local/share/terminal/remote-agents'))
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
    terminals = {rows[pid].get('tty') for pid in matches
                 if rows[pid].get('tty') not in (None, '?', '??')}
    # Process ancestry is not terminal ownership: zsh prompt helpers can
    # detach and become another root while retaining this session's tty and
    # SSH_CONNECTION. The controlling tty and its foreground group are kernel
    # evidence that survives that detachment. Distinct ttys on one transport
    # still mean multiple interactive channels, which cannot be guessed here.
    if len(terminals) != 1:
        return []
    terminal = next(iter(terminals))
    foregrounds = {rows[pid]['foreground'] for pid in matches if rows[pid].get('tty') == terminal}
    if len(foregrounds) != 1:
        return []
    foreground = next(iter(foregrounds))
    if foreground <= 0:
        return []
    members = [row for pid, row in rows.items()
               if pid not in excluded and row.get('tty') == terminal and row['age'] <= max_age]
    if any(Path(row['executable']).name.lower().startswith(('tmux', 'screen')) for row in members):
        return []
    return sorted((row for row in members if row['group'] == foreground),
                  key=lambda row: sum(belongs(row['pid'], other['pid'], rows) for other in members))[:32]


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


def probe(max_age, pairs, auto_install=False):
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
            try:
                integration = automatic_integration(row) if auto_install else None
            except (OSError, ValueError):
                integration = dict(status='failed', restart=False)
            records.append(dict(identity=identity(row), pid=row['pid'], parent=row['parent'], executable=row['executable'],
                                arguments=row['arguments'], state=read_state(row),
                                integration=integration))
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


def run_codex(arguments, executable='codex'):
    process = subprocess.Popen([executable] + arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.stdout.close()
            process.stderr.close()
        raise RuntimeError('codex plugin command timed out')
    if process.returncode:
        raise RuntimeError(stderr.decode(errors='replace').strip() or stdout.decode(errors='replace').strip() or
                           'codex plugin command failed (exit %d)' % process.returncode)


def source_text():
    # stdin probes carry their source explicitly, so a detached installer can
    # persist an inspectable helper without reopening the exhausted SSH pipe.
    return globals().get('_terminal_source') or Path(__file__).read_text()


def write_atomic(path, data, mode=0o600):
    # Preserve user-created links while replacing the resolved managed file.
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def process_environment(pid):
    try:
        if sys.platform.startswith('linux'):
            data = Path('/proc/%d/environ' % pid).read_bytes()
        else:
            libc = ctypes.CDLL(None, use_errno=True)
            mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2.
            size = ctypes.c_size_t()
            if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) or size.value < 4:
                return {}
            buffer = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
                return {}
            blob = buffer.raw[:size.value]
            count = int.from_bytes(blob[:4], sys.byteorder, signed=True)
            if count <= 0:
                return {}
            offset = blob.index(b'\0', 4)
            while offset < len(blob) and blob[offset] == 0:
                offset += 1
            for _ in range(count):
                offset = blob.index(b'\0', offset) + 1
            data = blob[offset:]
        return {entry.split(b'=', 1)[0].decode(): entry.split(b'=', 1)[1].decode()
                for entry in data.split(b'\0') if b'=' in entry}
    except (OSError, ValueError, UnicodeError):
        return {}


def integration_kind(row):
    for value in [row['executable']] + row['arguments'][:3]:
        name = Path(value).name
        if name in ('claude', 'claude.js'):
            return 'claude'
        if name in ('codex', 'codex.js'):
            return 'codex'
    return None


def installation_paths(kind, config_root):
    key = kind + '-' + hashlib.sha256(str(config_root.resolve()).encode()).hexdigest()[:16]
    directory = ROOT / 'installations'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    return directory / (key + '.json'), directory / (key + '.lock')


def read_receipt(path):
    try:
        with path.open('rb') as stream:
            data = json.loads(stream.read(MAX_STATE + 1))
        if not isinstance(data, dict):
            return {}
        for field in ('installed_at', 'retry_at'):
            value = data.get(field, 0)
            if type(value) not in (int, float) or not math.isfinite(value):
                return {}
        return data
    except (OSError, ValueError, OverflowError):
        return {}


def codex_registration_current(provider_home):
    config = provider_home / 'config.toml'
    configured = config.read_text() if config.is_file() else ''
    header = re.search(r'''(?m)^[ \t]*\[plugins\.(?:"terminal-remote-agent-state@terminal-remote-agents"|'terminal-remote-agent-state@terminal-remote-agents')\][ \t]*(?:\#[^\n]*)?$''', configured)
    if not header:
        return False
    section = re.split(r'(?m)^[ \t]*\[', configured[header.end():], maxsplit=1)[0]
    # A provider-level disable is intentional, even if its cache was removed.
    # Re-adding the plugin to repair that cache would silently enable it again.
    if re.search(r'(?m)^[ \t]*enabled[ \t]*=[ \t]*false[ \t]*(?:\#[^\n]*)?$', section):
        return True
    cached = provider_home / 'plugins/cache/terminal-remote-agents/terminal-remote-agent-state/1.0.0'
    return all((cached / relative).is_file()
               and (cached / relative).read_bytes() == (ROOT / 'codex' / relative).read_bytes()
               for relative in ('.codex-plugin/plugin.json', 'hooks/hooks.json'))


def installation_present(kind, config_root, source):
    # A receipt survives a profile reset or provider cache cleanup. Verify
    # the managed files before using it, without running a CLI on every poll.
    try:
        if (ROOT / 'terminal_remote_agent.py').read_text() != source:
            return False
        manifest = ROOT / kind / ('.claude-plugin' if kind == 'claude' else '.codex-plugin') / 'plugin.json'
        if not manifest.is_file():
            return False
        if kind == 'claude':
            link = config_root / 'skills/terminal-remote-agent-state'
            return link.is_symlink() and link.resolve() == (ROOT / kind).resolve()
        return codex_registration_current(config_root)
    except (OSError, ValueError):
        return False


def automatic_integration(row):
    kind = integration_kind(row)
    if kind is None:
        return None
    environment = process_environment(row['pid'])
    home = Path(environment.get('HOME') or str(Path.home()))
    variable = 'CODEX_HOME' if kind == 'codex' else 'CLAUDE_CONFIG_DIR'
    configured = environment.get(variable)
    if configured == '~':
        config_root = home
    elif configured and configured.startswith('~/'):
        config_root = home / configured[2:]
    else:
        config_root = Path(configured or str(home / ('.codex' if kind == 'codex' else '.claude'))).expanduser()
    if not config_root.is_absolute():
        return dict(status='failed', restart=False)
    receipt, lock_path = installation_paths(kind, config_root)
    lock = lock_path.open('a')
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(status='installing', restart=False)
        source = source_text()
        digest = hashlib.sha256(source.encode()).hexdigest()
        previous = read_receipt(receipt)
        if previous.get('digest') == digest:
            if previous.get('status') == 'ready' and installation_present(kind, config_root, source):
                restart = time.time() - row['age'] < previous.get('installed_at', 0) - 2
                return dict(status='ready', restart=restart)
            if time.time() < previous.get('retry_at', 0):
                return dict(status='failed', restart=False)
        # fork keeps the lock alive in the child; closing the parent's copy
        # must not explicitly unlock that shared open-file description.
        child = os.fork()
        if child:
            return dict(status='installing', restart=False)
        try:
            os.setsid()
            null = os.open(os.devnull, os.O_RDWR)
            for descriptor in (0, 1, 2):
                os.dup2(null, descriptor)
            if null > 2:
                os.close(null)
            os.environ['HOME'] = str(home)
            os.environ[variable] = str(config_root)
            os.environ['PATH'] = environment.get('PATH') or os.environ.get('PATH', '')
            executable = row['executable'] if Path(row['executable']).name == kind else shutil.which(kind)
            result = dict(digest=digest, status='ready', installed_at=time.time())
            try:
                changed = install(kind, source=source, executable=executable or kind, quiet=True)
                result['installed_at'] = time.time() if changed else previous.get('installed_at', 0)
            except Exception as error:
                result = dict(digest=digest, status='failed', retry_at=time.time() + 300,
                              error=str(error)[:500])
            write_atomic(receipt, json.dumps(result).encode())
        finally:
            os._exit(0)
    finally:
        lock.close()



def install(kind, source=None, executable='codex', quiet=False):
    # Only Terminal's own plugin folders are written. Provider settings stay
    # with the provider; Codex installs and approves its plugin itself.
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    helper = ROOT / 'terminal_remote_agent.py'
    write_atomic(helper, (source or source_text()).encode(), mode=0o700)
    plugin = ROOT / kind
    manifest_dir = plugin / ('.claude-plugin' if kind == 'claude' else '.codex-plugin')
    manifest_dir.mkdir(parents=True, exist_ok=True)
    events = ['UserPromptSubmit', 'PostToolUse', 'PermissionRequest', 'Stop', 'SubagentStart', 'SubagentStop']
    events += ['PostToolUseFailure', 'Notification', 'StopFailure'] if kind == 'claude' else ['Interrupt']
    hooks = {event: [dict(hooks=[dict(type='command', timeout=5,
              command=shlex.join(['env', 'TERMINAL_REMOTE_AGENT_ROOT=' + str(ROOT), sys.executable, str(helper), 'hook', kind, event]))])] for event in events}
    manifest = dict(name='terminal-remote-agent-state', version='1.0.0',
                    description='Reports remote agent activity to Terminal over SSH.')
    if kind == 'claude':
        manifest['hooks'] = hooks
    else:
        hook_dir = plugin / 'hooks'
        hook_dir.mkdir(exist_ok=True)
        (hook_dir / 'hooks.json').write_text(json.dumps(dict(hooks=hooks), indent=2))
        manifest['hooks'] = './hooks/hooks.json'
    manifest_path = manifest_dir / 'plugin.json'
    manifest_data = json.dumps(manifest, indent=2).encode()
    changed = not manifest_path.exists() or manifest_path.read_bytes() != manifest_data
    write_atomic(manifest_path, manifest_data)
    if kind == 'claude':
        config_root = Path(os.environ.get('CLAUDE_CONFIG_DIR') or str(Path.home() / '.claude')).expanduser()
        link = config_root / 'skills/terminal-remote-agent-state'
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            if link.resolve() != plugin.resolve():
                raise RuntimeError('Remote Claude plugin path is occupied')
        elif link.exists():
            raise RuntimeError('Remote Claude plugin path is occupied')
        else:
            link.symlink_to(plugin, target_is_directory=True)
            changed = True
        if not quiet:
            print('claude')
    else:
        market = ROOT / '.agents/plugins'
        market.mkdir(parents=True, exist_ok=True)
        (market / 'marketplace.json').write_text(json.dumps(dict(name='terminal-remote-agents', plugins=[dict(
            name=manifest['name'], source=dict(source='local', path='./codex'), description=manifest['description'])])))
        provider_home = Path(os.environ.get('CODEX_HOME') or str(Path.home() / '.codex')).expanduser()
        # Codex resolves CODEX_HOME before its plugin command can recreate it.
        provider_home.mkdir(parents=True, exist_ok=True, mode=0o700)
        config = provider_home / 'config.toml'
        configured = config.read_text() if config.exists() else ''
        current = codex_registration_current(provider_home)
        changed = not current
        if not current:
            if re.search(r'^\s*\[marketplaces\.(?:terminal-remote-agents|"terminal-remote-agents")\]\s*$', configured, re.MULTILINE):
                run_codex(['plugin', 'marketplace', 'remove', 'terminal-remote-agents'], executable)
            run_codex(['plugin', 'marketplace', 'add', str(ROOT)], executable)
            run_codex(['plugin', 'add', 'terminal-remote-agent-state@terminal-remote-agents'], executable)
        if not quiet:
            print('codex')
    return changed


def manual_install(kind):
    variable = 'CODEX_HOME' if kind == 'codex' else 'CLAUDE_CONFIG_DIR'
    config_root = Path(os.environ.get(variable) or str(Path.home() / ('.codex' if kind == 'codex' else '.claude'))).expanduser()
    receipt, lock_path = installation_paths(kind, config_root)
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Remote hook setup is already running')
        changed = install(kind)
        previous = read_receipt(receipt)
        result = dict(digest=hashlib.sha256(source_text().encode()).hexdigest(), status='ready',
                      installed_at=time.time() if changed else previous.get('installed_at', 0))
        write_atomic(receipt, json.dumps(result).encode())


def main():
    command = sys.argv[1]
    if command == 'probe':
        probe(int(sys.argv[2]), sys.argv[3:], auto_install=True)
    elif command == 'hook' and sys.argv[2] in ('claude', 'codex'):
        # Hooks must never print into the agent's context or block its turn.
        try:
            hook(sys.argv[2], sys.argv[3])
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            pass
    elif command == 'install' and sys.argv[2] in ('claude', 'codex'):
        try:
            manual_install(sys.argv[2])
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            raise SystemExit(str(error))
    else:
        raise SystemExit('Usage: terminal_remote_agent.py install claude|codex')


if __name__ == '__main__':
    main()
