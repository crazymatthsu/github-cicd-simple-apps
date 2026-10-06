#!/usr/bin/env bash
# test-infra/compose/stack.sh: lifecycle of the test-infra compose stacks (ADR-0025).
#
# One script, two callers: the integration-test workflow steps and Gradle's composeUp / composeDown /
# devUp / devDown Exec tasks, so a laptop and a runner execute the same commands. Portable to bash 3.2
# (macOS). Run `stack.sh --help` for the interface.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-infra/compose/stack.sh <command> [options]

Commands
  up --project <gradle path> [--local]
      Start the dependency stacks that stacks.yml declares for the project (base.yml, <stack>.yml...,
      it-runner.yml), plus the shared docker/docker-compose.yml and the app's overrides when APP_IMAGE is set
      (ADR-0025): pull --quiet,
      up --wait --wait-timeout 180, run each stack's seed (stacks.yml), then start the app under test.
      Exports COMPOSE_FILE, COMPOSE_PROJECT_NAME, COMPOSE_ENV_FILES, LABEL_PREFIX and the IT_* values to
      $GITHUB_ENV in CI and records them in test-infra/compose/.state/<project>.env.
      Writes what the stacks publish to the tests (their env entries in stacks.yml, ADR-0038) to
      .state/<project>.it-runner.env (it-runner, on the stack network) and .state/<project>.host.env
      (a test JVM on the host: local_env replaces env).
      --local also publishes the stacks' ports on 127.0.0.1 (local-ports.yml). In CI the app under
      test publishes no port either (tests reach it as <AppName>:8080 on the stack network: the service is
      `app`, aliased <AppName>).
  diagnostics <dir>
      Write compose-ps.txt, <service>.log, health-<service>.json and stats.txt for the stack into <dir>.
  down
      down -v --remove-orphans --timeout 20, then remove every container, volume and network that
      still carries the stack's labels. Exit 0 only when nothing is left.
  leak-check [--warn-only]
      List containers, volumes and networks carrying this run's labels; exit 1 if any remain
      (--warn-only: report, exit 0). Writes a summary to $GITHUB_STEP_SUMMARY in CI.

  diagnostics, down and leak-check find the stack through COMPOSE_PROJECT_NAME, else the only state
  file under test-infra/compose/.state/. --project <gradle path> selects one when several exist.

Environment
  COMPOSE_BIN              "docker compose" or "podman compose" (default: docker when present, else podman)
  COMPOSE_PROJECT_NAME     default ci-<CI_RUN_ID>-<CI_RUN_ATTEMPT> in CI, local-<AppName> elsewhere
  CI_RUN_ID, CI_RUN_ATTEMPT  run labels (default GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT, else local / 0); their keys
                           are <group>.ci.run and <group>.ci.attempt, the group being projects[0].group of
                           platform.yml, which stack.sh exports to compose as LABEL_PREFIX (ADR-0041)
  APP_IMAGE                image under test; adds docker/docker-compose.yml, the app's override and the instance's
                           config-tree overrides to the stack, with the combined env scripts/run-compose.sh writes
  APP_ENV, APP_FLOW, APP_INSTANCE
                           identity of the app instance (default local, the one flow of config/<env>/ that
                           configures the app, and the instance named by the project's test-infra/testdata
                           manifests)
  <KEY> of a stack's KEY=<generated-secret> entry (stacks.yml)
                           a throwaway secret (generated when unset; reused on a re-run)
  IT_TABLE_PREFIX          the run's prefix for target tables (default it_<sha7>_)
  STACK_WAIT_TIMEOUT       seconds for each up --wait (default 180); STACK_SKIP_PULL=1 skips the pull

Exit codes
  0 success   1 compose failure, unhealthy stack or leak found   2 usage
  4 platform.yml missing, or without a valid projects[0].group (ADR-0041)
  5 no container engine or compose, or the engine is not reachable
EOF
}

COMPOSE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TEST_INFRA_DIR=$(dirname "$COMPOSE_DIR")
REPO_ROOT=$(dirname "$TEST_INFRA_DIR")
STATE_DIR=${STACK_STATE_DIR:-$COMPOSE_DIR/.state}
STACKS_FILE=$COMPOSE_DIR/stacks.yml
VERSIONS_ENV=$COMPOSE_DIR/versions.env
PLATFORM_FILE=$REPO_ROOT/platform.yml
# projects[0].group of platform.yml: lower-case words joined by dots, the start of every label key (ADR-0041).
GROUP_PATTERN='^[a-z][a-z0-9]{0,62}(\.[a-z][a-z0-9]{0,62})*$'
LABEL_PROJECT=com.docker.compose.project
WAIT_TIMEOUT=${STACK_WAIT_TIMEOUT:-180}
DOWN_TIMEOUT=20

# Recorded in the state file and, in CI, appended to $GITHUB_ENV: every later compose call on the stack
# (the workflow's `docker compose run --rm it-runner`, diagnostics, down) needs the same interpolation.
STATE_VARS="COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_ENV_FILES
  CI_RUN_ID CI_RUN_ATTEMPT LABEL_PREFIX IT_TABLE_PREFIX IT_RUNNER_UID IT_RUNNER_GID IT_WORKSPACE IT_GRADLE_HOME
  IT_RUNNER_ENV_FILE STACK_PROJECT STACK_SERVICES APP_IMAGE APP_NAME APP_ENV APP_FLOW APP_INSTANCE
  COMPOSE_ENV_FILE FLOW_APP_YML APP_APP_YML INSTANCE_APP_YML PROJECT IMAGE_REPO IMAGE_TAG ACTUATOR_HOST_PORT"
