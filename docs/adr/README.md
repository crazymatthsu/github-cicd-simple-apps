# The repository contract

This folder is the contract that every Spring Boot app in this repository, and every repository built from this
one, follows. It is what lets those apps reuse the same CI/CD workflows, configuration management and runtime
operations. Each rule is an ADR — an architecture decision record. The format and the rules about the rules are in
[ADR-0001](0001-adrs-are-the-repository-contract.md).

How to read it:

- **New here:** start with ADR-0002 to ADR-0006 (what a project, an env, an instance and a repository are), then the
  group you work in.
- **Adding an app, adding an instance, or creating a repository:** follow the checklists below.
- **Changing a convention:** write the ADR that supersedes the old one, in the same pull request
  ([ADR-0001](0001-adrs-are-the-repository-contract.md)).

This index is the living part of the folder: ADR statuses, checklists, known gaps and open decisions are kept up to
date here. The ADRs themselves change only by supersession.

## The ADRs

| ADR | Rule in one line | Status |
|---|---|---|
| **Foundations** | | |
| [0001](0001-adrs-are-the-repository-contract.md) | Decisions are numbered ADRs with MUST/SHOULD rules and an "Enforced by" line. ADR-0001 to ADR-0999 are the shared contract; a repository's own decisions start at ADR-1000. | Accepted |
| [0002](0002-one-repository-one-project-one-release-line.md) | A repository is one project of Spring Boot apps and libraries, released together as `vX.Y.Z`. `platform.yml` declares only what the tree cannot derive. | Accepted |
| [0003](0003-identity-tuple-names-every-instance.md) | `<env>/<flow>/<AppName>/<AppInstance>` is the configuration path and the source of every name. | Accepted |
| [0004](0004-environments-and-runtimes.md) | Only local and dev are configured and deployed here. qa, uat, prod and parallel are configured and deployed from a separate configuration repository, promoted by pull request. On-prem compose runs every env until EKS. | Accepted |
| [0005](0005-repository-layout-and-shared-tooling.md) | One skeleton for every repository. Shared tooling is copied unchanged, project files are the project's own, and changes to the tooling are made here first. | Accepted |
| [0006](0006-apps-and-framework-modules.md) | `apps/<AppName>/` holds an app's code and only the infrastructure that differs between apps. `framework/<name>/` holds shared libraries, never deployed. | Accepted |
| **Build and artifacts** | | |
| [0007](0007-gradle-build-with-convention-plugins.md) | Convention plugins in `build-logic/`, one version catalog and the Spring Boot BOM give reproducible, cached builds; a module declares only its plugins and dependencies. | Accepted |
| [0008](0008-versions-derived-from-git.md) | Versions come from git tags and Conventional Commits on every build. No version file exists. | Accepted |
| [0009](0009-one-shared-image-definition.md) | One Dockerfile and a three-file build context for every app; images are non-root and layered, and Gradle builds them with docker or podman. | Accepted |
| [0010](0010-image-tags-digests-promotion-retention.md) | Images are `<registry>/<project>/<AppName>` with immutable version and sha tags. They move by digest, are promoted by re-tagging, and the retention sweep keeps everything in use. | Accepted |
| **Configuration** | | |
| [0011](0011-configuration-tree-and-spring-layers.md) | Spring layers apply jar < flow < app < instance < secrets. Layers are files named by level, only `application.<layer>.yml` reaches the container, and nothing is shared above the flow. | Accepted |
| [0012](0012-compose-template-and-generated-env.md) | One compose template plus structural overrides. The env layers merge into one generated, annotated env per instance, from allow-listed variables. | Accepted |
| [0013](0013-secrets.md) | Secrets never enter git, the layers, the images or the bundles. They are passed through from the shell or mounted at `/secrets/`, masked wherever printed, and scanned for. | Accepted |
| [0014](0014-config-lint-enforces-the-config-contract.md) | `./gradlew configLint` enforces the configuration rules with numbered checks, the same on a laptop and in CI. | Accepted |
| **Runtime operations** | | |
| [0015](0015-actuator-health-and-metrics-contract.md) | Every app exposes `health`, `info`, `prometheus` and `connectorconfig` on port 8080. Readiness is `readinessState` plus `connector`, the identity is on every meter, and one test checks all of it. | Accepted |
| [0016](0016-logging-and-startup-configuration-summary.md) | Logs go to stdout with the identity on every line. The masked effective configuration is available at start-up, from an endpoint, and offline. | Accepted |
| [0017](0017-run-compose-operations-cli-and-runtime-posture.md) | `run-compose.sh` operates every compose-run instance of this repository — laptop, CI, dev host — with safety rules and an audit line; the shared template hardens every container. | Accepted |
| [0018](0018-on-prem-host-layout-versioned-bundles.md) | Hosts keep `/apps/<user>/versions/<project>/<version>/` per deploy, with `current` the live one. Activation is atomic, and rollback points `current` back. | Accepted |
| [0019](0019-kubernetes-and-helm-are-provisional.md) | Charts, Helm values, the Helm deploy script, check 12 and the kind tier are kept working, not extended, until the EKS design. | Accepted |
| **Source control** | | |
| [0020](0020-branching-protection-and-merge-rules.md) | `main` and `hotfix/*` change only by squash-merged pull request with `pr-gate` green. Pull-request titles are Conventional Commits, and no workflow writes to protected branches. | Accepted |
| **CI** | | |
| [0021](0021-ci-layering.md) | Thin trigger workflows call reusable stage workflows, then composite actions, then scripts and Gradle tasks that run on a laptop. Least privilege, and JSON between stages. | Accepted |
| [0022](0022-pull-request-pipeline.md) | Affected projects come from `affected-map.yml`: a fast tier on push, a full tier on pull requests and the merge queue. `pr-gate` is the only required check. | Accepted |
| [0023](0023-main-pipeline-build-once-test-publish.md) | Build once, run the component and system tests on those digests, then publish, then deploy dev. | Accepted |
| [0024](0024-ephemeral-ci-environments.md) | Each job gets its own labelled stack or cluster, torn down in `always()` steps; a leak check and a nightly drill prove the teardown. | Accepted |
| **Testing** | | |
| [0025](0025-integration-tests-on-compose-stacks.md) | One `stack.sh` serves laptops and CI. Stacks are declared per project, the app under test runs as deployed, and tests run at a component and a system level. | Accepted |
| [0026](0026-integration-test-data-and-comparison.md) | Test cases are `test-infra/testdata/<AppName>/<case>/`: a manifest, inputs, and canonical JSON Lines, compared by shared comparators with explicit tolerances. | Accepted |
| **CD and release** | | |
| [0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md) | Every tested `main` commit deploys dev from a per-flow inventory. The configuration tree declares intent; a GitHub Deployment records what happened, with nothing written back to git. | Accepted |
| [0028](0028-host-pool-deployment.md) | Placement is pinned, else discovered, else assigned. Instances start from a new version, and every box activates it only when all are healthy; otherwise everything returns to `current`. | Accepted |
| [0029](0029-release-and-promotion.md) | release-please tags; `release.yml` re-tags the tested digests and attaches SBOMs. The promoted envs change only by pull request in the configuration repository. | Accepted |

