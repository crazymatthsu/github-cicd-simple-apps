# ADR-0027 — Every tested `main` commit is deployed to the dev envs, and a GitHub Deployment is the record

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | the dev envs of `platform.yml` (`dev_envs`); `_deploy-dev.yml`; each dev flow's `workflows-config.yml` |
| Enforced by | `_deploy-dev.yml` (refuses any env that is not `*-dev`; holds `contents: read` only); config-lint check 11 (inventory against the tree) |
| Related | [ADR-0004](0004-environments-and-runtimes.md), [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0020](0020-branching-protection-and-merge-rules.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0028](0028-host-pool-deployment.md) |

## Context

Dev should always run what `main` is, so that integration problems show up within minutes of a merge. A deploy
has to be recorded: which tag, which image digests, which box. But no workflow may commit to `main`
([ADR-0020](0020-branching-protection-and-merge-rules.md)), so the record cannot be a commit.

## Decision

1. **Every tested `main` commit is deployed.** After `publish` and the kind deployment test, `main.yml` runs
   `_deploy-dev.yml` for the dev envs ([ADR-0023](0023-main-pipeline-build-once-test-publish.md)). Configuration-only
   merges deploy too. Hotfix branches do not deploy dev.
2. **The deploy inventory.** Each dev flow has one inventory, `config/<env>/<flow>/workflows-config.yml`:

   ```yaml
   env: us-dev                      # restates the path
   flow: cash                       # restates the path
   pool: {hosts: [...], user: deploy, keep: 5}    # the flow's boxes (ADR-0028)
   defaults: {kind: compose}        # any target field
   targets:                         # exactly one per instance directory of the flow
     - instance: <AppName>/<AppInstance>
       kind: compose                # compose | helm
       host: <box>                  # optional pin, one of pool.hosts
   ```

   There is no env-level inventory. A `helm` target names a `cluster` and a `namespace` (default: the flow).
   Today the only cluster is the throwaway `kind-ci` ([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)).
3. **The tree declares intent; the deploy records facts.**
   - The dev instance layers say `IMAGE_TAG=main` (and `image.tag: main`).
   - The deploy passes the literal version of the run as the `IMAGE_TAG` override.
   - `record-tag` writes that version into the box's version directory
     ([ADR-0018](0018-on-prem-host-layout-versioned-bundles.md)).
   - Git is never written.
4. **The record is a GitHub Deployment.** The job creates one per run, after the deploy, on the Environment named
   like the env (`us-dev`):
   - `ref` is the deployed commit, which is also the configuration tree that was deployed;
   - the payload holds `env`, `tag`, `configSha`, the run URL, `images` (Gradle project → digest-pinned
     reference), `instances` (instance, kind, box or cluster and namespace, image, `deployed` or `failed`) and
     `bundles` (per pooled flow: version directory, root, sha256, file count, transport);
   - its status is `success` only when every instance deployed.

   The job summary is the readable copy. The Environment itself is used with `deployment: false`, so this record is
   the only one per run.
5. **What runs in dev** is answered by the last successful Deployment of the env, and on the boxes by `current`.
   Retention keeps every tag that record names ([ADR-0010](0010-image-tags-digests-promotion-retention.md)).
6. **Deploy mechanics.**
   - Pooled compose targets go through `pool-deploy.sh` ([ADR-0028](0028-host-pool-deployment.md)). It uses the
     `ssh` transport when the Environment holds `DEV_DEPLOY_SSH_KEY` and `config/<env>/known_hosts` exists. Until
     then the runner plays every box (the `local` transport: a validated dry run).
   - Deploys of one env are serialized and never cancelled.
   - Every target is attempted, failures are recorded in the Deployment, and the job fails after the record is
     written.

## Alternatives considered

- **Commit the deployed tag back to `main`.** It needs a bypass of branch protection, and every deploy becomes a
  commit that must not trigger another deploy.
- **A rolling "record" pull request.** Noise in the pull-request list, and the record lags the deploy.
- **Create the Deployment before deploying.** A Deployment's payload cannot change after creation, so the
  per-instance results would have nowhere to go.

## Consequences

- `git log config/us-dev` shows what dev is meant to run, and the Deployments show what it ran. In the promoted
  envs git is both: their tags are literal and change only by pull request
  ([ADR-0029](0029-release-and-promotion.md)).
- Known gaps:
  - a per-flow deploy policy (on every merge or on a schedule), and manual deploy and rollback dispatches, do not
    exist yet: every tested merge deploys every dev flow;
  - a compose target in a flow without a pool gets only a validated dry run.
