# ADR-0003 — The identity tuple `<env>/<flow>/<AppName>/<AppInstance>` names every running instance

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every app, every instance, every tool that names one |
| Enforced by | config-lint checks 1 and 4; `run-compose.sh` and `pool-deploy.sh` argument validation; `ConnectorIdentity` (the app refuses to start); `scripts/smoke.sh` (identity in `/actuator/info`) |
| Related | [ADR-0004](0004-environments-and-runtimes.md), [ADR-0011](0011-configuration-tree-and-spring-layers.md), [ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md) |

## Context

One app runs as many instances, in many envs and flows. An operator looking at a log line, a metric, a container,
a deploy record or a directory on a host must be able to tell which instance it belongs to without a lookup
table, and every tool must derive the same names from the same source.

## Decision

1. **The four parts:**

   | Part | Meaning | Grammar |
   |---|---|---|
   | `env` | where it runs | `local`, or `<region>-<stage>`; region: two lower-case letters (`us`, `jp` today); stage: `dev`, `qa`, `uat`, `prod` or `parallel` ([ADR-0004](0004-environments-and-runtimes.md)) |
   | `flow` | a business flow. One flow in one env is one **cluster**, with its own hosts, deploy inventory and shared endpoints | one of the project's flows (`cash`, `deriv`, `swap` today) |
   | `AppName` | the app: its directory under `apps/`, its Gradle project, its image name and its `spring.application.name` | `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, at most 20 characters |
   | `AppInstance` | one configured pipeline of the app in that flow | same grammar, at most 32 characters; a business name, never a bare number; `<AppName>-<AppInstance>` at most 53 characters (the Kubernetes release-name budget) |

2. **The path is the identity.** An instance exists because the directory
   `config/<env>/<flow>/<AppName>/<AppInstance>/` exists ([ADR-0011](0011-configuration-tree-and-spring-layers.md)).
   The instance layer restates the identity — `APP_ENV`, `APP_FLOW`, `APP_NAME` and `APP_INSTANCE` in
   `_docker-compose.instance.env` (and `identity`/`env` in the provisional Helm values). The restated values MUST
   equal the path. The deployer passes them to the container as environment variables.
3. **Every name is derived from the tuple, the same way in every tool:**

   | Where | Name |
   |---|---|
   | compose project | `<env>-<flow>-<AppName>-<AppInstance>`; CI test stacks prefix `ci-<run>-<attempt>-` |
   | container labels | `com.example.env`, `com.example.flow`, `com.example.app`, `com.example.instance` |
   | metric tags, log fields, MDC | `env`, `flow`, `app`, `instance` ([ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md)) |
   | `/actuator/info` | `connector.env`, `.flow`, `.app`, `.instance`, `.tuple`, `.complete` |
   | deploy inventory target | `<AppName>/<AppInstance>`, relative to the flow's `workflows-config.yml` |
   | deploy output and records | `<flow>/<AppName>/<AppInstance>` (plus the box: `…@<host>`) |
   | host bundle | one per `<env>/<flow>`; a box serves exactly one `<env>/<flow>` ([ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)) |
   | Kubernetes (provisional) | release `<AppName>-<AppInstance>` in namespace `<flow>` ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)) |

   App-specific names MAY be derived further, for example the connectors' Deephaven table prefix
   `<flow>_<AppInstance>_`.
4. **The app validates its identity at start-up.** The framework's `ConnectorIdentity` reads `APP_ENV`, `APP_FLOW`,
   `APP_NAME` and `APP_INSTANCE`. The app refuses to start when the identity breaks the grammar, or when `APP_NAME`
   differs from `spring.application.name` — an image started with another app's configuration. Without the variables
   (a laptop, a unit test) the identity is `local/none/<AppName>/none` and is reported as incomplete.
5. **One vocabulary.** The allowed stages, regions and flows MUST be defined once. They are project values
   declared in `platform.yml` ([ADR-0002](0002-one-repository-one-project-one-release-line.md)) and read by every
   implementation: `run-compose.sh`, `pool-deploy.sh`, config-lint and `ConnectorIdentity`.

## Alternatives considered

- **Numbered instances** (`instance-1`). They mean nothing in a log line or an alert, and get reused after a
  deletion.
- **Identity as a property inside the configuration.** It duplicates the path and can drift from it. Instead the
  path is the source, and the restated copy is checked against it.
- **No flow level.** One flow in one env is the unit of isolation: its own hosts, endpoints and inventory.
  Without the level, a shared value would reach every flow of the env.

## Consequences

- Renaming an instance means moving its directory. That makes it a new instance, with a new compose project and
  new names everywhere.
- Two instances on one box are told apart by name, but need distinct `*_HOST_PORT` values
  ([ADR-0012](0012-compose-template-and-generated-env.md)).
- The length limits keep every derived Kubernetes name valid.
- Today the vocabulary is hard-coded in four places that disagree. Config-lint accepts only the regions `us|jp`,
  and nothing accepts the stages `uat` and `parallel`, so an app would refuse to start there. These are known gaps
  in the index.
