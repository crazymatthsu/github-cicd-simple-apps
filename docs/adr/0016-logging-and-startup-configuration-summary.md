# ADR-0016 — Logs go to stdout with the identity on every line, and every app prints its effective configuration at start-up

| | |
|---|---|
| Status | Accepted. Rule 5 superseded in part by [ADR-0037](0037-runtime-scripts-read-generic-actuator-names.md) and [ADR-0040](0040-actuator-contract-and-runtime-module-carry-generic-names.md). Rule 4 superseded in part by [ADR-0042](0042-property-roots-and-secret-properties-in-platform-yml.md) |
| Date | 2026-10-04 |
| Applies to | every app; `run-compose.sh` |
| Enforced by | `ConfigurationSummaryTest`, `SecretMaskerTest` and `ConnectorMdcTest` in the framework; the actuator contract test (`connectorconfig` masks secrets); review of each app's `application.yml` |
| Related | [ADR-0003](0003-identity-tuple-names-every-instance.md), [ADR-0011](0011-configuration-tree-and-spring-layers.md), [ADR-0013](0013-secrets.md), [ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md) |

**In short:** Every app logs to stdout, and every log line names the instance that wrote it. Once ready, every app
also logs its effective configuration with secrets masked, and the same summary is available from the running
instance and offline. So "what is this instance running with?" can be answered without shell access to the host.

## Context

Logs from many instances end up in one place, so every line must say which instance wrote it.

In most incidents the first question is "what configuration is this instance actually running?". We want to answer
it from the log, from the running instance, or offline. The answer should need no shell access to the host, and it
must not expose secrets.

## Decision

1. **stdout is the log channel.** Apps log to stdout. File appenders are optional and write only to `/app/logs`
   (on a box, the instance's `<LOGS_DIR>/<AppName>/<AppInstance>`,
   [ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)). The compose template rotates container logs
   (`json-file`, 10 MB × 3).
2. **Levels.** The root level is `logging.level.root: ${LOG_LEVEL_ROOT:INFO}`, and `LOG_LEVEL_ROOT` is an env-layer
   setting ([ADR-0012](0012-compose-template-and-generated-env.md)). Any other level is a property in a YAML
   layer.
3. **The identity is on every line:**
   - Plain-text lines carry `[<env>/<flow>/<app>/<instance>]` in the level column.
   - Structured JSON adds the fields `env`, `flow`, `app` and `instance`
     (`logging.structured.json.add.*`). Deployed envs SHOULD switch the console to ECS JSON (Elastic Common
     Schema) in their flow layer (`logging.structured.format.console: ecs`, as `us-dev/cash` does). `local` stays
     plain text.
   - `ConnectorMdc` puts the identity into the MDC, SLF4J's per-thread logging context. `ConnectorMdc.wrap`
     carries it into worker threads.

   The identity reaches a log line by these three routes:

   ```mermaid
   flowchart LR
       ident["Identity<br/>APP_ENV, APP_FLOW, APP_NAME, APP_INSTANCE"]
       pattern["logging.pattern.level"]
       add["logging.structured.json.add.*"]
       mdc["ConnectorMdc puts it in the MDC,<br/>wrap carries it to worker threads"]
       plain["Plain-text line<br/>env/flow/app/instance in the level column"]
       json["Structured JSON line<br/>fields env, flow, app, instance"]
       ident --> pattern --> plain
       ident --> add --> json
       ident --> mdc --> json
   ```

4. **The start-up summary.** Once the app is ready, it logs `Started <env>/<flow>/<app>/<instance>`, followed by
   its configuration summary:

   > **Superseded in part by [ADR-0042](0042-property-roots-and-secret-properties-in-platform-yml.md) rule 1.** The
   > summary shows every property under the roots of `platform.yml` `property_prefixes` and under `spring.datasource`;
   > `connector` is this repository's root.

   - the identity;
   - the configuration layers that were found, lowest precedence first (the `/config/…` files and the secret
     trees, such as `/secrets/`, with one file per property);
   - every property under `connector.*` and `spring.datasource.*` with its effective value, secrets masked
     ([ADR-0013](0013-secrets.md)).
5. **The same summary, three ways:**

   > **Superseded in part by [ADR-0037](0037-runtime-scripts-read-generic-actuator-names.md) rule 5.** `run-compose.sh
   > app-config` reads `/actuator/appconfig`, then `/actuator/connectorconfig`, and says which one answered.
   > **Superseded in part by [ADR-0040](0040-actuator-contract-and-runtime-module-carry-generic-names.md) rule 1.**
   > The running instance serves the summary at `/actuator/appconfig`.

   | Where | How | When |
   |---|---|---|
   | log | logged once at start-up | always |
   | running instance | `GET /actuator/connectorconfig`; `run-compose.sh … app-config` | the instance is up |
   | offline | `--print-config`; `run-compose.sh … app-config --offline` | before a start, or when the instance does not start |

   `--print-config` resolves the configuration exactly as a start would. It prints the summary to stdout and exits
   without serving or connecting.

   All three ways use the same summary code:

   ```mermaid
   flowchart LR
       summary["ConfigurationSummary<br/>secrets masked"]
       startlog["Start-up log<br/>once, when the app is ready"]
       endpoint["GET /actuator/connectorconfig<br/>while the instance is up"]
       offline["The --print-config flag<br/>prints, then exits"]
       appconfig["run-compose.sh app-config"]
       appoffline["run-compose.sh app-config --offline"]
       summary --> startlog
       summary --> endpoint
       summary --> offline
       appconfig -->|calls| endpoint
       appoffline -->|runs the app with| offline
   ```

6. **Operations are audited.** `run-compose.sh` writes one audit line per invocation when it exits, to stderr and to
   syslog (`logger -t run-compose`); only `--help` and an unparseable option write none. The line names the user,
   host, identity, command, options, result, any shell overrides, and the CI run when there is one
   ([ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)).

## Alternatives considered

- **Log files rotated on the hosts.** Every box would hold state, and an agent would have to collect it. stdout
  needs only the container runtime.
- **JSON everywhere.** Unreadable on a laptop; the flow layer switches it on per env instead.
- **`/actuator/env` for configuration questions.** It shows every property source, unmasked values included.

## Consequences

- Log collection needs only the containers' stdout, and every line belongs to one instance.
- "What does this instance run with?" has the same answer from the log, the running instance and an offline run.
- Known gaps:
  - the logging block is copied into every app's `application.yml`;
  - the summary's prefixes (`connector`, `spring.datasource`) are domain choices built into the framework. An app
    with other properties is not summarised until the framework's generic part takes the prefixes as input.
