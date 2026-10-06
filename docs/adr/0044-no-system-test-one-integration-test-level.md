# ADR-0044 — There is no system test: the integration tests run once, against the images pinned in `versions.env`

| | |
|---|---|
| Status | Accepted. Supersedes rule 2 of ADR-0034, and in part rule 2 of ADR-0023, rule 6 of ADR-0025, rule 1 of ADR-0030, rules 4 and 6 of ADR-0034, rule 4 of ADR-0035, rule 1 of ADR-0038 and rule 2 of ADR-0039 (rule 5) |
| Date | 2026-10-06 |
| Applies to | every repository built from this one; `main.yml`, `pr.yml`, `_integration-test.yml`, the `compose-stack` action; `test-infra/compose/versions.env` |
| Enforced by | the job graph of `main.yml` (actionlint checks its conditions); `_integration-test.yml`, which has no `level` input, so a caller that still passes one fails when the run is set up; review |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0024](0024-ephemeral-ci-environments.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md), [ADR-0035](0035-dev-envs-and-reference-app-are-optional.md), [ADR-0038](0038-stacks-publish-their-test-environment.md), [ADR-0039](0039-an-adr-applies-where-its-subject-exists.md) |

**In short:** `main` ran the reference app's integration tests twice: once as every app's tests run, against the
upstream Deephaven server image, and once more, as the "system test", against the organisation's own build of that
image. The second run started the same stack, ran the same test class on the same test data, and differed in one
variable. It is gone. The integration tests run once, against the dependency images that `versions.env` pins, and a
repository whose tests should run against its own build of a dependency pins that build there. The shared
workflows name no dependency any more.

## Context

[ADR-0023](0023-main-pipeline-build-once-test-publish.md) rule 2 and
[ADR-0025](0025-integration-tests-on-compose-stacks.md) rule 6 defined two levels: component, against the upstream
images, in pull requests and on `main` for every app; system, against the organisation's own server image, on
`main` for the reference app. [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) rule 2 made the
system test conditional on `DEEPHAVEN_SERVER_IMAGE` in `versions.env`, and
[ADR-0038](0038-stacks-publish-their-test-environment.md) rule 1 let `_integration-test.yml` keep that one
dependency name, as the override the level needed.

What the system level did, read from `_integration-test.yml`: it checked that its `level` input was `component`
or `system`; at `system` it resolved the server image, from the build's images or from `DEEPHAVEN_SERVER_IMAGE`, and
exported it as `DEEPHAVEN_IMAGE`, which replaced the pin of `versions.env`. Everything else was the same job. The
Gradle plugin does not read the level, the test class is tagged `component` and nothing filters by tag, and the
stack, the seed, the test data and the assertions were those of the component run. In this repository the
organisation's image is the upstream image with the demo CA imported into its trust store, and the tests make no
TLS connection: the demo root has no key, so no leaf certificate exists (`test-infra/ca/README.md`). So the stage
repeated a green test for about three minutes on every `main` run, gated `publish`, the dev deploy and every
release behind it, and was the one place where the shared workflows named a dependency.

The question the stage was meant to answer, "does the app work against the server we actually run", needs no
second stage. The component level already takes its dependency images from `versions.env`.

## Decision

1. **One level.** The integration tests of a project run once per pipeline, against the dependency images that
   `test-infra/compose/versions.env` pins and the app image built in the run
   ([ADR-0025](0025-integration-tests-on-compose-stacks.md) rule 3). There is no system level, no `system-test` job
   in `main.yml`, and no `level` input of `_integration-test.yml`.
2. **`versions.env` pins the images the tests are meant to run against.** A repository whose tests should run
   against its own build of a dependency MUST pin that build, by digest, as the stack's image variable in
   `versions.env`: for the Deephaven stack of this repository, `DEEPHAVEN_IMAGE`. Pull requests and `main` then
   test against it alike. `DEEPHAVEN_SERVER_IMAGE` has no reader, and `versions.env` no longer declares it.
3. **The shared workflows name no dependency.** `main.yml`, `pr.yml`, `_integration-test.yml` and the
   `compose-stack` action MUST NOT name a dependency stack or its image variable, as
   [ADR-0038](0038-stacks-publish-their-test-environment.md) rule 1 already requires of `stack.sh`, the Gradle
   plugin and the compose files. The override that rule 1 kept for the system level is withdrawn.
4. **`publish` follows the stages that ran.** `publish` MUST run when `platform`, `build` and `config-lint` passed
   and `integration-test` passed or was skipped under
   [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) rule 1, and MUST NOT run after a failed or
   cancelled stage. A reference app no longer needs integration tests for the pipeline's sake.
5. **What this decision supersedes:**
   - [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) rule 2 in full: there is no system test to
     switch on; rule 4, in part: `publish` needs no `system-test`; rule 6, in part: its sentence on ADR-0025 rule 6;
   - [ADR-0023](0023-main-pipeline-build-once-test-publish.md) rule 2, in part: `system-test` leaves the job graph,
     and `integration-test` and `config-lint` feed `publish`;
   - [ADR-0025](0025-integration-tests-on-compose-stacks.md) rule 6, in part: the component level is the only
     level, and its dependencies are the images pinned in `versions.env`, upstream or the organisation's own;
   - [ADR-0030](0030-platform-yml-declares-every-project-value.md) rule 1, in part: `projects[0].reference_app` is
     the app of the kind deployment test and the nightly teardown drill;
   - [ADR-0035](0035-dev-envs-and-reference-app-are-optional.md) rule 4, in part: the `system-test` row of its
     table; `reference_app` switches the kind deployment test, the nightly teardown drill and the `public-base` job;
   - [ADR-0038](0038-stacks-publish-their-test-environment.md) rule 1, in part: the override it kept for the system
     level;
   - [ADR-0039](0039-an-adr-applies-where-its-subject-exists.md) rule 2, in part: the same, in its table of
     switches.

## Alternatives considered

- **Keep the stage and make it generic**: a `stacks.yml` declaration naming the stack, the variable and the image
  of a "system" run, read by the workflows. It keeps a second run of the same tests, and the publish condition that
  waits for it, for a difference that one line of `versions.env` expresses.
- **Keep the stage to track upstream**: test against the organisation's build everywhere and against upstream in
  the stage. Tracking upstream is nightly work ([ADR-0024](0024-ephemeral-ci-environments.md) names the version
  matrix as a later drill), not a gate on every merge.
- **Drop it from this repository only.** The stage is shared tooling
  ([ADR-0005](0005-repository-layout-and-shared-tooling.md)): every repository built from this one carried it, and a
  `level` input nobody sets is the kind of switch ADR-0034 rule 3 refuses.

## Consequences

- Every `main` run is one stage shorter, and `publish` waits for `integration-test` and `config-lint` only.
- The reference app's integration tests run once, with every other app's. This repository keeps `DEEPHAVEN_IMAGE`
  on the upstream image: it is public, so a pull request from a fork pulls it, and the organisation's build differs
  from it only by a trust store the tests do not use.
- The workflows and the `compose-stack` action carry no dependency name. Outside the documentation, Deephaven is
  named only in project files: the stack file, `versions.env`, `stacks.yml`, the apps and their test data.
- `_integration-test.yml` lost its `level` input. A caller that still passes it fails when GitHub sets the run up,
  which is the intended way to find it. The pull request of this change carries `!`, so the release is a major
  version ([ADR-0029](0029-release-and-promotion.md)).
- Known gap G13 shrinks to the base images.
