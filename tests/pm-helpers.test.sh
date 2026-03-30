#!/usr/bin/env bash
# Boundary tests for lib/pm-helpers.sh pure parser functions.
# No faked binaries needed — all input via heredocs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/pm-helpers.sh"

# Disable colors for test output
pm_helpers_set_colors "" ""

strip_ansi() {
    perl -pe 's/\e\[[0-9;]*[mK]//g'
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "$expected" != "$actual" ]]; then
        fail "$label: expected [$expected], got [$actual]"
    fi
}

# ============================================================
# parse_npm_tree
# ============================================================

test_parse_npm_tree_standard() {
    declare -A result=()
    parse_npm_tree result < <(printf '%s\n' \
        '/opt/homebrew/lib' \
        '├── npm@10.9.0' \
        '├── typescript@5.8.2' \
        '└── @antfu/ni@24.2.0')

    assert_eq "${result[npm]}" "10.9.0" "npm version"
    assert_eq "${result[typescript]}" "5.8.2" "typescript version"
    assert_eq "${result[@antfu/ni]}" "24.2.0" "@antfu/ni version"
    assert_eq "${#result[@]}" "3" "entry count"
}

test_parse_npm_tree_npm_v9_plus_style() {
    declare -A result=()
    parse_npm_tree result < <(printf '%s\n' \
        '/usr/local/lib' \
        '+-- npm@9.5.0' \
        '`-- eslint@8.45.0')

    assert_eq "${result[npm]}" "9.5.0" "npm version"
    assert_eq "${result[eslint]}" "8.45.0" "eslint version"
}

test_parse_npm_tree_empty_input() {
    declare -A result=()
    parse_npm_tree result < <(printf '')
    assert_eq "${#result[@]}" "0" "empty input"
}

test_parse_npm_tree_skips_header() {
    declare -A result=()
    parse_npm_tree result < <(printf '%s\n' \
        '/opt/homebrew/lib/node_modules')

    assert_eq "${#result[@]}" "0" "header only"
}

test_parse_npm_tree_indented_entries() {
    declare -A result=()
    parse_npm_tree result < <(printf '%s\n' \
        '  ├── typescript@5.8.2' \
        '  └── @antfu/ni@24.2.0')

    assert_eq "${result[typescript]}" "5.8.2" "indented typescript"
    assert_eq "${result[@antfu/ni]}" "24.2.0" "indented @antfu/ni"
}

# ============================================================
# parse_bun_tree
# ============================================================

test_parse_bun_tree_standard() {
    declare -A result=()
    parse_bun_tree result < <(printf '%s\n' \
        '├── wrangler@4.73.0' \
        '└── vercel@50.33.0')

    assert_eq "${result[wrangler]}" "4.73.0" "wrangler version"
    assert_eq "${result[vercel]}" "50.33.0" "vercel version"
}

test_parse_bun_tree_scoped_package() {
    declare -A result=()
    parse_bun_tree result < <(printf '%s\n' \
        '├── @biomejs/biome@1.9.0')

    assert_eq "${result[@biomejs/biome]}" "1.9.0" "scoped package"
}

test_parse_bun_tree_empty() {
    declare -A result=()
    parse_bun_tree result < <(printf '')
    assert_eq "${#result[@]}" "0" "empty input"
}

test_parse_bun_tree_ignores_non_tree_lines() {
    declare -A result=()
    parse_bun_tree result < <(printf '%s\n' \
        'some header text' \
        '├── pkg@1.0.0' \
        '  another line')

    assert_eq "${#result[@]}" "1" "only tree lines parsed"
    assert_eq "${result[pkg]}" "1.0.0" "pkg version"
}

# ============================================================
# parse_pipx_output
# ============================================================

test_parse_pipx_output_format1() {
    local out
    out=$(printf '%s\n' \
        'upgraded package black from 24.1.0 to 24.2.0' \
        'upgraded package flake8 from 7.0.0 to 7.1.0' \
        'nothing else' | parse_pipx_output | strip_ansi)

    assert_contains "$out" "black: 24.1.0 → 24.2.0"
    assert_contains "$out" "flake8: 7.0.0 → 7.1.0"
    assert_not_contains "$out" "nothing else"
}

test_parse_pipx_output_format2() {
    local out
    out=$(printf '%s\n' \
        'Package black upgraded 24.1.0 -> 24.2.0' | parse_pipx_output | strip_ansi)

    assert_contains "$out" "black: 24.1.0 → 24.2.0"
}

test_parse_pipx_output_no_changes() {
    local out
    out=$(printf '%s\n' \
        'nothing to upgrade' | parse_pipx_output | strip_ansi)

    assert_contains "$out" "All pipx packages already up to date."
    assert_not_contains "UP" "$out"  # no upgrade arrows
}

