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

assert_equals() {
  local actual="$1" expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    echo "--- EXPECTED ---" >&2
    printf '%s\n' "$expected" >&2
    echo "--- ACTUAL ---" >&2
    printf '%s\n' "$actual" >&2
    fail "output mismatch"
  fi
}

# Print the body line that immediately follows the "<header>:" line.
# Lets tests pair a two-line section's header with its dim bullet body.
body_after() {
  local haystack="$1" header="$2"
  printf '%s\n' "$haystack" | awk -v h="$header" 'found{print; exit} $0==h{found=1}'
}

make_fake_cmds() {
  local bindir="$1"

  ln -sf "$HOST_BASH" "$bindir/bash"

  cat > "$bindir/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "${FAKE_BREW_LOG:-/dev/null}"
if [[ "${1:-}" == "list" ]]; then
  [[ "${FAKE_BREW_FAIL:-}" == 1 ]] && exit 1
  versions=false
  kind=""
  for a in "$@"; do
    case "$a" in
      --versions) versions=true ;;
      --formula) kind=formula ;;
      --cask) kind=cask ;;
    esac
  done
  if $versions; then
    [[ "$kind" == formula ]] && printf 'git 2.43.0\nnode 20.0.0\n'
    [[ "$kind" == cask ]] && printf 'firefox 120.0\n'
  else
    [[ "$kind" == formula ]] && printf 'git\nnode\n'
    [[ "$kind" == cask ]] && printf 'firefox\n'
  fi
fi
exit 0
EOF

  cat > "$bindir/softwareupdate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$bindir/mise" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "activate" ]]; then
  echo ":"
  exit 0
fi
if [[ "${1:-}" == "ls" || "${1:-}" == "list" ]]; then
  [[ "${FAKE_MISE_FAIL:-}" == 1 ]] && exit 1
  has_installed=false
  for a in "$@"; do [[ "$a" == "--installed" ]] && has_installed=true; done
  if $has_installed; then
    cat <<'TABLE'
node    20.10.0  core
node    18.0.0   core
python  3.12.0   core
TABLE
  else
    # Without --installed a configured-but-missing tool leaks in.
    cat <<'TABLE'
Plugin  Version  Origin
node    20.10.0  core
node    18.0.0   core
python  3.12.0   core
ruby    <missing> core
TABLE
  fi
  exit 0
fi
exit 0
EOF

  cat > "$bindir/pipx" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  has_short=false
  for a in "$@"; do [[ "$a" == "--short" ]] && has_short=true; done
  $has_short || { echo "pipx: --short required" >&2; exit 1; }
  [[ "${FAKE_PIPX_FAIL:-}" == 1 ]] && exit 1
  [[ "${FAKE_PIPX_EMPTY:-}" == 1 ]] && exit 0
  cat <<'SHORT'
black 24.0.0
ruff 0.1.0
SHORT
  exit 0
fi
exit 0
EOF

  cat > "$bindir/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" && "${2:-}" == "-g" ]]; then
  [[ "${FAKE_NPM_FAIL:-}" == 1 ]] && exit 1
  cat <<'TREE'
/Users/x/lib
├── @scope/pkg-a@1.2.3
└── typescript@5.4.0
TREE
  exit 0
fi
exit 0
EOF

  cat > "$bindir/pnpm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" && "${2:-}" == "-g" ]]; then
  [[ -n "${FAKE_PNPM_PATH_FILE:-}" ]] && printf '%s\n' "$PATH" > "$FAKE_PNPM_PATH_FILE"
  [[ "${FAKE_PNPM_FAIL:-}" == 1 ]] && exit 1
  cat <<'TREE'
/Users/x/lib
├── cowsay@1.6.0
└── tsc@5.0.0
TREE
  exit 0
fi
exit 0
EOF

  cat > "$bindir/bun" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pm" && "${2:-}" == "ls" && "${3:-}" == "-g" ]]; then
  [[ -n "${FAKE_BUN_PWD_FILE:-}" ]] && printf '%s\n' "$PWD" > "$FAKE_BUN_PWD_FILE"
  if [[ "${FAKE_BUN_NOLOCKFILE:-}" == 1 ]]; then
    echo "error: ${FAKE_BUN_NOLOCKFILE_MSG:-Lockfile not found}" >&2
    exit 1
  fi
  [[ "${FAKE_BUN_FAIL:-}" == 1 ]] && exit 1
  cat <<'TREE'
