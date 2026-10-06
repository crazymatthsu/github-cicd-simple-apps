# config/ — the configuration tree ([ADR-0011](../docs/adr/0011-configuration-tree-and-spring-layers.md))

This tree holds `local` and the dev envs listed in `platform.yml` (`dev_envs`), with the regions, stages and flows of
`platform.yml` ([ADR-0004](../docs/adr/0004-environments-and-runtimes.md), [ADR-0030](../docs/adr/0030-platform-yml-declares-every-project-value.md));
config-lint rejects any other env or flow. The promoted envs live in the configuration repository.

The layers are files ([ADR-0011](../docs/adr/0011-configuration-tree-and-spring-layers.md)): each sits in the directory that already identifies its level, and its name says
which layer it is. The directory path is the identity tuple; nothing is shared at the env level and nothing across
envs (a default that is the same everywhere is a jar default, [ADR-0011](../docs/adr/0011-configuration-tree-and-spring-layers.md)). In `*-dev` envs every flow also has its deploy-dev
inventory `workflows-config.yml`, with the boxes' host keys in `config/<env>/known_hosts`.

```
config/<env>/<flow>/                                the flow (one cluster, ADR-0011)
    workflows-config.yml                            *-dev only: the flow's deploy inventory
    application.flow.yml                            optional
    _docker-compose.flow.env  _docker-compose.flow.yml          optional
config/<env>/<flow>/<AppName>/                      the app in this flow
    application.app.yml                             required
    _helm-values.app.yaml                           required when platform.yml kinds includes helm (ADR-0036)
    _docker-compose.app.env  _docker-compose.app.yml            optional
config/<env>/<flow>/<AppName>/<AppInstance>/        one instance
    application.instance.yml  _docker-compose.instance.env      required
    _helm-values.instance.yaml                      required when platform.yml kinds includes helm (ADR-0036)
    _docker-compose.instance.yml                    optional
```

- **`application.<layer>.yml`** is what the app reads: `run-compose.sh` mounts each one as a single read-only file at
  `/config/flow|common|instance/application.yml` (a missing flow layer mounts `/dev/null`) and the jar's import list
  applies them lowest precedence first: flow, app, instance ([ADR-0011](../docs/adr/0011-configuration-tree-and-spring-layers.md)). It is the only kind of file that reaches the
  container.
- **`_<tool>.<layer>.<ext>`** is read on the host and never mounted: `_docker-compose.*` by compose, `_helm-values.*`
  by Helm (the Helm design is deferred until the EKS work; the names are provisional, [ADR-0019](../docs/adr/0019-kubernetes-and-helm-are-provisional.md)).
