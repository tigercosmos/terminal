#!/usr/bin/env python3
"""Remote discovery and hook regressions; no remote account or provider CLI needed."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, ports), [])
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

    def test_only_this_connections_foreground_job_is_selected(self):
        rows = {10: row(10, 1, group=10, executable='/bin/bash'),
                20: row(20, 10), 21: row(21, 20),
                30: row(30, 10, group=30), 40: row(40, 1)}
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
        ports = {10: (1234, 22), 20: (1234, 22)}
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, ports.get), [])
        rows[10]['age'] = 100
        rows.pop(20)
        self.assertEqual(agent.select_processes(rows, {(1234, 22)}, 30, ports.get), [])

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
            config.parent.mkdir()
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
