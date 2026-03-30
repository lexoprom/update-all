#!/usr/bin/env bash

GLOBAL_PACKAGES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pm-helpers.sh
source "$GLOBAL_PACKAGES_LIB_DIR/pm-helpers.sh"

declare -grA GLOBAL_PACKAGES_LABELS=(
    [pipx]="pipx packages"
    [npm]="npm global packages"
    [bun]="bun global packages"
)

declare -gra GLOBAL_PACKAGES_DEFAULT_MANAGERS=(pipx npm bun)

_global_packages_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_global_packages_label() {
    printf '%s' "${GLOBAL_PACKAGES_LABELS[$1]:-$1 packages}"
}

_global_packages_emit_status() {
    local sink="$1"
    local label="$2"
    local status="$3"
    [[ -n "$sink" ]] || return 0
    declare -F "$sink" >/dev/null || return 0
    "$sink" "$label" "$status"
}

_global_packages_supported() {
    declare -F "_global_packages_${1}_installed" >/dev/null &&
        declare -F "_global_packages_${1}_run" >/dev/null
}

_global_packages_pipx_installed() { _global_packages_command_exists pipx; }
_global_packages_pipx_run() {
    local report_dir="$1"
    local red="${RED:-\033[0;31m}"
    local nc="${NC:-\033[0m}"

    if pipx upgrade-all > "$report_dir/pipx.log" 2>&1; then
        parse_pipx_output < "$report_dir/pipx.log"
    else
        echo -e "${red}⚠️ Pipx upgrade failed. Details:${nc}"
        cat "$report_dir/pipx.log"
        return 1
    fi
}

_global_packages_npm_installed() { _global_packages_command_exists npm; }
_global_packages_npm_run() {
    local report_dir="$1"
    local red="${RED:-\033[0;31m}"
    local nc="${NC:-\033[0m}"

    declare -A old_versions=()
    parse_npm_tree old_versions < <(npm list -g --depth=0 2>/dev/null)

    local -a packages=()
    readarray -t packages < <(map_to_latest old_versions npm)

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No global npm packages detected."
        return 0
    fi

    echo "Updating npm globals: ${packages[*]}"
    if npm install -g "${packages[@]}" > "$report_dir/npm_install.log" 2>&1; then
        declare -A new_versions=()
        parse_npm_tree new_versions < <(npm list -g --depth=0 2>/dev/null)
        print_version_diff old_versions new_versions
    else
        echo -e "${red}⚠️ npm update failed. Details:${nc}"
        cat "$report_dir/npm_install.log"
        return 1
    fi
}

_global_packages_bun_installed() { _global_packages_command_exists bun; }
_global_packages_bun_run() {
    local report_dir="$1"
    local red="${RED:-\033[0;31m}"
    local nc="${NC:-\033[0m}"
    local workdir
    local exit_code=0

    workdir="$(mktemp -d "/tmp/global-packages-bun.XXXXXX")"

    declare -A old_versions=()
    parse_bun_tree old_versions < <(cd "$workdir" && bun pm ls -g 2>/dev/null)

    local -a packages=()
    readarray -t packages < <(map_to_latest old_versions)

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No global Bun packages detected."
        rm -rf "$workdir"
        return 0
    fi

    echo "Updating Bun globals: ${packages[*]}"
    if (cd "$workdir" && bun add -g "${packages[@]}") > "$report_dir/bun_install.log" 2>&1; then
        declare -A new_versions=()
        parse_bun_tree new_versions < <(cd "$workdir" && bun pm ls -g 2>/dev/null)
        print_version_diff old_versions new_versions
    else
        echo -e "${red}⚠️ Bun update failed. Details:${nc}"
        cat "$report_dir/bun_install.log"
        exit_code=1
    fi

    rm -rf "$workdir"
    return $exit_code
}

_global_packages_run_one() {
    local pm="$1"
    local report_dir="$2"
    local state_dir="$3"
    local output_file="$state_dir/$pm.output"
    local status_file="$state_dir/$pm.status"
    local exit_code

    set +e
    "_global_packages_${pm}_run" "$report_dir" > "$output_file" 2>&1
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        printf '✅ Success\n' > "$status_file"
    else
        printf '❌ Failed\n' > "$status_file"
    fi
}

global_packages_run() {
    local -n _result="$1"
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
    local pm label status pid entry failures=0

    for pm in "${managers[@]}"; do
        label="$(_global_packages_label "$pm")"
        _result["label.$pm"]="$label"

        if ! _global_packages_supported "$pm"; then
            status="❌ Failed"
            _result["status.$pm"]="$status"
            _global_packages_emit_status "$status_sink" "$label" "$status"
            continue
        fi

        if ! "_global_packages_${pm}_installed"; then
            status="⏭️ Not installed"
            _result["status.$pm"]="$status"
            _global_packages_emit_status "$status_sink" "$label" "$status"
            continue
        fi

        if [[ "$dry_run" == true ]]; then
            status="🔍 Dry run"
            _result["status.$pm"]="$status"
            _global_packages_emit_status "$status_sink" "$label" "$status"
            continue
        fi

        _global_packages_run_one "$pm" "$report_dir" "$state_dir" &
        pid=$!
        pending+=("$pm:$pid")
    done

    if [[ ${#pending[@]} -gt 0 ]]; then
        echo "Waiting for package managers..."
        for entry in "${pending[@]}"; do
            pid="${entry##*:}"
            wait "$pid"
        done
    fi

    for entry in "${pending[@]}"; do
        pm="${entry%%:*}"
        label="${_result["label.$pm"]}"
        status="$(< "$state_dir/$pm.status")"
        _result["status.$pm"]="$status"

        if [[ -s "$state_dir/$pm.output" ]]; then
            cat "$state_dir/$pm.output"
        fi

        _global_packages_emit_status "$status_sink" "$label" "$status"
        [[ "$status" == "❌ Failed" ]] && ((failures++))
    done

    rm -rf "$state_dir"

    _result[failures]="$failures"
    _result[managers]="${managers[*]}"

    [[ $failures -eq 0 ]]
}
