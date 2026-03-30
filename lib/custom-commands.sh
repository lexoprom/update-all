#!/usr/bin/env bash

_custom_commands_emit_status() {
    local sink="$1"
    local component="$2"
    local status="$3"
    [[ -n "$sink" ]] || return 0
    declare -F "$sink" >/dev/null || return 0
    "$sink" "$component" "$status"
}

_custom_commands_trim() {
    local line="$1"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s' "$line"
}

custom_commands_has_entries() {
    local file="$1"
    local line

    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(_custom_commands_trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        return 0
    done < "$file"

    return 1
}

custom_commands_should_run() {
    local skip_commands="$1"
    local file="$2"
    [[ "$skip_commands" = false ]] && custom_commands_has_entries "$file"
}

custom_commands_handle_disabled() {
    local skip_commands="$1"
    local status_sink="${2:-}"

    if [[ "$skip_commands" = true ]]; then
        _custom_commands_emit_status "$status_sink" "custom commands" "⏭️ Skipped"
    else
        _custom_commands_emit_status "$status_sink" "custom commands" "⏭️ No commands file"
    fi
}

_custom_commands_run_command() {
    local label="$1"
    local line="$2"
    bash -lc "$line"
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
    local exit_code
    local previous_errexit=0

    : > "$idxfile"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(_custom_commands_trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        i=$((i + 1))
        label="command $(printf '%02d' "$i")"
        printf '%s\t%s\n' "$label" "$line" >> "$idxfile"

        if [[ "$dry_run" = true ]]; then
            echo -e "${cyan}[DRY RUN] Would execute: $line${nc}"
            _custom_commands_emit_status "$status_sink" "$label" "🔍 Dry run"
            continue
        fi

        [[ $- == *e* ]] && previous_errexit=1 || previous_errexit=0
        set +e
        "$runner_fn" "$label" "$line"
        exit_code=$?
        if [[ $previous_errexit -eq 1 ]]; then set -e; else set +e; fi

        if [[ $exit_code -ne 0 ]]; then
            failures=$((failures + 1))
        fi
    done < "$file"

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
