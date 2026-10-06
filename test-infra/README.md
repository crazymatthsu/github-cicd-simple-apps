# test-infra

Dependency stacks, test data and the demo CA for the integration tests ([ADR-0025](../docs/adr/0025-integration-tests-on-compose-stacks.md), [ADR-0026](../docs/adr/0026-integration-test-data-and-comparison.md)). One script,
`compose/stack.sh`, drives the stacks for both callers: the CI workflow and Gradle's
`composeUp` / `composeDown` / `devUp` / `devDown`. A laptop and a runner therefore run the same
commands against the same files. Docker compose is the only stack mechanism of the integration tests
(no Testcontainers, [ADR-0025](../docs/adr/0025-integration-tests-on-compose-stacks.md)). The provisional Helm path adds `kind/`, a throwaway Kubernetes cluster for the Helm
deployment test ([ADR-0019](../docs/adr/0019-kubernetes-and-helm-are-provisional.md)), which is not an integration-test stack.

```
test-infra/
├── ca/                       demo-root-ca.pem: public stand-in for the enterprise CA bundle (README inside)
├── compose/
│   ├── base.yml              first file of every stack: run labels on the default network (ADR-0024)
│   ├── deephaven.yml         Deephaven CI profile: heap, anonymous auth, readiness on 10000 (ADR-0025)
│   ├── sqlserver.yml         SQL Server 2022 Developer, sqlcmd health check, seed mounts
│   ├── kafka.yml             single-node KRaft broker
│   ├── it-runner.yml         the test JVM as a compose service (ci-build image, profile "tools")
│   ├── local-ports.yml       localhost ports for developers; never used in CI
│   ├── versions.env          image references, tag + digest, one line each
│   ├── stacks.yml            which stacks each Gradle subproject declares, and what each stack publishes (ADR-0038)
│   └── stack.sh              up | diagnostics | down | leak-check (scripts/test/stack-test.sh checks its reading of stacks.yml)
├── kind/                     the kind cluster of the Helm deployment test (ADR-0019; README inside)
│   ├── versions.env          pinned kind, kubectl, helm, kubeconform (= the ci-build image pins)
│   ├── cluster.yaml          one control-plane node, no port mappings
│   └── kind.sh               up | load | diagnostics | down | leak-check
├── seed/sqlserver/           generic SQL helpers (databases) + apply.sh, run inside the container
└── testdata/<connector>/<case>/{manifest.yml,input/,expected/}   (ADR-0026)
```

## Stacks

| Gradle subproject | Stacks (`compose/stacks.yml`) |
|---|---|
| `:source-database` | `deephaven`, `sqlserver` |
| `:source-kafka` | `deephaven`, `kafka` |
| `:source-amps` | `deephaven` (AMPS has no public image; stub sink) |
| `:app-runtime` | `deephaven` |

| Service | Image (`versions.env`) | Readiness | Memory (limit) |
|---|---|---|---|
| `deephaven` | `ghcr.io/deephaven/server:42.5` (by digest) | `grpc_health_probe` on 10000 (shipped in the image), bash `/dev/tcp` fallback; 30 s start period + 24 x 5 s | heap `DEEPHAVEN_HEAP` 1536m, limit `DEEPHAVEN_MEM_LIMIT` 2g |
| `sqlserver` | `mcr.microsoft.com/mssql/server:2022-latest` (CU27, by digest, amd64) | `sqlcmd -C ... -Q "SELECT 1"` (`/opt/mssql-tools18`) | `MSSQL_MEMORY_LIMIT_MB` 2048, limit `MSSQL_MEM_LIMIT` 2560m |
| `kafka` | `docker.io/apache/kafka:4.3.1` (by digest) | `kafka-broker-api-versions.sh` | heap 512m, limit `KAFKA_MEM_LIMIT` 1g |
| `it-runner` | `ghcr.io/crazymatthsu/base/ci-build` | started only by `compose run` | limit `IT_RUNNER_MEM_LIMIT` 2g |
| `<AppName>` | `APP_IMAGE` | the app's own HEALTHCHECK | the app template's setting |

