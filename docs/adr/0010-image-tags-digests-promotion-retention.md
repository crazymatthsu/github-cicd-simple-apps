# ADR-0010 — Images are named per project, referenced by digest, promoted by re-tagging, never rebuilt

| | |
|---|---|
| Status | Accepted. Rule 7 superseded in part by [ADR-0032](0032-registry-credentials.md) |
| Date | 2026-10-04 |
| Applies to | every image the pipeline builds, tests, publishes, deploys or deletes |
| Enforced by | `scripts/ci/retag-image.sh` (refuses to move an immutable tag, exit 3; verifies every write); `pushImage` (refuses a local build); `_integration-test.yml` (requires a digest-pinned image); config-lint check 10 (tag policy); `scripts/ci/retention.sh`; `scripts/ci/resolve-image.sh` (a reference to its digest, without a pull: what the jobs hand on) |
| Related | [ADR-0008](0008-versions-derived-from-git.md), [ADR-0009](0009-one-shared-image-definition.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0029](0029-release-and-promotion.md) |

**In short:** An image is built once and never rebuilt. Tests, deploys and releases refer to it by digest: the hash
that identifies its exact content. Promotion only adds tags to that digest, so prod runs exactly what was tested. A
nightly sweep, once enabled, deletes old images, but never one that is released or in use.

## Context

A change is first tested in its pull request. After the merge, `main` builds the images that can be released: it
runs the component and system tests on them and deploys them to dev. A release then takes those same images to the
promoted envs. What runs in prod has to be, bit for bit, what was tested. Every reference has to be traceable to a
commit and a build. And registries fill up unless something deletes what is no longer needed, without deleting
anything in use.

## Decision

1. **Name.** `<registry>/<project>/<AppName>`, with `registry` and the project from `platform.yml`
   ([ADR-0002](0002-one-repository-one-project-one-release-line.md)). Here:
   `ghcr.io/crazymatthsu/github-cicd-simple-apps/<AppName>`.
2. **Tag sets per build kind.** `buildlogic.git-version` computes the tags of each build
   ([ADR-0008](0008-versions-derived-from-git.md)); `release.yml` computes the release set:

   | Build | Tags |
   |---|---|
   | pull request, merge queue | `pr-<number>-<sha7>` |
   | `main` | `<next>-rc.<n>`, `sha-<sha7>`, `main` |
   | `hotfix/<x>` | `<next-patch>-rc.<n>`, `sha-<sha7>` |
   | release (by re-tagging, rule 4) | `X.Y.Z`, `sha-<sha7>`; plus `X.Y`, `X` and `latest` when it is the newest release of that series |
   | laptop | `local`, `<version>` — never pushed (`pushImage` refuses unless `-Pimage.allowLocalPush=true`) |

3. **Immutable and convenience tags.**
   - **Immutable:** version tags, `sha-<sha7>` and `pr-<number>-<sha7>`. Once they exist they MUST NOT move.
   - **Convenience:** `main`, `latest`, `X`, `X.Y`. These MAY move, and only to a tested digest.
4. **Promotion re-tags; nothing is rebuilt.**
   - After the build, every stage passes images as `repository:tag@sha256:<digest>`. Every test, deploy and
     release uses the digest.
   - Promotion writes tags onto an existing digest inside the registry
     (`docker buildx imagetools create --prefer-index=false`) and verifies each write.
   - After the system test, `main` writes its tag set again onto the tested digests
     ([ADR-0023](0023-main-pipeline-build-once-test-publish.md)).
   - A release re-tags the digests of the `main` build it releases, found by `sha-<sha7>`
     ([ADR-0029](0029-release-and-promotion.md)).

   The journey of one change's images, from its pull request to the promoted envs:

   ```mermaid
   sequenceDiagram
     participant PR as pr.yml
     participant Main as main.yml
     participant Reg as Registry
     participant Rel as release.yml
     participant Env as Promoted envs
     PR->>Reg: push pr-{number}-{sha7}, then test that digest
     Note over PR,Reg: pull-request images are tested, never promoted
     Main->>Reg: build once, push {next}-rc.{n}, sha-{sha7} and main
     Main->>Main: component and system tests on the digest
     Main->>Reg: publish, writing the same tags onto the tested digest
     Rel->>Reg: find the tested digest by sha-{sha7}
     Rel->>Reg: tag it X.Y.Z, plus X.Y, X and latest if newest
     Note over Env: configuration names X.Y.Z, optionally pinned by digest
   ```

5. **Pushing.**
   - `pushImage` pushes the images of one build one at a time (a shared build-service lock).
   - It retries a transient registry failure (three attempts by default, with backoff).
   - It writes the pushed digest to `build/image/digest.txt`.
   - `-PpushConvenienceTags=false` leaves out the floating (convenience) tags.
6. **References in configuration** ([ADR-0004](0004-environments-and-runtimes.md)):
   - promoted envs name an immutable release tag `X.Y.Z`, optionally pinned as `X.Y.Z@sha256:<digest>`;
   - dev declares the floating intent `main`, and the deploy records the literal version
     ([ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md));
   - `local` uses `local`.
7. **Retention.** The nightly sweep of `retention.sh` is a dry run until it is enabled. It works on versions: a
   version is one digest in the registry, with its tags.

   > **Superseded in part by [ADR-0032](0032-registry-credentials.md) rule 5.** The sweep runs on GHCR only; on another
   > registry `retention.sh` prints a notice and exits 0.

   - It deletes `pr-*` versions seven days after their pull request closed. It keeps the 20 newest `-rc`
     versions and every one younger than 30 days.
   - It never deletes a version that:
     - carries a release or convenience tag;
     - is untagged (it can hold the per-platform manifests of a tagged index);
     - carries a tag in use: named by a `_docker-compose.instance.env` or `_helm-values.instance.yaml`, or by the
       last successful GitHub Deployment of a dev env.

   How the sweep decides for each version (a dry run only reports what it would delete):

   ```mermaid
   flowchart TD
     v["One version<br/>a digest and its tags"] --> q1{"Untagged, or a release,<br/>convenience or in-use tag?"}
     q1 -->|yes| keep["Keep"]
     q1 -->|no| q2{"A pr-{number}-{sha7} tag?"}
     q2 -->|yes| q3{"Pull request closed<br/>more than 7 days ago?"}
     q3 -->|yes| del["Delete"]
     q3 -->|no| keep
     q2 -->|no| q4{"A -rc tag?"}
     q4 -->|no| keep
     q4 -->|yes| q5{"One of the 20 newest,<br/>or younger than 30 days?"}
     q5 -->|yes| keep
     q5 -->|no| del
   ```

## Alternatives considered

- **Rebuild at release.** The released bits were never tested, and the build is not reproducible enough to
  promise otherwise.
- **Floating tags only** (`latest`, `main`). There is no way to say exactly what ran, and nothing to roll back to.
- **A separate registry per stage, promoted by copying** (enterprise repository-manager promotion). It is
  equivalent in principle, and the re-tag step is where that promotion would plug in.

## Consequences

- A released image is identical to the one that passed the system test. Its labels show the `-rc` version it was
  built with — the price of building once.
- Rollback is always possible, because the tags of everything in use are protected.
- The build job pushes the full `main` set, `main` included, before any test has run. If a test then fails, `main`
  keeps pointing at the failed build, although rule 3 allows moving it only to a tested digest. The build should
  push with `-PpushConvenienceTags=false` and leave `main` to the publish step (known gap).
- Every tool takes the registry from `platform.yml` ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).
