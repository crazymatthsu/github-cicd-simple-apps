# ADR-0045 — Every tool prefers Podman and `podman compose`, then Docker and `docker compose`; CI pins Docker

| | |
|---|---|
| Status | Accepted. Supersedes in part rule 4 of ADR-0009 and rule 4 of ADR-0017 (rule 5) |
| Date | 2026-10-07 |
| Applies to | every shared tool that picks a container engine: `buildImage` and `pushImage`, config-lint check 6, `scripts/run-compose.sh`, `test-infra/compose/stack.sh`, `test-infra/kind/kind.sh`, `scripts/ci/public-base-smoke.sh`; every workflow that runs one of them |
| Enforced by | `ContainerEnginesTest` (the order of the image build and of config-lint's compose); `scripts/test/engine-order-test.sh` in the `lint` job (the order of the three scripts, `CONTAINER_ENGINE` and the tools' own settings, against stub engines); review of the workflows' `env` |
| Related | [ADR-0009](0009-one-shared-image-definition.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0018](0018-on-prem-host-layout-versioned-bundles.md), [ADR-0021](0021-ci-layering.md), [ADR-0024](0024-ephemeral-ci-environments.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

**In short:** On a machine with both engines, every tool used Docker. They now use Podman, with `podman compose`,
and fall back to Docker, with `docker compose`, only when Podman is missing or does not answer. One variable,
`CONTAINER_ENGINE=podman|docker`, names the engine for every tool at once. CI sets it to `docker`, so the pipeline
runs as before.

## Context

The tooling supports both engines and has from the start. The image build passes `--format docker` to Podman, so
`HEALTHCHECK` survives ([ADR-0009](0009-one-shared-image-definition.md)). Published ports are 1024 or above, for
rootless Podman. Mounts carry SELinux labels. `run-compose.sh` works around the faults of podman-compose
([ADR-0012](0012-compose-template-and-generated-env.md),
[ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)). Every image reference is fully qualified, as
Podman requires.

Each tool still chose Docker first, and each chose in its own way:

| Tool | Order before this ADR | Setting |
|---|---|---|
| `buildImage`, `pushImage` | Docker, then Podman: the first whose daemon or service answers `info` | `-Pimage.engine`, `CONTAINER_ENGINE` |
| config-lint check 6 | `docker compose`, `podman compose`, `docker-compose`, `podman-compose` | `-PconfigLint.compose` |
| `run-compose.sh` | `docker compose`, then `podman compose`, then `podman-compose` | `--engine`, `RUN_COMPOSE_ENGINE` |
| `stack.sh` | `docker compose`, then `podman compose` | `COMPOSE_BIN` |
| `kind.sh` | Docker when installed, else Podman | `KIND_EXPERIMENTAL_PROVIDER` |
| `public-base-smoke.sh` | Docker | `CONTAINER_ENGINE` |

So a laptop or a box with both engines ran Docker. Choosing Podman meant setting five variables. The tools did not
even agree when Docker was down: with its daemon stopped, Gradle built the image with Podman, and
`public-base-smoke.sh` then looked for it in Docker. Podman runs rootless and needs no daemon, which is how the boxes
of a pool should run instances.

GitHub-hosted runners carry both engines too. The pipeline, though, is wired to Docker. The build job reaches the
host's Docker engine through its socket ([ADR-0021](0021-ci-layering.md) rule 6). The `registry-login` action writes
Docker's credentials. The bootstrap builds of the base images use buildx with the GitHub Actions cache, and kind runs
on Docker. Podman has never run in this pipeline: the nightly workflow lists a Podman parity drill as later work.

## Decision

1. **Podman first, then Docker.** Every tool that picks a container engine tries Podman, then Docker, and takes the
   first one that is usable:
   - **Usable** means the CLI is on the PATH and its service (Podman) or daemon (Docker) answers `info`. A tool that
     runs compose also needs a compose CLI that answers `version`.
   - **The compose CLI** under Podman is `podman compose`, else `podman-compose`. Under Docker it is
     `docker compose`. config-lint also accepts the standalone `docker-compose`, after these three.
   - **Commands that need no engine** take the first engine whose compose answers, without asking for `info`:
     config-lint's render, and the `run-compose.sh` commands that work offline (`validate`, `config`, `printenv`,
     `compose-env`, `record-tag`, `--dry-run`).
   - **`stack.sh` needs compose v2.** `up --wait` and `COMPOSE_ENV_FILES` are compose v2 features
     ([ADR-0025](0025-integration-tests-on-compose-stacks.md)). So `stack.sh` takes `podman compose` only when it runs
     the `docker-compose` provider. When it runs podman-compose, `stack.sh` moves on to Docker.
   - **kind tries Docker first on its own.** When `kind.sh` chooses Podman, it exports
     `KIND_EXPERIMENTAL_PROVIDER=podman` for kind.
   - **The image is built where it runs.** `public-base-smoke.sh` picks its engine and passes it to `buildImage`, so
     the image it runs is in that engine's store.
