#!/usr/bin/env bash
set -euo pipefail

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

  cat > "$bindir/brew" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/mise" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "activate" ]]; then
  echo ":"
  exit 0
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
  exit 0
fi
exit 0
EOF

  cat > "$bindir/bun" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pm" && "${2:-}" == "ls" && "${3:-}" == "-g" ]]; then
  if [[ -n "${FAKE_BUN_LS_OUTPUT:-}" ]]; then
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
  exit 0
fi
exit 0
EOF

  chmod +x "$bindir/"*
}

setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin" "$case_dir/home" "$case_dir/lib"
  cp ./update-all "$case_dir/update-all"
  cp ./lib/pm-helpers.sh "$case_dir/lib/pm-helpers.sh"
  chmod +x "$case_dir/update-all"
  make_fake_cmds "$case_dir/bin"
}

run_case() {
  local case_dir="$1"
  shift
  HOME="$case_dir/home" PATH="$case_dir/bin:$HOST_BASH_DIR:/usr/bin:/bin" "$case_dir/update-all" "$@" 2>&1 | strip_ansi
}

test_default_commands_file_runs_last() {
  local case_dir="$tmp/default"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
cd ~/.codex/superpowers && git pull
EOF

  local out
  out="$(run_case "$case_dir" --dry-run)"

  assert_contains "$out" "Would execute: cd ~/.codex/superpowers && git pull"

  local phase2_line
  local cmd_line
  phase2_line="$(printf '%s\n' "$out" | grep -n 'Updating global packages' | head -n1 | cut -d: -f1)"
  cmd_line="$(printf '%s\n' "$out" | grep -nF 'Would execute: cd ~/.codex/superpowers && git pull' | head -n1 | cut -d: -f1)"
  [[ -n "$phase2_line" && -n "$cmd_line" ]] || fail "missing expected output lines"
  [[ "$phase2_line" -lt "$cmd_line" ]] || fail "custom commands did not run last"
}

test_commands_file_override() {
  local case_dir="$tmp/override"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo wrong-file
EOF
  cat > "$case_dir/custom.commands" <<'EOF'
echo right-file
EOF

  local out
  out="$(run_case "$case_dir" --dry-run --commands-file "$case_dir/custom.commands")"

  assert_contains "$out" "Would execute: echo right-file"
  assert_not_contains "$out" "Would execute: echo wrong-file"
}

test_skip_commands() {
  local case_dir="$tmp/skip"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo should-not-run
EOF

  local out
  out="$(run_case "$case_dir" --dry-run --skip-commands)"

  assert_not_contains "$out" "Would execute: echo should-not-run"
  assert_contains "$out" "custom commands:"
  assert_contains "$out" "Skipped"
}

test_step_count_includes_enabled_custom_commands() {
  local case_dir="$tmp/step-count-enabled"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo one
EOF

  local out
  out="$(run_case "$case_dir" --dry-run)"

  assert_contains "$out" "[5/5] Running custom commands"
}

test_step_count_excludes_disabled_custom_commands() {
  local case_dir="$tmp/step-count-disabled"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo one
EOF

  local out
  out="$(run_case "$case_dir" --dry-run --skip-commands)"

  assert_contains "$out" "[4/4] Updating global packages (Bun, npm, Pipx)"
  assert_not_contains "$out" "[5/5] Running custom commands"
}

test_comments_and_blank_lines_ignored() {
  local case_dir="$tmp/comments"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
# comment

   # indented comment

echo one
   echo two
EOF

  local out
  out="$(run_case "$case_dir" --dry-run)"

  assert_contains "$out" "Would execute: echo one"
  assert_contains "$out" "Would execute: echo two"
  assert_not_contains "$out" "Would execute: # comment"
  assert_contains "$out" "Completed (2)"
  assert_contains "$out" "Custom commands"
  assert_contains "$out" "- echo one"
  assert_contains "$out" "- echo two"
  assert_not_contains "$out" "command 01:"
}

