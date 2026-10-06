# ADR-0023 — `main` builds once, tests the images it built, then publishes them

| | |
|---|---|
| Status | Accepted. Rule 2 superseded in part by [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) and [ADR-0044](0044-no-system-test-one-integration-test-level.md) |
| Date | 2026-10-04 |
| Applies to | `main.yml`, on `main` and `hotfix/**` |
| Enforced by | the job graph of `main.yml`; `_integration-test.yml` (digest-pinned image required); `_docker-publish.yml` (refuses to move an immutable tag); `release.yml` (releases only a commit whose `main.yml` run succeeded) |
| Related | [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0021](0021-ci-layering.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0029](0029-release-and-promotion.md) |

**In short:** Each push to `main` builds every image once, tests exactly those images, and only then publishes them
and deploys dev. Later jobs pass the images along by digest and never rebuild them. So what runs in dev, and what a
release ships, is bit for bit the image that passed the tests.

## Context

What is deployed and released must be the exact image that passed the tests. Rebuilding at a later stage would
produce different bits. Publishing before the tests would let consumers pick up an untested build.

## Decision

1. **Trigger.** A push to `main` or `hotfix/**`, which happens only when a pull request is merged
   ([ADR-0020](0020-branching-protection-and-merge-rules.md)). Runs are serialized per branch and never cancelled.
2. **The job graph.** The jobs, roughly in the order they run:

   > **Superseded in part by [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) rule 6.**
   > `integration-test` and `system-test` run only when the repository has them, and `publish` follows the stages that
   > ran, never a failed or cancelled one.

   > **Superseded in part by [ADR-0044](0044-no-system-test-one-integration-test-level.md) rule 5.** There is no
   > `system-test`: `publish` follows `integration-test` and `config-lint`.

   - **build:** builds every project and runs the unit tests. Images are pushed with the `main` tag set
     ([ADR-0010](0010-image-tags-digests-promotion-retention.md)). Tags already on `HEAD` are ignored, so the
     version is always the `-rc` form.
   - **config-lint:** needs no other job, so it starts together with the build.
   - **integration-test:** the component integration tests of every app that has them, against the digests just
     built ([ADR-0025](0025-integration-tests-on-compose-stacks.md)).
   - **system-test:** the reference scenario against those digests and the organisation's own server image, pinned
     by digest in `test-infra/compose/versions.env`.
   - **publish:** runs after the system test and config-lint pass, and re-asserts the tag set on the tested
     digests. Convenience tags, such as `main`, move here; immutable tags are verified.
   - **kind-deploy:** the provisional Helm deployment test against the published digests
     ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)).
   - **deploy-dev:** deploys the dev envs ([ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md)).

   Each arrow is a `needs:` edge of `main.yml`, and the dotted ones let a job read the digests that `build` pushed:

   ```mermaid
   flowchart LR
     build["build"] --> it["integration-test<br/>component, every app"]
     it --> sys["system-test"]
     sys --> pub["publish"]
     cfg["config-lint"] --> pub
     pub --> kind["kind-deploy"]
     kind --> dev["deploy-dev<br/>main only"]
     pub --> dev
     build -.-> sys
     build -.-> pub
     build -.-> kind
     build -.-> dev
   ```

3. **Images move by digest only.** From the build on, images move between jobs only as
   `repository:tag@sha256:<digest>`. No job rebuilds an image, and no job resolves a floating tag (one that can
   move to another image).
4. **Hotfix branches** run the same graph, without `main`'s convenience tag and without the dev deploy.
5. **Releases depend on it.** A release may only promote a commit whose `main.yml` run succeeded
   ([ADR-0029](0029-release-and-promotion.md)).

## Alternatives considered

- **Build again for each stage or for the release.** Different bits from those tested, and a slower pipeline.
- **Publish first, test after.** Consumers and dev could pick up an image that later fails its tests.
- **Deploy to dev from pull requests.** Dev would run unmerged code and stop meaning "what `main` is".

## Consequences

- A green `main` run means its images are tested, published and running in dev. Any of them can be released.
- A failing system test blocks publishing, the dev deploy and every release of that commit.
- The build pushes `main` before the tests (known gap, [ADR-0010](0010-image-tags-digests-promotion-retention.md)).
- The system test's project, the kind test's app and the dev envs come from `platform.yml` ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).