## Glossary

| Term | Meaning |
|---|---|
| project | the one release line of a repository: its apps and libraries ([ADR-0002](0002-one-repository-one-project-one-release-line.md)) |
| app | a deployable Spring Boot service, `apps/<AppName>/`, one image |
| library | a module under `framework/`, built and released with the apps, never deployed |
| shared tooling | the files copied unchanged into every repository built from this one ([ADR-0005](0005-repository-layout-and-shared-tooling.md)) |
| project values | what the shared tooling needs to know about a project; declared in `platform.yml` |
| env | `local`, or `<region>-<stage>` |
| stage | `dev`, `qa`, `uat`, `prod`, `parallel` |
| dev env | an env this repository configures and deploys (`dev_envs`) |
| promoted env | `qa`, `uat`, `prod` or `parallel`: configured in and deployed from the configuration repository, immutable tags only ([ADR-0004](0004-environments-and-runtimes.md)) |
| configuration repository | the separate repository holding the configuration of the promoted envs |
| flow, cluster | a business flow; one flow in one env is one cluster, with its own boxes and inventory |
| instance | one configured pipeline of an app in a flow: `config/<env>/<flow>/<AppName>/<AppInstance>/` |
| layer | one level of configuration (jar, flow, app, instance, secrets) and the files at that level ([ADR-0011](0011-configuration-tree-and-spring-layers.md)) |
| combined env | the generated `.run/…/compose.env` of one instance ([ADR-0012](0012-compose-template-and-generated-env.md)) |
| deploy inventory | a dev flow's `workflows-config.yml`: its pool and one target per instance |
| host pool, box | the bare-metal hosts of one flow; any instance of the flow can run on any of them |
| host bundle, version directory | the runtime of one `<env>/<flow>` synced to a box as `/apps/<user>/versions/<project>/<version>/` ([ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)) |

