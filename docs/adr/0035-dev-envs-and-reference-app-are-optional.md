# ADR-0035 — `dev_envs` may be `[]` and `reference_app` may be left out, so a repository can release before it deploys

| | |
|---|---|
| Status | Accepted. Supersedes in part rules 1 and 3 of ADR-0030, rule 5 of ADR-0024, rule 1 of ADR-0027 and rule 5 of ADR-0034 (rule 7). Rule 4 superseded in part by [ADR-0044](0044-no-system-test-one-integration-test-level.md) |
| Date | 2026-10-06 |
| Applies to | every repository built from this one; every reader of `dev_envs` and `projects[0].reference_app` in `platform.yml` |
| Enforced by | the `buildlogic.platform` settings plugin (`PlatformManifestTest`); config-lint check 1 (`ConfigLinterTest`); the env checks of `run-compose.sh`, `helm-deploy-instance.sh` and `pool-deploy.sh` (`scripts/test/env-vocabulary-test.sh`); `scripts/ci/projects.py` and `affected.py` (`scripts/test/affected-test.sh`); the `platform-manifest` action; the job conditions of `pr.yml`, `main.yml` and `nightly.yml`; `pr-gate` |
| Related | [ADR-0004](0004-environments-and-runtimes.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0023](0023-main-pipeline-build-once-test-publish.md), [ADR-0024](0024-ephemeral-ci-environments.md), [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0030](0030-platform-yml-declares-every-project-value.md) |

**In short:** Two values of `platform.yml` now switch parts of the pipeline off. `dev_envs: []` means the repository
deploys no env: no kind deployment test and no dev deploy run, and the scripts and config-lint accept `local` only.
A missing `reference_app` means there is no reference scenario: no system test, no kind deployment test and no
nightly teardown drill. A repository can then build, test, publish images and release, and nothing more. Setting the
values later turns those jobs on.

## Context

[ADR-0030](0030-platform-yml-declares-every-project-value.md) made both values required. Its schema asks for a
`<region>-dev` list and for an app under `apps_dir`, and the tooling refused anything less:

- the `platform-manifest` action failed on an empty `dev_envs` or a missing `reference_app`, and with it every run;
- the settings plugin failed every Gradle run, and `projects.py` failed `affected.py`;
- `run-compose.sh`, `helm-deploy-instance.sh` and `pool-deploy.sh` refused an empty `dev_envs`;
- `main.yml` and `pr.yml` ran matrices over `dev_envs`, and GitHub fails a run whose matrix is empty;
- `pr.yml` matched the reference app's image with `format(':{0}"', app)`, which matches any image for an empty app.

So a repository had to name a dev env before its first pull request could pass. Naming one made `main.yml` deploy
it, which needs boxes, an SSH key, `known_hosts` and a GitHub Environment. A repository that only wants to build,
test, publish and release could not exist. [ADR-0004](0004-environments-and-runtimes.md) does not require a dev env:
its rules limit this repository to `local` and its dev envs, however many there are.

## Decision

1. **`dev_envs: []` is valid.** It means the repository deploys no env yet. The key MUST stay present as a one-line
   list ([ADR-0030](0030-platform-yml-declares-every-project-value.md) rule 2), and `[]` is one. Each entry MUST
   still be `<region>-dev` with a region of `regions`.
2. **`reference_app` MAY be left out.** Without it there is no reference scenario. When the key is present, it MUST
   name an app under `apps_dir`, and the settings plugin fails otherwise. An empty value is not a way to leave it
   out.
3. **The readers say "none" the same way.** The `platform-manifest` action outputs `dev-envs` as `[]`, and
   `reference-app`, `reference-project` and `reference-image` as empty strings. `projects.py --reference-dir` prints
   an empty line, and `affected.py` adds no `deploy-test` path for it. The scripts and config-lint check 1 accept
   `local` and refuse every other env.
