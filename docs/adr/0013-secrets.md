# ADR-0013 — Secrets never enter git, the configuration layers, the images or the host bundles

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every app, every env, every pipeline |
| Enforced by | config-lint check 9 (secret keys in YAML layers, secret-looking values anywhere in the tree); `run-compose.sh` (refuses `start`, `restart` and `validate` while a required secret is unset); `SecretMaskerTest`, `ConfigurationSummaryTest` and the actuator contract test (masking); the chart's values schema (secret-bearing `env` names) |
| Related | [ADR-0011](0011-configuration-tree-and-spring-layers.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md), [ADR-0028](0028-host-pool-deployment.md) |

## Context

The configuration tree is reviewed and readable by everyone with repository access. Bundles are copied to many
hosts, and images are pulled by many runtimes. The start-up summary, the actuator and the operations CLI all
print configuration. A secret in any of them is a leak.

## Decision

1. **Nowhere in the repository.** No secret value is stored in git: not in a YAML layer, an env layer, a compose
   override, a Helm values file, an image or a host bundle. The test CA under `test-infra/ca/` is a public
   certificate; its private key MUST NOT exist in the repository.
2. **How a secret reaches an app:**
   - **Compose.** The compose files declare each required secret as a pass-through,
     `NAME: ${NAME:?set in the shell, never in git}`. An app's own secrets go in its
     `apps/<AppName>/docker/docker-compose.override.yml`, for example `SPRING_DATASOURCE_USERNAME` and
     `SPRING_DATASOURCE_PASSWORD`. Values come from the shell that runs `run-compose.sh`; on a host, from the deploy
     user's environment, provisioned outside the repository. `start`, `restart` and `validate` refuse while a
     required secret is unset. Read-only commands substitute placeholders.
   - **Kubernetes (provisional).** A Secret mounted at `/secrets/`, one file per property, read through
     `optional:configtree:/secrets/` ([ADR-0011](0011-configuration-tree-and-spring-layers.md)). It is created by
     the deployer or rendered by an ExternalSecret.
   - **CI.** Secrets live in GitHub Environment secrets (`DEV_DEPLOY_SSH_KEY` in `us-dev`). They are used only by
     the step that needs them: the deploy key goes into that step's `ssh-agent` and its temporary file is removed
     at once.
   - **Integration tests.** Throwaway credentials are generated per build (`IT_SA_PASSWORD`), never stored.
3. **Masked wherever configuration is printed.** The start-up summary, `/actuator/connectorconfig`,
   `run-compose.sh … config | printenv | app-config` and `--print-config` all mask:
   - values whose key is a known secret property, or whose key has a secret-looking segment (`password`,
     `secret`, `token`, `credential`, `*key`);
   - the usernames paired with secret passwords;
   - credentials embedded in URLs (`;password=…`, `user:pass@`).

   `/actuator/env` is never exposed ([ADR-0015](0015-actuator-health-and-metrics-contract.md)).
4. **Detected before merge.** Config-lint check 9 fails on:
   - a secret property key in any YAML layer;
   - a secret-looking value anywhere in the tree: private keys, cloud access keys, GitHub and Slack tokens, a
     literal value assigned to a password-like key, a password inside a JDBC URL.
5. **Host access.** The deploy key reaches the hosts as a fixed deploy user. Host keys are pinned in the reviewed
   `config/<env>/known_hosts`, and an unknown host key is never accepted
   ([ADR-0028](0028-host-pool-deployment.md)).

## Alternatives considered

- **Encrypted secrets in git** (SOPS, sealed secrets). Key management moves into the repository, and ciphertext
  stays in the history forever.
- **Secrets in env layers outside git** (`*.local.env`). Fine on a laptop, and git-ignored for that reason. On
  hosts they would be another file to provision and protect, with no advantage over the deploy user's environment.
- **A secret manager agent on every host.** It is a candidate for the promoted envs; the choice is open.

## Consequences

- Any instance of a flow can be placed on any box of its pool, so every box MUST hold the secret environment of
  every instance of its flow ([ADR-0028](0028-host-pool-deployment.md)).
- How secrets are provisioned and rotated on the hosts of the promoted envs is not decided (open decision).
- The list of secret property names exists twice, in config-lint and in `SecretMasker`, and names connector
  properties. That domain knowledge sits in shared tooling (known gap).