test_parse_pipx_output_mixed() {
    local out
    out=$(printf '%s\n' \
        'upgraded package black from 24.1.0 to 24.2.0' \
        'some unrelated line' \
        'Package flake8 upgraded 7.0.0 -> 7.1.0' | parse_pipx_output | strip_ansi)

    assert_contains "$out" "black: 24.1.0 → 24.2.0"
    assert_contains "$out" "flake8: 7.0.0 → 7.1.0"
    assert_contains "$out" "Updated 2 pipx package(s)."
}

# ============================================================
# print_version_diff
# ============================================================

test_print_version_diff_changed() {
    declare -A old=([typescript]="5.8.2" [eslint]="8.0.0")
    declare -A new=([typescript]="5.9.0" [eslint]="9.0.0")
    local out
    out=$(print_version_diff old new | strip_ansi)

    assert_contains "$out" "typescript: 5.8.2 → 5.9.0"
    assert_contains "$out" "eslint: 8.0.0 → 9.0.0"
}

test_print_version_diff_no_change() {
    declare -A old=([pkg]="1.0.0")
    declare -A new=([pkg]="1.0.0")
    local out
    out=$(print_version_diff old new | strip_ansi)

    assert_eq "$out" "" "no diff output"
}

test_print_version_diff_partial_change() {
    declare -A old=([a]="1.0.0" [b]="2.0.0" [c]="3.0.0")
    declare -A new=([a]="1.0.0" [b]="2.1.0" [c]="3.0.0")
    local out
    out=$(print_version_diff old new | strip_ansi)

    assert_not_contains "$out" "a:"
    assert_contains "$out" "b: 2.0.0 → 2.1.0"
    assert_not_contains "$out" "c:"
}

test_print_version_diff_removed_package() {
    declare -A old=([a]="1.0.0")
    declare -A new=()
    local out
    out=$(print_version_diff old new | strip_ansi)

    assert_eq "$out" "" "removed package produces no diff"
}

# ============================================================
# map_to_latest
# ============================================================

test_map_to_latest_basic() {
    declare -A pkgs=([typescript]="5.8.2" [eslint]="8.0.0")
    local out
    out=$(map_to_latest pkgs | sort)

    assert_contains "$out" "eslint@latest"
    assert_contains "$out" "typescript@latest"
}

test_map_to_latest_with_exclude() {
    declare -A pkgs=([npm]="10.9.0" [typescript]="5.8.2")
    local out
    out=$(map_to_latest pkgs npm)

    assert_not_contains "$out" "npm@latest"
    assert_contains "$out" "typescript@latest"
}

test_map_to_latest_multiple_excludes() {
    declare -A pkgs=([npm]="10.9.0" [typescript]="5.8.2" [eslint]="8.0.0")
    local out
    out=$(map_to_latest pkgs npm typescript | sort)

    assert_not_contains "$out" "npm@latest"
    assert_not_contains "$out" "typescript@latest"
    assert_contains "$out" "eslint@latest"
}

test_map_to_latest_empty() {
    declare -A pkgs=()
    local out
    out=$(map_to_latest pkgs)

    assert_eq "$out" "" "empty input"
}

test_map_to_latest_scoped_package() {
    declare -A pkgs=([@antfu/ni]="24.2.0")
    local out
    out=$(map_to_latest pkgs)

    assert_contains "$out" "@antfu/ni@latest"
}

# ============================================================
# Helpers
# ============================================================

assert_contains() {
    local haystack="$1" needle="$2"
    printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null || fail "missing: $needle"
}

assert_not_contains() {
    local haystack="$1" needle="$2"
    if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
        fail "unexpected: $needle"
    fi
}

# ============================================================
# Run
# ============================================================

test_parse_npm_tree_standard
test_parse_npm_tree_npm_v9_plus_style
test_parse_npm_tree_empty_input
test_parse_npm_tree_skips_header
test_parse_npm_tree_indented_entries

test_parse_bun_tree_standard
test_parse_bun_tree_scoped_package
test_parse_bun_tree_empty
test_parse_bun_tree_ignores_non_tree_lines

test_parse_pipx_output_format1
test_parse_pipx_output_format2
test_parse_pipx_output_no_changes
test_parse_pipx_output_mixed

test_print_version_diff_changed
test_print_version_diff_no_change
test_print_version_diff_partial_change
test_print_version_diff_removed_package

test_map_to_latest_basic
test_map_to_latest_with_exclude
test_map_to_latest_multiple_excludes
test_map_to_latest_empty
test_map_to_latest_scoped_package

echo "PASS"
