#!/usr/bin/env python3
"""Remote discovery and hook regressions; no remote account or provider CLI needed."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import io

HELPER = Path(__file__).resolve().parents[1] / 'TerminalCore/Sources/TerminalCore/Resources/RemoteAgents/terminal_remote_agent.py'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('remote_agent', HELPER)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def row(pid, parent, group=20, foreground=20, age=10, executable='/usr/bin/claude'):
    return dict(pid=pid, parent=parent, group=group, foreground=foreground,
                age=age, tty='pts/1', executable=executable, start=str(pid), arguments=['claude'])


class RemoteAgentsTests(unittest.TestCase):
    def wait_for_install(self, process):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = agent.automatic_integration(process)
            if state['status'] != 'installing':
                return state
            time.sleep(0.05)
        self.fail('automatic installer did not finish')

    def test_claude_installs_automatically_into_the_detected_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / 'profile with spaces'
            profile.mkdir()
            settings = profile / 'settings.json'
            settings.write_text('{"user_setting": true}')
            environment = dict(HOME=directory, CLAUDE_CONFIG_DIR=str(profile), PATH=os.environ['PATH'])
            process = row(20, 1, age=100)
            with mock.patch.object(agent, 'ROOT', root / 'managed'), mock.patch.object(agent, 'process_environment', return_value=environment):
                status = self.wait_for_install(process)
                self.assertEqual(status, dict(status='ready', restart=True))
                link = profile / 'skills/terminal-remote-agent-state'
                self.assertTrue(link.is_symlink())
                self.assertTrue((link / '.claude-plugin/plugin.json').is_file())
                self.assertEqual(settings.read_text(), '{"user_setting": true}')
                manifest = (link / '.claude-plugin/plugin.json').read_bytes()
                self.assertEqual(agent.automatic_integration(process), status)
                self.assertEqual((link / '.claude-plugin/plugin.json').read_bytes(), manifest)
                self.assertFalse(agent.automatic_integration(dict(process, age=0))['restart'])
                receipt = next((root / 'managed/installations').glob('*.json'))
                installed_at = json.loads(receipt.read_text())['installed_at']
                upgraded = agent.source_text() + '\n# A helper-only update.\n'
                with mock.patch.object(agent, 'source_text', return_value=upgraded):
                    self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertEqual(json.loads(receipt.read_text())['installed_at'], installed_at)
                alias = root / 'profile-alias'
                alias.symlink_to(profile, target_is_directory=True)
                with mock.patch.object(agent, 'process_environment', return_value=dict(environment, CLAUDE_CONFIG_DIR=str(alias))):
                    self.assertIn(agent.automatic_integration(process)['status'], ['installing', 'ready'])
                    # Restore the original source digest after the upgrade test.
                    self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertEqual(len(list((root / 'managed/installations').glob('*.json'))), 1)

    def test_automatic_codex_setup_coalesces_calls_and_caches_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'codex'
            calls = root / 'calls'
            binary.write_text('#!/bin/sh\nprintf "call\\n" >> "$HOME/calls"\nsleep 0.1\nexit 1\n')
            binary.chmod(0o700)
            process = row(20, 1, executable=str(binary))
            environment = dict(HOME=directory, CODEX_HOME=str(root / '.codex'), PATH=os.environ['PATH'])
            with mock.patch.object(agent, 'ROOT', root / 'managed'), mock.patch.object(agent, 'process_environment', return_value=environment):
                self.assertEqual(agent.automatic_integration(process)['status'], 'installing')
                for _ in range(5):
                    self.assertIn(agent.automatic_integration(process)['status'], ['installing', 'failed'])
                self.assertEqual(self.wait_for_install(process)['status'], 'failed')
                for _ in range(5):
                    self.assertEqual(agent.automatic_integration(process)['status'], 'failed')
                self.assertEqual(calls.read_text().splitlines(), ['call'])

    def test_ready_claude_setup_repairs_removed_registration_and_managed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            managed = root / 'managed'
            profile = root / '.claude'
            environment = dict(HOME=directory, CLAUDE_CONFIG_DIR=str(profile), PATH=os.environ['PATH'])
            with mock.patch.object(agent, 'ROOT', managed), mock.patch.object(agent, 'process_environment', return_value=environment):
                process = row(20, 1)
                self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                for path in [profile / 'skills/terminal-remote-agent-state',
                             managed / 'claude/.claude-plugin/plugin.json',
                             managed / 'terminal_remote_agent.py']:
                    with self.subTest(path=path.name):
                        path.unlink()
                        self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                        self.assertTrue(path.is_file() or path.is_symlink())

    def test_ready_codex_setup_repairs_lost_profile_and_cache_but_keeps_disabled_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            managed = root / 'managed'
            profile = root / '.codex'
            config = profile / 'config.toml'
            cached = profile / 'plugins/cache/terminal-remote-agents/terminal-remote-agent-state/1.0.0/hooks/hooks.json'
            cached_manifest = cached.parent.parent / '.codex-plugin/plugin.json'
            calls = root / 'calls.jsonl'

            def provider_command(arguments, executable):
                with calls.open('a') as stream:
                    stream.write(json.dumps(arguments) + '\n')
                if arguments[:2] == ['plugin', 'add']:
                    # Native Codex requires an existing CODEX_HOME, including
                    # when repairing a profile deleted during a live session.
                    self.assertTrue(config.parent.is_dir())
                    config.write_text('[plugins."terminal-remote-agent-state@terminal-remote-agents"]\nenabled = true\n')
                    cached.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(managed / 'codex/hooks/hooks.json', cached)
                    cached_manifest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(managed / 'codex/.codex-plugin/plugin.json', cached_manifest)

            environment = dict(HOME=directory, CODEX_HOME=str(profile), PATH=os.environ['PATH'])
            with mock.patch.object(agent, 'ROOT', managed), mock.patch.object(agent, 'process_environment', return_value=environment), mock.patch.object(agent, 'run_codex', side_effect=provider_command):
                process = row(20, 1, executable='/opt/bin/codex')
                self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                call_count = len(calls.read_text().splitlines())
                config.write_text(config.read_text().replace('enabled = true', 'enabled = false'))
                for _ in range(3):
                    self.assertEqual(agent.automatic_integration(process)['status'], 'ready')
                self.assertIn('enabled = false', config.read_text())
                self.assertEqual(len(calls.read_text().splitlines()), call_count)
                cached.unlink()
                self.assertEqual(agent.automatic_integration(process)['status'], 'ready')
                self.assertIn('enabled = false', config.read_text())
                self.assertEqual(len(calls.read_text().splitlines()), call_count)
                with mock.patch.object(agent, 'source_text', return_value=agent.source_text() + '\n# Update while disabled.\n'):
                    self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertIn('enabled = false', config.read_text())
                self.assertEqual(len(calls.read_text().splitlines()), call_count)
                shutil.rmtree(profile)
                self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertTrue(config.is_file())
                self.assertTrue(cached.is_file())
                cached.unlink()
                self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertTrue(cached.is_file())
                cached_manifest.unlink()
                self.assertEqual(self.wait_for_install(process)['status'], 'ready')
                self.assertTrue(cached_manifest.is_file())

    def test_tilde_profile_uses_the_agents_home(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'other home'
            home.mkdir()
            environment = dict(HOME=str(home), CLAUDE_CONFIG_DIR='~/custom', PATH=os.environ['PATH'])
            with mock.patch.object(agent, 'ROOT', Path(directory) / 'managed'), mock.patch.object(agent, 'process_environment', return_value=environment):
                self.assertEqual(self.wait_for_install(row(20, 1))['status'], 'ready')
                self.assertTrue((home / 'custom/skills/terminal-remote-agent-state').is_symlink())

    def test_kernel_environment_preserves_profile_paths_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='terminal profile ') as directory:
            code = 'import runpy,json,os; m=runpy.run_path(' + repr(str(HELPER)) + '); e=m["process_environment"](os.getpid()); print(json.dumps({k:e.get(k) for k in ["HOME","CODEX_HOME"]}))'
            result = subprocess.run([sys.executable, '-c', code],
                                    env=dict(os.environ, HOME=directory, CODEX_HOME=directory + '/codex profile'),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), dict(HOME=directory, CODEX_HOME=directory + '/codex profile'))

    def test_malformed_install_receipts_are_recoverable(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'receipt.json'
            for data in [[], dict(installed_at='invalid'), dict(retry_at=float('inf'))]:
                receipt.write_text(json.dumps(data))
                self.assertEqual(agent.read_receipt(receipt), {})

    def test_setup_permission_failure_does_not_hide_the_agent(self):
        process = row(20, 1)
        with mock.patch.object(agent, 'processes', return_value={20: process}), mock.patch.object(agent, 'prune_state'), mock.patch.object(agent, 'select_processes', return_value=[process]), mock.patch.object(agent, 'details', side_effect=lambda value: value), mock.patch.object(agent, 'read_state', return_value=None), mock.patch.object(agent, 'automatic_integration', side_effect=PermissionError), mock.patch.object(agent.sys, 'platform', 'linux'), mock.patch('sys.stdout', new_callable=io.StringIO) as stdout:
            agent.probe(30, ['1234:22'], auto_install=True)
        data = json.loads(stdout.getvalue())['processes']
        self.assertEqual(data[0]['pid'], 20)
        self.assertEqual(data[0]['integration']['status'], 'failed')

    def test_other_agent_kinds_do_not_create_an_installation_directory(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(agent, 'ROOT', Path(directory) / 'managed'):
            process = row(20, 1, executable='/opt/aider')
            process['arguments'] = ['aider']
            self.assertIsNone(agent.automatic_integration(process))
            self.assertFalse(agent.ROOT.exists())

    def test_macos_ps_arguments_do_not_parse_prompt_quotes_as_shell_syntax(self):
        with mock.patch.object(agent.sys, 'platform', 'darwin'), mock.patch.object(agent, 'output', side_effect=['Mon Nov 1 12:00:00 2026', "claude -p what's up"]):
            result = agent.details(row(20, 10))
        self.assertEqual(result['arguments'][:2], ['claude', '-p'])

    def test_probe_skips_a_process_that_exits_during_details(self):
        rows = {10: row(10, 1)}
        with mock.patch.object(agent, 'processes', return_value=rows), mock.patch.object(agent, 'select_processes', return_value=list(rows.values())), mock.patch.object(agent, 'prune_state'), mock.patch.object(agent, 'details', side_effect=subprocess.CalledProcessError(1, 'ps')), mock.patch.object(agent.sys, 'platform', 'linux'), mock.patch('sys.stdout', new_callable=io.StringIO) as stdout:
            agent.probe(30, ['1234:22'])
        self.assertEqual(json.loads(stdout.getvalue())['processes'], [])

    def test_long_and_non_string_subagent_ids_are_removed(self):
        for identifier in ['x' * 300, 12345]:
            with self.subTest(identifier=str(identifier)[:20]):
                state = agent.apply_event({}, 'SubagentStart', dict(agent_id=identifier, agent_type='worker'))
                agent.apply_event(state, 'Stop', {})
                agent.apply_event(state, 'SubagentStop', dict(agent_id=identifier))
                self.assertEqual(state['subagents'], [])
                self.assertEqual(state['phase'], 'idle')

    def test_probe_channel_on_the_same_master_is_not_a_second_pane(self):
        rows = {10: row(10, 1, group=10, executable='/bin/zsh'), 20: row(20, 10),
                40: row(40, 1, group=40, foreground=0), 41: row(41, 40, group=40, foreground=0)}
        ports = lambda pid: (1234, 22)
        rows[40]['tty'] = rows[41]['tty'] = '??'
        selected = agent.select_processes(rows, {(1234, 22)}, 30, ports, excluded={40, 41})
        self.assertEqual([item['pid'] for item in selected], [20])

    def test_pruning_removes_dead_and_reused_pids_but_preserves_live_state(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(agent, 'ROOT', Path(directory)), mock.patch.object(agent.sys, 'platform', 'linux'):
            states = Path(directory) / 'state'
            states.mkdir()
            live = row(10, 1)
            old = dict(live, start='old')
            dead = row(9999999, 1)
            for item in [live, old, dead]:
                for suffix in ['.json', '.lock']:
                    (states / (agent.identity(item) + suffix)).write_text('{}')
            with mock.patch.object(agent.os, 'kill', side_effect=ProcessLookupError):
                agent.prune_state({10: live})
            self.assertEqual({path.name for path in states.iterdir()},
                             {agent.identity(live) + '.json', agent.identity(live) + '.lock'})

    def test_pruning_respects_a_hook_holding_its_lock(self):
        import fcntl
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(agent, 'ROOT', Path(directory)):
            states = Path(directory) / 'state'
            states.mkdir()
            key = agent.identity(row(9999999, 1))
            state = states / (key + '.json')
            state.write_text('{}')
            with (states / (key + '.lock')).open('w') as lock, mock.patch.object(agent.os, 'kill', side_effect=ProcessLookupError):
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                agent.prune_state({})
                self.assertTrue(state.exists())

    def test_orphaned_prompt_helper_on_the_same_tty_is_not_another_session(self):
        # A prompt's zsh/gitstatus pair can detach from the live login shell.
        # Both roots still name the same tty and foreground Codex group.
        rows = {10: row(10, 1, group=10, foreground=30, executable='-zsh'),
                20: row(20, 1, group=19, foreground=30, executable='-zsh'),
                21: row(21, 20, group=19, foreground=30, executable='/opt/gitstatusd'),
                30: row(30, 10, group=30, foreground=30, executable='/opt/codex')}
        ports = {21: (1234, 22), 30: (1234, 22)}
        self.assertEqual([item['pid'] for item in agent.select_processes(rows, {(1234, 22)}, 30, ports.get)], [30])

    def test_only_this_connections_foreground_job_is_selected(self):
        rows = {10: row(10, 1, group=10, executable='/bin/bash'),
                20: row(20, 10), 21: row(21, 20),
                30: row(30, 10, group=30), 40: row(40, 1)}
        rows[40]['tty'] = 'pts/2'
        ports = {10: (1234, 22), 20: (1234, 22), 21: (1234, 22), 30: (1234, 22), 40: (5678, 22)}
        selected = agent.select_processes(rows, {(1234, 22)}, 30, ports.get)
        self.assertEqual([item['pid'] for item in selected], [20, 21])

    def test_erased_shell_environment_is_recovered_from_its_native_children(self):
        rows = {10: row(10, 1, group=10, executable='/bin/zsh'),
                20: row(20, 10), 30: row(30, 10, group=30)}
        ports = {20: (1234, 22), 30: (1234, 22)}
        self.assertEqual([item['pid'] for item in agent.select_processes(rows, {(1234, 22)}, 30, ports.get)], [20])

    def test_ambiguous_or_old_connections_are_not_guessed(self):
        rows = {10: row(10, 1), 20: row(20, 1)}
        rows[20]['tty'] = 'pts/2'
        ports = {10: (1234, 22), 20: (1234, 22)}
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, ports.get), [])
        rows[10]['age'] = 100
        rows.pop(20)
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, ports.get), [])

    def test_tty_reuse_cannot_select_a_process_older_than_the_connection(self):
        rows = {10: row(10, 1, group=10, foreground=20),
                20: row(20, 10, group=20, foreground=20, age=100)}
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, {10: (1234, 22)}.get), [])

    def test_changing_foreground_group_during_a_snapshot_is_not_guessed(self):
        rows = {10: row(10, 1, foreground=20), 20: row(20, 10, foreground=30)}
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, lambda pid: (1234, 22)), [])

    def test_multiplexer_does_not_borrow_an_unrelated_agent(self):
        rows = {10: row(10, 1, executable='/bin/bash'),
                20: row(20, 10, executable='/usr/bin/tmux')}
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, lambda pid: (1234, 22)), [])

    def test_subagents_hold_completion_until_the_last_stop(self):
        state = agent.apply_event({}, 'UserPromptSubmit', {})
        agent.apply_event(state, 'SubagentStart', dict(agent_id='1', agent_type='worker'))
        agent.apply_event(state, 'Stop', {})
        self.assertEqual(state['phase'], 'working')
        agent.apply_event(state, 'SubagentStop', dict(agent_id='1'))
        self.assertEqual(state['phase'], 'idle')
        self.assertGreater(state['turn'], 0)

    def test_permission_interrupt_and_awaited_background_work(self):
        state = agent.apply_event({}, 'PermissionRequest', {})
        self.assertEqual(state['phase'], 'blocked')
        agent.apply_event(state, 'PostToolUse', {})
        self.assertEqual(state['phase'], 'working')
        agent.apply_event(state, 'SubagentStart', dict(agent_id='1', agent_type='worker'))
        agent.apply_event(state, 'Interrupt', {})
        self.assertEqual(state['phase'], 'idle')
        self.assertEqual(state['subagents'], [])
        agent.apply_event(state, 'Stop', dict(background_tasks=[dict(type='workflow')]))
        self.assertEqual(state['phase'], 'working')

    def test_pid_reuse_changes_the_state_file_identity(self):
        original = row(10, 1)
        replacement = dict(original, start='later')
        self.assertNotEqual(agent.identity(original), agent.identity(replacement))

    def test_real_hook_finds_its_agent_ancestor_and_writes_private_state(self):
        with tempfile.TemporaryDirectory(prefix='terminal-remote-hook-') as directory:
            root = Path(directory)
            script = root / 'claude'
            import shlex
            script.write_text('printf \'{}\' | ' + shlex.join([sys.executable, str(HELPER), 'hook', 'claude', 'UserPromptSubmit']) + '\n')
            environment = dict(os.environ, HOME=directory)
            result = subprocess.run(['/bin/sh', str(script)], env=environment, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b'')
            states = list((root / '.local/share/terminal/remote-agents/state').glob('*.json'))
            self.assertEqual(len(states), 1)
            self.assertEqual(json.loads(states[0].read_text())['phase'], 'working')
            self.assertEqual(states[0].stat().st_mode & 0o777, 0o600)

    def test_codex_installs_through_the_provider_cli(self):
        with tempfile.TemporaryDirectory(prefix='terminal-remote-codex-') as directory:
            root = Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            codex = binary / 'codex'
            codex.write_text('#!/bin/sh\npython3 -c \'import json,os,sys; f=open(os.path.join(os.environ["HOME"],"calls.jsonl"),"a"); f.write(json.dumps(sys.argv[1:])+"\\n")\' "$@"\n')
            codex.chmod(0o700)
            result = subprocess.run([sys.executable, str(HELPER), 'install', 'codex'],
                                    env=dict(os.environ, HOME=directory, PATH=str(binary) + os.pathsep + os.environ['PATH']),
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
            self.assertEqual(calls[0][:3], ['plugin', 'marketplace', 'add'])
            self.assertEqual(calls[1], ['plugin', 'add', 'terminal-remote-agent-state@terminal-remote-agents'])
            self.assertFalse((root / '.codex/config.toml').exists())
            self.assertEqual(result.stdout, b'codex\n')
            config = root / '.codex/config.toml'
            self.assertTrue(config.parent.is_dir())
            config.write_text('[marketplaces.terminal-remote-agents]\nsource = "local"\n')
            result = subprocess.run([sys.executable, str(HELPER), 'install', 'codex'],
                                    env=dict(os.environ, HOME=directory, CODEX_HOME=str(config.parent),
                                             PATH=str(binary) + os.pathsep + os.environ['PATH']),
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
            self.assertEqual(calls[2], ['plugin', 'marketplace', 'remove', 'terminal-remote-agents'])
            self.assertEqual(result.stdout, b'codex\n')

    def test_install_preserves_settings_and_quotes_paths(self):
        with tempfile.TemporaryDirectory(prefix="terminal remote ' ") as directory:
            root = Path(directory)
            settings = root / '.claude/settings.json'
            settings.parent.mkdir()
            settings.write_text('{"user": true}')
            result = subprocess.run([sys.executable, str(HELPER), 'install', 'claude'],
                                    env=dict(os.environ, HOME=directory), capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(settings.read_text(), '{"user": true}')
            plugin = root / '.local/share/terminal/remote-agents/claude/.claude-plugin/plugin.json'
            command = json.loads(plugin.read_text())['hooks']['Stop'][0]['hooks'][0]['command']
            import shlex
            self.assertEqual(shlex.split(command)[-3:], ['hook', 'claude', 'Stop'])
            self.assertIn(directory, shlex.split(command)[1])


if __name__ == '__main__':
    unittest.main()
