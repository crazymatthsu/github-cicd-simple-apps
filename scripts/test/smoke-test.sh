#!/usr/bin/env bash
# smoke-test.sh — check 2 of scripts/smoke.sh, the identity in /actuator/info (ADR-0015, ADR-0037): the generic app
# section is read first and the framework's connector section is accepted; two sections that disagree fail; an info
# document with neither skips the check with a warning and exits 0; a wrong identity fails. A stub curl answers
# readiness UP and the info document of each case. The jq-less path (a section's "tuple") runs with a PATH that holds
# only the tools smoke.sh needs, so no jq. Plain bash 3.2+; the lint job runs it with the other scripts/test/*-test.sh.
# Exit codes: 0 every case passed · 1 a case failed · 2 a missing tool.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO SMOKE="$REPO/scripts/smoke.sh"
command -v jq >/dev/null 2>&1 || { echo "smoke-test: jq is needed" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/smoke-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK
trap 'rm -rf "${WORK:?}"' EXIT
# Nothing from the caller's shell steers the script under test.
unset ACTUATOR_HOST_PORT APP_ENV APP_FLOW APP_NAME APP_INSTANCE CONFIG_ROOT SMOKE_TIMEOUT STUB_INFO

# The stub curl: readiness UP, and STUB_INFO as /actuator/info.
mkdir -p "$WORK/bin" "$WORK/no-jq"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
    */actuator/health/readiness) echo '{"status":"UP"}' ;;
    */actuator/info) printf '%s\n' "$STUB_INFO" ;;
    *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
EOF
chmod +x "$WORK/bin/curl"
for tool in bash sed dirname basename sleep; do ln -s "$(command -v "$tool")" "$WORK/no-jq/$tool"; done
ln -s "$WORK/bin/curl" "$WORK/no-jq/curl"
readonly WITH_JQ="$WORK/bin:$PATH" NO_JQ="$WORK/no-jq"
PATH="$NO_JQ" command -v jq >/dev/null 2>&1 && { echo "smoke-test: jq is still on the jq-less PATH" >&2; exit 2; }

PASSED=0 FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'not ok - %s\n' "$1"; }
# expect <case> <PATH> <exit code> <text in the output> <info document>: smoke.sh of eu-dev/alpha/demo-app/inst-one.
expect() {
    local rc=0 out
    out="$(PATH="$2" STUB_INFO="$5" "$SMOKE" eu-dev alpha demo-app inst-one http://stub.test:8080 2>&1)" || rc=$?
    if [ "$rc" -eq "$3" ] && [[ $out == *"$4"* ]]; then
        pass "$1 → $3"
    else
        fail "$1 → exit $rc, expected $3 with '$4'; output: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"
    fi
}

FIELDS='"env":"eu-dev","flow":"alpha","app":"demo-app","instance":"inst-one"'
TUPLE=eu-dev/alpha/demo-app/inst-one
ID="$FIELDS,\"tuple\":\"$TUPLE\""
OTHER='"env":"eu-dev","flow":"alpha","app":"other-app","instance":"inst-one","tuple":"eu-dev/alpha/other-app/inst-one"'
BUILD='"build":{"version":"1.2.3","name":"demo-app"},"java":{"version":"21","vendor":{"name":"Eclipse Adoptium"}}'

for mode in jq no-jq; do
    path="$WITH_JQ"
    [ "$mode" = jq ] || path="$NO_JQ"
    expect "$mode: app section" "$path" 0 "identity $TUPLE (http://stub.test:8080/actuator/info, app section)" \
        "{$BUILD,\"app\":{$ID}}"
    expect "$mode: connector section" "$path" 0 "connector section)" "{$BUILD,\"connector\":{$ID,\"complete\":true}}"
    expect "$mode: both, consistent" "$path" 0 "app section)" "{\"connector\":{$ID},$BUILD,\"app\":{$ID}}"
    expect "$mode: both, disagreeing" "$path" 1 "the connector section says" "{\"connector\":{$OTHER},\"app\":{$ID}}"
    expect "$mode: neither" "$path" 0 "check 2 is skipped" "{$BUILD}"
    expect "$mode: neither, readiness only" "$path" 0 "OK demo-app at http://stub.test:8080 (readiness only)" "{$BUILD}"
    expect "$mode: app section of info.app.* only" "$path" 0 "check 2 is skipped" "{\"app\":{\"name\":\"demo\"}}"
    expect "$mode: wrong app name" "$path" 1 "app is 'other-app', expected 'demo-app'" "{$BUILD,\"app\":{$OTHER}}"
done
# The fields alone (no tuple): jq reads them, the jq-less path finds no identity.
expect "jq: connector fields without a tuple" "$WITH_JQ" 0 "connector section)" "{\"connector\":{$FIELDS}}"
expect "no-jq: connector fields without a tuple" "$NO_JQ" 0 "check 2 is skipped" "{\"connector\":{$FIELDS}}"
expect "jq: unset instance" "$WITH_JQ" 1 "identity 'eu-dev/alpha/demo-app/none': instance is not set" \
    "{\"app\":{${FIELDS/inst-one/none}}}"
expect "jq: not a JSON object" "$WITH_JQ" 1 "did not answer a JSON object" "<html>Whitelabel Error Page</html>"

printf 'smoke-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
