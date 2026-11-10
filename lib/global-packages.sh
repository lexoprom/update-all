#!/usr/bin/env bash

GLOBAL_PACKAGES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pm-helpers.sh
source "$GLOBAL_PACKAGES_LIB_DIR/pm-helpers.sh"
# shellcheck source=./common.sh
source "$GLOBAL_PACKAGES_LIB_DIR/common.sh"

declare -grA GLOBAL_PACKAGES_LABELS=(
    [pipx]="pipx packages"
    [npm]="npm global packages"
    [pnpm]="pnpm global packages"
    [bun]="bun global packages"
    [uv]="uv tools"
)

declare -gra GLOBAL_PACKAGES_DEFAULT_MANAGERS=(pipx npm pnpm bun uv)
declare -gr GLOBAL_PACKAGES_NPM_BASELINE_FILE="npm_globals.before"

_global_packages_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_global_packages_execute() {
    # The updater provides the watchdog; keep standalone library use working.
    if declare -F run_with_timeout >/dev/null; then
        local exit_code=0
        run_with_timeout "${TOOL_TIMEOUT_SECONDS:-3600}" "$@" || exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            printf 'Timed out after %ss: %s\n' "${TOOL_TIMEOUT_SECONDS:-3600}" "$*" >&2
        fi
        return "$exit_code"
    fi
    "$@"
}

_global_packages_label() {
    printf '%s' "${GLOBAL_PACKAGES_LABELS[$1]:-$1 packages}"
}

# Report <label> <status> to the optional status sink.
_global_packages_emit_status() {
    call_if_defined "$1" "$2" "$3" || true
}

_global_packages_log_failure() {
    local log_file="$1"
    local message="$2"
    local red="${RED:-\033[0;31m}"
    local nc="${NC:-\033[0m}"

    echo -e "${red}${message}${nc}"
    cat "$log_file"
}

_global_packages_print_info() {
    local output_file="$1"
    local dim="${DIM:-\033[2m}"
    local nc="${NC:-\033[0m}"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$line" ]]; then
            printf '  %b·  %s%b\n' "$dim" "$line" "$nc"
        else
            printf '\n'
        fi
    done < "$output_file"
}

_global_packages_set_status() {
    local -n status_result="$1"
    local pm="$2"
    local label="$3"
    local status="$4"
    local sink="${5:-}"

    status_result["label.$pm"]="$label"
    status_result["status.$pm"]="$status"
    _global_packages_emit_status "$sink" "$label" "$status"
}

# _global_packages_capture <out> <err> <failure message> <cmd>...: run a
# command with stdout and stderr in separate files; print the message and
# stderr on failure.
_global_packages_capture() {
    local out_file="$1" err_file="$2" message="$3"
    shift 3
    _global_packages_execute "$@" > "$out_file" 2> "$err_file" && return 0
    _global_packages_log_failure "$err_file" "$message"
    return 1
}

# Bun exits 1 without a global lockfile, i.e. before any global install:
# "Lockfile not found" (older Bun) or "missing lockfile, nothing to list"
# (newer Bun, e.g. 1.4.0). Shared by the updater and `update-all list`.
bun_missing_global_lockfile() {
    [[ "$1" == *"Lockfile not found"* || "$1" == *"missing lockfile"* ]]
}

_global_packages_supported() {
    declare -F "_global_packages_${1}_run" >/dev/null
}

# A manager is installed when its command of the same name is on PATH.
_global_packages_installed() {
    _global_packages_command_exists "$1"
}

global_packages_snapshot() {
    local report_dir="$1"
    local npm_baseline="$report_dir/$GLOBAL_PACKAGES_NPM_BASELINE_FILE"

    [[ -d "$report_dir" ]] || return 0
    _global_packages_command_exists npm || return 0

    local exit_code=0
    _global_packages_execute npm list -g --depth=0 > "$npm_baseline" 2>/dev/null || exit_code=$?
    # A timed-out or empty listing is no baseline.
    if [[ $exit_code -eq 124 || ! -s "$npm_baseline" ]]; then
        rm -f "$npm_baseline"
    fi
}

_global_packages_pipx_run() {
    local report_dir="$1"
    local log_file="$report_dir/pipx.log"

    if _global_packages_execute pipx upgrade-all > "$log_file" 2>&1; then
        parse_pipx_output < "$log_file"
    else
        _global_packages_log_failure "$log_file" "⚠️ Pipx upgrade failed. Details:"
        return 1
    fi
}

