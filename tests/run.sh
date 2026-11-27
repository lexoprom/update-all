#!/usr/bin/env bash
# Run all isolated update-all test suites (parallel by default).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SERIAL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL=true ;;
    --help|-h)
      cat <<'EOF'
Usage: tests/run.sh [--serial]

Run all isolated fake-manager test suites. Suites run in parallel by default;
pass --serial to run them one by one.
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

TESTS=(
  "bash:tests/custom-commands.test.sh"
  "bash:tests/global-packages.test.sh"
  "bash:tests/tool-runner.test.sh"
  "bash:tests/update-all-brew-intervals.test.sh"
  "bash:tests/update-all-commands.test.sh"
  "bash:tests/update-all-list.test.sh"
  "bash:tests/update-all-macos-interval.test.sh"
  "bash:tests/update-all-retry.test.sh"
  "python3:tests/doctor.test.py"
  "python3:tests/doctor-cli.test.py"
  "python3:tests/update-all-interrupt.test.py"
  "python3:tests/update-all-timeout.test.py"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

start_ts=$SECONDS
failures=0

if [[ "$SERIAL" == true ]]; then
  for spec in "${TESTS[@]}"; do
    runner="${spec%%:*}"
    file="${spec#*:}"
    printf '==> %s\n' "$file"
    if ! "$runner" "$file"; then
      failures=$((failures + 1))
    fi
  done
else
  declare -a pids=() names=() logs=()
  idx=0
  for spec in "${TESTS[@]}"; do
    runner="${spec%%:*}"
    file="${spec#*:}"
    log="$TMP_DIR/$idx.log"
    rcfile="$TMP_DIR/$idx.rc"
    (
      rc=0
      # Background jobs in non-interactive shells inherit SIGINT=SIG_IGN, which
      # breaks tests that send SIGINT to child shells; restore SIG_DFL first.
      python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$runner" "$file" > "$log" 2>&1 || rc=$?
      printf '%s\n' "$rc" > "$rcfile"
    ) &
    pids+=("$!")
    names+=("$file")
    logs+=("$log")
    idx=$((idx + 1))
  done

  for (( i = 0; i < ${#pids[@]}; i++ )); do
    wait "${pids[$i]}" || true
    rc="$(cat "$TMP_DIR/$i.rc" 2>/dev/null || echo 1)"
    if [[ "$rc" -eq 0 ]]; then
      printf 'PASS  %s\n' "${names[$i]}"
    else
      printf 'FAIL  %s (exit %s)\n' "${names[$i]}" "$rc"
      sed 's/^/  /' "${logs[$i]}" >&2
      failures=$((failures + 1))
    fi
  done
fi

elapsed=$((SECONDS - start_ts))
printf '\n%d suites finished in %ds (%d failed)\n' "${#TESTS[@]}" "$elapsed" "$failures"
[[ $failures -eq 0 ]]
