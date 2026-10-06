# github-cicd-simple-apps — Deephaven connector apps

The connector apps of the Deephaven data platform — `source-kafka`, `source-amps`, `source-database` — and the
framework they share, as one **project repository**:

- one release line;
- `apps/<AppName>` per deployable app;
- `framework/` for the shared code the apps are built on;
- the `config/` tree of the envs this repository deploys itself;
- a `platform.yml` manifest for what the tree cannot derive.

The repository is also the reference implementation of the contract in [`docs/adr/`](docs/adr/README.md). Other
Spring Boot apps follow that contract — in this repository, or in repositories created from it — to reuse its CI/CD
workflows, configuration management and runtime operations. The apps are hello-world Spring Boot 4.1 / Java 21
services (identity, masked configuration summary, actuator); the plumbing around them is the point.

| Path | What |
|---|---|
| `platform.yml` | the manifest of every project value: registry, the one project (`github-cicd-simple-apps`: group, apps directory, runtimes, reference app), the dev envs and the regions, stages and flows, the apps' property roots and the secret properties. The build validates it, and every tool reads it ([ADR-0030](docs/adr/0030-platform-yml-declares-every-project-value.md), [ADR-0042](docs/adr/0042-property-roots-and-secret-properties-in-platform-yml.md)) |
| `apps/<AppName>/` | one Gradle project per deployable app: `src/{main,test,integrationTest}`, `helm/<AppName>/`, and only when the app needs it in every env `docker/docker-compose.override.yml` |
| `docker/` | `spring-boot.Dockerfile` and `entrypoint.sh`: one image definition shared by every app, staged with its `application.jar` by `buildlogic.docker-image` ([ADR-0009](docs/adr/0009-one-shared-image-definition.md)); `docker-compose.yml`: one compose template for every app and instance ([ADR-0012](docs/adr/0012-compose-template-and-generated-env.md)) |
| `framework/app-runtime/` | the framework the apps are built on: identity, `connector.*` properties, masked start-up summary, health, metrics tags, test fixtures ([ADR-0006](docs/adr/0006-apps-and-framework-modules.md)) |
| `config/` | configuration tree `config/<env>/<flow>/<AppName>/<AppInstance>/`. Each layer is a file in the directory of its level — `application.<layer>.yml`, `_docker-compose.<layer>.env` / `.yml`, `_helm-values.<layer>.yaml` for the flow, app and instance — plus one `workflows-config.yml` per dev flow ([`config/README.md`](config/README.md), [ADR-0011](docs/adr/0011-configuration-tree-and-spring-layers.md)) |
| `test-infra/` | compose stacks, kind tier, seeds and test data of the integration tests ([`test-infra/README.md`](test-infra/README.md)) |
| `scripts/` | `run-compose.sh`, `smoke.sh`, `pool-deploy.sh`, `helm-deploy-instance.sh`, `scripts/ci/` — shared tooling (below) |
| `build-logic/` | the Gradle convention plugins `buildlogic.*` — shared tooling (below) |
| `.github/` | thin trigger workflows (`pr`, `main`, `release`, `release-please`, `nightly`, `config-lint`), the reusable `_*.yml` and the composite actions — shared tooling (below) |
| `docs/` | the documentation index ([`docs/README.md`](docs/README.md)) and the repository contract ([`docs/adr/`](docs/adr/README.md)) |

Images are `ghcr.io/crazymatthsu/github-cicd-simple-apps/<AppName>` — `<registry>/<project>/<AppName>` with the
project of `platform.yml`. Versions come from git tags (`vX.Y.Z` releases, `<next>-rc.<n>` on `main`,
`pr-<n>-<sha7>` on pull requests); every app releases in lockstep.

## Build

Requires a JDK 21; everything else comes through the Gradle wrapper.

```bash
./gradlew build                              # compile, unit tests, coverage floor, boot jars (no containers)
./gradlew configLint                         # lint the config tree
./gradlew -q printVersion                    # version derived from git, e.g. 0.1.0-local.3.1a2b3c4
./gradlew buildImages                        # container images (Docker or Podman)
./gradlew :source-database:integrationTest   # compose stack + integration tests of one app
./gradlew devUp / devDown                    # dependency stack for local development

scripts/run-compose.sh local cash source-database positions-db-to-deephaven start --dry-run
scripts/run-compose.sh --help
```

## Pipeline

`pr.yml` (affected build, lint, config-lint, images `pr-<n>-<sha7>`, integration tests, kind deploy test;
`pr-gate` is the one required check) → `main.yml` (build all, integration tests when a project has them, publish,
kind deploy, deploy-dev) → `release-please.yml` / `release.yml` (release PR, tag, promote the tested digests, SBOMs,
GitHub Release). The details are in ADR-0021 to ADR-0029, ADR-0034 and ADR-0044, and the repository settings the
pipeline needs are in [ADR-0020](docs/adr/0020-branching-protection-and-merge-rules.md). Where each job runs, and
which of the two base images the Gradle build, the unit tests and the integration tests use, is drawn in
[`docs/ci-build-environment.md`](docs/ci-build-environment.md).

## Shared tooling

This repository is the source of the shared tooling: `build-logic/`, `docker/`, `scripts/`, `.github/actions/`,
the reusable `.github/workflows/_*.yml` and the test-infra scripts. A repository created from this one copies these
files unchanged and takes its project values from its own `platform.yml`. A change to the shared tooling is made
here first ([ADR-0005](docs/adr/0005-repository-layout-and-shared-tooling.md)). The checklists for adding an app
or creating a repository are in [`docs/adr/README.md`](docs/adr/README.md).
