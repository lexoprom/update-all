# update-all

A Bash updater for Homebrew, mise runtimes, npm/pnpm/Bun global packages,
pipx/uv tools, and commands in `update-all.commands`. macOS updates are listed,
not installed. Requires Bash 4.4+ (the script finds Homebrew Bash on macOS).

```sh
update-all                         # Update installed tools and run custom commands
update-all --dry-run               # Preview update commands
update-all list --versions         # List installed packages
update-all doctor                 # Diagnose locally and check available updates
update-all doctor --offline        # Local checks only
update-all doctor --verbose        # Include commands and full diagnostics
```

Stages run in order: Homebrew and the macOS update check in parallel, then
Homebrew casks marked `auto_updates` (`brew upgrade --cask --greedy-auto-updates`,
serial because pkg installers may prompt for a sudo password), then mise (after
Homebrew, which may upgrade mise itself), then global package managers, then
custom commands.

Custom commands run at most once every `UPDATE_ALL_COMMANDS_INTERVAL_DAYS` days
(default 7; 0 runs them every time). A run is recorded only when every command
succeeds, and editing the commands file triggers a run. `--force-commands`
runs them now regardless.

Each update command is stopped after `UPDATE_ALL_TOOL_TIMEOUT` seconds
(default 3600; 0 disables), so a wedged tool cannot hang the run or keep its
lock. Ctrl-C stops running commands, including parallel stages.

`UPDATE_ALL_GLOBAL_MANAGERS` selects the global package managers to update
(space-separated, default `pipx npm pnpm bun uv`). Set it to an empty string
when mise owns all global CLIs: the stage is skipped, so `npm install -g` never
reinstalls or restores globals outside mise.

```sh
export UPDATE_ALL_GLOBAL_MANAGERS=""      # mise-only setup
export UPDATE_ALL_GLOBAL_MANAGERS="npm uv"
```

`UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS` (default `2`) skips the macOS update
check when a previous check succeeded within that many days; `0` checks on every
run. The last successful check is stored in
`${XDG_STATE_HOME:-$HOME/.local/state}/update-all/macos-check`. Failed checks and
`--dry-run` never update it, and unrecognized `softwareupdate` output is not
cached. A cached result is dropped once the macOS build changes (for example
after installing an update). If the last check found pending updates, skipped
runs still report them as a warning.

```sh
UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS=0 update-all   # force a check now
```

Two Homebrew steps also run on an interval (both default 7 days; 0 runs them
every time): the `auto_updates` cask upgrade (`UPDATE_ALL_CASKS_INTERVAL_DAYS`),
since most of those apps update themselves and upgrading reinstalls running
apps, and `brew cleanup` (`UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS`), since
`brew upgrade` already removes the versions it replaces. Only successful real
runs are recorded, in `brew-casks` and `brew-cleanup` next to `macos-check`.

`--force-intervals` ignores every interval (macOS check, custom commands, casks,
cleanup) for one run.

## Doctor

Doctor checks manager inventories, missing installations and executables,
Python environment dependencies, PATH differences, remaining updates, and
Homebrew/mise cleanup candidates. It never runs the custom commands file or
installs, repairs, or removes packages. Online checks refresh Homebrew metadata;
package managers may maintain caches and logs. `--offline` skips remote version
and macOS update checks.

Python 3.8+ is required for doctor and update receipts; no Python dependencies
need installing. Checks run from your home directory, like the updater, rather
than the caller's project. Each command has a 120-second timeout (300 seconds
for macOS). A failed or unsupported check is reported, never treated as an empty
inventory or proof that everything is current.

- `OK`: the check passed.
- `WARN`: updates, incomplete checks, or a configuration worth reviewing.
- `ERROR`: a broken installation or packages lost during the last update.
- `INFO`: context, intentional constraints, duplicates, or cleanup candidates.
- `SKIP`: a missing manager or an explicitly disabled online check.

Exit codes: **0** without warnings/errors, **1** with findings or incomplete
checks, **2** for usage/startup failure (including an active updater).
Doctor does not take over or remove another updater's lock.

Old runtimes and duplicates are candidates, not proof of unused software.
Mise constraints and Homebrew/pipx pins are respected. When a Python tool has a
saved version constraint, newer registry versions are informational and need
review. Arbitrary source installs and custom-command effects cannot be fully
verified; custom commands are represented only by their saved execution status.

Read-only mise calls use the global dry-run flag, disable automatic installation
and hooks, and resolve shims without running arbitrary tool commands. This also
suppresses mise's scheduled cleanup of old runtimes; see
[mise command startup](https://github.com/jdx/mise/blob/main/src/cli/mod.rs).

## Update receipts

Real update runs atomically save a private, versioned JSON receipt at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/update-all/last-run.json
```

It contains timestamps, completion state, step results, and inventories before
and after updating, including package versions and installation paths. It does
not contain custom-command text or raw command logs. Only the latest run is kept.
If Python is missing or storage fails, updates continue with a warning.

Doctor distinguishes packages lost during an update from removals made later.
Missing or invalid snapshots are not interpreted as empty installations.
Interrupted runs remain marked unfinished. Existing installations without a
receipt still receive current-state checks; a future real update creates history.
`doctor`, `list`, and `--dry-run` do not replace it.

## Tests

Run the isolated fake-manager suites (no real updates):

```sh
for test in tests/*.test.sh; do bash "$test" || break; done
python3 tests/update-all-timeout.test.py && python3 tests/update-all-interrupt.test.py
```
