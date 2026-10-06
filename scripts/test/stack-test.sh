#!/usr/bin/env bash
# stack-test.sh — what test-infra/compose/stack.sh up publishes to the tests (stacks.yml, ADR-0038), and the labels
# it filters by (ADR-0024, ADR-0041), against a stub engine. Hermetic: a copy of stack.sh runs in a temporary tree with
# fixture stacks and a platform.yml of its own (group test.example.stacktest), so no engine, project file or host is
# reached. The lint job runs it with the other scripts/test/*-test.sh. Exit codes: 0 every check passed · 1 a check
# failed.
# shellcheck disable=SC2016 # the stub and the fixtures hold literal $ expressions
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir=$work/test-infra/compose
state=$dir/.state
mkdir -p "$dir" "$work/bin" "$work/home"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cp "$REPO/test-infra/compose/stack.sh" "$dir/stack.sh"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub engine: logs every call; a compose call also logs the LABEL_PREFIX that compose interpolates the labels with.
if [[ ${1:-} == compose ]]; then printf '%s [LABEL_PREFIX=%s]\n' "$*" "${LABEL_PREFIX:-}"; else printf '%s\n' "$*"; fi >>"$STUB_LOG"
STUB
chmod +x "$work/bin/docker"
# The fixture's own group: every label key starts with it (ADR-0041), and nothing here may filter by another prefix.
prefix=test.example.stacktest
cat >"$work/platform.yml" <<EOF
projects:
  - name: stack-test
    group: $prefix   # every label prefix
EOF
for f in base it-runner db cache broken; do printf 'services: {}\n' >"$dir/$f.yml"; done
: >"$dir/versions.env"
cat >"$dir/stacks.yml" <<'EOF'
demo: [db, cache]
other: [cache]
bad: [broken]

stacks:
  db:
    seed: bash /seed/apply.sh --quiet  # a comment
    env:
      # a comment
      - DB_HOST=db
      - DB_PASSWORD=<generated-secret>
      - "DB_URL=jdbc:x://db/${DB_PASSWORD}"
    local_env:
      - DB_HOST=localhost
      - DB_PORT=${DB_HOST_PORT:-5432}
  cache:
    env:
    - CACHE_HOST=cache
  broken:
    env:
      - X=${NOT_SET_ANYWHERE}
EOF

fails=0 rc=0
check() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
run() { # [VAR=value...] <stack.sh arguments...>
  local vars=()
  while [[ $1 == *=* ]]; do vars+=("$1"); shift; done
  rc=0
  env -i PATH="$work/bin:$PATH" HOME="$work/home" STUB_LOG="$work/log" COMPOSE_BIN="docker compose" \
    ${vars[@]+"${vars[@]}"} bash "$dir/stack.sh" "$@" >"$work/out" 2>&1 || rc=$?
}
has() { grep -qxF -- "$2" "$1"; }
entries() { grep -v '^#' "$1" | paste -s -d ' ' -; }

run up --project :demo
pw=$(sed -n 's/^DB_PASSWORD=//p' "$state/local-demo.it-runner.env")
check "up exits 0" test "$rc" -eq 0
check "a <generated-secret> is generated" grep -Eqx 'It-[0-9a-f]{32}-Aa1' <<<"$pw"
check "it-runner: env only, references expanded" test "$(entries "$state/local-demo.it-runner.env")" \
  = "DB_HOST=db DB_PASSWORD=$pw DB_URL=jdbc:x://db/$pw CACHE_HOST=cache"
check "host: local_env replaces env, defaults apply" test "$(entries "$state/local-demo.host.env")" \
  = "DB_HOST=localhost DB_PASSWORD=$pw DB_URL=jdbc:x://db/$pw DB_PORT=5432 CACHE_HOST=cache"
