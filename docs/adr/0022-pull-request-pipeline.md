# ADR-0022 — Pull requests: test the affected projects in two tiers, with `pr-gate` as the only required check

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | `pr.yml`, `config-lint.yml`, `.github/affected-map.yml`, `scripts/ci/affected.py` |
| Enforced by | `pr-gate` (the only required check, [ADR-0020](0020-branching-protection-and-merge-rules.md)); `affected.py` (an unmapped path counts as shared) |
| Related | [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md), [ADR-0021](0021-ci-layering.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md) |

**In short:** A pull request builds and tests only the projects that its changed files affect, so a change to one
app stays fast. A change to shared code, or to a file the map does not know, tests everything. One job, `pr-gate`,
collects every result and is the only check that branch protection requires.

## Context

A pull request must be fast when it touches one app, and thorough when it touches shared code. A path filter that
skips a job must never let untested code merge. And branch protection must not need an edit every time a job is
added, renamed or skipped.

## Decision

1. **Triggers and tiers.** The fast tier builds no images and starts no containers. The full tier adds the images
   and the tests that run them.
   - **Push** to any branch except `main`, `hotfix/**` and merge-queue branches: the **fast tier**. Affected
     detection runs first. Then three jobs run side by side: `lint`, the build and unit tests of the affected
     projects (no images), and config-lint.
   - **`pull_request`** (opened, synchronize, reopened, labeled) and **`merge_group`**: the fast tier, plus the
     **full tier**:
     - images `pr-<number>-<sha7>` are pushed for the affected apps (pull requests from this repository and the
       merge queue only);
     - the component integration tests of the affected apps run against those images
       ([ADR-0025](0025-integration-tests-on-compose-stacks.md));
     - the kind deployment test runs when `deploy-test` is set and the image it deploys was pushed
       ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)).
   - **Only docs-class paths changed:** nothing is built, and `pr-gate` passes with a docs-only summary.

   `config-lint.yml` also runs on its own for pull requests that touch `config/**`, a chart, the compose template or
   an app's compose override.

   Every other job of `pr.yml` needs `detect-affected`, and `pr-gate` waits for all of them:

   ```mermaid
   flowchart TD
     event["push, pull_request or merge_group"] --> detect["detect-affected"]
     subgraph fast ["Fast tier"]
       lint["lint"]
       build["build and unit tests<br/>plus images in the full tier"]
       cfg["config-lint"]
     end
     subgraph full ["Full tier: pull requests, merge queue"]
       it["component integration tests"]
       kind["kind deployment test<br/>when deploy-test is set"]
     end
     detect --> lint
     detect --> build
     detect --> cfg
     build --> it
     build --> kind
     detect --> gate["pr-gate<br/>always runs"]
     lint --> gate
     build --> gate
     cfg --> gate
     it --> gate
     kind --> gate
   ```

2. **Affected detection.** `scripts/ci/affected.py`, through the `affected-matrix` action, classifies each changed
   path with `.github/affected-map.yml`. The first matching section wins:
   1. `docs` — nothing to build;
   2. `config` — config-lint only;
   3. `shared` — everything: `framework/`, `build-logic/`, Gradle files, `platform.yml`, `docker/`, Dockerfiles,
      `test-infra/`, `scripts/`, `.github/`, `.hadolint.yaml`;
   4. `paths` — the app's own directory selects that app.

   **A path that matches nothing counts as shared,** so an unmapped file can never skip the tests it affects. The
   same rules, for one changed path:

   ```mermaid
   flowchart TD
     path["A changed path"] --> d{"In docs?"}
     d -->|yes| none["Nothing to build"]
     d -->|no| c{"In config?"}
     c -->|yes| cfgonly["config-lint only"]
     c -->|no| s{"In shared?"}
     s -->|yes| every["Every project"]
     s -->|no| p{"Matches a paths glob?"}
     p -->|yes| app["That app"]
     p -->|no, unmapped| every
   ```

   - `deploy-test` is a flag for the kind deployment test. Any path that matches the map's `deploy-test` section
     raises it, and so does a run that selects every project.
   - The label `ci:full` and the merge queue select every project.
   - The map's `projects` section lists every Gradle project. Its flags say whether each one builds an image and
     has integration tests.
3. **`pr-gate` is the only required check.** It always runs, and it fails when:
   - detection failed, or any job it needs failed or was cancelled;
   - in the merge queue, images were not pushed, so the integration tests could not run;
   - in the merge queue, the kind deployment test did not run where it had to.

   A pull request from a fork cannot push images. For it, the gate only warns: the merge queue runs those tests
   before anything lands. (The merge queue is not enabled yet, a known gap.) The push-triggered run of the same commit names itself `push-gate`, so it can never
   satisfy or mask the required check.
4. **Reproducible locally.** `python3 scripts/ci/affected.py --base origin/main` prints what CI will build and test
   for a branch.

## Alternatives considered

- **Build and test everything on every pull request.** Simple, but slow enough that people stop waiting for it.
- **Path filters in `on:`.** A skipped workflow leaves its required check pending forever, or lets a pull request
  merge untested.
- **One required check per job.** Every pipeline change would mean editing the rulesets, and a skipped job would
  block the merge.

## Consequences

- A change to one app tests that app. A change to shared code tests everything. The merge queue always tests
  everything against the real merge result.
- Pull requests from forks run no integration tests before the merge queue.
- `.github/affected-map.yml` is maintained by hand: one `projects` entry and one `paths` glob per app. An app
  missing from `projects` is silently left out of the integration-test matrix, of publishing, and of releases.
  The map should be derived from the build, or checked against it (known gap).
