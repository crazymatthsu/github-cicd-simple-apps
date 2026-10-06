#!/usr/bin/env bash
# run-compose.sh — the one entry point for a connector's compose stack (ADR-0017): local development, CI test
# stacks and the dev compose hosts. Never qa, uat, prod or parallel: those envs are deployed from the configuration
# repository (ADR-0004).
#
# The one implementation for every app (ADR-0017, no per-app wrapper) and one compose template for every app
# (docker/docker-compose.yml, ADR-0012): the config tree names the instance, and the app directory — apps/<AppName>, or
# any <dir>/<AppName> (--app-dir pins it) — only adds what one app needs everywhere (docker/docker-compose.override.yml,
# scripts/smoke.sh). Run with --help for the command table and the file layout. On a box of a host pool (ADR-0028) it runs from a version directory of
# the host bundle, /apps/<user>/versions/<project>/<version>/ (ADR-0018), that scripts/pool-deploy.sh synced: the nearest
# ancestor holding .platform-bundle is the root, `activate` makes that directory the box's `current` one, and
# start / restart first ask the pool's other boxes (the pool guard, ADR-0017).
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4 EXIT_ENGINE=5 EXIT_TIMEOUT=124
readonly COMMANDS="start stop down restart config app-config printenv compose-env health status ps logs pull validate record-tag exec shell version"
readonly COMPOSE_ENV_ALLOWED="IMAGE_REPO IMAGE_TAG APP_ENV APP_FLOW APP_NAME APP_INSTANCE JAVA_OPTS TZ LOG_LEVEL_ROOT LOGS_DIR DATA_DIR MEM_LIMIT"
# Only the instance layer may set these (plus *_HOST_PORT): the image tag, the identity and the published ports.
readonly INSTANCE_ONLY="IMAGE_TAG APP_ENV APP_FLOW APP_NAME APP_INSTANCE"
readonly SCRIPT_VARIABLES="COMPOSE_ENV_FILE FLOW_APP_YML APP_APP_YML INSTANCE_APP_YML PROJECT INSTANCE_LOGS_DIR INSTANCE_DATA_DIR"
# The compose service of every app (docker/docker-compose.yml); other containers reach it as its AppName.
readonly SERVICE=app
readonly IMAGE_TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}(@sha256:[0-9a-f]{64})?$'
readonly VERSION_DIR_PATTERN='^[0-9]{8}-[0-9]{6}$'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

usage() {
    cat <<'EOF'
Usage: run-compose.sh <env> <flow> <AppName> <AppInstance> <command> [args] [options]

  <env>          local | <region>-<stage>, a region and a stage of platform.yml (only local and the dev_envs of
                 platform.yml are allowed here)
  <flow>         a flow of platform.yml
  <AppName>      the app, e.g. source-database (apps/<AppName>)
  <AppInstance>  the pipeline, e.g. trades-db-to-amps (config/<env>/<flow>/<AppName>/<AppInstance>/)

Commands (ADR-0017):
  start [--no-wait]     up -d --wait (--wait-timeout $START_TIMEOUT, default 180); 124 on timeout
  stop                  stop -t $STOP_TIMEOUT (default 30)
  down [--volumes]      down --remove-orphans; --volumes adds -v (on *-dev hosts also needs --force)
  restart               stop, then start (picks up env layer, image and mount changes)
  config                the rendered compose configuration, secrets masked
  app-config [--offline]  the app's effective configuration (actuator), or --offline: run --print-config
  printenv              the resolved environment (paths, identity, engine, the combined env), secrets masked
  compose-env           write the combined env (below) and print its path
  health                container running and /actuator/health/readiness UP; 1 otherwise
  status | ps           ps, plus drift between the desired image and the running one; 1 on drift
  logs [-f] [--since T] [--tail N]
  pull                  pre-pull the image (the only command that contacts the registry)
  validate              offline checks: names, required files, env layer rules, variables, override paths, compose lint
  record-tag            host bundle only: write IMAGE_TAG (required in this shell) into the instance's
                        _docker-compose.instance.env
                        of this version directory, so a start there runs that tag (pool-deploy.sh, before pull /
                        start / health; the directory is the record, ADR-0018)
  exec <svc> <cmd...>   exec in a service (arguments after <svc> belong to the command)
  shell                 exec app sh (every app's service is `app`; other containers reach it as <AppName>)
  version               tag, digest and OCI labels of the running image

Host bundle form (a box of a host pool, ADR-0018):
  run-compose.sh activate [--keep N] [--previous | --to <version>] [--dry-run]
                        make this version directory, /apps/<user>/versions/<project>/<version>/, the box's `current`
                        one (an atomic symlink switch), create /logs/<user>/<project>/{logs,data}, and
                        remove the versions beyond the newest N (default 5; never current or the one it replaced).
                        --previous / --to <version> switch current to an older version instead (a rollback,
                        run through current/scripts/run-compose.sh). Prints `activated <version>` on stdout.

Options (before or after the command):
  --dry-run             print the resolved paths, identity, engine and exact command lines; run nothing
  --force               allow a guarded operation (down --volumes on *-dev; start / restart past the pool
                        guard); never overrides the env allow-list
  --engine docker|podman  force the engine (default: $RUN_COMPOSE_ENGINE, else docker, then podman)
  --json                machine-readable output for health, status and version
  -q, --quiet           less informational output
  -h, --help            this text

Files (ADR-0012; <c> = config/<env>/<flow>, every file optional unless marked):
  compose  -f docker/docker-compose.yml (required) -f apps/<AppName>/docker/docker-compose.override.yml
           -f <c>/_docker-compose.flow.yml -f <c>/<AppName>/_docker-compose.app.yml
           -f <c>/<AppName>/<AppInstance>/_docker-compose.instance.yml
  env      <c>/_docker-compose.flow.env < <c>/<AppName>/_docker-compose.app.env
           < <c>/<AppName>/<AppInstance>/_docker-compose.instance.env (required: IMAGE_TAG, identity, *_HOST_PORT)
           < the shell (IMAGE_TAG / IMAGE_REPO only), merged into ONE combined env,
           .run/<env>/<flow>/<AppName>/<AppInstance>/compose.env under the root: regenerated by every command,
           passed as --env-file and loaded by the template's env_file; each line names the layer it came from
  spring   <c>/application.flow.yml, <c>/<AppName>/application.app.yml (required),
           <c>/<AppName>/<AppInstance>/application.instance.yml (required), each mounted as one file at
           /config/{flow,common,instance}/application.yml (a missing flow layer mounts /dev/null)
  host     LOGS_DIR and DATA_DIR of the env layers: absolute host paths, on a box /logs/<user>/<project>/logs
           and /logs/<user>/<project>/data (ADR-0018). The instance mounts <dir>/<AppName>/<AppInstance> at
           /app/logs and /app/data; start and restart create them, writable by the image's user. Unset: volumes
           of the compose project

Exit codes: 0 ok · 1 operation failed or check negative · 2 usage · 3 refused by a safety rule ·
            4 config tree error · 5 engine not found or not running · 124 timeout
Environment: CONFIG_ROOT (default <repo>/config), START_TIMEOUT, STOP_TIMEOUT, DEPS_NETWORK (join an
existing network, e.g. the one of ./gradlew devUp), RUN_COMPOSE_ENGINE, IMAGE_TAG and IMAGE_REPO (override
the env layers in every env, ADR-0012; deploy-dev's record-tag writes IMAGE_TAG into the new version directory's
_docker-compose.instance.env before pull / start / health run from it; every other value always comes from the
layers), APP_IMAGE (local only: run this image instead of IMAGE_REPO/APP_NAME:IMAGE_TAG);
secrets such as SPRING_DATASOURCE_PASSWORD are passed through from this shell, never from an env layer
(ADR-0013).

Root: the nearest ancestor of this script holding a .platform-bundle marker (a host bundle synced by
scripts/pool-deploy.sh as one version directory /apps/<user>/versions/<project>/<version>/, ADR-0018), else
the git checkout, else the script's parent directory. The root's platform.yml (a host bundle carries a copy)
declares the regions, stages and flows names are checked against, and the dev_envs this script operates
(ADR-0030).
Pool guard (ADR-0028): on a box whose .platform-bundle lists more than one pool host (POOL_HOSTS), start and
restart of an instance of that bundle's env and flow (never local) first ask every other box of the pool
  $POOL_SSH $POOL_SSH_OPTS <POOL_USER>@<box> -- <POOL_ROOT>/current/scripts/run-compose.sh
      <env> <flow> <AppName> <AppInstance> status --json
and refuse (3) when the instance runs there; a box that does not answer is only a warning (a dead box must
not block a failover). --force skips the guard, --dry-run prints its commands, POOL_PEER_CHECK=off disables
it; POOL_SELF_HOST names this box in POOL_HOSTS (default: hostname -f). POOL_SSH is the ssh binary (default
ssh); POOL_SSH_OPTS defaults to -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes, plus
-o UserKnownHostsFile=<CONFIG_ROOT>/<env>/known_hosts when that file exists (an unknown key is never trusted).
EOF
}

# --- output helpers ---------------------------------------------------------------------------------------

QUIET=0
info() { if [ "$QUIET" -eq 0 ]; then printf 'run-compose: %s\n' "$*" >&2; fi; }
warn() { printf 'run-compose: warning: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    printf 'run-compose: error: %s\n' "$*" >&2
    exit "$code"
}
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}
# Relative to the repository root, for readable output.
rel() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