_global_packages_npm_run() {
    local report_dir="$1"
    local log_file="$report_dir/npm_install.log"
    local baseline_file="$report_dir/$GLOBAL_PACKAGES_NPM_BASELINE_FILE"
    local current_file="$report_dir/npm_globals.current"
    local current_err="$report_dir/npm_globals.current.err"

    declare -A old_versions=()
    declare -A current_versions=()
    _global_packages_capture "$current_file" "$current_err" "⚠️ npm global package list failed. Details:" \
        npm list -g --depth=0 || return 1
    parse_npm_tree current_versions < "$current_file"
    parse_npm_tree old_versions < "$current_file"

    local name

    local -a missing_from_current=()
    if [[ -s "$baseline_file" ]]; then
        declare -A baseline_versions=()
        parse_npm_tree baseline_versions < "$baseline_file"
        for name in "${!baseline_versions[@]}"; do
            if [[ -z "${current_versions[$name]+_}" ]]; then
                missing_from_current+=("$name")
            fi
            old_versions["$name"]="${baseline_versions[$name]}"
        done
    fi

    local -a packages=()
    readarray -t packages < <(map_to_latest old_versions)

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No global npm packages detected."
        return 0
    fi

    if [[ ${#missing_from_current[@]} -gt 0 ]]; then
        echo "Restoring npm globals missing after runtime switch: ${missing_from_current[*]}"
    fi
    echo "Updating npm globals: ${packages[*]}"
    if ! _global_packages_execute npm install -g "${packages[@]}" > "$log_file" 2>&1; then
        _global_packages_log_failure "$log_file" "⚠️ npm update failed. Details:"
        return 1
    fi

    local after_file="$report_dir/npm_globals.after"
    _global_packages_capture "$after_file" "$after_file.err" "⚠️ npm global package list failed after update. Details:" \
        npm list -g --depth=0 || return 1
    declare -A new_versions=()
    parse_npm_tree new_versions < "$after_file"
    print_version_diff old_versions new_versions
}

_global_packages_pnpm_run() {
    local report_dir="$1"
    local log_file="$report_dir/pnpm_update.log"
    local before_list="$report_dir/pnpm_list_before.txt"
    local before_err="$report_dir/pnpm_list_before.err"
    local recovery_log="$report_dir/pnpm_recovery.log"

    # Capture list output and stderr explicitly. A broken pnpm launcher exits
    # non-zero; treating that as an empty parse would falsely report "No global
    # pnpm packages detected." When the list fails, bootstrap pnpm via npm/npx
    # (the same recovery command as update-all.commands) and retry exactly once
    # before giving up.
    if ! _global_packages_execute pnpm list -g --depth=0 > "$before_list" 2> "$before_err"; then
        if ! pnpm_config_pm_on_fail=ignore _global_packages_execute npx --yes pnpm@latest-11 self-update > "$recovery_log" 2>&1; then
            _global_packages_log_failure "$recovery_log" "⚠️ pnpm recovery failed. Details:"
            return 1
        fi
        _global_packages_capture "$before_list" "$before_err" "⚠️ pnpm global package list failed after recovery. Details:" \
            pnpm list -g --depth=0 || return 1
        echo "Recovered pnpm via npm; retrying global package list."
    fi

    declare -A old_versions=()
    parse_pnpm_tree old_versions < "$before_list"

    if [[ ${#old_versions[@]} -eq 0 ]]; then
        echo "No global pnpm packages detected."
        return 0
    fi

    local -a packages=()
    local pkg_name
    for pkg_name in "${!old_versions[@]}"; do
        [[ "$pkg_name" == "pnpm" || "$pkg_name" == "@pnpm/exe" ]] && continue
        packages+=("$pkg_name")
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No global pnpm packages to update."
        return 0
    fi

    echo "Updating pnpm globals: ${packages[*]}"
    if ! _global_packages_execute pnpm update -g --latest "${packages[@]}" > "$log_file" 2>&1 ||
        ! _global_packages_execute pnpm approve-builds -g --all >> "$log_file" 2>&1; then
        _global_packages_log_failure "$log_file" "⚠️ pnpm update failed. Details:"
        return 1
    fi

    # Re-check the post-update list too: a pnpm failure here must not be
    # silently read as "no version changes".
    local after_list="$report_dir/pnpm_list_after.txt"
    _global_packages_capture "$after_list" "$report_dir/pnpm_list_after.err" \
        "⚠️ pnpm global package list failed after update. Details:" pnpm list -g --depth=0 || return 1
    declare -A new_versions=()
    parse_pnpm_tree new_versions < "$after_list"
    print_version_diff old_versions new_versions
}

# Bun reads a project lockfile from the working directory, so every Bun call
# runs in a fresh temporary directory that is always removed afterwards.
_global_packages_bun_run() {
    local workdir exit_code=0
    workdir="$(mktemp -d "/tmp/global-packages-bun.XXXXXX")"
    _global_packages_bun_update "$1" "$workdir" || exit_code=$?
    rm -rf "$workdir"
    return "$exit_code"
}

_global_packages_bun_update() {
    local report_dir="$1"
    local workdir="$2"
    local log_file="$report_dir/bun_install.log"
    local before_file="$report_dir/bun_globals.before"
    local exit_code=0

    declare -A old_versions=()
    (cd "$workdir" && _global_packages_execute bun pm ls -g) > "$before_file" 2> "$log_file" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        if [[ $exit_code -ne 124 && ! -s "$before_file" ]] &&
            bun_missing_global_lockfile "$(< "$log_file")"; then
            echo "No global Bun packages detected."
            return 0
        fi
        _global_packages_log_failure "$log_file" "⚠️ Bun global package list failed. Details:"
        return 1
    fi
    parse_bun_tree old_versions < "$before_file"

    local -a packages=()
    readarray -t packages < <(map_to_latest old_versions)

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No global Bun packages detected."
        return 0
    fi

    echo "Updating Bun globals: ${packages[*]}"
    if ! (cd "$workdir" && _global_packages_execute bun add -g "${packages[@]}") > "$log_file" 2>&1; then
        _global_packages_log_failure "$log_file" "⚠️ Bun update failed. Details:"
        return 1
    fi

    declare -A new_versions=()
    if ! (cd "$workdir" && _global_packages_execute bun pm ls -g) > "$report_dir/bun_globals.after" 2> "$log_file"; then
        _global_packages_log_failure "$log_file" "⚠️ Bun global package list failed after update. Details:"
        return 1
    fi
    parse_bun_tree new_versions < "$report_dir/bun_globals.after"
    print_version_diff old_versions new_versions
}

_global_packages_uv_run() {
    local report_dir="$1"
    local log_file="$report_dir/uv_tool_upgrade.log"

    if _global_packages_execute uv tool upgrade --all > "$log_file" 2>&1; then
        cat "$log_file"
    else
        _global_packages_log_failure "$log_file" "⚠️ uv tool upgrade failed. Details:"
        return 1
    fi
}

_global_packages_run_one() {
    local pm="$1"
    local report_dir="$2"
    local state_dir="$3"
    local output_file="$state_dir/$pm.output"
    local status_file="$state_dir/$pm.status"

    if "_global_packages_${pm}_run" "$report_dir" > "$output_file" 2>&1; then
        printf '✅ Success\n' > "$status_file"
    else
        printf '❌ Failed\n' > "$status_file"
    fi
}

global_packages_run() {
    local -n results_map="$1"
    local report_dir="$2"
    local dry_run="$3"
    local status_sink="${4:-}"
    shift 4 || true

    local -a managers=("$@")
    if [[ ${#managers[@]} -eq 0 ]]; then
        managers=("${GLOBAL_PACKAGES_DEFAULT_MANAGERS[@]}")
    fi

    local state_dir
    state_dir="$(mktemp -d "/tmp/global-packages-state.XXXXXX")"

    local -a pending=()
    local pm label status entry failures=0

    for pm in "${managers[@]}"; do
        label="$(_global_packages_label "$pm")"

        if ! _global_packages_supported "$pm"; then
            _global_packages_set_status results_map "$pm" "$label" "❌ Failed" "$status_sink"
            continue
        fi

        if ! _global_packages_installed "$pm"; then
            _global_packages_set_status results_map "$pm" "$label" "⏭️ Not installed" "$status_sink"
            continue
        fi

        if [[ "$dry_run" == true ]]; then
            _global_packages_set_status results_map "$pm" "$label" "🔍 Dry run" "$status_sink"
            continue
        fi

        results_map["label.$pm"]="$label"

        _global_packages_run_one "$pm" "$report_dir" "$state_dir" &
        pending+=("$pm:$!")
    done

    # Collect in start order, so output stays grouped per manager.
    for entry in "${pending[@]}"; do
        pm="${entry%%:*}"
        wait "${entry##*:}" || true
        label="${results_map["label.$pm"]}"
        status="$(< "$state_dir/$pm.status")"
        results_map["status.$pm"]="$status"

        if [[ -s "$state_dir/$pm.output" ]]; then
            if [[ "$status" == "✅ Success" ]]; then
                _global_packages_print_info "$state_dir/$pm.output"
            else
                cat "$state_dir/$pm.output"
            fi
        fi

        _global_packages_emit_status "$status_sink" "$label" "$status"
        [[ "$status" == "❌ Failed" ]] && failures=$((failures + 1))
    done

    rm -rf "$state_dir"

    results_map[failures]="$failures"
    results_map[managers]="${managers[*]}"

    [[ $failures -eq 0 ]]
}
