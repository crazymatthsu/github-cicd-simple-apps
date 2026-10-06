#!/usr/bin/env bash
# stack-test.sh — what test-infra/compose/stack.sh up publishes to the tests (stacks.yml, ADR-0038), against a stub
# engine. Hermetic: a copy of stack.sh runs in a temporary tree with fixture stacks, so no engine, project file or
# host is reached. The lint job runs it with the other scripts/test/*-test.sh. Exit codes: 0 every check passed ·
# 1 a check failed.
# shellcheck disable=SC2016 # the stub and the fixtures hold literal $ expressions
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir=$work/test-infra/compose
state=$dir/.state
mkdir -p "$dir" "$work/bin" "$work/home"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cp "$REPO/test-infra/compose/stack.sh" "$dir/stack.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$STUB_LOG"\n' >"$work/bin/docker"
chmod +x "$work/bin/docker"
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

run down --project :demo
check "down exits 0" test "$rc" -eq 0
check "down removes the stack's env files" test ! -e "$state/local-demo.host.env" -a ! -e "$state/local-demo.it-runner.env"

echo "$fails failure(s)"
[[ $fails -eq 0 ]]
