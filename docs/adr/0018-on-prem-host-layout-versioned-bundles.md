# ADR-0018 — On-prem hosts hold versioned host bundles under `/apps/<user>/versions/<project>/`, with `current` the live one

| | |
|---|---|
| Status | Accepted. Rule 2 superseded in part by [ADR-0030](0030-platform-yml-declares-every-project-value.md) |
| Date | 2026-10-04 |
| Applies to | every on-prem host of every env |
| Enforced by | `run-compose.sh activate` and `record-tag` (refuse outside a version directory, or across project, env or flow); `pool-deploy.sh` (builds, hashes and verifies bundles); config-lint check 11 (`pool.keep` ≥ 2, no `pool.root`, a box in one flow only); `scripts/test/pool-deploy-test.sh` |
| Related | [ADR-0004](0004-environments-and-runtimes.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0028](0028-host-pool-deployment.md) |

**In short:** Each deploy copies the complete runtime of one flow — scripts, compose template, configuration and
image tag — into a new, time-stamped directory on each of the flow's hosts. A `current` symlink points at the live
one. Switching that symlink makes a deploy atomic, and pointing it back is a rollback that restores the old
configuration and image together.

## Context

A deploy must switch a host from one complete state to another in one step. That state is the scripts, the
template, the configuration and the image tag. A rollback must restore the previous configuration together with
the previous image. Hosts must not need a git checkout, git credentials or a build. The layout is the same in every
env served by compose ([ADR-0004](0004-environments-and-runtimes.md)).

## Decision

1. **The layout of a host:**

   ```
   /apps/<user>/versions/<project>/<YYYYMMDD-HHMMSS>/   one host bundle per deploy, never synced over again
   /apps/<user>/versions/<project>/current              symlink to the live version
   /apps/<user>/shared/<project>/logs                   what survives a version change (LOGS_DIR)
   /apps/<user>/shared/<project>/data                   (DATA_DIR)
   ```

   `<user>` is the pool's deploy user (`pool.user`, default `deploy`); `<project>` is the project of `platform.yml`.
   The layout is fixed: an inventory cannot move the root.
2. **A host bundle is the runtime of one `<env>/<flow>`:**
   - `scripts/run-compose.sh` and `scripts/smoke.sh`;
   - `docker/docker-compose.yml`;
   - for each app of the flow that ships them, `apps/<AppName>/docker/docker-compose.override.yml` and
     `apps/<AppName>/scripts/smoke.sh`;
   - the flow's whole configuration, `config/<env>/<flow>/`, including `workflows-config.yml`;
   - `config/<env>/known_hosts` when present;
   - the manifest `.platform-bundle`.

   No secrets and no images are bundled.
3. **The manifest.** `.platform-bundle` holds `KEY=value` lines: `BUNDLE_PROJECT`, `BUNDLE_ENV`, `BUNDLE_FLOW`,
   `BUNDLE_GIT_SHA`, `BUNDLE_TAG`, `BUNDLE_CREATED`, `BUNDLE_FILES`, `BUNDLE_SHA256`, `POOL_HOSTS`, `POOL_USER`,
   `POOL_ROOT`, `POOL_KEEP`. `BUNDLE_SHA256` is the sha256 of the sorted `<sha256>  <path>` listing of every file
   except the manifest and `.run/`. The scripts read the manifest as data; they never source it.
4. **One cluster per box.** A box serves exactly one `<env>/<flow>`: its `current` is that cluster's runtime.
5. **The version directory records what it runs.** `run-compose.sh … record-tag` writes the deployed `IMAGE_TAG` into
   the version's `_docker-compose.instance.env`, before anything starts from it. It refuses to write outside a
   bundle; in a checkout the tag changes only through git. The combined envs are generated under the version's own
   `.run/`.
6. **Activation is atomic.** `run-compose.sh activate` switches `current` to its own version directory: it creates
   a new symlink and renames it over the old one.
   - It creates `shared/<project>/{logs,data}`.
   - It keeps the newest `keep` versions (default 5, at least 2), and always keeps `current` and the version it
     replaced.
   - `--previous` or `--to <version>` switch back instead.
   - It refuses a version of another project, env or flow.

   A version directory moves through these states on a box, as the deploys and rollbacks of
   [ADR-0028](0028-host-pool-deployment.md) run.

   ```mermaid
   stateDiagram-v2
       state "Synced and verified, not live" as Synced
       state "IMAGE_TAG recorded" as Tagged
       state "Instances started from it" as Started
       state "Live, current points here" as Live
       state "On disk, not live" as Idle
       [*] --> Synced : sync
       Synced --> Tagged : record-tag
       Tagged --> Started : pull, start, health
       Started --> Live : activate, once every instance is healthy
       Started --> Idle : a start or health fails, current stays
       Live --> Idle : another version is activated
       Idle --> Live : activate --previous or --to, a rollback
       Idle --> [*] : removed, beyond the newest keep
   ```

7. **Operating on a host.** Every command runs through the live version:
   `/apps/<user>/versions/<project>/current/scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> <command>`.
   A deploy is the exception: it starts the instances from the new version directory, then activates it
   ([ADR-0028](0028-host-pool-deployment.md)).
8. **Access.** The deploy user's SSH key is restricted by a forced command, an SSH key setting that lets the host
   decide what the key can run. It allows two things:
   - `run-compose.sh` with `pull`, `start`, `stop`, `health`, `status`, `record-tag` and `activate`;
   - `rsync --server` into `/apps/<user>/versions/<project>/<version>/`.

   Hosts are provisioned with `/apps/<user>/versions/<project>/` and `/apps/<user>/shared/<project>/`.

## Alternatives considered

- **Syncing one directory in place.** There would be no atomic switch. A rollback would have to rebuild the previous
  state from records, and the configuration and the tag of the previous version would be lost.
- **A git checkout on every host.** It puts credentials on the hosts and leaves partial states during a pull. The
  tag would live in a working-copy edit.
- **OS packages** (rpm or deb) per release. They are heavier to build and sign, and they still need per-host
  configuration and an activation step.
- **Configuration baked into the image.** That means one image per env, which breaks "the tested image is the
  deployed image" ([ADR-0010](0010-image-tags-digests-promotion-retention.md)).

## Consequences

- A rollback is "point `current` back, restart". The image tag and the configuration of the older version come
  back together.
- A box keeps a bounded history of complete, self-describing versions on disk.
- Hosts need bash 4+, rsync, curl, and docker or podman with compose. They need no git.
- Known gaps:
  - the forced command is not implemented, and no hosts exist yet (deploy-dev plays them on the runner,
    [ADR-0028](0028-host-pool-deployment.md));
  - for the promoted envs, the configuration repository must assemble the same bundles from a release's runtime
    files (open decision).
