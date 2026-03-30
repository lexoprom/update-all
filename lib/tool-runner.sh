#!/usr/bin/env bash

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
    local existing

    for existing in "${TOOL_RUNNER_PHASE_ORDER[@]}"; do
        [[ "$existing" == "$phase" ]] && break
    done
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

_tool_runner_call_if_defined() {
    local fn="$1"
    shift || true
    [[ -n "$fn" ]] || return 1
    declare -F "$fn" >/dev/null || return 1
    "$fn" "$@"
}

_tool_runner_is_enabled() {
    local id="$1"
    _tool_runner_call_if_defined "${TOOL_RUNNER_ENABLED_FNS[$id]-}"
}

_tool_runner_run() {
    local id="$1"
    local exit_code
    local previous_errexit=0

    [[ $- == *e* ]] && previous_errexit=1
    set +e
    _tool_runner_call_if_defined "${TOOL_RUNNER_RUN_FNS[$id]-}"
    exit_code=$?
    if [[ $previous_errexit -eq 1 ]]; then set -e; else set +e; fi
    return "$exit_code"
}

_tool_runner_handle_disabled() {
    local id="$1"
    _tool_runner_call_if_defined "${TOOL_RUNNER_DISABLED_FNS[$id]-}"
}

_tool_runner_emit_progress() {
    local progress_fn="$1"
    local current="$2"
    local total="$3"
    local label="$4"
    _tool_runner_call_if_defined "$progress_fn" "$current" "$total" "$label" || true
}

tool_runner_count_enabled() {
    local count=0
    local id
    for id in "${TOOL_RUNNER_IDS[@]}"; do
        if _tool_runner_is_enabled "$id"; then
            ((count++))
        fi
    done
    echo "$count"
}

_tool_runner_wait_for_jobs() {
    local -a jobs=("$@")
    local pid
    local previous_errexit=0

    [[ $- == *e* ]] && previous_errexit=1
    for pid in "${jobs[@]}"; do
        set +e
        wait "$pid"
        if [[ $previous_errexit -eq 1 ]]; then set -e; else set +e; fi
    done

    return 0
}

_tool_runner_run_parallel_phase() {
    local phase="$1"
    local progress_fn="$2"
    local total="$3"
    local -n _current="$4"
    local -a jobs=()
    local id
    local label
    local wait_message="${TOOL_RUNNER_PHASE_WAIT_MESSAGES[$phase]-}"
    local blue="${BLUE:-\033[0;34m}"
    local nc="${NC:-\033[0m}"

    for id in "${TOOL_RUNNER_IDS[@]}"; do
        [[ "${TOOL_RUNNER_PHASES[$id]-}" == "$phase" ]] || continue
        _tool_runner_is_enabled "$id" || continue

        _current=$((_current + 1))
        label="${TOOL_RUNNER_LABELS[$id]-$id}"
        _tool_runner_emit_progress "$progress_fn" "$_current" "$total" "$label"

        (_tool_runner_run "$id") &
        jobs+=("$!")
    done

    if [[ ${#jobs[@]} -gt 0 ]]; then
        [[ -n "$wait_message" ]] && echo -e "${blue}${wait_message}${nc}"
        _tool_runner_wait_for_jobs "${jobs[@]}"
    fi
}

_tool_runner_run_serial_phase() {
    local phase="$1"
    local progress_fn="$2"
    local total="$3"
    local -n _current="$4"
    local id
    local label

    for id in "${TOOL_RUNNER_IDS[@]}"; do
        [[ "${TOOL_RUNNER_PHASES[$id]-}" == "$phase" ]] || continue
        if _tool_runner_is_enabled "$id"; then
            _current=$((_current + 1))
            label="${TOOL_RUNNER_LABELS[$id]-$id}"
            _tool_runner_emit_progress "$progress_fn" "$_current" "$total" "$label"
            _tool_runner_run "$id" || true
        else
            _tool_runner_handle_disabled "$id"
        fi
    done
}

tool_runner_generate_summary() {
    local report_dir="$1"
    local commands_index="${2:-$report_dir/commands.index}"
    local yellow="${YELLOW:-\033[0;33m}"
    local green="${GREEN:-\033[0;32m}"
    local blue="${BLUE:-\033[0;34m}"
    local cyan="${CYAN:-\033[0;36m}"
    local nc="${NC:-\033[0m}"
    declare -A status=()
    local id component components_fn

    if [[ -f "$report_dir/status.log" ]]; then
        while IFS=$'\t' read -r component state; do
            [[ -z "${component// }" ]] && continue
            status["$component"]="$state"
        done < "$report_dir/status.log"
    fi

    echo -e "\n${yellow}=======================================================${nc}"
    echo -e "${green}Update Summary Report${nc}"
    echo -e "${yellow}=======================================================${nc}\n"

    for id in "${TOOL_RUNNER_IDS[@]}"; do
        components_fn="${TOOL_RUNNER_COMPONENTS_FNS[$id]-}"
        while IFS= read -r component; do
            [[ -z "${component:-}" ]] && continue
            if [[ -n "${status[$component]+_}" ]]; then
                printf "${blue}%-45s${nc} %s\n" "$component:" "${status[$component]}"
            fi
        done < <(_tool_runner_call_if_defined "$components_fn" || true)
    done

    if [[ -f "$commands_index" ]]; then
        echo -e "\n${green}Custom commands${nc}"
        while IFS=$'\t' read -r label cmd; do
            [[ -z "${label:-}" ]] && continue
            echo -e "${cyan}- $cmd${nc}"
        done < "$commands_index"
    fi

    echo -e "\n${cyan}Completed on: $(date)${nc}"
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
            parallel) _tool_runner_run_parallel_phase "$phase" "$progress_fn" "$total" current ;;
            serial) _tool_runner_run_serial_phase "$phase" "$progress_fn" "$total" current ;;
            *) echo "Unknown tool runner phase mode: $mode" >&2; return 1 ;;
        esac
    done

    tool_runner_generate_summary "$report_dir" "$commands_index"
}
