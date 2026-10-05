# ADR-0017 — `run-compose.sh` is the one operations CLI for compose-run instances, and every instance runs hardened

| | |
|---|---|
| Status | Accepted. Rule 5 superseded in part by [ADR-0030](0030-platform-yml-declares-every-project-value.md) |
| Date | 2026-10-04 |
| Applies to | every compose-run instance of this repository: laptops, CI test stacks and the dev hosts |
| Enforced by | its own argument, safety and configuration checks (exit codes 2, 3, 4); ShellCheck and `scripts/test/pool-deploy-test.sh` in the `lint` job; the template's settings ([ADR-0012](0012-compose-template-and-generated-env.md)) |
| Related | [ADR-0004](0004-environments-and-runtimes.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0015](0015-actuator-health-and-metrics-contract.md), [ADR-0018](0018-on-prem-host-layout-versioned-bundles.md), [ADR-0028](0028-host-pool-deployment.md) |

**In short:** One script, `scripts/run-compose.sh`, performs every operation on every compose-run instance of this
repository: on a laptop, in CI and on the dev hosts. It assembles the compose files, the combined env and the
identity itself, applies safety rules, and writes an audit line for every command, whether it succeeds or not. The
compose template, not the apps, gives every container the same hardened runtime.

## Context

Every app needs the same operations — start, stop, health, logs, inspect, roll — on a laptop, in CI and on every
host. With raw compose commands, each operator would assemble the file chain, the combined env, the identity and
the secrets by hand ([ADR-0012](0012-compose-template-and-generated-env.md)). Nothing would enforce safety rules or
leave an audit trail. Docker and Podman, and their compose implementations, also differ in ways that break naive
scripts.

## Decision

