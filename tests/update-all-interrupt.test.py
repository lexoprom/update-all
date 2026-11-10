#!/usr/bin/env python3
"""Ctrl-C must stop running update commands in serial and parallel stages."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')

# Fake tools: the stage under test records its PID and then hangs.
FAKES = {
    'brew': '[[ "$1" == upgrade && -z "${2:-}" && -f "$(dirname "$0")/hang-brew" ]] && '
            '{ echo $$ > "$(dirname "$0")/brew.pid"; exec sleep 60; }\nexit 0\n',
    'mise': '[[ "$1" == activate ]] && echo ":"\n'
            '[[ "$1" == upgrade && -f "$(dirname "$0")/hang-mise" ]] && '
            '{ echo $$ > "$(dirname "$0")/mise.pid"; exec sleep 60; }\nexit 0\n',
    'softwareupdate': 'echo "No new software available."\n',
}


class InterruptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        (self.root / 'lib').mkdir()
        self.bin.mkdir()
        (self.root / 'home').mkdir()
        # A unique name keeps the lock private to this test.
        self.script = self.root / ('update-all-interrupt-{}'.format(os.getpid()))
        shutil.copy(ROOT / 'update-all', self.script)
        for lib in (ROOT / 'lib').iterdir():
            if lib.suffix in ('.sh', '.py'):
                shutil.copy(lib, self.root / 'lib' / lib.name)
        (self.bin / 'bash').symlink_to(BASH)
        for name, body in FAKES.items():
            path = self.bin / name
            path.write_text('#!/bin/bash\n' + body)
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def interrupt(self, stage):
        (self.bin / ('hang-' + stage)).touch()
        pid_file = self.bin / (stage + '.pid')
        env = dict(PATH='{}:/usr/bin:/bin'.format(self.bin), HOME=str(self.root / 'home'),
                   XDG_STATE_HOME=str(self.root / 'state'), UPDATE_ALL_GLOBAL_MANAGERS='')
        proc = subprocess.Popen([BASH, str(self.script), '--skip-commands'], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        tool = None
        try:
            for _ in range(200):
                if pid_file.exists() and pid_file.read_text().strip():
                    break
                time.sleep(0.05)
            tool = int(pid_file.read_text())
            # Ctrl-C signals the whole foreground process group.
            os.killpg(proc.pid, signal.SIGINT)
            self.assertEqual(proc.wait(timeout=15), 130)
            time.sleep(0.2)
            with self.assertRaises(ProcessLookupError):
                os.kill(tool, 0)
            self.assertFalse(Path('/tmp/.{}_lock'.format(self.script.name)).exists())
        finally:
            for pid in (tool,):
                if pid:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()

    def test_interrupt_stops_parallel_stage(self):
        self.interrupt('brew')

    def test_interrupt_stops_serial_stage(self):
        self.interrupt('mise')


if __name__ == '__main__':
    unittest.main()
