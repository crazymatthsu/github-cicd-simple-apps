# ADR-0007 — Gradle builds every module through convention plugins in `build-logic/`

| | |
|---|---|
| Status | Accepted. Rule 3 superseded in part by [ADR-0030](0030-platform-yml-declares-every-project-value.md) |
| Date | 2026-10-04 |
| Applies to | every module and the root build |
| Enforced by | `FAIL_ON_PROJECT_REPOS`; `org.gradle.configuration-cache.problems=fail`; `jacocoTestCoverageVerification` in `check`; Gradle wrapper validation in CI; the `build-logic` unit tests (part of the root `check`) |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0008](0008-versions-derived-from-git.md), [ADR-0009](0009-one-shared-image-definition.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

**In short:** Every module is built, tested and packaged by the same shared Gradle plugins, kept in `build-logic/`.
Every dependency version lives in one catalog file. So an app's build file names only its plugins and its
dependencies, and every build is reproducible and cacheable.

## Context

Every app has to be built, tested, measured and packaged the same way. The same commit should always give the same
result, and builds should reuse cached work. They also have to run inside an enterprise network that can reach only
a repository manager. Copying build logic into every module scales as badly as copying Dockerfiles did.

## Decision

1. **The Gradle wrapper is the only entry point.** The wrapper jar is committed and validated in CI. The JDK 21
   comes from the environment: the `ci-build` image in CI, the developer's installation on a laptop. Toolchain
   auto-download is off.
2. **Conventions live in `build-logic/`.** A convention plugin is a small Gradle plugin that applies shared build
   settings. `build-logic/` is an included build (a separate Gradle build that the main build uses) of precompiled
   Kotlin script plugins.
   - The logic behind the plugins lives in plain Kotlin classes under `build-logic/src/main/kotlin/buildlogic/`.
     It is unit-tested there (`VersionSchemeTest`, `ConfigLinterTest`, `PlatformManifestTest`, `ContainerEnginesTest`, `PushRetryTest`),
     and the root `check` runs those tests.
   - The root build scripts hold no conventions, and no module uses `allprojects {}` or `subprojects {}`.
3. **The plugins.** Each part of the build applies only the plugins it needs. The diagram shows which part applies
   each plugin, and what the plugin adds:

   ```mermaid
   flowchart LR
     settings["settings.gradle.kts"] --> gitver["buildlogic.git-version<br/>project.version and git facts"]
     jvm["every JVM module<br/>apps and framework"] --> javaconv["buildlogic.java-conventions<br/>Java 21, BOM, tests, coverage"]
     apps["every app"] --> bootapp["buildlogic.spring-boot-app<br/>layered bootJar, build info"]
     apps --> image["buildlogic.docker-image<br/>stage, build and push the image"]
     apps --> itest["buildlogic.integration-test<br/>integration tests, compose stacks"]
     rootb["root build"] --> lint["buildlogic.config-lint<br/>configLint"]
   ```

   What each plugin provides:
   - **`buildlogic.git-version`**, a settings plugin applied by `settings.gradle.kts`: `project.version` and the git
     facts ([ADR-0008](0008-versions-derived-from-git.md)).
   - **`buildlogic.java-conventions`**, applied to every JVM module:
     - the Java 21 toolchain, the Spring Boot BOM as a platform, and JUnit Platform;
     - tests in UTC and UTF-8, a JaCoCo report, and a coverage floor (`coverage.minimum`, default `0.20`) that is
       only ever raised;
     - `-parameters` and `-Xlint`, reproducible archives, and `Implementation-Version` in the manifest.
   - **`buildlogic.spring-boot-app`**, for apps: the Spring Boot plugin; a layered `bootJar` named `<AppName>.jar`
     with the tools jarmode; no plain jar. It also writes build info for `/actuator/info`: the version, git sha,
     branch, dirty flag and version kind, with the commit time as the build time.
   - **`buildlogic.docker-image`**, for apps: `stageDockerContext`, `buildImage`, `pushImage`, `printImageRef`
     ([ADR-0009](0009-one-shared-image-definition.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md)).
   - **`buildlogic.integration-test`**, for apps: the `integrationTest` suite, `composeUp`/`composeDown` and
     `devUp`/`devDown` ([ADR-0025](0025-integration-tests-on-compose-stacks.md)).
   - **`buildlogic.config-lint`**, for the root: `configLint`
     ([ADR-0014](0014-config-lint-enforces-the-config-contract.md)).

   An app's `build.gradle.kts` applies the three app plugins and declares its dependencies, and nothing else.
4. **One place for versions.** `gradle/libs.versions.toml`, the version catalog, is the only file where a dependency
   or plugin version appears. The Spring Boot BOM (bill of materials: a set of versions known to work together)
   manages Spring, Jackson, Micrometer, JUnit and the JDBC drivers. So those catalog entries carry no version.
   Modules MUST NOT declare versions or repositories.
5. **Repositories.** Maven Central and the Gradle Plugin Portal are the defaults. When `ARTIFACTORY_URL` is set, the
   build uses that repository manager's virtual repositories instead. Credentials come only from the environment
   (`ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN`), never from a file.
6. **Reproducible and cached.**
   - The configuration cache is on, and its problems fail the build. This cache lets Gradle skip the configuration
     phase when nothing changed. The build cache and parallel execution are on too.
   - Archives have no timestamps and a stable entry order.
   - Build info uses the commit time instead of "now".
7. **Aggregate tasks.** The root build defines only aggregates: `build`, `configLint`, `printVersion`,
   `buildImages`, `pushImages`, `integrationTest`, `devUp`, `devDown`. `check` does five things:
   - it compiles;
   - it runs the unit tests;
   - it verifies coverage;
   - it compiles the integration tests without running them;
   - it runs the `build-logic` tests.
8. **Dependency updates arrive as Renovate pull requests.**
   - Their Conventional Commit types decide the release: `fix(deps)` produces a patch release, `ci(deps)` none.
   - The Spring Boot plugin and BOM move together. The build follows minor Boot versions; a major version is a
     decision of its own.

## Alternatives considered

- **`buildSrc`.** Any change to it invalidates the whole build. An included build is isolated and cacheable.
- **Shared logic in the root build** (`allprojects`/`subprojects`). It couples modules in ways nobody sees, and it
  fights the configuration cache.
- **Binary plugins published to a repository.** This is the right form once several repositories share the plugins,
  as part of extracting the shared tooling ([ADR-0005](0005-repository-layout-and-shared-tooling.md)). Today it is
  premature.

## Consequences

- An app's build file is about fifteen lines.
- A change to `build-logic/`, `gradle/` or a root Gradle file rebuilds and retests everything
  ([ADR-0022](0022-pull-request-pipeline.md)).
- Builds need git history and tags, because the version comes from them.
- `buildlogic.integration-test` holds domain values inside shared tooling: it wires in the Deephaven client and the
  connectors' test endpoints (known gap). The project values, the group among them, come from `platform.yml`
  ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).
- The toolchain vendor is not pinned.
