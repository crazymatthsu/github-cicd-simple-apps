---
name: add-app
description: Add a Spring Boot app to this repository the way the contract requires. Creates the module under the apps directory from the templates, its configuration in local and in each dev env, the chart when kinds includes helm, and runs the verification. Use when asked to add, create or scaffold a new app, service or module.
arguments: [app, flow, instance]
allowed-tools: Bash(./gradlew *) Bash(scripts/*) Bash(cp *) Bash(sed *) Bash(mkdir *) Bash(grep *) Read Write Edit Glob Grep
---

# Add an app

The executable form of "Add an app to this repository" in `docs/adr/README.md` (ADR-0006, ADR-0011, ADR-0015,
ADR-0043). The templates are in `${CLAUDE_SKILL_DIR}/templates/`; `scripts/test/skills-test.sh` keeps them equal to
the reference app's files, so copy them rather than an existing app: an existing app carries its own domain.

## Inputs

| Input | Rule |
|---|---|
| `$app` | the `AppName`: lower-case kebab-case, at most 20 characters (ADR-0003). It is the directory, the Gradle project, the image name and `spring.application.name` |
| `$flow` | one of the `flows` of `platform.yml` |
| `$instance` | the first `AppInstance`: a business name in lower-case kebab-case, at most 32 characters, never a bare number |
| summary | one line: what the app does (the class comment and the README) |
| port | a free `ACTUATOR_HOST_PORT` per env: the next unused value above 18080 among `config/<env>/*/*/*/_docker-compose.instance.env` |
| integration tests | yes or no; if yes, the stacks the tests need (ADR-0025, ADR-0038) |

Derived from `platform.yml`: `group`, `apps_dir`, `kinds`, `dev_envs`, `registry` and `name`. The Java package is
`<group>.<app without hyphens>`; the class prefix is the app name in PascalCase (`ledger-feed` gives
`com.acme.payments.ledgerfeed` and `LedgerFeedApplication`).

## Steps

1. **The module** `<apps_dir>/$app/`, from `${CLAUDE_SKILL_DIR}/templates/app/`:

   | Creates | From |
   |---|---|
   | `build.gradle.kts` | `templates/app/build.gradle.kts` |
   | `src/main/java/<package path>/<Class>Application.java` | `templates/app/Application.java` |
   | `src/main/resources/application.yml` | `templates/app/application.yml` |
   | `src/test/java/<package path>/<Class>ApplicationTest.java` | `templates/app/ApplicationTest.java` |
   | `README.md` | `templates/app/README.md` |

   Replace the placeholders `__APP_NAME__`, `__APP_PACKAGE__`, `__APP_CLASS__` and `__APP_SUMMARY__` in every
   copied file (`sed -i`). Nothing else changes: the build discovers the directory (ADR-0006 rule 6), the image comes
   from the shared Dockerfile (ADR-0009), and the port is 8080.

2. **The configuration in `local`**, from `${CLAUDE_SKILL_DIR}/templates/config/`:
   - `config/local/$flow/$app/application.app.yml` and `_docker-compose.app.env`;
   - `config/local/$flow/$app/$instance/application.instance.yml` and `_docker-compose.instance.env`;
   - when `kinds` includes `helm`: `_helm-values.app.yaml` in the app directory and `_helm-values.instance.yaml` in
     the instance directory.

   Placeholders: `__ENV__` (`local`), `__FLOW__`, `__APP_NAME__`, `__INSTANCE__`, `__IMAGE_TAG__` (`local`),
   `__PORT__`. The flow directory must already hold `_docker-compose.flow.env` (`IMAGE_REPO`, ADR-0012); for a new
   flow create it from `${CLAUDE_SKILL_DIR}/../new-repo-from-template/templates/flow.env`.

3. **Each dev env of `dev_envs`**: the same files with `__ENV__` the env, `__IMAGE_TAG__` = `main` and a port free on
   the env's boxes, plus a target in `config/<env>/$flow/workflows-config.yml` (ADR-0027):
   ```yaml
     - instance: <app>/<instance> # <AppName>/<AppInstance>, relative to this flow
       kind: compose # any box of the pool (ADR-0028); `host: <box>` pins it
   ```

4. **When `kinds` includes `helm`**: the chart. `cp -r ${CLAUDE_SKILL_DIR}/templates/helm <apps_dir>/$app/helm/$app`
   and replace `__APP_NAME__`, `__IMAGE_REPOSITORY__` (`<registry>/<name>/$app`) and `__REPOSITORY_URL__` (the
   GitHub URL of the repository). Charts are identical but for the name and the description (ADR-0019).

5. **Integration tests, only when asked** (ADR-0025, ADR-0038): apply `buildlogic.integration-test` in the build
   file (the commented line), add the tests under `src/integrationTest/java/`, declare the stacks in
   `test-infra/compose/stacks.yml` (`<app>: [<stack>, ...]`, each stack a `<stack>.yml` next to it with its entry
   under `stacks:`), a test case under `test-infra/testdata/<app>/<case>/` (ADR-0026), and the test clients as
   `integrationTestImplementation` dependencies of the app.

6. **Only if needed**: `<apps_dir>/$app/docker/docker-compose.override.yml` to pass a secret through from the shell
   (ADR-0013); `<apps_dir>/$app/scripts/smoke.sh` for app-specific smoke checks (ADR-0017).

7. **Verify**, then add the app to the repository's `README.md`:
   ```bash
   ./gradlew :<app>:build configLint
   scripts/run-compose.sh local <flow> <app> <instance> validate
   scripts/run-compose.sh local <flow> <app> <instance> start   # with a container engine; then health, then down
   ./gradlew :<app>:integrationTest                             # when it has integration tests and an engine
   ```

## Never

- Copy another app's `application.yml` or chart: they carry that app's domain. The templates carry the contract only.
- Set a secret, a Spring property or a host of a promoted env in an env file (ADR-0012, ADR-0013).
- Reuse an `ACTUATOR_HOST_PORT` within an env, or name an instance with a bare number (ADR-0003).
