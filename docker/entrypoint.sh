#!/bin/sh
# Container entrypoint of every app image (D3 §6.4), shared like docker/spring-boot.Dockerfile (R-0007): exec keeps
# Java as PID 1 so SIGTERM reaches it (graceful shutdown, D6 §6.10).
# JAVA_TOOL_OPTIONS_DEFAULTS (image) and JAVA_OPTS (the compose env layers / Helm values) are split on whitespace on
# purpose; the heap is a percentage of the container limit, never -Xmx. Arguments pass through, e.g.
# `--print-config` (run-compose.sh app-config --offline).
set -eu
# shellcheck disable=SC2086
exec java ${JAVA_TOOL_OPTIONS_DEFAULTS:-} ${JAVA_OPTS:-} -cp /app org.springframework.boot.loader.launch.JarLauncher "$@"