/Users/x/install/global/node_modules
├── is-even@1.0.0
└── is-odd@3.0.1
TREE
  exit 0
fi
exit 0
EOF

  cat > "$bindir/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "tool" && "${2:-}" == "list" ]]; then
  [[ "${FAKE_UV_FAIL:-}" == 1 ]] && exit 1
  [[ "${FAKE_UV_EMPTY:-}" == 1 ]] && exit 0
  cat <<'LIST'
ruff v0.1.0
- Application: ruff
eslint v9.0.0
- Application: eslint
LIST
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
  cp ./lib/global-packages.sh "$case_dir/lib/global-packages.sh"
  cp ./lib/custom-commands.sh "$case_dir/lib/custom-commands.sh"
  cp ./lib/tool-runner.sh "$case_dir/lib/tool-runner.sh"
  cp ./lib/pm-helpers.sh "$case_dir/lib/pm-helpers.sh"
  cp ./lib/doctor.py "$case_dir/lib/doctor.py"
  chmod +x "$case_dir/update-all"
  make_fake_cmds "$case_dir/bin"
}

# Run list; write ANSI-stripped output to $2; return the script's exit code.
run_list_rc() {
  local case_dir="$1"
  local out_file="$2"
  shift 2
  local raw rc=0
  raw="$(HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" env -u PNPM_HOME "$case_dir/update-all" "$@" 2>&1)" || rc=$?
  printf '%s' "$raw" | strip_ansi > "$out_file"
  return "$rc"
}

DEFAULT_EXPECTED="Homebrew:
  ·  firefox, git, node
macOS Software Update:
  ·  available
mise:
  ·  node, python
pipx:
  ·  black, ruff
npm:
  ·  @scope/pkg-a, typescript
pnpm:
  ·  cowsay, tsc
Bun:
  ·  is-even, is-odd
uv:
  ·  eslint, ruff
custom commands:
  ·  none"

VERSIONS_EXPECTED="Homebrew:
  ·  firefox 120.0, git 2.43.0, node 20.0.0
macOS Software Update:
  ·  available
mise:
  ·  node 18.0.0, node 20.10.0, python 3.12.0
pipx:
  ·  black 24.0.0, ruff 0.1.0
npm:
  ·  @scope/pkg-a 1.2.3, typescript 5.4.0
pnpm:
  ·  cowsay 1.6.0, tsc 5.0.0
Bun:
  ·  is-even 1.0.0, is-odd 3.0.1
uv:
  ·  eslint v9.0.0, ruff v0.1.0
custom commands:
  ·  none"

test_default_output() {
  local case_dir="$tmp/default"
  local out="$tmp/default.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" list
  assert_equals "$(cat "$out")" "$DEFAULT_EXPECTED"
}

test_versions_output() {
  local case_dir="$tmp/versions"
  local out="$tmp/versions.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" list --versions
  assert_equals "$(cat "$out")" "$VERSIONS_EXPECTED"
}

test_skip_brew_omits_and_does_not_invoke_homebrew() {
  local case_dir="$tmp/skipbrew"
  local out="$tmp/skipbrew.out"
  local brew_log="$tmp/skipbrew.brew.log"
  setup_case "$case_dir"
  FAKE_BREW_LOG="$brew_log" run_list_rc "$case_dir" "$out" list --skip-brew
  local text
  text="$(cat "$out")"
  assert_not_contains "$text" "Homebrew:"
  assert_contains "$text" "macOS Software Update:"
  assert_contains "$text" "·  available"
  assert_contains "$text" "npm:"
  assert_contains "$text" "·  @scope/pkg-a, typescript"
  [[ ! -s "$brew_log" ]] || fail "brew was invoked under --skip-brew: $(cat "$brew_log")"
}

