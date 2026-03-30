#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/tool-runner.sh"

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

append_status() {
  printf '%s\t%s\n' "$1" "$2" >> "$REPORT_DIR/status.log"
}

progress_sink() {
  printf '[%s/%s] %s\n' "$1" "$2" "$3" >> "$CASE_DIR/progress.log"
}

phase1_a_enabled() { return 0; }
phase1_a_run() {
  sleep 0.1
  append_status "Tool A" "✅ Success"
  : > "$CASE_DIR/phase1-a.done"
}
phase1_a_components() { printf '%s\n' "Tool A"; }

phase1_b_enabled() { return 0; }
phase1_b_run() {
  sleep 0.1
  append_status "Tool B" "✅ Success"
  : > "$CASE_DIR/phase1-b.done"
}
phase1_b_components() { printf '%s\n' "Tool B"; }

phase2_enabled() { return 0; }
phase2_run() {
  [[ -f "$CASE_DIR/phase1-a.done" ]] || fail "phase2 ran before phase1 tool A finished"
  [[ -f "$CASE_DIR/phase1-b.done" ]] || fail "phase2 ran before phase1 tool B finished"
  append_status "Tool C" "✅ Success"
}
phase2_components() { printf '%s\n' "Tool C"; }

post_enabled() { return 0; }
post_run() {
  append_status "Tool D" "✅ Success"
}
post_components() { printf '%s\n' "Tool D"; }

disabled_post_enabled() { return 1; }
disabled_post_run() { fail "disabled post tool should not run"; }
disabled_post_disabled() {
  append_status "custom commands" "⏭️ Skipped"
}
disabled_post_components() { printf '%s\n' "custom commands"; }

setup_case() {
  CASE_DIR="$tmp/$1"
  REPORT_DIR="$CASE_DIR/report"
  mkdir -p "$REPORT_DIR"
  : > "$CASE_DIR/progress.log"
}

test_tool_runner_executes_phases_and_summary_at_boundary() {
  setup_case "scheduler"

  cat > "$REPORT_DIR/commands.index" <<'EOF'
command 01	echo one
command 02	echo two
EOF

  tool_runner_reset
  tool_runner_define_phase "phase1" "parallel" "...waiting phase1..."
  tool_runner_define_phase "phase2" "parallel" "...waiting phase2..."
  tool_runner_define_phase "post" "serial"

  tool_runner_register "a" "phase1" "Tool A step" phase1_a_enabled phase1_a_run phase1_a_components
  tool_runner_register "b" "phase1" "Tool B step" phase1_b_enabled phase1_b_run phase1_b_components
  tool_runner_register "c" "phase2" "Tool C step" phase2_enabled phase2_run phase2_components
  tool_runner_register "d" "post" "Tool D step" post_enabled post_run post_components
  tool_runner_register "disabled" "post" "Disabled step" disabled_post_enabled disabled_post_run disabled_post_components disabled_post_disabled

  local out
  out="$(tool_runner_execute "$REPORT_DIR" progress_sink | strip_ansi)"

  local progress
  progress="$(< "$CASE_DIR/progress.log")"
  assert_contains "$progress" "[1/4] Tool A step"
  assert_contains "$progress" "[2/4] Tool B step"
  assert_contains "$progress" "[3/4] Tool C step"
  assert_contains "$progress" "[4/4] Tool D step"

  local statuses
  statuses="$(< "$REPORT_DIR/status.log")"
  assert_contains "$statuses" $'Tool A\t✅ Success'
  assert_contains "$statuses" $'Tool B\t✅ Success'
  assert_contains "$statuses" $'Tool C\t✅ Success'
  assert_contains "$statuses" $'Tool D\t✅ Success'
  assert_contains "$statuses" $'custom commands\t⏭️ Skipped'

  assert_contains "$out" "...waiting phase1..."
  assert_contains "$out" "...waiting phase2..."
  assert_contains "$out" "Tool A:"
  assert_contains "$out" "Tool B:"
  assert_contains "$out" "Tool C:"
  assert_contains "$out" "Tool D:"
  assert_contains "$out" "custom commands:"
  assert_contains "$out" "Custom commands"
  assert_contains "$out" "- echo one"
  assert_contains "$out" "- echo two"
}

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

test_tool_runner_executes_phases_and_summary_at_boundary

echo "PASS"