# Values of secret-looking names (ADR-0013: *PASSWORD*, *SECRET*, *TOKEN*, *KEY*; plus the usernames paired with
# secret passwords) -> ***.
mask_stream() {
    awk '
    {
        line = $0
        if (match(line, /^[[:space:]]*-?[[:space:]]*"?[A-Za-z0-9_.-]+"?[[:space:]]*[:=]/)) {
            prefix = substr(line, 1, RLENGTH)
            key = prefix
            gsub(/^[[:space:]]*-?[[:space:]]*"?/, "", key)
            gsub(/"?[[:space:]]*[:=]$/, "", key)
            lk = tolower(key)
            if (lk ~ /(password|passwd|secret|token|credential|key)/ ||
                lk ~ /^(spring_datasource_username|connector_amps_username|connector_kafka_sasl_username)$/) {
                rest = substr(line, RLENGTH + 1)
                if (rest ~ /[^[:space:]]/) {
                    print prefix (prefix ~ /=$/ ? "***" : " ***")
                    next
                }
            }
        }
        print line
    }'
}

# --- the host bundle (ADR-0018, ADR-0028) -----------------------------------------------------------------

# The nearest ancestor of $1 (itself included) that holds a .platform-bundle marker: the root of a host bundle
# that scripts/pool-deploy.sh synced to a box of a pool — one version directory /apps/<user>/versions/<project>/
# <YYYYMMDD-HHMMSS>/ (ADR-0018).
find_bundle_root() {
    local dir="$1"
    while :; do
        if [ -f "$dir/.platform-bundle" ]; then
            printf '%s' "$dir"
            return 0
        fi
        [ "$dir" != / ] || return 1
        dir="$(dirname "$dir")"
    done
}
# One value of a manifest: KEY=value lines, the value optionally in double quotes. Read, never sourced.
manifest_value() { # <manifest> <key>
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }' "$1"
}
BUNDLE_ROOT=""
bundle_value() {
    [ -n "$BUNDLE_ROOT" ] || return 0
    manifest_value "$BUNDLE_ROOT/.platform-bundle" "$1"
}
# activate: this version directory becomes the box's current one — <versions>/current -> <version>, switched
# atomically (a new symlink renamed over the old one); --previous / --to point it at an older version instead.
# The newest --keep versions stay, and always current and the version it replaced, so a rollback stays possible.
cmd_activate() {
    local versions version target previous keep="${KEEP:-5}" tmp v key user_dir logs_root index=0 candidates=() kept=() removed=()
    BUNDLE_ROOT="$(find_bundle_root "$SCRIPT_DIR" || true)"
    [ -n "$BUNDLE_ROOT" ] ||
        die "$EXIT_REFUSED" "activate switches the current version of a host bundle (a box synced by scripts/pool-deploy.sh) only; this is a checkout"
    versions="$(dirname "$BUNDLE_ROOT")" version="$(basename "$BUNDLE_ROOT")"
    [[ $version =~ $VERSION_DIR_PATTERN ]] ||
        die "$EXIT_CONFIG" "$BUNDLE_ROOT is not a version directory: a host bundle lives in /apps/<user>/versions/<project>/<YYYYMMDD-HHMMSS>/ (ADR-0018)"
    [[ $keep =~ ^[0-9]+$ ]] && [ "$keep" -ge 2 ] || die "$EXIT_USAGE" "--keep must be an integer of at least 2 (was '$keep')"
    [ "$ACTIVATE_PREVIOUS" -eq 0 ] || [ -z "$ACTIVATE_TO" ] || die "$EXIT_USAGE" "--previous and --to exclude each other"
    previous="$(readlink "$versions/current" 2>/dev/null || true)"
    previous="${previous%/}" previous="${previous##*/}"
    # Every version directory under <versions>, newest first.
    for v in "$versions"/*/; do
        v="${v%/}" v="${v##*/}"
        [[ $v =~ $VERSION_DIR_PATTERN ]] && [ -f "$versions/$v/.platform-bundle" ] || continue
        candidates+=("$v")
    done
    mapfile -t candidates < <(printf '%s\n' ${candidates[@]+"${candidates[@]}"} | sort -r)
    target="$version"
    if [ -n "$ACTIVATE_TO" ]; then
        [[ $ACTIVATE_TO =~ $VERSION_DIR_PATTERN ]] || die "$EXIT_USAGE" "--to '$ACTIVATE_TO' is not a version (<YYYYMMDD-HHMMSS>)"
        contains_word "$ACTIVATE_TO" "${candidates[*]}" || die "$EXIT_CONFIG" "no version $ACTIVATE_TO under $versions"
        target="$ACTIVATE_TO"
    elif [ "$ACTIVATE_PREVIOUS" -eq 1 ]; then
        target=""
        for v in "${candidates[@]}"; do
            if [[ $v < ${previous:-$version} ]]; then target="$v"; break; fi
        done
        [ -n "$target" ] || die "$EXIT_CONFIG" "no version older than ${previous:-$version} under $versions to go back to"
    fi
    # The target is a bundle of the same project, env and flow: a typo cannot activate another cluster's tree.
    for key in BUNDLE_PROJECT BUNDLE_ENV BUNDLE_FLOW; do
        [ "$(manifest_value "$versions/$target/.platform-bundle" "$key")" = "$(bundle_value "$key")" ] ||
            die "$EXIT_REFUSED" "$versions/$target is a bundle of another $key than $BUNDLE_ROOT: not activated"
    done
    for v in "${candidates[@]}"; do
        if [ "$index" -lt "$keep" ] || [ "$v" = "$target" ] || [ "$v" = "$previous" ]; then kept+=("$v"); else removed+=("$v"); fi
        index=$((index + 1))
    done
    # What survives a version change (ADR-0018): /logs/<user>/<project>/{logs,data} (LOGS_DIR, DATA_DIR), under the
    # root that holds /apps/<user>/versions/<project>/ (/ on a box; a box directory of the local transport in tests).
    user_dir="$(dirname "$(dirname "$versions")")"
    logs_root="$(dirname "$(dirname "$user_dir")")"
    logs_root="${logs_root%/}/logs/$(basename "$user_dir")/$(basename "$versions")"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'run-compose.sh --dry-run: activate (nothing is executed)\n'
        printf '  %-13s %s\n' "versions" "$versions" "activate" "current -> $target (now ${previous:-none})" \
            "logs, data" "$logs_root/{logs,data}" "keep" "${kept[*]}" "remove" "${removed[*]:--}"
        return 0
    fi
    if [ "$target" = "$previous" ]; then
        info "$versions/current already points at $target"
    else
        tmp="$versions/.current.$$"
        if ! ln -sfn "$target" "$tmp" || ! mv -fT "$tmp" "$versions/current"; then
            rm -f "$tmp"
            die "$EXIT_FAILED" "could not point $versions/current at $target"
        fi
        info "$versions/current -> $target (was ${previous:-none})"
    fi
    mkdir -p "$logs_root/logs" "$logs_root/data" 2>/dev/null || warn "could not create $logs_root/{logs,data}"
    for v in ${removed[@]+"${removed[@]}"}; do
        if rm -rf -- "${versions:?}/$v"; then info "removed version $v (keeping the newest $keep)"; else warn "could not remove $versions/$v"; fi
    done
    printf 'activated %s\n' "$target"
}

# --- arguments --------------------------------------------------------------------------------------------

DRY_RUN=0 FORCE=0 JSON=0 NO_WAIT=0 VOLUMES=0 OFFLINE=0 FOLLOW=0
ENGINE_CHOICE="${RUN_COMPOSE_ENGINE:-}" SINCE="" TAIL="" APP_DIR_ARG=""
KEEP="" ACTIVATE_PREVIOUS=0 ACTIVATE_TO=""
POSITIONAL=()
CMD_ARGS=()
OPTS_TEXT=""
AUDIT=1
ENV_NAME="" FLOW="" APP="" INSTANCE="" COMMAND=""

need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }

while [ $# -gt 0 ]; do
    # exec <svc> <cmd...>: once the service is known, everything else belongs to the command.
    if [ "${#POSITIONAL[@]}" -eq 5 ] && [ "${POSITIONAL[4]}" = exec ] && [ "${#CMD_ARGS[@]}" -ge 1 ]; then
        CMD_ARGS+=("$@")
        break
    fi
    case "$1" in
        --dry-run) DRY_RUN=1; OPTS_TEXT="$OPTS_TEXT --dry-run" ;;
        --force) FORCE=1; OPTS_TEXT="$OPTS_TEXT --force" ;;
        --json) JSON=1; OPTS_TEXT="$OPTS_TEXT --json" ;;
        --no-wait) NO_WAIT=1; OPTS_TEXT="$OPTS_TEXT --no-wait" ;;
        --volumes) VOLUMES=1; OPTS_TEXT="$OPTS_TEXT --volumes" ;;
        --offline) OFFLINE=1; OPTS_TEXT="$OPTS_TEXT --offline" ;;
        -q | --quiet) QUIET=1 ;;
        -f | --follow) FOLLOW=1; OPTS_TEXT="$OPTS_TEXT -f" ;;
        --engine) need_value "$@"; ENGINE_CHOICE="$2"; shift ;;
        --engine=*) ENGINE_CHOICE="${1#*=}" ;;
        --since) need_value "$@"; SINCE="$2"; shift ;;
        --since=*) SINCE="${1#*=}" ;;
        --tail) need_value "$@"; TAIL="$2"; shift ;;
        --tail=*) TAIL="${1#*=}" ;;
        --app-dir) need_value "$@"; APP_DIR_ARG="$2"; shift ;;
        --app-dir=*) APP_DIR_ARG="${1#*=}" ;;
        --keep) need_value "$@"; KEEP="$2"; OPTS_TEXT="$OPTS_TEXT --keep $2"; shift ;;
        --keep=*) KEEP="${1#*=}"; OPTS_TEXT="$OPTS_TEXT --keep ${1#*=}" ;;
        --previous) ACTIVATE_PREVIOUS=1; OPTS_TEXT="$OPTS_TEXT --previous" ;;
        --to) need_value "$@"; ACTIVATE_TO="$2"; OPTS_TEXT="$OPTS_TEXT --to $2"; shift ;;
        --to=*) ACTIVATE_TO="${1#*=}"; OPTS_TEXT="$OPTS_TEXT --to ${1#*=}" ;;
        -h | --help) AUDIT=0; usage; exit 0 ;;
        --) shift; CMD_ARGS+=("$@"); break ;;
        -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
        *)
            if [ "${#POSITIONAL[@]}" -lt 5 ]; then POSITIONAL+=("$1"); else CMD_ARGS+=("$1"); fi
            ;;
    esac
    shift
