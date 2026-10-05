#!/usr/bin/env bash
# pool-deploy-test.sh — script tests of the host pools (DL-39, DL-41, DL-46; D6 §6.8): scripts/pool-deploy.sh, the
# versioned layout /apps/<user>/versions/<project>/<version>/ with `current`, `activate`, the .platform-bundle root,
# the pool guard and record-tag of scripts/run-compose.sh. Plain bash: stub ssh and rsync (POOL_SSH / POOL_RSYNC)
# and a stub docker and curl (PATH) record their arguments and answer from STUB_* variables, so nothing reaches a
# host, a registry or an engine.
#
# Usage: scripts/test/pool-deploy-test.sh [<case>...]     every case by default; the pr.yml lint job runs it.
# Needs bash 4+, mikefarah yq v4, jq, rsync and git; a docker compose CLI is optional (validate skips its lint).
# Exit codes: 0 every case passed · 1 a case failed · 2 usage or a missing tool.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO POOL_DEPLOY="$REPO/scripts/pool-deploy.sh"
readonly H1=dev-cash-01.us-dev.example.com H2=dev-cash-02.us-dev.example.com
readonly TRADES=cash/source-database/trades-db-to-amps POSITIONS=cash/source-database/positions-db-to-deephaven
# The layout of a box (DL-41, DL-46): the project's versions under the deploy user's directory, `current` the live one.
readonly PROJECT=github-cicd-simple-apps ROOT=/apps/deploy/versions/github-cicd-simple-apps
readonly V0=20261004-110000 V1=20261004-120000 V2=20261004-130000 V3=20261004-140000 V4=20261004-150000
# The commands a box runs: the new version's run-compose.sh (a deploy) and the current one's (discovery, rollback).
readonly NEW="$ROOT/$V1/scripts/run-compose.sh" CUR="$ROOT/current/scripts/run-compose.sh"
readonly CASES="bundle activate plan_assigns plan_pinned discovered two_boxes move versions_local dry_run health_fails
    record_tag record_first known_hosts refusals guard ssh_deploy rollback_ssh local_execute"

for tool in yq jq rsync git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "pool-deploy-test: $tool is needed" >&2; exit 2; }
done
yq --version 2>/dev/null | grep -q mikefarah || { echo "pool-deploy-test: mikefarah yq v4 is needed" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi
# Only what each case sets: nothing from the caller's shell steers the scripts under test.
unset CONFIG_ROOT POOL_TRANSPORT POOL_LOCAL_ROOT POOL_LOCAL_EXECUTE POOL_SSH POOL_RSYNC POOL_SSH_OPTS POOL_PEER_CHECK \
    POOL_SELF_HOST POOL_VERSION IMAGE_TAG IMAGE_REPO APP_IMAGE STUB_RUNNING STUB_FAIL STUB_UNREACHABLE STUB_NO_CURRENT \
    STUB_CURRENT STUB_RSYNC_CHANGES STUB_RSYNC_FAIL STUB_HEALTHY STUB_INSTANCE

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-deploy-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK STUB="$WORK/stub" DOCKER_BIN="$WORK/docker-bin"
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "$STUB" "$DOCKER_BIN"

cat >"$STUB/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: logs "ssh <args>"; the remote line is [IMAGE_TAG=<tag>] <dir>/scripts/run-compose.sh <env> <flow> <app>
# <inst> <command> [args], or <dir>/scripts/run-compose.sh activate [args]. Answers status --json with running true
# for the "<host>:<AppInstance>" pairs in STUB_RUNNING (the current version STUB_CURRENT, default 20261004-110000);
# activate prints "activated <version>" (the directory's, or the --to one, or STUB_CURRENT's predecessor for
# --previous); fails the "<host>:<command>" pairs in STUB_FAIL; with STUB_NO_CURRENT set a command through
# .../current/ fails as a missing script does (127); plays dead (exit 255, as ssh does) for STUB_UNREACHABLE hosts.
printf 'ssh %s\n' "$*" >>"$STUB_LOG"
target="" remote=""
while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then remote="$2"; break; fi
    target="$1"
    shift
done
host="${target#*@}"
case " ${STUB_UNREACHABLE:-} " in *" $host "*) echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255 ;; esac
read -r -a words <<<"$remote"
[[ ${words[0]:-} != IMAGE_TAG=* ]] || words=("${words[@]:1}")
script="${words[0]:-}"
dir="${script%/scripts/run-compose.sh}"
if [ -n "${STUB_NO_CURRENT:-}" ] && [[ $dir == */current ]]; then
    echo "bash: $script: No such file or directory" >&2
    exit 127
fi
current="${STUB_CURRENT:-20261004-110000}"
if [ "${words[1]:-}" = activate ]; then
    case " ${STUB_FAIL:-} " in *" $host:activate "*) echo "stub: activate failed on $host" >&2; exit 1 ;; esac
    version="${dir##*/}"
    [ "$version" != current ] || version="$current"
    for ((i = 2; i < ${#words[@]}; i++)); do
        case "${words[i]}" in
            --to) version="${words[i + 1]}" ;;
            --previous) version="$(printf '%08d-%06d' "${current%%-*}" "$((10#${current##*-} - 10000))")" ;;
        esac
    done
    echo "activated $version"
    exit 0
fi
inst="${words[4]:-}" cmd="${words[5]:-}"
case " ${STUB_FAIL:-} " in *" $host:$cmd "*) echo "stub: $cmd of $inst failed on $host" >&2; exit 1 ;; esac
if [ "$cmd" = status ]; then
    running=false image=""
    case " ${STUB_RUNNING:-} " in *" $host:$inst "*) running=true image="ghcr.io/o/r/source-database:t0" ;; esac
    echo "NAME    IMAGE    SERVICE    STATUS"
    printf '{"project":"us-dev-cash-source-database-%s","running":%s,"desired":"ghcr.io/o/r/source-database:1","runningImage":"%s","runningId":"","desiredId":"","drift":"false","bundleRoot":"%s"}\n' \
        "$inst" "$running" "$image" "/apps/deploy/versions/github-cicd-simple-apps/$current"
    [ "$running" = true ] || exit 1
fi
exit 0
EOF
cat >"$STUB/rsync" <<'EOF'
#!/usr/bin/env bash
# Stub rsync (ssh transport): logs "rsync <args>"; a --dry-run pass (the verification) prints STUB_RSYNC_CHANGES;
# the transfer to the host in STUB_RSYNC_FAIL fails as a dead box would.
printf 'rsync %s\n' "$*" >>"$STUB_LOG"
dest="${!#}"
case " $* " in *" --dry-run "*) printf '%b' "${STUB_RSYNC_CHANGES:-}"; exit 0 ;; esac
if [ -n "${STUB_RSYNC_FAIL:-}" ] && [[ $dest == *"@$STUB_RSYNC_FAIL:"* ]]; then
    echo "rsync: connection unexpectedly closed" >&2
    exit 12
