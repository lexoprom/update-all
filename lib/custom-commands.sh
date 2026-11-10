#!/usr/bin/env bash

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Report <component> <status> to the optional status sink.
_custom_commands_emit_status() {
    call_if_defined "$1" "$2" "$3" || true
}

_custom_commands_trim() {
    local line="$1"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s' "$line"
}

# Print each command in the file, trimmed, skipping blank and comment lines.
custom_commands_entries() {
    local file="$1"
    local line

    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(_custom_commands_trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$file"
}

custom_commands_has_entries() {
    [[ -n "$(custom_commands_entries "$1")" ]]
}

custom_commands_should_run() {
    local skip_commands="$1"
    local file="$2"
    [[ "$skip_commands" = false ]] && custom_commands_has_entries "$file"
}

custom_commands_handle_disabled() {
    local skip_commands="$1"
    local status_sink="${2:-}"
    local file="${3:-}"

    if [[ "$skip_commands" = true ]]; then
        _custom_commands_emit_status "$status_sink" "custom commands" "⏭️ Skipped"
    elif [[ -n "$file" && -f "$file" ]]; then
        _custom_commands_emit_status "$status_sink" "custom commands" "⏭️ No commands"
    else
        _custom_commands_emit_status "$status_sink" "custom commands" "⏭️ No commands file"
    fi
}

# Default runner: <label> <command line>.
_custom_commands_run_command() {
    bash -lc "$2"
}

custom_commands_run() {
    local -n _result="$1"
    local file="$2"
    local report_dir="$3"
    local dry_run="$4"
    local status_sink="${5:-}"
    local runner_fn="${6:-_custom_commands_run_command}"
    local idxfile="$report_dir/commands.index"
    local cyan="${CYAN:-\033[0;36m}"
    local nc="${NC:-\033[0m}"
    local line label
    local i=0
    local failures=0

    : > "$idxfile"

    while IFS= read -r line; do
        i=$((i + 1))
        label="command $(printf '%02d' "$i")"
        printf '%s\t%s\n' "$label" "$line" >> "$idxfile"

        if [[ "$dry_run" = true ]]; then
            echo -e "${cyan}[DRY RUN] Would execute: $line${nc}"
            _custom_commands_emit_status "$status_sink" "$label" "🔍 Dry run"
            continue
        fi

        "$runner_fn" "$label" "$line" < /dev/null || failures=$((failures + 1))
    done < <(custom_commands_entries "$file")

    if [[ $failures -eq 0 ]]; then
        _custom_commands_emit_status "$status_sink" "custom commands" "✅ Completed ($i)"
    else
        _custom_commands_emit_status "$status_sink" "custom commands" "❌ Failed ($failures of $i)"
    fi

    _result[count]="$i"
    _result[failures]="$failures"
    _result[index_file]="$idxfile"
    [[ $failures -eq 0 ]]
}
