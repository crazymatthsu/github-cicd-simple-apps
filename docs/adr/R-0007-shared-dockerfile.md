# R-0007 — One shared `docker/spring-boot.Dockerfile` replaces the per-app Dockerfiles

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Supersedes | R-0001 decision 4, last sentence (`scripts/entrypoint.sh` stays per app) |
| Platform decisions applied | D3 §6.4–§6.7, §6.11 (the app image); the shared-Dockerfile design of the trading-platform reference (`docker/spring-boot.Dockerfile` + `acme.docker-conventions`) |

## Context

Every app carried `docker/Dockerfile`, `scripts/entrypoint.sh` and `.dockerignore`. The three Dockerfiles differed
only in the app name (the jar path `build/libs/<AppName>.jar`, the title and `com.example.app` labels, the header
comment); the three entrypoints and `.dockerignore` files were byte-identical. Every image change had to be made
three times — and once more per new app — and any copy that was missed drifted silently. The name was only in the
file because the build context mirrored the subproject layout.

## Decision

- **One Dockerfile**: `docker/spring-boot.Dockerfile` at the repository root, with the shared `docker/entrypoint.sh`
  beside it. Its content is the former per-app Dockerfile (company base `ghcr.io/crazymatthsu/base/jre21`, layered
  Boot extraction, user 10001, `JAVA_TOOL_OPTIONS_DEFAULTS` / `JAVA_OPTS` through the entrypoint, curl liveness
  healthcheck), minus everything app-specific.
- **Generic build context**: `stageDockerContext` of `buildlogic.docker-image` stages exactly three files into
  `apps/<AppName>/build/docker/` — `Dockerfile`, `entrypoint.sh` and `application.jar` (the `bootJar`, renamed). The
  jar is always at the same path, so there is no `ARG APP`, no repository-root context and no `.dockerignore`.
  `buildImage` builds that directory as before; by hand it is `docker buildx build apps/<AppName>/build/docker` after
  `./gradlew :<AppName>:stageDockerContext`.
- **Labels**: the per-app labels (`org.opencontainers.image.title`, `com.example.app`) come from `buildImage`'s
  `--label` flags, which already carried them; the Dockerfile keeps only the generic ones.
- **Override**: an app that cannot use the shared file adds `apps/<AppName>/docker/Dockerfile`; when it exists it is
  staged as `Dockerfile` instead (same context). It is a documented exception — code review should ask why.
- **CI**: hadolint lints `*.Dockerfile` too; `docker/**` and `**/*.Dockerfile` are shared inputs in
  `.github/affected-map.yml` (a change rebuilds every app).

## Alternatives

- **Keep per-app files, generate them** from a template: still N files to review and keep in step with the generator.
- **Repository-root context with `ARG APP`**: one Dockerfile too, but the context becomes the whole repository (slow,
  cache-hostile, needs a large `.dockerignore`) and the app name leaks back into the image definition.

## Consequences

- Removed: `apps/*/docker/Dockerfile`, `apps/*/scripts/entrypoint.sh`, `apps/*/.dockerignore`. The apps keep
  `docker/docker-compose.yml` (the host bundle is unchanged: it never carried the Dockerfile or the entrypoint), and
  `platform.yml` now names the compose template as what makes a directory under `apps/` an app.
- A new app needs no image files: applying `buildlogic.docker-image` to a Spring Boot project is enough.
- The images themselves are unchanged apart from the jar's name inside the throwaway extraction stage.