fi
exit 0
EOF
cat >"$DOCKER_BIN/docker" <<'EOF'
#!/usr/bin/env bash
# Stub docker for run-compose.sh: a compose CLI and a daemon that accept everything. With STUB_HEALTHY set,
# `ps -q --filter label=...` (run-compose.sh finds the app's container by its compose labels) names a container, so
# health goes on to ask the actuator (the stub curl).
printf 'docker %s\n' "$*" >>"$STUB_LOG"
if [ "${1:-}" = compose ] && [ "${2:-}" = version ]; then echo "Docker Compose version v2.99.0-stub"; fi
if [ -n "${STUB_HEALTHY:-}" ] && [ "${1:-}" = ps ] && [[ " $* " == *" -q "* ]]; then echo 0123456789ab; fi
exit 0
EOF
cat >"$DOCKER_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl for run-compose.sh health and smoke.sh: with STUB_HEALTHY set, the actuator of a ready instance
# (readiness UP, the identity of STUB_INSTANCE, default trades-db-to-amps); otherwise nothing listens.
printf 'curl %s\n' "$*" >>"$STUB_LOG"
[ -n "${STUB_HEALTHY:-}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
case "${!#}" in
    */actuator/health/readiness) echo '{"status":"UP"}' ;;
    */actuator/info)
        printf '{"connector":{"env":"us-dev","flow":"cash","app":"source-database","instance":"%s"}}\n' \
            "${STUB_INSTANCE:-trades-db-to-amps}" ;;
    *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
EOF
chmod +x "$STUB/ssh" "$STUB/rsync" "$DOCKER_BIN/docker" "$DOCKER_BIN/curl"

# --- helpers ----------------------------------------------------------------------------------------------

CASE_FAILED=0 RC=0 OUT="" ERR=""
fail() {
    printf '    %s\n' "$*"
    CASE_FAILED=1
}
# run <command...>: stdout in OUT, stderr in ERR, exit code in RC.
run() {
    RC=0
    "$@" >"$WORK/stdout" 2>"$WORK/stderr" || RC=$?
    OUT="$(cat "$WORK/stdout")" ERR="$(cat "$WORK/stderr")"
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "exit $RC, expected $1; stderr: $(tail -n 4 <<<"$ERR" | tr '\n' ' ')"; }
expect_in() { [[ $2 == *"$1"* ]] || fail "missing '$1' in: $(head -c 900 <<<"$2")"; }
expect_not_in() { [[ $2 != *"$1"* ]] || fail "unexpected '$1' in: $(head -c 900 <<<"$2")"; }
expect_json() { # <json> <jq filter> <expected>
    local actual
    actual="$(jq -r "$2" <<<"$1" 2>&1)" || actual="(jq failed: $actual)"
    [ "$actual" = "$3" ] || fail "jq '$2' is '$actual', expected '$3'"
}
line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d : -f 1; }
in_order() { # <log> <needle>...: every needle appears, each after the previous one
    local log="$1" previous=0 line needle
    shift
    for needle in "$@"; do
        line="$(line_of "$needle" "$log")"
        if [ -z "$line" ]; then fail "missing '$needle' in $(basename "$log")"; return; fi
        if [ "$line" -le "$previous" ]; then fail "'$needle' (line $line) does not follow the previous command (line $previous)"; return; fi
        previous="$line"
    done
}
in_dir() { # <dir> <command...>: the command, run from <dir>
    local dir="$1"
    shift
    (cd "$dir" && "$@")
}
# copy_config <dest>: a copy of config/ without the pins (the `host` of every target of a pooled flow), so each
# case starts from an unplaced inventory whatever the tree declares. Flows without a pool keep their hosts: there
# a compose target needs one.
copy_config() {
    local f
    cp -R "$REPO/config" "$1"
    for f in "$1"/*/*/workflows-config.yml; do
        [ -f "$f" ] || continue
        yq -i 'with(select(.pool != null); del(.targets[].host))' "$f"
    done
}
# fixture <name> [yq expression for us-dev/cash/workflows-config.yml]: a copy of config/, printed as a CONFIG_ROOT.
fixture() {
    mkdir -p "$WORK/$1"
    copy_config "$WORK/$1/config"
    [ -z "${2:-}" ] || yq -i "$2" "$WORK/$1/config/us-dev/cash/workflows-config.yml"
    printf '%s' "$WORK/$1/config"
}
known_hosts() { # the reviewed host keys the ssh transport requires (a test key, public)
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' "$H1" "$H2" >"$1/us-dev/known_hosts"
}
bundle() { # <config root> <out>: a verified bundle of us-dev/cash
    CONFIG_ROOT="$1" "$POOL_DEPLOY" us-dev cash bundle --out "$2" --tag t1 >/dev/null 2>"$WORK/bundle.err" ||
        { fail "bundle failed: $(tail -n 3 "$WORK/bundle.err")"; return 1; }
}
# The instance layer (what record-tag writes) and the combined env run-compose.sh generates (R-0008) in a version.
box_env() { printf '%s/%s%s/%s/config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env' "$1" "$2" "$ROOT" "$3"; } # <boxes> <host> <version>
box_combined() { printf '%s/%s%s/%s/.run/us-dev/cash/source-database/trades-db-to-amps/compose.env' "$1" "$2" "$ROOT" "$3"; } # <boxes> <host> <version>

# --- cases (DL-39 contract §4; DL-41 decisions 2, 3, 5; DL-46) ----------------------------------------------

