#!/usr/bin/env python3
"""The Gradle projects of this repository, derived from its build files (ADR-0031).

The rule is the build's own: every directory under platform.yml's `apps_dir` and under `framework/` that holds a
`build.gradle.kts` is the top-level project `:<directory>` (ADR-0006, ADR-0030). A project produces an image when its
build file applies `buildlogic.docker-image`, and has integration tests when it applies `buildlogic.integration-test`;
both plugins fail the build when they are applied anywhere else (buildlogic.ProjectIndex), so this reading cannot
disagree with Gradle. Standard library only and no Gradle: CI reads it before anything is built.

    python3 scripts/ci/projects.py                  # {":<name>": {"dir": ..., "image": ..., "it": ...}, ...}
    python3 scripts/ci/projects.py --images         # JSON list of the projects that produce images
    python3 scripts/ci/projects.py --reference-dir  # the directory of platform.yml's reference_app

Exit codes: 0 success, 2 platform.yml, a module or the reference app is not as the build expects.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

PLATFORM_FILE = "platform.yml"
LIBRARIES_DIR = "framework"
IMAGE_PLUGIN = "buildlogic.docker-image"
IT_PLUGIN = "buildlogic.integration-test"
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)


def fail(message: str) -> None:
    print(f"projects.py: {message}", file=sys.stderr)
    sys.exit(2)


def platform_value(root: str, key: str) -> str:
    """A plain value of platform.yml (`<key>: <value>`), as the build validated it; no YAML parser needed."""
    path = os.path.join(root, PLATFORM_FILE)
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    match = re.search(rf"^\s*(?:-\s+)?{re.escape(key)}:\s*([^\s#]+)", text, re.MULTILINE)
    if not match:
        fail(f"{PLATFORM_FILE} has no `{key}` (ADR-0030)")
    return match.group(1)


def applies(build_file_text: str, plugin_id: str) -> bool:
    """Whether the build file applies `id("<plugin_id>")`, comments ignored; the same reading as buildlogic.ProjectIndex."""
    code = "\n".join(line.split("//", 1)[0] for line in BLOCK_COMMENT.sub("", build_file_text).splitlines())
    return re.search(r'\bid\(\s*"' + re.escape(plugin_id) + r'"\s*\)', code) is not None


def derive(root: str) -> dict[str, dict]:
    """Every project, apps first: `:<name>` → its directory (relative to [root]) and whether it has an image and ITs."""
    index: dict[str, dict] = {}
    for parent in (platform_value(root, "apps_dir"), LIBRARIES_DIR):
        directory = os.path.join(root, parent)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            build_file = os.path.join(directory, name, "build.gradle.kts")
            if not os.path.isfile(build_file):
                continue
            path = f":{name}"
            if path in index:
                fail(f"module '{name}' exists in both {index[path]['dir']} and {parent}/{name}: project names must be "
                     "unique (ADR-0006)")
            with open(build_file, encoding="utf-8") as handle:
                text = handle.read()
            index[path] = {"dir": f"{parent}/{name}", "image": applies(text, IMAGE_PLUGIN), "it": applies(text, IT_PLUGIN)}
    if not index:
        fail("no module found under platform.yml's apps_dir or framework/ (ADR-0006)")
    return index


def reference_dir(root: str, index: dict[str, dict]) -> str:
    app = platform_value(root, "reference_app")
    entry = index.get(f":{app}")
    if entry is None or not entry["image"]:
        fail(f"{PLATFORM_FILE}: reference_app '{app}' is not an app with an image (ADR-0030)")
    return entry["dir"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="the repository root (default: the current directory)")
    what = parser.add_mutually_exclusive_group()
    what.add_argument("--images", action="store_true", help="print the JSON list of the projects that produce images")
    what.add_argument("--reference-dir", action="store_true", help="print the directory of platform.yml's reference_app")
    args = parser.parse_args()
    index = derive(args.root)
    if args.images:
        print(json.dumps([path for path, entry in index.items() if entry["image"]], separators=(",", ":")))
    elif args.reference_dir:
        print(reference_dir(args.root, index))
    else:
        print(json.dumps(index, indent=2))


if __name__ == "__main__":
    main()