done
[ -n "$ENGINE_CHOICE" ] && OPTS_TEXT="$OPTS_TEXT --engine $ENGINE_CHOICE"

# shellcheck disable=SC2329 # invoked by the EXIT trap below
audit() {
    local result="$1"
    [ "$AUDIT" -eq 1 ] || return 0
    local who line
    who="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo unknown)}}"
    line="ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) who=$who host=$(hostname 2>/dev/null || uname -n)"
    line="$line env=$ENV_NAME flow=$FLOW app=$APP instance=$INSTANCE cmd=$COMMAND opts=\"${OPTS_TEXT# }\" result=$result"
    [ -z "${OVERRIDES:-}" ] || line="$line override=$OVERRIDES"
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        line="$line run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/$GITHUB_RUN_ID actor=${GITHUB_ACTOR:-unknown}"
    fi
    printf 'run-compose audit: %s\n' "$line" >&2
    if command -v logger >/dev/null 2>&1; then logger -t run-compose -- "$line" 2>/dev/null || true; fi
}
trap 'audit "$?"' EXIT

# The host bundle form: `activate` takes no instance (ADR-0018).
if [ "${POSITIONAL[0]:-}" = activate ]; then
    COMMAND=activate
    [ "${#POSITIONAL[@]}" -eq 1 ] && [ "${#CMD_ARGS[@]}" -eq 0 ] ||
        die "$EXIT_USAGE" "activate takes options only: run-compose.sh activate [--keep N] [--previous | --to <version>] [--dry-run]"
    cmd_activate
    exit $?
fi
if [ -n "$KEEP" ] || [ "$ACTIVATE_PREVIOUS" -eq 1 ] || [ -n "$ACTIVATE_TO" ]; then
    die "$EXIT_USAGE" "--keep, --previous and --to only apply to activate (run-compose.sh activate ...)"
fi
if [ "${#POSITIONAL[@]}" -lt 5 ]; then
    usage >&2
    die "$EXIT_USAGE" "expected <env> <flow> <AppName> <AppInstance> <command>, got ${#POSITIONAL[@]} argument(s)"
fi
ENV_NAME="${POSITIONAL[0]}" FLOW="${POSITIONAL[1]}" APP="${POSITIONAL[2]}" INSTANCE="${POSITIONAL[3]}" COMMAND="${POSITIONAL[4]}"

# --- the root and its platform.yml (ADR-0030) -------------------------------------------------------------

BUNDLE_ROOT="$(find_bundle_root "$SCRIPT_DIR" || true)"
if [ -n "$BUNDLE_ROOT" ]; then
    REPO_ROOT="$BUNDLE_ROOT"
else
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd -P))"
fi
PLATFORM_FILE="$REPO_ROOT/platform.yml"
# The words of a one-line list of platform.yml (`<key>: [a, b]` at the top level); read without a YAML parser,
# because the boxes have no yq. Exit 1: no such key; 2: not a one-line list.
platform_list() { # <key>
    awk -v k="$1" '
    index($0, k ":") == 1 {
        v = substr($0, length(k) + 2)
        sub(/#.*$/, "", v)
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (substr(v, 1, 1) != "[" || substr(v, length(v), 1) != "]") { bad = 1; exit }
        v = substr(v, 2, length(v) - 2)
        if (index(v, "[") || index(v, "]")) { bad = 1; exit }
        gsub(/[ \t]/, "", v)
        gsub(/,/, " ", v)
        print v
        found = 1
        exit
    }
    END { if (bad) exit 2; if (!found) exit 1 }' "$PLATFORM_FILE"
}
read_platform_list() { # <key> <variable> [empty-ok]: only dev_envs may be [] (ADR-0035)
    local words
    if ! words="$(platform_list "$1")" || { [ -z "$words" ] && [ "${3:-}" != empty-ok ]; }; then
        die "$EXIT_CONFIG" "$(rel "$PLATFORM_FILE"): $1 must be a one-line list at the top level, e.g. '$1: [a, b]' (ADR-0030)"
    fi
    printf -v "$2" '%s' "$words"
}
[ -f "$PLATFORM_FILE" ] ||
    die "$EXIT_CONFIG" "platform.yml not found in $REPO_ROOT: it declares the regions, stages, flows and dev envs (ADR-0030)"
REGIONS="" STAGES="" FLOWS="" DEV_ENVS=""
read_platform_list regions REGIONS
read_platform_list stages STAGES
read_platform_list flows FLOWS
read_platform_list dev_envs DEV_ENVS empty-ok # [] (ADR-0035): local only

# --- validation: usage (2), safety (3) --------------------------------------------------------------------

contains_word "$COMMAND" "$COMMANDS" || die "$EXIT_USAGE" "unknown command '$COMMAND' (one of: $COMMANDS; activate takes no instance: run-compose.sh activate)"
# local, or <region>-<stage> with a region and a stage of platform.yml (ADR-0003).
if [ "$ENV_NAME" != local ]; then
    region="${ENV_NAME%%-*}" stage="${ENV_NAME#*-}"
    if [ "$region" = "$ENV_NAME" ] || ! contains_word "$region" "$REGIONS" || ! contains_word "$stage" "$STAGES"; then
        die "$EXIT_USAGE" "env '$ENV_NAME' must be local or <region>-<stage> with a region of: $REGIONS and a stage of: $STAGES (platform.yml)"
    fi
fi
contains_word "$FLOW" "$FLOWS" || die "$EXIT_USAGE" "flow '$FLOW' must be one of: $FLOWS (platform.yml)"
is_token() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; }
if ! is_token "$APP" || [ "${#APP}" -gt 20 ]; then
    die "$EXIT_USAGE" "AppName '$APP' must be lower-case kebab-case, at most 20 characters"
fi
if ! is_token "$INSTANCE" || [ "${#INSTANCE}" -gt 32 ]; then
    die "$EXIT_USAGE" "AppInstance '$INSTANCE' must be lower-case kebab-case, at most 32 characters"
fi
case "$INSTANCE" in *[!0-9]*) ;; *) die "$EXIT_USAGE" "AppInstance '$INSTANCE' is a business name, never a bare number" ;; esac
if [ $((${#APP} + 1 + ${#INSTANCE})) -gt 53 ]; then
    die "$EXIT_USAGE" "'$APP-$INSTANCE' exceeds the 53-character release-name budget (ADR-0003)"
fi
case "$ENGINE_CHOICE" in "" | docker | podman) ;; *) die "$EXIT_USAGE" "--engine must be docker or podman" ;; esac
[ "$VOLUMES" -eq 0 ] || [ "$COMMAND" = down ] || die "$EXIT_USAGE" "--volumes only applies to down"
[ "$OFFLINE" -eq 0 ] || [ "$COMMAND" = app-config ] || die "$EXIT_USAGE" "--offline only applies to app-config"
[ "$NO_WAIT" -eq 0 ] || [ "$COMMAND" = start ] || [ "$COMMAND" = restart ] || die "$EXIT_USAGE" "--no-wait only applies to start and restart"
if [ "$FOLLOW" -eq 1 ] || [ -n "$SINCE" ] || [ -n "$TAIL" ]; then
    [ "$COMMAND" = logs ] || die "$EXIT_USAGE" "-f, --since and --tail only apply to logs"
fi
case "$COMMAND" in
    exec) [ "${#CMD_ARGS[@]}" -ge 2 ] || die "$EXIT_USAGE" "usage: ... exec <service> <command...>" ;;
    *) [ "${#CMD_ARGS[@]}" -eq 0 ] || die "$EXIT_USAGE" "unexpected argument(s) for $COMMAND: ${CMD_ARGS[*]}" ;;
esac

# Env allow-list (ADR-0017): local and the dev envs of platform.yml; --force never overrides it.
if [ "$ENV_NAME" != local ] && ! contains_word "$ENV_NAME" "$DEV_ENVS"; then
    [ "${ENV_NAME#*-}" != dev ] ||
        die "$EXIT_REFUSED" "env '$ENV_NAME' refused: it is not a dev env of this repository (platform.yml dev_envs: $DEV_ENVS) (ADR-0004)"
    die "$EXIT_REFUSED" "env '$ENV_NAME' refused: this repository operates local and its dev envs ($DEV_ENVS) only; the promoted envs are deployed from the configuration repository (ADR-0004)"
fi
if [ "$COMMAND" = down ] && [ "$VOLUMES" -eq 1 ] && [ "$ENV_NAME" != local ] && [ "$FORCE" -eq 0 ]; then
    die "$EXIT_REFUSED" "down --volumes on a $ENV_NAME host removes data: add --force to confirm"
fi

# --- path resolution (ADR-0012, ADR-0017) and config-tree checks (4) --------------------------------------