4. **Jobs are skipped, never run empty.** A job that runs per dev env MUST carry the condition
   `needs.<platform job>.outputs.dev-envs != '[]'`. A job of the reference scenario MUST carry
   `needs.<platform job>.outputs.reference-app != ''`. Each condition is a plain `&&` term, so it combines with
   others, such as the system image of `test-infra/compose/versions.env`. What each switch turns off:

   > **Superseded in part by [ADR-0044](0044-no-system-test-one-integration-test-level.md) rule 5.** There is no
   > `system-test` row: `reference_app` switches the kind deployment test, the nightly teardown drill and the
   > `public-base` job, and no condition of `main.yml` reads `versions.env`.

   | Job | `dev_envs: []` | no `reference_app` |
   |---|---|---|
   | `pr.yml` `kind-deploy` | skipped | skipped |
   | `main.yml` `system-test` | runs | skipped |
   | `main.yml` `kind-deploy` | skipped | skipped |
   | `main.yml` `deploy-dev` | skipped | runs after `publish` |
   | `nightly.yml` teardown drills | run | skipped; `retention` still runs |

5. **`deploy-dev` follows `publish`.** It runs on `main` when `publish` succeeded, no earlier job failed and the run
   was not cancelled. It waits for a kind deployment test only when one runs.
6. **The gate misses no test that cannot run.** `pr-gate` MUST count a skipped kind deployment test as missing only
   when the repository has a dev env and a reference app.
7. **What this decision supersedes:**
   - [ADR-0030](0030-platform-yml-declares-every-project-value.md) rule 1, in part: `dev_envs` may be `[]`, and
     `projects[0].reference_app` is optional;
   - [ADR-0030](0030-platform-yml-declares-every-project-value.md) rule 3, in part: the settings plugin fails when
     `reference_app` is present and names no app. A missing key is valid;
   - [ADR-0024](0024-ephemeral-ci-environments.md) rule 5, in part: the nightly teardown drill runs only with a
     reference app;
   - [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md) rule 1, in part: `deploy-dev`
     follows `publish` and the kind deployment test, or `publish` alone when no reference app exists (rule 5);
   - [ADR-0034](0034-main-runs-the-test-stages-the-repository-has.md) rule 5, in part: `deploy-dev` names
     `kind-deploy` when one runs, else `publish` (rule 5). The `public-base` job of
     [ADR-0033](0033-public-base-image-fallback.md) is skipped without a reference app too.

## Alternatives considered

- **A `deploy: false` key in `platform.yml`.** It restates what an empty `dev_envs` already says, and a new key
  needs a new reader in every tool.
- **Placeholder values.** A dev env without a tree, or any app as the reference app, moves the failure from the
  first pull request to the first `main` run, or tests nothing.
- **Delete the unneeded jobs in the derived repository.** The workflows are shared tooling
  ([ADR-0005](0005-repository-layout-and-shared-tooling.md)), copied unchanged.
- **Keep the empty matrix and let the job fail softly.** GitHub fails the run before any step runs. A job-level `if`
  skips the job before its matrix is expanded.

## Consequences

- This repository is unchanged. It declares `dev_envs: [us-dev]` and `reference_app: source-database`, so every job
  runs as before.
- These values are the sequencing switch of the template. A new repository starts with `dev_envs: []` and no
  `reference_app`. Its first pull request goes green before its boxes, SSH key, `known_hosts` and GitHub
  Environment exist. Setting `dev_envs` later turns the deploy on, and setting `reference_app` turns the reference
  scenario on. Each is one line.
- A repository that only builds, tests, publishes and releases is a valid end state, not only a start.
- Without a reference app, `publish` runs on the component tests alone, and the teardown guarantee of
  [ADR-0024](0024-ephemeral-ci-environments.md) rests on the leak checks of every pull-request and `main` run.
- With no dev env, the scripts name an empty list when they refuse an env: `(platform.yml dev_envs: )`.
- The `platform-manifest` action now fails when the `dev_envs` key is missing, as the build does.
