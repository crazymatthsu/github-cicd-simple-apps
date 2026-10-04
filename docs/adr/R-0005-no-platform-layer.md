# R-0005 — The platform layer `config/_common/<AppName>/` is removed (DL-45)

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-45 (amends DL-07 layer 2, DL-41 bundle layout, DL-42 §2, DL-44 layer count); D5 v1.2 §6.1 |

## Context

A value in `config/_common/<AppName>/` reached every env at once: the blast radius of one wrong edit at the top of
the tree was dev, qa and prod together, and a CODEOWNERS guard only slows such an edit down. DL-45 removes the
layer: nothing is shared across envs, as nothing is shared at the env level (DL-44). A default that is the same
everywhere is a jar default (layer 1), shipped and tested with the code and promoted env by env with a release.

## Decision

- `config/_common/source-database/application.yml` is deleted. Its one key, `connector.source.poll-interval: 15s`,
  demonstrated precedence; the jar default (30s) stands and `app-common` sets 5s for us-dev/cash as before.
- The jar import list drops `/config/platform/application.yml`; the rendered-config test proves
  jar < flow (the cluster layer) < app-common < instance < secrets.
- The compose templates mount no `/config/platform`; `PLATFORM_DIR` is gone from `run-compose.sh`, `stack.sh` and
  `pool-deploy.sh`, and the host bundle carries no `config/_common/`.
- Helm: `appConfig.platform` / `appFiles.platform` are gone from the values schema, the ConfigMap and the helpers;
  `helm-deploy-instance.sh` passes the cluster layer (when present), app-common and the instance.
- config-lint check 1 rejects a top-level `config/_common/` with a pointer to the jar defaults and the cluster layer.

## Consequences

- Three file layers (cluster, app-common, instance); precedence unchanged.
- A setting that must be the same in every env is a code change: a release carries it through dev, qa and prod.
- `config/` holds env directories and `README.md` only.
