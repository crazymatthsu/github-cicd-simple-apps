# ADR-0038 — Each stack publishes its own test environment; the shared integration-test tooling names no dependency

| | |
|---|---|
| Status | Accepted. Supersedes in part rules 2, 5 and 7 of ADR-0025 and rule 3 of ADR-0007 (rule 8) |
| Date | 2026-10-06 |
| Applies to | every app with integration tests; `test-infra/compose/stacks.yml`, `stack.sh` and `it-runner.yml`; `buildlogic.integration-test` |
| Enforced by | `stack.sh up` (refuses a malformed declaration with exit 2); `scripts/test/stack-test.sh` in the `lint` job (stub engine); `StackEnvTest`; the component integration tests of the full tier of pull requests and of `main`; review |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md), [ADR-0007](0007-gradle-build-with-convention-plugins.md), [ADR-0013](0013-secrets.md), [ADR-0024](0024-ephemeral-ci-environments.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md), [ADR-0026](0026-integration-test-data-and-comparison.md) |

**In short:** The shared integration-test tooling no longer knows which dependencies a project has. Each stack
declares in `stacks.yml` what it gives the tests: a seed command, and `KEY=value` entries such as its endpoints and a
generated secret. `stack.sh up` writes those entries to two files: one for the `it-runner`, one for a test JVM on the
host. `it-runner.yml` and the Gradle plugin pass them on without reading them. An app declares the test clients of
its own tests in its own build file.

## Context

[ADR-0025](0025-integration-tests-on-compose-stacks.md) made the stacks project files and the tooling around them
shared ([ADR-0005](0005-repository-layout-and-shared-tooling.md) rule 5). But the shared files still named this
repository's dependencies:

- `buildlogic.integration-test` put the Deephaven Java client on every `integrationTest` classpath and passed Arrow's
  `--add-opens`. It set `IT_DEEPHAVEN_*`, `IT_SQLSERVER_*` and the SQL Server login for the host JVM, and generated
  the SQL Server `sa` password.
- `stack.sh` generated `IT_SA_PASSWORD`, seeded SQL Server whenever a stack had a `sqlserver` service, set
  `SPRING_DATASOURCE_*` for the app, and printed the Deephaven, SQL Server and Kafka endpoints.
- `it-runner.yml` listed the Deephaven and SQL Server endpoints, and required `IT_SA_PASSWORD` even in a stack without
  SQL Server.

So any other Spring Boot app that applied the plugin got Deephaven and SQL Server it did not use, and a repository
with other dependencies had to edit shared tooling, which ADR-0005 forbids (known gap G12).

## Decision

1. **The shared tooling names no dependency.** `buildlogic.integration-test`, `stack.sh`, `base.yml` and
   `it-runner.yml` MUST NOT name a dependency stack, its endpoints, its credentials or a test client. They keep what
   every test needs: the source set and the `integrationTest` task, the stack lifecycle, the app image under test
   and its actuator port, the compose project, `IT_TABLE_PREFIX` and the JUnit wiring. The system level keeps its
   server image override in `_integration-test.yml` (ADR-0025 rule 6): it sets `DEEPHAVEN_IMAGE`, the variable that
   `deephaven.yml` declares for its image.
2. **Each stack declares what it publishes**, in `stacks.yml` under `stacks:`, with the schema below. Every field is
   optional. A stack without a declaration publishes nothing.
3. **One file per view.** `stack.sh up` resolves the `env` entries of the project's stacks, in their order, and
   writes them under `test-infra/compose/.state/`:
   - `<project>.it-runner.env`: the `env` entries, as a JVM on the stack network sees the stack. `it-runner.yml`
     reads it through `env_file`. Its own `environment` wins.
   - `<project>.host.env`: the same entries, each replaced by the `local_env` entry of its key. The plugin passes it
     unchanged to the test JVM on the host.
   - It also exports the `env` entries and records them in the state file and in `$GITHUB_ENV`, so the stack files
     and the app's overrides can interpolate them.
