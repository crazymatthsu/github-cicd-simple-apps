# config/ — the configuration tree (D5)

`config/<env>/<flow>/<AppName>/{app-common,<AppInstance>}/` plus the optional cluster layer
`config/<env>/<flow>/_common/` (every app of one cluster — one business flow in one env, DL-44; nothing is shared at
the env level, and nothing across envs: a default that is the same everywhere is a jar default, DL-45), and in
`*-dev` envs one deploy-dev inventory per flow,
`config/<env>/<flow>/workflows-config.yml`, with the boxes' host keys in `config/<env>/known_hosts`. The directory path
is the identity tuple; `run-compose.sh` mounts the layers read-only under `/config/<layer>/` and the jar's import list
applies them lowest precedence first: flow, app-common, instance (D5 §6.1).

| File | Holds | Never |
|---|---|---|
| `application.yml` | endpoints, topics, table names, poll intervals, log levels | secrets (D2 §6.4) |
| `<AppInstance>/compose.env` | `IMAGE_REPO`, `IMAGE_TAG`, identity, `JAVA_OPTS`, `TZ`, `LOG_LEVEL_ROOT`, `*_HOST_PORT`, `LOGS_DIR`, `DATA_DIR`, `MEM_LIMIT` | `SPRING_*`, `LOGGING_*`, `MANAGEMENT_*`, `CONNECTOR_*`, secrets |
| `values.yaml` (Helm, D11 §6.2) | `app-common/`: `resources`, `env: {TZ}`; `<AppInstance>/`: `image.tag` (= `IMAGE_TAG`), `identity` (= the directory path), `env: {APP_ENV, APP_FLOW, APP_NAME, APP_INSTANCE, JAVA_OPTS, LOG_LEVEL_ROOT}` | `IMAGE_*`, `*_HOST_PORT`, `MEM_LIMIT`, `LOGS_DIR`, `DATA_DIR`, `SPRING_*`, `CONNECTOR_*_PASSWORD`, secrets |
| `<flow>/workflows-config.yml` (every flow of a `*-dev` env; D5 §6.6, DL-39) | `env` and `flow` (= the path); `pool: {hosts, user, keep}` — the flow's bare-metal boxes, SSH user (default `deploy`; the versions live under `/apps/<user>/versions/<project>/`, DL-46) and the versions kept per box (default 5, DL-41); `defaults`; `targets`: one entry per instance directory of the flow — `instance: <AppName>/<AppInstance>`, `kind: compose \| helm`, `host` (compose: the box; with a pool optional — one of `pool.hosts` — the deploy resolves it and records it in the GitHub Deployment, DL-40), `user`, `cluster`, `namespace` (default: the flow) | secrets; an env-level `config/<env>/workflows-config.yml` (config-lint check 11 rejects it); a box in two flows' pools (a box serves one `<env>/<flow>`, DL-41); `pool.root` (the layout is fixed, DL-46) |
| `known_hosts` (in `config/<env>/`) | the reviewed `ssh-keyscan` lines of every box; the ssh transport of `scripts/pool-deploy.sh` and the pool guard trust no other host key | private keys: the deploy key is the Environment `us-dev` secret `DEV_DEPLOY_SSH_KEY` |

## Host pools (DL-39, DL-41, DL-46)

Every box of a flow's `pool` holds this project's **host bundles** as version directories under
`/apps/<user>/versions/<project>/` — the deploy user's directory under `/apps` (DL-46); the project is `platform.yml`'s —
one per deploy and never changed afterwards, with `current` a symlink to the live one (DL-41). Any instance of the flow
can run on any box, each instance runs on exactly one, and a rollback points `current` back.
`scripts/pool-deploy.sh <env> <flow> bundle|plan|sync|discover|deploy|rollback|status` (`--help`) builds, syncs, deploys
and rolls back; deploy-dev runs `deploy` for every flow with a pool (`.github/README.md`).

