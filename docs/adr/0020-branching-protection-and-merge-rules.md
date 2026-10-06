# ADR-0020 — Trunk-based development: `main` and `hotfix/*` change only by pull request; feature branches are free

| | |
|---|---|
| Status | Accepted. Rule 8 superseded in part by [ADR-0032](0032-registry-credentials.md) |
| Date | 2026-10-04 |
| Applies to | every repository built from this one (its branches, tags and repository settings) |
| Enforced by | GitHub rulesets (repository settings, below); the required check `pr-gate`; CODEOWNERS reviews; no workflow job holds `contents: write` on a protected branch |
| Related | [ADR-0008](0008-versions-derived-from-git.md), [ADR-0021](0021-ci-layering.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0029](0029-release-and-promotion.md) |

**In short:** The repository uses trunk-based development: every change is integrated on `main`, and there are no
`develop` or `release/*` branches. Nobody, person or workflow, pushes to `main` or to an existing `hotfix/*` branch.
Every change there is a reviewed pull request, squash-merged once `pr-gate` is green, and its title sizes the next
version.

## Context

Every change to what gets released has to be reviewed and tested before it lands. There is no exception for people
or for automation. Versions and release notes come from commit messages
([ADR-0008](0008-versions-derived-from-git.md)), so the way pull requests are merged is part of the versioning
contract. A hotfix of a released version needs a branch of its own, because `main` has already moved past that
version. That branch needs the same protection.

## Decision

1. **Branches:**

   | Branch | Who pushes | How it changes | CI |
   |---|---|---|---|
   | `main` | nobody: no person, no workflow | a squash-merged pull request, through the merge queue | `main.yml`, `release-please.yml` |
   | `hotfix/<name>`, cut from the release tag it patches | nobody, after creation | a squash-merged pull request | `main.yml` (without the dev deploy) |
   | any other branch (feature branches; bot branches `release-please--…` and `bump/…`) | its author or bot | direct pushes | the fast tier of `pr.yml` on every push ([ADR-0022](0022-pull-request-pipeline.md)) |

   A squash merge turns all the commits of a pull request into one commit on the target branch. The merge queue
   tests the exact result of a merge before it happens.
2. **Rulesets on `main` and `hotfix/**`.** Rulesets are GitHub's branch and tag protection rules.
   - A pull request is required, with one approval, including a CODEOWNERS review for the paths it touches.
   - The only required status check is `pr-gate` ([ADR-0022](0022-pull-request-pipeline.md)).
   - History is linear: squash merges only.
   - The merge queue is on for `main`.
   - There are no bypass actors: not administrators, not workflows, not apps.
3. **Pull-request titles are Conventional Commits.** The title sizes the next version and becomes its changelog
   line, because the squash commit's message is the pull request's title. So the title MUST be a Conventional
   Commit:
   - `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `build:`, `ci:` or `chore:`, with an optional
     `(<scope>)`;
   - `!` or a `BREAKING CHANGE:` footer for a breaking change.
4. **No workflow writes to a protected branch.** No job of the `main` pipeline (`main.yml`) holds `contents: write`.
   The only jobs that do are release-please's (for the release branch and tags) and the release jobs (for tags,
   the GitHub Release and bump branches). Records of what was deployed are GitHub Deployments, never commits
   ([ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md)).
5. **Tags.** A `v*` tag is created in one of two ways:
   - by release-please, when the release pull request is merged;
   - by a release manager, as the emergency route for a hotfix.

   A tag ruleset restricts the creation of `v*` to those actors, and forbids moving or deleting a tag.
6. **Hotfix lifecycle:**
   1. A release manager creates `hotfix/<name>` from the tag `vX.Y.Z`.
   2. Fixes land by pull request. CI builds `X.Y.(Z+1)-rc.<n>` images and runs every test.
   3. A release manager pushes `vX.Y.(Z+1)` on the tested hotfix commit, and `release.yml` promotes that build
      ([ADR-0029](0029-release-and-promotion.md)).
   4. The fix is ported (applied again) to `main` by pull request. That pull request sets release-please's next
      version past the hotfix (a `Release-As:` footer), so `main` never proposes a version that already exists.

   An example: a feature lands by squash merge, `v1.4.0` is released, a hotfix ships `v1.4.1`, and the fix is
   ported to `main`:

   ```mermaid
   gitGraph
     commit id: "fix a"
     branch "feature/b"
     checkout "feature/b"
     commit id: "wip 1"
     commit id: "wip 2"
     checkout main
     commit id: "feat b, squashed"
     commit id: "release 1.4.0" tag: "v1.4.0"
     branch "hotfix/1.4"
     checkout "hotfix/1.4"
     commit id: "fix c, squashed" tag: "v1.4.1"
     checkout main
     commit id: "fix d, squashed"
     commit id: "fix c ported, Release-As 1.4.2"
   ```

7. **Ownership.** CODEOWNERS assigns every path:
   - the shared tooling to the platform maintainers ([ADR-0005](0005-repository-layout-and-shared-tooling.md));
   - the apps, the framework and `config/` to the app team;
   - each flow's directories, `config/*/<flow>/`, to that flow's team.
8. **Repository settings.** No file can set these, so each repository applies them once:

   > **Superseded in part by [ADR-0032](0032-registry-credentials.md) rule 6.** The table gains the optional secrets
   > `REGISTRY_USER` and `REGISTRY_TOKEN` (rule 1 there) and the registry read credentials of every box of a pool.

   | Setting | Value |
   |---|---|
   | Actions → workflow permissions | allow GitHub Actions to create pull requests (release pull request, version-bump pull request) |
   | Rulesets | as in rules 2 and 5 |
   | Environments | one per deployed env, named like the env (`us-dev`), deployment branch `main`, holding the env's deploy secrets (`DEV_DEPLOY_SSH_KEY`) |
   | Packages | the first `main` run creates `<registry>/<project>/<AppName>`; private by default; grant `read` to the consumers |
   | Optional | secret `RETENTION_TOKEN` and variable `RETENTION_DRY_RUN=false` for the nightly retention; label `ci:full`; the Renovate app |

## Alternatives considered

- **GitFlow** (`develop` and `release/*` branches). It brings long-lived branches, back-merges, and a second
  integration point that `main` would have to mirror.
- **Letting automation commit to `main`** (a bypass for a bot that records deployed tags). That puts unreviewed
  changes on the protected branch, and creates a loop the pipeline would have to guard against.
- **Merge commits.** The merge commit's body repeats the pull request's title, so the release tool counts every
  change twice. This repository's changelog shows exactly that.
- **One required check per job.** Every new or skipped job would mean editing branch protection, and a skipped
  required check blocks the merge.

## Consequences

- Every change on `main` was reviewed, tested in the merge queue, and is one Conventional Commit.
- Pull requests that workflows open with `GITHUB_TOKEN` (the release pull request, version-bump pull requests)
  start no workflow, so `pr-gate` never reports on them. Tags created that way start no workflow either. A GitHub
  App token removes both limits (known gap).
- Known gaps:
  - The merge queue is not enabled yet. Until it is, a pull request from a fork merges without any integration
    test having run on it; `main.yml` runs them only after the merge.
  - Merge commits are still allowed: 12 of the 27 commits so far are merges, and `CHANGELOG.md` lists each change
    twice.
  - No CI check validates pull-request titles.
  - A hotfix branch and `main` count from the same last tag, so both can compute the same `-rc.<n>` version.
    `pushImage` overwrites an existing tag, so immutability is enforced only when re-tagging.