case_bundle() { # the layout and manifest for us-dev/cash; every instance validates from the bundle alone
    local b="$WORK/bundle/out" m f n sha checkout inst
    run "$POOL_DEPLOY" us-dev cash bundle --out "$b" --tag t1
    expect_rc 0
    m="$b/.platform-bundle"
    for f in .platform-bundle scripts/run-compose.sh scripts/smoke.sh docker/docker-compose.yml \
        apps/source-database/docker/docker-compose.override.yml config/us-dev/cash/application.flow.yml \
        config/us-dev/cash/_docker-compose.flow.env config/us-dev/cash/workflows-config.yml \
        config/us-dev/cash/source-database/application.app.yml config/us-dev/cash/source-database/_docker-compose.app.env \
        config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env \
        config/us-dev/cash/source-database/positions-db-to-deephaven/application.instance.yml; do
        [ -f "$b/$f" ] || fail "the bundle lacks $f"
    done
    # One compose template for every app (R-0008) and no per-app wrapper (D12 §6.2): apps/source-database/ holds only
    # its compose override; no platform layer (DL-45); no combined env (.run/ is written on the box).
    for f in config/us-dev/workflows-config.yml config/us-dev/_common config/_common config/local apps/source-amps apps/source-kafka \
        apps/source-database/src apps/source-database/build apps/source-database/scripts \
        apps/source-database/docker/docker-compose.yml .run scripts/ci scripts/test .git; do
        [ ! -e "$b/$f" ] || fail "the bundle holds $f"
    done
    [ -x "$b/scripts/run-compose.sh" ] && [ -x "$b/scripts/smoke.sh" ] || fail "the bundle's scripts are not executable"
    [ "$OUT" = "$(cat "$m")" ] || fail "bundle does not print its manifest"
    # Shell-sourceable, so a box needs no yq; the manifest names the project and the versions root (DL-46).
    (
        set +u
        # shellcheck disable=SC1090 # the manifest under test
        . "$m"
        [ "$BUNDLE_PROJECT/$BUNDLE_ENV/$BUNDLE_FLOW/$BUNDLE_TAG" = "$PROJECT/us-dev/cash/t1" ] && [ "$POOL_HOSTS" = "$H1 $H2" ] &&
            [ "$POOL_USER" = deploy ] && [ "$POOL_ROOT" = "$ROOT" ] && [ "$POOL_KEEP" = 5 ]
    ) || fail "the marker does not source to $PROJECT us-dev/cash/t1, the pool and $ROOT: $(tr '\n' ' ' <"$m")"
    grep -Eq '^BUNDLE_CREATED=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$m" || fail "BUNDLE_CREATED is not UTC"
    grep -Eq '^BUNDLE_GIT_SHA=([0-9a-f]{40}(-dirty)?|unknown)$' "$m" || fail "BUNDLE_GIT_SHA is malformed"
    n="$(cd "$b" && find . -type f ! -path ./.platform-bundle ! -path './.run/*' | wc -l | tr -d ' ')"
    grep -qx "BUNDLE_FILES=$n" "$m" || fail "BUNDLE_FILES is not $n"
    # The documented recipe: sha256 of the sorted "<sha256>  <path>" lines of every other file but .run/.
    sha="$(cd "$b" && find . -type f ! -path ./.platform-bundle ! -path './.run/*' -print0 | LC_ALL=C sort -z | xargs -0 "${SHA256[@]}" |
        sed 's|  \./|  |' | "${SHA256[@]}" | cut -d ' ' -f 1)"
    grep -qx "BUNDLE_SHA256=$sha" "$m" || fail "BUNDLE_SHA256 is not the recipe's $sha"
    # Any instance of the flow can run on any box: both validate from the bundle, outside any checkout.
    for inst in trades-db-to-amps positions-db-to-deephaven; do
        run in_dir / env -u GITHUB_RUN_ID SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
            "$b/scripts/run-compose.sh" us-dev cash source-database "$inst" validate
        expect_rc 0
    done
    # The marker wins over an enclosing git checkout.
    checkout="$WORK/bundle/checkout"
    mkdir -p "$checkout"
    git -C "$checkout" init -q
    cp -R "$b" "$checkout/platform"
    run "$checkout/platform/scripts/run-compose.sh" us-dev cash source-database trades-db-to-amps printenv
    expect_rc 0
    expect_in "REPO_ROOT=$checkout/platform"$'\n' "$OUT"
    expect_in "CONFIG_ROOT=$checkout/platform/config"$'\n' "$OUT"
    # A second build replaces a previous bundle; a directory that is not one is refused.
    run "$POOL_DEPLOY" us-dev cash bundle --out "$b"
    expect_rc 0
    grep -qx 'BUNDLE_TAG=' "$m" || fail "a bundle without --tag has an empty BUNDLE_TAG"
    run "$POOL_DEPLOY" us-dev cash bundle --out "$checkout"
    expect_rc 2
}

case_activate() { # run-compose.sh activate: current -> this version, atomically; --previous / --to; keep N (DL-41, DL-46)
    local b="$WORK/activate/bundle" box="$WORK/activate/box" vroot v rc_cur
    vroot="$box$ROOT"
    bundle "$REPO/config" "$b" || return 0
    # Only a version directory of a host bundle activates: not a checkout, not a bundle elsewhere.
    run "$REPO/scripts/run-compose.sh" activate
    expect_rc 3
    expect_in "this is a checkout" "$ERR"
    run "$b/scripts/run-compose.sh" activate
    expect_rc 4
    expect_in "is not a version directory" "$ERR"
    for v in "$V1" "$V2" "$V3"; do mkdir -p "$vroot" && cp -R "$b" "$vroot/$v"; done
    # --dry-run shows the switch and touches nothing.
    run "$vroot/$V1/scripts/run-compose.sh" activate --dry-run
    expect_rc 0
    expect_in "activate      current -> $V1 (now none)" "$OUT"
    expect_in "keep          $V3 $V2 $V1" "$OUT"
    [ ! -e "$vroot/current" ] || fail "a dry run created current"
    run "$vroot/$V1/scripts/run-compose.sh" activate
    expect_rc 0
    [ "$OUT" = "activated $V1" ] || fail "stdout is '$OUT', expected 'activated $V1'"
    [ "$(readlink "$vroot/current")" = "$V1" ] || fail "current -> $(readlink "$vroot/current" || echo none), expected $V1"
    [ -d "$box/apps/deploy/shared/$PROJECT/logs" ] && [ -d "$box/apps/deploy/shared/$PROJECT/data" ] ||
        fail "shared/$PROJECT/{logs,data} were not created beside versions/"
    expect_in 'cmd=activate opts="" result=0' "$ERR"
    # The same again is a no-op; a newer version replaces it; an instance command never activates.
    run "$vroot/$V1/scripts/run-compose.sh" activate
    expect_rc 0
    expect_in "already points at $V1" "$ERR"
    run "$vroot/$V2/scripts/run-compose.sh" activate
    expect_rc 0
    [ "$(readlink "$vroot/current")" = "$V2" ] || fail "current did not move to $V2"
    [ -d "$vroot/$V1" ] || fail "the previous version was removed"
    run "$vroot/current/scripts/run-compose.sh" us-dev cash source-database trades-db-to-amps activate
    expect_rc 2
    expect_in "activate takes no instance" "$ERR"
    run "$vroot/current/scripts/run-compose.sh" us-dev cash source-database trades-db-to-amps printenv --keep 3
    expect_rc 2
    expect_in "only apply to activate" "$ERR"
    # Rollback through current: --previous goes to the newest older version, --to names one; nothing older: 4.
    run "$vroot/current/scripts/run-compose.sh" activate --previous
    expect_rc 0
    [ "$OUT" = "activated $V1" ] && [ "$(readlink "$vroot/current")" = "$V1" ] || fail "--previous did not go back to $V1: '$OUT'"
    run "$vroot/current/scripts/run-compose.sh" activate --previous
    expect_rc 4
    expect_in "no version older than $V1" "$ERR"
    run "$vroot/current/scripts/run-compose.sh" activate --to "$V3"
    expect_rc 0
    [ "$(readlink "$vroot/current")" = "$V3" ] || fail "--to did not switch to $V3"
    run "$vroot/current/scripts/run-compose.sh" activate --to 20200101-000000
    expect_rc 4
    run "$vroot/current/scripts/run-compose.sh" activate --to not-a-version
    expect_rc 2
    run "$vroot/current/scripts/run-compose.sh" activate --previous --to "$V1"
    expect_rc 2
    run "$vroot/$V1/scripts/run-compose.sh" activate --keep 1
    expect_rc 2
    expect_in "--keep must be an integer of at least 2" "$ERR"
    # Another cluster's bundle is never activated by mistake.
    cp -R "$b" "$vroot/$V4"
    sed -i 's/^BUNDLE_FLOW=cash$/BUNDLE_FLOW=deriv/' "$vroot/$V4/.platform-bundle"
    run "$vroot/current/scripts/run-compose.sh" activate --to "$V4"
    expect_rc 3
    expect_in "another BUNDLE_FLOW" "$ERR"
    [ "$(readlink "$vroot/current")" = "$V3" ] || fail "a refused activate moved current"
    rm -rf -- "${vroot:?}/${V4:?}"
    # keep: the newest N stay, plus the target and the version it replaced (a rollback stays possible).
    run "$vroot/$V2/scripts/run-compose.sh" activate --keep 2
    expect_rc 0
    rc_cur="$(readlink "$vroot/current")"
    [ "$rc_cur" = "$V2" ] || fail "current -> $rc_cur, expected $V2"
    [ -d "$vroot/$V3" ] || fail "the replaced version $V3 was removed"
    [ ! -d "$vroot/$V1" ] || fail "$V1 was kept beyond --keep 2 (not current, not the one before)"
    expect_in "removed version $V1" "$ERR"
}

