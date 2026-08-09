#!/usr/bin/env bash
# test-shell-helpers.sh - regression tests for scripts/env-set.sh,
# scripts/lib/curl-secrets.sh, select scripts/init-setup.sh helpers, and
# caddy/download-geodb.sh + caddy/entrypoint.sh.
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
    local mockdir func_src result
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"

    # Simulates a server that always answers HTTP 409, based on the actual
    # curl flags received rather than call order: real curl with -f fails
    # (exit 22, no body) on any non-2xx status, while without -f it
    # succeeds and delivers the raw status via -w. This is what actually
    # protects the transport-failure-vs-HTTP-409 distinction - a
    # call-order-based mock would stay green even if `-f` were accidentally
    # added to the Transmission-specific probe, even though real curl
    # would then exit 22 there too and the service would never be marked
    # ready.
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        -*f*) exit 22 ;;
    esac
done
echo -n "409"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_bash_function "wait_for_service" "$REPO_ROOT/scripts/init-setup.sh")

    (
        set -euo pipefail
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

# fetch_existing() depends on parse_response() and api_call(), so all three
# get extracted and eval'd together.
extract_init_setup_get_helpers() {
    printf '%s\n%s\n%s\n' \
        "$(extract_bash_function "parse_response" "$REPO_ROOT/scripts/init-setup.sh")" \
        "$(extract_bash_function "api_call" "$REPO_ROOT/scripts/init-setup.sh")" \
        "$(extract_bash_function "fetch_existing" "$REPO_ROOT/scripts/init-setup.sh")"
}

test_fetch_existing_returns_body_on_success() {
    local mockdir func_src output result
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    # Simulates a real 2xx response with a body, in the exact combined
    # shape curl's own -w '\n%{http_code}' produces: body, then a newline,
    # then the status code. An empty-array body here would be just as
    # valid a "success" - this specifically uses a non-empty one to also
    # confirm the body round-trips correctly, not just that 2xx is accepted.
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n200' '{"records":[]}'
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_init_setup_get_helpers)

    output=$(
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        log_err() { :; }
        eval "$func_src"
        fetch_existing "http://example.invalid/api" "test-key" "test resource"
    )
    result=$?

    if [ "$result" -eq 0 ] && [ "$output" = '{"records":[]}' ]; then
        pass "fetch_existing returns the response body on a 2xx status"
    else
        fail "fetch_existing returns the response body on a 2xx status (result=$result output='$output')"
    fi
    rm -rf "$mockdir"
}

test_fetch_existing_reports_http_error_distinctly() {
    local mockdir func_src logfile result log_content
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    logfile="$mockdir/log"
    : > "$logfile"
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n401' '{"error":"Unauthorized"}'
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_init_setup_get_helpers)

    (
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        export LOGFILE="$logfile"
        log_err() { echo "$*" >> "$LOGFILE"; }
        eval "$func_src"
        fetch_existing "http://example.invalid/api" "test-key" "test resource" > /dev/null
    )
    result=$?
    log_content=$(cat "$logfile" 2>/dev/null)

    if [ "$result" -eq 1 ] && echo "$log_content" | grep -q "HTTP 401" \
        && ! echo "$log_content" | grep -qi "transport"; then
        pass "fetch_existing reports a real HTTP error distinctly, not as a transport failure"
    else
        fail "fetch_existing reports a real HTTP error distinctly (result=$result, log='$log_content')"
    fi
    rm -rf "$mockdir"
}

test_fetch_existing_distinguishes_transport_failure() {
    local mockdir func_src logfile result log_content
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    logfile="$mockdir/log"
    : > "$logfile"
    # curl itself fails outright (no HTTP transaction at all) - api_call's
    # curl has no -f, so this is the only way RESP_CODE ends up "000"
    # rather than a real status.
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
exit 7
MOCKEOF
    chmod +x "$mockdir/bin/curl"

    func_src=$(extract_init_setup_get_helpers)

    (
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        export LOGFILE="$logfile"
        log_err() { echo "$*" >> "$LOGFILE"; }
        eval "$func_src"
        fetch_existing "http://example.invalid/api" "test-key" "test resource" > /dev/null
    )
    result=$?
    log_content=$(cat "$logfile" 2>/dev/null)

    if [ "$result" -eq 1 ] && echo "$log_content" | grep -qi "connection/transport error or timeout"; then
        pass "fetch_existing reports a transport/timeout failure distinctly, not as an HTTP response"
    else
        fail "fetch_existing reports a transport/timeout failure distinctly (result=$result, log='$log_content')"
    fi
    rm -rf "$mockdir"
}