2. **One variable names the engine for every tool.** `CONTAINER_ENGINE=podman` or `docker` sets the engine of every
   tool of rule 1; `auto`, or no value, is the order of rule 1. A tool's own setting still wins over it:
   `-Pimage.engine`, `-PconfigLint.compose`, `--engine` and `RUN_COMPOSE_ENGINE`, `COMPOSE_BIN`,
   `KIND_EXPERIMENTAL_PROVIDER`. A named engine that is not usable is an error (exit 5 in the scripts, a failed or
   skipped Gradle task as before). The tool does not fall back to the other engine.
3. **CI runs on Docker.** Every workflow whose jobs run a tool of rule 1 MUST set `CONTAINER_ENGINE: docker` in its
   top-level `env`: `_deploy-dev.yml`, `_gradle-build.yml`, `_integration-test.yml`, `_kind-deploy.yml`,
   `config-lint.yml`, `nightly.yml` and `pr.yml`. The steps that run compose themselves take the same engine
   (`${COMPOSE_BIN:-${CONTAINER_ENGINE:-docker} compose}`). A script test that stubs Docker also puts a stub Podman
   that answers nothing on its PATH, so a real Podman on the machine that runs the test changes nothing. Moving CI
   to Podman is a separate decision.
4. **Laptops and boxes follow rule 1.** A box of a host pool
   ([ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)) that has Podman runs its instances with Podman.
   `pool-deploy.sh` sends no engine to the box. On a box that must run Docker although it has Podman, the deploy
   user's environment sets `CONTAINER_ENGINE=docker`. The requirement of ADR-0018, "docker or podman with compose",
   is unchanged.
5. **What this decision supersedes:**
   - [ADR-0009](0009-one-shared-image-definition.md) rule 4, in part: `buildImage` tries Podman, then Docker, and
     picks the first whose service or daemon answers. `-Pimage.engine` or `CONTAINER_ENGINE` still names one;
   - [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md) rule 4, in part: `run-compose.sh` uses
     `podman compose`, else `podman-compose`, else `docker compose`, and the engine step of the flowchart under
     rule 6 follows. `--engine` of rule 2 now falls back to `RUN_COMPOSE_ENGINE`, then `CONTAINER_ENGINE`.

## Alternatives considered

- **Keep Docker first and document `CONTAINER_ENGINE=podman`.** The default would stay the opposite of the
  preference, and every laptop and box would carry a setting to undo it. A forgotten setting also splits a build from
  its run, as the context shows.
- **Prefer Podman in CI too.** The job container, the registry login, the base-image bootstrap and kind would all
  have to move to Podman, and none of that has run here. That is a pipeline change with its own risks, not part of
  an order of preference.
- **Keep one setting per tool.** Five variables for one choice is how the tools came to disagree. Each tool keeps its
  own setting for the exceptions, and `CONTAINER_ENGINE` covers the common case.

## Consequences

- On a machine with both engines, images are built into Podman's store, and the stacks and instances run on Podman.
  `CONTAINER_ENGINE=docker` restores the old behaviour in one place.
- A laptop where `podman compose` runs podman-compose gets Docker for `stack.sh` when Docker answers. Without
  Docker, `stack.sh` exits 5 and says to install the `docker-compose` provider. `run-compose.sh` accepts
  podman-compose and polls readiness, as ADR-0017 rule 4 describes.
- `kind.sh` now creates clusters with Podman where Podman answers. kind still calls its Podman provider
  experimental. `CONTAINER_ENGINE=docker` or `KIND_EXPERIMENTAL_PROVIDER=docker` keeps Docker.
- CI does not change. The pinned workflows run every tool on Docker, as before. The new `engine-order-test.sh` runs
  in the `lint` job, and `pool-deploy-test.sh` hides a real Podman behind a stub that answers nothing.
- No known gap opens or closes.