```
/apps/<user>/versions/<project>/                 <root>: one directory per deployed version, never synced over again
/apps/<user>/versions/<project>/current          symlink to the live version (run-compose.sh activate; atomic switch)
/apps/<user>/shared/<project>/{logs,data}        what survives a version change (LOGS_DIR, DATA_DIR of compose.env)
<root>/<YYYYMMDD-HHMMSS>/.platform-bundle        manifest, KEY=value lines: BUNDLE_PROJECT, BUNDLE_ENV, BUNDLE_FLOW, BUNDLE_GIT_SHA,
                                                 BUNDLE_TAG, BUNDLE_CREATED, BUNDLE_FILES, BUNDLE_SHA256, POOL_HOSTS, POOL_USER,
                                                 POOL_ROOT (= <root>), POOL_KEEP
<root>/<version>/scripts/run-compose.sh, smoke.sh   the one implementation for every app (D12 §6.2: no per-app wrapper)
<root>/<version>/apps/<AppName>/                 docker/docker-compose.yml (and scripts/smoke.sh when the app ships checks of its own)
<root>/<version>/config/<env>/<flow>/_common/    when present: the cluster layer (DL-44)
<root>/<version>/config/<env>/<flow>/            every app, instance and layer of the flow, and workflows-config.yml;
                                                 each <AppInstance>/compose.env names the tag the version runs (record-tag)
<root>/<version>/config/<env>/known_hosts        when present: the pool guard pins the other boxes' keys with it
```

- **Deploy** (DL-41): the bundle is synced as a new version directory to every box; `record-tag` writes the tag into
  it on every box; each instance runs `pull` → `start` → `health` from the new directory on its box; only when every
  instance passed does `run-compose.sh activate` switch `current` on every box (and remove the versions beyond
  `pool.keep`, never `current` or the one before it). Any failure sends every started instance back to `current` —
  the previous version, old image **and** old config — and `current` never moves; a first deploy, with no `current`,
  stops the failed instance. `pool-deploy.sh <env> <flow> rollback [--to <version>]` flips `current` back on every box
  and restarts the instances from it.
- **Placement**: pinned (`host` in `workflows-config.yml`) → discovered (the one box that runs the instance, asked
  through `current/scripts/run-compose.sh ... status --json`) → assigned (the box with the fewest placements, ties in
  pool order). The box and the version are recorded in the run's GitHub Deployment (DL-40), never written back; a PR
  that sets or changes `host` moves the instance (`deploy --move` stops it on the old box first). An instance found
  on two boxes stops the deploy (exit 6).
- **Record** (DL-40): the dev tree declares its intent — `IMAGE_TAG=main` in `compose.env`, `image.tag: main` in
  `values.yaml` — and no workflow commits to `main`. What `us-dev` runs is the last successful GitHub Deployment of
  Environment `us-dev` (payload: tag, digest-pinned images, every instance with its box or cluster and result, the
  config tree's git SHA, the version directory per flow) and, on the boxes, `current` and the `compose.env` of each
  version directory, which `record-tag` wrote before anything started.
- **Root**: `run-compose.sh` takes the nearest ancestor holding `.platform-bundle` as its root, so
  `<root>/current/scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> start` works on any box, with no git
  checkout and no `CONFIG_ROOT`; `<root>/<version>/scripts/run-compose.sh activate` makes that version `current`.
- **Pool guard**: on a box whose bundle lists more than one host, `start` and `restart` first run `status --json`
  through `current` on every other box over SSH (as `POOL_USER`) and refuse (exit 3) when the instance runs there. A
  box that does not answer only warns (a dead box must not block a failover); `--force` skips the guard,
  `POOL_PEER_CHECK=off` disables it, `POOL_SELF_HOST` names this box when `hostname -f` differs from its entry in
  the pool, and `--dry-run` prints the peer commands.
- **Secrets** never enter the bundle: every box of a pool holds the secret environment of every instance of its
  flow (D2). Two instances on one box need distinct `*_HOST_PORT` values in their `compose.env`.

`./gradlew configLint` checks the tree (D5 §6.5, including `helm lint` / `helm template` per instance when Helm 4 is
installed); `scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> validate` checks one instance;
`scripts/helm-deploy-instance.sh <env> <flow> <AppName> <AppInstance> --tag <tag> --mode template` renders its release.