test_init_setup_no_unguarded_curl_sf() {
    local file="$REPO_ROOT/scripts/init-setup.sh"
    local bad_lines
    # Every remaining `curl -sf` in the file must be either: the
    # wait_for_service main readiness check (used as an if-condition, so
    # set -e doesn't apply to its own failure), a comment, or already
    # guarded with `||`. Anything else is a leftover unguarded fetch that
    # should have been migrated to fetch_existing() - this is a static
    # tripwire against silently missing one during a future edit, not a
    # substitute for the functional tests above.
    bad_lines=$(grep -n 'curl -sf' "$file" | grep -vE '^[0-9]+: *if curl -sf' | grep -v '^[0-9]*:#' | grep -v '||')

    if [ -z "$bad_lines" ]; then
        pass "init-setup.sh has no unguarded 'curl -sf' assignments left"
    else
        fail "init-setup.sh has no unguarded 'curl -sf' assignments left - found: $bad_lines"
    fi
}

# --- caddy/download-geodb.sh and caddy/entrypoint.sh tests -----------------
#
# Both are standalone POSIX /bin/sh scripts (not bash functions), so they
# run as real subprocesses via `sh` rather than being extracted/eval'd like
# the init-setup.sh helpers above - this also genuinely exercises them
# under their actual intended interpreter, not bash's superset of it.

make_geodb_fixture_tarball() {
    local out="$1"
    local workdir
    workdir=$(mktemp -d)
    mkdir -p "$workdir/GeoLite2-Country_fixture"
    printf 'fake-mmdb-content' > "$workdir/GeoLite2-Country_fixture/GeoLite2-Country.mmdb"
    (cd "$workdir" && tar -czf "$out" GeoLite2-Country_fixture)
    rm -rf "$workdir"
}

write_mock_curl_for_geodb() {
    local mockdir="$1"
    mkdir -p "$mockdir/bin"
    # Parses just enough of curl's argv (the -o output path) to behave
    # like real curl would for download-geodb.sh's fixed invocation shape,
    # branching on $MOCK_MODE. Mirrors real curl's actual --fail behavior
    # (verified directly beforehand): on an HTTP error the -o file is never
    # written and %{http_code} still reports the real code; on a transport
    # failure neither the file nor a real code ever materializes ("000").
    cat > "$mockdir/bin/curl" <<'MOCKEOF'
#!/bin/sh
outfile=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
        outfile="$arg"
    fi
    prev="$arg"
done

case "$MOCK_MODE" in
    success)
        cp "$MOCK_FIXTURE_TARBALL" "$outfile"
        printf '200'
        exit 0
        ;;
    invalid_archive)
        printf 'this is not a valid gzip archive' > "$outfile"
        printf '200'
        exit 0
        ;;
    http_error)
        printf '404'
        exit 22
        ;;
    transport_error)
        printf '000'
        exit 6
        ;;
    *)
        echo "mock curl: unknown MOCK_MODE '$MOCK_MODE'" >&2
        exit 99
        ;;
esac
MOCKEOF
    chmod +x "$mockdir/bin/curl"
}

# Runs a patched copy of the real download-geodb.sh (only $DB_DIR
# redirected to a scratch directory - everything else is the shipped
# script, unmodified) under the given mock curl mode. Sets
# DOWNLOAD_GEODB_EXIT, DOWNLOAD_GEODB_DB_DIR, and DOWNLOAD_GEODB_OUTPUT
# (combined stdout+stderr) for the caller to inspect; called directly
# (never inside its own subshell) so those globals aren't lost the way
# subshell-local variables would be.
#
# Capturing OUTPUT matters, not just the exit code: the *old* script also
# aborts cleanly (via bare set -e, no -f/-w) on a failing curl or a bad
# tar - it just does so with no diagnostic at all (old curl has -s with no
# --show-error) or a confusing raw tar error, not a real gap in "does it
# stop." The actual improvement here is a clear, distinguishing message,
# which only an output-content check can verify.
run_download_geodb() {
    local mock_mode="$1" mockdir="$2"
    DOWNLOAD_GEODB_DB_DIR=$(mktemp -d)

    local script_copy="$mockdir/download-geodb.sh"
    cp "$REPO_ROOT/caddy/download-geodb.sh" "$script_copy"
    sed -i "s#^DB_DIR=\"/data/geolite2\"#DB_DIR=\"$DOWNLOAD_GEODB_DB_DIR\"#" "$script_copy"
    chmod +x "$script_copy"

    DOWNLOAD_GEODB_OUTPUT=$(
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        export MOCK_MODE="$mock_mode"
        export MAXMIND_LICENSE_KEY="test-license-key"
        sh "$script_copy" 2>&1
    )
    DOWNLOAD_GEODB_EXIT=$?
}