case_plan_assigns() { # two unplaced instances spread over the two boxes, the same way every time
    local cfg first
    cfg="$(fixture plan-assigns '.targets[].kind = "compose"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    expect_rc 0
    first="$OUT"
    expect_json "$OUT" '[.placements[] | "\(.instance)@\(.host)=\(.how)"] | join(" ")' "$TRADES@$H1=assigned $POSITIONS@$H2=assigned"
    expect_json "$OUT" '"\(.project)|\(.pool.hosts | join(" "))|\(.pool.user)|\(.pool.root)|\(.pool.keep)"' "$PROJECT|$H1 $H2|deploy|$ROOT|5"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    [ "$OUT" = "$first" ] || fail "a second plan differs from the first"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --transport dry-run
    expect_rc 0
    expect_in "$TRADES" "$OUT"
    expect_in "assigned" "$OUT"
    expect_in "versions $ROOT, keep 5" "$OUT"
}

case_plan_pinned() { # a pinned host is kept, and counted before the assignments
    local cfg
    cfg="$(fixture plan-pinned '.targets[].kind = "compose" | (.targets[] | select(.instance == "source-database/positions-db-to-deephaven")).host = "'"$H1"'"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --json --transport dry-run
    expect_rc 0
    expect_json "$OUT" '[.placements[] | "\(.instance)@\(.host)=\(.how)"] | join(" ")' "$TRADES@$H2=assigned $POSITIONS@$H1=pinned"
}

case_discovered() { # a box that already runs the instance keeps it; discovery and status ask through current
    local cfg log="$WORK/discovered.log"
    cfg="$(fixture discovered)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash plan --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.placements[0] | "\(.instance) \(.host) \(.how)"' "$TRADES $H2 discovered"
    expect_in "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps status --json" "$(cat "$log")"
    expect_in "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$cfg/us-dev/known_hosts deploy@$H2 --" "$(cat "$log")"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash discover --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.[0] | "\(.instance) \(.running | join(","))"' "$TRADES $H2"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" STUB_CURRENT="$V1" \
        "$POOL_DEPLOY" us-dev cash status --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '[.[] | "\(.host)=\(.status.running)/\(.version)"] | join(" ")' "$H1=false/$V1 $H2=true/$V1"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" STUB_CURRENT="$V1" \
        "$POOL_DEPLOY" us-dev cash status --transport ssh
    expect_rc 0
    expect_in "CURRENT" "$OUT"
    expect_in "$V1" "$OUT"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_UNREACHABLE="$H1" \
        "$POOL_DEPLOY" us-dev cash status --transport ssh
    expect_rc 1
    expect_in "unreachable" "$OUT"
}

case_two_boxes() { # an instance running on two boxes stops everything (6), before any change
    local cfg log="$WORK/two-boxes.log"
    cfg="$(fixture two-boxes)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash plan --transport ssh
    expect_rc 6
    expect_in "running on more than one box: $H1 $H2" "$ERR"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash discover --transport ssh
    expect_rc 6
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        STUB_RUNNING="$H1:trades-db-to-amps $H2:trades-db-to-amps" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh
    expect_rc 6
    expect_not_in "deployed" "$OUT"
    expect_not_in " pull" "$(cat "$log")"
    expect_not_in "activate" "$(cat "$log")"
}

case_move() { # pinned to box 1 but running on box 2: 6, or with --move stop there, then deploy on box 1
    local cfg log="$WORK/move.log"
    cfg="$(fixture move '(.targets[] | select(.instance == "source-database/trades-db-to-amps")).host = "'"$H1"'"')"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh
    expect_rc 6
    expect_in "pinned to $H1 but running on $H2" "$ERR"
    expect_not_in " stop" "$(cat "$log")"
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --move
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    # The tag is recorded in the new version on both boxes, the old copy stopped on box 2, then box 1 pulls and starts.
    in_order "$log" "deploy@$H1 -- IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag" \
        "deploy@$H2 -- $NEW us-dev cash source-database trades-db-to-amps stop" \
        "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps pull" \
        "deploy@$H1 -- $NEW activate --keep 5"
}

case_versions_local() { # the local transport: every box gets the same complete tree as a new version; current is untouched
    local cfg b="$WORK/versions-local/bundle" boxes="$WORK/versions-local/boxes" one two stamped
    cfg="$(fixture versions-local)"
    bundle "$cfg" "$b" || return 0
    one="$boxes/$H1$ROOT" two="$boxes/$H2$ROOT"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --version "$V1" --transport local --local-root "$boxes"
    expect_rc 0
    diff -r "$one/$V1" "$two/$V1" >/dev/null || fail "the two boxes differ: $(diff -r "$one/$V1" "$two/$V1" | head -n 5)"
    diff -r "$b" "$one/$V1" >/dev/null || fail "box 1 differs from the bundle"
    [ ! -e "$one/current" ] || fail "sync created current (only activate does)"
    expect_in "version $V1 synced and verified" "$ERR"
    expect_in "current is unchanged" "$ERR"
    # Another version beside it; without --version the directory is named after the moment (UTC).
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --version "$V2" --transport local --local-root "$boxes"
    expect_rc 0
    [ -d "$one/$V1" ] && [ -d "$one/$V2" ] || fail "the first version did not survive the second sync"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    stamped="$(find "$one" -mindepth 1 -maxdepth 1 -type d ! -name "$V1" ! -name "$V2" -printf '%f\n')"
    [[ $stamped =~ ^[0-9]{8}-[0-9]{6}$ ]] || fail "the default version is not <YYYYMMDD-HHMMSS>: '$stamped'"
    # A changed bundle is refused rather than synced; a bad version name is a usage error.
    echo tampered >>"$b/config/us-dev/cash/workflows-config.yml"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --version "$V3" --transport local --local-root "$boxes"
    expect_rc 4
    expect_in "changed since it was built" "$ERR"
    [ ! -e "$one/$V3" ] || fail "a refused bundle was synced"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash sync --bundle "$b" --version 2026-10-04 --transport local --local-root "$boxes"
    expect_rc 2
    expect_in "is not <YYYYMMDD-HHMMSS>" "$ERR"
}

