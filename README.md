# update-all

A Bash updater for Homebrew, mise runtimes, npm/pnpm/Bun global packages,
pipx/uv tools, and commands in `update-all.commands`. macOS updates are listed,
not installed. Requires Bash 4.3+ (the script finds Homebrew Bash on macOS).

```sh
update-all                         # Update installed tools and run custom commands
update-all --dry-run               # Preview update commands
update-all list --versions         # List installed packages
update-all doctor                 # Diagnose locally and check available updates
update-all doctor --offline        # Local checks only
update-all doctor --verbose        # Include commands and full diagnostics
```

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
```
