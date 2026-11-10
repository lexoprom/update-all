import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

# Tests expect the default manager list regardless of the caller's setup.
os.environ.pop('UPDATE_ALL_GLOBAL_MANAGERS', None)


SCRIPT = Path(__file__).resolve().parents[1] / 'update-all'
SOURCE = SCRIPT.read_text()
WATCHDOG = SOURCE[SOURCE.index('process_tree_pids() {'):
                  SOURCE.index('\nsafe_execute_retry() {')]
BASH = shutil.which('bash')


class TimeoutTests(unittest.TestCase):
    def run_watchdog(self, timeout, *command):
        # Extract only the real watchdog helpers; never run system updates.
        shell = WATCHDOG + '\noutput=$(run_with_timeout "$@")\nrc=$?\nprintf "%s" "$output"\nexit "$rc"\n'
        proc = subprocess.Popen([BASH, '-c', shell, 'watchdog', str(timeout), *command],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=10)
            return proc.returncode, stdout, stderr
        finally:
            # Also clean up descendants if the regression leaves capture hung.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            proc.stdout.close()
            proc.stderr.close()

    def test_fast_command_returns_promptly(self):
        started = time.monotonic()
        rc, output, _ = self.run_watchdog(3600, BASH, '-c', 'printf "done"')
        self.assertEqual((rc, output), (0, 'done'))
        self.assertLess(time.monotonic() - started, 1)

    def test_preserves_failure_status_and_output(self):
        rc, output, stderr = self.run_watchdog(
            3600, BASH, '-c', 'printf "output"; printf "error" >&2; exit 7')
        self.assertEqual((rc, output, stderr), (7, 'output', 'error'))

    def test_disabled_timeout(self):
        rc, output, _ = self.run_watchdog(0, BASH, '-c', 'printf "disabled"; exit 7')
        self.assertEqual((rc, output), (7, 'disabled'))

    def test_kills_child_that_ignores_term_after_parent_exits(self):
        with tempfile.TemporaryDirectory() as tmp:
            ready = Path(tmp) / 'child-ready'
            child = ('import signal, time; from pathlib import Path; '
                     'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                     f'Path({str(ready)!r}).write_text("ready"); time.sleep(60)')
            parent = ('import subprocess, sys; '
                      f'subprocess.Popen([sys.executable, "-c", {child!r}]).wait()')
            rc, _, _ = self.run_watchdog(1, sys.executable, '-c', parent)
            self.assertTrue(ready.exists(), 'child must install its signal handler')
            self.assertEqual(rc, 124)

    def test_interrupt_stops_command_that_ignores_sigint(self):
        # Asynchronous commands in a non-interactive shell ignore SIGINT, so
        # Ctrl-C must not leave the command running or the caller blocked.
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / 'pid'
            child = ('import os, time; from pathlib import Path; '
                     f'Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)')
            shell = WATCHDOG + '\nrun_with_timeout 3600 "$@"\n'
            proc = subprocess.Popen([BASH, '-c', shell, 'watchdog', sys.executable, '-c', child],
                                    start_new_session=True)
            try:
                for _ in range(100):
                    if pid_file.exists() and pid_file.read_text():
                        break
                    time.sleep(0.05)
                os.killpg(proc.pid, signal.SIGINT)
                self.assertEqual(proc.wait(timeout=10), 130)
                child_pid = int(pid_file.read_text())
                time.sleep(0.2)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()


if __name__ == '__main__':
    unittest.main()
