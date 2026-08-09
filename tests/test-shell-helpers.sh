#!/usr/bin/env bash
# test-shell-helpers.sh - regression tests for scripts/env-set.sh,
# scripts/lib/curl-secrets.sh, and select scripts/init-setup.sh helpers.
#
# Self-contained: no network access, no external services. curl itself is
# replaced by tests/support/mock-curl.sh (via a PATH shim), which records
# what the real curl binary would have received instead of making requests.
# The init-setup.sh tests below use their own small inline mocks instead,
# since they need stateful (per-invocation) curl behavior that
# mock-curl.sh's single MOCK_CURL_EXIT_CODE doesn't support.
#
# Run directly: ./tests/test-shell-helpers.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$TESTS_DIR")"
ORIGINAL_PATH="$PATH"

# shellcheck source=../scripts/lib/curl-secrets.sh
source "$REPO_ROOT/scripts/lib/curl-secrets.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# --- curl mock harness ----------------------------------------------------

MOCK_DIR=""
MOCK_ARGV=""
MOCK_CAPTURE_DIR=""

mock_curl_setup() {
    MOCK_DIR=$(mktemp -d)
    mkdir -p "$MOCK_DIR/bin"
    ln -s "$TESTS_DIR/support/mock-curl.sh" "$MOCK_DIR/bin/curl"
    MOCK_ARGV="$MOCK_DIR/argv.txt"
    MOCK_CAPTURE_DIR="$MOCK_DIR/captures"
    export MOCK_CURL_ARGV_FILE="$MOCK_ARGV"
    export MOCK_CURL_CAPTURE_DIR="$MOCK_CAPTURE_DIR"
    export PATH="$MOCK_DIR/bin:$ORIGINAL_PATH"
}