# The app directory adds what one app needs in every env; it is optional (a host bundle carries it only when the app
# ships docker/docker-compose.override.yml or scripts/smoke.sh).
is_app_dir() { [ -f "$1/build.gradle.kts" ] || [ -f "$1/docker/docker-compose.override.yml" ] || [ -f "$1/scripts/smoke.sh" ]; }
if [ -n "$APP_DIR_ARG" ]; then
    [ -d "$APP_DIR_ARG" ] || die "$EXIT_CONFIG" "app directory not found: $APP_DIR_ARG"
    APP_DIR="$(cd "$APP_DIR_ARG" && pwd -P)"
    [ "$(basename "$APP_DIR")" = "$APP" ] ||
        die "$EXIT_USAGE" "this script belongs to $(basename "$APP_DIR"), not to '$APP'"
else
    APP_DIR=""
    # apps/<AppName> (ADR-0006), else any <dir>/<AppName> (a monorepo nesting its apps).
    for candidate in "$REPO_ROOT/apps/$APP" "$REPO_ROOT/$APP" "$REPO_ROOT"/*/"$APP"; do
        if [ -d "$candidate" ] && is_app_dir "$candidate"; then APP_DIR="$candidate"; break; fi
    done
fi
CONFIG_ROOT="${CONFIG_ROOT:-$REPO_ROOT/config}"
# Absolute: compose resolves a relative path against the first compose file's directory (docker/), not this shell's.
[ ! -d "$CONFIG_ROOT" ] || CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd -P)"
ENV_DIR="$CONFIG_ROOT/$ENV_NAME"
FLOW_DIR="$ENV_DIR/$FLOW"
APP_CONFIG_DIR="$FLOW_DIR/$APP"
CONFIG_DIR="$APP_CONFIG_DIR/$INSTANCE"
COMPOSE_TEMPLATE="$REPO_ROOT/docker/docker-compose.yml"
# The env layers, lowest precedence first (the flow is the cluster, ADR-0011; nothing is shared at the env level).
FLOW_ENV="$FLOW_DIR/_docker-compose.flow.env"
APP_LAYER_ENV="$APP_CONFIG_DIR/_docker-compose.app.env"
INSTANCE_ENV="$CONFIG_DIR/_docker-compose.instance.env"
# The Spring layers, one file each (mounted at /config/{flow,common,instance}/application.yml).
FLOW_APP_YML="$FLOW_DIR/application.flow.yml"
APP_APP_YML="$APP_CONFIG_DIR/application.app.yml"
INSTANCE_APP_YML="$CONFIG_DIR/application.instance.yml"
# The generated combined env of the instance (below): outside config/, never committed, one per version on a box.
ENV_FILE="$REPO_ROOT/.run/$ENV_NAME/$FLOW/$APP/$INSTANCE/compose.env"

for dir in "$ENV_DIR" "$FLOW_DIR" "$APP_CONFIG_DIR" "$CONFIG_DIR"; do
    [ -d "$dir" ] || die "$EXIT_CONFIG" "config tree: directory missing: $(rel "$dir")"
done
# A tree in the layout before ADR-0011 says so instead of "file missing".
for old in "$APP_CONFIG_DIR/app-common" "$FLOW_DIR/_common" "$CONFIG_DIR/compose.env"; do
    [ ! -e "$old" ] || die "$EXIT_CONFIG" "config tree: $(rel "$old") is the layout before ADR-0011: the layers are files now" \
        "(application.<layer>.yml, _docker-compose.<layer>.env / .yml, _helm-values.<layer>.yaml; config/README.md)"
done
for file in "$APP_APP_YML" "$INSTANCE_APP_YML" "$INSTANCE_ENV" "$COMPOSE_TEMPLATE"; do
    [ -f "$file" ] || die "$EXIT_CONFIG" "config tree: required file missing: $(rel "$file")"
done

# The compose files, in merge order: the shared template, then every override that exists. compose_text: their
# content without comment lines, for the variable scans below.
COMPOSE_FILES=("$COMPOSE_TEMPLATE")
OVERRIDE_FILES=()
for file in ${APP_DIR:+"$APP_DIR/docker/docker-compose.override.yml"} "$FLOW_DIR/_docker-compose.flow.yml" \
    "$APP_CONFIG_DIR/_docker-compose.app.yml" "$CONFIG_DIR/_docker-compose.instance.yml"; do
    if [ -f "$file" ]; then COMPOSE_FILES+=("$file") OVERRIDE_FILES+=("$file"); fi
done
compose_text() { cat "${COMPOSE_FILES[@]}" | grep -v '^[[:space:]]*#'; }
ENV_LAYERS=()
for file in "$FLOW_ENV" "$APP_LAYER_ENV" "$INSTANCE_ENV"; do [ ! -f "$file" ] || ENV_LAYERS+=("$file"); done

# Every env layer: KEY=VALUE lines only, allowed variables only (ADR-0012), the instance-only ones in the instance
# layer only; the instance layer restates the identity of its path (ADR-0014 check 4). A key defined twice in one layer is
# config-lint's (check 5): record-tag repairs a duplicate IMAGE_TAG on a box, the first line wins.
layer_value() { awk -v k="$2" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }' "$1"; }
problems=""
check_env_layer() { # <file> <instance: 1|0>
    local raw line key
    while IFS= read -r raw || [ -n "$raw" ]; do
        line="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$line" in "" | "#"*) continue ;; esac
        key="${line%%=*}"
        if [ "$key" = "$line" ] || ! printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
            problems="$problems\n  $(rel "$1"): not KEY=VALUE: $line"
            continue
        fi
        case "$key" in
            SPRING_* | LOGGING_* | MANAGEMENT_* | CONNECTOR_*) problems="$problems\n  $(rel "$1"): $key is forbidden (YAML or shell pass-through, ADR-0012)" ;;
            *_HOST_PORT) [ "$2" -eq 1 ] || problems="$problems\n  $(rel "$1"): $key belongs in the instance layer only (_docker-compose.instance.env)" ;;
            *)
                if contains_word "$key" "$SCRIPT_VARIABLES"; then
                    problems="$problems\n  $(rel "$1"): $key is set by run-compose.sh, never in an env layer"
                elif ! contains_word "$key" "$COMPOSE_ENV_ALLOWED"; then
                    problems="$problems\n  $(rel "$1"): $key is not an allowed compose variable (ADR-0012)"
                elif [ "$2" -eq 0 ] && contains_word "$key" "$INSTANCE_ONLY"; then
                    problems="$problems\n  $(rel "$1"): $key belongs in the instance layer only (_docker-compose.instance.env)"
                fi
                ;;
        esac
    done <"$1"
}
[ ! -f "$FLOW_ENV" ] || check_env_layer "$FLOW_ENV" 0
[ ! -f "$APP_LAYER_ENV" ] || check_env_layer "$APP_LAYER_ENV" 0
check_env_layer "$INSTANCE_ENV" 1
for pair in "APP_ENV=$ENV_NAME" "APP_FLOW=$FLOW" "APP_NAME=$APP" "APP_INSTANCE=$INSTANCE"; do
    key="${pair%%=*}"
    actual="$(layer_value "$INSTANCE_ENV" "$key")"
    [ "$actual" = "${pair#*=}" ] || problems="$problems\n  $(rel "$INSTANCE_ENV"): $key='$actual' must restate the path ('${pair#*=}')"
done
if [ -n "$problems" ]; then
    printf 'run-compose: error: config tree:%b\n' "$problems" >&2
    exit "$EXIT_CONFIG"
fi

# The combined env (ADR-0012): the layers merged per key, the later one winning, written as only the winning lines,
# each after a comment naming its source and what it overrode. Regenerated by every command — it can never be
# stale — into a temporary file renamed over the old one. podman-compose keeps only the last of several --env-file
# flags, so one generated file is passed instead; it is also what `printenv` shows.
write_combined_env() { # <label=file>... (lowest precedence first)
    local tmp arg map=""
    local files=()
    for arg in "$@"; do
        files+=("${arg#*=}")
        map="$map${arg#*=}"$'\034'"${arg%%=*}"$'\034'
    done
    mkdir -p "$(dirname "$ENV_FILE")" || die "$EXIT_FAILED" "cannot create $(rel "$(dirname "$ENV_FILE")")"
    tmp="$(mktemp "$(dirname "$ENV_FILE")/.compose.env.XXXXXX")" || die "$EXIT_FAILED" "cannot write in $(rel "$(dirname "$ENV_FILE")")"
    # Layers are named by file (FILENAME), so an empty layer cannot shift the names of the ones after it.
    if ! awk -v map="$map" -v created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -v identity="$ENV_NAME/$FLOW/$APP/$INSTANCE" '
        BEGIN { n = split(map, m, "\034"); for (i = 1; i + 1 <= n; i += 2) label[m[i]] = m[i + 1] }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            key = substr(line, 1, index(line, "=") - 1)
            value = substr(line, index(line, "=") + 1)
            if (!(key in source)) order[++keys] = key
            else overridden[key] = label[source[key]] ": " val[key] (overridden[key] == "" ? "" : ", " overridden[key])
            source[key] = FILENAME; val[key] = value
        }
        END {
            print "# GENERATED by run-compose.sh at " created " — do not edit; edit the layers named below."
            print "# " identity
            for (i = 1; i <= keys; i++) {
                k = order[i]
                print ""
                print "# from " label[source[k]] (overridden[k] == "" ? "" : " (overrides " overridden[k] ")")
                print k "=" val[k]
            }
        }' "${files[@]}" >"$tmp" || ! mv -f "$tmp" "$ENV_FILE"; then
        rm -f "$tmp"
        die "$EXIT_FAILED" "could not write $(rel "$ENV_FILE")"
    fi
}
LAYER_ARGS=()
for file in "${ENV_LAYERS[@]}"; do LAYER_ARGS+=("$(rel "$file")=$file"); done
write_combined_env "${LAYER_ARGS[@]}"
env_value() { layer_value "$ENV_FILE" "$1"; }
ENV_KEYS="$(awk -F= '$0 !~ /^[[:space:]]*(#|$)/ { printf " %s", $1 }' "$ENV_FILE")"

# --- environment for the template (ADR-0012, ADR-0017) ----------------------------------------------------

PROJECT="$ENV_NAME-$FLOW-$APP-$INSTANCE"
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    export CI_RUN_ID="${CI_RUN_ID:-$GITHUB_RUN_ID}" CI_RUN_ATTEMPT="${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
    # CI test stacks (env local) get the run-scoped prefix that ADR-0024's teardown and leak check match; a *-dev
    # host keeps its stable name so that a redeploy replaces the stack instead of starting a second one.
    [ "$ENV_NAME" = local ] && PROJECT="ci-$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}-$PROJECT"
fi
# The env layers are the default for every variable they define; only IMAGE_REPO and IMAGE_TAG may be overridden
# from this shell, in every allowed env (deploy-dev injects IMAGE_TAG for pull / start / health, then record-tag
# writes it into the box's _docker-compose.instance.env; git keeps the declared tag, ADR-0027). Overrides are
# announced, recorded in the audit line and written into the combined env as its last layer. APP_IMAGE is local only.
OVERRIDES=""
for key in $ENV_KEYS; do
    case "$key" in IMAGE_REPO | IMAGE_TAG) ;; *) unset "$key" 2>/dev/null || true ;; esac
done
[ "$ENV_NAME" = local ] || unset APP_IMAGE
RECORD_TAG="${IMAGE_TAG:-}" # record-tag's value, also when it equals the env layers (then unset below)
for key in IMAGE_REPO IMAGE_TAG; do
    value="${!key:-}"
    if [ -n "$value" ] && [ "$value" != "$(env_value "$key")" ]; then
        case "$key" in
            IMAGE_TAG) pattern="$IMAGE_TAG_PATTERN" ;;
            *) pattern='^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$' ;;
        esac
        # [[ =~ ]] matches the whole value (grep would accept a value with one valid line among several).
        [[ $value =~ $pattern ]] || die "$EXIT_USAGE" "$key='$value' is not a valid override"
        info "$key=$value from the environment overrides the env layers ($(env_value "$key"))"
        OVERRIDES="$OVERRIDES,$key"
        export "${key?}"
    else
        unset "$key"
    fi
done
OVERRIDES="${OVERRIDES#,}"
if [ -n "$OVERRIDES" ]; then
    SHELL_LAYER="$(dirname "$ENV_FILE")/.shell.env"
    for key in IMAGE_REPO IMAGE_TAG; do [ -z "${!key:-}" ] || printf '%s=%s\n' "$key" "${!key}"; done >"$SHELL_LAYER"
    write_combined_env "${LAYER_ARGS[@]}" "the shell (IMAGE_TAG / IMAGE_REPO only)=$SHELL_LAYER"
    rm -f "$SHELL_LAYER"
fi
# record-tag changes a host bundle's copy of the instance layer only: in a checkout, it changes through git (a pull
# request — no workflow writes to main, ADR-0020); a box's version directory is never synced again, so the record stays
# with the version it belongs to (ADR-0018).
if [ "$COMMAND" = record-tag ]; then
    [ -n "$BUNDLE_ROOT" ] || die "$EXIT_REFUSED" "record-tag writes the _docker-compose.instance.env of a host bundle (a box" \
        "synced by scripts/pool-deploy.sh) only; in a checkout it changes through git"
    # The physical directory: neither `..` in CONFIG_ROOT nor a symlink may lead the write out of the bundle.
    case "$(cd "$CONFIG_DIR" && pwd -P)/" in
        "$BUNDLE_ROOT"/*) ;;
        *) die "$EXIT_REFUSED" "record-tag writes this bundle's own _docker-compose.instance.env only, and $(rel "$CONFIG_DIR") lies outside it" ;;
    esac
    [ -n "$RECORD_TAG" ] || die "$EXIT_USAGE" "record-tag needs IMAGE_TAG=<tag> in its environment: the tag start and health just ran"
    [[ $RECORD_TAG =~ $IMAGE_TAG_PATTERN ]] || die "$EXIT_USAGE" "IMAGE_TAG='$RECORD_TAG' is not a valid image tag"
    case ",$OVERRIDES," in
        *,IMAGE_REPO,*) die "$EXIT_USAGE" "record-tag records IMAGE_TAG only: run it without the IMAGE_REPO override" ;;
    esac
fi
export APP_ENV="$ENV_NAME" APP_FLOW="$FLOW" APP_NAME="$APP" APP_INSTANCE="$INSTANCE"
export COMPOSE_ENV_FILE="$ENV_FILE" APP_APP_YML INSTANCE_APP_YML PROJECT
if [ -f "$FLOW_APP_YML" ]; then export FLOW_APP_YML; else unset FLOW_APP_YML; fi
# The instance's host directories (ADR-0018): LOGS_DIR and DATA_DIR of the env layers name the flow's directories,
# and each instance mounts its own <dir>/<AppName>/<AppInstance>, so two instances on a box never share a file.
# Unset, the template mounts volumes of the compose project instead.
unset INSTANCE_LOGS_DIR INSTANCE_DATA_DIR
for key in LOGS_DIR DATA_DIR; do
    value="$(env_value "$key")"
    [ -n "$value" ] || continue
    case "$value" in
        /*) ;;
        *) die "$EXIT_CONFIG" "$key='$value' in the env layers must be an absolute host path (ADR-0018)" ;;
    esac
    printf -v "INSTANCE_$key" '%s' "${value%/}/$APP/$INSTANCE"
    export "INSTANCE_$key"
done
# DEPS_NETWORK joins a running dependency stack's network: a generated override (literal values — podman-compose
# reads an interpolated `external: false` as true), merged last.
if [ -n "${DEPS_NETWORK:-}" ]; then
    printf '%s' "$DEPS_NETWORK" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || die "$EXIT_USAGE" "DEPS_NETWORK='$DEPS_NETWORK' is not a network name"
    DEPS_OVERRIDE="$(dirname "$ENV_FILE")/deps-network.yml"
    printf '# GENERATED by run-compose.sh: DEPS_NETWORK=%s\nnetworks:\n  default:\n    name: %s\n    external: true\n' \
        "$DEPS_NETWORK" "$DEPS_NETWORK" >"$DEPS_OVERRIDE"
    COMPOSE_FILES+=("$DEPS_OVERRIDE")
else
    rm -f "$(dirname "$ENV_FILE")/deps-network.yml"
fi
unset DEPS_NETWORK_EXTERNAL
SELINUX_LABEL_SHARED="" SELINUX_LABEL_PRIVATE=""
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    SELINUX_LABEL_SHARED=",z" SELINUX_LABEL_PRIVATE=",Z"
fi
export SELINUX_LABEL_SHARED SELINUX_LABEL_PRIVATE
START_TIMEOUT="${START_TIMEOUT:-180}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
IMAGE_REF="${IMAGE_REPO:-$(env_value IMAGE_REPO)}/$APP:${IMAGE_TAG:-$(env_value IMAGE_TAG)}"
[ -z "${APP_IMAGE:-}" ] || IMAGE_REF="$APP_IMAGE"
ACTUATOR_PORT="$(env_value ACTUATOR_HOST_PORT)"

# Required template variables (${VAR:?...}) that nobody provides: the pass-through secrets (ADR-0013).
missing_required() {
    local var out=""
    # shellcheck disable=SC2013 # variable names never contain whitespace
    for var in $(compose_text | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?\?' | sed -e 's/^\${//' -e 's/:*?$//' | sort -u); do
        if [ -z "${!var:-}" ] && ! contains_word "$var" "$ENV_KEYS"; then out="$out $var"; fi
    done
    printf '%s' "${out# }"
}
MISSING="$(missing_required)"
case "$COMMAND" in
    start | restart | validate) NEEDS_SECRETS=1 ;;
    app-config) NEEDS_SECRETS="$OFFLINE" ;;
    *) NEEDS_SECRETS=0 ;;
esac
if [ -n "$MISSING" ]; then
    if [ "$NEEDS_SECRETS" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        die "$EXIT_FAILED" "set $MISSING in this shell first (secrets pass through, never from an env layer — ADR-0013)"
    fi
    # ps, logs, stop, down, pull ... never use the values: placeholders keep the template interpolating.
    for var in $MISSING; do export "$var=unset-for-$COMMAND"; done
    [ "$DRY_RUN" -eq 0 ] || info "not set in this shell: $MISSING (start, restart, validate and app-config --offline need them)"
fi

# --- pool guard (ADR-0017, ADR-0028): one running copy of an instance across the boxes of its pool --------

POOL_PEERS=()   # the other boxes of the pool when the guard applies
POOL_SSH_ARGS=()
POOL_GUARD_NOTE="" # why the guard does not apply to this start / restart (shown by --dry-run)
setup_pool_guard() {
    local hosts=() host self short matches=() user root
    case "$COMMAND" in start | restart) ;; *) return 0 ;; esac
    [ -n "$BUNDLE_ROOT" ] && [ "$ENV_NAME" != local ] || return 0
    [ "$(bundle_value BUNDLE_ENV)" = "$ENV_NAME" ] && [ "$(bundle_value BUNDLE_FLOW)" = "$FLOW" ] || return 0
    read -r -a hosts <<<"$(bundle_value POOL_HOSTS)"
    [ "${#hosts[@]}" -gt 1 ] || return 0
    user="$(bundle_value POOL_USER)"
    root="$(bundle_value POOL_ROOT)"
    for host in "${hosts[@]}"; do
        printf '%s' "$host" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' ||
            die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_HOSTS entry '$host' is not a host name"
    done
    printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' ||
        die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_USER '$user' is not a login name"
    printf '%s' "$root" | grep -Eq '^(/[A-Za-z0-9._-]+)+/?$' ||
        die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_ROOT '$root' is not an absolute path"
    if [ "${POOL_PEER_CHECK:-on}" = off ]; then
        POOL_GUARD_NOTE="off (POOL_PEER_CHECK=off)"
        return 0
    fi
    if [ "$FORCE" -eq 1 ]; then
        POOL_GUARD_NOTE="skipped (--force)"
        return 0
    fi
    # This box: POOL_SELF_HOST as given, else its FQDN — or the one pool host whose first label is its short name.
    self="${POOL_SELF_HOST:-}"
    if [ -z "$self" ]; then
        self="$(hostname -f 2>/dev/null || true)"
        [ -n "$self" ] || self="$(hostname 2>/dev/null || uname -n)"
        self="$(printf '%s' "$self" | tr '[:upper:]' '[:lower:]')"
        if ! contains_word "$self" "${hosts[*]}"; then
            short="${self%%.*}"
            for host in "${hosts[@]}"; do [ "${host%%.*}" != "$short" ] || matches+=("$host"); done
            [ "${#matches[@]}" -ne 1 ] || self="${matches[0]}"
        fi
    fi
    contains_word "$self" "${hosts[*]}" ||
        warn "this machine ($self) is not one of POOL_HOSTS: asking every box of the pool (set POOL_SELF_HOST to its name there)"
    for host in "${hosts[@]}"; do [ "$host" = "$self" ] || POOL_PEERS+=("$host"); done
    if [ -n "${POOL_SSH_OPTS:-}" ]; then
        read -r -a POOL_SSH_ARGS <<<"$POOL_SSH_OPTS"
    else
        # Never trust an unknown host key: the reviewed known_hosts of the env when the bundle carries it, else
        # the deploy user's own.
        POOL_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
        [ ! -f "$ENV_DIR/known_hosts" ] || POOL_SSH_ARGS+=(-o "UserKnownHostsFile=$ENV_DIR/known_hosts")
    fi
    POOL_USER_NAME="$user" POOL_ROOT_DIR="${root%/}"
}
# The peer's copy of this command — the run-compose.sh of its current version under the pool's root (ADR-0018) — as an
# argument vector.
PEER_CMD=()
peer_command() {
    local remote
    remote="$(printf '%q ' "$POOL_ROOT_DIR/current/scripts/run-compose.sh" "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" status --json)"
    PEER_CMD=("${POOL_SSH:-ssh}" "${POOL_SSH_ARGS[@]+"${POOL_SSH_ARGS[@]}"}" "$POOL_USER_NAME@$1" -- "${remote% }")
}
# For --dry-run: a command line as it would be typed (arguments with spaces in single quotes).
quote_words() {
    local out="" word sq="'"
    for word in "$@"; do
        case "$word" in *[!A-Za-z0-9_./:=@,+-]*) word="$sq${word//$sq/$sq\\$sq$sq}$sq" ;; esac
        out="$out $word"
    done
    printf '%s' "${out# }"
}
run_pool_guard() {
    local peer out rc running last
    [ "${#POOL_PEERS[@]}" -gt 0 ] && [ "$DRY_RUN" -eq 0 ] || return 0
    if ! command -v "${POOL_SSH:-ssh}" >/dev/null 2>&1; then
        warn "pool guard: ${POOL_SSH:-ssh} not found, so the other boxes (${POOL_PEERS[*]}) cannot be asked; continuing"
        return 0
    fi
    for peer in "${POOL_PEERS[@]}"; do
        peer_command "$peer"
        rc=0
        if command -v timeout >/dev/null 2>&1; then
            out="$(timeout 60 "${PEER_CMD[@]}" 2>&1 </dev/null)" || rc=$?
        else
            out="$("${PEER_CMD[@]}" 2>&1 </dev/null)" || rc=$?
        fi
        running="$(printf '%s\n' "$out" | grep '^{' | tail -n 1 | sed -nE 's/.*"running":(true|false).*/\1/p' || true)"
        case "$running" in
            true) die "$EXIT_REFUSED" "$INSTANCE is already running on $peer; stop it there first, or --force" ;;
            false) info "pool guard: $INSTANCE is not running on $peer" ;;
            *)
                last="$(printf '%s\n' "$out" | grep -v -e '^{' -e '^[[:space:]]*$' | tail -n 1 || true)"
                warn "pool guard: could not ask $peer whether $INSTANCE runs there (exit $rc${last:+: $last}); continuing — a box that does not answer must not block a failover"
                ;;
        esac
    done
}
POOL_USER_NAME="" POOL_ROOT_DIR=""
setup_pool_guard
run_pool_guard

