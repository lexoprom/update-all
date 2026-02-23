#!/usr/bin/env bash
set -euo pipefail

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

cp ./update-all "$tmp/update-all"
chmod +x "$tmp/update-all"

cat > "$tmp/update-all.commands" <<'EOF'
# Custom commands run after system/package updates
cd ~/.codex/superpowers && git pull
EOF

out="$("$tmp/update-all" --dry-run 2>&1 | strip_ansi)"

echo "$out" | grep -F "Would execute: cd ~/.codex/superpowers && git pull" >/dev/null \
  || fail "did not run commands from update-all.commands"

phase2_line="$(echo "$out" | awk '/Updating global packages/{print NR; exit}')"
phase2_line="$(printf '%s\n' "$out" | grep -n 'Updating global packages' | head -n1 | cut -d: -f1)"
cmd_line="$(printf '%s\n' "$out" | grep -nF 'Would execute: cd ~/.codex/superpowers && git pull' | head -n1 | cut -d: -f1)"

[[ -n "$phase2_line" && -n "$cmd_line" ]] || fail "missing expected output lines"
[[ "$phase2_line" -lt "$cmd_line" ]] || fail "expected custom commands to run after global packages"

echo "PASS"