- **The compose env layers** merge per key, flow < app < instance < the shell (`IMAGE_TAG` / `IMAGE_REPO` only), into
  ONE combined env that `run-compose.sh` regenerates on every command: `.run/<env>/<flow>/<AppName>/<AppInstance>/
  compose.env` under the repository root (or the box's version directory), git-ignored, each value after a comment
  naming the layer it came from and what it overrode. `run-compose.sh ... printenv` shows it. It is passed as
  `--env-file` and loaded by the template's `env_file:` (one file: podman-compose keeps only the last `--env-file`).
- **The compose files** merge in this order, each only when it exists: `docker/docker-compose.yml` (the one template,
  service `app`, aliased `<AppName>`), `apps/<AppName>/docker/docker-compose.override.yml` (what the app needs in every
  env), then `_docker-compose.flow.yml`, `_docker-compose.app.yml`, `_docker-compose.instance.yml`. Overrides are for
  structure (a volume, a healthcheck); values belong in the env layers. Compose resolves a relative path of any file
  against `docker/`, so overrides use variable-based paths only (config-lint check 6).

| File | Holds | Never |
|---|---|---|
| `application.<layer>.yml` | endpoints, topics, table names, poll intervals, log levels | secrets: Spring's datasource credentials and the `secret_properties` of `platform.yml`, with every key below them ([ADR-0013](../docs/adr/0013-secrets.md), [ADR-0042](../docs/adr/0042-property-roots-and-secret-properties-in-platform-yml.md)) |
| `_docker-compose.<layer>.env` | any layer: `IMAGE_REPO`, `JAVA_OPTS`, `TZ`, `LOG_LEVEL_ROOT`, `MEM_LIMIT`, `LOGS_DIR` and `DATA_DIR` (absolute host paths; each instance mounts its `<AppName>/<AppInstance>` below them, [ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)); the instance layer only: `IMAGE_TAG`, the identity (`APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE`, restating the path), `*_HOST_PORT` | `SPRING_*`, `LOGGING_*`, `MANAGEMENT_*` and the environment-variable form of each `property_prefixes` root of `platform.yml` ([ADR-0042](../docs/adr/0042-property-roots-and-secret-properties-in-platform-yml.md)), the variables `run-compose.sh` sets, secrets |
| `_docker-compose.<layer>.yml` | compose structure for the flow, the app or the instance | relative paths, secrets |
| `_helm-values.<layer>.yaml` (Helm, [ADR-0019](../docs/adr/0019-kubernetes-and-helm-are-provisional.md); required when `kinds` includes `helm`, checked whenever it exists, [ADR-0036](../docs/adr/0036-helm-checks-only-when-kinds-include-helm.md)) | `app`: `resources`, `env: {TZ}`; `instance`: `image.tag` (= `IMAGE_TAG`), `identity` (= the directory path), `env: {APP_ENV, APP_FLOW, APP_NAME, APP_INSTANCE, JAVA_OPTS, LOG_LEVEL_ROOT}` | `IMAGE_*`, `*_HOST_PORT`, `MEM_LIMIT`, `LOGS_DIR`, `DATA_DIR`, `SPRING_*`, `LOGGING_*`, `MANAGEMENT_*` and the environment-variable form of each `property_prefixes` root (check 4), secrets |
| `<flow>/workflows-config.yml` (every flow of a `*-dev` env; [ADR-0027](../docs/adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md)) | `env` and `flow` (= the path); `pool: {hosts, user, keep}` — the flow's bare-metal boxes, SSH user (default `deploy`; the versions live under `/apps/<user>/versions/<project>/`, [ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)) and the versions kept per box (default 5, [ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)); `defaults`; `targets`: one entry per instance directory of the flow — `instance: <AppName>/<AppInstance>`, `kind: compose \| helm`, `host` (compose: the box; with a pool optional — one of `pool.hosts` — the deploy resolves it and records it in the GitHub Deployment, [ADR-0027](../docs/adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md)), `user`, `cluster`, `namespace` (default: the flow) | secrets; an env-level `config/<env>/workflows-config.yml` (config-lint check 11 rejects it); a box in two flows' pools (a box serves one `<env>/<flow>`, [ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)); `pool.root` (the layout is fixed, [ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)) |
| `known_hosts` (in `config/<env>/`) | the reviewed `ssh-keyscan` lines of every box (see [Pinned host keys](#pinned-host-keys-configenvknown_hosts)); the ssh transport of `scripts/pool-deploy.sh` and the pool guard trust no other host key | private keys: the deploy key is the Environment `us-dev` secret `DEV_DEPLOY_SSH_KEY` |

A file of another level, an old name (`compose.env`, `values.yaml`, `application.yml`, `app-common/`, `_common/`) or
any other file is a config-lint error (checks 1 and 3), with the name it should have.

## Host pools ([ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md), [ADR-0028](../docs/adr/0028-host-pool-deployment.md))

Every box of a flow's `pool` holds this project's **host bundles** as version directories under
`/apps/<user>/versions/<project>/` — the deploy user's directory under `/apps` ([ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)); the project is `platform.yml`'s —
one per deploy and never changed afterwards, with `current` a symlink to the live one ([ADR-0018](../docs/adr/0018-on-prem-host-layout-versioned-bundles.md)). Any instance of the flow
can run on any box, each instance runs on exactly one, and a rollback points `current` back.
`scripts/pool-deploy.sh <env> <flow> bundle|plan|sync|discover|deploy|rollback|status` (`--help`) builds, syncs, deploys
and rolls back; deploy-dev runs `deploy` for every flow with a pool ([ADR-0027](../docs/adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md)).

```
/apps/<user>/versions/<project>/                 <root>: one directory per deployed version, never synced over again
/apps/<user>/versions/<project>/current          symlink to the live version (run-compose.sh activate; atomic switch)
/logs/<user>/<project>/logs/<AppName>/<AppInstance>/  the instance's /app/logs (LOGS_DIR of the flow's env layer)
/logs/<user>/<project>/data/<AppName>/<AppInstance>/  the instance's /app/data (DATA_DIR); both survive a version change
<root>/<YYYYMMDD-HHMMSS>/.platform-bundle        manifest, KEY=value lines: BUNDLE_PROJECT, BUNDLE_ENV, BUNDLE_FLOW, BUNDLE_GIT_SHA,
                                                 BUNDLE_TAG, BUNDLE_CREATED, BUNDLE_FILES, BUNDLE_SHA256, POOL_HOSTS, POOL_USER,
                                                 POOL_ROOT (= <root>), POOL_KEEP
<root>/<version>/scripts/run-compose.sh, smoke.sh   the one implementation for every app (ADR-0017: no per-app wrapper)
<root>/<version>/docker/docker-compose.yml       the one compose template (ADR-0012)
<root>/<version>/apps/<AppName>/                 when the app ships them: docker/docker-compose.override.yml, scripts/smoke.sh
<root>/<version>/config/<env>/<flow>/            the flow's layer files (the cluster layer, ADR-0011), every app, instance and
                                                 layer of the flow, and workflows-config.yml; each
                                                 <AppInstance>/_docker-compose.instance.env names the tag the version runs
                                                 (record-tag)
<root>/<version>/.run/                           the combined envs run-compose.sh writes on the box (not in the bundle)
<root>/<version>/config/<env>/known_hosts        when present: the pool guard pins the other boxes' keys with it
```

- **Deploy** ([ADR-0028](../docs/adr/0028-host-pool-deployment.md)): the bundle is synced as a new version directory to every box; `record-tag` writes the tag into
  it on every box; each instance runs `pull` → `start` → `health` from the new directory on its box; only when every
  instance passed does `run-compose.sh activate` switch `current` on every box (and remove the versions beyond
  `pool.keep`, never `current` or the one before it). Any failure sends every started instance back to `current` —
  the previous version, old image **and** old config — and `current` never moves; a first deploy, with no `current`,
  stops the failed instance. `pool-deploy.sh <env> <flow> rollback [--to <version>]` flips `current` back on every box
  and restarts the instances from it.
- **Placement**: pinned (`host` in `workflows-config.yml`) → discovered (the one box that runs the instance, asked
  through `current/scripts/run-compose.sh ... status --json`) → assigned (the box with the fewest placements, ties in
  pool order). The box and the version are recorded in the run's GitHub Deployment ([ADR-0027](../docs/adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md)), never written back; a PR
  that sets or changes `host` moves the instance (`deploy --move` stops it on the old box first). An instance found
  on two boxes stops the deploy (exit 6).
- **Record** ([ADR-0027](../docs/adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md)): the dev tree declares its intent — `IMAGE_TAG=main` in `_docker-compose.instance.env`,
  `image.tag: main` in `_helm-values.instance.yaml` — and no workflow commits to `main`. What `us-dev` runs is the last successful GitHub Deployment of
  Environment `us-dev` (payload: tag, digest-pinned images, every instance with its box or cluster and result, the
  config tree's git SHA, the version directory per flow) and, on the boxes, `current` and the
  `_docker-compose.instance.env` of each version directory, which `record-tag` wrote before anything started.
- **Root**: `run-compose.sh` takes the nearest ancestor holding `.platform-bundle` as its root, so
  `<root>/current/scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> start` works on any box, with no git
  checkout and no `CONFIG_ROOT`; `<root>/<version>/scripts/run-compose.sh activate` makes that version `current`.
- **Pool guard**: on a box whose bundle lists more than one host, `start` and `restart` first run `status --json`
  through `current` on every other box over SSH (as `POOL_USER`) and refuse (exit 3) when the instance runs there. A
  box that does not answer only warns (a dead box must not block a failover); `--force` skips the guard,
  `POOL_PEER_CHECK=off` disables it, `POOL_SELF_HOST` names this box when `hostname -f` differs from its entry in
  the pool, and `--dry-run` prints the peer commands.
- **Secrets** never enter the bundle: every box of a pool holds the secret environment of every instance of its
  flow ([ADR-0013](../docs/adr/0013-secrets.md)). Two instances on one box need distinct `*_HOST_PORT` values in their `_docker-compose.instance.env`.

### Pinned host keys: `config/<env>/known_hosts`

The ssh transport of `scripts/pool-deploy.sh` and the pool guard check every box's host key against this file and
accept no other ([ADR-0028](../docs/adr/0028-host-pool-deployment.md)). It holds public keys only, so it is not a
secret, and it changes only through a reviewed pull request: no script writes it.

- **One line per box**, as `ssh-keyscan` prints it, naming the box exactly as `pool.hosts` does; its IP may follow,
  comma-separated. Hashed names (`ssh-keyscan -H`) cannot be reviewed and are rejected.
- **Adding a box:** scan it from a trusted network, and compare its fingerprint with the one the box's admin reads on
  the box before you commit the line:

  ```bash
  ssh-keyscan -t ed25519 dev-cash-03.us-dev.example.com
  ssh-keyscan -t ed25519 dev-cash-03.us-dev.example.com | ssh-keygen -lf -
  ```

  On the box: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` must print the same fingerprint.
- **A rebuilt box:** an OS upgrade keeps the host keys (`/etc/ssh/ssh_host_*_key`). A reinstall, a replacement under
  the same name or a key rotation changes them: replace the box's line. Until then, deploys to that box fail, as they
  should.
- **Never scan at deploy time** (`ssh-keyscan >> known_hosts`, `StrictHostKeyChecking=accept-new`). That trusts
  whatever answers, and on an ephemeral runner every run is a first contact, so a spoofed or reused address would
  receive the deploy.
- **Many boxes, or frequent rebuilds:** sign the boxes' host keys with an SSH host CA when they are provisioned, and
  pin the CA instead. One line covers every box its patterns match, and a rebuilt box needs no change here:

  ```
  @cert-authority *.us-dev.example.com ssh-ed25519 AAAA...
  ```

config-lint check 11 fails a pull request when a box of a pool has no matching line; a `@cert-authority` pattern
counts, a `@revoked` line does not. While the file is missing, because no box exists yet, it only warns.

`./gradlew configLint` checks the tree ([ADR-0014](../docs/adr/0014-config-lint-enforces-the-config-contract.md), including `helm lint` / `helm template` per instance when `kinds`
includes `helm` and Helm 4 is installed); `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> validate` checks one instance;
`scripts/helm-deploy-instance.sh <env> <flow> <AppName> <AppInstance> --tag <tag> --mode template` renders its release.
