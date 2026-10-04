# R-0002 — DL-40 implemented: no workflow writes to `main`, the Deployment is the record

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Platform decisions applied | DL-40 items 1–3 and 6 (github-demo); D5 §6.8, D9 §6.3–§6.6, D12 §6.7 |

## Context

The company ruleset allows changes to `main` only through a pull request with a human approval, with no bypass for
workflows. The pipeline inherited from github-demo ended every dev deploy with a bot commit to `main`
(`chore(config): us-dev deployed <tag> [skip ci]`, the v1.0 write-back of DL-09 / DL-36), and the deploy job held
`contents: write`. The first `main.yml` run of this repository made exactly one such commit (`5d5d211`). DL-40 had
already decided the replacement; this ADR records its implementation here.

## Decision

1. **No workflow writes to `main`.** The write-back step and the scripts `write-back-tag.sh` and `set-target-host.sh`
   are gone; no job of `main.yml` or `_deploy-dev.yml` holds `contents: write`; the `[skip ci]` marker, the
   bot-actor conditions and the bot concurrency group (DL-36) are removed.
2. **The dev tree declares intent.** `config/us-dev/**/compose.env` says `IMAGE_TAG=main`, `values.yaml` says
   `image.tag: main` (config-lint check 10 permits floating tags in `*-dev`, check 4 still holds). The literal
   version lives in the deploy's `IMAGE_TAG` override, in the boxes' `compose.env` (`record-tag`) and in the record.
3. **The record is a GitHub Deployment** of the env's Environment (`us-dev`, named like the env, D12 §6.7), one per
   run, created when the deploy has finished, with `ref` = the run's commit (the config tree deployed) and a payload:
   `env`, `tag`, `configSha`, `run`, `images` (Gradle project → digest-pinned image), `instances` (per target: kind,
   box or cluster / namespace, image, `deployed` or `failed`), `bundles` (per flow: sha256, files, transport). Its
   status is `success` when every target deployed, else `failure`; the job summary is the human-readable copy. The
   job keeps `environment: <env>` with `deployment: false`, so the record with the payload is the only one per run.
4. **Fallback after a failed start or health** (D9 §6.9). The synced `compose.env` now names `main`, which is the
   build that just failed, so `pool-deploy.sh` goes back to the tag that ran before — known from discovery
   (`status --json` reports the running image) — with the `IMAGE_TAG` override, and records it on every box; without
   a known previous tag it starts the declared one.
5. **Retention** protects the tags of the last successful Deployment of each dev env in addition to the tags the
   tree names (`retention.sh`, with `deployments: read`).
6. **Placement** stays pinned → discovered → assigned (DL-39 v1.3); the chosen box is recorded in the Deployment
   payload instead of being written back as `host`. Declared placement and the versioned bundles are DL-41, later.

## Alternatives considered

- A GitHub App in the ruleset's bypass list, or a rolling "record" pull request: rejected by DL-40.
- Creating the Deployment before the deploy (in progress) and updating it afterwards: a payload cannot be changed
  after creation, so the per-instance facts (box, result) would have had no place; the record is created once, at
  the end, from the facts.
- Keeping Environment `dev`: D12 §6.7 names Environments like the envs, and the Deployment belongs to the env.

## Consequences

- "What runs in dev" is answered by the Deployments of Environment `us-dev` (and `pool-deploy.sh status`), not by
  `git log config/us-dev`; for qa and prod git remains the record (DL-40).
- Repository settings: the Environment `us-dev` (secrets `DEV_DEPLOY_SSH_KEY`, later `DEV_KUBECONFIG`); the ruleset on
  `main` needs no bypass. The Environment `dev` created by the first run is unused.
- Still open from DL-40 / DL-41: the per-flow `deploy` policy (`on-merge`, `schedule`, required for a dev flow), the
  hourly tick, the manual deploy and rollback dispatches with inputs project / env / flow, and the versioned
  per-project bundles with `activate`; until then every tested `main` merge deploys `us-dev`.
- github-demo's own `_deploy-dev.yml` still writes back; porting this change there is a follow-up in that repository.
