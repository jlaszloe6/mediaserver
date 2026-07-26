#!/usr/bin/env bash
# mock-curl.sh - stand-in for the real curl binary, used by test-shell-helpers.sh
#
# curl-secrets.sh calls `command curl ...`, which resolves via PATH lookup
# just like any other command. Tests prepend a directory containing this
# script (named exactly "curl") onto PATH, so `command curl` invokes this
# mock instead of hitting the network.
#
# It records every argument it was called with (one per line) to
# MOCK_CURL_ARGV_FILE, and for any argument that is (or starts with "@" and
# is) a /dev/fd or /proc/self/fd path, it copies that fd's content into
# MOCK_CURL_CAPTURE_DIR so a test can assert the real value made it to curl
# even though it never appeared in argv.
#
# Required env vars: MOCK_CURL_ARGV_FILE, MOCK_CURL_CAPTURE_DIR
# Optional env vars: MOCK_CURL_EXIT_CODE (default 0)

set -euo pipefail

: "${MOCK_CURL_ARGV_FILE:?MOCK_CURL_ARGV_FILE must be set}"
: "${MOCK_CURL_CAPTURE_DIR:?MOCK_CURL_CAPTURE_DIR must be set}"

mkdir -p "$MOCK_CURL_CAPTURE_DIR"
: > "$MOCK_CURL_ARGV_FILE"

n=0
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$MOCK_CURL_ARGV_FILE"

    path="$arg"
    case "$arg" in
        @*) path="${arg#@}" ;;
    esac

    case "$path" in
        /dev/fd/*|/proc/self/fd/*)
            n=$((n + 1))
            cat "$path" > "$MOCK_CURL_CAPTURE_DIR/fd-$n.captured" 2>/dev/null || true
            ;;
    esac
done

exit "${MOCK_CURL_EXIT_CODE:-0}"
