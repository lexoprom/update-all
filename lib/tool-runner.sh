#!/usr/bin/env bash

# shellcheck source=./common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

declare -ag TOOL_RUNNER_IDS=()
declare -ag TOOL_RUNNER_PHASE_ORDER=()
declare -gA TOOL_RUNNER_PHASE_MODES=()
declare -gA TOOL_RUNNER_PHASE_WAIT_MESSAGES=()
declare -gA TOOL_RUNNER_LABELS=()
declare -gA TOOL_RUNNER_PHASES=()
declare -gA TOOL_RUNNER_ENABLED_FNS=()
declare -gA TOOL_RUNNER_RUN_FNS=()
declare -gA TOOL_RUNNER_COMPONENTS_FNS=()
declare -gA TOOL_RUNNER_DISABLED_FNS=()

tool_runner_reset() {
    TOOL_RUNNER_IDS=()
    TOOL_RUNNER_PHASE_ORDER=()
    TOOL_RUNNER_PHASE_MODES=()
    TOOL_RUNNER_PHASE_WAIT_MESSAGES=()
    TOOL_RUNNER_LABELS=()
    TOOL_RUNNER_PHASES=()
    TOOL_RUNNER_ENABLED_FNS=()
    TOOL_RUNNER_RUN_FNS=()
    TOOL_RUNNER_COMPONENTS_FNS=()
    TOOL_RUNNER_DISABLED_FNS=()
}

tool_runner_define_phase() {
    local phase="$1"
    local mode="$2"
    local wait_message="${3:-}"

    [[ " ${TOOL_RUNNER_PHASE_ORDER[*]} " == *" $phase "* ]] || TOOL_RUNNER_PHASE_ORDER+=("$phase")

    TOOL_RUNNER_PHASE_MODES["$phase"]="$mode"
    TOOL_RUNNER_PHASE_WAIT_MESSAGES["$phase"]="$wait_message"
}

tool_runner_register() {
    local id="$1"
    local phase="$2"
    local label="$3"
    local enabled_fn="$4"
    local run_fn="$5"
    local components_fn="$6"
    local disabled_fn="${7:-}"

    [[ " ${TOOL_RUNNER_IDS[*]} " == *" $id "* ]] || TOOL_RUNNER_IDS+=("$id")

    TOOL_RUNNER_PHASES["$id"]="$phase"
    TOOL_RUNNER_LABELS["$id"]="$label"
    TOOL_RUNNER_ENABLED_FNS["$id"]="$enabled_fn"
    TOOL_RUNNER_RUN_FNS["$id"]="$run_fn"
    TOOL_RUNNER_COMPONENTS_FNS["$id"]="$components_fn"
    TOOL_RUNNER_DISABLED_FNS["$id"]="$disabled_fn"
}

_tool_runner_is_enabled() {
    local id="$1"
    call_if_defined "${TOOL_RUNNER_ENABLED_FNS[$id]-}"
}

_tool_runner_run() {
    local id="$1"
    local exit_code=0

    call_if_defined "${TOOL_RUNNER_RUN_FNS[$id]-}" || exit_code=$?
    if [[ -n "${REPORT_DIR:-}" && -d "$REPORT_DIR" ]]; then
        printf '%s\t%s\n' "$id" "$exit_code" >> "$REPORT_DIR/stages.tsv"
    fi
    return "$exit_code"
}

_tool_runner_handle_disabled() {
    local id="$1"
    call_if_defined "${TOOL_RUNNER_DISABLED_FNS[$id]-}"
}

_tool_runner_emit_progress() {
    local progress_fn="$1"
    local current="$2"
    local total="$3"
    local label="$4"
    call_if_defined "$progress_fn" "$current" "$total" "$label" || true
}

tool_runner_count_enabled() {
    local count=0
    local id
    for id in "${TOOL_RUNNER_IDS[@]}"; do
        _tool_runner_is_enabled "$id" && count=$((count + 1))
    done
    echo "$count"
}

