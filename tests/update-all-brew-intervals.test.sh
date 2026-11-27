#!/usr/bin/env bash
set -euo pipefail
unset UPDATE_ALL_GLOBAL_MANAGERS UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS UPDATE_ALL_COMMANDS_INTERVAL_DAYS \
  UPDATE_ALL_CASKS_INTERVAL_DAYS UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS

# Tests for UPDATE_ALL_CASKS_INTERVAL_DAYS and UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS:
# the greedy cask upgrade and `brew cleanup` are skipped when they succeeded
# within the interval.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
SCRIPT_BIN="update-all-brew-intervals-$$"

make_fake_cmds() {
  local bindir="$1" cmd
  ln -sf "$HOST_BASH" "$bindir/bash"
  for cmd in mise pipx npm pnpm bun uv; do
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == activate ]] && echo ":"\nexit 0\n' > "$bindir/$cmd"
  done
  printf '#!/usr/bin/env bash\necho "No new software available."\n' > "$bindir/softwareupdate"
  printf '#!/usr/bin/env bash\necho TEST1\n' > "$bindir/sw_vers"
  # Logs each call; a brew-fail-<cleanup|casks> file makes that step fail.
  cat > "$bindir/brew" <<'BREW'
#!/usr/bin/env bash
bindir="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$bindir/brew-calls"
[[ "$1" == cleanup && -f "$bindir/brew-fail-cleanup" ]] && exit 3
[[ "$*" == *--greedy-auto-updates* && -f "$bindir/brew-fail-casks" ]] && exit 4
exit 0
BREW
  chmod +x "$bindir/"*
}