# Plus the keys of the stacks' env entries (stacks.yml, ADR-0038), and which of them are generated secrets.
STACK_ENV_KEYS=
STACK_SECRETS=

COMPOSE_CMD=()
ENGINE=
ENV_FILES=()
APP_OVERRIDES=()
STATE_FILE=

log()  { printf '[stack] %s\n' "$*"; }
warn() { printf '[stack] warning: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::error title=stack.sh::%s\n' "$*" >&2; fi
  printf '[stack] error: %s\n' "$*" >&2
  exit "$code"
}
usage_error() {
  printf '[stack] error: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
has_word() {
  local word=$1 w
  shift
  for w in "$@"; do [[ $w == "$word" ]] && return 0; done
  return 1
}
with_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}

# --- arguments ---------------------------------------------------------------------------------------

validate_gradle_path() {
  local re='^(:[a-z0-9][a-z0-9-]*)+$'
  [[ $1 =~ $re ]] || usage_error "invalid Gradle project path '$1' (expected e.g. :source-database)"
}

# Prints the stacks stacks.yml declares for a project name (one flow-style line per project).
declared_stacks() {
  local line
  line=$(grep -m 1 -E "^$1:[[:space:]]*\[" "$STACKS_FILE") || return 1
  line=${line#*\[}
  line=${line%%\]*}
  line=${line//,/ }
  # shellcheck disable=SC2086 # word splitting trims the list
  echo $line
}

# --- engine ------------------------------------------------------------------------------------------

detect_engine() {
  if [[ -n ${COMPOSE_BIN:-} ]]; then
    read -r -a COMPOSE_CMD <<<"$COMPOSE_BIN"
    [[ ${#COMPOSE_CMD[@]} -gt 0 ]] || die 5 "COMPOSE_BIN is blank; use \"docker compose\" or \"podman compose\"."
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
  else
    die 5 "no container engine with compose found. Install Docker with the compose plugin, or Podman with a compose provider, or set COMPOSE_BIN=\"docker compose\" | \"podman compose\"."
  fi
  ENGINE=${COMPOSE_CMD[0]%-compose} # docker, podman (also for docker-compose / podman-compose)
  command -v "${COMPOSE_CMD[0]}" >/dev/null 2>&1 || die 5 "'${COMPOSE_CMD[0]}' (COMPOSE_BIN) is not on PATH."
  command -v "$ENGINE" >/dev/null 2>&1 || die 5 "container engine '$ENGINE' is not on PATH."
  "${COMPOSE_CMD[@]}" version >/dev/null 2>&1 \
    || die 5 "'${COMPOSE_CMD[*]} version' failed: compose is not installed or not working."
  with_timeout 30 "$ENGINE" info >/dev/null 2>&1 \
    || die 5 "cannot reach the $ENGINE engine ('$ENGINE info' failed). Start Docker, or for Podman run 'podman machine start' or 'systemctl --user start podman.socket'; COMPOSE_BIN selects the engine."
}

compose() {
  local args=() f
  for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do args+=(--env-file "$f"); done
  "${COMPOSE_CMD[@]}" ${args[@]+"${args[@]}"} "$@"
}

# --- run identity and stack context --------------------------------------------------------------------

init_run_identity() {
  CI_RUN_ID=${CI_RUN_ID:-${GITHUB_RUN_ID:-local}}
  CI_RUN_ATTEMPT=${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-0}}
  # The run labels are <group>.ci.run and <group>.ci.attempt (ADR-0041). The group is read without a YAML parser: the
  # value of the first `group:` line of platform.yml, which the build checks is projects[0].group, unquoted.
  [[ -f $PLATFORM_FILE ]] || die 4 "platform.yml not found in $REPO_ROOT: its projects[0].group starts every label key (ADR-0041)"
  LABEL_PREFIX=$(awk '/^[ \t]*(-[ \t]+)?group:/ {
    sub(/^[ \t]*(-[ \t]+)?group:/, ""); sub(/#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
  }' "$PLATFORM_FILE")
  [[ $LABEL_PREFIX =~ $GROUP_PATTERN ]] \
    || die 4 "platform.yml: projects[0].group '$LABEL_PREFIX' must be lower-case words of letters and digits joined by dots, unquoted on a line of its own: every label key starts with it (ADR-0041)"
  export CI_RUN_ID CI_RUN_ATTEMPT LABEL_PREFIX
}

in_ci() { [[ $CI_RUN_ID != local ]]; }

# ADR-0024: ci-<run_id>-<attempt> in CI, local-<AppName> on a laptop; COMPOSE_PROJECT_NAME wins.
project_name_for() {
  if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf '%s' "$COMPOSE_PROJECT_NAME"
  elif in_ci; then
    printf 'ci-%s-%s' "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
  else
    printf 'local-%s' "$1"
  fi
}

validate_project_name() {
  local re='^[a-z0-9][a-z0-9_-]*$'
  [[ $COMPOSE_PROJECT_NAME =~ $re ]] \
    || usage_error "'$COMPOSE_PROJECT_NAME' is not a valid compose project name (lower-case letters, digits, '-' and '_')"
}

state_file_for() { printf '%s/%s.env' "$STATE_DIR" "$1"; }

# For diagnostics / down / leak-check: find the stack by COMPOSE_PROJECT_NAME, --project or the only
# state file, then load what `up` recorded (compose files, env files, interpolation values).
load_context() {
  local gradle_path=${1:-} f name
  local candidates=()
  if [[ -z ${COMPOSE_PROJECT_NAME:-} && -n $gradle_path ]]; then
    COMPOSE_PROJECT_NAME=$(project_name_for "${gradle_path##*:}")
  fi
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]]; then
    for f in "$STATE_DIR"/*.env; do
      name=${f##*/}
      name=${name%.env}
      # <project>.env only: <project>.compose.env, .it-runner.env and .host.env belong to it.
      if [[ -f $f && $name != *.* ]]; then candidates+=("$f"); fi
    done
    if [[ ${#candidates[@]} -eq 1 ]]; then
      name=${candidates[0]##*/}
      COMPOSE_PROJECT_NAME=${name%.env}
    elif [[ ${#candidates[@]} -gt 1 ]]; then
      usage_error "several stacks are recorded in $(rel "$STATE_DIR"); set COMPOSE_PROJECT_NAME or pass --project <gradle path>"
    fi
  fi
  [[ -n ${COMPOSE_PROJECT_NAME:-} ]] || return 0
  export COMPOSE_PROJECT_NAME
  STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")
  if [[ -f $STATE_FILE ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    set +a
  fi
  ENV_FILES=()
  if [[ -n ${COMPOSE_ENV_FILES:-} ]]; then
    local IFS=,
    # shellcheck disable=SC2206 # split the comma-separated list on purpose
    ENV_FILES=($COMPOSE_ENV_FILES)
  fi
}

# A value recorded by an earlier `up` of the same project (keeps a running dependency's generated secret).
previous_value() {
  [[ -f $STATE_FILE ]] || return 0
  (
    # shellcheck source=/dev/null
    . "$STATE_FILE" >/dev/null 2>&1
    printf '%s' "${!1:-}"
  )
}

write_state() {
  local var tmp=$STATE_FILE.tmp
  mkdir -p "$STATE_DIR"
  (
    umask 077
    {
      printf '# Written by test-infra/compose/stack.sh up (%s). May contain throwaway test secrets.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '# To run compose against this stack: set -a; . %s; set +a\n' "$(rel "$STATE_FILE")"
      for var in $STATE_VARS $STACK_ENV_KEYS; do
        if [[ -n ${!var:-} ]]; then printf '%s=%q\n' "$var" "${!var}"; fi
      done
    } >"$tmp"
  )
  mv "$tmp" "$STATE_FILE"
}

export_github_env() {
  [[ -n ${GITHUB_ENV:-} ]] || return 0
  local var
  for var in $STACK_SECRETS; do printf '::add-mask::%s\n' "${!var}"; done
  for var in $STATE_VARS $STACK_ENV_KEYS; do
    if [[ -n ${!var:-} ]]; then printf '%s=%s\n' "$var" "${!var}" >>"$GITHUB_ENV"; fi
  done
}

generate_secret() {
  local random
  if command -v openssl >/dev/null 2>&1; then
    random=$(openssl rand -hex 16)
  else
    random=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  # Upper case, lower case, digits and a symbol: meets common database password policies.
  printf 'It-%s-Aa1' "$random"
}

# --- what the stacks publish to the tests (stacks.yml, ADR-0038) ----------------------------------------

# Prints one field of a stack's declaration under `stacks:` in stacks.yml: the `seed` command, or the entries of its
# `env` or `local_env` list, one per line. Block style with two-space steps, as the file's header describes.
stack_field() {
  awk -v stack="$1" -v field="$2" -v q="'" '
    function clean(s) {
      sub(/[[:space:]]+#.*$/, "", s); sub(/[[:space:]]+$/, "", s)
      if (length(s) >= 2 && (s ~ /^".*"$/ || (substr(s, 1, 1) == q && substr(s, length(s), 1) == q))) s = substr(s, 2, length(s) - 2)
      return s
    }
    /^[^[:space:]#]/ { in_stacks = ($0 ~ /^stacks:[[:space:]]*$/); on = 0; next }
    !in_stacks || /^[[:space:]]*(#|$)/ { next }
    /^  [^[:space:]-][^:]*:[[:space:]]*$/ { name = $1; sub(/:$/, "", name); on = (name == stack); list = 0; next }
    !on { next }
    /^    +- / { if (list) { s = $0; sub(/^ +- +/, "", s); print clean(s) }; next }
    /^    [^[:space:]]/ {
      key = $1; sub(/:.*$/, "", key); list = (key == field && field != "seed")
      if (key == field && field == "seed") { s = $0; sub(/^ +[^:]*:[[:space:]]*/, "", s); print clean(s) }
    }
  ' "$STACKS_FILE"
}

# Expands ${NAME} and ${NAME:-default} in a declared value from the environment, which by then holds the entries
# declared before it. Fails on an unset ${NAME} without a default.
expand_value() {
  local rest=$1 out='' name re='^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}(.*)$'
  while [[ $rest =~ $re ]]; do
    out+=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    if [[ -n ${!name:-} ]]; then
      out+=${!name}
    elif [[ -n ${BASH_REMATCH[3]} ]]; then
      out+=${BASH_REMATCH[4]}
    else
      return 1
    fi
    rest=${BASH_REMATCH[5]}
  done
  # shellcheck disable=SC2016 # a literal ${ left over: a malformed reference
  [[ $rest != *'${'* ]] || return 1
  printf '%s' "$out$rest"
}

# Resolves the env entries of the given stacks, in order. Each `env` entry is exported (compose interpolates it in
# the stack files and the app's overrides) and recorded in the state file. Writes them for the tests: $1 as the
# it-runner sees the stack, on its network; $2 as a JVM on the host does, each `local_env` entry replacing the env
# entry of its key. A KEY=<generated-secret> entry keeps the value of the environment, else of the previous up of
# the same project, else gets a new one.
write_stack_env() {
  local runner_file=$1 host_file=$2 stack list entry key value runner='' host=''
  shift 2
  STACK_ENV_KEYS='' STACK_SECRETS=''
  for stack in "$@"; do
    for list in env local_env; do
      while IFS= read -r entry; do
        [[ $entry =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || usage_error "up: stacks.yml: '$entry' in $stack.$list is not KEY=value"
        key=${entry%%=*}
        value=${entry#*=}
        # shellcheck disable=SC2086 # one word per name
        ! has_word "$key" $STATE_VARS || usage_error "up: stacks.yml: $stack.$list sets $key, which stack.sh sets itself"
        if [[ $value == '<generated-secret>' ]]; then
          [[ $list == env ]] || usage_error "up: stacks.yml: $key=<generated-secret> belongs in $stack.env, not $stack.$list"
          value=${!key:-$(previous_value "$key")}
          [[ -n $value ]] || value=$(generate_secret)
          STACK_SECRETS+=" $key"
        else
          value=$(expand_value "$value") \
            || usage_error "up: stacks.yml: '$entry' in $stack.$list refers to a variable that is not set (use \${NAME:-default})"
        fi
        if [[ $list == env ]]; then
          export "$key=$value"
          # shellcheck disable=SC2086
          has_word "$key" $STACK_ENV_KEYS || STACK_ENV_KEYS+=" $key"
          runner+="$key=$value"$'\n'
        fi
        host+="$key=$value"$'\n'
      done < <(stack_field "$stack" "$list")
    done
  done
  (
    umask 077
    printf '# Written by stack.sh up: the env entries of the stacks (stacks.yml), for the it-runner.\n%s' "$runner" >"$runner_file"
    {
      printf '# Written by stack.sh up: the env entries of the stacks (stacks.yml) with local_env, for a JVM on the host.\n'
      # One line per key in the order of its first entry; the last value wins.
      printf '%s' "$host" | awk '{ k = substr($0, 1, index($0, "=") - 1); if (!(k in v)) o[++n] = k; v[k] = substr($0, index($0, "=") + 1) }
        END { for (i = 1; i <= n; i++) print o[i] "=" v[o[i]] }'
    } >"$host_file"
  )
}

short_sha() {
  local sha=${GITHUB_SHA:-}
  [[ -n $sha ]] || sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
  if [[ -n $sha ]]; then printf '%s' "${sha:0:7}"; else printf 'local'; fi
}

# The AppInstance the project's test cases run against (manifest key `instance`), when they agree.
manifest_instance() {
  local f instance found=''
  for f in "$TEST_INFRA_DIR/testdata/$1"/*/manifest.yml; do
    [[ -f $f ]] || continue
    instance=$(sed -n '/^instance:/{s/^instance:[[:space:]]*\([a-z0-9-]*\).*/\1/p;q;}' "$f")
    [[ -n $instance ]] || continue
    if [[ -z $found ]]; then
      found=$instance
    elif [[ $found != "$instance" ]]; then
      return 0
    fi
  done
  printf '%s' "$found"
}

# Interpolation values for the app's compose files when it joins the stack, mirroring what run-compose.sh exports
# (ADR-0012): identity, the Spring layer files, the combined env, the image under test. APP_OVERRIDES: the
# instance's config-tree compose overrides that exist (the shared template and the app's override come from cmd_up).
prepare_app() {
  local app=$1 base config_root=${CONFIG_ROOT:-$REPO_ROOT/config} file dir
  # Absolute: compose resolves a relative path against the first compose file's directory.
  if [[ -d $config_root ]]; then config_root=$(cd "$config_root" && pwd -P); fi
  export APP_NAME=${APP_NAME:-$app} APP_ENV=${APP_ENV:-local}
  # The flow: APP_FLOW, else the one flow of config/<env>/ that configures the app (the flows of platform.yml,
  # ADR-0030: none is a default).
  if [[ -z ${APP_FLOW:-} ]]; then
    local flows=()
    for dir in "$config_root/$APP_ENV"/*/"$APP_NAME"/; do
      if [[ -d $dir ]]; then flows+=("$(basename "$(dirname "$dir")")"); fi
    done
    case ${#flows[@]} in
      0) usage_error "up: no flow of $(rel "$config_root/$APP_ENV") configures $APP_NAME: add config/$APP_ENV/<flow>/$APP_NAME/ (ADR-0011), or set APP_FLOW" ;;
      1) APP_FLOW=${flows[0]} ;;
      *) usage_error "up: $APP_NAME is configured in several flows of $(rel "$config_root/$APP_ENV") (${flows[*]}); set APP_FLOW" ;;
    esac
  fi
  export APP_FLOW
  base=$config_root/$APP_ENV/$APP_FLOW/$APP_NAME
  # The instance whose config the app under test runs with (ADR-0025): APP_INSTANCE, else the instance the
  # app's test-case manifest names, else the app's only instance directory under config/<env>/<flow>/<app>
  # (the hello-world apps have no test case yet). The app template requires it (${APP_INSTANCE:?}), so a
  # missing instance fails here, with the remedy, rather than as a compose interpolation error.
  if [[ -z ${APP_INSTANCE:-} ]]; then
    APP_INSTANCE=$(manifest_instance "$app")
  fi
  if [[ -z $APP_INSTANCE ]]; then
    # The instance directories of config/<env>/<flow>/<app> (the app's own layers are files, ADR-0011).
    local candidates=() name
    for dir in "$base"/*/; do
      name=$(basename "$dir")
      if [[ -d $dir && $name != _* && $name != .* ]]; then candidates+=("$name"); fi
    done
    case ${#candidates[@]} in
      0) usage_error "up: no instance for $app: $(rel "$base") has no instance directory. Add one (ADR-0011), set APP_INSTANCE, or add a test-infra/testdata/$app/<case>/manifest.yml that names one" ;;
      1) APP_INSTANCE=${candidates[0]} ;;
      *) usage_error "up: $app has several instances under $(rel "$base") (${candidates[*]}); set APP_INSTANCE or add a test-infra/testdata/$app/<case>/manifest.yml that names one" ;;
    esac
  fi
  export APP_INSTANCE
  [[ -d $base/$APP_INSTANCE ]] || usage_error "up: the instance config $(rel "$base/$APP_INSTANCE") does not exist (APP_INSTANCE=$APP_INSTANCE)"
  export PROJECT=$COMPOSE_PROJECT_NAME

  # A template written as ${IMAGE_REPO}/${APP_NAME}:${IMAGE_TAG} must run APP_IMAGE and not the tag of the env
  # layers, so both are derived from it (they override the layers). A digest-only reference gets the placeholder
  # tag `by-digest`: with name:tag@digest, Docker and Podman pull by digest and ignore the tag.
  local ref=$APP_IMAGE digest='' last
  if [[ $ref == *@* ]]; then
    digest=${ref#*@}
    ref=${ref%%@*}
  fi
  last=${ref##*/}
  if [[ $last == *:* ]]; then
    export IMAGE_REPO=${ref%/*} IMAGE_TAG=${last#*:}${digest:+@$digest}
  else
    export IMAGE_REPO=${ref%/*} IMAGE_TAG=by-digest@$digest
  fi
  [[ ${last%%:*} == "$APP_NAME" ]] || warn "APP_IMAGE names '${last%%:*}', not '$APP_NAME'"

  # The combined env of the instance's layers, written by run-compose.sh itself (one merge implementation, with its
  # checks), with IMAGE_REPO / IMAGE_TAG above as its last layer.
  COMPOSE_ENV_FILE=$(env -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT CONFIG_ROOT="$config_root" \
    "$REPO_ROOT/scripts/run-compose.sh" "$APP_ENV" "$APP_FLOW" "$APP_NAME" "$APP_INSTANCE" compose-env -q) \
    || usage_error "up: scripts/run-compose.sh could not write the combined env of $APP_ENV/$APP_FLOW/$APP_NAME/$APP_INSTANCE"
  export COMPOSE_ENV_FILE
  export APP_APP_YML=$base/application.app.yml INSTANCE_APP_YML=$base/$APP_INSTANCE/application.instance.yml
  unset FLOW_APP_YML
  if [[ -f $config_root/$APP_ENV/$APP_FLOW/application.flow.yml ]]; then
    export FLOW_APP_YML=$config_root/$APP_ENV/$APP_FLOW/application.flow.yml
  fi
  # The template publishes 127.0.0.1:${ACTUATOR_HOST_PORT:?...}, which compose interpolates even when the CI
  # override drops the port. The shell beats --env-file, so the combined env's value is taken over, else 18080; the
  # state file records it, and a test JVM on the host finds the actuator there.
  if [[ -z ${ACTUATOR_HOST_PORT:-} ]]; then
    ACTUATOR_HOST_PORT=$(sed -n 's/^ACTUATOR_HOST_PORT=//p' "$COMPOSE_ENV_FILE" | tail -n 1)
    export ACTUATOR_HOST_PORT=${ACTUATOR_HOST_PORT:-18080}
  fi
  APP_OVERRIDES=()
  for file in "$config_root/$APP_ENV/$APP_FLOW/_docker-compose.flow.yml" "$base/_docker-compose.app.yml" \
    "$base/$APP_INSTANCE/_docker-compose.instance.yml"; do
    if [[ -f $file ]]; then APP_OVERRIDES+=("$file"); fi
  done
}

# Compose rejects an override for a service the stack does not define, so --local gets local-ports.yml
# filtered to the stack's services (one two-space-indented "<service>:" block each, see the file).
write_local_ports() {
  local out=$1
  shift
  (
    umask 077
    awk -v keep=" $* " '
      /^services:[[:space:]]*$/          { print; next }
      /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); on = index(keep, " " svc " ") > 0 }
      /^[^[:space:]#]/                   { on = 0 }
      on                                 { print }
    ' "$COMPOSE_DIR/local-ports.yml" >"$out"
  )
  if [[ $(wc -l <"$out") -le 1 ]]; then printf 'services: {}\n' >"$out"; fi
}

# ADR-0024: nothing publishes a port in CI. The app template publishes its actuator on 127.0.0.1; this
# override, merged after it, empties that list (compose `!reset`, Docker Compose 2.24+), so the template
# stays as it is. Tests reach the app as <AppName>:8080 on the stack network (the alias of the service `app`).
write_app_no_ports() {
  local out=$1 service=$2
  (
    umask 077
    printf '# Written by stack.sh up in CI: the app under test publishes no port (ADR-0024).\n' >"$out"
    printf 'services:\n  %s:\n    ports: !reset []\n' "$service" >>"$out"
  )
}

# --- labels, prune, leftovers ------------------------------------------------------------------------

# Filters that identify what this run created (ADR-0024). In CI: the run label, which also covers
# run-compose.sh stacks of the same run, plus the project label. On a laptop every stack shares the
# run label "local", so only the project label is used; without a project, all local stacks. The run label's key
# is <group>.ci.run (ADR-0041): the prefix up recorded in the state file when there is one, so teardown matches
# what up labelled, else the group of platform.yml.
label_filters() {
  if in_ci; then
    printf 'label=%s.ci.run=%s\n' "$LABEL_PREFIX" "$CI_RUN_ID"
    if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then printf 'label=%s=%s\n' "$LABEL_PROJECT" "$COMPOSE_PROJECT_NAME"; fi
  elif [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf 'label=%s=%s\n' "$LABEL_PROJECT" "$COMPOSE_PROJECT_NAME"
  else
    printf 'label=%s.ci.run=local\n' "$LABEL_PREFIX"
  fi
}

filters_text() { label_filters | sed 's/^label=//' | paste -s -d ' ' - | sed 's/ / or /g'; }

prune_by_labels() {
  local filter ids
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    ids=$("$ENGINE" ps -aq --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing containers with $filter"
      # shellcheck disable=SC2086 # one argument per id
      "$ENGINE" rm -f -v $ids >/dev/null || warn "could not remove every container with $filter"
    fi
    ids=$("$ENGINE" volume ls -q --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing volumes with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" volume rm -f $ids >/dev/null || warn "could not remove every volume with $filter"
    fi
    ids=$("$ENGINE" network ls -q --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing networks with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" network rm $ids >/dev/null || warn "could not remove every network with $filter"
    fi
  done <<<"$(label_filters)"
}

# One line per resource still carrying a label of this run: "<kind> <id or name> [details]".
list_leftovers() {
  local filter
  {
    while IFS= read -r filter; do
      [[ -n $filter ]] || continue
      "$ENGINE" ps -a --filter "$filter" --format 'container {{.ID}} {{.Names}} ({{.Status}})'
      "$ENGINE" volume ls --filter "$filter" --format 'volume {{.Name}}'
      "$ENGINE" network ls --filter "$filter" --format 'network {{.ID}} {{.Name}}'
    done <<<"$(label_filters)"
  } | sort -u
}

# --- commands ----------------------------------------------------------------------------------------

cmd_up() {
  local gradle_path='' local_ports=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "up: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      --local) local_ports=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "up: unknown argument '$1'" ;;
    esac
  done
  [[ -n $gradle_path ]] || usage_error "up: --project <gradle path> is required"
  validate_gradle_path "$gradle_path"
  local app=${gradle_path##*:} project_dir=${gradle_path#:} stacks stack app_file='' app_override='' candidate
  project_dir=${project_dir//://}
  stacks=$(declared_stacks "$app") || usage_error "up: stacks.yml declares no stacks for '$app' ($gradle_path)"
  [[ -n $stacks ]] || usage_error "up: the stack list for '$app' in stacks.yml is empty"
  for stack in $stacks; do
    [[ -f $COMPOSE_DIR/$stack.yml ]] || usage_error "up: stacks.yml names '$stack' but test-infra/compose/$stack.yml does not exist"
  done
  if [[ -n ${APP_IMAGE:-} ]]; then
    local re='^[^/@[:space:]]+(/[^/@[:space:]]+)+(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?(@sha256:[0-9a-f]{64})?$'
    [[ $APP_IMAGE =~ $re && ( ${APP_IMAGE##*/} == *:* || $APP_IMAGE == *@* ) ]] \
      || usage_error "up: APP_IMAGE '$APP_IMAGE' must be <registry>/<path>/<AppName>:<tag>, <...>@sha256:<digest>, or both"
    # The shared compose template (ADR-0012), then the app's own override when it has one: apps/<AppName>/
    # (ADR-0006), else the directory of the Gradle path (a monorepo nesting its apps, e.g. deephaven-connectors/<AppName>/),
    # else any <dir>/<AppName>/ (platform.yml's apps_dir, ADR-0030).
    app_file=$REPO_ROOT/docker/docker-compose.yml
    [[ -f $app_file ]] || usage_error "up: APP_IMAGE is set but docker/docker-compose.yml (the shared compose template) is missing"
    for candidate in "$REPO_ROOT/apps/$app" "$REPO_ROOT/$project_dir" "$REPO_ROOT"/*/"$app"; do
      if [[ -f $candidate/docker/docker-compose.override.yml ]]; then app_override=$candidate/docker/docker-compose.override.yml; break; fi
    done
  fi

  detect_engine
  init_run_identity
  COMPOSE_PROJECT_NAME=$(project_name_for "$app")
  export COMPOSE_PROJECT_NAME
  validate_project_name
  STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")

  # Test-only settings (ADR-0013, ADR-0025).
  export IT_TABLE_PREFIX=${IT_TABLE_PREFIX:-it_$(short_sha)_}
  export IT_RUNNER_UID=${IT_RUNNER_UID:-$(id -u)} IT_RUNNER_GID=${IT_RUNNER_GID:-$(id -g)}
  export IT_WORKSPACE=${IT_WORKSPACE:-$REPO_ROOT}
  export IT_GRADLE_HOME=${IT_GRADLE_HOME:-${GRADLE_USER_HOME:-$HOME/.gradle}}
  mkdir -p "$IT_GRADLE_HOME" # created by the caller, not by the engine as root
  export STACK_PROJECT=$gradle_path STACK_SERVICES=${stacks// /,}
  # What the stacks publish to the tests (stacks.yml, ADR-0038). The it-runner reads its file through env_file,
  # which compose resolves against test-infra/compose/, so the path is absolute.
  mkdir -p "$STATE_DIR"
  export IT_RUNNER_ENV_FILE
  IT_RUNNER_ENV_FILE=$(cd "$STATE_DIR" && pwd -P)/$COMPOSE_PROJECT_NAME.it-runner.env
  # shellcheck disable=SC2086 # one argument per stack
  write_stack_env "$IT_RUNNER_ENV_FILE" "${STATE_FILE%.env}.host.env" $stacks

  ENV_FILES=("$VERSIONS_ENV")
  local files=("$COMPOSE_DIR/base.yml")
  for stack in $stacks; do files+=("$COMPOSE_DIR/$stack.yml"); done
  files+=("$COMPOSE_DIR/it-runner.yml")
  if [[ -n $app_file ]]; then
    files+=("$app_file")
    if [[ -n $app_override ]]; then files+=("$app_override"); fi
    prepare_app "$app"
    files+=(${APP_OVERRIDES[@]+"${APP_OVERRIDES[@]}"})
    # One env file for the whole stack: podman-compose keeps only the last of several --env-file flags.
    local stack_env=${STATE_FILE%.env}.compose.env
    (umask 077; cat "$VERSIONS_ENV" "$COMPOSE_ENV_FILE" >"$stack_env")
    ENV_FILES=("$stack_env")
    if in_ci; then
      local no_ports_file=${STATE_FILE%.env}.app-no-ports.yml
      write_app_no_ports "$no_ports_file" app
      files+=("$no_ports_file")
    fi
  fi
  if $local_ports; then
    local ports_file=${STATE_FILE%.env}.local-ports.yml
    # shellcheck disable=SC2086 # one argument per service
    write_local_ports "$ports_file" $stacks
    files+=("$ports_file")
  fi
  COMPOSE_FILE=$(IFS=:; printf '%s' "${files[*]}")
  COMPOSE_ENV_FILES=$(IFS=,; printf '%s' "${ENV_FILES[*]}")
  export COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR=:
  write_state
  export_github_env

  log "project $COMPOSE_PROJECT_NAME ($gradle_path): $stacks${APP_IMAGE:+ + ${APP_NAME:-app} ($APP_IMAGE)}"
  log "compose files: $(for f in "${files[@]}"; do printf '%s ' "$(rel "$f")"; done)"
  if [[ ${STACK_SKIP_PULL:-0} != 1 ]]; then
    log "pulling dependency images"
    # Only the dependencies: the app image may exist only locally (Gradle buildImage, tag `local`);
    # up pulls it when it is missing.
    # shellcheck disable=SC2086
    compose pull --quiet $stacks || up_failed "pulling the dependency images failed"
  fi
  log "starting $stacks (up --wait, ${WAIT_TIMEOUT}s)"
  # shellcheck disable=SC2086
  compose up --wait --wait-timeout "$WAIT_TIMEOUT" $stacks || up_failed "the dependencies did not become healthy"
  # Each stack's seed (stacks.yml), in the stack's own service, before the app starts.
  local seed seed_args=()
  for stack in $stacks; do
    seed=$(stack_field "$stack" seed)
    [[ -n $seed ]] || continue
    read -r -a seed_args <<<"$seed"
    log "seeding $stack: $seed"
    compose exec -T "$stack" "${seed_args[@]}" || up_failed "seeding $stack failed ($seed)"
  done
  if [[ -n $app_file ]]; then
    log "starting the app under test (up --wait, ${WAIT_TIMEOUT}s)"
    compose up --wait --wait-timeout "$WAIT_TIMEOUT" --quiet-pull || up_failed "the app under test did not become healthy"
  fi

  log "up: $COMPOSE_PROJECT_NAME is healthy"
  log "  state file: $(rel "$STATE_FILE")  (set -a; . <file>; set +a  to run compose against the stack)"
  log "  network for run-compose.sh: DEPS_NETWORK=${COMPOSE_PROJECT_NAME}_default"
  if $local_ports; then
    # What the stacks publish to a JVM on the host (stacks.yml); a value holding a secret stays in the file.
    local line secret summary=''
    while IFS= read -r line; do
      [[ -n $line && $line != '#'* ]] || continue
      for secret in $STACK_SECRETS; do
        if [[ ${line#*=} == *"${!secret}"* ]]; then line="${line%%=*}=<secret>"; fi
      done
      summary+=" $line"
    done <"${STATE_FILE%.env}.host.env"
    log "  for the tests on this host:${summary:- nothing} ($(rel "${STATE_FILE%.env}.host.env"))"
  fi
}

up_failed() {
  warn "$1. Stack state follows; 'stack.sh diagnostics <dir>' collects the full bundle."
  compose ps -a >&2 || true
  compose logs --no-color --timestamps --tail 50 >&2 || true
  # The interleaved tail is dominated by the chatty services; show each failed container's own last lines.
  local line service state health
  while read -r service state health; do
    [[ -n $service ]] || continue
    if [[ $state != running || $health == unhealthy ]]; then
      warn "last output of $service ($state${health:+, $health}):"
      compose logs --no-color --no-log-prefix --tail 40 "$service" >&2 || true
    fi
  done < <(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null || true)
  die 1 "up failed for $COMPOSE_PROJECT_NAME: $1 (tear down with: test-infra/compose/stack.sh down)"
}

cmd_diagnostics() {
  local dir='' gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "diagnostics: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage_error "diagnostics: unknown option '$1'" ;;
      *)
        [[ -z $dir ]] || usage_error "diagnostics: exactly one directory expected"
        dir=$1
        shift
        ;;
    esac
  done
  [[ -n $dir ]] || usage_error "diagnostics: <dir> is required"
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]] && ! in_ci; then
    usage_error "diagnostics: no stack recorded; set COMPOSE_PROJECT_NAME or pass --project <gradle path>"
  fi
  mkdir -p "$dir"
  log "diagnostics for $(filters_text) into $dir"

  # compose-ps.txt: the compose view when up recorded the files, the engine view otherwise.
  if [[ -n ${COMPOSE_FILE:-} && -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    compose ps -a >"$dir/compose-ps.txt" 2>&1 || true
  else
    : >"$dir/compose-ps.txt"
  fi
  local filter ids=''
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    "$ENGINE" ps -a --filter "$filter" >>"$dir/compose-ps.txt" 2>&1 || true
    ids+=" $("$ENGINE" ps -aq --filter "$filter" 2>/dev/null || true)"
  done <<<"$(label_filters)"
  # shellcheck disable=SC2086 # one line per id
  ids=$(printf '%s\n' $ids | sort -u | paste -s -d ' ' -)

  local id service name base
  for id in $ids; do
    service=$("$ENGINE" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)
    [[ $service != '<no value>' ]] || service=
    name=$("$ENGINE" inspect --format '{{.Name}}' "$id" 2>/dev/null || true)
    name=${name#/}
    base=${service:-${name:-$id}}
    [[ ! -e $dir/$base.log ]] || base=${name:-$id}
    "$ENGINE" logs --timestamps "$id" >"$dir/$base.log" 2>&1 || true
    "$ENGINE" inspect --format '{{json .State.Health}}' "$id" >"$dir/health-$base.json" 2>/dev/null || true
  done
  if [[ -n $ids ]]; then
    # shellcheck disable=SC2086
    "$ENGINE" stats --no-stream $ids >"$dir/stats.txt" 2>&1 || true
  else
    printf 'no containers match %s\n' "$(filters_text)" >"$dir/stats.txt"
  fi
  log "wrote $(cd "$dir" && printf '%s ' *)"
}

cmd_down() {
  local gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "down: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "down: unknown argument '$1'" ;;
    esac
  done
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]] && ! in_ci; then
    log "down: no stack recorded (no COMPOSE_PROJECT_NAME, nothing in $(rel "$STATE_DIR")); nothing to do"
    return 0
  fi

  if [[ -n ${COMPOSE_FILE:-} && -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    # The files are parsed again with the variables up recorded (the state file, $GITHUB_ENV in CI), the stacks'
    # env entries among them; the env files they name are removed only after this.
    log "down: project $COMPOSE_PROJECT_NAME (down -v --remove-orphans --timeout $DOWN_TIMEOUT)"
    compose down -v --remove-orphans --timeout "$DOWN_TIMEOUT" \
      || warn "compose down failed; removing by label instead"
  else
    log "down: no compose files recorded for ${COMPOSE_PROJECT_NAME:-this run}; removing by label"
  fi
  prune_by_labels
  if [[ -n ${STATE_FILE:-} ]]; then
    rm -f "$STATE_FILE" "${STATE_FILE%.env}.local-ports.yml" "${STATE_FILE%.env}.app-no-ports.yml" "${STATE_FILE%.env}.compose.env" \
      "${STATE_FILE%.env}.it-runner.env" "${STATE_FILE%.env}.host.env"
  fi

  local leftovers
  leftovers=$(list_leftovers)
  if [[ -n $leftovers ]]; then
    printf '%s\n' "$leftovers" >&2
    die 1 "down: resources with $(filters_text) remain"
  fi
  log "down: nothing with $(filters_text) remains"
}

cmd_leak_check() {
  local warn_only=false gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --warn-only) warn_only=true; shift ;;
      --project)
        [[ $# -ge 2 ]] || usage_error "leak-check: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "leak-check: unknown argument '$1'" ;;
    esac
  done
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"

  local leftovers what
  what=$(filters_text)
  leftovers=$(list_leftovers)
  if [[ -z $leftovers ]]; then
    log "leak-check: no container, volume or network carries $what"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: clean\n\nNo container, volume or network carries `%s`.\n' "$what" >>"$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi
  local count
  count=$(printf '%s\n' "$leftovers" | wc -l | tr -d ' ')
  printf '[stack] leak-check: %s resource(s) carry %s:\n' "$count" "$what" >&2
  printf '%s\n' "$leftovers" | sed 's/^/  /' >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: %s resource(s) left\n\nFilter: `%s`\n\n| Kind | Resource |\n|---|---|\n' "$count" "$what"
      # shellcheck disable=SC2016
      printf '%s\n' "$leftovers" | sed -E 's/^([a-z]+) (.*)$/| \1 | `\2` |/'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  if $warn_only; then
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::warning title=leak-check::%s resource(s) carry %s\n' "$count" "$what"; fi
    log "leak-check: --warn-only, not failing"
    return 0
  fi
  die 1 "leak-check: $count resource(s) carry $what"
}

main() {
  [[ $# -gt 0 ]] || usage_error "missing command"
  local command=$1
  shift
  case $command in
    up) cmd_up "$@" ;;
    diagnostics) cmd_diagnostics "$@" ;;
    down) cmd_down "$@" ;;
    leak-check) cmd_leak_check "$@" ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command '$command'" ;;
  esac
}

main "$@"