test_command_failure_does_not_stop_next() {
  local case_dir="$tmp/failure-continue"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<EOF
false
echo ok > "$case_dir/home/ok.txt"
EOF

  local out
  out="$(run_case "$case_dir")"

  [[ -f "$case_dir/home/ok.txt" ]] || fail "second command did not run after failure"
  assert_contains "$out" "command 01"
  assert_contains "$out" "failed with exit code 1"
  assert_contains "$out" "Failed (1 of 2)"
  assert_contains "$out" "Custom commands"
  assert_contains "$out" "- false"
}

test_missing_optional_repo_is_skipped() {
  local case_dir="$tmp/missing-optional"
  setup_case "$case_dir"
  cp ./update-all.commands "$case_dir/update-all.commands"

  local out
  out="$(run_case "$case_dir")"

  assert_contains "$out" "Skipping ~/.codex/superpowers: repo not present"
  assert_contains "$out" "Skipping ~/.agents/skills/pi-skills: repo not present"
  assert_not_contains "$out" "command 01 failed"
  assert_not_contains "$out" "command 02 failed"
  assert_contains "$out" "Completed (2)"
}

test_npm_globals_install_latest() {
  local case_dir="$tmp/npm-latest"
  setup_case "$case_dir"
  : > "$case_dir/update-all.commands"

  export FAKE_NPM_STATE_FILE="$case_dir/npm-state.txt"
  export FAKE_NPM_RECORD_FILE="$case_dir/npm-record.txt"
  printf '%s\n' '/fake/lib' '├── npm@10.9.0' '├── typescript@5.8.2' '└── @antfu/ni@24.2.0' > "$FAKE_NPM_STATE_FILE"
  export FAKE_NPM_NEXT_LIST_OUTPUT=$'/fake/lib\n├── npm@10.9.0\n├── typescript@5.9.0\n└── @antfu/ni@24.3.0'

  local out
  out="$(run_case "$case_dir")"

  [[ -f "$case_dir/npm-record.txt" ]] || fail "npm install -g was not called"
  local record
  record="$(<"$case_dir/npm-record.txt")"

  assert_contains "$record" "args=install -g"
  assert_contains "$record" "typescript@latest"
  assert_contains "$record" "@antfu/ni@latest"
  assert_not_contains "$record" "npm@latest"
  assert_contains "$out" "Updating npm globals:"
  assert_contains "$out" "typescript: 5.8.2 → 5.9.0"
  assert_contains "$out" "@antfu/ni: 24.2.0 → 24.3.0"

  unset FAKE_NPM_STATE_FILE
  unset FAKE_NPM_RECORD_FILE
  unset FAKE_NPM_NEXT_LIST_OUTPUT
}

test_bun_globals_use_temp_dir_and_latest() {
  local case_dir="$tmp/bun-latest"
  setup_case "$case_dir"
  : > "$case_dir/update-all.commands"

  export FAKE_BUN_LS_OUTPUT=$'├── wrangler@4.73.0\n└── vercel@50.33.0'
  export FAKE_BUN_RECORD_FILE="$case_dir/bun-record.txt"

  local out
  out="$(run_case "$case_dir")"

  [[ -f "$case_dir/bun-record.txt" ]] || fail "bun add -g was not called"
  local record
  record="$(<"$case_dir/bun-record.txt")"

  assert_contains "$record" "args=add -g"
  assert_contains "$record" "wrangler@latest"
  assert_contains "$record" "vercel@latest"
  assert_not_contains "$record" "pwd=$case_dir/home"
  assert_contains "$out" "Updating Bun globals:"

  unset FAKE_BUN_LS_OUTPUT
  unset FAKE_BUN_RECORD_FILE
}

tmp="$(mktemp -d)"
HOST_BASH_DIR="$(dirname "$(command -v bash)")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

test_default_commands_file_runs_last
test_commands_file_override
test_skip_commands
test_step_count_includes_enabled_custom_commands
test_step_count_excludes_disabled_custom_commands
test_comments_and_blank_lines_ignored
test_command_failure_does_not_stop_next
test_missing_optional_repo_is_skipped
test_npm_globals_install_latest
test_bun_globals_use_temp_dir_and_latest

echo "PASS"
