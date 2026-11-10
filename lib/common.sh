#!/usr/bin/env bash
# Helpers shared by the update-all libraries.

# call_if_defined <function> [args...]: call the named function when it
# exists; fail (without output) when the name is empty or undefined. Used for
# optional callbacks such as status sinks and progress reporters.
call_if_defined() {
    local fn="${1:-}"
    shift || true
    [[ -n "$fn" ]] || return 1
    declare -F "$fn" >/dev/null || return 1
    "$fn" "$@"
}
