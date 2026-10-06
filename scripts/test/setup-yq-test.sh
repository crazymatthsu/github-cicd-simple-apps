#!/usr/bin/env bash
# setup-yq-test.sh — scripts/ci/setup-yq.sh (ADR-0021): the pinned mikefarah yq on PATH is kept and nothing is
# downloaded; another yq (another version, or the Python wrapper of the same name) is shadowed by the release binary,
# installed only when its SHA-256 matches the release's checksums-bsd; a bad pin or base URL is a usage error (2).
# Stub curl, uname and yq, so no network is reached and the cases run on any host; the checksum lines are in the
# format of a real release (v4.54.1), padded names included. The lint job runs it with the other scripts/test/*-test.sh.
# Exit codes: 0 every case passed · 1 a case failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO SETUP_YQ="$REPO/scripts/ci/setup-yq.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/setup-yq-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK
trap 'rm -rf "${WORK:?}"' EXIT
unset YQ_DOWNLOAD_BASE GITHUB_PATH RUNNER_TEMP

command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "setup-yq-test: sha256sum or shasum is needed" >&2; exit 2; }
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'; }

readonly WANT=v4.54.1 BASE=https://downloads.example.test/yq
STUBS="$WORK/stubs" FIXTURES="$WORK/fixtures" CURL_LOG="$WORK/curl.log"
mkdir -p "$STUBS" "$FIXTURES"
# uname: a Linux amd64 host, whatever this one is.
printf '#!/usr/bin/env bash\ncase "${1:-}" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac\n' >"$STUBS/uname"
# curl: serves <fixtures>/<basename of the URL> into -o <file>, logs the URL; 22 when the fixture is missing.
cat >"$STUBS/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
echo "\$url" >>"$CURL_LOG"
[ -f "$FIXTURES/\$(basename "\$url")" ] || exit 22
cp "$FIXTURES/\$(basename "\$url")" "\$out"
EOF
chmod 0755 "$STUBS/uname" "$STUBS/curl"
# The "release binary": a script that answers like the mikefarah build of the pinned version.
printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version %s"\n' "$WANT" >"$FIXTURES/yq_linux_amd64"
GOOD_SUM="$(sum "$FIXTURES/yq_linux_amd64")"
readonly STUBS FIXTURES CURL_LOG GOOD_SUM
# checksums-bsd as a release publishes it (lines of v4.54.1, the SHA256 of our binary in place of the real one).
checksums() { # checksums <sha256 of yq_linux_amd64, or "none">
    cat <<EOF
CRC32 (yq_linux_amd64) = 1167c4b7
MD4   (yq_linux_amd64) = 731c8ac20bb057786f83c62c77aa155c
SHA1  (yq_linux_amd64) = d985b2875be40470c803f3e90b3b01785cdc9e29
SHA224 (yq_linux_amd64) = a248dd810ce88af2d6bbfbc69653fc8294d405123ef53a93392ecbb7
EOF
    [ "$1" = none ] || echo "SHA256 (yq_linux_amd64) = $1"
    cat <<'EOF'
SHA384 (yq_linux_amd64) = 9fa1403044c6ce29be9324e38f53cb5d5ce7ddf24fa27f815816ed84aff5a7107277808a35ef0dd97f9dd17f3bc2476e
SHA256 (yq_linux_amd64.tar.gz) = e68a456f90c577af3fe4960184b3a3cf5c461e0348407c10f107da3a5fec8972
SHA256 (yq_linux_arm64) = 189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b
EOF
}
# The yq first on PATH: "mikefarah <version>" or "python" (the wrapper). Every case stubs one, so the host's own yq —
# on a runner, the pinned one that setup-yq just installed — never decides a case.
with_yq() {
    rm -f "$STUBS/yq"
    case $1 in
        mikefarah) printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version %s"\n' "$2" >"$STUBS/yq" ;;
        python) printf '#!/usr/bin/env bash\necho "yq 3.4.3"\n' >"$STUBS/yq" ;;
    esac
    [ ! -f "$STUBS/yq" ] || chmod 0755 "$STUBS/yq"
}

PASSED=0 FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'not ok - %s\n' "$1"; }
# run <case> <expected exit> <text expected in stderr or ""> <args...>: runs setup-yq.sh with the stubs first on PATH.
run() {
    local name="$1" code="$2" text="$3" rc=0 out err
    shift 3
    : >"$CURL_LOG"
    out="$(PATH="$STUBS:$PATH" bash "$SETUP_YQ" --bin-dir "$WORK/bin" --base-url "$BASE" "$@" 2>"$WORK/stderr")" || rc=$?
    err="$(cat "$WORK/stderr")"
    OUT="$out"
    if [ "$rc" -ne "$code" ]; then fail "$name → exit $rc, expected $code; stderr: $(tail -n 2 "$WORK/stderr" | tr '\n' ' ')"; return 0; fi
    case "$err" in *"$text"*) pass "$name → $code" ;; *) fail "$name → $code but stderr lacks '$text': $(tail -n 2 "$WORK/stderr" | tr '\n' ' ')" ;; esac
}
downloads() { grep -c . "$CURL_LOG" 2>/dev/null || true; }

