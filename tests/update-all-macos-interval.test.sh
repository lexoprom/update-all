#!/usr/bin/env bash
set -euo pipefail
unset UPDATE_ALL_GLOBAL_MANAGERS UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS

# Tests for UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS: the macOS update check is
# skipped when a previous check succeeded within the interval.

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  printf '%s\n' "$1" | grep -F -- "$2" >/dev/null || fail "missing: $2"
}

assert_not_contains() {
  if printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; then
    fail "unexpected: $2"
  fi
}

make_fake_cmds() {
  local bindir="$1"
  ln -sf "$HOST_BASH" "$bindir/bash"

  local cmd
  for cmd in brew mise pipx npm pnpm bun uv; do
    cat > "$bindir/$cmd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "activate" ]]; then echo ":"; fi
exit 0
EOF
  done

  # Counts invocations; behaviour is controlled by files next to the script.
  cat > "$bindir/softwareupdate" <<'EOF'
#!/usr/bin/env bash
bindir="$(cd "$(dirname "$0")" && pwd)"
n="$(cat "$bindir/su-count" 2>/dev/null || echo 0)"
echo $((n + 1)) > "$bindir/su-count"
if [[ -f "$bindir/su-fail" ]]; then exit 7; fi
if [[ -f "$bindir/su-silent" ]]; then exit 0; fi
if [[ -f "$bindir/su-updates" ]]; then
  echo "Software Update found the following new or updated software:"
  echo "* Label: macOS 99.0"
  exit 0
fi
echo "No new software available."
exit 0
EOF
  # Fake macOS build; change it by writing to su-build.
  cat > "$bindir/sw_vers" <<'EOF'
#!/usr/bin/env bash
bindir="$(cd "$(dirname "$0")" && pwd)"
[[ "${1:-}" == "-buildVersion" ]] || exit 1
cat "$bindir/su-build" 2>/dev/null || echo TEST1
EOF
  chmod +x "$bindir/"*
}

setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin" "$case_dir/home" "$case_dir/lib"
  cp ./update-all "$case_dir/update-all"
  cp ./lib/*.sh ./lib/doctor.py "$case_dir/lib/"
  chmod +x "$case_dir/update-all"
  make_fake_cmds "$case_dir/bin"
}

run_case() {
  local case_dir="$1"
  shift
  HOME="$case_dir/home" XDG_STATE_HOME="$case_dir/home/.local/state" \
    UPDATE_ALL_RETRY_DELAY=0 UPDATE_ALL_TOOL_TIMEOUT=0 \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    env -u PNPM_HOME "$case_dir/update-all" "$@" 2>&1 | strip_ansi
}

su_count() { cat "$1/bin/su-count" 2>/dev/null || echo 0; }
state_file() { echo "$1/home/.local/state/update-all/macos-check"; }

# Run update-all expecting exit code $2; output goes to $OUT.
run_expect() {
  local d="$1" want="$2" rc=0
  shift 2
  OUT="$(run_case "$d" "$@")" || rc=$?
  [[ "$rc" -eq "$want" ]] || { printf '%s\n' "$OUT" >&2; fail "${FUNCNAME[1]}: expected exit $want, got $rc"; }
}

seed_state() {
  mkdir -p "$(dirname "$(state_file "$1")")"
  printf '%s\t%s\t%s\n' "$2" "$3" "${4:-TEST1}" > "$(state_file "$1")"
}

assert_count() {
  [[ "$(su_count "$1")" == "$2" ]] || fail "${FUNCNAME[1]}: expected $2 softwareupdate call(s), got $(su_count "$1")"
}

receipt_result() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["results"].get("macOS Updates", "missing"))' \
    "$1/home/.local/state/update-all/last-run.json"
}

test_second_run_is_skipped() {
  local d="$tmp/skip"; setup_case "$d"
  run_expect "$d" 0
  assert_count "$d" 1
  assert_contains "$(cat "$(state_file "$d")")" "up-to-date"
  run_expect "$d" 0
  assert_count "$d" 1
  assert_contains "$OUT" "Skipped (up to date as of"
  [[ "$(receipt_result "$d")" == skipped ]] || fail "receipt should record skipped, got $(receipt_result "$d")"
}

test_interval_zero_always_checks() {
  local d="$tmp/zero"; setup_case "$d"
  run_expect "$d" 0
  UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS=0 run_expect "$d" 0
  assert_count "$d" 2
}

test_force_intervals_checks() {
  local d="$tmp/force-intervals"; setup_case "$d"
  seed_state "$d" "$(date +%s)" up-to-date
  run_expect "$d" 0 --force-intervals
  assert_count "$d" 1
}

test_stale_state_checks() {
  local d="$tmp/stale"; setup_case "$d"
  seed_state "$d" "$(( $(date +%s) - 3 * 86400 ))" up-to-date
  run_expect "$d" 0
  assert_count "$d" 1
}

test_custom_interval_respected() {
  local d="$tmp/custom"; setup_case "$d"
  seed_state "$d" "$(( $(date +%s) - 3 * 86400 ))" up-to-date
  UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS=7 run_expect "$d" 0
  assert_count "$d" 0
  # A leading zero must be read as decimal, not octal.
  UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS=08 run_expect "$d" 0
  assert_count "$d" 0
}

test_bad_state_checks() {
  local d="$tmp/bad"; setup_case "$d"
  local n=0 contents
  # future timestamp, garbage, leading-zero (octal) epoch, overflowing epoch,
  # pre-build two-field format
  for contents in "$(( $(date +%s) + 86400 ))"$'\tup-to-date\tTEST1' "garbage" \
                  $'0999\tup-to-date\tTEST1' $'99999999999999999999\tup-to-date\tTEST1' \
                  "$(date +%s)"$'\tup-to-date'; do
    mkdir -p "$(dirname "$(state_file "$d")")"
    printf '%s\n' "$contents" > "$(state_file "$d")"
    run_expect "$d" 0
    n=$((n + 1))
    assert_count "$d" "$n"
    assert_contains "$OUT" "Up to date"
    [[ "$(receipt_result "$d")" == ok ]] || fail "state '$contents': receipt should be ok, got $(receipt_result "$d")"
  done
}

test_unreadable_state_is_quiet() {
  [[ "$(id -u)" -ne 0 ]] || return 0
  local d="$tmp/unreadable"; setup_case "$d"
  seed_state "$d" "$(date +%s)" up-to-date
  chmod 000 "$(state_file "$d")"
  run_expect "$d" 0
  chmod 600 "$(state_file "$d")"
  assert_count "$d" 1
  assert_not_contains "$OUT" "Permission denied"
}

test_cached_updates_stay_a_warning() {
  local d="$tmp/cached"; setup_case "$d"
  touch "$d/bin/su-updates"
  run_expect "$d" 0
  assert_contains "$(cat "$(state_file "$d")")" "updates-available"
  run_expect "$d" 0
  assert_count "$d" 1
  assert_contains "$OUT" "Updates available (cached, checked"
  assert_contains "$OUT" "--force-intervals to recheck"
  [[ "$(receipt_result "$d")" == warning ]] || fail "receipt should record warning, got $(receipt_result "$d")"
}

test_build_change_invalidates_cache() {
  local d="$tmp/build"; setup_case "$d"
  touch "$d/bin/su-updates"
  run_expect "$d" 0
  assert_contains "$(cat "$(state_file "$d")")" $'updates-available\tTEST1'
  # The update gets installed: macOS build changes, so the cache is dropped.
  echo TEST2 > "$d/bin/su-build"
  rm "$d/bin/su-updates"
  run_expect "$d" 0
  assert_count "$d" 2
  assert_contains "$OUT" "Up to date"
  assert_not_contains "$OUT" "cached"
  assert_contains "$(cat "$(state_file "$d")")" $'up-to-date\tTEST2'
  run_expect "$d" 0
  assert_count "$d" 2
}

test_unrecognized_output_not_cached() {
  local d="$tmp/unrecognized"; setup_case "$d"
  touch "$d/bin/su-silent"
  run_expect "$d" 0
  assert_contains "$OUT" "Unrecognized output"
  [[ ! -f "$(state_file "$d")" ]] || fail "unrecognized output must not be cached"
  run_expect "$d" 0
  assert_count "$d" 2
}

test_failed_check_writes_no_state() {
  local d="$tmp/failed"; setup_case "$d"
  touch "$d/bin/su-fail"
  run_expect "$d" 1
  [[ ! -f "$(state_file "$d")" ]] || fail "failed check must not write state"
  run_expect "$d" 1
  assert_count "$d" 2
}

test_leftover_temp_files_removed() {
  local d="$tmp/leftover"; setup_case "$d"
  mkdir -p "$(dirname "$(state_file "$d")")"
  touch "$(dirname "$(state_file "$d")")/.macos-check.AbC123"
  run_expect "$d" 0
  [[ ! -e "$(dirname "$(state_file "$d")")/.macos-check.AbC123" ]] || fail "leftover temp file not removed"
}

test_invalid_value_rejected() {
  local d="$tmp/invalid"; setup_case "$d"
  local v
  for v in abc -1 1.5 123456 99999999999999999999; do
    UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS="$v" run_expect "$d" 1
    assert_contains "$OUT" "UPDATE_ALL_MACOS_CHECK_INTERVAL_DAYS"
  done
  assert_count "$d" 0
}

test_dry_run_ignores_state() {
  local d="$tmp/dry"; setup_case "$d"
  run_expect "$d" 0 --dry-run
  [[ ! -f "$(state_file "$d")" ]] || fail "dry run must not write state"
  seed_state "$d" "$(date +%s)" up-to-date
  run_expect "$d" 0 --dry-run
  assert_contains "$OUT" "Dry run"
  assert_not_contains "$OUT" "Skipped (up to date"
  assert_count "$d" 0
}

tmp="$(mktemp -d)"
HOST_BASH="$(command -v bash)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

test_second_run_is_skipped
test_interval_zero_always_checks
test_force_intervals_checks
test_stale_state_checks
test_custom_interval_respected
test_bad_state_checks
test_unreadable_state_is_quiet
test_cached_updates_stay_a_warning
test_build_change_invalidates_cache
test_unrecognized_output_not_cached
test_failed_check_writes_no_state
test_leftover_temp_files_removed
test_invalid_value_rejected
test_dry_run_ignores_state

echo "PASS"