mock_curl_teardown() {
    PATH="$ORIGINAL_PATH"
    unset MOCK_CURL_ARGV_FILE MOCK_CURL_CAPTURE_DIR
    [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
    MOCK_DIR=""
}

# --- env-set.sh tests -------------------------------------------------

test_env_set_preserves_inode() {
    local dir before after
    dir=$(mktemp -d)
    printf 'FOO=bar\n' > "$dir/.env"
    before=$(stat -c %i "$dir/.env")

    ENV_FILE="$dir/.env" "$REPO_ROOT/scripts/env-set.sh" FOO=baz

    after=$(stat -c %i "$dir/.env")
    if [ "$before" = "$after" ]; then
        pass "env-set.sh does not change the .env inode"
    else
        fail "env-set.sh does not change the .env inode (before=$before after=$after)"
    fi
    rm -rf "$dir"
}

test_env_set_leaves_unrelated_values_alone() {
    local dir
    dir=$(mktemp -d)
    printf '# a comment\nFOO=bar\nOTHER=untouched\n' > "$dir/.env"

    ENV_FILE="$dir/.env" "$REPO_ROOT/scripts/env-set.sh" FOO=changed

    if grep -qxF '# a comment' "$dir/.env" && grep -qxF 'OTHER=untouched' "$dir/.env" \
        && grep -qxF 'FOO=changed' "$dir/.env"; then
        pass "existing unrelated values remain unchanged"
    else
        fail "existing unrelated values remain unchanged"
    fi
    rm -rf "$dir"
}

test_env_set_preserves_equals_in_value() {
    local dir
    dir=$(mktemp -d)
    printf 'FOO=bar\n' > "$dir/.env"

    ENV_FILE="$dir/.env" "$REPO_ROOT/scripts/env-set.sh" 'COMPLEX=a=b=c'

    if grep -qxF 'COMPLEX=a=b=c' "$dir/.env"; then
        pass "values containing = are preserved"
    else
        fail "values containing = are preserved"
    fi
    rm -rf "$dir"
}

test_env_set_appends_new_key() {
    local dir
    dir=$(mktemp -d)
    printf 'FOO=bar\n' > "$dir/.env"

    ENV_FILE="$dir/.env" "$REPO_ROOT/scripts/env-set.sh" NEWKEY=newval

    if grep -qxF 'NEWKEY=newval' "$dir/.env"; then
        pass "new keys are appended"
    else
        fail "new keys are appended"
    fi
    rm -rf "$dir"
}

# --- curl-secrets.sh tests ----------------------------------------------

test_api_header_secret_not_in_argv() {
    mock_curl_setup
    curl -sf -H "X-Api-Key: sup3rSecretApiKey123" -H "Content-Type: application/json" \
        "http://example.invalid/api" >/dev/null

    if grep -q "sup3rSecretApiKey123" "$MOCK_ARGV"; then
        fail "API header secret does not appear in curl argv"
    else
        pass "API header secret does not appear in curl argv"
    fi
    mock_curl_teardown
}

test_smtp_credentials_not_in_argv() {
    mock_curl_setup
    curl -sf --url "smtp://mail.example.invalid:587" \
        --mail-from "from@example.invalid" --mail-rcpt "to@example.invalid" \
        --user "smtpuser:hunter2SMTPpassword" -T - <<< "body" >/dev/null

    if grep -q "hunter2SMTPpassword" "$MOCK_ARGV"; then
        fail "SMTP credentials do not appear in curl argv"
    else
        pass "SMTP credentials do not appear in curl argv"
    fi
    mock_curl_teardown
}

test_data_body_not_in_argv() {
    mock_curl_setup
    curl -sf -X POST -H "Content-Type: application/json" \
        -d '{"name":"sensitive-payload-value"}' "http://example.invalid/" >/dev/null

    if grep -q "sensitive-payload-value" "$MOCK_ARGV"; then
        fail "sensitive request bodies do not appear in curl argv"
    else
        pass "sensitive request bodies do not appear in curl argv"
    fi
    mock_curl_teardown
}

test_data_at_file_reference_passes_through_untouched() {
    mock_curl_setup
    local file
    file=$(mktemp)
    printf '{"from":"file"}' > "$file"

    curl -sf -X POST -d "@$file" "http://example.invalid/" >/dev/null

    # curl (unlike --data-raw) treats a leading "@" as "read the body from
    # this file" — that's not a secret to hide, it's a path, and the file's
    # bytes never touch argv either way. The wrapper must leave it alone
    # rather than bundling the literal string "@path" into a synthetic body.
    if grep -qxF "@$file" "$MOCK_ARGV"; then
        pass "-d @file passes through untouched instead of sending the literal '@path' string"
    else
        fail "-d @file passes through untouched instead of sending the literal '@path' string"
    fi
    rm -f "$file"
    mock_curl_teardown
}

test_data_raw_at_prefix_is_still_literal() {
    mock_curl_setup
    curl -sf -X POST --data-raw '@not-a-real-file' "http://example.invalid/" >/dev/null

    # --data-raw explicitly never interprets a leading "@" as a file
    # reference, so this one *should* still go through the fd as a literal
    # string, unlike -d/--data/--data-binary above.
    if grep -rq '^@not-a-real-file$' "$MOCK_CAPTURE_DIR"; then
        pass "--data-raw with a leading @ is sent as a literal string"
    else
        fail "--data-raw with a leading @ is sent as a literal string"
    fi
    mock_curl_teardown
}

test_values_still_reach_curl_via_fd() {
    mock_curl_setup
    curl -sf -H "X-Api-Key: reachableHeaderSecret" -u "reachableUser:reachablePass" \
        -d '{"k":"reachableBodySecret"}' "http://example.invalid/" >/dev/null

    if grep -rq "reachableHeaderSecret" "$MOCK_CAPTURE_DIR" \
        && grep -rq "reachableUser:reachablePass" "$MOCK_CAPTURE_DIR" \
        && grep -rq "reachableBodySecret" "$MOCK_CAPTURE_DIR"; then
        pass "original values still reach curl through the anonymous file descriptors"
    else
        fail "original values still reach curl through the anonymous file descriptors"
    fi
    mock_curl_teardown
}

test_no_secrets_no_op_passthrough() {
    mock_curl_setup
    curl -s "http://example.invalid/healthcheck" >/dev/null

    if [ "$(cat "$MOCK_ARGV")" = "$(printf -- '-s\nhttp://example.invalid/healthcheck')" ]; then
        pass "calls with no secrets pass through unchanged"
    else
        fail "calls with no secrets pass through unchanged"
    fi
    mock_curl_teardown
}

test_newline_in_header_rejected() {
    mock_curl_setup
    if curl -sf -H "$(printf 'X-Api-Key: bad\nInjected: header')" "http://example.invalid/" >/dev/null 2>/dev/null; then
        fail "newline in header value is rejected"
    else
        pass "newline in header value is rejected"
    fi
    mock_curl_teardown
}

# --- init-setup.sh tests ---------------------------------------------------
#
# init-setup.sh runs its whole setup flow unconditionally when executed (it
# isn't structured with a sourcing guard), so it can't be `source`d directly
# in a test without it trying to configure a real stack. Instead these tests
# extract just the function under test verbatim out of the real file with
# sed (anchored on its unindented opening/closing braces, which every
# function in this file uses) and eval it in an isolated subshell - this
# tests the actual shipped code, not a reimplementation of it, while still
# avoiding any of the file's top-level side effects.

extract_bash_function() {
    local func_name="$1" file="$2"
    sed -n "/^${func_name}() {/,/^}/p" "$file"
}

test_wait_for_service_survives_transport_failure() {
    local mockdir counter func_src result
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    counter="$mockdir/count"
    echo 0 > "$counter"

    # Fails (exit 7, curl's real "couldn't connect" code) for the first two
    # invocations - one for wait_for_service's main -sf check, one for the
    # Transmission-specific %{http_code} check that used to be unguarded -
    # then succeeds on the third, simulating the service coming up during
    # a retry. If the old bare `code=$(curl ...)` bug were still present,
    # the second invocation's failure would raise an uncaught command
    # substitution error under set -e and this subshell would abort
    # instead of reaching a third attempt.
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
n=$(cat "$COUNTER_FILE")
n=$((n + 1))
echo "$n" > "$COUNTER_FILE"
if [ "$n" -lt 3 ]; then
    exit 7
fi
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_bash_function "wait_for_service" "$REPO_ROOT/scripts/init-setup.sh")

    (
        set -euo pipefail
        export COUNTER_FILE="$counter"
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        log_info() { :; }
        log_ok() { :; }
        log_err() { :; }
        sleep() { :; }
        eval "$func_src"
        wait_for_service "Transmission" "http://example.invalid/transmission/rpc"
    )
    result=$?

    if [ "$result" -eq 0 ]; then
        pass "wait_for_service retries past a transport-level curl failure instead of aborting under set -e"
    else
        fail "wait_for_service retries past a transport-level curl failure instead of aborting under set -e (exit=$result)"
    fi
    rm -rf "$mockdir"
}

