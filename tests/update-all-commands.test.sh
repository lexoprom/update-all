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

  cat > "$bindir/bun" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pm" && "${2:-}" == "ls" && "${3:-}" == "-g" ]]; then
  exit 0
fi
if [[ "${1:-}" == "add" && "${2:-}" == "-g" ]]; then
  exit 0
fi
exit 0
EOF

  chmod +x "$bindir/"*
}

setup_case() {
  local case_dir="$1"
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cp ./update-all "$case_dir/update-all"
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

tmp="$(mktemp -d)"
HOST_BASH_DIR="$(dirname "$(command -v bash)")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

test_default_commands_file_runs_last
test_commands_file_override
test_skip_commands
test_comments_and_blank_lines_ignored
test_command_failure_does_not_stop_next
test_missing_optional_repo_is_skipped

echo "PASS"
