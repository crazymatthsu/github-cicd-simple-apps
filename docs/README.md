# Documentation of github-cicd-simple-apps

This repository is a **project repository** of the Deephaven data platform: one release line, the connector apps.
The platform's design documents D0–D12 and its decision log DL-01 … DL-42 live in
[github-demo/docs](https://github.com/crazymatthsu/github-demo/tree/main/docs); the repository contract this
layout follows is D12 (`docs/12-repository-layout-and-pipeline-contract.md`) with ADR DL-42. This directory holds
only what is specific to this repository.

| Document | What |
|---|---|
| [`adr/`](adr/README.md) | decisions of this repository (R-0001: the extraction) |
| [`../config/README.md`](../config/README.md) | the configuration tree and the host bundle |
| [`../test-infra/README.md`](../test-infra/README.md) | compose stacks, kind tier, how the integration tests run |
| `../apps/<AppName>/README.md`, `../apps/<AppName>/helm/<AppName>/README.md` | one app and its chart |

## The layout against the contract (D12 §6.2)

| Contract | Here |
|---|---|
| `platform.yml` | platform `v1`, kind `app`, registry `ghcr.io/crazymatthsu`, project `github-cicd-simple-apps` (`apps_dir: apps`), `dev_envs: [us-dev]` |
| `apps/<AppName>/{build.gradle.kts, src/main, src/test, src/integrationTest, docker/Dockerfile, docker/docker-compose.yml, helm/<AppName>/}` | `source-kafka`, `source-amps`, `source-database`; each also carries `scripts/entrypoint.sh`, part of the image |
| `framework/<name>` (DL-43; `libs/` before) | `connectors-framework` |
| `config/<env>/<flow>/<AppName>/<AppInstance>/` and one `workflows-config.yml` per flow | `local/cash`, `us-dev/cash` (inventory schema v1.3; the v2 schema of DL-40 / DL-41 arrives with their implementation) |
| `test-infra/`, `docs/`, `.github/CODEOWNERS` | present |
| no per-app `scripts/run-compose.sh` / `scripts/smoke.sh` wrappers | removed: `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> <command>` finds the app under `apps/`; an app that needs checks of its own adds `apps/<AppName>/scripts/smoke.sh` |
| one shared compose template with per-app overrides; one library chart | **not yet** — every app still ships its full `docker/docker-compose.yml` and chart (scheduled with DL-41) |
| thin, generated trigger workflows and `affected-map.yml` | **not yet** — hand-written copies (`render-workflows.sh` does not exist); keep `.github/affected-map.yml` in step with `apps/` |
| `uses: <org>/platform-ci/...@v1`, plugins by version | **not yet** — vendored copies (README) |

## Pipeline

| Workflow | Trigger | Does |
|---|---|---|
| `pr.yml` | branch push, pull request, merge queue | detect affected → lint (hadolint, ShellCheck, script tests, actionlint) → build, with images `pr-<n>-<sha7>` on pull requests → config-lint → component integration tests → kind deploy test → **`pr-gate`**, the one required check |
| `main.yml` | push to `main`, `hotfix/**` | build all → component integration tests → system test (`source-database` against the platform's Deephaven server image, `DEEPHAVEN_SERVER_IMAGE` in `test-infra/compose/versions.env`) → publish (`<next>-rc.<n>`, `sha-<sha7>`, `main`) → kind deploy → deploy-dev (`main` only), recorded as a GitHub Deployment of Environment `us-dev` (DL-40) |
| `release-please.yml` | push to `main` | the release PR; merging it creates the tag `vX.Y.Z` and dispatches `release.yml` |
| `release.yml` | tag `v*` | assert `printVersion` = tag → wait for the tested `main.yml` run → retag its digests → SBOMs → GitHub Release → `us-qa` bump PR (skipped while `config/us-qa` does not exist) |
| `nightly.yml` | 03:17 UTC | GHCR retention (dry run unless told otherwise), teardown drill |
| `config-lint.yml` | reusable | `./gradlew configLint` |

**No workflow writes to `main`** (DL-40, ADR R-0002): no job holds `contents: write`. The dev tree declares its
intent (`IMAGE_TAG=main`, `image.tag: main`); `deploy-dev` pins the literal version with the `IMAGE_TAG` override,
`record-tag` writes it into the boxes' `compose.env`, and the run is recorded as a GitHub Deployment of Environment
`us-dev` whose payload names, per instance, the tag, the digest-pinned image, the box or cluster and the result, plus
the config tree's git SHA. Still open from DL-40 / DL-41: the per-flow deploy policy (`deploy.on-merge`,
`deploy.schedule`), the manual deploy and rollback dispatches, and the versioned per-project bundles.

## Repository settings (D12 §6.10)

No file can set these; apply them once in the repository settings:

1. **Actions → General → Workflow permissions**: "Allow GitHub Actions to create and approve pull requests" —
   `release-please.yml` opens the release PR, `release.yml` the qa bump PR.
2. **Environment `us-dev`** (named like the env, D12 §6.7): created by the first `deploy-dev` run; add the secret
   `DEV_DEPLOY_SSH_KEY` (and `config/us-dev/known_hosts` in the tree) once boxes exist — until then the runner plays
   every box (transport `local`). The Environment `dev` of the first run is unused and can be deleted.
3. **Ruleset on `main`** (and `hotfix/**`): pull request required, one approval, required check `pr-gate`, linear
   history, no bypass for GitHub Actions — nothing here needs one (DL-40).
4. **Packages**: the first `main.yml` run creates `ghcr.io/crazymatthsu/github-cicd-simple-apps/<AppName>`, linked to
   this repository and private by default; make them public or grant `packages: read` to their consumers.
5. **Optional**: the secret `RETENTION_TOKEN` (read and delete packages) and the repository variable
   `RETENTION_DRY_RUN=false` for the nightly sweep; the label `ci:full`; the Renovate app.
