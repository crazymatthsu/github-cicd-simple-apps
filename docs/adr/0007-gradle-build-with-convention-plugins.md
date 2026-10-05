# ADR-0007 — Gradle builds every module through convention plugins in `build-logic/`

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every module and the root build |
| Enforced by | `FAIL_ON_PROJECT_REPOS`; `org.gradle.configuration-cache.problems=fail`; `jacocoTestCoverageVerification` in `check`; Gradle wrapper validation in CI; the `build-logic` unit tests (part of the root `check`) |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0008](0008-versions-derived-from-git.md), [ADR-0009](0009-one-shared-image-definition.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

## Context

Every app has to be built, tested, measured and packaged the same way. The result should be reproducible from a
commit, cacheable, and buildable inside an enterprise network that sees only a repository manager. Copying
build logic into every module scales as badly as copying Dockerfiles did.

## Decision

1. **The Gradle wrapper is the only entry point.** The wrapper jar is committed and validated in CI. The JDK 21
   comes from the environment: the `ci-build` image in CI, the developer's installation on a laptop. Toolchain
   auto-download is off.
2. **Conventions live in `build-logic/`,** an included build of precompiled Kotlin script plugins. The logic behind
   them lives in plain Kotlin classes under `build-logic/src/main/kotlin/buildlogic/`, unit-tested there
   (`VersionSchemeTest`, `ConfigLinterTest`, `ContainerEnginesTest`, `PushRetryTest`). The root `check` runs those
   tests. The root build scripts hold no conventions, and no module uses `allprojects {}` or `subprojects {}`.
3. **The plugins:**

   | Plugin | Applied by | Provides |
   |---|---|---|
   | `buildlogic.git-version` (settings) | `settings.gradle.kts` | `project.version` and the git facts ([ADR-0008](0008-versions-derived-from-git.md)) |
   | `buildlogic.java-conventions` | every JVM module | Java 21 toolchain; the Spring Boot BOM as a platform; JUnit Platform; tests in UTC and UTF-8; JaCoCo report; a coverage floor (`coverage.minimum`, default `0.20`) that is only ever raised; `-parameters` and `-Xlint`; reproducible archives; `Implementation-Version` in the manifest |
   | `buildlogic.spring-boot-app` | apps | the Spring Boot plugin; a layered `bootJar` named `<AppName>.jar` with the tools jarmode; no plain jar; build info (version, git sha, branch, dirty flag, version kind, commit time as the build time) for `/actuator/info` |
   | `buildlogic.docker-image` | apps | `stageDockerContext`, `buildImage`, `pushImage`, `printImageRef` ([ADR-0009](0009-one-shared-image-definition.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md)) |
   | `buildlogic.integration-test` | apps | the `integrationTest` suite, `composeUp`/`composeDown`, `devUp`/`devDown` ([ADR-0025](0025-integration-tests-on-compose-stacks.md)) |
   | `buildlogic.config-lint` | root | `configLint` ([ADR-0014](0014-config-lint-enforces-the-config-contract.md)) |

   An app's `build.gradle.kts` applies the three app plugins and declares its dependencies, and nothing else.
4. **One place for versions.** `gradle/libs.versions.toml` is the only file where a dependency or plugin version
   appears. The Spring Boot BOM manages Spring, Jackson, Micrometer, JUnit and the JDBC drivers, so those catalog
   entries carry no version. Modules MUST NOT declare versions or repositories.
5. **Repositories.** Maven Central and the Gradle Plugin Portal are the defaults. When `ARTIFACTORY_URL` is set, the
   build uses that repository manager's virtual repositories instead. Credentials come only from the environment
   (`ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN`), never from a file.
6. **Reproducible and cached.**
   - The configuration cache is on, and its problems fail the build. The build cache and parallel execution are
     on.
   - Archives have no timestamps and a stable entry order.
   - Build info uses the commit time instead of "now".
7. **Aggregate tasks.** The root build defines only aggregates: `build`, `configLint`, `printVersion`,
   `buildImages`, `pushImages`, `integrationTest`, `devUp`, `devDown`. `check` compiles, runs the unit tests, verifies
   coverage, compiles the integration tests without running them, and runs the `build-logic` tests.
8. **Dependency updates arrive as Renovate pull requests:**
   - Conventional Commit types decide the release: `fix(deps)` produces a patch release, `ci(deps)` none.
   - The Spring Boot plugin and BOM move together. Minor Boot versions are followed; a major version is a
     decision.

## Alternatives considered

- **`buildSrc`.** Any change to it invalidates the whole build. An included build is isolated and cacheable.
- **Shared logic in the root build** (`allprojects`/`subprojects`). It couples modules implicitly and fights the
  configuration cache.
- **Binary plugins published to a repository.** This is the right form once several repositories share them, as
  part of extracting the shared tooling ([ADR-0005](0005-repository-layout-and-shared-tooling.md)). It is premature
  now.

## Consequences

- An app's build file is about fifteen lines.
- A change to `build-logic/`, `gradle/` or a root Gradle file rebuilds and retests everything
  ([ADR-0022](0022-pull-request-pipeline.md)).
- Builds need git history and tags, because the version comes from them.
- `buildlogic.java-conventions` hard-codes this project's group (`com.example.connectors`), and
  `buildlogic.integration-test` wires in the Deephaven client and the connectors' test endpoints. Both are project
  or domain values inside shared tooling (known gaps). The toolchain vendor is not pinned.
