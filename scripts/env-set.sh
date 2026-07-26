#!/usr/bin/env bash
# env-set.sh - update a single KEY=VALUE pair in .env without changing its inode
#
# `sed -i` (and any other edit that renames a temp file over the original
# path) gives the file a NEW inode. A container that already has the old
# path bind-mounted keeps referencing the OLD inode, so it silently keeps
# serving the pre-edit content until it's recreated — even though `cat
# .env` on the host looks completely correct. See issue #85.
#
# This script edits the file's existing inode directly: it builds the new
# content in a temp file, then copies (truncate + write) that content over
# the original path — never renaming anything onto it.
#
# Usage:
#   ./scripts/env-set.sh KEY=VALUE
#   ENV_FILE=/path/to/.env ./scripts/env-set.sh KEY=VALUE
#
# - VALUE may itself contain "=" characters (only the first "=" splits).
# - KEY must match [A-Za-z_][A-Za-z0-9_]*
# - VALUE must not contain a newline.
# - If KEY already exists (possibly more than once, by accident), all
#   occurrences collapse into a single line at the first occurrence's
#   position, holding the new value.
# - If KEY does not exist, it's appended.

set -euo pipefail

usage() {
    echo "Usage: $0 KEY=VALUE" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage

arg="$1"
case "$arg" in
    *=*) ;;
    *)
        echo "env-set: expected KEY=VALUE, got: $arg" >&2
        exit 1
        ;;
esac

key=${arg%%=*}
value=${arg#*=}

case "$key" in
    [A-Za-z_]*) ;;
    *)
        echo "env-set: invalid variable name: $key" >&2
        exit 1
        ;;
esac
case "$key" in
    *[!A-Za-z0-9_]*)
        echo "env-set: invalid variable name: $key" >&2
        exit 1
        ;;
esac

case "$value" in
    *$'\n'*)
        echo "env-set: value for $key must not contain a newline" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${ENV_FILE:-$SCRIPT_DIR/../.env}"

tmp=$(mktemp)
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

found=0
if [ -f "$TARGET" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                if [ "$found" -eq 0 ]; then
                    printf '%s=%s\n' "$key" "$value" >> "$tmp"
                    found=1
                fi
                # any further occurrence (the first, or an accidental
                # duplicate) is dropped — it's already been written once
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$TARGET"
fi

if [ "$found" -eq 0 ]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
fi

# Truncate + write into the EXISTING inode at $TARGET — never mv/rename,
# which would swap in a new inode and strand any live bind mount.
cat "$tmp" > "$TARGET"
