# ADR-0020 — Trunk-based development: `main` and `hotfix/*` change only by pull request; feature branches are free

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every repository built from this one (its branches, tags and repository settings) |
| Enforced by | GitHub rulesets (repository settings, below); the required check `pr-gate`; CODEOWNERS reviews; no workflow job holds `contents: write` on a protected branch |
| Related | [ADR-0008](0008-versions-derived-from-git.md), [ADR-0021](0021-ci-layering.md), [ADR-0022](0022-pull-request-pipeline.md), [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0029](0029-release-and-promotion.md) |

## Context

Every change to what gets released must be reviewed and tested before it lands, with no exception for people or
automation. Versions and release notes come from commit messages ([ADR-0008](0008-versions-derived-from-git.md)),
so the way pull requests are merged is part of the versioning contract. Hotfixes of a released version need a
branch that `main` has moved past, under the same protection.

## Decision

1. **Branches:**

   | Branch | Who pushes | How it changes | CI |
   |---|---|---|---|
   | `main` | nobody: no person, no workflow | a squash-merged pull request, through the merge queue | `main.yml`, `release-please.yml` |
   | `hotfix/<name>`, cut from the release tag it patches | nobody, after creation | a squash-merged pull request | `main.yml` (without the dev deploy) |
   | any other branch (feature branches; bot branches `release-please--…` and `bump/…`) | its author or bot | direct pushes | the fast tier of `pr.yml` on every push ([ADR-0022](0022-pull-request-pipeline.md)) |

2. **Rulesets on `main` and `hotfix/**`:**
   - a pull request is required, with one approval, including a CODEOWNERS review for the paths it touches;
   - the only required status check is `pr-gate` ([ADR-0022](0022-pull-request-pipeline.md));
   - history is linear: squash merges only;
   - the merge queue is on for `main`;
   - there are no bypass actors: not administrators, not workflows, not apps.
3. **Pull-request titles are Conventional Commits.** The squash commit's message is the pull request's title, so the
   title MUST be a Conventional Commit:
   - `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `test:`, `build:`, `ci:` or `chore:`, with an optional
     `(<scope>)`;
   - `!` or a `BREAKING CHANGE:` footer for a breaking change.

   The title sizes the next version and becomes its changelog line.
4. **No workflow writes to a protected branch.** No job that runs on `main` holds `contents: write`. The only jobs
   that do are release-please's (the release branch and tags) and the release jobs (tags, the GitHub Release,
   bump branches). Records of what was deployed are GitHub Deployments, never commits
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
   4. The fix is ported to `main` by pull request. That pull request sets release-please's next version past the
      hotfix (a `Release-As:` footer), so `main` never proposes a version that already exists.
7. **Ownership.** CODEOWNERS assigns every path:
   - the shared tooling to the platform maintainers ([ADR-0005](0005-repository-layout-and-shared-tooling.md));
   - the apps, the framework and `config/` to the app team;
   - each flow's directories, `config/*/<flow>/`, to that flow's team.
8. **Repository settings.** No file can set these; each repository applies them once:

   | Setting | Value |
   |---|---|
   | Actions → workflow permissions | allow GitHub Actions to create pull requests (release pull request, version-bump pull request) |
   | Rulesets | as in rules 2 and 5 |
   | Environments | one per deployed env, named like the env (`us-dev`), deployment branch `main`, holding the env's deploy secrets (`DEV_DEPLOY_SSH_KEY`) |
   | Packages | the first `main` run creates `<registry>/<project>/<AppName>`; private by default; grant `read` to the consumers |
   | Optional | secret `RETENTION_TOKEN` and variable `RETENTION_DRY_RUN=false` for the nightly retention; label `ci:full`; the Renovate app |

## Alternatives considered

- **GitFlow** (`develop` and `release/*` branches). Long-lived branches, back-merges, and a second integration
  point that `main` would have to mirror.
- **Letting automation commit to `main`** (a bypass for a bot that records deployed tags). Unreviewed changes on
  the protected branch, and a loop the pipeline would have to guard against.
- **Merge commits.** The pull request's title is repeated in the merge commit's body, so the release tool counts
  every change twice. This repository's changelog shows exactly that.
- **One required check per job.** Every new or skipped job would mean editing branch protection, and a skipped
  required check blocks the merge.

## Consequences

- Every change on `main` was reviewed, tested in the merge queue, and is one Conventional Commit.
- Pull requests opened by workflows with `GITHUB_TOKEN` (the release pull request, version-bump pull requests) start
  no workflow, so `pr-gate` never reports on them. Tags created that way start no workflow either. A GitHub App
  token removes both limits (known gap).
- Known gaps:
  - Merge commits are still allowed: 12 of the 27 commits so far are merges, and `CHANGELOG.md` lists each change
    twice.
  - No CI check validates pull-request titles.
  - A hotfix branch and `main` count from the same last tag, so both can compute the same `-rc.<n>` version.
    `pushImage` overwrites an existing tag, so immutability is enforced only when re-tagging.
