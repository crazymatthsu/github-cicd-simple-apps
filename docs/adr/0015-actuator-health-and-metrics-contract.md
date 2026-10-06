# ADR-0015 — Every app exposes the same operational contract: actuator endpoints, health groups and metrics

| | |
|---|---|
| Status | Accepted. Rules 3 and 6 superseded in part by [ADR-0037](0037-runtime-scripts-read-generic-actuator-names.md) |
| Date | 2026-10-04 |
| Applies to | every app |
| Enforced by | `AbstractConnectorApplicationTest` (each app's unit tests); `scripts/smoke.sh` after every start; the readiness health check of the compose template; `ConnectorIdentity` (the app refuses to start) |
| Related | [ADR-0003](0003-identity-tuple-names-every-instance.md), [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md) |

**In short:** Every app answers the same four actuator endpoints on port 8080, with the same health groups and the
same identity tags on its metrics. So health checks, the smoke test, deploys, Kubernetes probes and dashboards work
with any app without knowing which one it is. The shared framework provides all of this, and a shared test class
checks it in every app.

## Context

The same tools must work with every app, without any per-app knowledge:

- the compose health check and `start --wait`;
- `run-compose.sh health`, `status` and `app-config`;
- the smoke test;
- the deploy's health gate;
- Kubernetes probes, later;
- dashboards and alerts.

That works only if every app answers the same endpoints, with the same meaning and the same identity labels.

## Decision

1. **The framework provides the contract.** Every app depends on the framework module
   ([ADR-0006](0006-apps-and-framework-modules.md)). Its auto-configuration registers:
   - the identity (`ConnectorIdentity`, validated at start-up,
     [ADR-0003](0003-identity-tuple-names-every-instance.md));
   - the common metric tags;
   - the health indicator `connector`;
   - the identity in `/actuator/info`;
   - the `connectorconfig` endpoint;
   - the start-up summary ([ADR-0016](0016-logging-and-startup-configuration-summary.md)).
2. **One port.** The app and the actuator share HTTP port `8080`.
3. **Exposed endpoints: exactly `health`, `info`, `prometheus` and `connectorconfig`.** No other endpoint is
   exposed. In particular, `env`, `configprops`, `beans` and `heapdump` are never exposed: they can reveal secrets.
4. **Health groups:**

   | Endpoint | Contains | Meaning |
   |---|---|---|
   | `/actuator/health/liveness` | `livenessState` | the JVM is alive; restart it when this fails |
   | `/actuator/health/readiness` | `readinessState` + `connector` | the instance can do its work; deploys and rollouts wait for this |
   | `/actuator/health` | every indicator, details shown | diagnosis (for example `db`, `sourceDatabase`) |

   A restart cannot fix a dependency, so an external dependency MUST NOT be part of liveness. It affects readiness
   only through the `connector` indicator, which reports whether the pipeline can work.
5. **Who uses which probe:**
   - the image's `HEALTHCHECK` uses liveness;
   - the compose template's health check uses readiness (10 s interval, 120 s start period), so
     `run-compose.sh start` returns only when the instance is ready;
   - Kubernetes (provisional) uses liveness for its startup and liveness probes, and readiness for its readiness
     probe;
   - `run-compose.sh health` checks that the container runs, that readiness is `UP`, and that the smoke test passes
     ([ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)).

   In the picture, each arrow points from a tool to the endpoint it calls.

   ```mermaid
   flowchart LR
       subgraph port ["The app, on port 8080"]
           live["/actuator/health/liveness<br/>livenessState"]
           ready["/actuator/health/readiness<br/>readinessState + connector"]
           infoep["/actuator/info<br/>build and identity"]
       end
       img["Image HEALTHCHECK"] --> live
       k8slive["Kubernetes startup<br/>and liveness probes"] --> live
       composehc["Compose health check<br/>run-compose.sh start waits for it"] --> ready
       k8sready["Kubernetes readiness probe"] --> ready
       health["run-compose.sh health"] --> ready
       health --> smoke["Smoke test"]
       smoke --> ready
       smoke -->|compares the identity| infoep
   ```

6. **`/actuator/info`** carries:
   - the build: version, git sha, branch, dirty flag and version kind, from the build info
     ([ADR-0007](0007-gradle-build-with-convention-plugins.md));
   - the Java runtime;
   - `connector`: `env`, `flow`, `app`, `instance`, `tuple` and `complete`.

   The smoke test compares this identity with the instance that was started.
7. **`/actuator/prometheus`** (Micrometer) tags every meter with `env`, `flow`, `app` and `instance`.
8. **Graceful shutdown.** `server.shutdown: graceful` and `spring.lifecycle.timeout-per-shutdown-phase: 20s`, within
   a 30 s stop grace period (compose `stop_grace_period`, Kubernetes `terminationGracePeriodSeconds`). Java runs
   as PID 1, so the stop signal reaches it ([ADR-0009](0009-one-shared-image-definition.md)).
9. **The contract is tested.** Each app has a unit test that extends `AbstractConnectorApplicationTest`. It starts
   the whole app on a random port and asserts:
   - liveness and readiness are `UP`, and readiness includes `connector`;
   - `/actuator/info` carries the identity and the build;
   - Prometheus output carries the four tags;
   - `/actuator/connectorconfig` masks secrets.

   Integration tests check a running container through `ActuatorClient`.

## Alternatives considered

- **Endpoints chosen per app.** Every tool and dashboard would need to know each app.
- **A separate management port.** One more port to publish, secure and probe. With one port, the template
  publishes only that port, on `127.0.0.1`.
- **Dependencies in liveness.** A database outage would restart every instance in a loop, without fixing anything.

## Consequences

- The runtime tools, the smoke test and dashboards are app-agnostic: they work with any app unchanged.
- A real pipeline reports its source and sink connections in the `connector` indicator, so starts and rollouts
  wait for a working pipeline. The current apps report `UP` with their identity and sink.
- `show-details: always` shows every component's details to whoever can reach the port. The compose template
  limits that by binding the port to `127.0.0.1` on the host.
- Known gaps:
  - the `management`, `server` and `logging` blocks are copied into every app's `application.yml` instead of
    coming from the framework;
  - the contract's implementation and names (`connectorconfig`, `connector`) belong to the connector framework, so
    an app outside that domain would need the generic part split out (open decision).