# 1. The pinned version is on PATH: kept, nothing downloaded, the version printed.
with_yq mikefarah "$WANT"
run "pinned version on PATH" 0 "is on PATH" --version "$WANT"
[ "$OUT" = "$WANT" ] && pass "prints $WANT" || fail "printed '$OUT', expected $WANT"
[ "$(downloads)" = 0 ] && pass "no download" || fail "downloaded: $(cat "$CURL_LOG")"

# 2. The Python wrapper is on PATH: the release binary is installed after its checksum matched, and GITHUB_PATH gets the directory.
with_yq python
checksums "$GOOD_SUM" >"$FIXTURES/checksums-bsd"
rm -rf "${WORK:?}/bin"
: >"$WORK/github_path"
GITHUB_PATH="$WORK/github_path" run "python wrapper on PATH" 0 "not the mikefarah build" --version "$WANT"
[ "$OUT" = "$WANT" ] && pass "prints $WANT after installing" || fail "printed '$OUT', expected $WANT"
[ -x "$WORK/bin/yq" ] && pass "installed $WORK/bin/yq" || fail "no executable at $WORK/bin/yq"
[ "$(downloads)" = 2 ] && pass "downloaded the binary and checksums-bsd" || fail "downloads: $(cat "$CURL_LOG")"
grep -qx "$WORK/bin" "$WORK/github_path" && pass "GITHUB_PATH gets the install directory" || fail "GITHUB_PATH: $(cat "$WORK/github_path")"
grep -q "$BASE/$WANT/yq_linux_amd64" "$CURL_LOG" && pass "assets fetched from --base-url" || fail "URLs: $(cat "$CURL_LOG")"

# 3. Another mikefarah version on PATH: shadowed the same way.
with_yq mikefarah v4.0.0
rm -rf "${WORK:?}/bin"
run "another mikefarah version on PATH" 0 "PATH has mikefarah yq v4.0.0" --version "$WANT"
[ -x "$WORK/bin/yq" ] && pass "installed over the older version" || fail "no executable at $WORK/bin/yq"

# 4. A checksum mismatch, or no SHA-256 line at all: nothing is installed.
with_yq python
checksums 0000000000000000000000000000000000000000000000000000000000000000 >"$FIXTURES/checksums-bsd"
rm -rf "${WORK:?}/bin"
run "checksum mismatch" 1 "checksum mismatch" --version "$WANT"
[ ! -e "$WORK/bin/yq" ] && pass "nothing installed on a mismatch" || fail "$WORK/bin/yq exists after a mismatch"
checksums none >"$FIXTURES/checksums-bsd"
run "no SHA-256 line" 1 "no SHA-256 for yq_linux_amd64" --version "$WANT"

# 5. A missing asset: the download fails. A binary that answers with another version: refused after the install.
checksums "$GOOD_SUM" >"$FIXTURES/checksums-bsd"
mv "$FIXTURES/yq_linux_amd64" "$FIXTURES/yq_linux_amd64.off"
run "asset missing from the release" 1 "download of" --version "$WANT"
mv "$FIXTURES/yq_linux_amd64.off" "$FIXTURES/yq_linux_amd64"
run "binary reports another version" 1 "after installing v4.99.99" --version v4.99.99

# 6. Usage errors, before anything is fetched.
run "bad version" 2 "must be v4.<minor>.<patch>" --version 4.54.1
run "unknown argument" 2 "unknown argument" --nope
[ "$(downloads)" = 0 ] && pass "usage errors download nothing" || fail "downloaded: $(cat "$CURL_LOG")"
rc=0; PATH="$STUBS:$PATH" bash "$SETUP_YQ" --bin-dir "$WORK/bin" --base-url http://plain.example.test --version "$WANT" >/dev/null 2>"$WORK/stderr" || rc=$?
[ "$rc" -eq 2 ] && grep -q "must be an https:// URL" "$WORK/stderr" && pass "http base URL → 2" || fail "http base URL → $rc"

# 7. The pin of this repository's .github/versions.env is what the script reads by default.
pin="$(sed -n 's/^YQ_VERSION=//p' "$REPO/.github/versions.env")"
with_yq mikefarah "$pin"
run "default pin from .github/versions.env ($pin)" 0 "is on PATH"

printf 'setup-yq-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
