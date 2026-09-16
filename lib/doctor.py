#!/usr/bin/env python3
"""Read-only diagnostics and versioned update receipts. Python 3 stdlib only."""
import argparse
import collections
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

MANAGERS = ('brew', 'mise', 'npm', 'pnpm', 'bun', 'pipx', 'uv')
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def clean(text):
    return ''.join(c for c in ANSI.sub('', str(text)) if c in '\n\t' or ord(c) >= 32)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class CheckError(Exception):
    pass


class Runner:
    def __init__(self, offline=False, verbose=False, timeout=120):
        self.env = os.environ.copy()
        self.env.update(NO_COLOR='1', FORCE_COLOR='0', CI='1', LC_ALL='C',
                        HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_ANALYTICS='1',
                        MISE_AUTO_INSTALL='false', MISE_AUTO_UPDATE='false',
                        MISE_NO_HOOKS='1', MISE_UPGRADE_AUTO_PRUNE='false',
                        MISE_EXEC_AUTO_INSTALL='false', UV_PYTHON_DOWNLOADS='never',
                        npm_config_update_notifier='false', PIP_DISABLE_PIP_VERSION_CHECK='1',
                        pnpm_config_manage_package_manager_versions='false',
                        pnpm_config_pm_on_fail='ignore')
        if offline:
            self.env.update(MISE_OFFLINE='1', UV_OFFLINE='1', npm_config_offline='true')
        self.cwd = str(Path.home())
        self.verbose = verbose
        self.timeout = timeout

    def exists(self, name):
        return shutil.which(name, path=self.env.get('PATH', ''))

    def prepare_path(self):
        if self.exists('mise'):
            data = self.data('mise', 'env', '--json')
            if not isinstance(data, dict) or not isinstance(data.get('PATH'), str):
                raise CheckError('mise did not return its effective PATH')
            pnpm = self.env.get('PNPM_HOME', str(Path.home() / 'Library/pnpm'))
            self.env['PATH'] = str(Path(pnpm) / 'bin') + ':' + data['PATH']

    def run(self, args, accepted=(0,), timeout=None, cwd=None):
        if args[0] == 'mise':
            # Recent mise releases remove scheduled old runtimes even in `which`.
            # The global dry-run flag suppresses that implicit cleanup.
            args = ['mise', '--dry-run'] + args[1:]
        else:
            executable = self.exists(args[0])
            shim_dir = Path(self.env.get('MISE_DATA_DIR', str(Path.home() / '.local/share/mise'))) / 'shims'
            if executable and Path(executable).parent == shim_dir:
                resolved = self.output('mise', 'which', args[0])
                if not os.path.isabs(resolved) or Path(resolved).parent == shim_dir:
                    raise CheckError('cannot safely resolve mise shim: ' + args[0])
                args = [resolved] + args[1:]
        # Do not let /usr/bin/env shebangs invoke mise's auto-cleaning shims.
        child_env = self.env.copy()
        shim_dir = Path(self.env.get('MISE_DATA_DIR', str(Path.home() / '.local/share/mise'))) / 'shims'
        child_env['PATH'] = ':'.join(p for p in self.env.get('PATH', '').split(':') if Path(p) != shim_dir)
        if self.verbose:
            print('  $ ' + shlex.join(args), flush=True)
        try:
            with subprocess.Popen(args, cwd=cwd or self.cwd, env=child_env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, start_new_session=True) as proc:
                try:
                    out, err = proc.communicate(timeout=timeout or self.timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()
                    if sys.exc_info()[0] is KeyboardInterrupt:
                        raise
                    raise CheckError('timed out: ' + shlex.join(args))
        except OSError as exc:
            raise CheckError(str(exc)) from exc
        out, err = clean(out.decode(errors='replace')), clean(err.decode(errors='replace'))
        if proc.returncode not in accepted:
            raise CheckError('{} (exit {}): {}'.format(shlex.join(args), proc.returncode,
                                                      (err or out).strip()[:3000]))
        if proc.returncode == 0 and re.search(r'(?im)\b(?:warning|warn|error|failed)\b', err):
            raise CheckError(shlex.join(args) + ': ' + err.strip()[:3000])
        return out, err, proc.returncode

    def output(self, *args, **kwargs):
        return self.run(list(args), **kwargs)[0].strip()

    def data(self, *args, **kwargs):
        out = self.output(*args, **kwargs)
        try:
            return json.loads(out)
        except ValueError as exc:
            raise CheckError('invalid JSON from ' + shlex.join(args)) from exc


def package(name, version, location='', **extra):
    if not isinstance(name, str) or not name or not isinstance(version, str) or not version:
        raise CheckError('incomplete package metadata')
    return dict(name=name, version=version, location=str(location), **extra)


def path_value(value):
    return value.get('__Path__', '') if isinstance(value, dict) else str(value)


def js_packages(data, root):
    records = []
    if not isinstance(data, list):
        data = [data]
    for tree in data:
        if tree.get('error') or tree.get('problems'):
            raise CheckError('invalid global dependency tree: ' + str(tree.get('problems', tree.get('error'))))
        deps = tree.get('dependencies', {})
        for name, item in deps.items():
            if item.get('missing') or item.get('invalid'):
                raise CheckError('missing or invalid dependency: ' + name)
            records.append(package(name, item.get('version'), item.get('path') or str(Path(root) / name)))
    return records


def collect(runner, manager):
    """Failure is never an empty inventory. Shared by doctor and history."""
    r = runner
    if not r.exists(manager):
        return dict(status='absent', packages=[])
    try:
        records = []
        if manager == 'brew':
            prefix = r.output('brew', '--prefix')
            for kind, directory in (('formula', 'Cellar'), ('cask', 'Caskroom')):
                output = r.output('brew', 'list', '--versions', '--' + kind)
                for line in output.splitlines():
                    fields = line.split()
                    if len(fields) < 2:
                        raise CheckError('invalid Homebrew inventory: ' + line)
                    for version in fields[1:]:
                        records.append(package(kind + ':' + fields[0], version,
                                               str(Path(prefix) / directory / fields[0] / version)))
        elif manager == 'mise':
            data = r.data('mise', 'ls', '--installed', '--json')
            for name, versions in data.items():
                for item in versions:
                    records.append(package(name, item['version'], item['install_path'],
                                           active=item.get('active', False),
                                           requested=item.get('requested_version', '')))
        elif manager in ('npm', 'pnpm'):
            data = r.data(manager, 'list', '-g', '--depth=0', '--json')
            root = r.output(manager, 'root', '-g')
            records = js_packages(data, root)
        elif manager == 'bun':
            with tempfile.TemporaryDirectory(prefix='update-all-bun-') as work:
                out, err, code = r.run(['bun', 'pm', 'ls', '-g'], accepted=(0, 1), cwd=work)
            if code and ('Lockfile not found' in err or 'missing lockfile' in err):
                return dict(status='ok', packages=[], executable=r.exists(manager))
            if code:
                raise CheckError(err or out or 'bun inventory failed')
            root = ''
            for line in out.splitlines():
                if line.startswith('/'):
                    root = line.strip().split(' node_modules')[0]
                    if not root.endswith('/node_modules'):
                        root += '/node_modules'
                match = re.match(r'^[├└]── (.+)@([^@\s]+)\s*$', line)
                if match:
                    if not root:
                        raise CheckError('missing Bun global installation path')
                    name, version = match.groups()
                    records.append(package(name, version, str(Path(root) / name)))
                elif line.startswith(('├', '└')):
                    raise CheckError('unrecognized Bun package: ' + line)
            if not root and out.strip():
                raise CheckError('unrecognized Bun inventory')
        elif manager == 'pipx':
            data = r.data('pipx', 'list', '--json', '--skip-maintenance')
            for name, venv in data['venvs'].items():
                metadata = venv['metadata']
                main = metadata['main_package']
                paths = [path_value(p) for p in main.get('app_paths', [])]
                if main.get('include_dependencies', False):
                    for values in main.get('app_paths_of_dependencies', {}).values():
                        paths.extend(path_value(p) for p in values)
                location = str(Path(paths[0]).parent.parent) if paths else ''
                records.append(package(name, main['package_version'], location,
                                       apps=paths if metadata.get('exposure_enabled', True) else [],
                                       suffix=main.get('suffix', '') or '',
                                       pinned=main.get('pinned', False), requested=main.get('package_or_url', '')))
        elif manager == 'uv':
            out = r.output('uv', 'tool', 'list', '--show-paths', '--show-version-specifiers')
            current = None
            for line in out.splitlines():
                match = re.match(r'^([^\s]+) v([^\s]+).*\((/.*)\)$', line)
                app = re.match(r'^- \S+ \((/.*)\)$', line)
                if match:
                    current = package(*match.groups(), apps=[])
                    spec = re.search(r'\[required: (.*?)\]', line)
                    current['requested'] = spec.group(1) if spec else ''
                    records.append(current)
                elif app and current is not None:
                    current['apps'].append(app.group(1))
                elif line.strip():
                    raise CheckError('unrecognized uv inventory: ' + line)
        return dict(status='ok', packages=records, executable=r.exists(manager))
    except (CheckError, KeyError, TypeError, AttributeError, ValueError) as exc:
        return dict(status='error', packages=[], error=str(exc), executable=r.exists(manager))


def state_path():
    return Path(os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')) / 'update-all/last-run.json'


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.receipt-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def snapshot(runner):
    environment_error = False
    try:
        runner.prepare_path()
    except CheckError:
        environment_error = True
    result = {name: collect(runner, name) for name in MANAGERS}
    if environment_error:
        # An inventory under the wrong runtime cannot prove packages were retained.
        for name in ('mise', 'npm', 'pnpm', 'bun', 'pipx', 'uv'):
            result[name] = dict(status='error', packages=[], error='environment unavailable')
    # Do not retain raw diagnostics: package managers may echo registry credentials.
    for inventory in result.values():
        if inventory['status'] == 'error':
            inventory['error'] = 'inventory collection failed'
        inventory['packages'] = [{key: item[key] for key in ('name', 'version', 'location')}
                                 for item in inventory['packages']]
    return result


def statuses(report):
    result = {}
    path = Path(report) / 'status.log'
    if path.exists():
        for line in path.read_text().splitlines():
            name, sep, status = line.partition('\t')
            if not sep:
                continue
            if '❌' in status or 'Failed' in status or 'failed' in status:
                value = 'failed'
            elif '⚠' in status:
                value = 'warning'
            elif '⏭' in status or '🔍' in status:
                value = 'skipped'
            else:
                value = 'ok'
            result[name] = value
    stages = Path(report) / 'stages.tsv'
    if stages.exists():
        for line in stages.read_text().splitlines():
            name, _, code = line.partition('\t')
            result['stage:' + name] = 'ok' if code == '0' else 'failed'
    return result


@contextlib.contextmanager
def receipt_lock(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Keep a separate, stable inode: atomic_write replaces the receipt itself.
    fd = os.open(path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def history(action, report):
    path = state_path()
    if action == 'start':
        data = dict(schema=1, run_id=report, started_at=now(), state='running',
                    before={}, after={}, results={})
        with receipt_lock(path):
            atomic_write(path, data)
        data['before'] = snapshot(Runner(offline=True))
    else:
        data = json.loads(path.read_text())
        if data.get('run_id') != report:
            return  # A forced updater has replaced our receipt.
        data['results'] = statuses(report)
        data['state'] = 'interrupted' if action == 'interrupt' else 'completed'
        data['finished_at'] = now()
        if action == 'finish':
            data['after'] = snapshot(Runner(offline=True))
    with receipt_lock(path):
        if json.loads(path.read_text()).get('run_id') != report:
            return  # Ownership may have changed during snapshot collection.
        atomic_write(path, data)


class Doctor:
    def __init__(self, runner, offline=False, original_path=None):
        self.r = runner
        self.offline = offline
        self.original_path = original_path if original_path is not None else runner.env.get('PATH', '')
        self.counts = collections.Counter()
        self.inventories = {}
        self.commands = set(MANAGERS) | {'node', 'python', 'python3', 'softwareupdate'}
        self.shim_targets = {}

    def emit(self, status, label, detail='', advice=''):
        self.counts[status] += 1
        print('[{}] {}'.format(status, clean(label)), flush=True)
        if detail:
            lines = clean(detail).strip().splitlines()
            limit = len(lines) if self.r.verbose else 12
            for line in lines[:limit]:
                print('  ' + line)
            if len(lines) > limit:
                print('  ... use --verbose for full details')
        if advice:
            print('  Next: ' + clean(advice))

    def check(self, label, args, output_status=None, failure='WARN', advice='', accepted=(0,), timeout=None):
        try:
            out, err, code = self.r.run(args, accepted=accepted, timeout=timeout)
            text = (out + '\n' + err).strip()
            status = output_status if text and output_status else 'OK'
            if code:
                status = failure
            self.emit(status, label, text if status != 'OK' or self.r.verbose else '', advice if status != 'OK' else '')
            return code == 0
        except CheckError as exc:
            self.emit(failure, label, str(exc), advice or 'Retry: ' + shlex.join(args))
            return False

    def inventory(self, manager):
        inv = collect(self.r, manager)
        self.inventories[manager] = inv
        if inv['status'] == 'absent':
            self.emit('SKIP', manager + ': not installed')
            return False
        if inv['status'] == 'error':
            self.emit('ERROR', manager + ': inventory unavailable', inv['error'],
                      'Inspect the manager installation; retry update-all doctor --verbose.')
            return False
        self.emit('OK', '{}: {} installed entries'.format(manager, len(inv['packages'])))
        self.inspect_packages(manager, inv['packages'])
        return True

    def inspect_packages(self, manager, packages):
        for item in packages:
            location = item.get('location')
            if location and not Path(location).exists():
                self.emit('ERROR', manager + ': missing installation ' + item['name'], location,
                          'Reinstall this package with ' + manager + ' after reviewing its version constraint.')
                continue
            if manager in ('npm', 'pnpm', 'bun'):
                manifest = Path(location) / 'package.json'
                try:
                    data = json.loads(manifest.read_text())
                    if data.get('version') != item['version']:
                        self.emit('ERROR', manager + ': installed version differs from inventory: ' + item['name'],
                                  '{} reports {}; manifest contains {}'.format(manager, item['version'], data.get('version')),
                                  'Review and reinstall this package with ' + manager + '.')
                    bins = data.get('bin', {})
                    if isinstance(bins, str):
                        bins = {item['name'].split('/')[-1]: bins}
                    for name, target in bins.items():
                        self.commands.add(name)
                        target = Path(location) / target
                        if not target.is_file():
                            self.emit('ERROR', manager + ': missing executable ' + name, str(target),
                                      'Reinstall ' + item['name'] + ' with ' + manager + '.')
                        self.check_exposure(manager, name, target)
                except (OSError, ValueError, TypeError, AttributeError) as exc:
                    self.emit('ERROR', manager + ': unreadable package manifest ' + item['name'], str(exc),
                              'Reinstall this package with ' + manager + '.')
            elif manager in ('pipx', 'uv'):
                for app in item.get('apps', []):
                    target = Path(app)
                    name = target.name + (item.get('suffix', '') if manager == 'pipx' else '')
                    self.commands.add(name)
                    if not target.is_file() or not os.access(target, os.X_OK):
                        self.emit('ERROR', manager + ': broken executable ' + name, str(target),
                                  'Reinstall ' + item['name'] + ' with ' + manager + '.')
                    self.check_exposure(manager, name, target)
                if location:
                    python = Path(location) / 'bin/python'
                    if not python.is_file():
                        self.emit('ERROR', manager + ': broken Python environment ' + item['name'], str(python),
                                  'Reinstall ' + item['name'] + ' with ' + manager + '.')
                    elif self.r.exists('uv'):
                        self.check(manager + ': dependencies of ' + item['name'],
                                   ['uv', 'pip', 'check', '--python', str(python), '--no-python-downloads'],
                                   failure='ERROR')
                    else:
                        # runpip can provision pip; invoking an existing interpreter cannot.
                        self.check('pipx: dependencies of ' + item['name'],
                                   [str(python), '-m', 'pip', 'check'], failure='WARN')

    def check_exposure(self, manager, name, target):
        active = shutil.which(name, path=self.r.env.get('PATH', ''))
        if not active:
            self.emit('WARN', manager + ': command is not on updater PATH: ' + name, str(target),
                      'Check the manager bin directory and shell PATH.')
        elif self.resolved(active, name) != os.path.realpath(target):
            self.emit('INFO', manager + ': another installation provides ' + name,
                      '{}; package executable: {}'.format(active, target),
                      'Review which installation should provide this command.')

    def resolved(self, path, name):
        if not path:
            return None
        # Resolve shims through mise without executing arbitrary user commands.
        shim_dir = Path(self.r.env.get('MISE_DATA_DIR', str(Path.home() / '.local/share/mise'))) / 'shims'
        if Path(path).parent == shim_dir:
            if name not in self.shim_targets:
                try:
                    self.shim_targets[name] = os.path.realpath(self.r.output('mise', 'which', name))
                except CheckError:
                    self.emit('WARN', 'PATH: mise shim is not usable: ' + name, path,
                              'Review mise configuration and mise reshim; do not remove an active tool.')
                    self.shim_targets[name] = os.path.realpath(path)
            return self.shim_targets[name]
        # pnpm cmd-shim launchers are regular shell files, not symlinks.
        try:
            with open(path, 'rb') as stream:
                content = stream.read(16384)
            if content.startswith(b'#!/bin/sh'):
                text = content.decode(errors='replace')
                match = re.search(r'^# cmd-shim-target=(/.*)$', text, re.MULTILINE)
                if match:
                    return os.path.realpath(match.group(1))
                targets = re.findall(r'"\$basedir/([^"$]+)"', text)
                targets = [p for p in targets if '/node_modules/' in p]
                if targets:
                    return os.path.realpath(Path(path).resolve().parent / targets[-1])
        except OSError:
            pass
        return os.path.realpath(path)

    def paths(self):
        for name in sorted(self.commands):
            original = shutil.which(name, path=self.original_path)
            effective = shutil.which(name, path=self.r.env.get('PATH', ''))
            if effective and not original:
                self.emit('WARN', 'PATH: unavailable in caller shell: ' + name, effective,
                          'Add the manager bin directory to your shell PATH.')
            elif original and effective and self.resolved(original, name) != self.resolved(effective, name):
                self.emit('WARN', 'PATH: shell and updater use different ' + name,
                          'shell: {}\nupdater: {}'.format(original, effective),
                          'Review PATH order and mise activation in your shell.')
            found = {}
            for directory in dict.fromkeys((self.original_path + ':' + self.r.env.get('PATH', '')).split(':')):
                path = Path(directory or self.r.cwd) / name
                if path.is_symlink() and not path.exists():
                    self.emit('ERROR', 'PATH: broken link ' + str(path),
                              'target: ' + os.readlink(path), 'Repair or remove this link after checking its owner.')
                elif path.is_file() and os.access(path, os.X_OK):
                    found[self.resolved(str(path), name)] = str(path)
            if len(found) > 1:
                self.emit('INFO', 'PATH: multiple installations of ' + name, '\n'.join(found.values()),
                          'Review before removing any installation.')
        for group in (('npm', 'pnpm', 'bun'), ('pipx', 'uv')):
            owners = collections.defaultdict(set)
            for manager in group:
                for item in self.inventories.get(manager, {}).get('packages', []):
                    owners[item['name']].add(manager)
            for name, managers in sorted(owners.items()):
                if len(managers) > 1:
                    self.emit('INFO', 'Duplicate package: ' + name, ', '.join(sorted(managers)),
                              'Review ownership; duplicate installations can be intentional.')

    def online(self, manager):
        if self.offline:
            self.emit('SKIP', manager + ': online updates (--offline)')
            return
        try:
            if manager == 'brew':
                if not self.check('Homebrew metadata refresh', ['brew', 'update'], advice='Retry brew update.'):
                    self.emit('WARN', 'Homebrew freshness is unknown; metadata refresh failed')
                    return
                data = self.r.data('brew', 'outdated', '--json=v2')
                entries = data['formulae'] + data['casks']
                pinned = set(self.r.output('brew', 'list', '--pinned').splitlines())
                for entry in entries:
                    name = entry.get('name') or entry['token']
                    pin = entry.get('pinned', False) or name in pinned
                    self.emit('INFO' if pin else 'WARN', 'brew: ' + name + (' is pinned' if pin else ' has an update'),
                              '{} -> {}'.format(entry.get('installed_versions', entry.get('installed', '?')),
                                                entry.get('current_version', '?')),
                              '' if pin else 'Run update-all, or review brew upgrade ' + shlex.quote(name))
                if not entries:
                    self.emit('OK', 'brew: no remaining updates')
            elif manager == 'mise':
                data = self.r.data('mise', 'outdated', '--json')
                for name, item in data.items():
                    self.emit('WARN', 'mise: update available for ' + name,
                              '{} -> {} (requested: {})'.format(item.get('current'), item.get('latest'), item.get('requested')),
                              'Run mise upgrade --yes (respects configured constraints).')
                if not data:
                    self.emit('OK', 'mise: configured versions are up to date')
            elif manager in ('npm', 'pnpm'):
                out, err, code = self.r.run([manager, 'outdated', '-g', '--json'], accepted=(0, 1))
                data = json.loads(out)
                if not isinstance(data, dict) or 'error' in data or (code and not data):
                    raise CheckError(err or out or 'outdated check failed')
                for name, item in data.items():
                    delegated = manager == 'pnpm' and name in ('pnpm', '@pnpm/exe')
                    self.emit('INFO' if delegated else 'WARN', manager + ': update available for ' + name,
                              '{} -> {}'.format(item.get('current'), item.get('latest')),
                              'Managed separately by the pnpm self-update command; review its version tag.' if delegated else 'Run update-all.')
                if not data:
                    self.emit('OK', manager + ': no remaining updates')
            elif manager == 'bun':
                with tempfile.TemporaryDirectory(prefix='update-all-bun-') as work:
                    out, err, code = self.r.run(['bun', 'outdated', '-g', '--no-save'], cwd=work)
                rows = [line for line in out.splitlines() if re.search(r'[│|].*[│|]', line)
                        and not re.search(r'Package\s*[│|]', line)]
                if rows:
                    self.emit('WARN', 'bun: updates available', out, 'Run update-all.')
                elif not out.strip() or 'up to date' in out.lower():
                    self.emit('OK', 'bun: no remaining updates')
                else:
                    self.emit('WARN', 'bun: could not interpret outdated result', out + '\n' + err,
                              'Review bun outdated -g --no-save.')
            elif manager == 'pipx':
                out = self.r.output('pipx', 'list', '--outdated', '--skip-maintenance')
                pins = {p['name'] for p in self.inventories[manager]['packages']
                        if p.get('pinned') or re.search(r'[<>=!~@/]', p.get('requested', ''))}
                found = False
                for line in out.splitlines():
                    if not line.strip():
                        continue
                    if line == 'pipx found no available upgrades.':
                        continue
                    if line == 'pipx found no index packages to check.':
                        self.emit('INFO', 'pipx: no index packages to check; source installs were not checked')
                        found = True
                        continue
                    match = re.match(r'^(\S+?)( \[pinned\])?: (\S+) -> (\S+)$', line)
                    if not match:
                        raise CheckError('unrecognized pipx outdated result: ' + line)
                    name, pinned, _, _ = match.groups()
                    found = True
                    self.emit('INFO' if name in pins or pinned else 'WARN', 'pipx: ' + line,
                              advice='' if name in pins or pinned else 'Run update-all.')
                if not found:
                    self.emit('OK', 'pipx: no remaining updates')
            elif manager == 'uv':
                out = self.r.output('uv', 'tool', 'list', '--outdated')
                updates = [line for line in out.splitlines() if 'latest:' in line]
                if updates:
                    constrained = {p['name']: p.get('requested') for p in self.inventories[manager]['packages']
                                   if p.get('requested')}
                    for line in updates:
                        name = line.split()[0]
                        self.emit('INFO' if name in constrained else 'WARN', 'uv: ' + line,
                                  'Required: ' + constrained[name] if name in constrained else '',
                                  'Review the saved constraint before changing versions.' if name in constrained else 'Run update-all.')
                elif not out:
                    self.emit('OK', 'uv: no remaining updates')
                else:
                    raise CheckError('unrecognized uv outdated result: ' + out)
        except (CheckError, ValueError, KeyError, TypeError, AttributeError) as exc:
            self.emit('WARN', manager + ': freshness check incomplete', str(exc),
                      'Retry update-all doctor --verbose; check network and manager support.')

    def receipt(self):
        path = state_path()
        if not path.exists():
            self.emit('INFO', 'No update history; the last update cannot be verified',
                      advice='A real update-all run will save a receipt.')
            return
        try:
            data = json.loads(path.read_text())
            if data.get('schema') != 1 or data.get('state') not in ('running', 'completed', 'interrupted'):
                raise ValueError('unsupported receipt schema or state')
            if not all(isinstance(data.get(k), dict) for k in ('before', 'after', 'results')):
                raise ValueError('incomplete receipt')
            self.emit('INFO', 'Last update: ' + data['started_at'], data['state'])
            if data['state'] != 'completed':
                self.emit('WARN', 'Last update did not finish', advice='Review failures and rerun update-all.')
            for name, result in data['results'].items():
                if name.startswith('command ') or name == 'custom commands':
                    self.emit('WARN' if result == 'failed' else 'INFO', 'Last update: ' + name + ': ' + result,
                              'Saved execution status only; effects have not been verified.')
                elif result in ('failed', 'warning'):
                    self.emit('WARN', 'Last update: ' + name + ': ' + result, advice='Review this update step.')
            for manager in MANAGERS:
                before = data['before'].get(manager, {})
                after = data['after'].get(manager, {})
                current = self.inventories.get(manager, {})
                if before.get('status') == 'error' or after.get('status') == 'error':
                    self.emit('WARN', manager + ': saved inventory is incomplete')
                if data['state'] == 'completed' and (not before or not after):
                    self.emit('WARN', manager + ': saved inventory is missing')
                if before.get('status') == 'ok' and after.get('status') in ('ok', 'absent'):
                    old = {p['name'] for p in before['packages']}
                    new = {p['name'] for p in after['packages']}
                    for name in sorted(old - new):
                        self.emit('ERROR', manager + ': disappeared during last update: ' + name,
                                  advice='Review the old runtime/prefix and reinstall the package if still needed.')
                if after.get('status') == 'ok' and current.get('status') in ('ok', 'absent'):
                    old = {p['name'] for p in after['packages']}
                    new = {p['name'] for p in current['packages']}
                    for name in sorted(old - new):
                        self.emit('WARN', manager + ': removed since last update: ' + name,
                                  'This may be an intentional later change.')
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            self.emit('WARN', 'Update history is unreadable', str(exc), 'Run update-all to create a new receipt.')

    def run(self):
        print('Update all doctor', flush=True)
        try:
            self.r.prepare_path()
        except CheckError as exc:
            self.emit('WARN', 'Updater environment could not be fully resolved', str(exc),
                      'Review mise configuration; runtime-dependent checks may be incomplete.')
        for manager in MANAGERS:
            if not self.inventory(manager):
                continue
            if manager == 'brew':
                self.check('Homebrew doctor', ['brew', 'doctor'], advice='Review the Homebrew recommendations.')
                self.check('Homebrew dependencies', ['brew', 'missing'], failure='ERROR',
                           advice='Review brew missing and reinstall affected packages.')
                self.check('Homebrew cleanup candidates', ['brew', 'cleanup', '--dry-run'], output_status='INFO',
                           advice='Review before running brew cleanup.')
                self.check('Homebrew unused dependency candidates', ['brew', 'autoremove', '--dry-run'], output_status='INFO',
                           advice='Review before running brew autoremove.')
            elif manager == 'mise':
                self.check('mise doctor', ['mise', 'doctor'], advice='Review mise doctor recommendations.')
                self.check('mise missing configured tools', ['mise', 'ls', '--missing', '--no-header'], output_status='ERROR',
                           advice='Review mise install.')
                self.check('mise unused version candidates', ['mise', 'ls', '--prunable', '--no-header'], output_status='INFO',
                           advice='Review mise prune --dry-run; other projects may still need these versions.')
            if not self.offline and manager in ('npm', 'pnpm', 'bun', 'pipx', 'uv') and not self.inventories[manager]['packages']:
                self.emit('INFO', manager + ': no global packages to check for updates')
            else:
                self.online(manager)
        self.paths()
        if not self.r.exists('softwareupdate'):
            self.emit('SKIP', 'macOS Software Update: unavailable')
        elif self.offline:
            self.emit('SKIP', 'macOS updates (--offline)')
        else:
            try:
                out, err, _ = self.r.run(['softwareupdate', '-l'], timeout=300)
                text = out + '\n' + err
                if 'No new software available' in text:
                    self.emit('OK', 'macOS: up to date')
                elif '* Label:' in text or '* ' in text:
                    self.emit('INFO', 'macOS updates available', text,
                              'Open System Settings > General > Software Update. update-all does not install these.')
                else:
                    self.emit('WARN', 'macOS update result could not be interpreted', text)
            except CheckError as exc:
                self.emit('WARN', 'macOS update check incomplete', str(exc), 'Retry softwareupdate -l.')
        self.receipt()
        print('\nSummary: ' + ', '.join('{} {}'.format(self.counts[s], s) for s in ('OK', 'WARN', 'ERROR', 'INFO', 'SKIP')))
        print('No packages were installed, repaired or removed. INFO candidates require review.')
        return 1 if self.counts['WARN'] or self.counts['ERROR'] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('doctor', 'start', 'finish', 'interrupt'))
    parser.add_argument('report', nargs='?')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    try:
        if args.action != 'doctor':
            if not args.report:
                parser.error('history actions require a report directory')
            history(args.action, args.report)
            return 0
        return Doctor(Runner(args.offline, args.verbose), args.offline,
                      os.environ.get('UPDATE_ALL_ORIGINAL_PATH')).run()
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, CheckError) as exc:
        print('Doctor unavailable: ' + str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