check "the state file records the env entries" has "$state/local-demo.env" "DB_PASSWORD=$pw"
check "the state file names the it-runner's file" has "$state/local-demo.env" "IT_RUNNER_ENV_FILE=$state/local-demo.it-runner.env"
check "the seed runs in its stack's service" grep -qF "exec -T db bash /seed/apply.sh --quiet" "$work/log"
check "a stack without a seed is not seeded" test "$(grep -c ' exec ' "$work/log")" -eq 1

run DB_HOST_PORT=6000 up --project :demo
check "a re-run keeps the secret" has "$state/local-demo.it-runner.env" "DB_PASSWORD=$pw"
check "\${NAME:-default} takes the environment" has "$state/local-demo.host.env" "DB_PORT=6000"
run DB_PASSWORD=given up --project :demo
check "a secret set by the caller wins" has "$state/local-demo.it-runner.env" "DB_URL=jdbc:x://db/given"

run up --project :other
check "another project gets only its stacks' entries" test "$(entries "$state/local-other.it-runner.env")" = "CACHE_HOST=cache"
run up --project :bad
check "an unset reference is a usage error" test "$rc" -eq 2
check "the error names the entry" grep -qF 'X=${NOT_SET_ANYWHERE}' "$work/out"

# The labels (ADR-0024, ADR-0041): compose interpolates them with LABEL_PREFIX, the group of platform.yml, and down
# and leak-check filter by <group>.ci.run.
check "up exports the group to compose as LABEL_PREFIX" \
  bash -c 'grep -q "^compose .* up --wait" "$1" && ! grep "^compose " "$1" | grep -v "^compose version" |
    grep -vqF "[LABEL_PREFIX=$2]"' _ "$work/log" "$prefix"
check "the state file records LABEL_PREFIX" has "$state/local-demo.env" "LABEL_PREFIX=$prefix"
: >"$work/log"
run down --project :demo
check "down exits 0" test "$rc" -eq 0
check "down removes the stack's env files" test ! -e "$state/local-demo.host.env" -a ! -e "$state/local-demo.it-runner.env"
check "on a laptop down prunes by the compose project" grep -qF -- "ps -aq --filter label=com.docker.compose.project=local-demo" "$work/log"
: >"$work/log"
run CI_RUN_ID=777 CI_RUN_ATTEMPT=2 up --project :other
run CI_RUN_ID=777 CI_RUN_ATTEMPT=2 leak-check --project :other
check "in CI leak-check filters by <group>.ci.run" grep -qF -- "ps -a --filter label=$prefix.ci.run=777 " "$work/log"
run CI_RUN_ID=777 CI_RUN_ATTEMPT=2 down --project :other
check "in CI down prunes by <group>.ci.run" grep -qF -- "volume ls -q --filter label=$prefix.ci.run=777" "$work/log"
check "in CI down also prunes by the compose project" grep -qF -- "network ls -q --filter label=com.docker.compose.project=ci-777-2" "$work/log"
check "no other prefix is filtered by" bash -c '! grep -oE "label=[a-z0-9.]*\.ci\.run=" "$1" | grep -vqxF "label=$2.ci.run="' _ "$work/log" "$prefix"

# A group the scripts cannot read is a configuration error before anything starts (exit 4).
cp "$work/platform.yml" "$work/platform.yml.good"
sed "s/group: $prefix/group: \"$prefix\"/" "$work/platform.yml.good" >"$work/platform.yml"
: >"$work/log"
run up --project :demo
check "a quoted group is exit 4" test "$rc" -eq 4
check "the error names projects[0].group" grep -qF "projects[0].group '\"$prefix\"' must be lower-case words" "$work/out"
check "nothing starts without a valid group" test "$(grep -c '^compose .* up ' "$work/log")" -eq 0
rm "$work/platform.yml"
run leak-check
check "no platform.yml is exit 4" test "$rc" -eq 4
mv "$work/platform.yml.good" "$work/platform.yml"

echo "$fails failure(s)"
[[ $fails -eq 0 ]]
