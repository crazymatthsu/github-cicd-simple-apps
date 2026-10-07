#!/usr/bin/env bash
# public-base-smoke.sh: prove that an app image built on the public fallback base runs (ADR-0033).
#
# Usage: public-base-smoke.sh <AppName>
# Builds the image of :<AppName> with BASE_IMAGE set to BASE_IMAGE_FALLBACK of .github/versions.env, as
# setup-build-env does in a repository without <registry>/base/jre21. Starts it with a local identity (the first
# flow of platform.yml, instance smoke) under the compose template's posture (read-only root, /tmp on tmpfs, no
# capabilities), runs scripts/smoke.sh against it (readiness UP, identity), then checks that it runs as user 10001
# and that curl, which the health checks call, works inside it. The container is removed on every exit.
# Needs a JDK 21, curl and Podman or Docker (ADR-0045). Exit codes: 0 proven · 1 failed · 2 usage.
set -euo pipefail

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
fail() {
  echo "public-base-smoke.sh: $*" >&2
  exit 1
}

[[ $# -eq 1 && $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || usage
app=$1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# The engine of buildImage (ADR-0045): CONTAINER_ENGINE, else Podman when it answers, else Docker. Gradle gets it too,
# so the image is built where it then runs.
engine=${CONTAINER_ENGINE:-auto}
if [[ $engine == auto ]]; then
  engine=docker
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then engine=podman; fi
fi
[[ $engine == podman || $engine == docker ]] || fail "CONTAINER_ENGINE must be podman, docker or auto (was '$engine')"

# Both read without yq: the pin of .github/versions.env, and the one-line flows list of platform.yml (ADR-0030).
base=$(sed -n 's/^BASE_IMAGE_FALLBACK=//p' "$root/.github/versions.env" | tail -n 1)
flow=$(awk '/^flows:/ { sub(/^flows:[ \t]*\[[ \t]*/, ""); sub(/[ \t]*[],].*$/, ""); print; exit }' "$root/platform.yml")
[[ -n $base ]] || fail ".github/versions.env has no BASE_IMAGE_FALLBACK"
[[ -n $flow ]] || fail "platform.yml has no one-line flows list"

# BASE_IMAGE from the environment, the way setup-build-env hands the fallback to buildImage. A local tag only.
export BASE_IMAGE=$base
cd "$root"
./gradlew ":$app:buildImage" -Pimage.tags=public-base-smoke -Pimage.engine="$engine"
image=$(./gradlew -q ":$app:printImageRef" -Pimage.tags=public-base-smoke | tr -d '\r' | grep -E ':public-base-smoke$' |
  tail -n 1) || fail "printImageRef printed no reference tagged public-base-smoke"

name=public-base-smoke-$$
trap '"$engine" rm -f "$name" >/dev/null 2>&1 || true' EXIT
"$engine" run -d --name "$name" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
  -e APP_ENV=local -e APP_FLOW="$flow" -e APP_NAME="$app" -e APP_INSTANCE=smoke \
  -p 127.0.0.1::8080 "$image" >/dev/null
port=$("$engine" port "$name" 8080/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n 1)
[[ -n $port ]] || fail "no host port published for 8080 of $name"

if ! SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-150} "$root/scripts/smoke.sh" local "$flow" "$app" smoke "http://127.0.0.1:$port"; then
  "$engine" logs --tail 200 "$name" >&2 || true
  fail "$image on $base did not become ready"
fi
uid=$("$engine" exec "$name" id -u)
[[ $uid == 10001 ]] || fail "$image runs as uid $uid, not 10001 (ADR-0009)"
"$engine" exec "$name" curl -fsS -o /dev/null http://localhost:8080/actuator/health/readiness ||
  fail "curl, which the health checks call, does not work in $image"
echo "public-base-smoke.sh: $image on $base is ready, runs as uid $uid and has curl"
