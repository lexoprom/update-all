#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/custom-commands.sh"

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="${3:-value}"
  if [[ "$expected" != "$actual" ]]; then
    fail "$label: expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    fail "unexpected: $needle"
  fi
}

status_sink() {
  printf '%s\t%s\n' "$1" "$2" >> "$STATUS_FILE"
}

test_runner() {
  local label="$1"
  local line="$2"
  printf '%s\t%s\n' "$label" "$line" >> "$CASE_DIR/run.log"
  if [[ "$line" == "false" ]]; then
    return 1
  fi
  bash -lc "$line"
}

setup_case() {
  CASE_DIR="$tmp/$1"
  mkdir -p "$CASE_DIR/report" "$CASE_DIR/home"
  STATUS_FILE="$CASE_DIR/status.log"
  : > "$STATUS_FILE"
  : > "$CASE_DIR/run.log"
}

test_custom_commands_should_run_and_disabled_status() {
  setup_case "enabled"
  local file="$CASE_DIR/commands.txt"

  cat > "$file" <<'EOF'
# comment

echo one
EOF

  custom_commands_should_run false "$file"
  custom_commands_handle_disabled true status_sink
  custom_commands_handle_disabled false status_sink

  local statuses
  statuses="$(< "$STATUS_FILE")"
  assert_contains "$statuses" $'custom commands\t⏭️ Skipped'
  assert_contains "$statuses" $'custom commands\t⏭️ No commands file'
}

test_custom_commands_dry_run_indexes_and_reports_boundary() {
  setup_case "dry-run"
  local file="$CASE_DIR/commands.txt"
  declare -A result=()

  cat > "$file" <<EOF
# comment

echo one
 echo two 
echo dry > "$CASE_DIR/should-not-exist.txt"
EOF

  custom_commands_run result "$file" "$CASE_DIR/report" true status_sink test_runner > "$CASE_DIR/output.log" 2>&1
  local out
  out="$(< "$CASE_DIR/output.log")"
  out="$(printf '%s' "$out" | strip_ansi)"

  assert_eq "3" "${result[count]}" "command count"
  assert_eq "0" "${result[failures]}" "failure count"
  [[ ! -f "$CASE_DIR/should-not-exist.txt" ]] || fail "dry run executed command"

  local idx
  idx="$(< "$CASE_DIR/report/commands.index")"
  assert_contains "$idx" $'command 01\techo one'
  assert_contains "$idx" $'command 02\techo two'
  assert_contains "$idx" "should-not-exist.txt"

  local statuses
  statuses="$(< "$STATUS_FILE")"
  assert_contains "$statuses" $'command 01\t🔍 Dry run'
  assert_contains "$statuses" $'command 02\t🔍 Dry run'
  assert_contains "$statuses" $'command 03\t🔍 Dry run'
  assert_contains "$statuses" $'custom commands\t✅ Completed (3)'
  assert_contains "$out" "Would execute: echo one"
  assert_contains "$out" "Would execute: echo two"
}

test_custom_commands_failures_do_not_stop_next_boundary() {
  setup_case "failure-continue"
  local file="$CASE_DIR/commands.txt"
  declare -A result=()

  cat > "$file" <<EOF
false
echo ok > "$CASE_DIR/ok.txt"
EOF

  set +e
  custom_commands_run result "$file" "$CASE_DIR/report" false status_sink test_runner > "$CASE_DIR/output.log" 2>&1
  local exit_code=$?
  set -e

  assert_eq "1" "$exit_code" "boundary exit"
  assert_eq "2" "${result[count]}" "command count"
  assert_eq "1" "${result[failures]}" "failure count"
  [[ -f "$CASE_DIR/ok.txt" ]] || fail "second command did not run"

  local statuses
  statuses="$(< "$STATUS_FILE")"
  assert_contains "$statuses" $'custom commands\t❌ Failed (1 of 2)'

  local run_log
  run_log="$(< "$CASE_DIR/run.log")"
  assert_contains "$run_log" $'command 01\tfalse'
  assert_contains "$run_log" $'command 02'
}

test_custom_commands_default_runner_handles_optional_repo_script() {
  setup_case "optional-repo"
  declare -A result=()

  local old_home="$HOME"
  HOME="$CASE_DIR/home"
  set +e
  custom_commands_run result "$SCRIPT_DIR/update-all.commands" "$CASE_DIR/report" false status_sink > "$CASE_DIR/output.log" 2>&1
  local exit_code=$?
  set -e
  HOME="$old_home"

  assert_eq "0" "$exit_code" "optional repo exit"
  assert_eq "2" "${result[count]}" "optional repo count"
  assert_eq "0" "${result[failures]}" "optional repo failures"

  local out
  out="$(< "$CASE_DIR/output.log")"
  assert_contains "$out" "Skipping ~/.codex/superpowers: repo not present"
  assert_contains "$out" "Skipping ~/.agents/skills/pi-skills: repo not present"

  local statuses
  statuses="$(< "$STATUS_FILE")"
  assert_contains "$statuses" $'custom commands\t✅ Completed (2)'
}

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

test_custom_commands_should_run_and_disabled_status
test_custom_commands_dry_run_indexes_and_reports_boundary
test_custom_commands_failures_do_not_stop_next_boundary
test_custom_commands_default_runner_handles_optional_repo_script

echo "PASS"
