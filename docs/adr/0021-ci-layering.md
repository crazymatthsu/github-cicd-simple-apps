# ADR-0021 — CI has four layers: thin trigger workflows, reusable stage workflows, composite actions, and scripts that run anywhere

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | everything under `.github/` and the scripts it calls |
| Enforced by | actionlint (with ShellCheck on `run:` blocks), ShellCheck and the script tests in the `lint` job; review for logic in YAML |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md), [ADR-0020](0020-branching-protection-and-merge-rules.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0029](0029-release-and-promotion.md) |

**In short:** CI is built in four layers, and the logic lives in the bottom one: scripts and Gradle tasks. The
workflows and actions above it mostly connect events, permissions and jobs to those scripts. So whatever CI
decides can be rerun on a laptop, and the same CI can be copied into a new repository.

## Context

Every app in this repository reuses the same CI, and every repository built from this one copies it
([ADR-0005](0005-repository-layout-and-shared-tooling.md)). Logic written inline in workflow YAML gets in the way of
both. It cannot run on a laptop or be unit-tested, and it gets copied from one workflow to the next. A failure in
CI must also be reproducible locally, with the same commands.

## Decision

1. **Four layers.** Each layer has its own files and its own job:

   | Layer | Files | Holds |
   |---|---|---|
   | trigger workflows | `.github/workflows/pr.yml`, `main.yml`, `release.yml`, `release-please.yml`, `nightly.yml`, `config-lint.yml` | events, concurrency, permissions, the job graph, the project's parameters |
   | reusable stage workflows | `.github/workflows/_gradle-build.yml`, `_integration-test.yml`, `_docker-publish.yml`, `_kind-deploy.yml`, `_deploy-dev.yml` | one pipeline stage each, with typed inputs and outputs |
   | composite actions | `.github/actions/{platform-manifest,setup-yq,setup-build-env,registry-login,affected-matrix,compose-stack,kind-cluster,setup-kube-tools,helm-deploy-instance}` | reusable step sequences |
   | scripts and Gradle tasks | `scripts/`, `scripts/ci/`, `test-infra/compose/stack.sh`, `test-infra/kind/kind.sh`, `./gradlew …` | the logic |

   A call usually goes down the layers in order, and a laptop runs the bottom layer directly:

   ```mermaid
   flowchart TD
     subgraph gha ["GitHub Actions"]
       trigger["Trigger workflows<br/>events, permissions, job graph"]
       stage["Reusable stage workflows<br/>one pipeline stage each"]
       action["Composite actions<br/>reusable step sequences"]
     end
     logic["Scripts and Gradle tasks<br/>the logic"]
     laptop["Developer laptop"]
     trigger -->|calls| stage
     stage -->|calls| action
     action -->|calls| logic
     laptop -->|runs the same commands| logic
   ```

2. **Logic lives in scripts and Gradle tasks.** A workflow step SHOULD be a short call into the bottom layer. That
   way, everything CI decides can be reproduced on a laptop:
   - `./gradlew build configLint`;
   - `python3 scripts/ci/affected.py --base origin/main`;
   - `test-infra/compose/stack.sh up --project :<app>`;
   - `scripts/run-compose.sh … --dry-run`;
   - `scripts/pool-deploy.sh … plan`.
3. **Stages exchange JSON.** Reusable workflows pass data to each other as JSON outputs:
   - the project list;
   - the integration-test matrix;
   - `images`: Gradle project → `repository:tag@sha256:<digest>`;
   - `image-tags`: project → tag set.

   Images travel by digest only.
4. **Least privilege.** Each workflow declares `contents: read`. A job adds only the permissions it needs:
   - `packages: write` to push;
   - `deployments: write` to record a deployment;
   - `contents: write` only in the release tooling ([ADR-0020](0020-branching-protection-and-merge-rules.md)).

   Secrets reach only the steps that use them.
5. **Concurrency.**
   - A new pull-request run cancels the superseded runs of the same pull request.
   - `main`, release and deploy runs queue and are never cancelled: a cancelled deploy is worse than a late one.
   - Deploys are serialized per env.
6. **Build environment.**
   - The Gradle job runs in the `ci-build` image (`<registry>/base/ci-build`, resolved to a digest) when that image
     is published. Otherwise it runs on the runner, with `actions/setup-java`.
   - The container runs as the runner's UID and joins the group that owns the Docker socket. So the host engine
     builds the images, and nothing runs as root.
   - Only GitHub-hosted, ephemeral runners are used. A self-hosted runner is allowed only on a host that GitHub
     cannot reach for deploys.
7. **Pinned tools.** Actions are pinned by major version. The linters (hadolint, ShellCheck, actionlint) are
   installed at exact versions. The Kubernetes tools are installed at the versions in `test-infra/kind/versions.env`,
   and each one is verified by its sha256.
8. **The `lint` job** runs on every change that is not docs-only:
   - hadolint on every Dockerfile;
   - ShellCheck (severity warning) on every `*.sh`;
   - the plain-bash script tests `scripts/test/*-test.sh`;
   - actionlint.
9. **Reporting.** Every job writes a job summary for people to read. Reports and diagnostics are uploaded as
   artifacts, kept 7 days for pull requests, 14 for `main` and 30 for SBOMs. `scripts/ci/junit-summary.sh`
   summarizes the unit and integration test results.
10. **Registry access** goes through the `registry-login` action. Token mode uses `GITHUB_TOKEN`. An OIDC mode, for
    an enterprise repository manager, is stubbed.

## Alternatives considered

- **Monolithic workflows.** The same steps are repeated in each workflow, so every change is made N times.
- **Logic inline in YAML.** It cannot be tested or run locally, and reviewers read it in its least readable form.
- **A CI-specific build tool or a third-party orchestration service.** One more system, and no way to run its
  pipeline on a laptop.

## Consequences

- Copying CI into a new repository means copying the shared tooling and setting the project values.
- A CI fix is usually a script fix, which can be tested without pushing.
- The workflows read the registry, the dev envs and the reference app from `platform.yml` through the
  `platform-manifest` action ([ADR-0030](0030-platform-yml-declares-every-project-value.md)). Only `release.yml`'s
  version bump still names project values, `config/us-qa` and the apps `source-*` (known gap).
