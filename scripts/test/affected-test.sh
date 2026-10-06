#!/usr/bin/env bash
# affected-test.sh — scripts/ci/projects.py and scripts/ci/affected.py on a fixture repository (ADR-0022, ADR-0031):
# the projects are derived from the build files of apps_dir and framework/, each project's directory selects it, the
# reference app's directory raises deploy-test (no directory does without one), and a map that still lists projects is
# refused. The fixture uses this repository's real .github/affected-map.yml. Needs python3, and yq or PyYAML to read
# the map.
# The lint job runs it with the other scripts/test/*-test.sh. Exit codes: 0 every case passed · 1 a case failed ·
# 2 a missing tool.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
command -v python3 >/dev/null 2>&1 || { echo "affected-test: python3 is needed" >&2; exit 2; }
exec python3 - "$REPO" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile

repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "scripts", "ci"))
import projects  # noqa: E402

PROJECTS = os.path.join(repo, "scripts", "ci", "projects.py")
AFFECTED = os.path.join(repo, "scripts", "ci", "affected.py")
MAP = os.path.join(repo, ".github", "affected-map.yml")
passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"ok - {name}")
    else:
        failed += 1
        print(f"not ok - {name}: {detail}")


def run(*args):
    result = subprocess.run([sys.executable, *args], capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


work = tempfile.mkdtemp(prefix="affected-test.")
try:
    def write(rel, text):
        path = os.path.join(work, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    # A repository whose apps live in services/ (platform.yml's apps_dir), with one app without integration tests.
    write("platform.yml", "platform: v1\nprojects:\n  - name: demo\n    apps_dir: services   # the apps\n"
                          "    reference_app: ledger\n")
    write("services/ledger/build.gradle.kts", 'plugins {\n    id("buildlogic.spring-boot-app")\n'
                                               '    id("buildlogic.docker-image")\n    id("buildlogic.integration-test")\n}\n')
    write("services/feed/build.gradle.kts", 'plugins {\n    id("buildlogic.docker-image")\n'
                                            '    // id("buildlogic.integration-test")\n}\n')
    write("framework/lib/build.gradle.kts", 'plugins {\n    id("buildlogic.java-conventions")\n}\n')
    write("framework/notes/README.md", "no build file: not a project\n")
    write("services/stray.txt", "a file, not a module\n")

    rc, out, err = run(PROJECTS, "--root", work)
    check("projects.py derives the modules of apps_dir and framework/ from their build files", rc == 0 and json.loads(out) == {
        ":feed": {"dir": "services/feed", "image": True, "it": False},
        ":ledger": {"dir": "services/ledger", "image": True, "it": True},
        ":lib": {"dir": "framework/lib", "image": False, "it": False},
    }, f"exit {rc}: {out}{err}")
    rc, out, err = run(PROJECTS, "--root", work, "--images")
    check("--images lists the projects that build an image", rc == 0 and json.loads(out) == [":feed", ":ledger"], out + err)
    rc, out, err = run(PROJECTS, "--root", work, "--reference-dir")
    check("--reference-dir is the reference app's directory", rc == 0 and out.strip() == "services/ledger", out + err)

    def affected(*files, map_path=MAP):
        rc, out, err = run(AFFECTED, "--root", work, "--map", map_path, "--files", *files)
        return (json.loads(out) if rc == 0 else None), rc, err

    decision, rc, err = affected("services/ledger/src/main/java/Ledger.java")
    check("an app's directory selects that app, and the reference app raises deploy-test",
          decision is not None and decision["projects"] == [":ledger"] and decision["matrix"] == [":ledger"]
          and decision["image-projects"] == [":ledger"] and decision["deploy-test"] and not decision["full"], err)
    decision, rc, err = affected("services/feed/README.txt")
    check("an app without integration tests is built but joins no matrix",
          decision is not None and decision["projects"] == [":feed"] and decision["matrix"] == []
          and not decision["deploy-test"], err)
    decision, rc, err = affected("framework/lib/src/Lib.java")
    check("a library is shared: everything", decision is not None and decision["full"]
          and sorted(decision["projects"]) == [":feed", ":ledger", ":lib"], err)
    decision, rc, err = affected("services/new-app/x.txt")
    check("a directory without a build file is unmapped: everything", decision is not None and decision["full"], err)
    decision, rc, err = affected("docs/guide.md")
    check("documentation builds nothing", decision is not None and decision["docs-only"], err)

    # Without reference_app there is no reference scenario (ADR-0035): an empty directory, and no deploy-test from it.
    write("platform.yml", "platform: v1\nprojects:\n  - name: demo\n    apps_dir: services   # the apps\n")
    rc, out, err = run(PROJECTS, "--root", work, "--reference-dir")
    check("--reference-dir is empty without a reference app", rc == 0 and out.strip() == "", f"exit {rc}: {out}{err}")
    decision, rc, err = affected("services/ledger/src/main/java/Ledger.java")
    check("without a reference app, no app's directory raises deploy-test",
          decision is not None and decision["projects"] == [":ledger"] and not decision["deploy-test"], err)

    with open(MAP, encoding="utf-8") as handle:
        stale = handle.read() + '\nprojects:\n  ":ledger": { image: true, it: true }\n'
    write("stale-map.yml", stale)
    decision, rc, err = affected("docs/guide.md", map_path=os.path.join(work, "stale-map.yml"))
    check("a map that still lists projects is refused", rc == 2 and "derived from the build files" in err, f"exit {rc}: {err}")

    write("framework/ledger/build.gradle.kts", "plugins {}\n")
    rc, out, err = run(PROJECTS, "--root", work)
    check("a module name used twice is refused", rc == 2 and "exists in both" in err, f"exit {rc}: {err}")
    shutil.rmtree(os.path.join(work, "framework", "ledger"))
    write("platform.yml", "projects:\n  - apps_dir: services\n    reference_app: lib\n")
    rc, out, err = run(PROJECTS, "--root", work, "--reference-dir")
    check("a reference app that builds no image is refused", rc == 2 and "reference_app 'lib'" in err, f"exit {rc}: {err}")

    # The reading CI shares with the build: the same cases as ProjectIndexTest (build-logic).
    plugin = "buildlogic.docker-image"
    agree = [
        (True, f'plugins {{\n    id("buildlogic.spring-boot-app")\n    id("{plugin}")\n}}\n'),
        (True, f'plugins {{ id( "{plugin}" ) }}'),
        (True, f'plugins {{\n    id("{plugin}") // the image (ADR-0009)\n}}\n'),
        (False, f'plugins {{\n    // id("{plugin}")\n}}\n'),
        (False, f'plugins {{\n    /* id("{plugin}")\n    */\n}}\n'),
        (False, f'plugins {{\n    id("{plugin}-extra")\n    id("buildlogic.docker")\n}}\n'),
        (False, 'plugins {\n    id("buildlogic.docker-imageX")\n}\n'),
        (False, f'plugins {{\n    android("{plugin}")\n}}\n'),
    ]
    wrong = [text for expected, text in agree if projects.applies(text, plugin) != expected]
    check("projects.applies reads build files as buildlogic.ProjectIndex does", not wrong, repr(wrong))
finally:
    shutil.rmtree(work, ignore_errors=True)

print(f"affected-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
