#!/usr/bin/env bash
# engine-order-test.sh — the container engine each shared script picks (ADR-0045): Podman, then Docker, the first that
# is usable; CONTAINER_ENGINE names one for every tool, and a tool's own setting wins over it. Runs
# scripts/run-compose.sh, test-infra/compose/stack.sh and test-infra/kind/kind.sh against stub podman, docker,
# podman-compose and kind that log their arguments and answer from STUB_* variables, so no engine is reached. An engine
# "off" here has its CLI on the PATH but answers nothing, because a real one on this machine cannot be hidden. The
# Gradle side (buildImage, config-lint) is ContainerEnginesTest. The lint job runs it with the other
# scripts/test/*-test.sh.
# Exit codes: 0 every case passed · 1 a case failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO
WORK="$(mktemp -d "${TMPDIR:-/tmp}/engine-order-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK BIN="$WORK/bin" FIX="$WORK/fixture" LOG="$WORK/log"
trap 'rm -rf "${WORK:?}"' EXIT
# Nothing from the caller's shell steers the scripts under test.
unset CONTAINER_ENGINE RUN_COMPOSE_ENGINE COMPOSE_BIN KIND_EXPERIMENTAL_PROVIDER COMPOSE_PROJECT_NAME KIND_CLUSTER_NAME \
    CI_RUN_ID CI_RUN_ATTEMPT GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_ACTIONS GITHUB_ENV GITHUB_STEP_SUMMARY CONFIG_ROOT \
    IMAGE_TAG IMAGE_REPO APP_IMAGE DOCKER_HOST STUB_PODMAN STUB_DOCKER STUB_PODMAN_COMPOSE

# --- stubs and fixture -------------------------------------------------------------------------------------------
# Each stub logs "<name> <args>", kind with the provider kind.sh hands it. STUB_<NAME> sets how it answers: on (default) answers everything; off fails every
# call, as an engine without a compose provider and a stopped service does; python makes `podman compose` run
# podman-compose; nocompose answers everything but `compose`.
mkdir -p "$BIN"
for name in podman docker podman-compose kind; do
    cat >"$BIN/$name" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
if [ "$name" = kind ]; then
    printf 'kind %s [provider=%s]\n' "$*" "${KIND_EXPERIMENTAL_PROVIDER:-}" >>"$STUB_LOG"
else
    printf '%s %s\n' "$name" "$*" >>"$STUB_LOG"
fi
var="STUB_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
mode="${!var:-on}"
[ "$mode" != off ] || { echo "$name: cannot connect" >&2; exit 125; }
case "${1:-} ${2:-}" in
    "compose version")
        [ "$mode" != nocompose ] || { echo "Error: no compose provider found" >&2; exit 125; }
        if [ "$mode" = python ]; then echo "podman-compose version 1.6.0"; else echo "Docker Compose version v2.99.0-stub"; fi ;;
    "version "*) echo "podman-compose version 1.6.0" ;;
esac
exit 0
EOF
    chmod +x "$BIN/$name"
done

# A checkout with one local instance (ADR-0003): this repository's platform.yml and scripts, a template of its own.
flow="$(sed -n 's/^flows:[[:space:]]*\[[[:space:]]*\([a-z0-9-]*\).*/\1/p' "$REPO/platform.yml")"
inst="$FIX/config/local/$flow/source-x/inst"
mkdir -p "$FIX/scripts" "$FIX/docker" "$FIX/test-infra/compose" "$FIX/test-infra/kind" "$inst"
cp "$REPO/platform.yml" "$FIX/"
cp "$REPO/scripts/run-compose.sh" "$FIX/scripts/"
cp "$REPO/test-infra/compose/stack.sh" "$FIX/test-infra/compose/"
cp "$REPO/test-infra/kind/kind.sh" "$REPO/test-infra/kind/versions.env" "$FIX/test-infra/kind/"
printf 'services:\n  app:\n    image: example.com/x/source-x:local\n' >"$FIX/docker/docker-compose.yml"
printf 'a: 1\n' >"$FIX/config/local/$flow/source-x/application.app.yml"
printf 'a: 1\n' >"$inst/application.instance.yml"
printf 'IMAGE_REPO=example.com/x\nIMAGE_TAG=local\nAPP_ENV=local\nAPP_FLOW=%s\nAPP_NAME=source-x\nAPP_INSTANCE=inst\n' "$flow" \
    >"$inst/_docker-compose.instance.env"

