# R-0003 — `framework/` replaces `libs/` (DL-43)

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-43 (amends DL-42 §2 / §4), D12 v1.1 §6.2 |

## Context

DL-43 renamed the shared-code directory of a project repository from `libs/` to `framework/`: the apps are
built on the connector framework, not on a bag of utilities, and `libs` already names Gradle's build outputs
(`build/libs/`) and the version catalog (`libs.versions.toml`, `libs.` accessors).

## Decision

`libs/connectors-framework/` moves to `framework/connectors-framework/`. The Gradle project stays
`:connectors-framework`, so the apps' `project(":connectors-framework")` dependencies, the images and the
integration tests are untouched. `settings.gradle.kts` discovers `apps/*` and `framework/*`;
`.github/affected-map.yml` treats `framework/**` as shared (a change there builds and tests everything);
CODEOWNERS and `platform.yml` follow.

## Consequences

- R-0001 item 2 reads `framework/` from here on (note there).
- The host bundle and the deploy scripts are unaffected: they only ever carry `apps/<AppName>/docker/`.
- A second shared module is a directory under `framework/` with a `build.gradle.kts`; nothing else to register.
