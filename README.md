# github-cicd-simple-apps — Deephaven connector apps

The connector apps of the Deephaven data platform — `source-kafka`, `source-amps`, `source-database` — and their
shared library, extracted from the [`github-demo`](https://github.com/crazymatthsu/github-demo) monorepo as one
**project repository** under the platform's repository contract (ADR DL-42 and design document D12 there): one
release line, `apps/<AppName>` per deployable app, `framework/` for the shared code the apps are built on, the `config/` tree of the envs this
repository deploys itself, and a `platform.yml` manifest for what the tree cannot derive. The apps are
hello-world Spring Boot 4.1 / Java 21 services (identity, masked configuration summary, actuator); the plumbing
around them is the point.

| Path | What |
|---|---|
| `platform.yml` | the manifest: platform major, registry, the one project (`github-cicd-simple-apps`) and its dev envs |
| `apps/<AppName>/` | one Gradle project per deployable app: `src/{main,test,integrationTest}`, `docker/` (Dockerfile, compose template), `helm/<AppName>/`, `scripts/entrypoint.sh` |
| `framework/connectors-framework/` | the framework the apps are built on: identity, `connector.*` properties, masked start-up summary, health, metrics tags, test fixtures (DL-43) |
| `config/` | configuration tree `config/<env>/<flow>/<AppName>/{app-common,<AppInstance>}`, the `_common` layers, one `workflows-config.yml` per dev flow ([`config/README.md`](config/README.md)) |
| `test-infra/` | compose stacks, kind tier, seeds and test data of the integration tests ([`test-infra/README.md`](test-infra/README.md)) |
| `scripts/` | `run-compose.sh`, `smoke.sh`, `pool-deploy.sh`, `helm-deploy-instance.sh`, `scripts/ci/` — platform scripts, vendored (below) |
| `build-logic/` | the Gradle convention plugins `buildlogic.*` — vendored (below) |
| `.github/` | thin trigger workflows (`pr`, `main`, `release`, `release-please`, `nightly`, `config-lint`), the reusable `_*.yml` and the composite actions — vendored (below) |
| `docs/` | this repository's documentation and ADRs ([`docs/README.md`](docs/README.md)); the platform design lives in github-demo |

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

`pr.yml` (affected build, lint, config-lint, images `pr-<n>-<sha7>`, component integration tests, kind deploy
test; `pr-gate` is the one required check) → `main.yml` (build all, integration tests, system test against the
platform's Deephaven server image, publish, kind deploy, deploy-dev) → `release-please.yml` / `release.yml`
(release PR, tag, promote the tested digests, SBOMs, GitHub Release). Details and the repository settings the
pipeline needs: [`docs/README.md`](docs/README.md).

## What is vendored, and why

The contract (D12 §6.9) has every repository *consume* the workflows, actions, CI and runtime scripts and the
convention plugins from a versioned `platform-ci` repository. That repository does not exist yet, so this one
carries copies of `.github/workflows/_*.yml`, `.github/actions/`, `scripts/` and `build-logic/`, taken from
github-demo at commit `d139d4c` and laid out so that they move out without a change to the apps. Until then a
pipeline fix is made in github-demo and ported here, and vice versa. Design documents, ADRs, the company base
images (`docker/base/`, `base-image.yml`) and the `gha-*` Claude Code skills stay in github-demo.
