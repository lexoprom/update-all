#!/usr/bin/env bash
# Shared assertion helpers for Bash test suites.

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

assert_ne() {
  local unexpected="$1"
  local actual="$2"
  local label="${3:-value}"
  if [[ "$unexpected" == "$actual" ]]; then
    fail "$label: expected not [$unexpected], got [$actual]"
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    echo "--- EXPECTED ---" >&2
    printf '%s\n' "$expected" >&2
    echo "--- ACTUAL ---" >&2
    printf '%s\n' "$actual" >&2
    fail "output mismatch"
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