test_download_geodb_success_installs_db_atomically() {
    local mockdir fixture leftover_tmp db_file
    mockdir=$(mktemp -d)
    write_mock_curl_for_geodb "$mockdir"
    fixture="$mockdir/fixture.tar.gz"
    make_geodb_fixture_tarball "$fixture"

    export MOCK_FIXTURE_TARBALL="$fixture"
    run_download_geodb success "$mockdir"
    unset MOCK_FIXTURE_TARBALL

    db_file="$DOWNLOAD_GEODB_DB_DIR/GeoLite2-Country.mmdb"
    leftover_tmp=$(find "$DOWNLOAD_GEODB_DB_DIR" -maxdepth 1 -name '.download-*' 2>/dev/null)

    if [ "$DOWNLOAD_GEODB_EXIT" -eq 0 ] && [ -f "$db_file" ] \
        && [ "$(cat "$db_file")" = "fake-mmdb-content" ] && [ -z "$leftover_tmp" ]; then
        pass "download-geodb.sh installs the database atomically on success, with no leftover temp dir"
    else
        fail "download-geodb.sh installs the database atomically on success (exit=$DOWNLOAD_GEODB_EXIT, leftover='$leftover_tmp')"
    fi
    rm -rf "$mockdir" "$DOWNLOAD_GEODB_DB_DIR"
}

test_download_geodb_http_error_leaves_no_db_file() {
    local mockdir db_file leftover_tmp
    mockdir=$(mktemp -d)
    write_mock_curl_for_geodb "$mockdir"

    run_download_geodb http_error "$mockdir"

    db_file="$DOWNLOAD_GEODB_DB_DIR/GeoLite2-Country.mmdb"
    leftover_tmp=$(find "$DOWNLOAD_GEODB_DB_DIR" -maxdepth 1 -name '.download-*' 2>/dev/null)

    # Checking the message content (not just exit code/file absence)
    # matters: the *old* script also died via bare set -e on any curl
    # failure, exit code and file absence alone don't distinguish that
    # from the fix - only the diagnostic being clear and specifically
    # naming "HTTP 404" (not a raw/confusing tar error, not silence) does.
    if [ "$DOWNLOAD_GEODB_EXIT" -ne 0 ] && [ ! -e "$db_file" ] && [ -z "$leftover_tmp" ] \
        && echo "$DOWNLOAD_GEODB_OUTPUT" | grep -q "HTTP 404"; then
        pass "download-geodb.sh fails cleanly on an HTTP error with a clear, specific diagnostic"
    else
        fail "download-geodb.sh fails cleanly on an HTTP error with a clear diagnostic (exit=$DOWNLOAD_GEODB_EXIT, leftover='$leftover_tmp', output='$DOWNLOAD_GEODB_OUTPUT')"
    fi
    rm -rf "$mockdir" "$DOWNLOAD_GEODB_DB_DIR"
}

test_download_geodb_transport_error_leaves_no_db_file() {
    local mockdir db_file leftover_tmp
    mockdir=$(mktemp -d)
    write_mock_curl_for_geodb "$mockdir"

    run_download_geodb transport_error "$mockdir"

    db_file="$DOWNLOAD_GEODB_DB_DIR/GeoLite2-Country.mmdb"
    leftover_tmp=$(find "$DOWNLOAD_GEODB_DB_DIR" -maxdepth 1 -name '.download-*' 2>/dev/null)

    # Same reasoning as the HTTP-error test above: must say "connection/
    # transport error or timeout" distinctly, not "000" as if that were a
    # real HTTP response, and not the old script's silence (-s with no
    # --show-error produced no diagnostic here at all).
    if [ "$DOWNLOAD_GEODB_EXIT" -ne 0 ] && [ ! -e "$db_file" ] && [ -z "$leftover_tmp" ] \
        && echo "$DOWNLOAD_GEODB_OUTPUT" | grep -qi "connection/transport error or timeout"; then
        pass "download-geodb.sh fails cleanly on a transport/timeout error with a clear, distinct diagnostic"
    else
        fail "download-geodb.sh fails cleanly on a transport/timeout error with a clear diagnostic (exit=$DOWNLOAD_GEODB_EXIT, leftover='$leftover_tmp', output='$DOWNLOAD_GEODB_OUTPUT')"
    fi
    rm -rf "$mockdir" "$DOWNLOAD_GEODB_DB_DIR"
}

