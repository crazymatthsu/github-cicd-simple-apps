# Documentation of github-cicd-simple-apps

| Document | What |
|---|---|
| [`adr/`](adr/README.md) | **The repository contract**: the ADRs; checklists for adding an app, adding an instance or creating a repository from this one; known gaps; open decisions |
| [`../config/README.md`](../config/README.md) | the configuration tree in practice: files per level, host pools, the deploy inventory |
| [`../test-infra/README.md`](../test-infra/README.md) | the compose stacks and how the integration tests run, on a laptop and in CI |
| [`../test-infra/kind/README.md`](../test-infra/kind/README.md) | the kind tier of the provisional Helm path |
| `../apps/<AppName>/README.md` | one app: what it does, its configuration keys, its actuator |
| `../apps/<AppName>/helm/<AppName>/README.md` | its chart (provisional) |

## Where to find what

| Question | Answer in |
|---|---|
| What is a project, an env, a flow, an instance? | [ADR-0002](adr/0002-one-repository-one-project-one-release-line.md) to [ADR-0004](adr/0004-environments-and-runtimes.md), and the glossary in [`adr/README.md`](adr/README.md) |
| Which files may an app, the framework or the configuration tree contain? | [ADR-0005](adr/0005-repository-layout-and-shared-tooling.md), [ADR-0006](adr/0006-apps-and-framework-modules.md), [ADR-0011](adr/0011-configuration-tree-and-spring-layers.md) |
| What does each workflow do, and why? | [ADR-0021](adr/0021-ci-layering.md) to [ADR-0024](adr/0024-ephemeral-ci-environments.md), [ADR-0027](adr/0027-continuous-deployment-to-dev-and-the-deployment-record.md), [ADR-0029](adr/0029-release-and-promotion.md) |
| How do I run, inspect or roll back an instance? | [ADR-0017](adr/0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0018](adr/0018-on-prem-host-layout-versioned-bundles.md), [ADR-0028](adr/0028-host-pool-deployment.md), and `scripts/run-compose.sh --help` |
| Which repository settings must be applied by hand? | [ADR-0020](adr/0020-branching-protection-and-merge-rules.md), rule 8 |

## Documentation rules

- Decisions — and the rules they set — are made only in ADRs ([ADR-0001](adr/0001-adrs-are-the-repository-contract.md)).
- A README lives next to what it describes and explains how to use it. It must not contradict an ADR.
- `CHANGELOG.md` is written by the release tooling and never edited by hand.
