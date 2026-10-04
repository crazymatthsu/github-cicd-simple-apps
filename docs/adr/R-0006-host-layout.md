# R-0006 — The boxes hold versioned bundles under `/apps/<user>/versions/<project>/` with `current` (DL-41, DL-46)

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-46 (the host root `/apps/<user>`, amending DL-41 decision 2); DL-41 decisions 2, 3 and 5 (versioned per-project bundles, deploy all with activation after health, rollback to the previous version); D5 v1.3 §6.6 |

## Context

Until now a deploy synced the flow's host bundle **in place** into `/opt/platform` on every box (DL-39 v1.3): the box
held one tree, `record-tag` rewrote its `compose.env`, the next sync overwrote it, and going back to the version that
ran before needed the running image's tag from discovery. The platform owner's on-prem convention for a deployment
host is one directory per deployed version under the deploy user's directory, `/apps/<user>/versions/<project>/`, and
a `current` symlink to the live one (DL-46, fixing the root DL-41 had left home-relative). Rollback is pointing
`current` back.

## Decision

- **Layout** on every box of a pool: `/apps/<user>/versions/<project>/<YYYYMMDD-HHMMSS>/` holds one deployed bundle,
  never changed afterwards; `/apps/<user>/versions/<project>/current` is a symlink to the live version;
  `/apps/<user>/shared/<project>/{logs,data}` holds what survives a version change. `<user>` is `pool.user` of the
  flow's inventory (default `deploy`, DL-35), `<project>` is `platform.yml`'s. `pool.root` is gone from the inventory
  and config-lint rejects it; `pool.keep` (default 5, at least 2) is how many versions a box keeps. A box serves one
  `<env>/<flow>`: check 11 rejects a box listed by two flows.
- **Deploy** (`pool-deploy.sh <env> <flow> deploy`): the bundle is synced as a new version directory to every box;
  `record-tag` writes the tag into it on every box before anything starts (the directory is the record); each
  instance runs `pull` → `start` → `health` from the new directory on its box; only when every instance passed does
  `run-compose.sh activate` switch `current` on every box (an atomic symlink rename) and remove the versions beyond
  `keep`, never `current` or the one it replaced. Any failure sends every started instance back to `current` — the
  previous version directory, old image and old config — and `current` never moves; a first deploy, with no `current`,
  stops the failed instance. The deployed lines, and so the Deployment's results, exist only when activation ran.
- **Rollback** (`pool-deploy.sh <env> <flow> rollback [--to <version>]`): `activate --previous` (or `--to`) through
  `current` on every box, then every instance restarts from the new `current` on the box that ran it (else its pinned
  box). `run-compose.sh activate` refuses a bundle of another project, env or flow.
- **Placement** stays DL-39's (pinned → discovered → assigned); discovery, status and the pool guard ask the boxes
  through `current/scripts/run-compose.sh`. The GitHub Deployment payload and the report carry the version directory.
- **Forced command** (DL-35): `run-compose.sh` with `pull`, `start`, `stop`, `health`, `status`, `record-tag` and
  `activate`, and `rsync --server` confined to `/apps/<user>/versions/<project>/<version>/`; the boxes are
  provisioned with `/apps/<user>/versions/<project>/` and `/apps/<user>/shared/<project>/`.

## Consequences

- `scripts/pool-deploy.sh` (project from `platform.yml`, `--version`, the versioned sync, record first, activation,
  rollback-on-failure, `rollback`, `status` with the current version), `scripts/run-compose.sh` (`activate`, `status
  --json` names the version directory, the pool guard through `current`), config-lint check 11, the us-dev inventory,
  `_deploy-dev.yml` and `scripts/test/pool-deploy-test.sh` (18 cases) implement it.
- Left from DL-41 for later: declared placement (the `instances` map, no discovery), the inventory schema v2 (`hosts`,
  `deploy`), the short form `run-compose.sh <AppName> <AppInstance> <command>` on a box and the env/flow refusal,
  `--link-dest=../current` for the sync.
