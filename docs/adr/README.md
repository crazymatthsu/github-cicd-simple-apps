# ADRs of github-cicd-simple-apps

Decisions specific to this repository. Platform-wide decisions (DL-01 … DL-46) live in
[github-demo/docs/adr](https://github.com/crazymatthsu/github-demo/tree/main/docs/adr) and apply here unchanged.
Format: the platform's (D6 §6.13) — status, context, decision, alternatives, consequences; an accepted ADR is never
edited in substance, a new one supersedes it.

| ADR | Title | Status |
|---|---|---|
| [R-0001](R-0001-extracted-from-github-demo.md) | Extracted from github-demo as one project repository | Accepted (2026-10-04) |
| [R-0002](R-0002-no-workflow-writes-to-main.md) | DL-40 implemented: no workflow writes to `main`, the Deployment is the record | Accepted (2026-10-04) |
| [R-0003](R-0003-framework-directory.md) | `framework/` replaces `libs/` (DL-43) | Accepted (2026-10-04) |
| [R-0004](R-0004-cluster-layer.md) | The cluster layer `config/<env>/<flow>/_common/` replaces the env layer (DL-44) | Accepted (2026-10-04); its directory superseded by R-0008 |
| [R-0005](R-0005-no-platform-layer.md) | The platform layer `config/_common/<AppName>/` is removed (DL-45) | Accepted (2026-10-04) |
| [R-0006](R-0006-host-layout.md) | The boxes hold versioned bundles under `/apps/<user>/versions/<project>/` with `current` (DL-41, DL-46) | Accepted (2026-10-04) |
| [R-0007](R-0007-shared-dockerfile.md) | One shared `docker/spring-boot.Dockerfile` replaces the per-app Dockerfiles | Accepted (2026-10-04) |
| [R-0008](R-0008-compose-config-layers.md) | One compose template; the config layers are files merged into one generated env | Accepted (2026-10-04) |
