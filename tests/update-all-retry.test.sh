#!/usr/bin/env bash
set -euo pipefail

# Tests for retry behavior of mise tool upgrades (transient aube/npm stream
# errors) and for exit-code propagation when updates fail.

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

make_fake_cmds() {
  local bindir="$1"

  ln -sf "$HOST_BASH" "$bindir/bash"

  cat > "$bindir/brew" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  # mise: `upgrade` fails the first N invocations (N read from
  # mise-fail-times next to this script) with the same transient aube stream
  # error seen in the wild, then succeeds. Attempt count is persisted in
  # mise-upgrade-count.
  cat > "$bindir/mise" <<'EOF'
#!/usr/bin/env bash
bindir="$(cd "$(dirname "$0")" && pwd)"
if [[ "${1:-}" == "activate" ]]; then
  echo ":"
  exit 0
fi
if [[ "${1:-}" == "upgrade" ]]; then
  fail_times="$(cat "$bindir/mise-fail-times" 2>/dev/null || echo 1)"
  count_file="$bindir/mise-upgrade-count"
  n="$(cat "$count_file" 2>/dev/null || echo 0)"
  n=$((n + 1))
  echo "$n" > "$count_file"
  if (( n <= fail_times )); then
    echo "mise ERROR Failed to install tools: npm:agent-browser@latest: aube install failed: stream error for agent-browser@0.38.1: HTTP error: error decoding response body" >&2
    exit 1
  fi
fi
exit 0
EOF

  cat > "$bindir/softwareupdate" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-l" ]]; then
  echo "No new software available."
  exit 0
fi
exit 0
EOF

  cat > "$bindir/pipx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/pnpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/bun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$bindir/"*
}

setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin" "$case_dir/home" "$case_dir/lib"
  cp ./update-all "$case_dir/update-all"
  cp ./lib/global-packages.sh "$case_dir/lib/global-packages.sh"
  cp ./lib/custom-commands.sh "$case_dir/lib/custom-commands.sh"
  cp ./lib/tool-runner.sh "$case_dir/lib/tool-runner.sh"
  cp ./lib/pm-helpers.sh "$case_dir/lib/pm-helpers.sh"
  cp ./lib/doctor.py "$case_dir/lib/doctor.py"
  chmod +x "$case_dir/update-all"
  make_fake_cmds "$case_dir/bin"
}

run_case() {
  local case_dir="$1"
  shift
  HOME="$case_dir/home" XDG_STATE_HOME="$case_dir/home/.local/state" \
    UPDATE_ALL_RETRY_DELAY="${UPDATE_ALL_RETRY_DELAY:-0}" \
    UPDATE_ALL_TOOL_TIMEOUT="${UPDATE_ALL_TOOL_TIMEOUT:-0}" \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    env -u PNPM_HOME "$case_dir/update-all" "$@" 2>&1 | strip_ansi
}

test_mise_retry_recovers_from_transient_error() {
  local case_dir="$tmp/recover"
  setup_case "$case_dir"
  echo 1 > "$case_dir/bin/mise-fail-times"

  # An inherited pnpm installation must never override the fake commands.
  local PNPM_HOME="$tmp/inherited-pnpm"
  export PNPM_HOME
  mkdir -p "$PNPM_HOME/bin"
  cat > "$PNPM_HOME/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: inherited pnpm was invoked" >&2
exit 99
EOF
  chmod +x "$PNPM_HOME/bin/pnpm"

  local out rc=0
  set +e
  out="$(run_case "$case_dir")"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "expected exit 0 after successful retry, got $rc"
  assert_contains "$out" "retrying in 0s (attempt 2/2)"
  assert_contains "$out" "mise tool upgrades"
  assert_contains "$out" "Success"
  assert_not_contains "$out" "Failed (exit code"
  assert_not_contains "$out" "inherited pnpm was invoked"
}

test_mise_retry_exhausted_reports_failure() {
  local case_dir="$tmp/exhausted"
  setup_case "$case_dir"
  echo 99 > "$case_dir/bin/mise-fail-times"

  local out rc=0
  set +e
  out="$(run_case "$case_dir")"
  rc=$?
  set -e

  [[ "$rc" -eq 1 ]] || fail "expected exit 1 when all attempts fail, got $rc"
  assert_contains "$out" "retrying in 0s (attempt 2/2)"
  assert_contains "$out" "mise tool upgrades failed (exit code 1)"
  assert_contains "$out" "stream error for agent-browser@0.38.1"
  assert_contains "$out" "Failed (exit code: 1)"
  # reshim still runs after a failed upgrade
  assert_contains "$out" "mise reshim"
}