## Checklists

### Add an app to this repository ([ADR-0006](0006-apps-and-framework-modules.md))

1. `apps/<AppName>/build.gradle.kts`: apply `buildlogic.spring-boot-app`, `buildlogic.docker-image` and
   `buildlogic.integration-test`. Depend on `project(":connectors-framework")` and, for tests, on its test fixtures.
2. `src/main/resources/application.yml`:
   - `spring.application.name: <AppName>`;
   - the import list of [ADR-0011](0011-configuration-tree-and-spring-layers.md);
   - the `server`, `management` and `logging` blocks, copied from an existing app
     ([ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md)).
3. The main class calls `ConnectorApplication.run(<Main>.class, args)`. One unit test extends
   `AbstractConnectorApplicationTest`.
4. Configuration in `local`:
   - `config/local/<flow>/<AppName>/application.app.yml` and `_helm-values.app.yaml`;
   - one instance directory with `application.instance.yml`, `_helm-values.instance.yaml` and
     `_docker-compose.instance.env`. The env file holds `IMAGE_TAG=local`, the identity restating the path, and a
     free `ACTUATOR_HOST_PORT`.
5. In each dev env: the same files, with `IMAGE_TAG=main`, plus a target in the flow's `workflows-config.yml`.
6. Register the app by hand (known gap G10):
   - `.github/affected-map.yml`: a `projects` entry and a `paths` glob;
   - `test-infra/compose/stacks.yml`: its dependency stacks.
7. Integration tests in `src/integrationTest/java`, and a test case in `test-infra/testdata/<AppName>/<case>/`
   ([ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0026](0026-integration-test-data-and-comparison.md)).
8. A chart: copy `apps/<other>/helm/<other>/` to `apps/<AppName>/helm/<AppName>/` and rename it. Required while Helm
   is provisional ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)).
9. Only if needed:
   - `docker/docker-compose.override.yml` for secret pass-through ([ADR-0013](0013-secrets.md));
   - `scripts/smoke.sh` for app-specific smoke checks.
10. Write `apps/<AppName>/README.md`.
11. Verify:
    - `./gradlew build configLint`;
    - `./gradlew :<AppName>:integrationTest`;
    - `scripts/run-compose.sh local <flow> <AppName> <AppInstance> validate`.

### Add an instance ([ADR-0003](0003-identity-tuple-names-every-instance.md), [ADR-0011](0011-configuration-tree-and-spring-layers.md))

1. Create `config/<env>/<flow>/<AppName>/<AppInstance>/` with three files:
   - `application.instance.yml`;
   - `_docker-compose.instance.env`: the identity restating the path, `IMAGE_TAG`, and an `ACTUATOR_HOST_PORT` that
     is free on the instance's boxes;
   - `_helm-values.instance.yaml`.
2. In a dev env: add a target for it to the flow's `workflows-config.yml`.
3. Verify: `./gradlew configLint`, then `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> start --dry-run`.

### Create a repository from this one ([ADR-0005](0005-repository-layout-and-shared-tooling.md))

1. Copy this repository at a release tag. Keep the shared tooling unchanged.
2. Set the project values:
   - the repository name, `rootProject.name` and `platform.yml` `projects[0].name`, all equal;
   - `registry` and `dev_envs` in `platform.yml`;
   - `component` in `release-please-config.json`;
   - until G7 is closed, the hard-coded values listed there.
