#!/usr/bin/env bash
# Pure parser functions for package manager output.
# No dependencies on global script state (REPORT_DIR, log_status, etc.).
# All functions operate on text in/out — testable with heredocs.

# Colors (set by caller via pm_helpers_set_colors, or defaults)
_PM_GREEN="${_PM_GREEN:-\033[0;32m}"
_PM_NC="${_PM_NC:-\033[0m}"

pm_helpers_set_colors() {
    _PM_GREEN="$1"
    _PM_NC="$2"
}

# --- npm ---

# Parse npm list -g --depth=0 tree output into an associative array.
# Usage: parse_npm_tree <assoc_array_name> < output
# Populates assoc array with name=version for each package.
parse_npm_tree() {
    local -n _out="$1"
    local pkg name version
    while IFS= read -r pkg; do
        name="${pkg%@*}"
        version="${pkg##*@}"
        [[ -z "$name" || "$name" == "$pkg" || -z "$version" ]] && continue
        _out["$name"]="$version"
    done < <(sed -nE 's/^[[:space:]]*([├└]── |\+-- |`-- )(.+)$/\2/p')
}

# --- bun ---

# Parse bun pm ls -g tree output into an associative array.
# Usage: parse_bun_tree <assoc_array_name> < output
# Expects lines like "├── pkg@version" or "└── pkg@version".
parse_bun_tree() {
    local -n _out="$1"
    local line pkg name version
    while IFS= read -r line; do
        [[ "$line" =~ ^[├└] ]] || continue
        pkg="$(echo "$line" | awk '{print $NF}')"
        name="${pkg%@*}"
        version="${pkg##*@}"
        [[ -z "$name" || "$name" == "$pkg" || -z "$version" ]] && continue
        _out["$name"]="$version"
    done
}

# --- pipx ---

# Parse pipx upgrade-all output and print colored version diff lines.
# Usage: parse_pipx_output < output
# Prints lines like "  ↑ pkg: old → new" for each upgraded package.
# Outputs a summary line ("All pipx packages already up to date." or "Updated N pipx package(s).").
parse_pipx_output() {
    local updated=0
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ upgraded\ (.+)\ from\ (.+)\ to\ (.+) ]]; then
            echo -e "${_PM_GREEN}  ↑ ${BASH_REMATCH[1]}: ${BASH_REMATCH[2]} → ${BASH_REMATCH[3]}${_PM_NC}"
            ((updated++))
        elif [[ "$line" =~ (.+)\ upgraded\ (.+)\ -\>\ (.+) ]]; then
            echo -e "${_PM_GREEN}  ↑ ${BASH_REMATCH[1]}: ${BASH_REMATCH[2]} → ${BASH_REMATCH[3]}${_PM_NC}"
            ((updated++))
        fi
    done
    if [[ $updated -eq 0 ]]; then
        echo "All pipx packages already up to date."
    else
        echo "Updated $updated pipx package(s)."
    fi
}

# --- shared ---

# Print version diff between two associative arrays.
# Usage: print_version_diff <old_assoc_name> <new_assoc_name>
# Prints "  ↑ name: old → new" for each package whose version changed.
print_version_diff() {
    local -n _old="$1"
    local -n _new="$2"
    local name old_ver new_ver
    local updated=0
    for name in "${!_old[@]}"; do
        old_ver="${_old[$name]}"
        new_ver="${_new[$name]:-}"
        if [[ -n "$new_ver" && "$old_ver" != "$new_ver" ]]; then
            echo -e "${_PM_GREEN}  ↑ $name: $old_ver → $new_ver${_PM_NC}"
            ((updated++))
        fi
    done
    return 0
}

# Map associative array entries to "name@latest" strings.
# Usage: map_to_latest <assoc_array_name> [exclude...]
# Prints one "name@latest" per line for each entry, optionally excluding names.
map_to_latest() {
    local -n _pkgs="$1"
    shift
    local name
    for name in "${!_pkgs[@]}"; do
        local skip=false
        local excl
        for excl in "$@"; do
            [[ "$name" == "$excl" ]] && { skip=true; break; }
        done
        $skip || echo "${name}@latest"
    done
}