case_dry_run() { # dry-run prints the sync into the version directory, record-tag on every box, pull / start / health, activate; deploys nothing
    local cfg cmd
    cfg="$(fixture dry-run)"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --dry-run
    expect_rc 0
    [ -z "$OUT" ] || fail "a dry run reports '$OUT' on stdout"
    expect_in "rsync -az --delete --exclude=/.run/ -e 'ssh -o BatchMode=yes" "$ERR"
    expect_in "/ deploy@$H1:$ROOT/$V1/" "$ERR"
    expect_in "deploy@$H1 -- 'IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag'" "$ERR"
    expect_in "deploy@$H2 -- 'IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag'" "$ERR"
    for cmd in pull start health; do
        expect_in "deploy@$H1 -- '$NEW us-dev cash source-database trades-db-to-amps $cmd'" "$ERR"
    done
    expect_not_in "IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps start" "$ERR"
    expect_not_in "deploy@$H2 -- '$NEW us-dev cash source-database trades-db-to-amps start'" "$ERR"
    expect_in "deploy@$H1 -- '$NEW activate --keep 5'" "$ERR"
    expect_in "deploy@$H2 -- '$NEW activate --keep 5'" "$ERR"
    expect_in "known_hosts is missing: the ssh transport would refuse" "$ERR"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash rollback --dry-run
    expect_rc 0
    expect_in "deploy@$H1 -- '$CUR activate --previous --keep 5'" "$ERR"
    [ -z "$OUT" ] || fail "a dry-run rollback reports '$OUT' on stdout"
}

case_health_fails() { # a failed health check sends every started instance back to current; current never moves (DL-41)
    local cfg log="$WORK/health-fails.log" report="$WORK/health-fails.json"
    cfg="$(fixture health-fails '.targets[].kind = "compose"')"
    known_hosts "$cfg"
    # trades (box 1) fails health, positions (box 2) passed: both go back to current, nothing is activated.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H1:health" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    in_order "$log" "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps health" \
        "deploy@$H2 -- $NEW us-dev cash source-database positions-db-to-deephaven health" \
        "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps start" \
        "deploy@$H2 -- $CUR us-dev cash source-database positions-db-to-deephaven start"
    expect_not_in "activate" "$(cat "$log")"
    expect_json "$(cat "$report")" '.placements[0].result' "failed: health (back to current)"
    expect_json "$(cat "$report")" '.placements[1].result' "rolled back: $TRADES failed (back to current)"
    expect_json "$(cat "$report")" '[.boxes[] | .activated] | join(",")' ","
    expect_json "$(cat "$report")" '.version' "$V1"
    expect_in "back to current, the version that ran before" "$ERR"
    # A first deploy: no current version to go back to, so the failed instance is stopped.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H1:health" STUB_NO_CURRENT=1 \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    in_order "$log" "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps start" \
        "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps stop"
    expect_json "$(cat "$report")" '.placements[0].result' "failed: health (no current version to go back to: stopped)"
    expect_json "$(cat "$report")" '.placements[1].result' "rolled back: $TRADES failed (no current version to go back to: stopped)"
}

case_record_tag() { # run-compose.sh record-tag: IMAGE_TAG into a host bundle's instance layer only, in place, idempotent
    local cfg b="$WORK/record-tag/bundle" rc env before first mode inside
    cfg="$(fixture record-tag)"
    bundle "$cfg" "$b" || return 0
    rc="$b/scripts/run-compose.sh"
    env="$b/config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env"
    # The box's copy gets a commented-out IMAGE_TAG and a second IMAGE_TAG line (compose reads the last one,
    # run-compose.sh the first), and mode 640.
    { echo "# IMAGE_TAG=commented-out"; cat "$env"; echo "IMAGE_TAG=duplicate"; } >"$WORK/record-tag.env"
    cat "$WORK/record-tag.env" >"$env"
    chmod 640 "$env"
    before="$WORK/record-tag.before"
    cp "$env" "$before"
    first="$(grep -n '^IMAGE_TAG=' "$before" | head -n 1)"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t2 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    [ "$(grep -n '^IMAGE_TAG=' "$env")" = "${first%%:*}:IMAGE_TAG=t2" ] ||
        fail "expected one IMAGE_TAG line, t2, where the first was (line ${first%%:*}): $(grep -n IMAGE_TAG "$env" | tr '\n' ' ')"
    [ "$(grep -v '^IMAGE_TAG=' "$env")" = "$(grep -v '^IMAGE_TAG=' "$before")" ] || fail "another line of the instance layer changed"
    mode="$(stat -c %a "$env" 2>/dev/null || stat -f %Lp "$env")"
    [ "$mode" = 640 ] || fail "the instance layer lost its mode: $mode"
    [ -z "$(find "$(dirname "$env")" -name '._docker-compose.instance.env.*')" ] || fail "a temporary file was left behind"
    expect_in "IMAGE_TAG=t2 recorded in config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env (was ${first#*:IMAGE_TAG=}); this version directory keeps it" "$ERR"
    expect_in 'cmd=record-tag opts="" result=0 override=IMAGE_TAG' "$ERR"
    # Idempotent; --dry-run only says what it would write.
    cp "$env" "$before"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t2 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    expect_in "already records IMAGE_TAG=t2" "$ERR"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 "$rc" us-dev cash source-database trades-db-to-amps record-tag --dry-run
    expect_rc 0
    expect_in "write         IMAGE_TAG=t3 into config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env (now t2)" "$OUT"
    # Refused: no tag; a value that is not a tag (a second line would add a variable); an IMAGE_REPO override.
    run in_dir / env -u GITHUB_RUN_ID "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG="t3"$'\n'"JAVA_OPTS=-Dinjected" "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG="t3"$'\n'"JAVA_OPTS=-Dinjected" "$rc" us-dev cash source-database trades-db-to-amps printenv
    expect_rc 2
    expect_in "is not a valid override" "$ERR"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 IMAGE_REPO=ghcr.io/other/repo "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 2
    expect_in "records IMAGE_TAG only" "$ERR"
    cmp -s "$env" "$before" || fail "a dry run or a refused record-tag changed the instance layer: $(diff "$before" "$env" | tr '\n' ' ')"
    # Never outside the bundle: a CONFIG_ROOT elsewhere, or a checkout (there the instance layer changes through git).
    cp "$cfg/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env" "$WORK/record-tag.cfg"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 CONFIG_ROOT="$cfg" "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 3
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t3 CONFIG_ROOT="$b/../../record-tag/config" "$rc" us-dev cash source-database \
        trades-db-to-amps record-tag
    expect_rc 3
    cmp -s "$cfg/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env" "$WORK/record-tag.cfg" || fail "record-tag wrote outside the bundle"
    inside="$REPO/config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env"
    cp "$inside" "$WORK/record-tag.repo"
    run env -u GITHUB_RUN_ID IMAGE_TAG=t3 "$REPO/scripts/run-compose.sh" \
        us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 3
    expect_in "in a checkout it changes through git" "$ERR"
    cmp -s "$inside" "$WORK/record-tag.repo" || fail "record-tag wrote the checkout's instance layer"
    # Without an IMAGE_TAG line the tag is appended.
    grep -v '^IMAGE_TAG=' "$before" >"$env"
    run in_dir / env -u GITHUB_RUN_ID IMAGE_TAG=t4 "$rc" us-dev cash source-database trades-db-to-amps record-tag
    expect_rc 0
    [ "$(tail -n 1 "$env")" = IMAGE_TAG=t4 ] || fail "IMAGE_TAG was not appended: $(tail -n 2 "$env" | tr '\n' ' ')"
}

