# CLAUDE.md

This repository is the reference implementation and the template of one set of conventions for Spring Boot
services: the layout, the Gradle build, the configuration tree, the CI/CD workflows and the runtime operations.
Other repositories are created from it and copy its shared tooling unchanged. The conventions are the contract in
`docs/adr/`; this file is the short form for a coding agent. Where the two disagree, the ADRs win.

## Read first

- `docs/adr/README.md`: the index. One row per ADR, the glossary, the three checklists (add an app, add an
  instance, create a repository), what a new repository may leave out, the known gaps and the open decisions.
- `platform.yml`: every project value (registry, project name, group, apps directory, runtimes, reference app,
  dev envs, regions, stages, flows). Nothing else declares one, and every tool reads this file (ADR-0030).

## The contract in one screen

- **One repository, one project, one release line** (ADR-0002). Versions come from git tags and Conventional
  Commits (ADR-0008); `CHANGELOG.md` is written by release-please, never by hand.
- **Three classes of files** (ADR-0005 rule 5). Shared tooling is copied unchanged into every repository built
  from this one and changed here first: `build-logic/`, `docker/`, `scripts/`, `.github/actions/`,
  `.github/workflows/_*.yml`, `test-infra/compose/{base.yml,it-runner.yml,stack.sh}`, `test-infra/kind/`, the
  ADRs 0001 to 0999, `CLAUDE.md` and `.claude/skills/`. Project files are the project's own: `platform.yml`,
  `apps/`, `framework/`, `config/`, the test data and stacks, `README.md`.
- **An app** is `apps/<AppName>/`: a Spring Boot service on Java 21 built on the runtime module under
  `framework/`, packaged as one image by the shared Dockerfile (ADR-0006, ADR-0009). Its main class calls
  `PlatformApplication.run`; one test extends `AbstractPlatformApplicationTest`. It exposes `health`, `info`,
  `prometheus` and `appconfig` on port 8080 and nothing else (ADR-0015, ADR-0040).
- **The identity tuple** `<env>/<flow>/<AppName>/<AppInstance>` names every running instance; an env is `local`
  or `<region>-<stage>` (ADR-0003). The config tree restates it: `config/<env>/<flow>/<AppName>/<AppInstance>/`
  holds `application.instance.yml` and `_docker-compose.instance.env` (the identity, `IMAGE_TAG`,
  `ACTUATOR_HOST_PORT`); the app directory holds `application.app.yml`; the flow directory holds
  `_docker-compose.flow.env` and, in a dev env, `workflows-config.yml` (ADR-0011, ADR-0012, ADR-0027). The Helm
  values files exist only when `kinds` includes `helm` (ADR-0036).
- **Secrets never sit in the tree.** They arrive from the environment or `/secrets/`; config-lint check 9 refuses
  a secret property or a secret-looking value in any YAML layer (ADR-0013).
- **Every change goes through a pull request** with a Conventional Commit title; `pr-gate` is the only required
  check; squash merge (ADR-0020). A change to behaviour an ADR governs adds the superseding ADR in the same pull
  request and updates the known gaps (ADR-0001 rule 8).
- **An ADR applies where its subject exists.** A repository without Helm, integration tests, a dev env or a host
  pool deviates from nothing (ADR-0039); the index section "What a new repository may leave out" lists the switches.

## Commands

```bash
./gradlew build                      # every module: unit tests, quality gates, bootJar; buildImage no-ops without an engine
./gradlew configLint                 # the configuration tree against the contract (ADR-0014)
scripts/ci/setup-yq.sh               # the pinned mikefarah yq on PATH (the script tests and pool-deploy.sh need it)
for t in scripts/test/*-test.sh; do bash "$t"; done     # the script tests the lint job runs
scripts/run-compose.sh local <flow> <AppName> <AppInstance> validate   # also start, health, app-config, down
test-infra/compose/stack.sh up --project :<AppName> --local            # an app's test stack on a laptop (ADR-0025)
./gradlew :<AppName>:integrationTest                                   # its component integration tests on that stack
```

actionlint, ShellCheck and hadolint run in the `lint` job (ADR-0021 rule 8). Run them locally on a workflow, a
script or the Dockerfile you change.

## Procedures

The three checklists of the index have an executable form: the skills `new-repo-from-template`, `add-app` and
`add-instance` under `.claude/skills/`. Use them for those tasks. They carry the file templates and the
verification steps, and `scripts/test/skills-test.sh` keeps their templates equal to the reference app's files
(ADR-0043).

## Where things are

| Need | Look in |
|---|---|
| a project value | `platform.yml` only |
| what a workflow does | the header comment of each `.github/workflows/*.yml`; ADR-0021 to ADR-0024, ADR-0027, ADR-0029 |
| how an instance runs on a box | `scripts/run-compose.sh --help`; ADR-0017, ADR-0018, ADR-0028 |
| the compose test stacks | `test-infra/README.md`, `test-infra/compose/stacks.yml`; ADR-0025, ADR-0038 |
| the config-lint checks | ADR-0014; `build-logic/src/main/kotlin/buildlogic/ConfigLint.kt` |
| the repository settings applied by hand | ADR-0020 rule 8, ADR-0032 |
| what does not work yet | the known gaps and the open decisions in `docs/adr/README.md` |

## Rules for a coding agent

- Do not edit shared tooling in a repository built from this one; change it here and copy the release (ADR-0005).
- Do not hard-code a project value; read `platform.yml` (Gradle gets it as `buildlogic.platform.<key>`, scripts
  read it with awk or yq, the jar carries the vocabulary).
- Do not add an endpoint, a file class or a configuration layer that no ADR names; write the ADR first.
- Do not commit a secret, a model name, or generated state: `CHANGELOG.md` is written by release-please, and the
  `.run/` and `.state/` directories of the runtime scripts and the test stacks are local.
- Before a pull request: `./gradlew build configLint`, the script tests, and the linters of the files you touched.
