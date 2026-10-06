#!/usr/bin/env bash
# env-vocabulary-test.sh — the env and flow checks of scripts/run-compose.sh and scripts/helm-deploy-instance.sh against
# platform.yml (ADR-0003, ADR-0004, ADR-0030): an unknown region, stage or flow is a usage error (2); a promoted env, or
# a dev env that dev_envs does not list, is refused (3); a missing or malformed platform.yml is a config error (4);
# with dev_envs: [] only local passes (ADR-0035). The forbidden env-layer prefixes are Spring's and the env forms of
# property_prefixes, and printenv masks the secret_properties with every key below them (ADR-0042).
# The cases are derived from this repository's platform.yml. Plain bash 3.2+: no engine, Helm or yq, because every
# case ends before a script needs one. The lint job runs it with the other scripts/test/*-test.sh.
# Exit codes: 0 every case passed · 1 a case failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO RUN_COMPOSE="$REPO/scripts/run-compose.sh" HELM_DEPLOY="$REPO/scripts/helm-deploy-instance.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/env-vocabulary-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK
trap 'rm -rf "${WORK:?}"' EXIT
# Nothing from the caller's shell steers the scripts under test.
unset CONFIG_ROOT IMAGE_TAG IMAGE_REPO APP_IMAGE GITHUB_RUN_ID

# The words of a one-line list of platform.yml (`<key>: [a, b]`), as the scripts read them.
words() { sed -n "s/^$1:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$REPO/platform.yml" | tr -d ' \t' | tr ',' ' '; }
REGIONS="$(words regions)" STAGES="$(words stages)" FLOWS="$(words flows)" DEV_ENVS="$(words dev_envs)"
PROPERTY_PREFIXES="$(words property_prefixes)"
readonly REGIONS STAGES FLOWS DEV_ENVS PROPERTY_PREFIXES
has() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
region="${REGIONS%% *}" flow="${FLOWS%% *}"
unknown_region="" promoted="" unlisted_dev=""
for r in qq zz xq; do has "$r" "$REGIONS" || { unknown_region="$r"; break; }; done
for s in $STAGES; do [ "$s" = dev ] || { promoted="$region-$s"; break; }; done
for r in $REGIONS; do has "$r-dev" "$DEV_ENVS" || { unlisted_dev="$r-dev"; break; }; done

PASSED=0 FAILED=0
# A command line for the report, with the repository and the scratch directory shortened.
label() { local s="$*"; s="${s//"$REPO"\//}"; printf '%s' "${s//"$WORK"\//}"; }
pass() { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'not ok - %s\n' "$1"; }
# expect <exit code> <text in stderr> <command...>
expect() {
    local code="$1" text="$2" rc=0 err
    shift 2
    err="$("$@" 2>&1 >/dev/null)" || rc=$?
    case "$err" in
        *"$text"*) [ "$rc" -eq "$code" ] && pass "$(label "$@") → $code" && return 0 ;;
    esac
    fail "$(label "$@") → exit $rc, expected $code with '$text'; stderr: $(printf '%s' "$err" | grep -v 'audit:' | tail -n 2 | tr '\n' ' ')"
}
# expect_not <exit codes> <command...>: the env checks let the command through (it may fail later, e.g. without Helm).
expect_not() {
    local codes="$1" rc=0
    shift
    "$@" >/dev/null 2>&1 || rc=$?
    if has "$rc" "$codes"; then fail "$(label "$@") → exit $rc, expected none of: $codes"; else pass "$(label "$@") → $rc (not $codes)"; fi
}

# --- run-compose.sh ------------------------------------------------------------------------------------------------
[ -z "$unknown_region" ] || expect 2 "(platform.yml)" "$RUN_COMPOSE" "$unknown_region-dev" "$flow" source-x inst status
expect 2 "(platform.yml)" "$RUN_COMPOSE" "$region-nostage" "$flow" source-x inst status
expect 2 "must be local or <region>-<stage>" "$RUN_COMPOSE" "$region" "$flow" source-x inst status
expect 2 "flow 'no-such-flow' must be one of" "$RUN_COMPOSE" local no-such-flow source-x inst status
[ -z "$promoted" ] || expect 3 "the promoted envs are deployed from the configuration repository" \
    "$RUN_COMPOSE" "$promoted" "$flow" source-x inst status
[ -z "$unlisted_dev" ] || expect 3 "is not a dev env of this repository" "$RUN_COMPOSE" "$unlisted_dev" "$flow" source-x inst status

# A root without platform.yml, and one whose list spans lines: config errors, before any name is checked.
mkdir -p "$WORK/bare/scripts" "$WORK/multiline/scripts"
cp "$RUN_COMPOSE" "$WORK/bare/scripts/run-compose.sh"
cp "$RUN_COMPOSE" "$WORK/multiline/scripts/run-compose.sh"
sed "s/^flows:.*/flows:\\
  - $flow/" "$REPO/platform.yml" >"$WORK/multiline/platform.yml"
expect 4 "platform.yml not found" "$WORK/bare/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "flows must be a one-line list" "$WORK/multiline/scripts/run-compose.sh" local "$flow" source-x inst status

# --- helm-deploy-instance.sh: every mode checks the vocabulary; only deploy checks dev_envs -------------------------
expect 2 "(platform.yml)" "$HELM_DEPLOY" "$region-nostage" "$flow" source-x inst --tag t --mode lint
expect 2 "flow 'no-such-flow' must be one of" "$HELM_DEPLOY" local no-such-flow source-x inst --tag t --mode lint
if [ -n "$promoted" ]; then
    expect 3 "the promoted envs are deployed from the configuration repository" \
        "$HELM_DEPLOY" "$promoted" "$flow" source-x inst --tag 1.0.0 --mode deploy --dry-run
    expect_not "2 3" "$HELM_DEPLOY" "$promoted" "$flow" source-x inst --tag 1.0.0 --mode template --dry-run