case_record_first() { # the tag is recorded in the new version on every box before anything starts; the instance's own box must have it
    local cfg log="$WORK/record-first.log" report="$WORK/record-first.json" box
    local b="$WORK/record-first/bundle" boxes="$WORK/record-first/boxes"
    cfg="$(fixture record-first)"
    known_hosts "$cfg"
    # ssh: record-tag on the instance's box, then on the other box, then pull → start → health there, then activate everywhere.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    in_order "$log" "deploy@$H1 -- IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag" \
        "deploy@$H2 -- IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag" \
        "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps pull" \
        "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps start" \
        "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps health" \
        "deploy@$H1 -- $NEW activate --keep 5" \
        "deploy@$H2 -- $NEW activate --keep 5"
    expect_not_in "IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps start" "$(cat "$log")"
    expect_json "$(cat "$report")" '.placements[0] | "\(.result) \([.commands[] | select(test("record-tag.$"))] | length) \(.commands | length)"' "deployed 2 5"
    expect_json "$(cat "$report")" '[.boxes[] | .activated] | join(",")' "activated $V1,activated $V1"
    expect_json "$(cat "$report")" '"\(.project) \(.version) \(.pool.root)"' "$PROJECT $V1 $ROOT"
    # The other box fails to record: the instance is still deployed (exit 0, its line), and the report says so.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H2:record-tag" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "a failed record-tag on $H2 cost the deployed line: '$OUT'"
    expect_in "_docker-compose.instance.env of version $V1 on $H2 does not name t1" "$ERR"
    expect_json "$(cat "$report")" '.placements[0].result' "deployed; IMAGE_TAG not recorded on $H2"
    # The instance's own box fails to record: nothing starts there (the directory would run the declared tag).
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H1:record-tag" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    expect_not_in " pull" "$(cat "$log")"
    expect_not_in "activate" "$(cat "$log")"
    expect_json "$(cat "$report")" '.placements[0].result' "failed: record-tag on $H1 (nothing started)"
    # The local transport validates: record-tag --dry-run on both box directories, start --dry-run, activate --dry-run; nothing written.
    bundle "$cfg" "$b" || return 0
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --bundle "$b" --transport local --local-root "$boxes"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the validated instance"
    [ "$(grep -c "write         IMAGE_TAG=t1 into config/us-dev/cash/source-database/trades-db-to-amps/_docker-compose.instance.env" <<<"$ERR")" -eq 2 ] ||
        fail "expected record-tag --dry-run on both boxes: $(grep 'write  ' <<<"$ERR" | tr '\n' ' ')"
    [ "$(grep -c "activate      current -> $V1 (now none)" <<<"$ERR")" -eq 2 ] ||
        fail "expected activate --dry-run on both boxes: $(grep 'activate  ' <<<"$ERR" | tr '\n' ' ')"
    for box in "$H1" "$H2"; do
        if grep -qx 'IMAGE_TAG=t1' "$(box_env "$boxes" "$box" "$V1")"; then fail "$box: a validation run recorded the tag"; fi
        [ ! -e "$boxes/$box$ROOT/current" ] || fail "$box: a validation run activated the version"
    done
}

case_known_hosts() { # the ssh transport never runs without the reviewed known_hosts (5)
    local cfg cmd
    cfg="$(fixture known-hosts)"
    for cmd in "deploy --tag t1" "discover" "status" "rollback" "sync --bundle $WORK/none"; do
        # shellcheck disable=SC2086 # the command and its options, split on purpose
        run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$WORK/known-hosts.log" \
            "$POOL_DEPLOY" us-dev cash $cmd --transport ssh
        expect_rc 5
        expect_in "config/us-dev/known_hosts is missing" "$ERR"
    done
    [ ! -s "$WORK/known-hosts.log" ] || fail "something ran without known_hosts: $(cat "$WORK/known-hosts.log")"
    # plan is a preview: it plans without asking the boxes.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$WORK/known-hosts.log" "$POOL_DEPLOY" us-dev cash plan --json --transport ssh
    expect_rc 0
    expect_json "$OUT" '.discovery | startswith("skipped")' true
}

case_refusals() { # env, flow, pool, version and usage rules
    local cfg
    run "$POOL_DEPLOY" us-qa cash plan
    expect_rc 3
    run "$POOL_DEPLOY" us-prod cash deploy --tag t1
    expect_rc 3
    cfg="$(fixture refusals)"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev deriv plan --dry-run
    expect_rc 4
    expect_in "config/us-dev/deriv/workflows-config.yml not found" "$ERR"
    cfg="$(fixture refusals-no-pool 'del(.pool) | .targets[0].host = "dev-compose-01.us-dev.example.com"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "no pool in" "$ERR"
    cfg="$(fixture refusals-pin '.targets[0].host = "dev-other-01.us-dev.example.com"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "is not a box of the pool" "$ERR"
    cfg="$(fixture refusals-flow '.flow = "deriv"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    # The layout is fixed (DL-46): no root in the inventory; keep is at least 2.
    cfg="$(fixture refusals-root '.pool.root = "/opt/platform"')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "pool.root is gone (DL-46)" "$ERR"
    cfg="$(fixture refusals-keep '.pool.keep = 1')"
    run env CONFIG_ROOT="$cfg" "$POOL_DEPLOY" us-dev cash plan --dry-run
    expect_rc 4
    expect_in "pool.keep '1' must be an integer of at least 2" "$ERR"
    run "$POOL_DEPLOY" us-dev cash
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash deploy
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash plan --move
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash plan --out "$WORK/refusals/out"
    expect_rc 2
    expect_in "--out does not apply to plan" "$ERR"
    run "$POOL_DEPLOY" us-dev cash plan --version "$V1"
    expect_rc 2
    expect_in "--version does not apply to plan" "$ERR"
    run "$POOL_DEPLOY" us-dev cash deploy --tag t1 --to "$V1"
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1-x"
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash rollback --to yesterday --dry-run
    expect_rc 2
    expect_in "--to 'yesterday' is not a version" "$ERR"
    run "$POOL_DEPLOY" us-dev cash plan --transport ftp
    expect_rc 2
    run "$POOL_DEPLOY" us-dev fx plan
    expect_rc 2
    run "$POOL_DEPLOY" us-dev cash deploy --tag 'bad tag'
    expect_rc 2
    run "$POOL_DEPLOY" --help
    expect_rc 0
    expect_in "pool-deploy.sh <env> <flow> <command>" "$OUT"
    expect_in "/apps/<user>/versions/<project>/" "$OUT"
}