# --- engine (ADR-0017) ------------------------------------------------------------------------------------

ENGINE="" COMPOSE_KIND=""
COMPOSE=()
detect_engine() {
    if { [ -z "$ENGINE_CHOICE" ] || [ "$ENGINE_CHOICE" = docker ]; } &&
        command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ENGINE=docker COMPOSE_KIND=plugin
        COMPOSE=(docker compose)
        return 0
    fi
    if [ -z "$ENGINE_CHOICE" ] || [ "$ENGINE_CHOICE" = podman ]; then
        if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
            ENGINE=podman COMPOSE_KIND=plugin
            COMPOSE=(podman compose)
            # `podman compose` runs an external provider; podman-compose (python) has no `up --wait`.
            # (Captured first: with pipefail, `| grep -q` would fail on podman's SIGPIPE.)
            case "$(podman compose version 2>&1)" in *podman-compose*) COMPOSE_KIND=python ;; esac
            return 0
        fi
        if command -v podman-compose >/dev/null 2>&1; then
            ENGINE=podman COMPOSE_KIND=python
            COMPOSE=(podman-compose)
            return 0
        fi
    fi
    return 1
}
case "$COMMAND" in
    printenv) NEEDS_CLI=0 NEEDS_DAEMON=0 ;;
    config) NEEDS_CLI=1 NEEDS_DAEMON=0 ;;
    validate | record-tag | compose-env) NEEDS_CLI=0 NEEDS_DAEMON=0 ;;
    app-config) NEEDS_CLI="$OFFLINE" NEEDS_DAEMON="$OFFLINE" ;;
    *) NEEDS_CLI=1 NEEDS_DAEMON=1 ;;