1. **One script, every app.** `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> <command> [options]`
   operates every instance. Apps MUST NOT ship wrappers of their own.

   | Command | Does |
   |---|---|
   | `start [--no-wait]`, `stop`, `restart`, `down [--volumes]` | lifecycle; `start` waits for readiness (default 180 s, exit 124 on timeout) |
   | `health` | the container runs, readiness is `UP`, and the smoke test passes (the app's `apps/<AppName>/scripts/smoke.sh` when it ships one, else `scripts/smoke.sh`) |
   | `status` / `ps` | state, plus drift between the desired image and the running one (exit 1 on drift) |
   | `logs [-f] [--since] [--tail]`, `exec`, `shell` | diagnosis |
   | `config`, `printenv`, `app-config [--offline]`, `version` | what runs and with which configuration, secrets masked ([ADR-0016](0016-logging-and-startup-configuration-summary.md)) |
   | `pull` | pre-pull the image; the only command that contacts the registry |
   | `validate` | offline checks: names, required files, env-layer rules, template variables, override paths, `compose config` |
   | `compose-env` | write the combined env and print its path ([ADR-0012](0012-compose-template-and-generated-env.md)) |
   | `record-tag`, `activate` | host bundles only ([ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)); `activate` takes no instance: `run-compose.sh activate [options]` |

2. **Common options:**
   - `--dry-run` prints the resolved paths, files, identity, engine and the exact command lines, and runs nothing.
   - `--json` gives machine-readable `health`, `status` and `version`.
   - `--engine docker|podman` forces an engine.
   - `--force` confirms a guarded operation.

   Exit codes follow [ADR-0005](0005-repository-layout-and-shared-tooling.md): `0` ok, `1` failed, `2` usage,
   `3` refused, `4` configuration, `5` engine, `124` timeout.
3. **The root.** The script resolves its root to the nearest ancestor that holds a `.platform-bundle` manifest (a
   host's version directory), else the git checkout. So the same command line works in a checkout and on a host,
   with no `CONFIG_ROOT`.
4. **Engines.** It uses `docker compose` if present, else `podman compose`, else `podman-compose`. It handles their
   differences:
   - `podman-compose` has no `up --wait`, so `start` polls readiness;
   - the app container is found through its compose labels;
   - a literal network override replaces an interpolated `external` value.

   With rootless Podman every published port is 1024 or above. On SELinux hosts the Spring layer mounts get `:z`
   or `:Z` labels.
5. **Safety rules.** `--force` never lifts them, unless noted:
   - **Allowed envs:** `local` and `*-dev` only. This repository deploys and operates nothing else
     ([ADR-0004](0004-environments-and-runtimes.md)).
   - **Volumes:** `down --volumes` outside `local` requires `--force`.
   - **Pool guard:** an instance runs on one box (host) of its pool at a time. Before `start` or `restart`, the
     script asks the pool's other boxes whether the instance already runs there. If it does, the script refuses
     with exit 3 ([ADR-0028](0028-host-pool-deployment.md)). `--force` skips the guard.
   - **Shell overrides:** only `IMAGE_TAG` and `IMAGE_REPO`, validated, announced and recorded in the audit line.
     `APP_IMAGE` works only in `local`.
   - **Secrets:** required secrets must be set before `start`, `restart`, `validate` or `app-config --offline`
     ([ADR-0013](0013-secrets.md)).
6. **Audit.** Once its options parse, every invocation writes one audit line when it exits, whatever the result
   ([ADR-0016](0016-logging-and-startup-configuration-summary.md)). `--help` writes none.

   Put together, one invocation for an instance runs these steps in order. A failed check stops it with the exit
   code shown; the audit line is written on exit in every case.

   ```mermaid
   flowchart TD
       args["Check the command line<br/>exit 2"]
       safety["Safety rules: allowed envs,<br/>down --volumes needs --force<br/>exit 3"]
       root["Find the root: the version directory<br/>with .platform-bundle, else the checkout"]
       tree["Check the configuration tree<br/>and the env layers<br/>exit 4"]
       envfile["Write the combined env,<br/>shell overrides as the last layer"]
       secrets["Check the required secrets<br/>for start, restart, validate<br/>and app-config --offline"]
       guard["Pool guard before start or restart<br/>exit 3"]
       engine["Pick the engine: docker compose,<br/>else podman compose, else podman-compose<br/>exit 5"]
       run["Run the command,<br/>or only print it with --dry-run"]
       audit["On exit, whatever the result:<br/>write the audit line to stderr and syslog"]
       args --> safety --> root --> tree --> envfile --> secrets --> guard --> engine --> run --> audit
   ```

7. **The hardened runtime of every instance** comes from the template, not from the apps:

   | Setting | Value |
   |---|---|
   | user | non-root `10001` (the image) |
   | root filesystem | read-only; `tmpfs` on `/tmp`; writable `/app/logs` and `/app/data` only |
   | privileges | `cap_drop: [ALL]`, `no-new-privileges:true` |
   | memory | `mem_limit: ${MEM_LIMIT:-1g}`; the heap is a percentage of it |
   | network exposure | only the actuator port, on `127.0.0.1:${ACTUATOR_HOST_PORT}` |
   | restart | `unless-stopped`; 30 s stop grace period |
   | logs | `json-file`, 10 MB × 3 |
   | labels | `com.example.{env,flow,app,instance}`, plus the CI run labels ([ADR-0024](0024-ephemeral-ci-environments.md)) |

   The compose project is `<env>-<flow>-<AppName>-<AppInstance>`. CI test stacks in `local` prefix it with
   `ci-<run>-<attempt>-`.

## Alternatives considered

- **A wrapper per app.** The copies drifted apart, and every fix had to be made in each copy.
- **Raw compose commands in runbooks.** No validation, no safety rules, no audit, and every operator assembles
  the file chain by hand.
- **Configuration management (for example Ansible) for day-to-day operations.** It suits provisioning the hosts.
  But it is heavy for start, stop and health, and it does not run the same way on a laptop.

## Consequences

- Operators learn one CLI, valid for every app and env. Every action is auditable.
- The script is a critical part of the shared tooling (about 1,100 lines of bash). ShellCheck and the stub-based
  tests of `scripts/test/` cover it. It needs bash 4 or later on the hosts.
- The script reads the regions, stages, flows and dev envs from the `platform.yml` of its root, which every host
  bundle carries ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).
