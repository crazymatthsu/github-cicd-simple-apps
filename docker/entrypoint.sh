#!/bin/sh
# Container entrypoint of every app image, shared like docker/spring-boot.Dockerfile (ADR-0009): exec keeps
# Java as PID 1 so SIGTERM reaches it (graceful shutdown, ADR-0015).
# JAVA_TOOL_OPTIONS_DEFAULTS (image) and JAVA_OPTS (the compose env layers / Helm values) are split on whitespace on
# purpose; the heap is a percentage of the container limit, never -Xmx. Arguments pass through, e.g.
# `--print-config` (run-compose.sh app-config --offline).
set -eu
# shellcheck disable=SC2086
exec java ${JAVA_TOOL_OPTIONS_DEFAULTS:-} ${JAVA_OPTS:-} -cp /app org.springframework.boot.loader.launch.JarLauncher "$@"
