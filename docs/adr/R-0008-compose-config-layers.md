# R-0008 — One compose template, and the config layers are files merged into one generated env

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Supersedes | R-0004's directory `config/<env>/<flow>/_common/` (the cluster layer stays, as files); R-0007's consequence "the apps keep `docker/docker-compose.yml`" |
| Deviates from | D5 §6.1–§6.4 and D12 §6.2 names (`app-common/`, `_common/`, `compose.env`, `values.yaml`) — the platform scripts here are vendored copies; to be proposed upstream in github-demo |
| Platform decisions applied | DL-44 (the cluster layer), D6 §6.2–§6.7 (run-compose.sh), D12 §6.2 ("one shared compose template with per-app overrides") |

## Context

On-prem runs on podman compose; EKS will use Helm later. Every app carried its own `docker/docker-compose.yml`; the
three differed only in the service name and source-database's two secret pass-through lines. Compose variables could
be set only per instance (`<AppInstance>/compose.env`), so `IMAGE_REPO`, `TZ`, `JAVA_OPTS` and `MEM_LIMIT` were
repeated in every instance of an app and of a flow. The layers were directories (`_common/`, `app-common/`) mounted
whole into the container, which config-lint requires to be flat.

Measured on podman 5.8.2 / podman-compose 1.6.0 (the latest release): repeated `--env-file` keeps only the **last** file
and `COMPOSE_ENV_FILES` is ignored, while an `env_file:` list in a service does layer; an `env_file:` value cannot fill a
`${VAR}` of the compose file. While implementing this, two older faults showed up under podman-compose: `external:
${DEPS_NETWORK_EXTERNAL:-false}` reads the string "false" as true (every `run-compose.sh start` without `DEPS_NETWORK`
failed), and `ps -q <service>` is rejected (so `health` and `status` never found the container); and `podman compose`
running podman-compose was treated as the Docker plugin, whose `up --wait` podman-compose ignores.

## Decision

- **One compose template**, `docker/docker-compose.yml`: the service is `app`, with the network alias `${APP_NAME}`
  (compose does not interpolate mapping keys; the test stack's it-runner still reaches the app by its AppName). What
  one app needs in every env goes in `apps/<AppName>/docker/docker-compose.override.yml` (source-database: its
  `SPRING_DATASOURCE_*` pass-through with the `:?` guard).
- **The layers are files** in the directory of their level — no layer directories, so config-lint check 1 holds:

  ```
  config/<env>/<flow>/                  application.flow.yml  _docker-compose.flow.env  _docker-compose.flow.yml
  config/<env>/<flow>/<AppName>/        application.app.yml  _helm-values.app.yaml  _docker-compose.app.env / .yml
  config/<env>/<flow>/<AppName>/<Inst>/ application.instance.yml  _docker-compose.instance.env  _helm-values.instance.yaml
                                        _docker-compose.instance.yml
  ```

  `application.<layer>.yml` is what the app reads and the only kind of file that reaches the container; the
  `_`-prefixed files are read on the host by compose or Helm. `<layer>` must match the level (config-lint).
- **Spring layers** are mounted one file each, read-only, at the container paths of before
  (`/config/{flow,common,instance}/application.yml`): the jars' import lists do not change. A missing flow layer mounts
  `/dev/null`. Mounting a directory would now expose every app and instance of the flow.
- **Compose files** merge in order: the template, the app's override, `_docker-compose.flow.yml`, `.app.yml`,
  `.instance.yml`, each when it exists. Overrides carry structure, never relative paths (compose resolves them against
  `docker/`); config-lint check 6 and `run-compose.sh validate` reject them.
- **Env layers** merge per key, flow < app < instance < the shell (`IMAGE_TAG` / `IMAGE_REPO` only), into ONE combined
  env that `run-compose.sh` regenerates on every command at `.run/<env>/<flow>/<AppName>/<AppInstance>/compose.env`
  under its root (the checkout, or the box's version directory). Only the winning value per key is written, each after
  a comment naming its layer and what it overrode, so `printenv` shows why every value is what it is. It is passed as
  the one `--env-file` and loaded by the template's `env_file:`. `IMAGE_TAG`, the identity and `*_HOST_PORT` belong in
  the instance layer only; `record-tag` writes `IMAGE_TAG` there. `run-compose.sh ... compose-env` writes it and prints
  its path, so `stack.sh` uses the same merge (and passes `versions.env` + the combined env as one file).
- **The podman-compose faults** above are fixed: `DEPS_NETWORK` adds a generated override with a literal
  `external: true`; the app container is found by its compose labels (`com.docker.compose.project` / `.service`) through
  the engine; `podman compose` backed by podman-compose polls the readiness probe instead of `up --wait`.
- **A deployable app** is a subproject that applies `buildlogic.docker-image` (config-lint); scripts take an app from
  the config tree, and its subproject directory is optional (a bundle carries it only for an override or smoke test).
- **Helm is deferred** until the EKS work: the values files are only renamed (`_helm-values.<layer>.yaml`) and the
  scripts and config-lint follow the paths; the charts, their rules, the ExternalSecret keys (`.../app-common`, a secret
  store path) and the kind tier are unchanged.
- `application.<layer>.env` files are **not** introduced: environment variables beat every Spring config file, so an
  app-level one would override the instance's YAML and invert the layering.

## Alternatives

- **Several `--env-file` flags**: drops every lower layer on podman-compose 1.6.0.
- **An `env_file:` list per layer**: layers the container environment, but cannot fill `${VAR}` (`IMAGE_TAG`,
  `MEM_LIMIT`, the port), so those could come from the instance only.
- **Layer directories with a `_docker/` subdirectory**: breaks the flat-layer rule and repeats the layer in the
  directory and the file name.
- **A separate env per runtime** (`us-dev-k8s`): duplicates the dev config and lets one pipeline run twice; the runtime
  is a property of the target (`kind: compose | helm` in `workflows-config.yml`).

## Consequences

- Moved (git mv): `_common/application.yml` → `application.flow.yml`, `app-common/{application.yml,values.yaml}` →
  `application.app.yml`, `_helm-values.app.yaml`, and per instance `application.yml`, `compose.env`, `values.yaml` →
  `application.instance.yml`, `_docker-compose.instance.env`, `_helm-values.instance.yaml`. The shared values moved
  down to `_docker-compose.flow.env` (`IMAGE_REPO`, `TZ`, `LOG_LEVEL_ROOT`) and `_docker-compose.app.env`
  (`JAVA_OPTS`, `MEM_LIMIT`); every combined env is what the instance file said before.
- Removed: `apps/*/docker/docker-compose.yml`. Added: `docker/docker-compose.yml`,
  `apps/source-database/docker/docker-compose.override.yml`, `/.run/` in `.gitignore`.
- `run-compose.sh` (layers, combined env, `compose-env`, service `app`, the podman-compose fixes), `smoke.sh` (no app
  directory needed), `stack.sh`, `pool-deploy.sh` (bundle: the template, the app's override and smoke test when it
  ships them, the flow's layer files; `.run/` excluded from the checksum and the sync), `helm-deploy-instance.sh`
  (paths), config-lint (layer files per level, env layers, the `-f` chain in check 6, relative paths) and its tests,
  `scripts/test/pool-deploy-test.sh`, `scripts/ci/{set-image-tag,retention}.sh` and the workflows follow.
- A tree in the old layout fails fast: `run-compose.sh` and config-lint name the file it should be.
