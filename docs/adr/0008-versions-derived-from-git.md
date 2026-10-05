# ADR-0008 — Versions are derived from git tags and Conventional Commits; no version file exists

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every build of every repository built from this one |
| Enforced by | `VersionSchemeTest`; `release.yml` asserts `./gradlew -q printVersion` equals the tag; `_gradle-build.yml` rejects a malformed version and expects a pre-release tag on `main` |
| Related | [ADR-0002](0002-one-repository-one-project-one-release-line.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0020](0020-branching-protection-and-merge-rules.md), [ADR-0029](0029-release-and-promotion.md) |

**In short:** No file holds the version. Gradle computes it from git every time it runs: from the last release tag,
the Conventional Commit messages since that tag, and the kind of build. So every commit gets a unique version, and
no bot has to commit to `main` to bump it.

## Context

The repository has one release line ([ADR-0002](0002-one-repository-one-project-one-release-line.md)). Every
commit needs a version that is unique and always computed the same way, because unique, immutable image tags are
made from it. A version file would have to be bumped by commits, and no workflow is allowed to commit to `main`
([ADR-0020](0020-branching-protection-and-merge-rules.md)).

## Decision

1. **Computed on every invocation.** The settings plugin `buildlogic.git-version` computes `project.version` from
   git each time Gradle runs. It checks these rows from top to bottom and uses the first one that matches:

   | Build | Version |
   |---|---|
   | `HEAD` carries the tag `vX.Y.Z` and the work tree is clean | `X.Y.Z` |
   | pull request or merge queue in CI | `<next>-pr.<number>.<sha7>` |
   | `main` in CI | `<next>-rc.<n>` |
   | `hotfix/<x>` in CI | `<next-patch>-rc.<n>` |
   | anything else (a laptop) | `<next>-local.<n>.<sha7>`, plus `.dirty` when tracked files changed |

   - `<n>` is the number of commits since the last `vX.Y.Z` tag.
   - `<next>` is that tag bumped by the Conventional Commits since it. A Conventional Commit message starts with a
     type, such as `feat:` or `fix:`. A `!` after the type (`feat!:`, `fix!:`) or a `BREAKING CHANGE:` footer bumps
     the major, `feat:` the minor, and anything else the patch. Without any tag, `<next>` is `0.1.0`.
   - `<next-patch>` is that tag with its patch bumped, whatever the commits say.

   The same rules as a decision tree, in the order Gradle applies them:

   ```mermaid
   flowchart TD
     q1{"HEAD carries vX.Y.Z<br/>and the work tree is clean?"}
     q1 -->|yes| v1["X.Y.Z"]
     q1 -->|no| q2{"Pull request or merge queue in CI?"}
     q2 -->|yes| v2["{next}-pr.{number}.{sha7}"]
     q2 -->|no| q3{"main in CI?"}
     q3 -->|yes| v3["{next}-rc.{n}"]
     q3 -->|no| q4{"hotfix/{x} in CI?"}
     q4 -->|yes| v4["{next-patch}-rc.{n}"]
     q4 -->|no| v5["{next}-local.{n}.{sha7}<br/>plus .dirty when tracked files changed"]
   ```

2. **Tags.** The only tags are `vX.Y.Z`. There are no pre-release tags, and each repository has one series. Release
   automation creates them ([ADR-0029](0029-release-and-promotion.md)).
3. **Commit messages drive versions.** The commit that lands on `main` is the squash of a pull request. That pull
   request's title MUST be a Conventional Commit ([ADR-0020](0020-branching-protection-and-merge-rules.md)).
4. **No version file.** No file in the repository holds the version. `.release-please-manifest.json` is the release
   tool's own bookkeeping, and the build never reads it. Release-please and `buildlogic.git-version` both compute
   versions, and the two MUST agree: `release.yml` fails when `printVersion` on the tagged commit differs from the
   tag.
5. **One way to read it.** `./gradlew -q printVersion` is the only way to obtain the version. `-Pversion=<v>`
   overrides it for local experiments; workflows MUST NOT use the override.
6. **Full history in CI.** CI checks out the full history (`fetch-depth: 0`). A shallow clone logs a warning, because
   missing tags and history can give the wrong version. `main` builds ignore tags on `HEAD`: the pipeline deletes them from its checkout
   before Gradle runs. So a `main` build always produces the `-rc` form, even when the release tag already points
   at the commit. The release promotes those builds ([ADR-0029](0029-release-and-promotion.md)).
7. **The same commit has a different version in different contexts** (pull request, `main`, laptop). This is
   intended: the version says what kind of build produced an artifact.

## Alternatives considered

- **A version in `gradle.properties`, bumped by commits.** It needs bot commits to `main` and causes merge
  conflicts on every release.
- **The release tool's manifest as the version source.** Local and pull-request builds would depend on a file that
  a bot maintains.
- **`-SNAPSHOT` versions.** They are not unique per commit, so they cannot name immutable images.

## Consequences

- Every artifact names its origin: an image's version label says whether it came from a pull request, from
  `main` or from a release build.
- A breaking change bumps the major version in the pre-release form at once. So the next release can be predicted
  from `printVersion` on `main`.
- Builds require git and the tags. An export without history computes its version from `0.1.0` and the sha
  `0000000`, with a warning; on a laptop it builds as `0.1.0-local.0.0000000`.
- No CI check validates pull-request titles as Conventional Commits yet (known gap). A wrong title silently gives
  the wrong bump.