# Run one phase. Parallel phases start every enabled tool in the background
# and wait for all of them; serial phases run them in order and also report
# disabled tools through their disabled handler.
_tool_runner_run_phase() {
    local phase="$1"
    local mode="$2"
    local progress_fn="$3"
    local total="$4"
    local -n _current="$5"
    local -a jobs=()
    local id pid
    local wait_message="${TOOL_RUNNER_PHASE_WAIT_MESSAGES[$phase]-}"
    local dim="${DIM:-\033[2m}"
    local nc="${NC:-\033[0m}"

    for id in "${TOOL_RUNNER_IDS[@]}"; do
        [[ "${TOOL_RUNNER_PHASES[$id]-}" == "$phase" ]] || continue
        if ! _tool_runner_is_enabled "$id"; then
            # A tool without a disabled handler is simply not reported.
            [[ "$mode" == serial ]] && { _tool_runner_handle_disabled "$id" || true; }
            continue
        fi

        _current=$((_current + 1))
        _tool_runner_emit_progress "$progress_fn" "$_current" "$total" "${TOOL_RUNNER_LABELS[$id]-$id}"

        if [[ "$mode" == parallel ]]; then
            (_tool_runner_run "$id") &
            jobs+=("$!")
        else
            _tool_runner_run "$id" || true
        fi
    done

    if [[ ${#jobs[@]} -gt 0 ]]; then
        [[ -n "$wait_message" ]] && printf '  %b·  %s%b\n' "$dim" "$wait_message" "$nc"
        for pid in "${jobs[@]}"; do
            wait "$pid" || true
        done
    fi
    return 0
}

tool_runner_generate_summary() {
    local report_dir="$1"
    local commands_index="${2:-$report_dir/commands.index}"
    local yellow="${YELLOW:-\033[0;33m}"
    local blue="${BLUE:-\033[0;34m}"
    local red="${RED:-\033[0;31m}"
    local bold="${BOLD:-\033[1m}"
    local dim="${DIM:-\033[2m}"
    local nc="${NC:-\033[0m}"
    declare -A status=()
    local id component components_fn
    local shown=0 failed=0 skipped=0 simulated=0

    if [[ -f "$report_dir/status.log" ]]; then
        while IFS=$'\t' read -r component state; do
            [[ -z "${component// }" ]] && continue
            status["$component"]="$state"
        done < "$report_dir/status.log"
    fi

    if [[ -f "$commands_index" ]]; then
        printf '\n'
        while IFS=$'\t' read -r _ cmd; do
            [[ -z "${cmd:-}" ]] && continue
            printf '  %b·  %s%b\n' "$dim" "$cmd" "$nc"
        done < "$commands_index"
    fi

    printf '\n%bSummary%b\n' "$bold" "$nc"
    printf '%b────────────────────────────────────────────%b\n' "$dim" "$nc"

    for id in "${TOOL_RUNNER_IDS[@]}"; do
        components_fn="${TOOL_RUNNER_COMPONENTS_FNS[$id]-}"
        while IFS= read -r component; do
            [[ -z "${component:-}" ]] && continue
            if [[ -n "${status[$component]+_}" ]]; then
                shown=$((shown + 1))
                case "${status[$component]}" in
                    *[Ff]ailed*) failed=$((failed + 1)) ;;
                    *Skipped*|*"Not installed"*|*"No commands"*) skipped=$((skipped + 1)) ;;
                    *"Dry run"*) simulated=$((simulated + 1)) ;;
                esac
                printf '  %b%-28s%b %s\n' "$blue" "$component" "$nc" "${status[$component]}"
            fi
        done < <(call_if_defined "$components_fn" || true)
    done

    printf '%b────────────────────────────────────────────%b\n' "$dim" "$nc"
    if [[ $failed -gt 0 || $simulated -gt 0 ]]; then
        if [[ $failed -gt 0 ]]; then
            printf '%b%d items · %d failed%b' "$red" "$shown" "$failed" "$nc"
        else
            printf '%b%d items · %d simulated%b' "$yellow" "$shown" "$simulated" "$nc"
        fi
        [[ $skipped -gt 0 ]] && printf '%b · %d skipped%b' "$dim" "$skipped" "$nc"
        printf '\n'
    fi
    printf '%bFinished %s%b\n' "$dim" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$nc"

    # Surface failed components in the script's exit status so wrappers and
    # history can detect partial failures.
    [[ $failed -eq 0 ]]
}

tool_runner_execute() {
    local report_dir="$1"
    local progress_fn="${2:-}"
    local commands_index="${3:-$report_dir/commands.index}"
    local total current=0
    local phase mode

    total="$(tool_runner_count_enabled)"

    for phase in "${TOOL_RUNNER_PHASE_ORDER[@]}"; do
        mode="${TOOL_RUNNER_PHASE_MODES[$phase]-serial}"
        case "$mode" in
            parallel|serial) _tool_runner_run_phase "$phase" "$mode" "$progress_fn" "$total" current ;;
            *) echo "Unknown tool runner phase mode: $mode" >&2; return 1 ;;
        esac
    done

    tool_runner_generate_summary "$report_dir" "$commands_index"
}
