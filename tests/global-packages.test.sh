#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/global-packages.sh"

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

create_fake_pipx() {
  local bindir="$1"
  cat > "$bindir/pipx" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "upgrade-all" ]]; then
  if [[ -n "${FAKE_PIPX_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_PIPX_OUTPUT"
  fi
  exit "${FAKE_PIPX_EXIT_CODE:-0}"
fi
exit 0
EOF
  chmod +x "$bindir/pipx"
}

create_fake_npm() {
  local bindir="$1"
  cat > "$bindir/npm" <<'EOF'
#!/usr/bin/env bash
state_file="${FAKE_NPM_STATE_FILE:-}"
if [[ "${1:-}" == "list" && "${2:-}" == "-g" && "${3:-}" == "--depth=0" ]]; then
  if [[ -n "$state_file" && -f "$state_file" ]]; then
    cat "$state_file"
  elif [[ -n "${FAKE_NPM_LIST_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_NPM_LIST_OUTPUT"
  fi
  exit 0
fi
if [[ "${1:-}" == "install" && "${2:-}" == "-g" ]]; then
  if [[ -n "${FAKE_NPM_RECORD_FILE:-}" ]]; then
    printf 'args=%s\n' "$*" > "$FAKE_NPM_RECORD_FILE"
  fi
  if [[ -n "$state_file" && -n "${FAKE_NPM_NEXT_LIST_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_NPM_NEXT_LIST_OUTPUT" > "$state_file"
  fi
  exit "${FAKE_NPM_INSTALL_EXIT_CODE:-0}"
fi
exit 0
EOF
  chmod +x "$bindir/npm"
}

create_fake_bun() {
  local bindir="$1"
  cat > "$bindir/bun" <<'EOF'
#!/usr/bin/env bash
state_file="${FAKE_BUN_STATE_FILE:-}"
if [[ "${1:-}" == "pm" && "${2:-}" == "ls" && "${3:-}" == "-g" ]]; then
  if [[ -n "$state_file" && -f "$state_file" ]]; then
    cat "$state_file"
  elif [[ -n "${FAKE_BUN_LS_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_BUN_LS_OUTPUT"
  fi
  exit 0
fi
if [[ "${1:-}" == "add" && "${2:-}" == "-g" ]]; then
  if [[ -n "${FAKE_BUN_RECORD_FILE:-}" ]]; then
    {
      printf 'pwd=%s\n' "$PWD"
      printf 'args=%s\n' "$*"
    } > "$FAKE_BUN_RECORD_FILE"
  fi
  if [[ -n "$state_file" && -n "${FAKE_BUN_NEXT_LS_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_BUN_NEXT_LS_OUTPUT" > "$state_file"
  fi
  exit "${FAKE_BUN_ADD_EXIT_CODE:-0}"
fi
exit 0
EOF
  chmod +x "$bindir/bun"
}

create_fake_uv() {
  local bindir="$1"
  cat > "$bindir/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "tool" && "${2:-}" == "upgrade" && "${3:-}" == "--all" ]]; then
  if [[ -n "${FAKE_UV_RECORD_FILE:-}" ]]; then
    printf 'args=%s\n' "$*" > "$FAKE_UV_RECORD_FILE"
  fi
  if [[ -n "${FAKE_UV_OUTPUT:-}" ]]; then
    printf '%s\n' "$FAKE_UV_OUTPUT"
  fi
  exit "${FAKE_UV_EXIT_CODE:-0}"
fi
exit 0
EOF
  chmod +x "$bindir/uv"
}

setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin" "$case_dir/report"
  ln -sf "$HOST_BASH" "$case_dir/bin/bash"
}

status_sink() {
  printf '%s\t%s\n' "$1" "$2" >> "$STATUS_FILE"
}

run_global_packages() {
  local case_dir="$1"
  local dry_run="$2"
  shift 2
  local -a managers=("$@")
  local old_path="$PATH"

  PATH="$case_dir/bin:/usr/bin:/bin"
  STATUS_FILE="$case_dir/status.log"
  : > "$STATUS_FILE"
  unset TEST_RESULT || true
  declare -gA TEST_RESULT=()

  set +e
  global_packages_run TEST_RESULT "$case_dir/report" "$dry_run" status_sink "${managers[@]}" > "$case_dir/output.log" 2>&1
  TEST_EXIT_CODE=$?
  set -e

  PATH="$old_path"
  TEST_OUTPUT="$(< "$case_dir/output.log")"
  TEST_OUTPUT="$(printf '%s' "$TEST_OUTPUT" | strip_ansi)"
}

clear_fake_env() {
  unset FAKE_PIPX_OUTPUT FAKE_PIPX_EXIT_CODE
  unset FAKE_NPM_STATE_FILE FAKE_NPM_LIST_OUTPUT FAKE_NPM_NEXT_LIST_OUTPUT FAKE_NPM_RECORD_FILE FAKE_NPM_INSTALL_EXIT_CODE
  unset FAKE_BUN_STATE_FILE FAKE_BUN_LS_OUTPUT FAKE_BUN_NEXT_LS_OUTPUT FAKE_BUN_RECORD_FILE FAKE_BUN_ADD_EXIT_CODE
  unset FAKE_UV_OUTPUT FAKE_UV_EXIT_CODE FAKE_UV_RECORD_FILE
}

test_pipx_updates_reported_at_boundary() {
  local case_dir="$tmp/pipx"
  setup_case "$case_dir"
  create_fake_pipx "$case_dir/bin"

  export FAKE_PIPX_OUTPUT=$'upgraded package black from 24.1.0 to 24.2.0\nPackage flake8 upgraded 7.0.0 -> 7.1.0'

  run_global_packages "$case_dir" false pipx

  assert_eq "0" "$TEST_EXIT_CODE" "pipx exit"
  assert_eq "✅ Success" "${TEST_RESULT[status.pipx]}" "pipx status"
  assert_contains "$TEST_OUTPUT" "black: 24.1.0 → 24.2.0"
  assert_contains "$TEST_OUTPUT" "flake8: 7.0.0 → 7.1.0"
  assert_contains "$TEST_OUTPUT" "Updated 2 pipx package(s)."
  assert_contains "$(< "$STATUS_FILE")" $'pipx packages\t✅ Success'

  clear_fake_env
}

test_npm_globals_install_latest_at_boundary() {
  local case_dir="$tmp/npm"
  setup_case "$case_dir"
  create_fake_npm "$case_dir/bin"

  export FAKE_NPM_STATE_FILE="$case_dir/npm-state.txt"
  export FAKE_NPM_RECORD_FILE="$case_dir/npm-record.txt"
  printf '%s\n' '/fake/lib' '├── npm@10.9.0' '├── typescript@5.8.2' '└── @antfu/ni@24.2.0' > "$FAKE_NPM_STATE_FILE"
  export FAKE_NPM_NEXT_LIST_OUTPUT=$'/fake/lib\n├── npm@10.9.0\n├── typescript@5.9.0\n└── @antfu/ni@24.3.0'

  run_global_packages "$case_dir" false npm

  assert_eq "0" "$TEST_EXIT_CODE" "npm exit"
  assert_eq "✅ Success" "${TEST_RESULT[status.npm]}" "npm status"
  local record
  record="$(< "$case_dir/npm-record.txt")"
  assert_contains "$record" "args=install -g"
  assert_contains "$record" "typescript@latest"
  assert_contains "$record" "@antfu/ni@latest"
  assert_not_contains "$record" "npm@latest"
  assert_contains "$TEST_OUTPUT" "Updating npm globals:"
  assert_contains "$TEST_OUTPUT" "typescript: 5.8.2 → 5.9.0"
  assert_contains "$TEST_OUTPUT" "@antfu/ni: 24.2.0 → 24.3.0"

  clear_fake_env
}

test_bun_globals_use_temp_dir_at_boundary() {
  local case_dir="$tmp/bun"
  setup_case "$case_dir"
  create_fake_bun "$case_dir/bin"

  export FAKE_BUN_STATE_FILE="$case_dir/bun-state.txt"
  export FAKE_BUN_RECORD_FILE="$case_dir/bun-record.txt"
  printf '%s\n' '├── wrangler@4.73.0' '└── vercel@50.33.0' > "$FAKE_BUN_STATE_FILE"
  export FAKE_BUN_NEXT_LS_OUTPUT=$'├── wrangler@4.74.0\n└── vercel@50.34.0'

  run_global_packages "$case_dir" false bun

  assert_eq "0" "$TEST_EXIT_CODE" "bun exit"
  assert_eq "✅ Success" "${TEST_RESULT[status.bun]}" "bun status"
  local record
  record="$(< "$case_dir/bun-record.txt")"
  assert_contains "$record" "args=add -g"
  assert_contains "$record" "wrangler@latest"
  assert_contains "$record" "vercel@latest"
  assert_contains "$record" "pwd=/tmp/global-packages-bun"
  assert_contains "$TEST_OUTPUT" "Updating Bun globals:"
  assert_contains "$TEST_OUTPUT" "wrangler: 4.73.0 → 4.74.0"
  assert_contains "$TEST_OUTPUT" "vercel: 50.33.0 → 50.34.0"

  clear_fake_env
}

test_uv_tools_upgrade_all_at_boundary() {
  local case_dir="$tmp/uv"
  setup_case "$case_dir"
  create_fake_uv "$case_dir/bin"

  export FAKE_UV_RECORD_FILE="$case_dir/uv-record.txt"
  export FAKE_UV_OUTPUT=$'Resolved 1 package in 5ms\nUpgraded harbor from 0.3.0 to 0.4.0'

  run_global_packages "$case_dir" false uv

  assert_eq "0" "$TEST_EXIT_CODE" "uv exit"
  assert_eq "✅ Success" "${TEST_RESULT[status.uv]}" "uv status"
  local record
  record="$(< "$case_dir/uv-record.txt")"
  assert_contains "$record" "args=tool upgrade --all"
  assert_contains "$TEST_OUTPUT" "Resolved 1 package in 5ms"
  assert_contains "$TEST_OUTPUT" "Upgraded harbor from 0.3.0 to 0.4.0"
  assert_contains "$(< "$STATUS_FILE")" $'uv tools\t✅ Success'

  clear_fake_env
}

test_default_run_handles_dry_run_and_missing_managers() {
  local case_dir="$tmp/dry-run"
  setup_case "$case_dir"
  create_fake_npm "$case_dir/bin"

  run_global_packages "$case_dir" true

  assert_eq "0" "$TEST_EXIT_CODE" "dry-run exit"
  assert_eq "⏭️ Not installed" "${TEST_RESULT[status.pipx]}" "pipx skipped"
  assert_eq "🔍 Dry run" "${TEST_RESULT[status.npm]}" "npm dry run"
  assert_eq "⏭️ Not installed" "${TEST_RESULT[status.bun]}" "bun skipped"
  assert_eq "⏭️ Not installed" "${TEST_RESULT[status.uv]}" "uv skipped"
  assert_eq "0" "${TEST_RESULT[failures]}" "failure count"
  assert_eq "" "$TEST_OUTPUT" "dry-run output"

  local statuses
  statuses="$(< "$STATUS_FILE")"
  assert_contains "$statuses" $'pipx packages\t⏭️ Not installed'
  assert_contains "$statuses" $'npm global packages\t🔍 Dry run'
  assert_contains "$statuses" $'bun global packages\t⏭️ Not installed'
  assert_contains "$statuses" $'uv tools\t⏭️ Not installed'

  clear_fake_env
}

tmp="$(mktemp -d)"
HOST_BASH="$(command -v bash)"
cleanup() {
  clear_fake_env
  rm -rf "$tmp"
}
trap cleanup EXIT

test_pipx_updates_reported_at_boundary
test_npm_globals_install_latest_at_boundary
test_bun_globals_use_temp_dir_at_boundary
test_uv_tools_upgrade_all_at_boundary
test_default_run_handles_dry_run_and_missing_managers

echo "PASS"