test_download_geodb_invalid_archive_leaves_no_db_file() {
    local mockdir db_file leftover_tmp
    mockdir=$(mktemp -d)
    write_mock_curl_for_geodb "$mockdir"

    run_download_geodb invalid_archive "$mockdir"

    db_file="$DOWNLOAD_GEODB_DB_DIR/GeoLite2-Country.mmdb"
    leftover_tmp=$(find "$DOWNLOAD_GEODB_DB_DIR" -maxdepth 1 -name '.download-*' 2>/dev/null)

    # The old script would fail here too (tar aborts, set -e kills it),
    # but only via tar's own raw, unlabeled error text - this checks for
    # the new script's explicit "ERROR: ... not a valid gzip/tar file"
    # message specifically.
    if [ "$DOWNLOAD_GEODB_EXIT" -ne 0 ] && [ ! -e "$db_file" ] && [ -z "$leftover_tmp" ] \
        && echo "$DOWNLOAD_GEODB_OUTPUT" | grep -q "not a valid gzip/tar file"; then
        pass "download-geodb.sh fails cleanly on a non-gzip/invalid response body with a clear diagnostic"
    else
        fail "download-geodb.sh fails cleanly on a non-gzip/invalid response body with a clear diagnostic (exit=$DOWNLOAD_GEODB_EXIT, leftover='$leftover_tmp', output='$DOWNLOAD_GEODB_OUTPUT')"
    fi
    rm -rf "$mockdir" "$DOWNLOAD_GEODB_DB_DIR"
}

test_caddy_entrypoint_does_not_start_caddy_when_geodb_fails() {
    local mockdir entrypoint_copy caddy_marker result
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    caddy_marker="$mockdir/caddy-was-started"

    cat > "$mockdir/bin/caddy" <<MOCKEOF
#!/bin/sh
touch "$caddy_marker"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/caddy"

    # Simulates a completely unavailable GeoIP database - the exact
    # scenario that must not let Caddy start (fail-closed).
    cat > "$mockdir/bin/download-geodb.sh" <<'MOCKEOF'
#!/bin/sh
echo "mock: simulating a failed GeoDB download" >&2
exit 1
MOCKEOF
    chmod +x "$mockdir/bin/download-geodb.sh"

    entrypoint_copy="$mockdir/entrypoint.sh"
    cp "$REPO_ROOT/caddy/entrypoint.sh" "$entrypoint_copy"
    sed -i "s#/usr/local/bin/download-geodb.sh#$mockdir/bin/download-geodb.sh#" "$entrypoint_copy"
    sed -i "s#DB_FILE=\"/data/geolite2/GeoLite2-Country.mmdb\"#DB_FILE=\"$mockdir/nonexistent.mmdb\"#" "$entrypoint_copy"
    chmod +x "$entrypoint_copy"

    (
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        sh "$entrypoint_copy"
    )
    result=$?

    if [ "$result" -ne 0 ] && [ ! -e "$caddy_marker" ]; then
        pass "entrypoint.sh does not start Caddy when GeoDB acquisition fails (fail-closed preserved)"
    else
        fail "entrypoint.sh does not start Caddy when GeoDB acquisition fails (exit=$result, caddy_started=$([ -e "$caddy_marker" ] && echo yes || echo no))"
    fi
    rm -rf "$mockdir"
}