setup_case() {
  mkdir -p "$1/bin" "$1/home" "$1/lib"
  cp ./update-all "$1/$SCRIPT_BIN"
  cp ./lib/*.sh ./lib/doctor.py "$1/lib/"
  printf '# no commands\n' > "$1/update-all.commands"
  make_fake_cmds "$1/bin"
}

run_case() {
  local case_dir="$1"; shift
  HOME="$case_dir/home" XDG_STATE_HOME="$case_dir/home/.local/state" \
    UPDATE_ALL_GLOBAL_MANAGERS="" UPDATE_ALL_RETRY_DELAY=0 UPDATE_ALL_TOOL_TIMEOUT=0 \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    env -u PNPM_HOME "$case_dir/$SCRIPT_BIN" "$@" 2>&1 | strip_ansi
}

run_expect() {
  local d="$1" want="$2" rc=0
  shift 2
  OUT="$(run_case "$d" "$@")" || rc=$?
  [[ "$rc" -eq "$want" ]] || { printf '%s\n' "$OUT" >&2; fail "${FUNCNAME[1]}: expected exit $want, got $rc"; }
}

cleanups() { grep -c '^cleanup$' "$1/bin/brew-calls" 2>/dev/null || true; }
cask_upgrades() { grep -c -- '--greedy-auto-updates' "$1/bin/brew-calls" 2>/dev/null || true; }
expect_counts() {
  [[ "$(cleanups "$1")" == "$2" ]] || fail "${FUNCNAME[1]}: expected $2 cleanup(s), got $(cleanups "$1")"
  [[ "$(cask_upgrades "$1")" == "$3" ]] || fail "${FUNCNAME[1]}: expected $3 cask upgrade(s), got $(cask_upgrades "$1")"
}
state() { echo "$1/home/.local/state/update-all/$2"; }
summary_line() { printf '%s\n' "$OUT" | grep -F "$1" | tail -n1; }
receipt_result() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["results"].get(sys.argv[2], "missing"))' \
    "$1/home/.local/state/update-all/last-run.json" "$2"
}

test_second_run_skips_both() {
  local d="$tmp/skip"; setup_case "$d"
  run_expect "$d" 0
  expect_counts "$d" 1 1
  [[ -f "$(state "$d" brew-cleanup)" && -f "$(state "$d" brew-casks)" ]] || fail "state not written"
  run_expect "$d" 0
  expect_counts "$d" 1 1
  assert_contains "$(summary_line "Homebrew cleanup")" "Skipped (last run"
  assert_contains "$(summary_line "Homebrew casks")" "Success"
  assert_contains "$(summary_line "Homebrew auto-update casks")" "Skipped (last run"
  assert_eq "skipped" "$(receipt_result "$d" "Homebrew cleanup")"
  assert_eq "ok" "$(receipt_result "$d" "stage:homebrew_casks")"
  # Formulae upgrade in parallel phase1 on every run; regular casks run
  # serially when auto-update casks are skipped by the interval.
  [[ "$(grep -c '^upgrade --formula$' "$d/bin/brew-calls")" == 2 ]] || fail "brew upgrade --formula did not run twice"
  [[ "$(grep -c '^upgrade --cask$' "$d/bin/brew-calls")" == 1 ]] || fail "brew upgrade --cask did not run once on skipped interval"
}

test_stale_state_runs() {
  local d="$tmp/stale"; setup_case "$d"
  mkdir -p "$(dirname "$(state "$d" brew-cleanup)")"
  echo "$(( $(date +%s) - 8 * 86400 ))" > "$(state "$d" brew-cleanup)"
  echo "$(( $(date +%s) - 8 * 86400 ))" > "$(state "$d" brew-casks)"
  run_expect "$d" 0
  expect_counts "$d" 1 1
  UPDATE_ALL_CASKS_INTERVAL_DAYS=30 UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS=30 run_expect "$d" 0
  expect_counts "$d" 1 1
}

test_zero_and_force_run() {
  local d="$tmp/force"; setup_case "$d"
  run_expect "$d" 0
  UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS=0 run_expect "$d" 0
  expect_counts "$d" 2 1
  UPDATE_ALL_CASKS_INTERVAL_DAYS=0 run_expect "$d" 0
  expect_counts "$d" 2 2
  run_expect "$d" 0 --force-intervals
  expect_counts "$d" 3 3
}

test_failures_are_retried() {
  local d="$tmp/fail"; setup_case "$d"
  touch "$d/bin/brew-fail-cleanup" "$d/bin/brew-fail-casks"
  run_expect "$d" 1
  [[ ! -e "$(state "$d" brew-cleanup)" && ! -e "$(state "$d" brew-casks)" ]] || fail "failure recorded as success"
  [[ "$(receipt_result "$d" "stage:homebrew")" == failed ]] || fail "homebrew stage should fail"
  rm "$d/bin/brew-fail-cleanup" "$d/bin/brew-fail-casks"
  run_expect "$d" 0
  expect_counts "$d" 2 2
}

test_upgrade_failure_fails_stage_when_cleanup_skipped() {
  local d="$tmp/upgrade-fail"; setup_case "$d"
  run_expect "$d" 0
  # Make `brew upgrade --formula` fail on the next run.
  perl -0pi -e 's/exit 0\n\z/[[ "\$*" == "upgrade --formula" ]] \&\& exit 5\nexit 0\n/' "$d/bin/brew"
  run_expect "$d" 1
  [[ "$(receipt_result "$d" "stage:homebrew")" == failed ]] || fail "stage should report the upgrade failure"
}

test_dry_run_records_nothing() {
  local d="$tmp/dry"; setup_case "$d"
  run_expect "$d" 0 --dry-run
  [[ ! -e "$(state "$d" brew-cleanup)" && ! -e "$(state "$d" brew-casks)" ]] || fail "dry run wrote state"
}

test_invalid_values_rejected() {
  local d="$tmp/invalid"; setup_case "$d"
  OUT="$(UPDATE_ALL_CASKS_INTERVAL_DAYS=-1 run_case "$d" --dry-run || true)"
  assert_contains "$OUT" "UPDATE_ALL_CASKS_INTERVAL_DAYS: expected a whole number"
  OUT="$(UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS=x run_case "$d" --dry-run || true)"
  assert_contains "$OUT" "UPDATE_ALL_BREW_CLEANUP_INTERVAL_DAYS: expected a whole number"
}

test_stale_cask_app_is_trashed_and_upgrade_retried() {
  local d="$tmp/stale-app"; setup_case "$d"
  local stale="$d/caskroom/claude/1.0/Claude.app"
  mkdir -p "$stale"
  # `brew upgrade --cask` fails while the stale Caskroom app exists, like Homebrew.
  perl -0pi -e 's|exit 0\n\z|[[ "\$1" == --caskroom ]] \&\& { echo "\$bindir/../caskroom"; exit 0; }\nif [[ "\$*" == "upgrade --cask --greedy-auto-updates" \&\& -d "\$bindir/../caskroom/claude/1.0/Claude.app" ]]; then\n  echo "Error: claude: It seems there is already an App at \x27\$bindir/../caskroom/claude/1.0/Claude.app\x27." >\&2; exit 1\nfi\nexit 0\n|' "$d/bin/brew"
  run_expect "$d" 0
  [[ ! -e "$stale" ]] || fail "stale app not removed"
  ls "$d/home/.Trash" | grep -q '^Claude-stale-.*\.app$' || fail "stale app not in Trash"
  [[ "$(grep -c '^upgrade --cask --greedy-auto-updates$' "$d/bin/brew-calls")" == 2 ]] || fail "upgrade not retried"
  assert_contains "$(summary_line "Homebrew casks")" "Success"
  [[ -z "$(summary_line "Homebrew auto-update casks")" ]] || fail "greedy run logged a separate auto-update row"
}

tmp="$(mktemp -d)"
HOST_BASH="$(command -v bash)"
trap 'rm -rf "$tmp"' EXIT

test_second_run_skips_both
test_stale_state_runs
test_zero_and_force_run
test_failures_are_retried
test_upgrade_failure_fails_stage_when_cleanup_skipped
test_dry_run_records_nothing
test_invalid_values_rejected
test_stale_cask_app_is_trashed_and_upgrade_retried

echo "PASS"