case_guard() { # run-compose.sh start / restart on a pooled box asks the other boxes' current version first (D6 §6.5)
    local b="$WORK/guard/bundle" log="$WORK/guard.log" rc peer
    bundle "$REPO/config" "$b" || return 0
    rc="$b/scripts/run-compose.sh"
    peer="deploy@$H2 -- $CUR us-dev cash source-database trades-db-to-amps status --json"
    guard() { # [VAR=value...] -- <run-compose.sh arguments...>
        local envs=()
        while [ "$1" != -- ]; do envs+=("$1"); shift; done
        shift
        : >"$log"
        run env PATH="$DOCKER_BIN:$PATH" POOL_SSH="$STUB/ssh" STUB_LOG="$log" SPRING_DATASOURCE_USERNAME=u \
            SPRING_DATASOURCE_PASSWORD=p ${envs[@]+"${envs[@]}"} "$rc" us-dev cash source-database trades-db-to-amps "$@"
    }
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start
    expect_rc 3
    expect_in "trades-db-to-amps is already running on $H2; stop it there first, or --force" "$ERR"
    expect_in "$peer" "$(cat "$log")"
    expect_not_in "deploy@$H1" "$(cat "$log")"
    expect_not_in " up -d" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- restart
    expect_rc 3
    expect_not_in "docker compose" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start --force
    expect_rc 0
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" POOL_PEER_CHECK=off -- start
    expect_rc 0
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" -- start
    expect_rc 0
    expect_in "$peer" "$(cat "$log")"
    expect_in " up -d --wait" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_UNREACHABLE="$H2" -- start
    expect_rc 0
    expect_in "could not ask $H2 whether trades-db-to-amps runs there (exit 255" "$ERR"
    # A peer without a current version yet (first deploy) only warns too: a box that cannot answer never blocks.
    guard POOL_SELF_HOST="$H1" STUB_NO_CURRENT=1 -- start
    expect_rc 0
    expect_in "could not ask $H2 whether trades-db-to-amps runs there (exit 127" "$ERR"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- start --dry-run
    expect_rc 0
    expect_in "peer check    $STUB/ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes deploy@$H2 -- '$CUR us-dev cash source-database trades-db-to-amps status --json'" "$OUT"
    expect_in "host bundle   $PROJECT us-dev/cash version bundle, tag t1" "$OUT"
    expect_not_in "ssh " "$(cat "$log")"
    guard POOL_SELF_HOST=box-elsewhere.example.com -- start
    expect_rc 0
    expect_in "is not one of POOL_HOSTS" "$ERR"
    expect_in "deploy@$H1 --" "$(cat "$log")"
    guard POOL_SELF_HOST="$H1" STUB_RUNNING="$H2:trades-db-to-amps" -- status
    expect_not_in "ssh " "$(cat "$log")"
}

case_ssh_deploy() { # the ssh transport end to end: rsync into the version directory, verified per box, the commands, the report; a dead box
    local cfg log="$WORK/ssh-deploy.log" report="$WORK/ssh-deploy.json" cmd
    cfg="$(fixture ssh-deploy)"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    expect_in "-az --delete --exclude=/.run/ -e $STUB/ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$cfg/us-dev/known_hosts" "$(cat "$log")"
    expect_in "/ deploy@$H2:$ROOT/$V1/" "$(cat "$log")"
    expect_not_in "/opt/platform" "$(cat "$log")"
    [ "$(grep -c -- '--dry-run --itemize-changes --checksum' "$log")" -eq 2 ] || fail "not every box was verified"
    for cmd in pull start health; do
        expect_in "deploy@$H1 -- $NEW us-dev cash source-database trades-db-to-amps $cmd" "$(cat "$log")"
    done
    expect_json "$(cat "$report")" '[.boxes[] | "\(.result)/\(.version)/\(.activated)"] | join(",")' "synced/$V1/activated $V1,synced/$V1/activated $V1"
    # record-tag on both boxes, pull, start, health on the box.
    expect_json "$(cat "$report")" '.placements[0] | "\(.how) \(.result) \(.commands | length)"' "assigned deployed 5"
    # A verification that finds a difference fails the box; with no box left nothing is deployed.
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" \
        STUB_RSYNC_CHANGES='>f..t...... config/us-dev/cash/workflows-config.yml\n' "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh
    expect_rc 1
    expect_in "the synced tree differs from the bundle" "$ERR"
    expect_not_in "deployed" "$OUT"
    # A dead box does not block the flow: the instance goes to the box that received the version (which alone
    # records the tag and activates: the dead box is never asked); still exit 1.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_RSYNC_FAIL="$H1" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 1
    [ "$OUT" = "deployed $TRADES@$H2=t1" ] || fail "stdout is '$OUT', expected the instance on $H2"
    expect_in "not synced: $H1" "$ERR"
    expect_in "deploy@$H2 -- IMAGE_TAG=t1 $NEW us-dev cash source-database trades-db-to-amps record-tag" "$(cat "$log")"
    expect_in "deploy@$H2 -- $NEW activate --keep 5" "$(cat "$log")"
    expect_not_in "deploy@$H1 --" "$(cat "$log")"
    expect_json "$(cat "$report")" '[.boxes[] | "\(.result)/\(.activated)"] | join(",")' "failed: rsync exit 12/null,synced/activated $V1"
    # A box whose activate fails: the instances run the new version, current did not move there; exit 1 and the report says so.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" POOL_RSYNC="$STUB/rsync" STUB_LOG="$log" STUB_FAIL="$H2:activate" \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport ssh --report "$report"
    expect_rc 1
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the deployed line (the instance runs $V1)"
    expect_in "not activated: $H2" "$ERR"
    expect_json "$(cat "$report")" '[.boxes[] | .activated] | join(",")' "activated $V1,failed: activate"
}

case_rollback_ssh() { # rollback: current back to the previous version on every box, then every instance restarts from it where it runs
    local cfg log="$WORK/rollback.log" report="$WORK/rollback.json"
    cfg="$(fixture rollback '(.targets[] | select(.instance == "source-database/trades-db-to-amps")).host = "'"$H1"'"')"
    known_hosts "$cfg"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_RUNNING="$H2:trades-db-to-amps" STUB_CURRENT="$V1" \
        "$POOL_DEPLOY" us-dev cash rollback --transport ssh --report "$report"
    expect_rc 0
    # Discovery through current, the flip on both boxes, then start and health where the instance runs (box 2, not its pin).
    in_order "$log" "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps status --json" \
        "deploy@$H1 -- $CUR activate --previous --keep 5" \
        "deploy@$H2 -- $CUR activate --previous --keep 5" \
        "deploy@$H2 -- $CUR us-dev cash source-database trades-db-to-amps start" \
        "deploy@$H2 -- $CUR us-dev cash source-database trades-db-to-amps health"
    expect_not_in "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps start" "$(cat "$log")"
    [ "$OUT" = "rolled-back $TRADES@$H2=$V0" ] || fail "stdout is '$OUT', expected 'rolled-back $TRADES@$H2=$V0'"
    expect_json "$(cat "$report")" '[.boxes[] | .activated] | join(",")' "activated $V0,activated $V0"
    expect_json "$(cat "$report")" '.placements[0] | "\(.how) \(.host) \(.result)"' "discovered $H2 rolled back to $V0"
    expect_json "$(cat "$report")" '"\(.version) \(.tag)"' "null null"
    # Not running anywhere: the pinned box restarts it; --to names the version.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_CURRENT="$V2" \
        "$POOL_DEPLOY" us-dev cash rollback --to "$V1" --transport ssh
    expect_rc 0
    [ "$OUT" = "rolled-back $TRADES@$H1=$V1" ] || fail "stdout is '$OUT', expected the pinned box"
    expect_in "deploy@$H1 -- $CUR activate --to $V1 --keep 5" "$(cat "$log")"
    # A box that cannot switch: its instances are not restarted; exit 1.
    : >"$log"
    run env CONFIG_ROOT="$cfg" POOL_SSH="$STUB/ssh" STUB_LOG="$log" STUB_FAIL="$H1:activate" \
        "$POOL_DEPLOY" us-dev cash rollback --transport ssh --report "$report"
    expect_rc 1
    expect_in "$H1: could not switch current back" "$ERR"
    expect_not_in "deploy@$H1 -- $CUR us-dev cash source-database trades-db-to-amps start" "$(cat "$log")"
    expect_json "$(cat "$report")" '.placements[0].result' "skipped: current not switched on $H1"
}

