#!/usr/bin/env bash
# curl-secrets.sh - keep curl secrets out of argv (ps / /proc/<pid>/cmdline)
#
# `curl -H "X-Api-Key: $KEY"` (or -u/--user, -d/--data) puts the secret
# directly in this process's command-line arguments, visible to any other
# local user on the host for the life of the call. Sourcing this file
# shadows `curl` with a function that rewrites those arguments so the real
# curl process only ever sees /dev/fd/<N> paths on its argv — the actual
# header/credential/body bytes are delivered through anonymous file
# descriptors (bash process substitution) instead.
#
# Usage: source this file, then call `curl` exactly as before.
#   source "$SCRIPT_DIR/lib/curl-secrets.sh"
#   curl -sf -H "X-Api-Key: $KEY" "$url"
#
# Handles: -H/--header, -u/--user, -d/--data/--data-raw/--data-binary.
# Everything else passes through untouched. Calls `command curl` at the
# end so this cannot recurse into itself.

_curl_secrets_reject_newline() {
    # $1 = value to check, $2 = label used in the error message
    case "$1" in
        *$'\n'*|*$'\r'*)
            echo "curl-secrets: refusing to pass $2 containing a newline to curl" >&2
            return 1
            ;;
    esac
}

_curl_secrets_escape() {
    # Escape backslash and double-quote so $1 can be embedded as a
    # double-quoted value in a curl --config file.
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

curl() {
    local -a passthrough=()
    local -a config_lines=()
    local -a data_chunks=()
    local have_config=0
    local have_data=0
    local escaped=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -H|--header)
                _curl_secrets_reject_newline "$2" "a header value" || return 1
                escaped=$(_curl_secrets_escape "$2")
                config_lines+=("header = \"$escaped\"")
                have_config=1
                shift 2
                ;;
            --header=*)
                _curl_secrets_reject_newline "${1#--header=}" "a header value" || return 1
                escaped=$(_curl_secrets_escape "${1#--header=}")
                config_lines+=("header = \"$escaped\"")
                have_config=1
                shift
                ;;
            -u|--user)
                _curl_secrets_reject_newline "$2" "credentials" || return 1
                escaped=$(_curl_secrets_escape "$2")
                config_lines+=("user = \"$escaped\"")
                have_config=1
                shift 2
                ;;
            --user=*)
                _curl_secrets_reject_newline "${1#--user=}" "credentials" || return 1
                escaped=$(_curl_secrets_escape "${1#--user=}")
                config_lines+=("user = \"$escaped\"")
                have_config=1
                shift
                ;;
            -d|--data|--data-raw|--data-binary)
                data_chunks+=("$2")
                have_data=1
                shift 2
                ;;
            --data=*)
                data_chunks+=("${1#--data=}")
                have_data=1
                shift
                ;;
            --data-raw=*)
                data_chunks+=("${1#--data-raw=}")
                have_data=1
                shift
                ;;
            --data-binary=*)
                data_chunks+=("${1#--data-binary=}")
                have_data=1
                shift
                ;;
            *)
                passthrough+=("$1")
                shift
                ;;
        esac
    done

    if [ "$have_config" -eq 0 ] && [ "$have_data" -eq 0 ]; then
        command curl "${passthrough[@]}"
        return $?
    fi

    local joined_data=""
    if [ "$have_data" -eq 1 ]; then
        local IFS='&'
        joined_data="${data_chunks[*]}"
        unset IFS
    fi

    if [ "$have_config" -eq 1 ] && [ "$have_data" -eq 1 ]; then
        command curl \
            --config <(printf '%s\n' "${config_lines[@]}") \
            --data-binary "@"<(printf '%s' "$joined_data") \
            "${passthrough[@]}"
        return $?
    fi

    if [ "$have_config" -eq 1 ]; then
        command curl \
            --config <(printf '%s\n' "${config_lines[@]}") \
            "${passthrough[@]}"
        return $?
    fi

    command curl \
        --data-binary "@"<(printf '%s' "$joined_data") \
        "${passthrough[@]}"
    return $?
}