Services reach each other by service name on the project network: Deephaven at `deephaven:10000`,
SQL Server at `sqlserver:1433`, Kafka at `kafka:9092`. Nothing is published in CI. Every service,
named volume and network carries `com.example.ci.run` / `com.example.ci.attempt` (the `x-ci-labels`
anchor, repeated in each file because anchors do not cross files). Image-declared volumes are
replaced by labelled named volumes (Deephaven) or tmpfs (Kafka), so no unlabelled anonymous volume
can escape the leak check. A system IT sets `DEEPHAVEN_IMAGE` to the platform's `deephaven-server` image (`DEEPHAVEN_SERVER_IMAGE` in `versions.env`)
([ADR-0025](../docs/adr/0025-integration-tests-on-compose-stacks.md)).

### What a stack publishes ([ADR-0038](../docs/adr/0038-stacks-publish-their-test-environment.md))

The shared tooling (`stack.sh`, `it-runner.yml`, `buildlogic.integration-test`) names no dependency. Each stack
declares under `stacks:` in `compose/stacks.yml` what it gives the tests, all optional:

| Field | Meaning |
|---|---|
| `seed` | a command run in the stack's service (`compose exec -T <stack>`) once the stacks are healthy, before the app |
| `env` | `KEY=value` entries as a JVM on the stack network (it-runner) sees the stack; also exported for compose's interpolation |
| `local_env` | `KEY=value` entries for a test JVM on the host (`--local`): each replaces the `env` entry of its key |

Values expand `${NAME}` and `${NAME:-default}` from the entries above and the environment. `KEY=<generated-secret>`
is a throwaway secret, generated at the first `up` of the project and reused on a re-run (a value set in the
environment wins). This repository declares:

| Stack | `env` (it-runner) | `local_env` (host JVM) | `seed` |
|---|---|---|---|
| `deephaven` | `IT_DEEPHAVEN_HOST=deephaven`, `IT_DEEPHAVEN_PORT=10000` | `localhost`, `DEEPHAVEN_HOST_PORT` (10000) | none |
| `sqlserver` | `IT_SQLSERVER_HOST=sqlserver`, `IT_SQLSERVER_PORT=1433`, `IT_SA_PASSWORD=<generated-secret>`, `SPRING_DATASOURCE_USERNAME=sa`, `SPRING_DATASOURCE_PASSWORD=${IT_SA_PASSWORD}` | `localhost`, `SQLSERVER_HOST_PORT` (1433) | `bash /seed/apply.sh` |
| `kafka` | `IT_KAFKA_HOST=kafka`, `IT_KAFKA_PORT=9092` | `localhost`, `KAFKA_HOST_PORT` (9092) | none |

A test client belongs to the app whose tests use it: `apps/source-database/build.gradle.kts` declares the Deephaven
Java client and the `--add-opens` that Arrow needs. `scripts/test/stack-test.sh` checks the reading of `stacks.yml`
against a stub engine; the `lint` job runs it.

## `compose/stack.sh`

```
stack.sh up --project <gradle path> [--local]   stacks + it-runner (+ the app when APP_IMAGE is set)
stack.sh diagnostics <dir>                      compose-ps.txt, <service>.log, health-<service>.json, stats.txt
stack.sh down                                   down -v --remove-orphans --timeout 20, then prune by label
stack.sh leak-check [--warn-only]               exit 1 if anything carrying this run's labels remains
```

Exit codes: `0` success, `1` compose failure / unhealthy stack / leak, `2` usage, `5` no container
engine or compose, or the engine is unreachable. `stack.sh --help` lists everything.

What `up` does:

1. Merges `base.yml`, the declared `<stack>.yml` files and `it-runner.yml`. When `APP_IMAGE` is set,
   it adds the shared `docker/docker-compose.yml`, the app's `apps/<AppName>/docker/docker-compose.override.yml` and
   the instance's config-tree `_docker-compose.<layer>.yml` overrides ([ADR-0012](../docs/adr/0012-compose-template-and-generated-env.md)); with `--local`, it adds
   `local-ports.yml` filtered to the stack's services. It exports `COMPOSE_FILE`,
   `COMPOSE_PROJECT_NAME` and `COMPOSE_ENV_FILES`: one file, `compose/.state/<project>.compose.env`, which is
   `versions.env` plus the instance's combined env when the app joins (podman-compose keeps only the last of
   several env files).