case_local_execute() { # POOL_LOCAL_EXECUTE=true: the real run-compose.sh commands in the box directories (stub engine), versions and current
    local cfg log="$WORK/local-execute.log" boxes="$WORK/local-execute/boxes" box v
    cfg="$(fixture local-execute '.pool.keep = 2 | (.targets[] | select(.instance == "source-database/trades-db-to-amps")).host = "'"$H1"'"')"
    # The stub engine runs no container: health fails, there is no current to go back to, the instance is stopped.
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" POOL_LOCAL_EXECUTE=true SPRING_DATASOURCE_USERNAME=u \
        SPRING_DATASOURCE_PASSWORD=p "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport local --local-root "$boxes"
    expect_rc 1
    expect_not_in "deployed" "$OUT"
    expect_in "--env-file $(box_combined "$boxes" "$H1" "$V1")" "$(cat "$log")"
    expect_in " pull" "$(cat "$log")"
    expect_in " up -d --wait" "$(cat "$log")"
    expect_not_in "ssh " "$(cat "$log")"
    [ "$(grep -c 'cmd=record-tag ' <<<"$ERR")" -eq 2 ] || fail "expected record-tag on both boxes first: $(grep -c 'cmd=record-tag ' <<<"$ERR")"
    [ "$(grep -c 'cmd=start ' <<<"$ERR")" -eq 1 ] && [ "$(grep -c 'cmd=stop ' <<<"$ERR")" -eq 1 ] ||
        fail "expected one start and one stop: $(grep -E 'cmd=(start|stop) ' <<<"$ERR" | tr '\n' ' ')"
    expect_in "no current version to go back to" "$ERR"
    for box in "$H1" "$H2"; do
        grep -qx 'IMAGE_TAG=t1' "$(box_env "$boxes" "$box" "$V1")" || fail "$box: the new version does not record t1"
        [ ! -e "$boxes/$box$ROOT/current" ] || fail "$box: a failed deploy activated $V1"
    done
    # A healthy engine: deployed, recorded, current -> V1 on both boxes, shared/ beside versions/.
    : >"$log"
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
        SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
        "$POOL_DEPLOY" us-dev cash deploy --tag t1 --version "$V1" --transport local --local-root "$boxes"
    expect_rc 0
    [ "$OUT" = "deployed $TRADES@$H1=t1" ] || fail "stdout is '$OUT', expected the one deployed line"
    for box in "$H1" "$H2"; do
        [ "$(readlink "$boxes/$box$ROOT/current" 2>/dev/null)" = "$V1" ] || fail "$box: current -> $(readlink "$boxes/$box$ROOT/current" 2>/dev/null || echo none), expected $V1"
        [ -d "$boxes/$box/apps/deploy/shared/$PROJECT/logs" ] || fail "$box: shared/$PROJECT/logs missing"
    done
    expect_in "deployed t1 as version $V1" "$ERR"
    # A second version: current moves, the first version keeps its own instance layer (t1).
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
        SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
        "$POOL_DEPLOY" us-dev cash deploy --tag t2 --version "$V2" --transport local --local-root "$boxes"
    expect_rc 0
    [ "$(readlink "$boxes/$H1$ROOT/current")" = "$V2" ] || fail "current did not move to $V2"
    if ! grep -qx 'IMAGE_TAG=t1' "$(box_env "$boxes" "$H1" "$V1")" || ! grep -qx 'IMAGE_TAG=t2' "$(box_env "$boxes" "$H1" "$V2")"; then
        fail "the versions do not each record their own tag"
    fi
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
        "$POOL_DEPLOY" us-dev cash status --json --transport local --local-root "$boxes"
    expect_json "$OUT" '[.[] | .version] | join(",")' "$V2,$V2"
    # Rollback: current back to V1 on both boxes, the instance restarted from V1 on its pinned box (the simulated
    # boxes share one engine, so discovery places nothing).
    : >"$log"
    run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
        SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
        "$POOL_DEPLOY" us-dev cash rollback --transport local --local-root "$boxes"
    expect_rc 0
    [ "$OUT" = "rolled-back $TRADES@$H1=$V1" ] || fail "stdout is '$OUT', expected 'rolled-back $TRADES@$H1=$V1'"
    for box in "$H1" "$H2"; do
        [ "$(readlink "$boxes/$box$ROOT/current")" = "$V1" ] || fail "$box: rollback left current at $(readlink "$boxes/$box$ROOT/current")"
    done
    # Discovery asked the live version (V2) first; the restart itself ran from V1.
    [[ $(grep -- ' up -d' "$log") == *"$(box_combined "$boxes" "$H1" "$V1")"* ]] || fail "the restart did not run from $V1: $(grep -- ' up -d' "$log")"
    [[ $(grep -- ' up -d' "$log") != *"/$V2/"* ]] || fail "the restart ran from $V2: $(grep -- ' up -d' "$log")"
    # keep 2: after V3 nothing goes (V1 is the version V3 replaced); after V4, V1 and V2 go.
    for v in "$V3" "$V4"; do
        run env PATH="$DOCKER_BIN:$PATH" CONFIG_ROOT="$cfg" STUB_LOG="$log" STUB_HEALTHY=1 POOL_LOCAL_EXECUTE=true \
            SPRING_DATASOURCE_USERNAME=u SPRING_DATASOURCE_PASSWORD=p \
            "$POOL_DEPLOY" us-dev cash deploy --tag t3 --version "$v" --transport local --local-root "$boxes"
        expect_rc 0
        if [ "$v" = "$V3" ]; then
            [ -d "$boxes/$H1$ROOT/$V1" ] && [ -d "$boxes/$H1$ROOT/$V2" ] || fail "after $V3 a version went that keep 2 should have kept (V1 was current)"
        fi
    done
    [ ! -d "$boxes/$H1$ROOT/$V1" ] && [ ! -d "$boxes/$H1$ROOT/$V2" ] && [ -d "$boxes/$H1$ROOT/$V3" ] && [ -d "$boxes/$H1$ROOT/$V4" ] ||
        fail "after $V4 with keep 2 expected only $V3 and $V4: $(find "$boxes/$H1$ROOT" -mindepth 1 -maxdepth 1 -printf '%f ')"
    [ "$(readlink "$boxes/$H2$ROOT/current")" = "$V4" ] || fail "current did not end at $V4"
}

# --- runner -----------------------------------------------------------------------------------------------

selected=("$@")
[ "${#selected[@]}" -gt 0 ] || read -r -a selected <<<"$(tr '\n' ' ' <<<"$CASES")"
passed=0 failed=0
for name in "${selected[@]}"; do
    case " $(tr '\n' ' ' <<<"$CASES") " in *" $name "*) ;; *) echo "pool-deploy-test: unknown case '$name' (cases: $CASES)" >&2; exit 2 ;; esac
    status=0
    ( CASE_FAILED=0; "case_$name"; exit "$CASE_FAILED" ) >"$WORK/case.out" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        echo "ok - $name"
        passed=$((passed + 1))
    else
        echo "not ok - $name$([ "$status" -eq 1 ] || echo " (aborted with exit $status)")"
        cat "$WORK/case.out"
        failed=$((failed + 1))
    fi
done
echo "pool-deploy-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