test_failing_collector_does_not_suppress_others_and_exits_1() {
  local case_dir="$tmp/fail"
  local out="$tmp/fail.out"
  setup_case "$case_dir"
  set +e
  FAKE_BREW_FAIL=1 run_list_rc "$case_dir" "$out" list
  local rc=$?
  set -e
  [[ $rc -eq 1 ]] || fail "expected exit status 1, got $rc"
  local text
  text="$(cat "$out")"
  assert_contains "$text" "Homebrew:"
  assert_equals "$(body_after "$text" "Homebrew:")" "  ·  failed"
  assert_contains "$text" "·  @scope/pkg-a, typescript"
  assert_contains "$text" "·  eslint, ruff"
}

test_unavailable_manager_shows_not_installed() {
  local case_dir="$tmp/unavail"
  local out="$tmp/unavail.out"
  setup_case "$case_dir"
  rm -f "$case_dir/bin/bun"
  run_list_rc "$case_dir" "$out" list
  local text
  text="$(cat "$out")"
  assert_contains "$text" "Bun:"
  assert_equals "$(body_after "$text" "Bun:")" "  ·  not installed"
  assert_contains "$text" "·  @scope/pkg-a, typescript"
}

test_empty_manager_shows_none() {
  local case_dir="$tmp/empty"
  local out="$tmp/empty.out"
  setup_case "$case_dir"
  FAKE_UV_EMPTY=1 run_list_rc "$case_dir" "$out" list
  assert_contains "$(cat "$out")" "uv:"
  assert_equals "$(body_after "$(cat "$out")" "uv:")" "  ·  none"
}

test_custom_commands_listed_in_order_not_executed() {
  local case_dir="$tmp/ccmd"
  local out="$tmp/ccmd.out"
  setup_case "$case_dir"
  local marker="$case_dir/no-run-marker"
  cat > "$case_dir/update-all.commands" <<EOF
# a comment, ignored

echo first
touch "$marker"
echo second, with comma
EOF
  run_list_rc "$case_dir" "$out" list
  local text
  text="$(cat "$out")"
  assert_contains "$text" "·  echo first"
  assert_contains "$text" "·  touch \"$marker\""
  assert_contains "$text" "·  echo second, with comma"
  [[ ! -e "$marker" ]] || fail "custom command was executed during list"
}

test_custom_commands_file_override_and_skip() {
  local case_dir="$tmp/ccoverride"
  local out="$tmp/ccoverride.out"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo default-file
EOF
  cat > "$case_dir/custom.commands" <<'EOF'
echo override-one
echo override-two
EOF

  run_list_rc "$case_dir" "$out" list --commands-file "$case_dir/custom.commands"
  local text
  text="$(cat "$out")"
  assert_contains "$text" "·  echo override-one"
  assert_contains "$text" "·  echo override-two"
  assert_not_contains "$text" "echo default-file"

  run_list_rc "$case_dir" "$out" list --skip-commands
  assert_contains "$(cat "$out")" "custom commands:"
  assert_contains "$(cat "$out")" "·  skipped"
}

test_list_does_not_run_updates_or_snapshot_or_lock() {
  local case_dir="$tmp/noupdate"
  local out="$tmp/noupdate.out"
  local brew_log="$tmp/noupdate.brew.log"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<EOF
touch "$case_dir/no-run-marker"
EOF
  FAKE_BREW_LOG="$brew_log" run_list_rc "$case_dir" "$out" list
  local text
  text="$(cat "$out")"
  assert_not_contains "$text" "Update all"
  assert_not_contains "$text" "Would execute"
  assert_not_contains "$text" "Waiting for"
  assert_not_contains "$text" "DRY RUN"
  [[ ! -e "$case_dir/no-run-marker" ]] || fail "custom command ran during list"
  if [[ -s "$brew_log" ]] && grep -Eq 'brew (update|upgrade|cleanup)' "$brew_log"; then
    fail "update commands invoked during list: $(cat "$brew_log")"
  fi
}

test_list_help() {
  local case_dir="$tmp/help"
  local out="$tmp/help.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" list --help
  local text
  text="$(cat "$out")"
  assert_contains "$text" "Usage: update-all list [options]"
  assert_contains "$text" "--versions"
  assert_contains "$text" "--skip-brew"
}

test_general_help_mentions_list() {
  local case_dir="$tmp/ghelp"
  local out="$tmp/ghelp.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" --help
  assert_contains "$(cat "$out")" "list"
}