esac
if ! detect_engine; then
    if [ "$DRY_RUN" -eq 1 ] || [ "$NEEDS_CLI" -eq 0 ]; then
        ENGINE="${ENGINE_CHOICE:-docker}" COMPOSE_KIND=none
        COMPOSE=("$ENGINE" compose)
        [ "$NEEDS_CLI" -eq 0 ] || warn "no compose CLI found (docker compose, podman compose, podman-compose); showing '${COMPOSE[*]}'"
    else
        die "$EXIT_ENGINE" "no compose CLI found: install Docker with the compose plugin, or Podman with podman compose / podman-compose"
    fi
fi
if [ "$ENGINE" = podman ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
    export DOCKER_HOST="${DOCKER_HOST:-unix://$XDG_RUNTIME_DIR/podman/podman.sock}"
fi
if [ "$NEEDS_DAEMON" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && ! "$ENGINE" info >/dev/null 2>&1; then
    if [ "$ENGINE" = podman ]; then
        die "$EXIT_ENGINE" "podman is not usable: try 'systemctl --user start podman.socket' (rootless) or 'podman machine start'"
    fi
    die "$EXIT_ENGINE" "the Docker daemon is not running or not reachable (docker info failed)"
fi

# --- execution helpers ------------------------------------------------------------------------------------

# -p, --env-file and one -f per compose file, in merge order (the shared template first).
COMPOSE_ARGS=(-p "$PROJECT" --env-file "$ENV_FILE")
for file in "${COMPOSE_FILES[@]}"; do COMPOSE_ARGS+=(-f "$file"); done
compose_line() { printf '%s %s' "${COMPOSE[*]}" "${COMPOSE_ARGS[*]}"; }
# Every file or layer of a list, relative and space-separated ("-" when there is none).
rel_list() {
    local out="" f
    for f in "$@"; do out="$out $(rel "$f")"; done
    printf '%s' "${out# }"
}
show_plan() {
    [ "$DRY_RUN" -eq 1 ] || return 0
    printf 'run-compose.sh --dry-run: %s %s %s %s %s (nothing is executed)\n' "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" "$COMMAND"
    printf '  %-13s %s\n' "repo root" "$REPO_ROOT" "app dir" "$(rel "$APP_DIR")" "config root" "$(rel "$CONFIG_ROOT")" \
        "config dir" "$(rel "$CONFIG_DIR")" "compose files" "$(rel_list "${COMPOSE_FILES[@]}")" \
        "env layers" "$(rel_list "${ENV_LAYERS[@]}")" "combined env" "$(rel "$ENV_FILE")" \
        "spring layers" "$(rel_list ${FLOW_APP_YML:+"$FLOW_APP_YML"} "$APP_APP_YML" "$INSTANCE_APP_YML")" "project" "$PROJECT" \
        "identity" "APP_ENV=$APP_ENV APP_FLOW=$APP_FLOW APP_NAME=$APP_NAME APP_INSTANCE=$APP_INSTANCE" \
        "image" "$IMAGE_REF" "engine" "$ENGINE (${COMPOSE[*]})" "deps network" "${DEPS_NETWORK:--}" \
        "logs, data" "${INSTANCE_LOGS_DIR:-volume logs}, ${INSTANCE_DATA_DIR:-volume data}"
    if [ -n "$BUNDLE_ROOT" ]; then
        printf '  %-13s %s %s/%s version %s, tag %s, %s files, sha256 %.12s…, pool %s\n' "host bundle" \
            "$(bundle_value BUNDLE_PROJECT)" "$(bundle_value BUNDLE_ENV)" "$(bundle_value BUNDLE_FLOW)" "$(basename "$BUNDLE_ROOT")" \
            "$(bundle_value BUNDLE_TAG)" "$(bundle_value BUNDLE_FILES)" "$(bundle_value BUNDLE_SHA256)" "$(bundle_value POOL_HOSTS)"
    fi
    if [ -n "$POOL_GUARD_NOTE" ]; then
        printf '  %-13s %s\n' "peer check" "$POOL_GUARD_NOTE"
    else
        local peer
        for peer in ${POOL_PEERS[@]+"${POOL_PEERS[@]}"}; do
            peer_command "$peer"
            printf '  %-13s %s\n' "peer check" "$(quote_words "${PEER_CMD[@]}")"
        done
    fi
}
# Runs (or, with --dry-run, prints) one compose command; returns its exit code.
compose() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %-13s %s %s\n' "command" "$(compose_line)" "$*"
        return 0
    fi
    info "$(compose_line) $*"
    "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" "$@"
}
plan_step() { [ "$DRY_RUN" -eq 0 ] || printf '  %-13s %s\n' "then" "$*"; }
readiness_url() { printf 'http://127.0.0.1:%s/actuator/health/readiness' "$ACTUATOR_PORT"; }
# The app's container, found through the compose labels both docker compose and podman-compose set (podman-compose's
# `ps` takes no service argument).
APP_FILTERS=(--filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE")
app_container() { "$ENGINE" ps -q "${APP_FILTERS[@]}" 2>/dev/null | head -n 1; }
http_get() { curl -fsS --max-time 5 "$1"; }

wait_ready() {
    # podman-compose (python) has no `up --wait`: poll the readiness probe instead.
    local deadline=$(($(date +%s) + START_TIMEOUT))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if http_get "$(readiness_url)" >/dev/null 2>&1; then return 0; fi
        sleep 3
    done
    return "$EXIT_TIMEOUT"
}

# The instance's host directories (ADR-0018), before its container starts: an engine would create a missing one as
# root (docker) or refuse it (podman). The deploy user creates them and opens them to the image's non-root user,
# whose uid differs from the deploy user's. A directory that cannot be prepared is a warning: the app still logs to
# stdout, and the engine reports a mount it cannot make.
prepare_host_dirs() {
    local dir
    for dir in ${INSTANCE_LOGS_DIR:+"$INSTANCE_LOGS_DIR"} ${INSTANCE_DATA_DIR:+"$INSTANCE_DATA_DIR"}; do
        if [ "$DRY_RUN" -eq 1 ]; then
            plan_step "mkdir -p $dir && chmod 0777 $dir"
        elif ! { mkdir -p "$dir" && chmod 0777 "$dir"; } 2>/dev/null; then
            warn "could not prepare $dir (ADR-0018): create it writable for the image's user (uid 10001)"
        fi
    done
}

cmd_start() {
    local rc=0 started
    prepare_host_dirs
    started="$(date +%s)"
    if [ "$NO_WAIT" -eq 1 ]; then
        compose up -d || rc=$?
    elif [ "$COMPOSE_KIND" = python ]; then
        compose up -d || rc=$?
        plan_step "poll $(readiness_url) for up to ${START_TIMEOUT}s"
        if [ "$rc" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then wait_ready || rc=$?; fi
    else
        compose up -d --wait --wait-timeout "$START_TIMEOUT" || rc=$?
        if [ "$rc" -ne 0 ] && [ $(($(date +%s) - started)) -ge "$START_TIMEOUT" ]; then rc="$EXIT_TIMEOUT"; fi
    fi
    if [ "$rc" -ne 0 ]; then
        warn "start failed (exit $rc); last log lines:"
        "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" logs --tail 50 >&2 2>&1 || true
        [ "$rc" -eq "$EXIT_TIMEOUT" ] && return "$EXIT_TIMEOUT"
        return "$EXIT_FAILED"
    fi
    [ "$DRY_RUN" -eq 1 ] || info "$PROJECT is up$([ "$NO_WAIT" -eq 1 ] && echo ' (not waiting for health)' || echo ' and healthy')"
}

# The smoke test of this app (ADR-0017): the app's own scripts/smoke.sh when it ships one (app-specific checks,
# ADR-0006), else the platform's scripts/smoke.sh beside this script with --app-dir; empty when neither exists.
SMOKE_CMD=()
smoke_command() {
    SMOKE_CMD=()
    if [ -n "$APP_DIR" ] && [ -x "$APP_DIR/scripts/smoke.sh" ]; then
        SMOKE_CMD=("$APP_DIR/scripts/smoke.sh")
    elif [ -x "$SCRIPT_DIR/smoke.sh" ]; then
        SMOKE_CMD=("$SCRIPT_DIR/smoke.sh")
    fi
}
cmd_health() {
    local cid="" body="" status="DOWN" running=false rc=0
    smoke_command
    if [ "$DRY_RUN" -eq 1 ]; then
        plan_step "$ENGINE ps -q $(quote_words "${APP_FILTERS[@]}")"
        plan_step "curl -fsS $(readiness_url)"
        [ "${#SMOKE_CMD[@]}" -eq 0 ] || plan_step "$(rel "${SMOKE_CMD[0]}") $ENV_NAME $FLOW $APP $INSTANCE"
        return 0
    fi
    cid="$(app_container)"
    if [ -n "$cid" ]; then
        running=true
        if body="$(http_get "$(readiness_url)" 2>/dev/null)" && printf '%s' "$body" | grep -q '"status":"UP"'; then
            status=UP
        fi
    fi
    if [ "$status" = UP ] && [ "${#SMOKE_CMD[@]}" -gt 0 ]; then
        CONFIG_ROOT="$CONFIG_ROOT" ACTUATOR_HOST_PORT="$ACTUATOR_PORT" "${SMOKE_CMD[@]}" "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" >&2 ||
            { status=SMOKE_FAILED; rc="$EXIT_FAILED"; }
    fi
    [ "$status" = UP ] || rc="$EXIT_FAILED"
    if [ "$JSON" -eq 1 ]; then
        printf '{"project":%s,"running":%s,"readiness":%s,"url":%s}\n' "$(json_str "$PROJECT")" "$running" \
            "$(json_str "$status")" "$(json_str "$(readiness_url)")"
    else
        printf '%s: %s (container %s)\n' "$PROJECT" "$status" "$([ "$running" = true ] && echo running || echo 'not running')"
    fi
    return "$rc"
}

cmd_status() {
    local cid running_ref="" running_id="" desired_id="" drift=false rc=0
    compose ps
    if [ "$DRY_RUN" -eq 1 ]; then
        plan_step "$ENGINE inspect <app container>  vs  $ENGINE image inspect $IMAGE_REF"
        return 0
    fi
    cid="$(app_container)"
    if [ -z "$cid" ]; then
        rc="$EXIT_FAILED"
        drift=unknown
    else
        running_ref="$("$ENGINE" inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
        running_id="$("$ENGINE" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
        desired_id="$("$ENGINE" image inspect --format '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)"
        if [ "$running_ref" != "$IMAGE_REF" ] || [ -z "$desired_id" ] || [ "$running_id" != "$desired_id" ]; then
            drift=true
            rc="$EXIT_FAILED"
        fi
    fi
    if [ "$JSON" -eq 1 ]; then
        printf '{"project":%s,"running":%s,"desired":%s,"runningImage":%s,"runningId":%s,"desiredId":%s,"drift":%s,"bundleRoot":%s}\n' \
            "$(json_str "$PROJECT")" "$([ -n "$cid" ] && echo true || echo false)" "$(json_str "$IMAGE_REF")" \
            "$(json_str "$running_ref")" "$(json_str "$running_id")" "$(json_str "$desired_id")" "$(json_str "$drift")" \
            "$(json_str "$BUNDLE_ROOT")"
    else
        printf 'desired %s; running %s; drift: %s\n' "$IMAGE_REF" "${running_ref:-(not running)}" "$drift"
    fi
    return "$rc"
}

image_label() { "$ENGINE" image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }

cmd_version() {
    local cid image_id image digest
    if [ "$DRY_RUN" -eq 1 ]; then
        plan_step "$ENGINE ps -q $(quote_words "${APP_FILTERS[@]}")"
        plan_step "$ENGINE inspect <app container>; $ENGINE image inspect <image> (tag, digest, OCI labels)"
        return 0
    fi
    cid="$(app_container)"
    [ -n "$cid" ] || { warn "$PROJECT is not running"; return "$EXIT_FAILED"; }
    image="$("$ENGINE" inspect --format '{{.Config.Image}}' "$cid")"
    image_id="$("$ENGINE" inspect --format '{{.Image}}' "$cid")"
    digest="$("$ENGINE" image inspect --format '{{join .RepoDigests ","}}' "$image_id" 2>/dev/null || true)"
    if [ "$JSON" -eq 1 ]; then
        printf '{"image":%s,"digest":%s,"version":%s,"revision":%s,"source":%s,"created":%s,"buildUrl":%s}\n' \
            "$(json_str "$image")" "$(json_str "$digest")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.version)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.revision)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.source)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.created)")" \
            "$(json_str "$(image_label "$image_id" com.example.build-url)")"
    else
        printf 'image     %s\ndigest    %s\nversion   %s\nrevision  %s\nsource    %s\ncreated   %s\nbuild-url %s\n' \
            "$image" "$digest" "$(image_label "$image_id" org.opencontainers.image.version)" \
            "$(image_label "$image_id" org.opencontainers.image.revision)" \
            "$(image_label "$image_id" org.opencontainers.image.source)" \
            "$(image_label "$image_id" org.opencontainers.image.created)" \
            "$(image_label "$image_id" com.example.build-url)"
    fi
}

cmd_printenv() {
    {
        printf 'REPO_ROOT=%s\nAPP_DIR=%s\nCONFIG_ROOT=%s\nCONFIG_DIR=%s\n' "$REPO_ROOT" "$APP_DIR" "$CONFIG_ROOT" "$CONFIG_DIR"
        printf 'COMPOSE_FILES=%s\nENV_LAYERS=%s\nCOMPOSE_ENV_FILE=%s\nPROJECT=%s\nENGINE=%s\nCOMPOSE=%s\n' \
            "${COMPOSE_FILES[*]}" "${ENV_LAYERS[*]}" "$ENV_FILE" "$PROJECT" "$ENGINE" "${COMPOSE[*]}"
        printf 'FLOW_APP_YML=%s\nAPP_APP_YML=%s\nINSTANCE_APP_YML=%s\n' "${FLOW_APP_YML:-}" "$APP_APP_YML" "$INSTANCE_APP_YML"
        printf 'INSTANCE_LOGS_DIR=%s\nINSTANCE_DATA_DIR=%s\n' "${INSTANCE_LOGS_DIR:-}" "${INSTANCE_DATA_DIR:-}"
        printf 'APP_ENV=%s\nAPP_FLOW=%s\nAPP_NAME=%s\nAPP_INSTANCE=%s\nDEPS_NETWORK=%s\nSELINUX_LABEL_SHARED=%s\n' \
            "$APP_ENV" "$APP_FLOW" "$APP_NAME" "$APP_INSTANCE" "${DEPS_NETWORK:-}" "$SELINUX_LABEL_SHARED"
        printf '\n# ---- the combined env (%s) ----\n' "$(rel "$ENV_FILE")"
        cat "$ENV_FILE"
        printf '\n# ---- passed through from this shell ----\n'
        # shellcheck disable=SC2013 # variable names never contain whitespace
        for var in $(compose_text | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?\?' | sed -e 's/^\${//' -e 's/:*?$//' | sort -u); do
            if ! contains_word "$var" "$ENV_KEYS" && ! contains_word "$var" "$SCRIPT_VARIABLES APP_ENV APP_FLOW APP_NAME APP_INSTANCE"; then
                if contains_word "$var" "$MISSING"; then printf '%s=<unset>\n' "$var"; else printf '%s=%s\n' "$var" "${!var}"; fi
            fi
        done
    } | mask_stream
}

cmd_validate() {
    local rc=0 var used
    # Every ${VAR} of the compose files is defined by the combined env, the identity / script set, or this shell.
    used="$(compose_text | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${//' | sort -u)"
    for var in $used; do
        if ! contains_word "$var" "$ENV_KEYS" && [ -z "${!var+set}" ] &&
            ! compose_text | grep -Eq "\\$\\{$var:?-"; then
            warn "template variable $var has no value and no default"
            rc="$EXIT_FAILED"
        fi
    done
    # Compose resolves a relative path of any -f file against the first file's directory (docker/), not the
    # override's own: overrides use ${VAR} paths only.
    local file hits
    for file in ${OVERRIDE_FILES[@]+"${OVERRIDE_FILES[@]}"}; do
        hits="$(grep -nE '^[^#]*([[:space:]:"'\''=-]|^)\.\.?/' "$file" || true)"
        if [ -n "$hits" ]; then
            warn "$(rel "$file"): a relative path resolves against docker/, not this file's directory; use a \${VAR} path: $(printf '%s' "$hits" | head -n 3 | tr '\n' ' ')"
            rc="$EXIT_FAILED"
        fi
    done
    if [ "$COMPOSE_KIND" = none ]; then
        warn "no compose CLI: skipped the 'config --quiet' lint"
    else
        compose config --quiet || rc="$EXIT_FAILED"
    fi
    [ "$rc" -ne 0 ] || [ "$DRY_RUN" -eq 1 ] || info "$ENV_NAME/$FLOW/$APP/$INSTANCE is valid ($(rel "$CONFIG_DIR"))"
    return "$rc"
}

# IMAGE_TAG=<tag> as the one IMAGE_TAG line of the instance layer: the first one replaced in place, later ones dropped,
# appended when there is none, every other line kept. Written to a copy next to it (same mode) that is renamed over
# it, so the box never holds a half-written file; unchanged when it already says so. The next command regenerates
# the combined env from it.
cmd_record_tag() {
    local previous tmp
    previous="$(layer_value "$INSTANCE_ENV" IMAGE_TAG)"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %-13s %s\n' "write" "IMAGE_TAG=$RECORD_TAG into $(rel "$INSTANCE_ENV") (now ${previous:-without IMAGE_TAG})"
        return 0
    fi
    tmp="$(mktemp "$CONFIG_DIR/.${INSTANCE_ENV##*/}.XXXXXX")" || { warn "cannot create a file in $(rel "$CONFIG_DIR")"; return "$EXIT_FAILED"; }
    if ! cp -p "$INSTANCE_ENV" "$tmp" || ! awk -v tag="$RECORD_TAG" '
        { line = $0; sub(/^[[:space:]]+/, "", line) }
        index(line, "IMAGE_TAG=") == 1 { if (!done) print "IMAGE_TAG=" tag; done = 1; next }
        { print }
        END { if (!done) print "IMAGE_TAG=" tag }' "$INSTANCE_ENV" >"$tmp"; then
        rm -f "$tmp"
        warn "could not write a new $(rel "$INSTANCE_ENV")"
        return "$EXIT_FAILED"
    fi
    if cmp -s "$tmp" "$INSTANCE_ENV"; then
        rm -f "$tmp"
        info "$(rel "$INSTANCE_ENV") already records IMAGE_TAG=$RECORD_TAG"
        return 0
    fi
    if ! mv -f "$tmp" "$INSTANCE_ENV"; then
        rm -f "$tmp"
        warn "could not replace $(rel "$INSTANCE_ENV")"
        return "$EXIT_FAILED"
    fi
    info "IMAGE_TAG=$RECORD_TAG recorded in $(rel "$INSTANCE_ENV") (was ${previous:-unset}); this version directory keeps it (ADR-0018)"
}

cmd_app_config() {
    if [ "$OFFLINE" -eq 1 ]; then
        compose run --rm --no-deps -T "$SERVICE" --print-config | mask_stream
        return "${PIPESTATUS[0]}"
    fi
    local url="http://127.0.0.1:$ACTUATOR_PORT/actuator/connectorconfig"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %-13s curl -fsS %s\n' "command" "$url"
        return 0
    fi
    http_get "$url" | mask_stream || { warn "$url did not answer: is the stack up? (or use --offline)"; return "$EXIT_FAILED"; }
    printf '\n'
}

# --- dispatch (ADR-0017) ----------------------------------------------------------------------------------

show_plan
rc=0
case "$COMMAND" in
    start) cmd_start || rc=$? ;;
    stop) compose stop -t "$STOP_TIMEOUT" || rc="$EXIT_FAILED" ;;
    down)
        if [ "$VOLUMES" -eq 1 ]; then compose down --remove-orphans -v || rc="$EXIT_FAILED"; else compose down --remove-orphans || rc="$EXIT_FAILED"; fi
        ;;
    restart)
        compose stop -t "$STOP_TIMEOUT" || rc="$EXIT_FAILED"
        if [ "$rc" -eq 0 ]; then cmd_start || rc=$?; fi
        ;;
    config)
        if [ "$DRY_RUN" -eq 1 ]; then compose config; else compose config | mask_stream || rc="$EXIT_FAILED"; fi
        ;;
    app-config) cmd_app_config || rc=$? ;;
    printenv) if [ "$DRY_RUN" -eq 1 ]; then plan_step "print the resolved environment"; else cmd_printenv; fi ;;
    compose-env) printf '%s\n' "$ENV_FILE" ;;
    health) cmd_health || rc=$? ;;
    status | ps) cmd_status || rc=$? ;;
    logs)
        args=(logs)
        [ "$FOLLOW" -eq 1 ] && args+=(-f)
        [ -n "$SINCE" ] && args+=(--since "$SINCE")
        [ -n "$TAIL" ] && args+=(--tail "$TAIL")
        compose "${args[@]}" || rc="$EXIT_FAILED"
        ;;
    pull) compose pull || rc="$EXIT_FAILED" ;;
    validate) cmd_validate || rc=$? ;;
    record-tag) cmd_record_tag || rc=$? ;;
    exec)
        tty_flag=()
        [ -t 0 ] || tty_flag=(-T)
        compose exec "${tty_flag[@]+"${tty_flag[@]}"}" "${CMD_ARGS[@]}" || rc=$?
        ;;
    shell)
        tty_flag=()
        [ -t 0 ] || tty_flag=(-T)
        compose exec "${tty_flag[@]+"${tty_flag[@]}"}" "$SERVICE" sh || rc=$?
        ;;
    version) cmd_version || rc=$? ;;
esac
exit "$rc"
