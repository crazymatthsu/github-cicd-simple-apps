# ADR-0016 — Logs go to stdout with the identity on every line, and every app prints its effective configuration at start-up

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every app; `run-compose.sh` |
| Enforced by | `ConfigurationSummaryTest`, `SecretMaskerTest` and `ConnectorMdcTest` in the framework; the actuator contract test (`connectorconfig` masks secrets); review of each app's `application.yml` |
| Related | [ADR-0003](0003-identity-tuple-names-every-instance.md), [ADR-0011](0011-configuration-tree-and-spring-layers.md), [ADR-0013](0013-secrets.md), [ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md) |

## Context

Logs from many instances end up in one place, so every line must say which instance wrote it. The first
question in most incidents is "what configuration is this instance actually running?". It should be answerable
from the log, from the running instance, or offline, without shell access to the host and without exposing
secrets.

## Decision

1. **stdout is the log channel.** Apps log to stdout. File appenders are optional and write only to `/app/logs`
   (`LOGS_DIR` on the host). The compose template rotates container logs (`json-file`, 10 MB × 3).
2. **Levels.** The root level is `logging.level.root: ${LOG_LEVEL_ROOT:INFO}`, and `LOG_LEVEL_ROOT` is an env-layer
   setting ([ADR-0012](0012-compose-template-and-generated-env.md)). Any other level is a property in a YAML
   layer.
3. **The identity is on every line:**
   - Plain-text lines carry `[<env>/<flow>/<app>/<instance>]` in the level column.
   - Structured JSON adds the fields `env`, `flow`, `app` and `instance`
     (`logging.structured.json.add.*`). Deployed envs SHOULD switch the console to ECS JSON in their flow layer
     (`logging.structured.format.console: ecs`, as `us-dev/cash` does). `local` stays plain text.
   - `ConnectorMdc` puts the identity into the MDC, and `ConnectorMdc.wrap` carries it into worker threads.
4. **The start-up summary.** Once the app is ready it logs `Started <env>/<flow>/<app>/<instance>`, followed by
   its configuration summary:
   - the identity;
   - the configuration layers that were found, lowest precedence first (the `/config/…` files and the secret
     trees);
   - every property under `connector.*` and `spring.datasource.*` with its effective value, secrets masked
     ([ADR-0013](0013-secrets.md)).
5. **The same summary, three ways:**

   | Where | How | When |
   |---|---|---|
   | log | logged once at start-up | always |
   | running instance | `GET /actuator/connectorconfig`; `run-compose.sh … app-config` | the instance is up |
   | offline | `--print-config`: resolves the configuration exactly as a start would, prints the summary to stdout and exits without serving or connecting; `run-compose.sh … app-config --offline` | before a start, or when the instance does not start |

6. **Operations are audited.** `run-compose.sh` writes one audit line per invocation to stderr and to syslog
   (`logger -t run-compose`). The line names the user, host, identity, command, options, result, any shell
   overrides, and the CI run when there is one ([ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)).

## Alternatives considered

- **Log files rotated on the hosts.** State on every box, and an agent to collect it. stdout needs only the
  container runtime.
- **JSON everywhere.** Unreadable on a laptop; the flow layer switches it on per env instead.
- **`/actuator/env` for configuration questions.** It shows every property source, unmasked values included.

## Consequences

- Log collection needs only the containers' stdout, and every line belongs to one instance.
- "What does this instance run with?" has the same answer from the log, the running instance and an offline run.
- Known gaps:
  - the logging block is copied into every app's `application.yml`;
  - the summary's prefixes (`connector`, `spring.datasource`) are domain choices built into the framework, so an
    app with other properties is not summarised until the framework's generic part takes the prefixes as input.
