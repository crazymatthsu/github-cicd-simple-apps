---
name: new-repo-from-template
description: Create a new Spring Boot repository from this template. Copies it at a release tag, sets platform.yml, removes this repository's apps and configuration, adds the first app, starts the release line, verifies locally and pushes. Use when asked to create, bootstrap, scaffold or start a new repository or project from this template.
allowed-tools: Bash(git *) Bash(./gradlew *) Bash(scripts/*) Bash(bash *) Read Write Edit Glob Grep
---

# Create a repository from this template

The executable form of "Create a repository from this one" in `docs/adr/README.md` (ADR-0005, ADR-0030,
ADR-0039, ADR-0043). The new repository copies the shared tooling unchanged, declares its own values in
`platform.yml`, and starts with every switch off that it does not need yet: no dev env, no reference app, no Helm,
no integration tests, no company base images. Each turns on later with one line.

## Inputs

Collect all of these before writing a file. Ask once, in one message, for the ones `$ARGUMENTS` does not give.

| Input | Rule | Default |
|---|---|---|
| name | the GitHub repository name, lower-case kebab-case; also `projects[0].name` and `rootProject.name` | required |
| group | the Java group of every module, a package name such as `com.acme.payments` | required |
| registry | `<host>[/<namespace>]`, the `<registry>` of every image (ADR-0010) | required |
| regions | two lower-case letters each | required |
| stages | lower-case words; must include `dev` (ADR-0004) | `[dev, qa, uat, prod]` |
| flows | lower-case kebab-case, at least one (ADR-0003) | required |
| kinds | `[compose]`, or `[compose, helm]` when the repository deploys with Helm (ADR-0019) | `[compose]` |
| apps_dir | the directory of the apps | `apps` |
| dev_envs | `<region>-dev` entries, or `[]` until a dev env has boxes and a GitHub Environment (ADR-0035) | `[]` |
| property_prefixes | the apps' property roots, dotted lower-case, at least one: the summary shows them and no env layer may set their `UPPER_CASE_` forms (ADR-0042) | `[<last segment of group>]` |
| secret_properties | the project's secret property names, dotted lower-case; `spring.datasource.username/password` and secret-looking names are built in (ADR-0042) | `[]` |
| first app | `<AppName>` (at most 20 characters), its flow, its first instance name (at most 32) | required |
| target | the directory to create | `../<name>` |
| tag | the release of this template to copy | the latest `vX.Y.Z` tag |

## Steps

1. **Copy the template at the tag**, from this checkout:
   ```bash
   tag=$(git describe --tags --abbrev=0 --match 'v*')
   git clone --branch "$tag" --depth 1 "$(git remote get-url origin)" <target>
   cd <target> && rm -rf .git && git init -b main
   ```
   Keep the tag: it goes into the first commit message and into `docs/README.md` (step 7), so a later update of
   the shared tooling (open decision O3) knows where it started.

2. **Remove this template's project files** (ADR-0005 rule 5 names the three classes):
   ```bash
   rm -rf apps/* config/local config/us-dev test-infra/testdata/* test-infra/seed/*
   rm -f test-infra/compose/deephaven.yml test-infra/compose/sqlserver.yml test-infra/compose/kafka.yml
   ```
   Keep the runtime module under `framework/` (every app is built on it; the domain split of its
   `connector.*` properties is open decision O5), `test-infra/compose/{base.yml,it-runner.yml,stack.sh}`,
   `test-infra/kind/`, `config/README.md`, `test-infra/README.md` and `docs/`.
   In the files that stay, remove what named the template's own dependencies:
   - `test-infra/compose/stacks.yml`: delete the project lines and the `stacks:` block; keep the header.
   - `test-infra/compose/versions.env`: keep the header and the `CI_BUILD_IMAGE` line, with `<registry>/base/ci-build:latest`; delete the other images.
   - `test-infra/compose/local-ports.yml`: keep `services:` with no entries; the first stack adds its block.
   - `gradle/libs.versions.toml`: delete the `deephaven` version and the `deephaven-java-client-*` and `mssql-jdbc` libraries; keep the rest.
   - `renovate.json`: delete the Deephaven package rule; `ghcr.io/crazymatthsu/base/**` becomes `<registry>/base/**`.
   - `.hadolint.yaml`: `trustedRegistries` keeps `docker.io` and the registry's host; delete `mcr.microsoft.com` unless a stack uses it.
   - `.github/CODEOWNERS`: one rule per path class with the new repository's teams; the per-flow rules name its flows.

3. **Write `platform.yml`** from `${CLAUDE_SKILL_DIR}/templates/platform.yml`, replacing every `__KEY__`
   placeholder with the inputs, and keep the comments: they explain the schema to the next reader. Then
   `./gradlew help`: it fails on any problem of the file (ADR-0030 rule 3).

4. **Create the flow directories.** For `local` and for each dev env, for each flow:
   - `config/<env>/<flow>/_docker-compose.flow.env` from `${CLAUDE_SKILL_DIR}/templates/flow.env`:
     `IMAGE_REPO=<registry>/<name>`, `TZ`, `LOG_LEVEL_ROOT`; in a dev env also `LOGS_DIR` and `DATA_DIR`
     (ADR-0018: uncomment the two lines and set the pool user and the project).
   - In a dev env, `config/<env>/<flow>/workflows-config.yml` from
     `${CLAUDE_SKILL_DIR}/templates/workflows-config.yml`: the pool's boxes and user; `add-app` adds the targets.

5. **Add the first app** with the `add-app` skill: `/add-app <AppName> <flow> <AppInstance>`. It creates the
   module, its configuration in `local` and in each dev env, the chart when `kinds` includes `helm`, and verifies
   the build.

6. **Start the release line** (ADR-0029): `CHANGELOG.md` empty, `.release-please-manifest.json` holding `{}` (the
   first release is then the `initial-version` of `release-please-config.json`, `0.1.0`), `component` in
   `release-please-config.json` set to the name. No tag.

7. **Rewrite the documents that describe the project**: `README.md` (what the apps do, how to build and run; keep
   the sections that describe the copied tooling), `docs/README.md` (the apps' rows, and one line naming this
   template and the tag copied). `apps/<AppName>/README.md` comes from `add-app`.

8. **Verify locally** before the first commit:
   ```bash
   ./gradlew build configLint
   bash scripts/ci/setup-yq.sh && for t in scripts/test/*-test.sh; do bash "$t"; done
   scripts/run-compose.sh local <flow> <AppName> <AppInstance> validate
   ```
   `build` needs JDK 21 on PATH; without a container engine `buildImage` no-ops with a message. The script tests
   need `jq`, `rsync` and `python3` besides the yq the first command installs.

9. **Commit, push, settings, first pull request.**
   - `git add -A && git commit -m "chore: create <name> from <template> <tag>"`, with the attribution lines your
     session requires; create the GitHub repository; `git push -u origin main`.
   - Apply the settings of ADR-0020 rule 8 and ADR-0032: the rulesets, the Actions permissions, one Environment
     per dev env (none with `dev_envs: []`), the secrets `REGISTRY_USER` and `REGISTRY_TOKEN` when the registry
     is not GHCR, the variable `YQ_DOWNLOAD_BASE` behind JFrog. Tell the user which ones you could not apply.
   - Open a first pull request with a small change, such as the README, and check that `pr-gate` is green and that
     the first `main` run after its merge publishes the images.

## What stays off, and how it turns on

"What a new repository may leave out" in `docs/adr/README.md` lists every switch. In short: `dev_envs` from `[]`
to `[<region>-dev]`, plus the env's tree and its GitHub Environment, turns the dev deploy on (ADR-0035);
`reference_app` turns the system test, the kind deployment test and the nightly drill on; `helm` in `kinds`
requires a chart per app and the values files (ADR-0036); the first app that applies
`buildlogic.integration-test` turns the integration-test stage on (ADR-0034); the company base images are used as
soon as they are published under `<registry>/base/` (ADR-0033).

## Never

- Edit a file of the shared tooling in the new repository; change it in the template and copy the release
  (ADR-0005).
- Put a project value anywhere but `platform.yml`: the build, the scripts and config-lint read it there.
- Renumber or edit ADR-0001 to ADR-0999. The repository's own decisions start at ADR-1000 (ADR-0001), and a
  subject it does not have is not a deviation (ADR-0039).
