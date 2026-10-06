# ADR-0037 — The runtime scripts read the generic actuator names first and accept the framework's, so they work with any Spring Boot app

| | |
|---|---|
| Status | Accepted. Supersedes in part rules 3 and 6 of ADR-0015, rule 5 of ADR-0016 and rule 1 of ADR-0017 (rules 2 to 5 and 7) |
| Date | 2026-10-06 |
| Applies to | every app; `scripts/smoke.sh`, `scripts/helm-smoke-diff.sh` and `run-compose.sh app-config`; the framework's `ConnectorInfoContributor` |
| Enforced by | `scripts/test/smoke-test.sh` and `scripts/test/pool-deploy-test.sh` in the `lint` job; `AbstractConnectorApplicationTest` (each app's unit test: the `app` section equals the `connector` section); review |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md), [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0028](0028-host-pool-deployment.md) |

**In short:** The shared runtime scripts check every instance through its actuator. They now read the generic names
first: the `app` section of `/actuator/info` and the `/actuator/appconfig` endpoint. They still accept the connector
framework's names, `connector` and `connectorconfig`. An app that publishes neither passes on readiness, and the
scripts say what they skipped. So a Spring Boot app outside the framework passes `run-compose.sh health` and deploys
like the others, as long as it answers readiness on port 8080. Nothing is renamed: the framework publishes its
identity under both names.

## Context

The runtime scripts were written for the connector framework's contract
([ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0016](0016-logging-and-startup-configuration-summary.md)):

- `scripts/smoke.sh` failed unless `/actuator/info` held a `connector` section. `run-compose.sh health` runs it, so
  the dev deploy ([ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md)) and the pool deploy
  ([ADR-0028](0028-host-pool-deployment.md)) failed with it.
- `scripts/helm-smoke-diff.sh` read `.connector.tuple` and `/actuator/connectorconfig`.
- `run-compose.sh app-config` called `/actuator/connectorconfig`. Its `--offline` passes `--print-config`, which only
  the framework's `ConnectorApplication.run` understands.

So a Spring Boot app not built on `framework/connectors-framework` failed `health` although it was ready. The names
belong to the connector domain (known gap G11). Whether the framework renames them is open decision O5, and this
decision must not presume the answer.

## Decision

1. **Two names, the generic one first.** The shared runtime scripts MUST read the generic name first and MUST accept
   the framework's:

   | What | Generic name | Framework name |
   |---|---|---|
   | the identity section of `/actuator/info` | `app` | `connector` |
   | the masked configuration summary ([ADR-0016](0016-logging-and-startup-configuration-summary.md)) | `/actuator/appconfig` | `/actuator/connectorconfig` |

2. **The identity section** carries `env`, `flow`, `app`, `instance` and `tuple` (`<env>/<flow>/<app>/<instance>`),
   and MAY carry `complete`. An app that wants its identity checked after every start MUST publish it under `app`.
   An `app` section without any of these fields, such as Spring Boot's `info.app.*` properties, is not an identity
   section. When an app publishes both sections, they MUST carry identical values.
3. **The framework publishes both names.** Its info contributor puts one map under `app` and under `connector`. It
   keeps `connectorconfig`, the `connector` health indicator and `--print-config`, and adds no `appconfig` endpoint.
4. **Smoke test, check 2.** `scripts/smoke.sh` reads the `app` section, else the `connector` section. With jq it
   compares `env`, `flow`, `app` and `instance`; without jq, the section's `tuple`. A wrong or unset part fails, as
   before, and so do two sections that disagree. When neither section is present, check 2 is skipped with a warning
   and the test exits 0. Check 1, readiness `UP`, still gates `run-compose.sh health`, the dev deploy and the pool
   deploy.
5. **`run-compose.sh app-config`** calls `/actuator/appconfig`, then `/actuator/connectorconfig`, and says which one
   answered. When neither answers, it fails with exit 1. `--offline` still runs the image with `--print-config`. When
   that run exits non-zero, the script says that the configuration did not resolve or that the app has no offline
   summary.
6. **`scripts/helm-smoke-diff.sh`** compares the identity tuples and the configuration summaries, each read in the
   order of rule 1. A check that neither release answers is skipped with a warning. A check that only one release
   answers fails. Its exit codes do not change.
7. **Exposed endpoints.** An app exposes `health`, `info` and `prometheus`, plus the endpoint of its configuration
   summary when it has one: `appconfig`, or `connectorconfig` on the framework. No other endpoint is exposed.

## Alternatives considered

- **Rename the framework's names now.** That is the owner's decision (O5). It would also break, in one step, every
  dashboard, runbook and chart that reads `connector` or `connectorconfig`.
- **A setting that names the section per app**, in `platform.yml` or the env layers. More configuration for what two
  fixed names cover.
- **Fail when no identity is published**, as before. An app outside the framework could not be deployed at all.
- **Skip the check silently.** An operator could not tell a checked identity from an unchecked one.

## Consequences

- A Spring Boot app outside the framework passes `run-compose.sh health`, the dev deploy and the pool deploy on
  readiness alone. The smoke test's warning says that its identity was not checked.
- An app gets the identity check by publishing the `app` section: an `InfoContributor` of a few lines, like the
  framework's `ConnectorInfoContributor`.
- `/actuator/info` of a framework app carries the identity twice. The chart's smoke-test Pod
  ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)) matches the `tuple` string, which both sections carry.
- An app that ignores `--print-config` may start as usual under `app-config --offline` instead of exiting. The
  script can report only a non-zero exit.
- The generic names `app` and `appconfig` are what a future rename of the framework will adopt (open decision O5).
  Until then, the scripts read both names.
- Known gap G11 stays open: the framework still mixes the generic contract with the connector domain. The scripts no
  longer depend on it.
