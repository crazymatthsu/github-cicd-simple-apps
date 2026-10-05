# ONE shared Dockerfile for every Spring Boot app under apps/ (ADR-0009).
#
# It is generic because the build context is generic: buildlogic.docker-image (stageDockerContext) stages exactly
# `application.jar`, `entrypoint.sh` (docker/entrypoint.sh) and this file as `Dockerfile` into
# apps/<AppName>/build/docker/, so there is no ARG APP, no repo-root context and no per-app copy to drift apart.
#
#   Gradle : ./gradlew :<AppName>:buildImage          (CI and laptop; tags, labels and build args from Gradle)
#   by hand: ./gradlew :<AppName>:stageDockerContext && docker buildx build apps/<AppName>/build/docker
#            (or podman build --format docker apps/<AppName>/build/docker)
#
# An app that cannot use it keeps apps/<AppName>/docker/Dockerfile: a documented override that wins when present,
# staged against the same context (code review should ask why).
#
# The company base image (published outside this repository) carries the enterprise / demo CA in both
# trust stores, tzdata, curl and the non-root user app (10001); this file never repeats that (ADR-0009).
# No project value lives here (ADR-0030): the staged copy defaults BASE_IMAGE to <registry of platform.yml>/base/jre21:latest
# (stageDockerContext), and Gradle passes it and the per-build labels, the source repository included.
ARG BASE_IMAGE

# Stage 1: explode the layered Spring Boot jar (Boot 4.1 tools jarmode). The base ends as user 10001, which
# cannot write /build: this throwaway stage runs as root.
FROM ${BASE_IMAGE} AS layers
# hadolint ignore=DL3002,DL3066
USER root
WORKDIR /build
COPY application.jar .
RUN java -Djarmode=tools -jar application.jar extract --layers --launcher --destination extracted \
    && mkdir -p runtime/data

# Stage 2: the runtime image, least-changing layer first, so dependency layers stay byte-identical across
# releases and the registry cache actually hits.
FROM ${BASE_IMAGE} AS runtime
ARG BASE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_URL=local
ARG CREATED=unknown
# buildImage also passes every label with --label, including the per-app title, com.example.app and the source
# repository; these make a hand-built image self-describing too (ADR-0009).
LABEL org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      com.example.git-sha="${GIT_SHA}" \
      com.example.build-url="${BUILD_URL}"
ENV TZ=UTC \
    JAVA_OPTS="" \
    JAVA_TOOL_OPTIONS_DEFAULTS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -XX:+UseG1GC -Djava.io.tmpdir=/tmp -Djava.security.egd=file:/dev/./urandom"
WORKDIR /app
COPY --from=layers /build/extracted/dependencies/ ./
COPY --from=layers /build/extracted/spring-boot-loader/ ./
COPY --from=layers /build/extracted/snapshot-dependencies/ ./
COPY --from=layers /build/extracted/application/ ./
COPY --chmod=0755 entrypoint.sh /app/entrypoint.sh
# /app/data: what an app keeps across restarts and versions (DATA_DIR on a box, ADR-0018), owned by the app user like
# the base image's /app/logs, so a fresh volume mounted there is writable.
COPY --from=layers --chown=10001:10001 /build/runtime/ ./
# The base image provides /config (read-only mounts of the Spring layers, ADR-0011) and /app/logs; /app/logs and
# /app/data are the only writable paths besides /tmp. No VOLUME: anonymous volumes would escape the CI leak check;
# compose and Kubernetes mount volumes / emptyDir at run time instead (ADR-0017).
# Numeric user so that Kubernetes can verify runAsNonRoot (ADR-0019); the base image names it "app".
USER 10001:10001
EXPOSE 8080
# Compose test stacks override this with the readiness probe (ADR-0015); Kubernetes uses its own probes.
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD ["sh", "-c", "curl -fsS http://localhost:8080/actuator/health/liveness || exit 1"]
ENTRYPOINT ["/app/entrypoint.sh"]
