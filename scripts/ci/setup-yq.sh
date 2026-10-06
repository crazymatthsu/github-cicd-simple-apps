#!/usr/bin/env bash
# setup-yq.sh — mikefarah yq v4 at the pinned version, first on PATH (ADR-0021, ADR-0030).
#
# Usage: setup-yq.sh [--version <vX.Y.Z>] [--base-url <url>] [--bin-dir <dir>] [--versions-file <file>]
#   --version        the pin. Default: YQ_VERSION in --versions-file (.github/versions.env of this repository).
#   --base-url       where the release assets are, <base-url>/<version>/{yq_linux_<arch>,checksums-bsd}. Default:
#                    env YQ_DOWNLOAD_BASE, else https://github.com/mikefarah/yq/releases/download (behind JFrog: the
#                    generic remote of the GitHub releases).
#   --bin-dir        the install directory. Default: $RUNNER_TEMP/setup-yq/bin in CI, else a temp dir. Prepended to
#                    PATH for the later steps of the job when GITHUB_PATH is set.
# A yq on PATH that reports exactly the pinned mikefarah version is kept and nothing is downloaded. Any other yq —
# another version, or the Python wrapper of the same name — is shadowed, never replaced. The binary is checked
# against the SHA-256 the release publishes (checksums-bsd) before it is installed. Linux, amd64 or arm64.
# Prints the version in use on stdout; progress goes to stderr.
# Exit codes: 0 ok · 1 download, checksum or platform problem · 2 usage · 5 curl or sha256sum missing.
set -euo pipefail

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
err() {
  echo "setup-yq: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
want="" base="${YQ_DOWNLOAD_BASE:-}" bin="" versions_file="$REPO_ROOT/.github/versions.env"
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) [[ $# -ge 2 ]] || usage; want=$2; shift 2 ;;
    --base-url) [[ $# -ge 2 ]] || usage; base=$2; shift 2 ;;
    --bin-dir) [[ $# -ge 2 ]] || usage; bin=$2; shift 2 ;;
    --versions-file) [[ $# -ge 2 ]] || usage; versions_file=$2; shift 2 ;;
    -h | --help) usage ;;
    *) echo "setup-yq: unknown argument '$1'" >&2; usage ;;
  esac
done
if [[ -z $want ]]; then
  [[ -f $versions_file ]] || { echo "setup-yq: $versions_file not found (give --version)" >&2; exit 2; }
  want=$(sed -n 's/^YQ_VERSION=//p' "$versions_file" | tail -n 1)
fi
[[ $want =~ ^v4\.[0-9]+\.[0-9]+$ ]] || { echo "setup-yq: the version must be v4.<minor>.<patch>, got '$want'" >&2; exit 2; }
base=${base:-https://github.com/mikefarah/yq/releases/download}
base=${base%/}
[[ $base =~ ^https://[^[:space:]]+$ ]] || { echo "setup-yq: --base-url must be an https:// URL, got '$base'" >&2; exit 2; }

# What `yq --version` says: the mikefarah build prints "yq (https://github.com/mikefarah/yq/) version v4.x.y", the
# Python wrapper "yq <n>". The version for the mikefarah build, empty otherwise.
version_line() { yq --version 2>/dev/null | head -n 1 || true; }
current() {
  local line
  line=$(version_line)
  case $line in
    *mikefarah*) printf '%s\n' "${line##* }" ;;
    *) printf '\n' ;;
  esac
}

have=$(current)
if [[ $have == "$want" ]]; then
  echo "yq $want is on PATH" >&2
  echo "$want"
  exit 0
fi

command -v curl >/dev/null || { echo "setup-yq: curl is needed to download yq $want" >&2; exit 5; }
if command -v sha256sum >/dev/null; then
  sum() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum >/dev/null; then
  sum() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
  echo "setup-yq: sha256sum (or shasum) is needed to verify the download" >&2
  exit 5
fi
[[ $(uname -s) == Linux ]] || err "only Linux is supported (got $(uname -s))"
case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) err "unsupported architecture $(uname -m) (amd64 or arm64)" ;;
esac
asset="yq_linux_$arch"

if [[ -z $bin ]]; then
  if [[ -n ${RUNNER_TEMP:-} ]]; then bin="$RUNNER_TEMP/setup-yq/bin"; else bin="$(mktemp -d "${TMPDIR:-/tmp}/setup-yq.XXXXXX")/bin"; fi
fi
mkdir -p "$bin"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/setup-yq.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT

other=$(version_line)
if [[ -n $have ]]; then why=" (PATH has mikefarah yq $have)"; elif [[ -n $other ]]; then why=" (PATH has '$other', not the mikefarah build)"; else why=""; fi
echo "yq $want: installing$why from $base" >&2
fetch() { curl -fsSL --proto '=https' --retry 3 --retry-connrefused --retry-delay 2 "$@"; }
fetch -o "$tmp/$asset" "$base/$want/$asset" || err "download of $base/$want/$asset failed"
fetch -o "$tmp/checksums-bsd" "$base/$want/checksums-bsd" || err "download of $base/$want/checksums-bsd failed"
# checksums-bsd: one `SHA256 (<asset>) = <hex>` line per asset, among the other digests of the same asset.
expected=$(awk -v f="$asset" '$1 == "SHA256" && $2 == "(" f ")" { print $4; exit }' "$tmp/checksums-bsd")
[[ $expected =~ ^[0-9a-f]{64}$ ]] || err "no SHA-256 for $asset in the checksums-bsd of $want"
actual=$(sum "$tmp/$asset")
[[ $actual == "$expected" ]] || err "checksum mismatch for $asset $want: expected $expected, got $actual"
install -m 0755 "$tmp/$asset" "$bin/yq"
PATH="$bin:$PATH"
got=$(current)
[[ $got == "$want" ]] || err "$bin/yq reports '${got:-$(version_line)}' after installing $want"
[[ -z ${GITHUB_PATH:-} ]] || echo "$bin" >> "$GITHUB_PATH"
echo "yq $want installed in $bin" >&2
echo "$want"
