# ADR-0034 — `main` runs a test stage only when the repository has what it needs

| | |
|---|---|
| Status | Accepted. Supersedes in part rule 2 of ADR-0023 and rule 6 of ADR-0025 (rule 6) |
| Date | 2026-10-06 |
| Applies to | every repository built from this one; the job conditions of `main.yml`; `test-infra/compose/versions.env` |
| Enforced by | the job conditions of `main.yml` (actionlint checks them); `_integration-test.yml` (fails a system test whose image is not pinned by digest) |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0029](0029-release-and-promotion.md), [ADR-0030](0030-platform-yml-declares-every-project-value.md), [ADR-0031](0031-ci-derives-the-projects-from-the-build-files.md) |

**In short:** `main.yml` runs the component integration tests only when a project has them, and the system test
only when `test-infra/compose/versions.env` declares the platform's server image. `publish` follows the test stages
that ran and passed, and never a failed or cancelled one. A repository built from this one without integration
tests, or without a server image, gets a green first `main` run and edits no shared tooling.

## Context

[ADR-0023](0023-main-pipeline-build-once-test-publish.md) rule 2 puts both test stages in every `main` run, and
[ADR-0025](0025-integration-tests-on-compose-stacks.md) rule 6 runs the system level there. Both depend on project
files ([ADR-0005](0005-repository-layout-and-shared-tooling.md)):

- The integration-test matrix lists the projects that apply `buildlogic.integration-test`
  ([ADR-0031](0031-ci-derives-the-projects-from-the-build-files.md)). When none does, the list is empty, and GitHub
  fails a run on an empty matrix. `pr.yml` skips its integration tests then; `main.yml` did not.
- The system level needs `DEEPHAVEN_SERVER_IMAGE` in `versions.env`, or the server image built in the run. Without
  either, `_integration-test.yml` exits 2.

So the first `main` run of such a repository failed, and it published and deployed nothing.

## Decision

1. **Integration tests run when a project has them.** The `integration-test` job MUST run when the build's
   `it-projects` list is not empty, and MUST NOT run when it is empty.
2. **The system test runs when the repository declares a system image.** The `platform` job reads
   `DEEPHAVEN_SERVER_IMAGE` from `versions.env` as `_integration-test.yml` reads it, and hands it on as
   `system-image`. `system-test` MUST run when that value is not empty and the integration tests passed, and MUST
   NOT run otherwise.
   - A declared image MUST be pinned by digest; the system test fails on any other value.
   - The system test runs the reference app's integration tests, so a repository that declares the image MUST give
     its reference app integration tests.
   - A repository that builds the server image itself still declares the line. The system test then uses the image
     built in the run ([ADR-0025](0025-integration-tests-on-compose-stacks.md)).
3. **The tree is the only switch.** The build files decide rule 1 and `versions.env` rule 2. A key of `platform.yml`
   or a repository variable MUST NOT turn a stage on or off
   ([ADR-0030](0030-platform-yml-declares-every-project-value.md) rule 1).
4. **Publish never follows a failure.** `publish` MUST run only when `platform`, `build` and `config-lint` passed and
   each test stage passed or was skipped under rule 1 or 2. A failed or cancelled stage MUST stop it. It needs
   `platform` and `integration-test` directly, because a failure of either also skips `system-test`.
5. **The jobs after publish name the job before them.** `kind-deploy` and `deploy-dev` MUST state their condition on
   the result of the job they follow. GitHub applies a skip to every later job of a chain unless its condition says
   otherwise, and a stage skipped by design MUST NOT skip the deploys.
6. **What this decision supersedes.** In [ADR-0023](0023-main-pipeline-build-once-test-publish.md) rule 2,
   `integration-test` and `system-test` run under rules 1 and 2, and `publish` runs under rule 4. In
   [ADR-0025](0025-integration-tests-on-compose-stacks.md) rule 6, the system level runs on `main` under rule 2.

## Alternatives considered

- **A key in `platform.yml`, such as `system_test: false`.** The tree already says whether a stage can run, and a
  key could disagree with it.
- **Skip inside `_integration-test.yml`.** The job would start, log in and set up before it found nothing to test,
  and the run would show a system test that passed without running.
- **Keep both stages mandatory.** A repository built from this one would have to invent a server image and an
  integration test before its first `main` run could pass.

## Consequences

- This repository has integration tests in every app and declares `DEEPHAVEN_SERVER_IMAGE`, so every `main` run
  still runs every stage, and `publish` still waits for the system test.
- A repository without a server image publishes after the component tests. One without integration tests publishes
  after the build, the unit tests and config-lint.
- A skipped stage shows as skipped, and the run still succeeds, so `release.yml` can release the commit
  ([ADR-0029](0029-release-and-promotion.md)).
- The variable keeps Deephaven's name, `DEEPHAVEN_SERVER_IMAGE`. Decoupling the integration tests from Deephaven is
  known gap G12.
