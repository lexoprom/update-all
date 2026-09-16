#!/usr/bin/env python3
"""Exercise the actual Bash dispatcher with an isolated fake toolchain."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import signal
import unittest

ROOT = Path(__file__).resolve().parents[1]

FAKE = r'''import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f: f.write(name + ' ' + ' '.join(args) + '\n')
args = [arg for arg in args if arg != '--dry-run'] if name == 'mise' else args
if name == 'mise':
    if args == ['activate', 'bash']: print(':')
    elif args == ['env', '--json']: print(json.dumps({'PATH': os.environ['PATH']}))
    elif args[:1] == ['ls'] and '--json' in args: print('{}')
    elif args == ['outdated', '--json']: print('{}')
    elif args == ['doctor']: print('mise is healthy')
elif name == 'brew':
    if args == ['update'] and os.environ.get('SLOW_UPDATE'): time.sleep(2)
    if args == ['--prefix']: print(os.environ['HOME'] + '/brew')
    elif args == ['outdated', '--json=v2']: print('{"formulae": [], "casks": []}')
elif name in ('npm', 'pnpm'):
    if args[:1] == ['list'] and '--json' in args: print('{}' if name == 'npm' else '[]')
    elif args[:1] == ['root']: print(os.environ['HOME'] + '/globals')
    elif args[:1] == ['outdated']: print('{}')
elif name == 'bun':
    if args == ['pm', 'ls', '-g']: print(os.environ['HOME'] + '/bun/global node_modules (0)')
elif name == 'pipx':
    if '--json' in args: print('{"venvs": {}}')
elif name == 'softwareupdate': print('No new software available.')
'''


class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'lib', self.root / 'lib')
        self.script = self.root / ('doctor-test-' + str(os.getpid()))
        shutil.copy2(ROOT / 'update-all', self.script)
        (self.root / 'home').mkdir()
        binpath = self.root / 'bin'
        binpath.mkdir()
        for name in ('brew', 'mise', 'npm', 'pnpm', 'bun', 'pipx', 'uv', 'softwareupdate', 'node', 'python'):
            target = binpath / name
            target.write_text('#!' + sys.executable + '\n' + FAKE)
            target.chmod(0o755)
        (binpath / 'python3').symlink_to(sys.executable)
        (binpath / 'bash').symlink_to(shutil.which('bash'))
        self.env = dict(os.environ, HOME=str(self.root / 'home'),
                        PATH=str(binpath) + ':/usr/bin:/bin', PNPM_HOME=str(self.root / 'pnpm'),
                        XDG_STATE_HOME=str(self.root / 'state'), CALL_LOG=str(self.root / 'calls'))
        self.lock = Path('/tmp/.' + self.script.name + '_lock')
        self.addCleanup(lambda: self.lock.unlink(missing_ok=True))
        self.receipt = self.root / 'state/update-all/last-run.json'

    def run_cli(self, *args):
        return subprocess.run([str(self.script), *args], env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)

    def calls(self):
        path = self.root / 'calls'
        return path.read_text() if path.exists() else ''

    def test_help_and_bad_arguments_do_not_run_tools(self):
        result = self.run_cli('doctor', '--help')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('--offline', result.stdout)
        result = self.run_cli('doctor', '--fix')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('Script aborted', result.stdout)
        self.assertEqual(self.calls(), '')

    def test_offline_is_read_only_and_does_not_execute_custom_commands(self):
        (self.root / 'update-all.commands').write_text('touch ' + str(self.root / 'BAD') + '\n')
        result = self.run_cli('doctor', '--offline')
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        self.assertNotIn('outdated', calls)
        self.assertNotIn('brew update', calls)
        self.assertNotIn('mise activate', calls)
        self.assertNotIn('softwareupdate -l', calls)
        self.assertNotIn('upgrade', calls)
        self.assertNotIn('install', calls.replace('--installed', ''))
        self.assertFalse(self.receipt.exists())
        self.assertFalse((self.root / 'BAD').exists())
        self.assertFalse(self.lock.exists())

    def test_online_refreshes_only_metadata(self):
        result = self.run_cli('doctor')
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        self.assertIn('brew update\n', calls)
        self.assertIn('softwareupdate -l', calls)
        self.assertNotIn('brew upgrade', calls)
        self.assertNotIn('mise upgrade', calls)
        self.assertNotIn('reshim', calls)
        self.assertNotIn('self-update', calls)
        self.assertIn('brew cleanup --dry-run', calls)
        self.assertIn('brew autoremove --dry-run', calls)
        self.assertNotIn('bun outdated', calls)  # No global lockfile/packages is a healthy empty state.

    def test_foreign_lock_is_preserved_and_no_tools_run(self):
        self.lock.write_text(str(os.getpid()) + '\n')
        original = self.lock.read_bytes()
        result = self.run_cli('doctor')
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('is running', result.stdout)
        self.assertEqual(self.lock.read_bytes(), original)
        self.assertEqual(self.calls(), '')

    def test_update_saves_receipt_and_read_only_modes_preserve_it(self):
        result = self.run_cli('--skip-commands')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.receipt.exists(), result.stdout)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['state'], 'completed')
        self.assertEqual(set(receipt['before']), {'brew', 'mise', 'npm', 'pnpm', 'bun', 'pipx', 'uv'})
        self.assertEqual(receipt['results']['stage:homebrew'], 'ok')
        original = self.receipt.read_bytes()
        for args in (('doctor', '--offline'), ('--dry-run', '--skip-commands'), ('list', '--skip-commands')):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(self.receipt.read_bytes(), original)

    def test_interrupted_update_leaves_an_interrupted_receipt(self):
        self.env['SLOW_UPDATE'] = '1'
        with subprocess.Popen([str(self.script), '--skip-commands'], env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as proc:
            deadline = time.monotonic() + 15
            while 'brew update\n' not in self.calls() and time.monotonic() < deadline:
                time.sleep(0.05)
            proc.send_signal(signal.SIGTERM)
            output, _ = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 143, output)
        self.assertEqual(json.loads(self.receipt.read_text())['state'], 'interrupted')
        self.assertFalse(self.lock.exists())


if __name__ == '__main__':
    unittest.main()
