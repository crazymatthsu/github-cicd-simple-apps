# R-0001 — Extracted from github-demo as one project repository

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-01, DL-03, DL-04, DL-42 (D12) of github-demo |

## Context

The `github-demo` monorepo held two release lines — the connector family under `deephaven-connectors/` and the
`deephaven-server` image — together with the pipeline, the convention plugins and the design documents. DL-42 /
D12 fix one project repository per release line, a shared `platform-ci` repository for everything reusable, and a
configuration repository for the promoted envs. This repository was created to hold the connector family.

## Decision

1. **The project is the repository.** The release line, the image path and the Gradle root project are
   `github-cicd-simple-apps`: images `ghcr.io/crazymatthsu/github-cicd-simple-apps/<AppName>`, tags `vX.Y.Z`,
   `rootProject.name = "github-cicd-simple-apps"`, one `projects` entry in `platform.yml`. D12 §6.1 makes the
   project implicit in the repository; and the GHCR packages `deephaven-connectors/<AppName>` are linked to
   github-demo, which a token of this repository cannot push to, while new names link to this repository on their
   first push.
2. **Flat Gradle projects.** `:source-kafka`, `:source-amps`, `:source-database` live under `apps/`,
   `:connectors-framework` under `libs/`; `settings.gradle.kts` discovers them (a directory with a
   `build.gradle.kts`), so adding an app is a directory. The image group convention of `buildlogic.docker-image`
   becomes "the parent path of a nested app, else the root project", which keeps the demo monorepo's
   `:deephaven-connectors:<AppName>` → `deephaven-connectors/<AppName>` working.
3. **One version line.** `VersionLine` keeps only the family; release-please has one package (`.`); `release.yml`
   handles `v*` only and derives the image path from `platform.yml` (`registry`, `projects[0].name`).
4. **No per-app wrappers.** The per-app `scripts/run-compose.sh` and `scripts/smoke.sh` are gone (D12 §6.2):
   `scripts/run-compose.sh` resolves `apps/<AppName>` (or any `<dir>/<AppName>` with a compose template) and runs
   `scripts/smoke.sh --app-dir` for `health`; an app that needs checks of its own ships `apps/<AppName>/scripts/smoke.sh`,
   which is preferred and bundled. The host bundle therefore holds `scripts/` once and `apps/<AppName>/docker/`
   per app; the deploy user's forced command (DL-35) allows `<root>/scripts/run-compose.sh`. `scripts/entrypoint.sh`
   stays per app: it is part of the image, not a deploy wrapper.
5. **The platform's Deephaven server is a pinned dependency.** The system test of `main.yml` runs against
   `DEEPHAVEN_SERVER_IMAGE` in `test-infra/compose/versions.env` — a published, digest-pinned image of github-demo's
   `deephaven-server` line — when no `:deephaven-server` image comes out of the run; the reusable workflow keeps the
   in-run path for the monorepo. The company base images stay `ghcr.io/crazymatthsu/base/*`, built by github-demo.
6. **Platform pieces vendored, laid out to move.** `.github/workflows/_*.yml`, `.github/actions/`, `scripts/`,
   `scripts/ci/` and `build-logic/` are copies of github-demo at `d139d4c`, with every path and project reference
   made layout-agnostic (apps resolved by name, the project from the manifest) so that the same files can serve the
   monorepo and this repository from `platform-ci@v1` later. Not carried over: `deephaven-server/`, `docker/base/`,
   `base-image.yml`, `TODO.md`, the D-documents and DL ADRs, the `gha-*` skills.
7. **Deferred, unchanged from github-demo v1.6**: the inventory schema v2 and the Deployment record of DL-40 /
   DL-41 (the v1.0 write-back to `main` still runs at the end of `deploy-dev`), the shared compose template and
   library chart, generated thin workflows and `affected-map.yml`.

## Alternatives considered

- Keep the project name `deephaven-connectors` with images `ghcr.io/crazymatthsu/deephaven-connectors/<AppName>`:
  the packages are linked to github-demo (pushes from this repository would be refused), and D12 §6.1 names the
  repository as the project.
- Keep the nested Gradle path `:deephaven-connectors:<AppName>` under `apps/`: contradicts the D12 layout and
  buys nothing once the repository is the project.
- Keep the per-app wrappers until DL-41 is implemented: D12 §6.2 removes them, the root script already resolves
  an app by name, and `pool-deploy.sh` and its tests needed only the root path.
- Build the Deephaven server here too: a second release line in a repository created for one; the server keeps
  its own line in github-demo (`deephaven-server/vX.Y.Z`) until it gets a repository of its own.

## Consequences

- `IMAGE_REPO` in every `compose.env`, `image.repository` in every chart and the nightly drill image point to the
  new path; the first `main.yml` run of this repository publishes the new packages (repository settings:
  `docs/README.md`).
- github-demo still holds `deephaven-connectors/`; removing it there, and moving `docs/`, `build-logic/` and the
  workflows into `platform-ci`, are follow-ups in that repository.
- Until `platform-ci` exists, a fix to a vendored file is ported between the two repositories by hand; the
  layout-agnostic form of the scripts and workflows keeps that a copy, not a rewrite.
- D12 / DL-42 should record the image-path rule for a top-level app (`<registry>/<project>/<AppName>` with the
  project from the manifest) and this mapping as the worked example of a monorepo split.