4. **Generated secrets are generic.** `KEY=<generated-secret>` takes the value of the environment when it is set,
   else the value the previous `up` of the project recorded, else a new random one. `stack.sh` masks it in CI and
   never prints it. No tool knows what a secret is for. [ADR-0013](0013-secrets.md) applies unchanged.
5. **Seeds belong to the stack.** A stack's `seed` runs in its own service once the stacks are healthy, before the
   app starts. A failed seed fails `up`.
6. **An app declares its own test clients.** A client library that its integration tests use is an
   `integrationTestImplementation` dependency of the app. The JVM arguments that client needs (`--add-opens`) go on
   the app's `integrationTest` task, in the same build file.
7. **`scripts/test/stack-test.sh`** tests the reading of `stacks.yml` against a stub engine, in the `lint` job with
   the other script tests. It is shared tooling, like the `stack.sh` it tests.
8. **What this supersedes**, in part:
   - ADR-0025 rule 2: `stacks.yml` also declares, per stack, the seed and the variables for the tests.
   - ADR-0025 rule 5: the `IT_*` endpoints that the tests read come from the stack declarations.
   - ADR-0025 rule 7: a password is a `<generated-secret>` of the stack that needs it. `IT_SA_PASSWORD` is this
     repository's name for one, not the tooling's.
   - ADR-0007 rule 3: an app's build file declares its dependencies, its test clients among them, and the JVM
     arguments of its `integrationTest` task.

The `stacks.yml` schema:

| Field | Value | Effect |
|---|---|---|
| `<project>: [<stack>, ...]` | one flow-style line per Gradle project, as before | the stacks `stack.sh up --project` starts |
| `stacks.<stack>.seed` | a command, split on spaces | run with `compose exec -T <stack>` after `up --wait`, before the app |
| `stacks.<stack>.env` | a list of `KEY=value` | the tests' variables, as a JVM on the stack network sees the stack; also exported for compose |
| `stacks.<stack>.local_env` | a list of `KEY=value` | for a JVM on the host: replaces the `env` entry of the same key |
| `${NAME}`, `${NAME:-default}` in a value | `env`, `local_env` | expanded from the entries above and the environment; an unset `${NAME}` fails `up` |
| `<generated-secret>` as a value | `env` | a throwaway secret, reused on a re-run (rule 4) |

`stack.sh` reads the file without yq: block style, two spaces per level. `stacks` is a reserved key, never a
project. An entry for a variable that `stack.sh` sets itself, such as `COMPOSE_FILE` or `IT_TABLE_PREFIX`, fails `up`.

## Alternatives considered

- **Keep the values in the plugin, behind Gradle properties.** Every repository would still set its dependencies in
  Kotlin, and `it-runner.yml` would need a second copy.
- **One env file for both views.** The it-runner and a host JVM reach the stack by different names and ports. One
  file is right for only one of them.
- **Derive the host view from `local-ports.yml`.** Host and container ports do not always match: Kafka publishes a
  second listener for the host. The mapping stays declared.
- **Declarations in the stack files, as `x-` extensions.** Compose ignores them, but `stack.sh` would have to read
  every stack file. It already reads `stacks.yml`.
- **yq.** Laptops would need it. `stacks.yml` stays readable line by line.

## Consequences

- This repository's tests keep their variables and run unchanged. `source-database` still gets `IT_DEEPHAVEN_*`,
  `IT_SQLSERVER_*`, `SPRING_DATASOURCE_USERNAME=sa` and the generated `IT_SA_PASSWORD`, also as
  `SPRING_DATASOURCE_PASSWORD`, and the SQL Server seed still runs. `source-kafka` now gets `IT_KAFKA_HOST` and
  `IT_KAFKA_PORT`.
- A new dependency is a stack file, a pin in `versions.env`, a line and a declaration in `stacks.yml`. No shared file
  changes. Known gap G12 is closed; the consequences of ADR-0007 and ADR-0025 that name it no longer hold.
- An app that applies `buildlogic.integration-test` gets no Deephaven client. `source-database` declares it.
- `stack.sh up` records the actuator port the app publishes. A host JVM now reaches the actuator on the instance's
  own port (18081 for `source-database`), not on the fallback 18080.
