# ADR-0008 — Versions are derived from git tags and Conventional Commits; no version file exists

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every build of every repository built from this one |
| Enforced by | `VersionSchemeTest`; `release.yml` asserts `./gradlew -q printVersion` equals the tag; `_gradle-build.yml` rejects a malformed version and expects a pre-release tag on `main` |
| Related | [ADR-0002](0002-one-repository-one-project-one-release-line.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0020](0020-branching-protection-and-merge-rules.md), [ADR-0029](0029-release-and-promotion.md) |

## Context

The repository has one release line ([ADR-0002](0002-one-repository-one-project-one-release-line.md)). Every
commit needs a unique, deterministic version, from which unique, immutable image tags follow. Version files have
to be bumped by commits, and no workflow may commit to `main`
([ADR-0020](0020-branching-protection-and-merge-rules.md)).

## Decision

1. **Computed on every invocation.** The settings plugin `buildlogic.git-version` computes `project.version` from
   git each time Gradle runs:

   | Build | Version |
   |---|---|
   | `HEAD` carries the tag `vX.Y.Z` and the work tree is clean | `X.Y.Z` |
   | `main` in CI | `<next>-rc.<n>` |
   | `hotfix/<x>` in CI | `<next-patch>-rc.<n>` |
   | pull request or merge queue in CI | `<next>-pr.<number>.<sha7>` |
   | anything else (a laptop) | `<next>-local.<n>.<sha7>`, plus `.dirty` when tracked files changed |

   - `<n>` is the number of commits since the last `vX.Y.Z` tag.
   - `<next>` is that tag bumped by the Conventional Commits since it: `feat!:` or a `BREAKING CHANGE:` footer
     bumps the major, `feat:` the minor, anything else the patch. Without any tag it is `0.1.0`.
2. **Tags.** The only tags are `vX.Y.Z`: no pre-release tags, and one series per repository. Release automation
   creates them ([ADR-0029](0029-release-and-promotion.md)).
3. **Commit messages drive versions.** The commit that lands on `main` is the squash of a pull request, whose title
   MUST be a Conventional Commit ([ADR-0020](0020-branching-protection-and-merge-rules.md)).
4. **No version file.** No file in the repository holds the version. `.release-please-manifest.json` is the release
   tool's own bookkeeping, and the build never reads it. Both calculators MUST agree: `release.yml` fails when
   `printVersion` on the tagged commit differs from the tag.
5. **One way to read it.** `./gradlew -q printVersion` is the only way to obtain the version. `-Pversion=<v>`
   overrides it for local experiments; workflows MUST NOT use the override.
6. **Full history in CI.** CI checks out the full history (`fetch-depth: 0`); a shallow clone warns and computes
   the wrong version. `main` builds ignore tags on `HEAD`, so they always produce the `-rc` form even when the
   release tag already points at the commit. The release promotes those builds
   ([ADR-0029](0029-release-and-promotion.md)).
7. **The same commit has a different version in different contexts** (pull request, `main`, laptop). This is
   intended: the version says what kind of build produced an artifact.

## Alternatives considered

- **A version in `gradle.properties`, bumped by commits.** It needs bot commits to `main` and causes merge
  conflicts on every release.
- **The release tool's manifest as the version source.** Local and pull-request builds would depend on a bot file.
- **`-SNAPSHOT` versions.** They are not unique per commit, so they cannot name immutable images.

## Consequences

- Every artifact names its origin: an image's version label says whether it came from a pull request, from
  `main` or from a release build.
- A breaking change bumps the major version in the pre-release form at once, so the next release can be predicted
  from `printVersion` on `main`.
- Builds require git and the tags. An export without history builds as `0.1.0` with sha `0000000`, with a warning.
- No CI check validates pull-request titles as Conventional Commits yet (known gap); a wrong title silently gives
  the wrong bump.