2. Project name: `COMPOSE_PROJECT_NAME` if set, else `ci-<CI_RUN_ID>-<CI_RUN_ATTEMPT>` in CI
   (`CI_RUN_ID` defaults to `GITHUB_RUN_ID`), else `local-<AppName>`.
3. Sets `IT_TABLE_PREFIX=it_<sha7>_`, `IT_RUNNER_UID/GID` (the caller's), `IT_WORKSPACE` and `IT_GRADLE_HOME`.
   It resolves the `env` entries of the project's stacks (generating each `<generated-secret>`, reused on a re-run),
   exports them, and writes them for the tests: `compose/.state/<project>.it-runner.env` (the `env` entries, read by
   `it-runner.yml` through `env_file`, path in `IT_RUNNER_ENV_FILE`) and `compose/.state/<project>.host.env` (with
   the `local_env` replacements, read by Gradle's `integrationTest` on the host).
4. Records all of it in `compose/.state/<project>.env` (git-ignored, mode 600). In CI it also appends
   it to `$GITHUB_ENV`, masking the generated secrets first, so later steps can run
   `docker compose run --rm it-runner ...` with no further setup.
5. `pull --quiet` of the dependency images, `up --wait --wait-timeout 180` of the dependencies, then
   each stack's `seed` (here `bash /seed/apply.sh` in `sqlserver`, which creates the `positions` and `trades`
   databases). When `APP_IMAGE` is set, a second `up --wait` starts the app after its dependencies are healthy and
   seeded. The app image is not pulled up front, because Gradle's `buildImage` produces it locally.

When the app joins the stack, its template gets what `run-compose.sh` would export ([ADR-0025](../docs/adr/0025-integration-tests-on-compose-stacks.md)):
`APP_ENV=local`, `APP_FLOW` (when unset: the one flow of `config/local/` that configures the app, `cash` for
every app here; several or none is a usage error), `APP_NAME`, and `APP_INSTANCE` (when unset: the `instance:` of
the project's testdata manifests, `positions-db-to-deephaven` for `source-database`; else the app's only instance
directory under `config/local/<flow>/<AppName>/`, as for `source-kafka` and `source-amps`; several candidates
or none is a usage error). It also gets
the Spring layer files (`FLOW_APP_YML`, `APP_APP_YML`, `INSTANCE_APP_YML`), the combined env `COMPOSE_ENV_FILE`
that `scripts/run-compose.sh ... compose-env` writes (one merge implementation), `PROJECT`, the stacks' `env`
entries (`SPRING_DATASOURCE_USERNAME/PASSWORD` here), `ACTUATOR_HOST_PORT` (the combined env's, else `18080`;
recorded, so a host JVM finds the actuator), plus `IMAGE_REPO` and `IMAGE_TAG` derived from `APP_IMAGE` (the combined env's
last layer), so a template written as
`${IMAGE_REPO}/${APP_NAME}:${IMAGE_TAG}` still runs the image under test (a digest-only reference
becomes `by-digest@sha256:...`; the digest wins). `APP_IMAGE` must be
`<registry>/<path>/<AppName>:<tag>`, `...@sha256:<digest>`, or both.

`diagnostics`, `down` and `leak-check` find the stack through `COMPOSE_PROJECT_NAME`, else through
the only state file (with several, pass `--project <gradle path>`). Labels decide what `down` prunes
and what `leak-check` reports. In CI that is the run label, which also catches `run-compose.sh`
stacks of the same run ([ADR-0024](../docs/adr/0024-ephemeral-ci-environments.md)), plus the project label. On a laptop only the project label is
used, because every local stack shares the run label `local`. `down` exits 0 only when nothing is
left.

| Variable | Default | Effect |
|---|---|---|
| `COMPOSE_BIN` | `docker compose` if Docker is installed, else `podman compose` | compose command; the engine CLI is its first word |
| `DEEPHAVEN_IMAGE`, `MSSQL_IMAGE`, `KAFKA_IMAGE`, `CI_BUILD_IMAGE` | `versions.env` | image references; the environment overrides the file (system ITs: the platform's `deephaven-server`, `DEEPHAVEN_SERVER_IMAGE`) |
| `IT_RUNNER_UID`, `IT_RUNNER_GID` | the caller's `id -u` / `id -g` | user the `it-runner` container runs as |
| `STACK_WAIT_TIMEOUT` | `180` | seconds for each `up --wait` |
| `STACK_SKIP_PULL` | unset | `1` skips the pull (offline laptop) |
| `DEEPHAVEN_HEAP`, `DEEPHAVEN_MEM_LIMIT`, `DEEPHAVEN_AUTH_OPTS` | `1536m`, `2g`, anonymous handler | Deephaven profile; `DEEPHAVEN_AUTH_OPTS=-Dauthentication.psk=<key>` switches to a pre-shared key |
| `MSSQL_MEM_LIMIT`, `MSSQL_MEMORY_LIMIT_MB`, `KAFKA_MEM_LIMIT`, `IT_RUNNER_MEM_LIMIT` | see the table above | memory budget (measure, then adjust) |
| `DEEPHAVEN_HOST_PORT`, `SQLSERVER_HOST_PORT`, `KAFKA_HOST_PORT` | `10000`, `1433`, `9092` | local ports with `--local` |

## In CI ([ADR-0024](../docs/adr/0024-ephemeral-ci-environments.md), [ADR-0025](../docs/adr/0025-integration-tests-on-compose-stacks.md))

```yaml
env:
  COMPOSE_PROJECT_NAME: ci-${{ github.run_id }}-${{ github.run_attempt }}
  CI_RUN_ID: ${{ github.run_id }}
  CI_RUN_ATTEMPT: ${{ github.run_attempt }}
  APP_IMAGE: <image built in this run: repo:tag@sha256:...>
steps:
  - run: test-infra/compose/stack.sh up --project ":source-database"
  - run: docker compose run --rm it-runner ./gradlew :source-database:integrationTest -Pcompose.managed=false --no-daemon
  - if: failure()
    run: test-infra/compose/stack.sh diagnostics build/ci-logs
  - if: always()
    run: test-infra/compose/stack.sh down
  - if: always()
    run: test-infra/compose/stack.sh leak-check
```

Inside `it-runner`, the tests see the generic `IT_TABLE_PREFIX`, `APP_IMAGE`, `IT_APP_HOST` (the app's service
alias) and `IT_APP_PORT=8080`, plus the `env` entries of the project's stacks
([ADR-0038](../docs/adr/0038-stacks-publish-their-test-environment.md)). For `:source-database` those are
`IT_DEEPHAVEN_HOST=deephaven`, `IT_DEEPHAVEN_PORT=10000`, `IT_SQLSERVER_HOST=sqlserver`, `IT_SQLSERVER_PORT=1433`,
`IT_SA_PASSWORD`, `SPRING_DATASOURCE_USERNAME=sa` and `SPRING_DATASOURCE_PASSWORD`. The workspace is at
`/workspace` and the host Gradle home at `/gradle-home`. The container runs as the runner's UID/GID, so build
outputs keep their owner.

## Local development

Requirements: Docker with the compose plugin (v2.24 or later), or Podman with a compose provider.
With Podman, `podman compose` should use the `docker-compose` provider, because `--wait` and
`COMPOSE_ENV_FILES` are compose v2 features. Set `COMPOSE_BIN="podman compose"`, which is also the
default when `docker` is missing. SQL Server is amd64 only, so Apple silicon runs it under
emulation and may need `STACK_WAIT_TIMEOUT=300`.

```bash
# dependencies for local work, ports published on 127.0.0.1 (ADR-0025)
./gradlew :source-database:devUp        # stack.sh up --project ... --local (project local-dev)
DEPS_NETWORK=local-dev_default scripts/run-compose.sh local cash source-database positions-db-to-deephaven start
./gradlew :source-database:devDown      # stack.sh down

# or directly
test-infra/compose/stack.sh up --project :source-database --local
test-infra/compose/stack.sh down
```

With `--local`, Deephaven is at `localhost:10000` (anonymous, no login), SQL Server at
`localhost:1433` (user `sa`, password `IT_SA_PASSWORD` in `compose/.state/<project>.env`) and Kafka at
`localhost:9092`. To run compose commands against a running stack, load its state:

```bash
set -a; . test-infra/compose/.state/local-source-database.env; set +a
docker compose ps
docker compose exec -T sqlserver bash /seed/apply.sh --database positions /testdata/source-database/positions-basic/input
docker compose exec sqlserver /opt/mssql-tools18/bin/sqlcmd -C -U sa -P "$IT_SA_PASSWORD" -d positions -Q "SELECT * FROM dbo.positions"
```

## Running the reference IT locally

With Docker (or Podman) available:

```bash
./gradlew :source-database:integrationTest
```

`composeUp` builds the app image (`buildImage`, tag `local`). It then runs
`stack.sh up --project :source-database --local` with `APP_IMAGE` set to that
image, so the connector container starts with `config/local/cash/source-database/positions-db-to-deephaven`
mounted. The tests run on the host JVM against `localhost`, with the variables of
`compose/.state/local-source-database.host.env` and the app's actuator on its `ACTUATOR_HOST_PORT` (18081 for this
instance). `composeDown` (`stack.sh down`) runs even
when they fail. `-Pcompose.keep=true` keeps the stack for debugging; `stack.sh down` removes it
afterwards.

Exactly the CI shape (the test JVM inside `it-runner`, on the stack network):

```bash
test-infra/compose/stack.sh up --project :source-database
( set -a; . test-infra/compose/.state/local-source-database.env; set +a
  docker compose run --rm it-runner ./gradlew :source-database:integrationTest -Pcompose.managed=false --no-daemon )
test-infra/compose/stack.sh down
```

## kind ([ADR-0019](../docs/adr/0019-kubernetes-and-helm-are-provisional.md))

`kind/kind.sh` is the kind counterpart of `compose/stack.sh`. It uses the same exit codes (0 / 1 / 2 /
5), runs teardown in `down` and proves it with `leak-check` ([ADR-0024](../docs/adr/0024-ephemeral-ci-environments.md)). The workflows call it through
`.github/actions/kind-cluster`:

- The `kind-deploy` job (`.github/workflows/_kind-deploy.yml`, in `pr.yml` and `main.yml`) creates
  the cluster `ci-<run_id>-<attempt>`. It loads the app image built in the run, digest in and
  `<repo>:<tag>` on the node, and installs one Helm release per instance of
  `config/us-dev/*/source-database/`. Each release goes through `scripts/helm-deploy-instance.sh`:
  readiness, then `helm test`. A smoke diff across the two releases follows, then `down` and
  `leak-check` in `always()` steps.
- `deploy-dev` runs the same up, load, deploy, down and leak-check steps, without the smoke diff, for
  the `kind: helm` targets with `cluster: kind-ci`. Its cluster is named `deploy-<run_id>-<attempt>`.

`kind/README.md` covers the commands, the image-loading rule, the teardown layers and the local flow:
create, load, deploy both `local` instances, smoke diff, delete.

## Test data ([ADR-0026](../docs/adr/0026-integration-test-data-and-comparison.md))

`testdata/<connector>/<case>/` holds `manifest.yml` (instance, dataset version, input database and
files, expected target and comparison rules), `input/*.sql` and `expected/*.jsonl`. The reference
case `source-database/positions-basic` creates `dbo.positions` (account, instrument, qty, as_of,
ingested_at) in the `positions` database and seeds 8 rows. `expected/positions.jsonl` is canonical
JSON: sorted keys, no whitespace, plain decimals without exponent or trailing zeros, and ISO-8601 UTC
timestamps with milliseconds. Ignored columns such as `ingested_at` are omitted. The SQL files are
single batches without `GO`, so a test can apply them over JDBC or with
`seed/sqlserver/apply.sh`. A dataset's major version follows the connector family's major ([ADR-0026](../docs/adr/0026-integration-test-data-and-comparison.md)).

## What only CI proves

The stacks have been validated with `docker compose config` and a stubbed engine, not run: there is
no Docker daemon in the authoring environment. The first real runs have to confirm several things:
Deephaven 42.5 reaches healthy within the start period on a GitHub-hosted runner; SQL Server starts
with the chosen memory settings; Kafka's dual listeners work; the whole stack fits the runner's
memory (measure with `docker stats`); and the teardown drill (passing, failing and
cancelled runs) leaves nothing behind. `kind/kind.sh` is likewise tested against a stub engine only.
The cluster start, image load, rollout, `helm test`, smoke diff and kind teardown are proven by the
first `kind-deploy` runs.
