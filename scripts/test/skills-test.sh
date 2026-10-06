#!/usr/bin/env bash
# skills-test.sh — the skills under .claude/skills are the executable form of the index checklists (ADR-0043): each has a
# SKILL.md whose name is its directory and that has a description; every repository path that a skill or CLAUDE.md
# cites exists; the templates of add-app equal the reference app's files but for the name (the chart, the contract
# blocks of application.yml, the class the main class calls, the module it depends on); the platform.yml template has
# the keys of this repository's platform.yml. Plain bash, awk, sed and diff; no network, no engine.
# The lint job runs it with the other scripts/test/*-test.sh. Exit codes: 0 every check passed · 1 a check failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO SKILLS="$REPO/.claude/skills"
PASSED=0 FAILED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'not ok - %s\n' "$1"; }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

# --- 1. every skill has a SKILL.md with a frontmatter naming its directory and describing when to use it -------------
for dir in "$SKILLS"/*/; do
    name=$(basename "$dir")
    file="$dir/SKILL.md"
    [ -f "$file" ] || { fail "$name: no SKILL.md"; continue; }
    check "$name: frontmatter opens the file" test "$(head -n 1 "$file")" = "---"
    check "$name: name is the directory" grep -qx "name: $name" "$file"
    check "$name: has a description" grep -qE '^description: .{20,}' "$file"
    check "$name: no model name" bash -c '! grep -qiE "claude (opus|sonnet|haiku|fable)|gpt-[0-9]" "$1"' _ "$file"
done

# --- 2. every repository path a skill or CLAUDE.md cites exists (placeholders and globs are not paths) ---------------
cited() { # <file>: the backticked tokens that look like repository paths
    grep -o '`[^`]*`' "$1" | tr -d '`' |
        grep -E '^(scripts|docs|\.github|\.claude|test-infra|build-logic|docker|gradle|framework|config)/[^[:space:]]+$' |
        grep -vE '[<>$*{}]|__' | sort -u || true
}
for file in "$REPO/CLAUDE.md" "$SKILLS"/*/SKILL.md; do
    label=${file#"$REPO"/}
    missing=''
    while IFS= read -r path; do
        [ -z "$path" ] || [ -e "$REPO/$path" ] || missing="$missing $path"
    done < <(cited "$file")
    check "$label: every cited path exists${missing:+ (missing:$missing)}" test -z "$missing"
done

# --- 3. the add-app templates equal the reference app's files but for the name ---------------------------------------
T="$SKILLS/add-app/templates"
ref=$(sed -n 's/^ *reference_app: *\([a-z0-9-]*\).*/\1/p' "$REPO/platform.yml" | head -n 1)
apps_dir=$(sed -n 's/^ *apps_dir: *\([A-Za-z0-9_.-]*\).*/\1/p' "$REPO/platform.yml" | head -n 1)
registry=$(sed -n 's/^registry: *\([^ #]*\).*/\1/p' "$REPO/platform.yml" | head -n 1)
project=$(sed -n 's/^ *- *name: *\([^ #]*\).*/\1/p' "$REPO/platform.yml" | head -n 1)
app="$REPO/${apps_dir:-apps}/$ref"
if [ -n "$ref" ] && [ -d "$app" ]; then
    # The chart (README.md is the template's own; the rest is the reference chart with the name replaced).
    if [ -d "$app/helm/$ref" ]; then
        home=$(sed -n 's/^home: *//p' "$app/helm/$ref/Chart.yaml" | head -n 1)
        # Chart.yaml's header comment and description are the app's own: compared without them.
        chart_body() { awk '/^#/ { next } /^description:/ { skip = 1; next } /^[a-zA-Z]/ { skip = 0 } !skip' "$1"; }
        differing=''
        while IFS= read -r rel; do
            real="$app/helm/$ref/$rel"
            if [ ! -f "$real" ]; then differing="$differing $rel(missing)"; continue; fi
            if [ "$rel" = Chart.yaml ]; then
                diff -q <(chart_body "$real" | sed "s#${home:-__none__}#__REPOSITORY_URL__#g; s/$ref/__APP_NAME__/g") <(chart_body "$T/helm/$rel") >/dev/null || differing="$differing $rel"
            else
                sed "s#$registry/$project/$ref#__IMAGE_REPOSITORY__#g; s#${home:-__none__}#__REPOSITORY_URL__#g; s/$ref/__APP_NAME__/g" "$real" |
                    diff -q - "$T/helm/$rel" >/dev/null || differing="$differing $rel"
            fi
        done < <(cd "$T/helm" && find . -type f ! -name README.md | sed 's#^\./##' | sort)
        check "add-app chart template equals $ref's chart but for the name and the description${differing:+ (differs:$differing)}" test -z "$differing"
    fi
    # The contract blocks of application.yml: server, management and logging, as the reference app has them.
    blocks() { awk '/^[A-Za-z]/ { on = ($1 == "server:" || $1 == "management:" || $1 == "logging:") } on' "${1:--}"; }
    check "add-app application.yml carries $ref's server, management and logging blocks" \
        diff -q <(sed "s/$ref/__APP_NAME__/g" "$app/src/main/resources/application.yml" | blocks) <(blocks "$T/app/application.yml")
    # The main class calls, and the test extends, classes that exist in the runtime module.
    for pair in "Application.java:PlatformApplication" "ApplicationTest.java:AbstractPlatformApplicationTest"; do
        tfile=${pair%%:*} class=${pair#*:}
        pkg=$(sed -n "s/^import \([a-z0-9_.]*\)\.$class;/\1/p" "$T/app/$tfile" | head -n 1)
        check "add-app $tfile imports $class from a class of framework/" \
            test -n "$pkg" -a -n "$(find "$REPO/framework" -path "*/src/*/java/$(echo "$pkg" | tr . /)/$class.java" 2>/dev/null | head -n 1)"
    done
    module=$(sed -n 's/.*project(":\([a-z0-9-]*\)").*/\1/p' "$T/app/build.gradle.kts" | head -n 1)
    check "add-app build file depends on a module of framework/ ($module)" test -n "$module" -a -f "$REPO/framework/$module/build.gradle.kts"
else
    pass "no reference app with a directory: the template comparison is skipped (ADR-0035)"
fi

# --- 4. the platform.yml template has exactly the keys of this repository's platform.yml ------------------------------
keys() { # <file>: top-level keys, and the keys of projects[0], uncommented
    { grep -oE '^[a-z_]+:' "$1"; grep -oE '^    [a-z_]+:' "$1" | sed 's/^ *//'; } | sort -u
}
tkeys() { # the template: an optional key appears commented out, "# reference_app:", and counts
    { grep -oE '^[a-z_]+:' "$1"; grep -oE '^    (# )?[a-z_]+:' "$1" | sed 's/^ *//; s/^# //'; } | sort -u
}
check "new-repo-from-template platform.yml template has the keys of platform.yml" \
    diff -q <(keys "$REPO/platform.yml") <(tkeys "$SKILLS/new-repo-from-template/templates/platform.yml")

printf 'skills-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
