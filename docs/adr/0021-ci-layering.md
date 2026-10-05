# ADR-0021 — CI is layered: thin trigger workflows, reusable stage workflows, composite actions, and scripts that run anywhere

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | everything under `.github/` and the scripts it calls |
| Enforced by | actionlint (with ShellCheck on `run:` blocks), ShellCheck and the script tests in the `lint` job; review for logic in YAML |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md), [ADR-0020](0020-branching-protection-and-merge-rules.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0029](0029-release-and-promotion.md) |

## Context

CI has to be reused by every app in this repository and copied into every repository built from it
([ADR-0005](0005-repository-layout-and-shared-tooling.md)). Logic written inline in workflow YAML cannot be run on
a laptop, cannot be unit-tested, and gets copied from one workflow to the next. A failure in CI must be
reproducible locally with the same commands.

## Decision

1. **Four layers:**

   | Layer | Files | Holds |
   |---|---|---|
   | trigger workflows | `.github/workflows/pr.yml`, `main.yml`, `release.yml`, `release-please.yml`, `nightly.yml`, `config-lint.yml` | events, concurrency, permissions, the job graph, the project's parameters |
   | reusable stage workflows | `.github/workflows/_gradle-build.yml`, `_integration-test.yml`, `_docker-publish.yml`, `_kind-deploy.yml`, `_deploy-dev.yml` | one pipeline stage each, with typed inputs and outputs |
   | composite actions | `.github/actions/{setup-build-env,registry-login,affected-matrix,compose-stack,kind-cluster,setup-kube-tools,helm-deploy-instance}` | reusable step sequences |
   | scripts and Gradle tasks | `scripts/`, `scripts/ci/`, `test-infra/compose/stack.sh`, `test-infra/kind/kind.sh`, `./gradlew …` | the logic |

2. **Logic lives in scripts and Gradle tasks.** A workflow step SHOULD be a short call into the bottom layer.
   Everything CI decides can be reproduced on a laptop:
   - `./gradlew build configLint`;
   - `python3 scripts/ci/affected.py --base origin/main`;
   - `test-infra/compose/stack.sh up --project :<app>`;
   - `scripts/run-compose.sh … --dry-run`;
   - `scripts/pool-deploy.sh … plan`.
3. **Stages exchange JSON.** Reusable workflows pass data as JSON outputs: the project list, the integration-test
   matrix, `images` (Gradle project → `repository:tag@sha256:<digest>`), and `image-tags` (project → tag set).
   Images travel by digest only.
4. **Least privilege.** Each workflow declares `contents: read`. A job adds only what it needs:
   - `packages: write` to push;
   - `deployments: write` to record a deployment;
   - `contents: write` only in the release tooling ([ADR-0020](0020-branching-protection-and-merge-rules.md)).

   Secrets reach only the steps that use them.
5. **Concurrency.**
   - Pull-request runs cancel superseded runs of the same pull request.
   - `main`, release and deploy runs queue and are never cancelled: a cancelled deploy is worse than a late one.
   - Deploys are serialized per env.
6. **Build environment.**
   - The Gradle job runs in the `ci-build` image (`<registry>/base/ci-build`, resolved to a digest) when that image
     is published, else on the runner with `actions/setup-java`.
   - The container runs as the runner's UID and joins the Docker socket's group, so images are built by the host
     engine without running as root.
   - Only GitHub-hosted, ephemeral runners are used. A self-hosted runner is allowed only on a host that GitHub
     cannot reach for deploys.
7. **Pinned tools.** Actions are pinned by major version. The linters are installed at exact versions
   (hadolint, ShellCheck, actionlint). The Kubernetes tools are installed at the versions in
   `test-infra/kind/versions.env`, each verified by sha256.
8. **The `lint` job** runs on every non-docs change:
   - hadolint on every Dockerfile;
   - ShellCheck (severity warning) on every `*.sh`;
   - the plain-bash script tests `scripts/test/*-test.sh`;
   - actionlint.
9. **Reporting.** Every job writes a job summary for people. Reports and diagnostics are uploaded as artifacts,
   kept 7 days for pull requests, 14 for `main` and 30 for SBOMs. Unit and integration test results are summarized
   by `scripts/ci/junit-summary.sh`.
10. **Registry access** goes through the `registry-login` action. Token mode uses `GITHUB_TOKEN`. An OIDC mode for
    an enterprise repository manager is stubbed.

## Alternatives considered

- **Monolithic workflows.** The same steps repeated in each workflow, edited N times.
- **Logic inline in YAML.** Untestable, not runnable locally, and reviewed in the least readable form.
- **A CI-specific build tool or a third-party orchestration service.** One more system, with no way to run its
  pipeline on a laptop.

## Consequences

- Copying CI into a new repository means copying the shared tooling and setting the project values.
- A CI fix is usually a script fix, testable without pushing.
- The trigger workflows still hold this project's values: the dev env `us-dev`, the app `source-database` for the
  system test and the kind deployment test, and the registry namespace in `_gradle-build.yml` and `nightly.yml`.
  They should read them from `platform.yml` or derive them (known gap).
