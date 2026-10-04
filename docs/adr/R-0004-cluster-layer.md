# R-0004 — The cluster layer `config/<env>/<flow>/_common/` replaces the env layer (DL-44)

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-44 (amends DL-07 layer 3, DL-41 bundle layout, DL-42 §2); D5 v1.1 §6.1 |

## Context

Nothing is shared at the env level in this platform: one business flow in one env — `<env>/<flow>` — is one
business cluster, with its own boxes, inventory and shared endpoints. DL-44 therefore replaces the env-wide
layer `config/<env>/_common/` (mounted at `/config/env/`) with the cluster layer `config/<env>/<flow>/_common/`,
mounted at `/config/flow/`.

## Decision

- `config/us-dev/_common/` moved to `config/us-dev/cash/_common/`; config-lint check 1 now rejects a `_common/`
  directly under an env and lints the flow-level one as a layer.
- The jar import list reads `/config/flow/application.yml` (the rendered-config test follows); the compose
  templates mount `FLOW_COMMON_DIR` there; `run-compose.sh`, `stack.sh` and `pool-deploy.sh` resolve the layer
  from `config/<env>/<flow>/_common/`, and the host bundle carries it with the flow.
- Helm: `appConfig.flow` / `appFiles.flow` (ConfigMap keys `flow.*`), set by `helm-deploy-instance.sh` from the
  same directory; the chart's ExternalSecret reads the cluster's shared secrets from the Vault path
  `<env>/<flow>/_common`.

## Consequences

- Layer count unchanged (platform, cluster, app-common, instance); precedence unchanged.
- The `local` tree has no shared layer yet; adding `config/local/cash/_common/` is a directory, nothing to register.
- `config/<env>/known_hosts` and the flows are the only children of an env directory.