test_list_emits_bold_header_and_dim_body_ansi() {
  # Raw (non-stripped) output must use ${BOLD}...${NC} for headers and
  # ${DIM}·  ...${NC} for the dim bullet body lines.
  local case_dir="$tmp/ansi"
  local out="$tmp/ansi.out"
  setup_case "$case_dir"
  local raw rc=0
  raw="$(HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" env -u PNPM_HOME \
    "$case_dir/update-all" list 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] || fail "list exited $rc during ANSI test"
  assert_contains "$raw" $'\033[1mHomebrew:\033[0m'
  assert_contains "$raw" $'  \033[2m·  firefox, git, node\033[0m'
  assert_contains "$raw" $'\033[1mmacOS Software Update:\033[0m'
  assert_contains "$raw" $'  \033[2m·  available\033[0m'
  assert_contains "$raw" $'\033[1mcustom commands:\033[0m'
  assert_contains "$raw" $'  \033[2m·  none\033[0m'
}

test_versions_combines_with_skip_brew_and_skip_commands() {
  local case_dir="$tmp/combo"
  local out="$tmp/combo.out"
  setup_case "$case_dir"
  cat > "$case_dir/update-all.commands" <<'EOF'
echo only-command
EOF
  run_list_rc "$case_dir" "$out" list --versions --skip-brew --skip-commands
  local text
  text="$(cat "$out")"
  assert_not_contains "$text" "Homebrew:"
  assert_contains "$text" "·  @scope/pkg-a 1.2.3, typescript 5.4.0"
  assert_contains "$text" "custom commands:"
  assert_contains "$text" "·  skipped"
}

test_mise_requires_installed_flag() {
  # The fake exposes a missing 'ruby' entry unless --installed is passed, so a
  # correct invocation must never list it.
  local case_dir="$tmp/miseflag"
  local out="$tmp/miseflag.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" list
  local text
  text="$(cat "$out")"
  assert_not_contains "$text" "ruby"
  assert_contains "$text" "mise:"
  assert_contains "$text" "·  node, python"
}

test_pipx_requires_short_flag() {
  local case_dir="$tmp/pipxshort"
  local out="$tmp/pipxshort.out"
  setup_case "$case_dir"
  run_list_rc "$case_dir" "$out" list
  assert_contains "$(cat "$out")" "pipx:"
  assert_contains "$(cat "$out")" "·  black, ruff"
}

test_collector_failures_reported() {
  local spec mgr rest flag label case_dir out rc text
  for spec in \
    "pipx:FAKE_PIPX_FAIL:pipx" \
    "npm:FAKE_NPM_FAIL:npm" \
    "pnpm:FAKE_PNPM_FAIL:pnpm" \
    "bun:FAKE_BUN_FAIL:Bun"; do
    mgr="${spec%%:*}"
    rest="${spec#*:}"
    flag="${rest%%:*}"
    label="${spec##*:}"
    case_dir="$tmp/cfail-$mgr"
    out="$tmp/cfail-$mgr.out"
    setup_case "$case_dir"
    export "$flag=1"
    set +e
    run_list_rc "$case_dir" "$out" list
    rc=$?
    set -e
    unset "$flag"
    [[ $rc -eq 1 ]] || fail "$mgr: expected exit status 1, got $rc"
    text="$(cat "$out")"
    assert_contains "$text" "$label:"
    assert_equals "$(body_after "$text" "$label:")" "  ·  failed"
    assert_contains "$text" "·  eslint, ruff"
  done
}

test_pnpm_global_bin_on_path() {
  local case_dir="$tmp/pnpm_path"
  local out="$tmp/pnpm_path.out"
  local path_file="$tmp/pnpm_path.path"
  setup_case "$case_dir"
  FAKE_PNPM_PATH_FILE="$path_file" run_list_rc "$case_dir" "$out" list
  [[ -s "$path_file" ]] || fail "pnpm fake did not record PATH"
  # PNPM_HOME defaults to $HOME/Library/pnpm; its global bin dir must be on PATH.
  assert_contains "$(cat "$path_file")" "$case_dir/home/Library/pnpm/bin"
}