3. Replace the project files with the new project's own:
   - `apps/`, the domain code under `framework/`, `config/`;
   - `test-infra/testdata/`, the dependency stacks, `versions.env`, `stacks.yml`;
   - `.github/affected-map.yml`, `.github/CODEOWNERS`, `README.md`.
4. Start a new release line: an empty `CHANGELOG.md`, a reset `.release-please-manifest.json`, and no tags.
5. Keep `docs/adr/0001-…` to `0999-…` unchanged. Record the repository's own decisions from ADR-1000, and update
   `docs/README.md`.
6. Apply the repository settings of [ADR-0020](0020-branching-protection-and-merge-rules.md).
7. Verify: the first pull request gets a green `pr-gate`, and the first `main` run publishes the images and deploys
   dev.

## Known gaps

Places where the tree does not conform to an accepted ADR yet. A pull request that closes a gap removes its row; one
that opens a gap adds a row.

| # | Gap | ADR |
|---|---|---|
| G2 | `ConnectorIdentity` does not accept the stages `uat` and `parallel`, so the app image refuses to start in those envs, wherever it is deployed. Config-lint allows only the regions `us` and `jp`; the other implementations accept any two letters. | [0003](0003-identity-tuple-names-every-instance.md) |
| G3 | Config-lint check 1 does not know the stages `uat` and `parallel`, and check 10 treats only `qa` and `prod` as promoted envs that require immutable tags. This matters once the configuration repository reuses config-lint. | [0010](0010-image-tags-digests-promotion-retention.md), [0014](0014-config-lint-enforces-the-config-contract.md) |
| G4 | `release.yml`'s bump job commits to `config/us-qa` in this repository; it must open the pull request in the configuration repository. | [0029](0029-release-and-promotion.md) |
| G5 | This repository's config-lint accepts promoted-env directories, and CODEOWNERS still carries `config/*-qa/` and `config/*-prod/` rules. | [0004](0004-environments-and-runtimes.md), [0011](0011-configuration-tree-and-spring-layers.md) |
| G6 | `us-dev/cash/source-database/positions-db-to-deephaven` is a `kind: helm` target on the throwaway `kind-ci` cluster, so it runs nowhere after the deploy job. | [0004](0004-environments-and-runtimes.md), [0019](0019-kubernetes-and-helm-are-provisional.md) |
| G7 | Project values are hard-coded in shared tooling: the registry `ghcr.io/crazymatthsu` (`_gradle-build.yml`, `nightly.yml`, `setup-build-env`, `buildlogic.docker-image`, the Dockerfile's base image and source label); `group = "com.example.connectors"`; `us-dev`, `:source-database` and the nightly drill image in the trigger workflows. | [0002](0002-one-repository-one-project-one-release-line.md), [0005](0005-repository-layout-and-shared-tooling.md), [0021](0021-ci-layering.md) |
| G8 | The flows `cash deriv swap` are hard-coded in four places, and the identity vocabulary is not declared in `platform.yml`. | [0003](0003-identity-tuple-names-every-instance.md) |
| G9 | `platform.yml`'s `dev_envs`, `apps_dir` and `kinds` are read by nothing, and nothing checks that `rootProject.name` equals `projects[0].name`. | [0002](0002-one-repository-one-project-one-release-line.md) |
| G10 | `.github/affected-map.yml` and `test-infra/compose/stacks.yml` are maintained by hand. An app missing from the map's `projects` is silently left out of the integration-test matrix, of publishing and of releases. | [0006](0006-apps-and-framework-modules.md), [0022](0022-pull-request-pipeline.md), [0025](0025-integration-tests-on-compose-stacks.md) |
| G11 | The framework mixes the generic operational contract with the connector domain. The `server`, `management` and `logging` blocks are copied into every app, and the secret-property list exists twice (config-lint, `SecretMasker`). | [0006](0006-apps-and-framework-modules.md), [0013](0013-secrets.md), [0015](0015-actuator-health-and-metrics-contract.md), [0016](0016-logging-and-startup-configuration-summary.md) |
| G12 | `buildlogic.integration-test` and `it-runner.yml` hard-wire the Deephaven client and the Deephaven and SQL Server endpoints. | [0007](0007-gradle-build-with-convention-plugins.md), [0025](0025-integration-tests-on-compose-stacks.md) |
| G13 | The base images and the system test's server image are built outside this repository. `setup-build-env`'s bootstrap path expects `docker/base/<name>/Dockerfile`, which does not exist here. | [0009](0009-one-shared-image-definition.md) |
| G14 | The build job pushes `main` before any test, so a failed run leaves `main` on an untested build. The build should push with `-PpushConvenienceTags=false` and leave `main` to publish. | [0010](0010-image-tags-digests-promotion-retention.md), [0023](0023-main-pipeline-build-once-test-publish.md) |
| G15 | Merge commits are allowed: 12 of 27 commits are merges, and `CHANGELOG.md` lists each change twice. The rulesets should allow squash merges only. | [0020](0020-branching-protection-and-merge-rules.md) |
| G16 | No CI check validates pull-request titles as Conventional Commits. | [0008](0008-versions-derived-from-git.md), [0020](0020-branching-protection-and-merge-rules.md) |
| G17 | Pull requests and tags created with `GITHUB_TOKEN` (release, version bump) start no workflow, so `pr-gate` never reports on them. A GitHub App token is needed. | [0020](0020-branching-protection-and-merge-rules.md), [0029](0029-release-and-promotion.md) |
| G18 | A hotfix branch and `main` can compute the same `-rc.<n>` version, and `pushImage` overwrites an existing tag: immutability is enforced only when re-tagging. | [0010](0010-image-tags-digests-promotion-retention.md), [0020](0020-branching-protection-and-merge-rules.md) |
| G19 | The deploy user's forced command is not implemented, and no boxes exist yet (deploys use the `local` transport). A flow without a pool gets only a validated dry run. | [0018](0018-on-prem-host-layout-versioned-bundles.md), [0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [0028](0028-host-pool-deployment.md) |
| G20 | Config-lint checks 7 (merged configuration against metadata) and 8 (parity across envs) are not implemented. | [0014](0014-config-lint-enforces-the-config-contract.md) |
| G21 | Comments in code and configuration, and the READMEs outside `docs/`, cite identifiers of retired documents instead of ADR numbers. | [0001](0001-adrs-are-the-repository-contract.md) |
| G22 | Nothing checks that a derived repository's shared tooling is unchanged. | [0005](0005-repository-layout-and-shared-tooling.md) |

## Open decisions

Questions that no ADR answers yet. Each one becomes an ADR when it is decided.

| # | Question | Touches |
|---|---|---|
| O1 | The configuration repository's pipeline: how it validates without app subprojects (config-lint needs the app list from a manifest); how it assembles host bundles from a release's runtime files (scripts, compose template, the apps' overrides and smoke tests at the release tag); how it deploys and records the promoted envs; and so whether the bundled `run-compose.sh` must operate the higher envs (in this repository it refuses them, as it should). | [0004](0004-environments-and-runtimes.md), [0014](0014-config-lint-enforces-the-config-contract.md), [0029](0029-release-and-promotion.md) |
| O2 | How secrets are provisioned and rotated on the boxes of the promoted envs. | [0013](0013-secrets.md) |
| O3 | How repositories built from this one receive updates to the shared tooling: copying per release, a sync job, or extracting it into versioned reusable workflows, actions and a published Gradle plugin. | [0005](0005-repository-layout-and-shared-tooling.md) |
| O4 | The EKS design, superseding ADR-0019: chart structure, values layering, secrets, the kind tier, and how each env moves from compose. | [0019](0019-kubernetes-and-helm-are-provisional.md) |
| O5 | Splitting the framework into a generic app-runtime module (identity, actuator contract, masking, summary) and domain modules. | [0006](0006-apps-and-framework-modules.md), [0015](0015-actuator-health-and-metrics-contract.md) |
| O6 | The dev deploy policy per flow (every merge, or a schedule), and manual deploy and rollback dispatches. | [0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md) |