test_caddy_entrypoint_starts_caddy_when_geodb_succeeds() {
    local mockdir entrypoint_copy caddy_marker result db_file
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    caddy_marker="$mockdir/caddy-was-started"
    db_file="$mockdir/GeoLite2-Country.mmdb"

    cat > "$mockdir/bin/caddy" <<MOCKEOF
#!/bin/sh
touch "$caddy_marker"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/caddy"

    # Realistic success: actually creates the database file, matching what
    # the real download-geodb.sh guarantees whenever it exits 0. A mock
    # that only exits 0 without creating the file (the previous version of
    # this test) would also pass entrypoint.sh's fail-open gap - see the
    # dedicated test for that below.
    cat > "$mockdir/bin/download-geodb.sh" <<MOCKEOF
#!/bin/sh
echo "mock: simulating a successful GeoDB download"
echo "fake-mmdb-content" > "$db_file"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/download-geodb.sh"

    entrypoint_copy="$mockdir/entrypoint.sh"
    cp "$REPO_ROOT/caddy/entrypoint.sh" "$entrypoint_copy"
    sed -i "s#/usr/local/bin/download-geodb.sh#$mockdir/bin/download-geodb.sh#" "$entrypoint_copy"
    sed -i "s#DB_FILE=\"/data/geolite2/GeoLite2-Country.mmdb\"#DB_FILE=\"$db_file\"#" "$entrypoint_copy"
    chmod +x "$entrypoint_copy"

    (
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        sh "$entrypoint_copy"
    )
    result=$?

    if [ "$result" -eq 0 ] && [ -e "$caddy_marker" ]; then
        pass "entrypoint.sh starts Caddy once GeoDB acquisition succeeds and the database actually exists"
    else
        fail "entrypoint.sh starts Caddy once GeoDB acquisition succeeds (exit=$result, caddy_started=$([ -e "$caddy_marker" ] && echo yes || echo no))"
    fi
    rm -rf "$mockdir"
}

test_caddy_entrypoint_refuses_caddy_if_geodb_reports_success_but_file_missing() {
    local mockdir entrypoint_copy caddy_marker result db_file
    mockdir=$(mktemp -d)
    mkdir -p "$mockdir/bin"
    caddy_marker="$mockdir/caddy-was-started"
    db_file="$mockdir/GeoLite2-Country.mmdb"

    cat > "$mockdir/bin/caddy" <<MOCKEOF
#!/bin/sh
touch "$caddy_marker"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/caddy"

    # A "lying" downloader: reports success (exit 0) without actually
    # creating the database. This is exactly the fail-open gap
    # entrypoint.sh's own post-download existence re-check exists to
    # catch, independent of whether download-geodb.sh itself is correct
    # today, buggy tomorrow, or ever replaced - the guarantee shouldn't
    # rest solely on trusting its exit code.
    cat > "$mockdir/bin/download-geodb.sh" <<'MOCKEOF'
#!/bin/sh
echo "mock: reporting success without actually creating the database"
exit 0
MOCKEOF
    chmod +x "$mockdir/bin/download-geodb.sh"

    entrypoint_copy="$mockdir/entrypoint.sh"
    cp "$REPO_ROOT/caddy/entrypoint.sh" "$entrypoint_copy"
    sed -i "s#/usr/local/bin/download-geodb.sh#$mockdir/bin/download-geodb.sh#" "$entrypoint_copy"
    sed -i "s#DB_FILE=\"/data/geolite2/GeoLite2-Country.mmdb\"#DB_FILE=\"$db_file\"#" "$entrypoint_copy"
    chmod +x "$entrypoint_copy"

    (
        export PATH="$mockdir/bin:$ORIGINAL_PATH"
        sh "$entrypoint_copy"
    )
    result=$?

    if [ "$result" -ne 0 ] && [ ! -e "$caddy_marker" ]; then
        pass "entrypoint.sh refuses to start Caddy if the database is still missing even after a downloader reporting success"
    else
        fail "entrypoint.sh refuses to start Caddy if the database is still missing after a 'successful' download (exit=$result, caddy_started=$([ -e "$caddy_marker" ] && echo yes || echo no))"
    fi
    rm -rf "$mockdir"
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
test_fetch_existing_returns_body_on_success
test_fetch_existing_reports_http_error_distinctly
test_fetch_existing_distinguishes_transport_failure
test_init_setup_no_unguarded_curl_sf
test_download_geodb_success_installs_db_atomically
test_download_geodb_http_error_leaves_no_db_file
test_download_geodb_transport_error_leaves_no_db_file
test_download_geodb_invalid_archive_leaves_no_db_file
test_caddy_entrypoint_does_not_start_caddy_when_geodb_fails
test_caddy_entrypoint_starts_caddy_when_geodb_succeeds
test_caddy_entrypoint_refuses_caddy_if_geodb_reports_success_but_file_missing

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
