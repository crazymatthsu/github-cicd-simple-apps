# ADR-0025 — Integration tests run against compose stacks that laptops and CI share

| | |
|---|---|
| Status | Accepted. Rule 4 superseded in part by [ADR-0033](0033-public-base-image-fallback.md); rule 6 superseded in part by [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) |
| Date | 2026-10-04 |
| Applies to | every app with integration tests; `test-infra/compose/`; `buildlogic.integration-test` |
| Enforced by | `_integration-test.yml` (requires a digest-pinned app image); `stack.sh` (readiness, exit codes); the leak check ([ADR-0024](0024-ephemeral-ci-environments.md)) |
| Related | [ADR-0007](0007-gradle-build-with-convention-plugins.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0026](0026-integration-test-data-and-comparison.md) |

**In short:** Integration tests run against real dependencies and the real app image, started together as a compose
stack. One script, `stack.sh`, starts the same stack on a laptop and in CI, so a CI failure can be reproduced
locally. The app joins the stack the way it is deployed, so a test covers the image and its configuration, not
only the code.

## Context

An integration test should exercise the real image, with the real configuration layering, against real
dependencies. A developer must be able to run exactly what CI runs. Test setups owned by the JVM work one way on a
laptop and another in CI. They also do not start the app the way it is deployed.

## Decision

1. **Compose is the only stack mechanism.** There is no Testcontainers. One script,
   `test-infra/compose/stack.sh up | diagnostics | down | leak-check`, drives every stack. It has two callers:
   - Gradle (`composeUp`, `composeDown`, `devUp`, `devDown`);
   - CI (the `compose-stack` action).
2. **Projects declare their stacks.**
   - `test-infra/compose/stacks.yml` names, per Gradle project, the dependency stacks it needs.
   - Each stack is a file `test-infra/compose/<stack>.yml`. It defines a service of the same name, with a readiness
     health check, run labels and a memory limit.
   - `base.yml` always comes first. `it-runner.yml` defines the test container. `local-ports.yml` is added only on
     laptops.
   - Dependency images are pinned by tag and digest in `test-infra/compose/versions.env`, one line each. Renovate
     updates them.
3. **The app runs as deployed.** When `APP_IMAGE` is set, the stack adds the app the same way it runs in every env:
   - the compose template, the app's override and the instance's overrides;
   - the combined env that `run-compose.sh … compose-env` writes
     ([ADR-0012](0012-compose-template-and-generated-env.md));
   - the configuration of a `local` instance: the one that the test case's manifest names, else the app's only
     `local` instance.
4. **Where the test JVM runs:**
   - **CI:** inside the `it-runner` service (the `ci-build` image), on the stack's network, with no ports
     published: `compose run --rm it-runner ./gradlew :<app>:integrationTest -Pcompose.managed=false`.
   - **Laptop:** on the host JVM, against ports published on `127.0.0.1`. `./gradlew :<app>:integrationTest`
     builds the image, starts the stack, runs the tests, and stops the stack even when they fail.
     `-Pcompose.keep=true` keeps the stack running. Only one stack runs at a time: the root build orders
     each app's `composeUp` after the previous app's `composeDown`, and a build-service lock keeps two stack
     commands from overlapping.

   Both places start the same stack with the same script; only the test JVM sits somewhere else:

   ```mermaid
   flowchart TD
     subgraph laptop ["Laptop"]
       hostjvm["Tests on the host JVM"]
       gradle["./gradlew :{app}:integrationTest"]
     end
     subgraph ci ["CI job"]
       action["compose-stack action"]
       runner["Tests in the it-runner service"]
     end
     up["stack.sh up<br/>same stack files"]
     stack["Compose stack<br/>dependencies, plus the app<br/>through the compose template"]
     gradle -->|with local ports| up
     action -->|without ports| up
     up --> stack
     hostjvm -->|ports on 127.0.0.1| stack
     runner -->|stack network| stack
   ```

5. **The Gradle suite.** `integrationTest` is a JVM test suite in `src/integrationTest/java`. `check` compiles it
   but never runs it, and it is never up to date or cached. Tests read their endpoints from `IT_*` variables through
   the framework's `ItEnvironment`. They check the app through its actuator (`ActuatorClient`).
6. **Two levels:**

   | Level | Dependencies | Runs in |
   |---|---|---|
   | component | the upstream images in `versions.env` | the full tier of pull requests ([ADR-0022](0022-pull-request-pipeline.md)), and `main` for every app |
   | system | the organisation's own server image, pinned by digest in `versions.env` | `main`, for the reference scenario ([ADR-0023](0023-main-pipeline-build-once-test-publish.md)) |

7. **Isolation.**
   - Each run prefixes its target tables with `IT_TABLE_PREFIX=it_<sha7>_`.
   - Database passwords are generated per build (`IT_SA_PASSWORD`).
   - The env is always `local`.
8. **Local development.** `./gradlew devUp` starts the same dependency stacks as one shared compose project,
   `local-dev`. Then `DEPS_NETWORK=local-dev_default scripts/run-compose.sh local …` runs an app against them.

## Alternatives considered

- **Testcontainers.** The JVM owns the lifecycle, so the stack definitions live in test code and differ from what
  CI and operators run. The app image is not started as deployed, and Podman needs special handling.
- **In-memory fakes.** Fast, but they test neither the image nor the configuration nor the real protocols.
- **A shared test environment.** Rejected in [ADR-0024](0024-ephemeral-ci-environments.md).

## Consequences

- A failing CI integration test can be reproduced on a laptop with the same script and the same stack files.
- An integration test covers the image, the entrypoint, the configuration layering and the actuator, not only the
  code.
- The stacks are heavy: SQL Server is amd64-only and runs emulated on Apple silicon.
- A new dependency means a stack file, a pin in `versions.env` and a line in `stacks.yml`.
- Known gaps:
  - `stacks.yml` is maintained by hand;
  - `buildlogic.integration-test` and `it-runner.yml` hard-wire the Deephaven client and the Deephaven and
    SQL Server endpoints — domain choices inside shared tooling.