test_wait_for_service_still_detects_transmission_409() {
    local mockdir counter func_src result
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    counter="$mockdir/count"
    echo 0 > "$counter"

    # Invocation 1 = the main -sf check: fails, as -f does for any non-2xx
    # response (Transmission's real HTTP 409). Invocation 2 = the
    # Transmission-specific check: succeeds and prints "409", the exact
    # signal this function treats as "ready" despite the non-2xx status -
    # pre-existing, unchanged-by-this-fix behavior that must still work.
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
n=$(cat "$COUNTER_FILE")
n=$((n + 1))
echo "$n" > "$COUNTER_FILE"
if [ "$n" -eq 1 ]; then
    exit 22
fi
echo -n "409"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_bash_function "wait_for_service" "$REPO_ROOT/scripts/init-setup.sh")

    (
        set -euo pipefail
        export COUNTER_FILE="$counter"
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        log_info() { :; }
        log_ok() { :; }
        log_err() { :; }
        sleep() { :; }
        eval "$func_src"
        wait_for_service "Transmission" "http://example.invalid/transmission/rpc"
    )
    result=$?

    if [ "$result" -eq 0 ]; then
        pass "wait_for_service still treats a Transmission HTTP 409 as ready"
    else
        fail "wait_for_service still treats a Transmission HTTP 409 as ready (exit=$result)"
    fi
    rm -rf "$mockdir"
}

test_api_call_has_timeouts_and_preserves_existing_flags() {
    local func_src
    func_src=$(extract_bash_function "api_call" "$REPO_ROOT/scripts/init-setup.sh")

    mock_curl_setup
    (
        eval "$func_src"
        api_call POST "http://example.invalid/api/v3/indexer" "test-api-key" '{"name":"test"}' >/dev/null
    )

    # --connect-timeout/--max-time and the method/URL are not secrets, so
    # curl-secrets.sh's wrapper (sourced by init-setup.sh) passes them
    # through to argv untouched - but the API key header and JSON body ARE
    # secrets it deliberately diverts into anonymous-fd captures instead
    # (see the curl-secrets.sh tests above), so those two are checked in
    # $MOCK_CAPTURE_DIR, not $MOCK_ARGV, matching how curl actually receives
    # them.
    if grep -qxF -- '--connect-timeout' "$MOCK_ARGV" && grep -qxF -- '--max-time' "$MOCK_ARGV"; then
        pass "api_call includes --connect-timeout and --max-time"
    else
        fail "api_call includes --connect-timeout and --max-time"
    fi

    if grep -qxF -- 'POST' "$MOCK_ARGV" && grep -qxF -- 'http://example.invalid/api/v3/indexer' "$MOCK_ARGV" \
        && grep -rq "X-Api-Key: test-api-key" "$MOCK_CAPTURE_DIR" && grep -rq '{"name":"test"}' "$MOCK_CAPTURE_DIR"; then
        pass "api_call preserves its existing method/url/header/data flags unchanged"
    else
        fail "api_call preserves its existing method/url/header/data flags unchanged"
    fi
    mock_curl_teardown
}

# --- run everything -------------------------------------------------------

test_env_set_preserves_inode
test_env_set_leaves_unrelated_values_alone
test_env_set_preserves_equals_in_value
test_env_set_appends_new_key
test_api_header_secret_not_in_argv
test_smtp_credentials_not_in_argv
test_data_body_not_in_argv
test_data_at_file_reference_passes_through_untouched
test_data_raw_at_prefix_is_still_literal
test_values_still_reach_curl_via_fd
test_no_secrets_no_op_passthrough
test_newline_in_header_rejected
test_wait_for_service_survives_transport_failure
test_wait_for_service_still_detects_transmission_409
test_api_call_has_timeouts_and_preserves_existing_flags

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
