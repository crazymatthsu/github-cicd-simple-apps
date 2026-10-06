---
name: add-instance
description: Add a configured instance of an existing app in an env (local or a dev env). Creates the instance directory of the config tree with its Spring layer, its compose env file (identity, image tag, actuator port), the Helm values when kinds includes helm, the deploy target in a dev env, and runs the verification. Use when asked to add, configure or deploy a new instance of an app.
arguments: [env, flow, app, instance]
allowed-tools: Bash(./gradlew *) Bash(scripts/*) Bash(cp *) Bash(sed *) Bash(mkdir *) Bash(grep *) Read Write Edit Glob Grep
---

# Add an instance

The executable form of "Add an instance" in `docs/adr/README.md` (ADR-0003, ADR-0011, ADR-0012, ADR-0043). An
instance exists because its directory exists: `config/<env>/<flow>/<AppName>/<AppInstance>/` (ADR-0003 rule 2).
The templates are those of `add-app`, in `${CLAUDE_SKILL_DIR}/../add-app/templates/config/instance/`.

## Inputs

| Input | Rule |
|---|---|
| `$env` | `local`, or a dev env of `dev_envs` in `platform.yml`; the promoted envs are configured in the configuration repository (ADR-0004) |
| `$flow` | one of the `flows` of `platform.yml`; the app must already be configured in `config/$env/$flow/$app/` |
| `$app` | an existing app of the apps directory |
| `$instance` | a business name in lower-case kebab-case, at most 32 characters, never a bare number; `<AppName>-<AppInstance>` at most 53 characters (ADR-0003) |
| port | an `ACTUATOR_HOST_PORT` free in `$env`: the next unused value above 18080 among `config/$env/*/*/*/_docker-compose.instance.env` (on boxes, free on every box of the pool) |
| image tag | `local` in `local`, `main` in a dev env (ADR-0027) |
| properties | what only this instance sets: endpoints, names, tables; never a secret (ADR-0013) |

## Steps

1. **The instance directory** `config/$env/$flow/$app/$instance/`, from the templates:
   - `application.instance.yml`: the instance's own properties (layer 4, ADR-0011); the template is empty but for
     its header;
   - `_docker-compose.instance.env`: `IMAGE_TAG`, the identity restating the path (`APP_ENV`, `APP_FLOW`,
     `APP_NAME`, `APP_INSTANCE`) and `ACTUATOR_HOST_PORT`; nothing else may set them (ADR-0012);
   - `_helm-values.instance.yaml`, only when `kinds` includes `helm`: `image.tag` equal to `IMAGE_TAG`, the
     identity, and the app-facing `env` (ADR-0019, ADR-0036).

   Placeholders: `__ENV__`, `__FLOW__`, `__APP_NAME__`, `__INSTANCE__`, `__IMAGE_TAG__`, `__PORT__`. No
   subdirectory, no other file (ADR-0011 rule 5).

2. **In a dev env**: a target in `config/$env/$flow/workflows-config.yml` (ADR-0027, ADR-0028):
   ```yaml
     - instance: <app>/<instance> # <AppName>/<AppInstance>, relative to this flow
       kind: compose # any box of the pool; `host: <box>` pins it
   ```
   Use `kind: helm` only when `kinds` includes `helm` and the flow's defaults name a cluster (ADR-0019).

3. **Verify**:
   ```bash
   ./gradlew configLint
   scripts/run-compose.sh <env> <flow> <app> <instance> start --dry-run
   scripts/run-compose.sh local <flow> <app> <instance> start      # local, with a container engine; then health, then down
   ```
   In a dev env the next `main` run deploys it (ADR-0027); check its GitHub Deployment record.

## Never

- Put a secret, a Spring property or an image digest in the env file; config-lint checks 5, 9 and 10 refuse them.
- Let the identity in the files differ from the path; check 4 refuses it.
- Add an instance of a promoted env (`qa`, `uat`, `prod`, ...) here; they live in the configuration repository.