test_dry_run_does_not_retry() {
  local case_dir="$tmp/dry"
  setup_case "$case_dir"
  echo 1 > "$case_dir/bin/mise-fail-times"

  local out rc=0
  set +e
  out="$(run_case "$case_dir" --dry-run)"
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "expected exit 0 for dry run, got $rc"
  assert_contains "$out" "Would execute: mise upgrade --yes"
  assert_not_contains "$out" "retrying in"
  [[ ! -f "$case_dir/bin/mise-upgrade-count" ]] || fail "dry run executed mise"
}

test_macos_check_failure_fails_run() {
  local case_dir="$tmp/macos-failure"
  setup_case "$case_dir"
  echo 0 > "$case_dir/bin/mise-fail-times"
  cat > "$case_dir/bin/softwareupdate" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF

  local out rc=0
  out="$(run_case "$case_dir")" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "expected exit 1 on macOS check failure, got $rc"
  assert_contains "$out" "Check failed"
  assert_contains "$out" "1 failed"
}

test_macos_check_timeout_fails_run_but_completes() {
  local case_dir="$tmp/macos-timeout"
  setup_case "$case_dir"
  echo 0 > "$case_dir/bin/mise-fail-times"
  cat > "$case_dir/bin/softwareupdate" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF

  local out rc=0
  out="$(UPDATE_ALL_TOOL_TIMEOUT=1 run_case "$case_dir")" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "expected exit 1 on macOS timeout, got $rc"
  assert_contains "$out" "Check failed"
  assert_contains "$out" "1 failed"
  assert_contains "$out" "Finished"
}

test_npm_snapshot_timeout_still_completes() {
  local case_dir="$tmp/snapshot-timeout"
  setup_case "$case_dir"
  echo 0 > "$case_dir/bin/mise-fail-times"
  cat > "$case_dir/bin/npm" <<'EOF'
#!/usr/bin/env bash
bindir="${0%/*}"
if [[ "$*" == "list -g --depth=0" && ! -f "$bindir/npm-snapshot-started" ]]; then
  touch "$bindir/npm-snapshot-started"
  sleep 60
fi
exit 0
EOF

  local out rc=0
  out="$(UPDATE_ALL_TOOL_TIMEOUT=1 run_case "$case_dir")" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "expected best-effort snapshot timeout to allow updates, got $rc"
  assert_contains "$out" "npm global packages"
  assert_contains "$out" "Finished"
}

test_global_package_timeouts_fail_run_but_complete() {
  local case_dir="$tmp/packages-timeout"
  setup_case "$case_dir"
  echo 0 > "$case_dir/bin/mise-fail-times"
  local pm
  for pm in pipx npm pnpm bun uv; do
    cat > "$case_dir/bin/$pm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list -g --depth=0"|"pm ls -g") printf '└── example@1.0.0\n'; exit 0 ;;
  upgrade-all|"install -g "*|"update -g "*|"add -g "*|"tool upgrade --all") sleep 60 ;;
esac
exit 0
EOF
  done

  local out rc=0
  out="$(UPDATE_ALL_TOOL_TIMEOUT=1 run_case "$case_dir")" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "expected exit 1 on package timeouts, got $rc"
  assert_contains "$out" "5 failed"
  assert_contains "$out" "Timed out after 1s"
  assert_contains "$out" "Finished"
}

test_tool_timeout_fails_run_but_completes() {
  local case_dir="$tmp/timeout"
  setup_case "$case_dir"
  # brew upgrade wedges (like the real-world Homebrew ruby hang); update and
  # cleanup return instantly.
  cat > "$case_dir/bin/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "upgrade" ]]; then sleep 60; exit 0; fi
exit 0
EOF
  chmod +x "$case_dir/bin/brew"
  echo 0 > "$case_dir/bin/mise-fail-times"

  local out rc=0
  set +e
  UPDATE_ALL_TOOL_TIMEOUT=2 out="$(run_case "$case_dir")"
  rc=$?
  set -e

  [[ "$rc" -eq 1 ]] || fail "expected exit 1 on tool timeout, got $rc"
  assert_contains "$out" "Homebrew upgrade failed (exit code 124)"
  assert_contains "$out" "Timed out after 2s"
  # The run still completes: later tools run and the summary is printed.
  assert_contains "$out" "mise tool upgrades"
  assert_contains "$out" "Finished"
}

tmp="$(mktemp -d)"
HOST_BASH="$(command -v bash)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

test_mise_retry_recovers_from_transient_error
test_mise_retry_exhausted_reports_failure
test_dry_run_does_not_retry
test_tool_timeout_fails_run_but_completes
test_macos_check_failure_fails_run
test_macos_check_timeout_fails_run_but_completes
test_npm_snapshot_timeout_still_completes
test_global_package_timeouts_fail_run_but_complete

echo "PASS"
