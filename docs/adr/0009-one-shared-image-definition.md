# ADR-0009 — Every app image is built from one shared Dockerfile, through Gradle, with docker or podman

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every app image |
| Enforced by | hadolint in the `lint` job (warnings fail, trusted registries only); `ContainerEnginesTest`; `buildImage` fails in CI when no engine is usable |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0007](0007-gradle-build-with-convention-plugins.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md) |

**In short:** All apps share one Dockerfile and one entrypoint script. Gradle puts them, with the app's jar, into a
three-file build context and builds the image with Docker or Podman. With one definition there are no per-app copies
to drift apart, and a laptop builds an image the same way CI does.

## Context

We used to have a Dockerfile per app. They differed only in the app's name, and they drifted apart anyway. Images
have to be built the same way on a laptop and in CI, with Docker or with Podman. They have to be small and layered,
so that registry caches hit. And they have to run as a non-root user, with the company's CA bundle.

## Decision

1. **One Dockerfile.** `docker/spring-boot.Dockerfile` and `docker/entrypoint.sh` build every app.
2. **A generic build context.** The build context is the set of files the engine can see during a build.
   `stageDockerContext` stages exactly three files into `apps/<AppName>/build/docker/`:
   - `Dockerfile`;
   - `entrypoint.sh`;
   - `application.jar` (the app's `bootJar`).

   Every app's context looks the same. So the Dockerfile has no `ARG APP`, there is no repository-root context, and
   there is no `.dockerignore`. To build by hand, run `./gradlew :<AppName>:stageDockerContext`, then
   `docker buildx build apps/<AppName>/build/docker`.

   How the pieces come together for one app:

   ```mermaid
   flowchart LR
     jar["bootJar<br/>{AppName}.jar"] --> ctx["stageDockerContext<br/>apps/{AppName}/build/docker/<br/>Dockerfile, entrypoint.sh, application.jar"]
     df["docker/spring-boot.Dockerfile"] --> ctx
     ep["docker/entrypoint.sh"] --> ctx
     ovr["apps/{AppName}/docker/Dockerfile<br/>exception only"] -.->|replaces the shared Dockerfile| ctx
     ctx --> bi["buildImage<br/>docker buildx build --load<br/>or podman build --format docker"]
     bi --> img["App image, built on {registry}/base/jre21<br/>layers: dependencies, loader,<br/>snapshot dependencies, application"]
   ```

3. **The image:**
   - **Base:** the company JRE 21 image `<registry>/base/jre21`. It carries the CA bundle in both trust stores,
     tzdata, curl and the non-root user `10001`. The Dockerfile never repeats any of it.
   - **Two stages:** the first unpacks the layered jar into its layers
     (`-Djarmode=tools … extract --layers --launcher`). The second copies the layers, least-changing first:
     dependencies, loader, snapshot dependencies, application. So the dependency layers stay byte-identical across
     releases.
   - **Runtime:** `USER 10001:10001`, `EXPOSE 8080`, no `VOLUME`, a liveness `HEALTHCHECK` on
     `/actuator/health/liveness`, and `ENTRYPOINT ["/app/entrypoint.sh"]`.
   - **JVM options:** the entrypoint `exec`s Java as PID 1, so SIGTERM reaches it. Java gets
     `JAVA_TOOL_OPTIONS_DEFAULTS` from the image (`-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError
     -XX:+UseG1GC …`), followed by `JAVA_OPTS` from the deployment. The heap is a percentage of the container limit,
     never `-Xmx`. Arguments pass through, for example `--print-config`.
4. **Gradle builds it.**
   - `buildImage` runs `docker buildx build --load` or `podman build --format docker` (which keeps the
     `HEALTHCHECK`). It tries Docker, then Podman, and picks the first whose daemon or service answers.
     `-Pimage.engine` or `CONTAINER_ENGINE` forces one.
   - It passes the build arguments `APP_VERSION`, `GIT_SHA` and `BUILD_URL`, and these labels:
     `org.opencontainers.image.{title,description,version,revision,source}` and
     `com.example.{app,git-sha,build-url,version-kind}`. `BASE_IMAGE` (property or environment) overrides the
     base.
   - With `CI=true`, a missing engine fails the build. On a laptop it is a logged no-op, so `./gradlew build` works
     without one.
5. **Override by exception.** An app MAY replace the shared file with `apps/<AppName>/docker/Dockerfile`, staged
   into the same three-file context. It is a documented exception, and review asks why.
6. **Base images are external inputs.** `<registry>/base/jre21` and `<registry>/base/ci-build` are built and
   published outside this repository. CI resolves them to digests, and Renovate proposes their dated tags.

## Alternatives considered

- **Per-app Dockerfiles, hand-written or generated.** That is N files to review and keep in step. They drifted when
  they existed.
- **A repository-root context with `ARG APP`.** This is one Dockerfile too, but the context becomes the whole
  repository. That is slow and hostile to the cache, and it needs a large `.dockerignore`. The app's name also leaks
  back into the image definition.
- **Buildpacks (`bootBuildImage`) or Jib.** No Dockerfile, but less control over the base image, the CA bundle and
  the layout, and no equal Podman path.

## Consequences

- A new app needs no image files: applying `buildlogic.docker-image` is enough.
- A change under `docker/` or to any Dockerfile rebuilds every app ([ADR-0022](0022-pull-request-pipeline.md)).
- The base images are a supply-chain dependency outside the repository. `setup-build-env` has a bootstrap path that
  builds them locally from `docker/base/<name>/Dockerfile` when they are not published. Here that path has nothing
  to build (known gap).
- The Dockerfile names no registry: Gradle passes the base image, `<registry>/base/jre21` of `platform.yml`, and the
  labels ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).