# --- cases ---------------------------------------------------------------------------------------------------------
PASSED=0 FAILED=0
# picks <case> <expected first command> <script and arguments, after VAR=value assignments...>: the script's first
# engine call that is not a probe (`--version`, `info`, `compose version`) starts with the expected words.
picks() {
    local name="$1" want="$2" got rc=0
    shift 2
    : >"$LOG"
    env PATH="$BIN:$PATH" STUB_LOG="$LOG" HOME="$WORK" "$@" >"$WORK/out" 2>&1 || rc=$?
    got="$(grep -v -E '^kind |^[a-z-]+ (--version|info|compose version|version)( |$)' "$LOG" | head -n 1 || true)"
    case "$got" in
        "$want "*) PASSED=$((PASSED + 1)); printf 'ok - %s: %s\n' "$name" "$want" ;;
        *) FAILED=$((FAILED + 1))
           printf 'not ok - %s: expected "%s ...", got "%s" (exit %s): %s\n' "$name" "$want" "$got" "$rc" \
               "$(grep -v 'audit:' "$WORK/out" | tail -n 2 | tr '\n' ' ')" ;;
    esac
}
# fails <case> <exit code> <text in the output> <script and arguments, after VAR=value assignments...>
fails() {
    local name="$1" code="$2" text="$3" rc=0
    shift 3
    : >"$LOG"
    env PATH="$BIN:$PATH" STUB_LOG="$LOG" HOME="$WORK" "$@" >"$WORK/out" 2>&1 || rc=$?
    if [ "$rc" -eq "$code" ] && grep -qF -- "$text" "$WORK/out"; then
        PASSED=$((PASSED + 1)); printf 'ok - %s: exit %s\n' "$name" "$code"
    else
        FAILED=$((FAILED + 1))
        printf 'not ok - %s: exit %s, expected %s with "%s": %s\n' "$name" "$rc" "$code" "$text" \
            "$(grep -v 'audit:' "$WORK/out" | tail -n 2 | tr '\n' ' ')"
    fi
}

RC=("$FIX/scripts/run-compose.sh" local "$flow" source-x inst stop)
picks "run-compose: both answer" "podman compose" "${RC[@]}"
picks "run-compose: podman's service is down" "docker compose" STUB_PODMAN=off STUB_PODMAN_COMPOSE=off "${RC[@]}"
picks "run-compose: podman without compose, podman-compose next" "podman-compose" STUB_PODMAN=nocompose "${RC[@]}"
picks "run-compose: CONTAINER_ENGINE=docker" "docker compose" CONTAINER_ENGINE=docker "${RC[@]}"
picks "run-compose: CONTAINER_ENGINE=auto" "podman compose" CONTAINER_ENGINE=auto "${RC[@]}"
picks "run-compose: RUN_COMPOSE_ENGINE wins" "podman compose" CONTAINER_ENGINE=docker RUN_COMPOSE_ENGINE=podman "${RC[@]}"
picks "run-compose: --engine wins" "docker compose" RUN_COMPOSE_ENGINE=podman "${RC[@]}" --engine docker
fails "run-compose: a named engine that is down" 5 "podman is not usable" STUB_PODMAN=off CONTAINER_ENGINE=podman "${RC[@]}"
fails "run-compose: CONTAINER_ENGINE=nerdctl" 2 "must be podman or docker" CONTAINER_ENGINE=nerdctl "${RC[@]}"

ST=("$FIX/test-infra/compose/stack.sh" leak-check --warn-only)
picks "stack: both answer" "podman ps" COMPOSE_PROJECT_NAME=t "${ST[@]}"
picks "stack: podman's service is down" "docker ps" COMPOSE_PROJECT_NAME=t STUB_PODMAN=off "${ST[@]}"
picks "stack: podman compose runs podman-compose" "docker ps" COMPOSE_PROJECT_NAME=t STUB_PODMAN=python "${ST[@]}"
picks "stack: CONTAINER_ENGINE=docker" "docker ps" COMPOSE_PROJECT_NAME=t CONTAINER_ENGINE=docker "${ST[@]}"
picks "stack: COMPOSE_BIN wins" "podman ps" COMPOSE_PROJECT_NAME=t CONTAINER_ENGINE=docker COMPOSE_BIN="podman compose" "${ST[@]}"
fails "stack: nothing answers" 5 "no usable container engine" COMPOSE_PROJECT_NAME=t STUB_PODMAN=off STUB_DOCKER=off "${ST[@]}"

KD=("$FIX/test-infra/kind/kind.sh" leak-check --warn-only)
# hands_kind <case> <provider>: what kind itself was told after the last case (kind alone would try Docker first).
hands_kind() {
    if grep -qxF "kind get clusters [provider=$2]" "$LOG"; then
        PASSED=$((PASSED + 1)); printf 'ok - %s: kind gets provider "%s"\n' "$1" "$2"
    else
        FAILED=$((FAILED + 1)); printf 'not ok - %s: kind was not given provider "%s": %s\n' "$1" "$2" "$(grep '^kind ' "$LOG" | tr '\n' ' ')"
    fi
}
picks "kind: both answer" "podman ps" "${KD[@]}"
hands_kind "kind: both answer" podman
picks "kind: podman's service is down" "docker ps" STUB_PODMAN=off "${KD[@]}"
hands_kind "kind: podman's service is down" ""
picks "kind: CONTAINER_ENGINE=docker" "docker ps" CONTAINER_ENGINE=docker "${KD[@]}"
picks "kind: KIND_EXPERIMENTAL_PROVIDER wins" "podman ps" CONTAINER_ENGINE=docker KIND_EXPERIMENTAL_PROVIDER=podman "${KD[@]}"
fails "kind: nothing answers" 5 "no usable container engine" STUB_PODMAN=off STUB_DOCKER=off "${KD[@]}"

printf 'engine-order-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