test_bun_lockfile_missing_is_none() {
  # Bun's empty-global state: `bun pm ls -g` exits 1 with "Lockfile not found"
  # (older Bun). That is an empty inventory, not a collector failure.
  local case_dir="$tmp/bunlock"
  local out="$tmp/bunlock.out"
  setup_case "$case_dir"
  set +e
  FAKE_BUN_NOLOCKFILE=1 run_list_rc "$case_dir" "$out" list
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "expected exit status 0 for bun lockfile-missing, got $rc"
  local text
  text="$(cat "$out")"
  assert_contains "$text" "Bun:"
  assert_equals "$(body_after "$text" "Bun:")" "  ·  none"
}

test_bun_missing_lockfile_message_is_none() {
  # Newer Bun (e.g. 1.4.0) words the empty-global state as
  # "missing lockfile, nothing to list"; it must also read as "none".
  local case_dir="$tmp/bunlockmsg"
  local out="$tmp/bunlockmsg.out"
  setup_case "$case_dir"
  set +e
  FAKE_BUN_NOLOCKFILE=1 FAKE_BUN_NOLOCKFILE_MSG="missing lockfile, nothing to list" \
    run_list_rc "$case_dir" "$out" list
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "expected exit status 0 for bun missing-lockfile message, got $rc"
  local text
  text="$(cat "$out")"
  assert_contains "$text" "Bun:"
  assert_equals "$(body_after "$text" "Bun:")" "  ·  none"
}

test_bun_uses_temp_working_directory() {
  local case_dir="$tmp/bunwd"
  local out="$tmp/bunwd.out"
  local pwd_file="$tmp/bunwd.pwd"
  setup_case "$case_dir"
  FAKE_BUN_PWD_FILE="$pwd_file" run_list_rc "$case_dir" "$out" list
  [[ -s "$pwd_file" ]] || fail "bun fake did not record a working directory"
  local recorded
  recorded="$(cat "$pwd_file")"
  [[ "$recorded" != "$case_dir/home" ]] || fail "bun ran from \$HOME: $recorded"
  assert_contains "$(cat "$out")" "Bun:"
  assert_contains "$(cat "$out")" "·  is-even, is-odd"
}

test_list_preserves_foreign_lock() {
  # `list` and `list --help` never acquire a lock, so on exit they must not
  # remove a lock owned by another live updater. Use a uniquely named copy so
  # its /tmp/.<name>_lock cannot collide with a real updater or a parallel test.
  local case_dir="$tmp/lock"
  local out="$tmp/lock.out"
  local uniq="ua-locktest-$RANDOM-$$"
  local script="$case_dir/$uniq"
  setup_case "$case_dir"
  cp ./update-all "$script"
  chmod +x "$script"

  local lock_file="/tmp/.${uniq}_lock"
  # Seed the lock with the PID of a genuinely live, foreign process.
  sleep 30 & local lock_pid=$!
  echo "$lock_pid" > "$lock_file"

  local rc
  for args in "list" "list --help"; do
    rc=0
    HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" env -u PNPM_HOME \
      "$script" $args >"$out" 2>&1 || rc=$?
    [[ -f "$lock_file" ]] || fail "lock removed after '$args'"
    [[ "$(cat "$lock_file" 2>/dev/null || echo "")" == "$lock_pid" ]] || \
      fail "lock contents changed after '$args'"
  done

  kill "$lock_pid" 2>/dev/null || true
  rm -f "$lock_file"
}

tmp="$(mktemp -d)"
HOST_BASH="$(command -v bash)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

test_default_output
test_versions_output
test_list_emits_bold_header_and_dim_body_ansi
test_skip_brew_omits_and_does_not_invoke_homebrew
test_failing_collector_does_not_suppress_others_and_exits_1
test_unavailable_manager_shows_not_installed
test_empty_manager_shows_none
test_custom_commands_listed_in_order_not_executed
test_custom_commands_file_override_and_skip
test_list_does_not_run_updates_or_snapshot_or_lock
test_list_help
test_general_help_mentions_list
test_versions_combines_with_skip_brew_and_skip_commands
test_mise_requires_installed_flag
test_pipx_requires_short_flag
test_collector_failures_reported
test_bun_uses_temp_working_directory
test_pnpm_global_bin_on_path
test_bun_lockfile_missing_is_none
test_bun_missing_lockfile_message_is_none
test_list_preserves_foreign_lock

echo "PASS"
