#!/usr/bin/env python3
"""Deterministic diagnostic/receipt tests; never invoke installed managers."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('doctor', ROOT / 'lib/doctor.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class FakeRunner(d.Runner):
    def __init__(self, responses=None, installed=()):
        super().__init__()
        self.responses = responses or {}
        self.installed = set(installed)
        self.calls = []
        self.env['PATH'] = ''

    def exists(self, name):
        return '/fake/bin/' + name if name in self.installed else None

    def run(self, args, **kwargs):
        self.calls.append(tuple(args))
        value = self.responses.get(tuple(args))
        if value is None:
            raise AssertionError('Unexpected command: ' + repr(args))
        if isinstance(value, Exception):
            raise value
        if isinstance(value, tuple):
            return value
        return value, '', 0


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, HOME=str(self.root), XDG_STATE_HOME=str(self.root / 'state'))
        self.env.start()
        self.addCleanup(self.env.stop)

    def output(self, fn):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            result = fn()
        return result, stream.getvalue()

    def test_absent_managers_and_no_history_are_not_errors(self):
        runner = FakeRunner()
        rc, text = self.output(d.Doctor(runner, offline=True).run)
        self.assertEqual(rc, 0)
        self.assertIn('No update history', text)
        self.assertEqual(runner.calls, [])

    def test_failed_and_malformed_inventory_are_never_empty_success(self):
        for response in (d.CheckError('broken launcher'), 'not json', '{"error":"failure"}'):
            r = FakeRunner({('npm', 'list', '-g', '--depth=0', '--json'): response,
                            ('npm', 'root', '-g'): '/fake/root'}, ['npm'])
            inv = d.collect(r, 'npm')
            self.assertEqual(inv['status'], 'error')

    def test_scoped_packages_and_versioned_paths(self):
        r = FakeRunner({('npm', 'list', '-g', '--depth=0', '--json'):
                        json.dumps({'dependencies': {'@scope/tool': {'version': '2.0'}}}),
                        ('npm', 'root', '-g'): '/runtimes/node/22/lib/node_modules'}, ['npm'])
        inv = d.collect(r, 'npm')
        self.assertEqual(inv['packages'][0]['location'], '/runtimes/node/22/lib/node_modules/@scope/tool')

    def test_bun_empty_lockfile_is_empty_and_runs_outside_home(self):
        class BunRunner(FakeRunner):
            def run(inner, args, **kwargs):
                self.assertNotEqual(kwargs.get('cwd'), str(self.root))
                return super(BunRunner, inner).run(args, **kwargs)
        for message in ('Lockfile not found', 'missing lockfile, nothing to list'):
            r = BunRunner({('bun', 'pm', 'ls', '-g'): ('', message, 1)}, ['bun'])
            self.assertEqual(d.collect(r, 'bun')['status'], 'ok')
        r.responses[('bun', 'pm', 'ls', '-g')] = ('', 'broken runtime', 1)
        self.assertEqual(d.collect(r, 'bun')['status'], 'error')

    def test_bun_tree_paths(self):
        r = FakeRunner({('bun', 'pm', 'ls', '-g'): '/global node_modules (1)\n└── @scope/tool@1.2.3\n'}, ['bun'])
        self.assertEqual(d.collect(r, 'bun')['packages'][0]['location'], '/global/node_modules/@scope/tool')

    def test_uv_and_pipx_inventory_paths(self):
        r = FakeRunner({('uv', 'tool', 'list', '--show-paths', '--show-version-specifiers'):
                        'ruff v1.0 (/env/ruff)\n- ruff (/bin/ruff)\n'}, ['uv'])
        inv = d.collect(r, 'uv')
        self.assertEqual(inv['packages'][0]['apps'], ['/bin/ruff'])
        data = {'venvs': {'ruff': {'metadata': {'main_package': {
            'package_version': '1.0', 'pinned': True,
            'app_paths': [{'__Path__': '/env/ruff/bin/ruff'}]}}}}}
        r = FakeRunner({('pipx', 'list', '--json', '--skip-maintenance'): json.dumps(data)}, ['pipx'])
        self.assertTrue(d.collect(r, 'pipx')['packages'][0]['pinned'])

    def test_online_npm_exit_one_means_updates_only_with_valid_data(self):
        command = ('npm', 'outdated', '-g', '--json')
        r = FakeRunner({command: ('{"pkg":{"current":"1","latest":"2"}}', '', 1)}, ['npm'])
        doc = d.Doctor(r)
        _, text = self.output(lambda: doc.online('npm'))
        self.assertIn('update available for pkg', text)
        r.responses[command] = ('{}', 'network failure', 1)
        _, text = self.output(lambda: doc.online('npm'))
        self.assertIn('freshness check incomplete', text)
        self.assertNotIn('no remaining updates', text)

    def test_pins_and_prunable_versions_are_not_failures(self):
        r = FakeRunner({('brew', 'update'): '', ('brew', 'list', '--pinned'): 'node',
                        ('brew', 'outdated', '--json=v2'): json.dumps({
                            'formulae': [{'name': 'node', 'installed_versions': ['20'], 'current_version': '22'}], 'casks': []}),
                        ('mise', 'ls', '--prunable', '--no-header'): 'node 18\n'}, ['brew', 'mise'])
        doc = d.Doctor(r)
        self.output(lambda: doc.online('brew'))
        self.output(lambda: doc.check('candidates', ['mise', 'ls', '--prunable', '--no-header'], output_status='INFO'))
        self.assertEqual(doc.counts['WARN'] + doc.counts['ERROR'], 0)
        self.assertEqual(doc.counts['INFO'], 2)

    def test_offline_does_not_call_network(self):
        r = FakeRunner()
        doc = d.Doctor(r, offline=True)
        for manager in d.MANAGERS:
            self.output(lambda: doc.online(manager))
        self.assertEqual(r.calls, [])
        self.assertEqual(doc.counts['SKIP'], 7)

    def test_timeout_kills_process_group(self):
        r = d.Runner(timeout=0.1)
        with self.assertRaisesRegex(d.CheckError, 'timed out'):
            r.run([sys.executable, '-c', 'import time; time.sleep(5)'])

    def test_environment_disables_auto_install_and_maintenance(self):
        r = d.Runner(offline=True)
        for key in ('MISE_AUTO_INSTALL', 'MISE_AUTO_UPDATE', 'MISE_EXEC_AUTO_INSTALL'):
            self.assertEqual(r.env[key], 'false')
        self.assertEqual(r.env['UV_PYTHON_DOWNLOADS'], 'never')
        self.assertEqual(r.env['HOMEBREW_NO_AUTO_UPDATE'], '1')

    def test_success_with_stderr_warning_is_not_healthy(self):
        with self.assertRaisesRegex(d.CheckError, 'Ignoring malformed'):
            d.Runner().run([sys.executable, '-c', 'import sys; print("warning: Ignoring malformed tool", file=sys.stderr)'])

    def test_expected_nonzero_result_remains_available_to_collector(self):
        _, err, code = d.Runner().run([sys.executable, '-c',
                                      'import sys; print("error: missing lockfile", file=sys.stderr); sys.exit(1)'],
                                     accepted=(0, 1))
        self.assertEqual(code, 1)
        self.assertIn('missing lockfile', err)

    def test_pipx_does_not_expect_unexposed_dependency_commands(self):
        main = {'package_version': '1', 'app_paths': [{'__Path__': '/env/bin/tool'}],
                'include_dependencies': False,
                'app_paths_of_dependencies': {'dep': [{'__Path__': '/env/bin/dep'}]}}
        r = FakeRunner({('pipx', 'list', '--json', '--skip-maintenance'):
                        json.dumps({'venvs': {'tool': {'metadata': {'main_package': main}}}})}, ['pipx'])
        self.assertEqual(d.collect(r, 'pipx')['packages'][0]['apps'], ['/env/bin/tool'])

    def test_pipx_outdated_uses_supported_flags_and_respects_pins(self):
        r = FakeRunner({('pipx', 'list', '--outdated', '--skip-maintenance'):
                        'ruff [pinned]: 1 -> 2\nblack: 2 -> 3\n'}, ['pipx'])
        doc = d.Doctor(r)
        doc.inventories['pipx'] = {'packages': [d.package('ruff', '1', pinned=True), d.package('black', '2')]}
        _, text = self.output(lambda: doc.online('pipx'))
        self.assertIn('[INFO] pipx: ruff', text)
        self.assertIn('[WARN] pipx: black', text)

    def test_pipx_suffix_checks_exposed_main_and_dependency_commands(self):
        venv = self.root / 'venv/bin'
        exposed = self.root / 'bin'
        venv.mkdir(parents=True)
        exposed.mkdir()
        (venv / 'python').write_text('')
        for name in ('tool', 'dep'):
            target = venv / name
            target.write_text('#!/bin/sh\n')
            target.chmod(0o755)
            (exposed / (name + '-dev')).symlink_to(target)
        main = {'package_version': '1', 'suffix': '-dev',
                'app_paths': [{'__Path__': str(venv / 'tool')}],
                'include_dependencies': True,
                'app_paths_of_dependencies': {'dep': [{'__Path__': str(venv / 'dep')}]}}
        r = FakeRunner({('pipx', 'list', '--json', '--skip-maintenance'):
                        json.dumps({'venvs': {'tool-dev': {'metadata': {'main_package': main}}}}),
                        (str(venv / 'python'), '-m', 'pip', 'check'): ''}, ['pipx'])
        r.env['PATH'] = str(exposed)
        doc = d.Doctor(r)
        _, text = self.output(lambda: doc.inventory('pipx'))
        self.assertNotIn('[WARN]', text)
        self.assertNotIn('[ERROR]', text)
        self.assertNotIn('another installation', text)
        self.assertTrue({'tool-dev', 'dep-dev'} <= doc.commands)
        self.assertTrue({'tool', 'dep'}.isdisjoint(doc.commands))
        (exposed / 'tool-dev').unlink()
        (exposed / 'tool').symlink_to(venv / 'tool')
        _, text = self.output(lambda: doc.inventory('pipx'))
        self.assertIn('command is not on updater PATH: tool-dev', text)

    def test_uv_constrained_update_is_for_review(self):
        r = FakeRunner({('uv', 'tool', 'list', '--outdated'): 'ruff v1 [latest: 2]\n- ruff\n'}, ['uv'])
        doc = d.Doctor(r)
        doc.inventories['uv'] = {'packages': [d.package('ruff', '1', requested='==1')]}
        _, text = self.output(lambda: doc.online('uv'))
        self.assertIn('[INFO] uv: ruff', text)
        self.assertNotIn('[WARN]', text)

    def test_pnpm_launcher_is_resolved_without_execution(self):
        target = self.root / 'node_modules/tool/bin/tool.js'
        target.parent.mkdir(parents=True)
        target.write_text('')
        launcher = self.root / 'launcher'
        launcher.write_text('#!/bin/sh\nexit 99\n# cmd-shim-target=' + str(target) + '\n')
        doc = d.Doctor(FakeRunner())
        self.assertEqual(doc.resolved(str(launcher), 'tool'), os.path.realpath(target))

    def test_broken_links_and_same_target_aliases(self):
        a, b = self.root / 'a', self.root / 'b'
        a.mkdir(); b.mkdir()
        tool = a / 'tool'
        tool.write_text('#!/bin/sh\n')
        tool.chmod(0o755)
        (b / 'tool').symlink_to(tool)
        (a / 'broken').symlink_to('/nonexistent/doctor-tool')
        r = FakeRunner()
        r.env['PATH'] = str(a) + ':' + str(b)
        doc = d.Doctor(r, original_path=r.env['PATH'])
        doc.commands = {'tool', 'broken'}
        _, text = self.output(doc.paths)
        self.assertIn('broken link', text)
        self.assertNotIn('multiple installations of tool', text)

    def test_valid_mise_shim_is_equivalent_to_real_binary(self):
        shim = self.root / '.local/share/mise/shims'
        real = self.root / 'runtime/bin'
        shim.mkdir(parents=True); real.mkdir(parents=True)
        for directory in (shim, real):
            (directory / 'node').write_text('#!/bin/sh\n')
            (directory / 'node').chmod(0o755)
        r = FakeRunner({('mise', 'which', 'node'): str(real / 'node')}, ['mise'])
        r.env['PATH'] = str(shim) + ':' + str(real)
        doc = d.Doctor(r, original_path=str(real))
        doc.commands = {'node'}
        _, text = self.output(doc.paths)
        self.assertNotIn('different node', text)
        self.assertNotIn('multiple installations', text)

    def receipt(self, before=None, after=None, state='completed'):
        inventories = {m: {'status': 'absent', 'packages': []} for m in d.MANAGERS}
        return dict(schema=1, run_id='run', started_at='today', state=state,
                    before=before or inventories, after=after or inventories, results={})

    def test_history_distinguishes_update_loss_from_later_removal(self):
        before = {'npm': {'status': 'ok', 'packages': [d.package('lost', '1'), d.package('later', '2')]}}
        after = {'npm': {'status': 'ok', 'packages': [d.package('later', '2')]}}
        d.atomic_write(d.state_path(), self.receipt(before, after))
        doc = d.Doctor(FakeRunner())
        doc.inventories = {'npm': {'status': 'ok', 'packages': []}}
        _, text = self.output(doc.receipt)
        self.assertIn('[ERROR] npm: disappeared during last update: lost', text)
        self.assertIn('[WARN] npm: removed since last update: later', text)

    def test_bad_and_interrupted_receipts(self):
        d.atomic_write(d.state_path(), self.receipt(state='running'))
        doc = d.Doctor(FakeRunner())
        _, text = self.output(doc.receipt)
        self.assertIn('did not finish', text)
        d.state_path().write_text('$(touch should-never-run)')
        _, text = self.output(doc.receipt)
        self.assertIn('history is unreadable', text)
        self.assertFalse((self.root / 'should-never-run').exists())

    def test_receipts_are_atomic_private_and_redacted(self):
        report = self.root / 'report'
        report.mkdir()
        r = FakeRunner({('npm', 'list', '-g', '--depth=0', '--json'): d.CheckError('secret-token')}, ['npm'])
        with patch.object(d, 'Runner', return_value=r):
            d.history('start', str(report))
            started = json.loads(d.state_path().read_text())
            self.assertEqual(started['state'], 'running')
            self.assertNotIn('secret-token', d.state_path().read_text())
            (report / 'status.log').write_text('command 01\t❌ Failed (exit code: 1)\n')
            (report / 'commands.index').write_text('command 01\techo secret-token\n')
            d.history('finish', str(report))
            finished = json.loads(d.state_path().read_text())
            self.assertEqual(finished['results']['command 01'], 'failed')
            self.assertEqual(finished['state'], 'completed')
            self.assertNotIn('secret-token', d.state_path().read_text())
            self.assertEqual(d.state_path().stat().st_mode & 0o777, 0o600)
            previous = d.state_path().read_bytes()
            d.history('interrupt', 'different-run')
            self.assertEqual(previous, d.state_path().read_bytes())

    def test_unavailable_manager_does_not_suppress_later_checks(self):
        r = FakeRunner({('npm', 'list', '-g', '--depth=0', '--json'): d.CheckError('broken'),
                        ('uv', 'tool', 'list', '--show-paths', '--show-version-specifiers'): ''}, ['npm', 'uv'])
        rc, text = self.output(d.Doctor(r, offline=True).run)
        self.assertEqual(rc, 1)
        self.assertIn('[OK] uv: 0 installed entries', text)

    def test_newer_run_keeps_receipt_when_older_snapshot_finishes(self):
        for action in ('start', 'finish'):
            with self.subTest(action=action):
                d.atomic_write(d.state_path(), self.receipt())
                newer = []

                def overlapping_snapshot(runner):
                    with patch.object(d, 'snapshot', return_value={}):
                        d.history('start', 'newer-run')
                    newer.append(d.state_path().read_bytes())
                    return {'old-snapshot': {}}

                with patch.object(d, 'snapshot', side_effect=overlapping_snapshot):
                    d.history(action, 'run')
                self.assertEqual(d.state_path().read_bytes(), newer[0])

    def test_receipt_writes_hold_exclusive_lock(self):
        original_write = d.atomic_write
        writes = []

        def checked_write(path, data):
            with path.with_suffix('.lock').open() as lock:
                with self.assertRaises(BlockingIOError):
                    d.fcntl.flock(lock, d.fcntl.LOCK_EX | d.fcntl.LOCK_NB)
            writes.append(data['state'])
            original_write(path, data)

        with patch.object(d, 'atomic_write', side_effect=checked_write), \
                patch.object(d, 'snapshot', return_value={}):
            d.history('start', 'run')
            d.history('finish', 'run')
            d.history('interrupt', 'run')
        self.assertEqual(writes, ['running', 'running', 'completed', 'interrupted'])


if __name__ == '__main__':
    unittest.main()