fi
[ -z "$unlisted_dev" ] || expect 3 "is not a dev env of this repository" \
    "$HELM_DEPLOY" "$unlisted_dev" "$flow" source-x inst --tag t --mode deploy --dry-run

# --- dev_envs: [] (ADR-0035): a repository that deploys no env yet; local passes the env checks, no other env does ----
mkdir -p "$WORK/no-dev/scripts"
cp "$RUN_COMPOSE" "$HELM_DEPLOY" "$WORK/no-dev/scripts/"
sed 's/^dev_envs:.*/dev_envs: []/' "$REPO/platform.yml" >"$WORK/no-dev/platform.yml"
expect 4 "config tree: directory missing: config/local" "$WORK/no-dev/scripts/run-compose.sh" local "$flow" source-x inst status
expect 3 "is not a dev env of this repository" "$WORK/no-dev/scripts/run-compose.sh" "$region-dev" "$flow" source-x inst status
expect 3 "is not a dev env of this repository" \
    "$WORK/no-dev/scripts/helm-deploy-instance.sh" "$region-dev" "$flow" source-x inst --tag t --mode deploy --dry-run

# --- property_prefixes and secret_properties (ADR-0042) -----------------------------------------------------------
# Two roots with one local instance: this repository's platform.yml, and one whose app has other roots and secrets.
# Only the roots of a root's own platform.yml, and Spring's, are forbidden in its env layers.
own="${PROPERTY_PREFIXES%% *}"
own_var="$(printf '%s' "${own//-/}" | tr '.' '_' | tr '[:lower:]' '[:upper:]')_SOURCE_HOST"
# instance_env <root> [extra lines]: the instance layer, valid but for the extra lines.
instance_env() {
    printf 'IMAGE_REPO=example.com/x\nIMAGE_TAG=local\nAPP_ENV=local\nAPP_FLOW=%s\nAPP_NAME=source-x\nAPP_INSTANCE=inst\n%s' \
        "$flow" "${2:-}" >"$WORK/$1/config/local/$flow/source-x/inst/_docker-compose.instance.env"
}
make_root() { # <root> <sed script for platform.yml>
    mkdir -p "$WORK/$1/scripts" "$WORK/$1/docker" "$WORK/$1/config/local/$flow/source-x/inst"
    cp "$RUN_COMPOSE" "$WORK/$1/scripts/"
    sed "$2" "$REPO/platform.yml" >"$WORK/$1/platform.yml"
    # The template passes one variable through from the shell, as an app's secret is (ADR-0013).
    # shellcheck disable=SC2016 # a literal compose placeholder
    printf 'services:\n  app:\n    environment:\n      ORDERS_FEED_USERNAME: ${ORDERS_FEED_USERNAME:?secret}\n' \
        >"$WORK/$1/docker/docker-compose.yml"
    printf 'a: 1\n' >"$WORK/$1/config/local/$flow/source-x/application.app.yml"
    printf 'a: 1\n' >"$WORK/$1/config/local/$flow/source-x/inst/application.instance.yml"
    instance_env "$1" "ORDERS_FEED_URL=x
ACME_BILLINGSVC_URL=y
MANAGEMENT_PORT=1
$own_var=db
"
}
make_root own ''
make_root other 's/^property_prefixes:.*/property_prefixes: [orders, acme.billing-svc]/
s/^secret_properties:.*/secret_properties: [orders.feed.username]/'
expect 4 "ORDERS_FEED_URL is forbidden: SPRING_*, LOGGING_*, MANAGEMENT_*, ORDERS_*, ACME_BILLINGSVC_* belong in YAML" \
    "$WORK/other/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "ACME_BILLINGSVC_URL is forbidden" "$WORK/other/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "MANAGEMENT_PORT is forbidden" "$WORK/other/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "$own_var is not an allowed compose variable" "$WORK/other/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "$own_var is forbidden" "$WORK/own/scripts/run-compose.sh" local "$flow" source-x inst status
has orders "$PROPERTY_PREFIXES" ||
    expect 4 "ORDERS_FEED_URL is not an allowed compose variable" "$WORK/own/scripts/run-compose.sh" local "$flow" source-x inst status

# Both keys are required one-line lists; property_prefixes may not be empty, secret_properties may.
make_root no-secrets '/^secret_properties:/d'
make_root no-prefixes 's/^property_prefixes:.*/property_prefixes: []/'
expect 4 "secret_properties must be a one-line list" "$WORK/no-secrets/scripts/run-compose.sh" local "$flow" source-x inst status
expect 4 "property_prefixes must be a one-line list" "$WORK/no-prefixes/scripts/run-compose.sh" local "$flow" source-x inst status

# printenv masks a secret property of platform.yml in its environment-variable form, and only where it is one.
instance_env own
instance_env other
# printenv_shows <root> <expected line>
printenv_shows() {
    local out rc=0
    out="$(ORDERS_FEED_USERNAME=svc-orders "$WORK/$1/scripts/run-compose.sh" local "$flow" source-x inst printenv 2>/dev/null)" ||
        rc=$?
    case "$out" in
        *"$2"*) [ "$rc" -eq 0 ] && pass "$1: printenv shows $2" && return 0 ;;
    esac
    fail "$1: printenv → exit $rc, expected a line '$2'; got: $(printf '%s' "$out" | grep ORDERS_FEED_USERNAME | tr '\n' ' ')"
}
printenv_shows other "ORDERS_FEED_USERNAME=***"
has orders.feed.username "$(words secret_properties)" || printenv_shows own "ORDERS_FEED_USERNAME=svc-orders"

printf 'env-vocabulary-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
