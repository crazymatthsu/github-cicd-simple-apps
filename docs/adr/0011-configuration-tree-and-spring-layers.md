# ADR-0011 — Configuration lives in a tree whose path is the identity, applied as Spring layers

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every app, every instance, this repository's `config/` and the configuration repository |
| Enforced by | config-lint checks 1 to 5 and 9; `ConfigLayeringTest` (the precedence, against a rendered tree); `run-compose.sh` (required files, layouts it does not know) |
| Related | [ADR-0003](0003-identity-tuple-names-every-instance.md), [ADR-0004](0004-environments-and-runtimes.md), [ADR-0012](0012-compose-template-and-generated-env.md), [ADR-0013](0013-secrets.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md) |

## Context

One app runs as many instances. Configuration must be reviewable in git and layered so that a shared value is
written once. It must never contain secrets. The blast radius of an edit must match its scope: one instance, one
app in one cluster, one cluster. Changing configuration must not require a rebuild.

## Decision

1. **The tree.** `config/<env>/<flow>/<AppName>/<AppInstance>/`. The path is the identity
   ([ADR-0003](0003-identity-tuple-names-every-instance.md)). This repository holds `local` and its dev envs; the
   configuration repository holds the promoted envs with the same layout and rules
   ([ADR-0004](0004-environments-and-runtimes.md)).
2. **The Spring layers, lowest precedence first:**

   | # | Layer | Source | Required |
   |---|---|---|---|
   | 1 | jar defaults | `apps/<AppName>/src/main/resources/application.yml` | yes |
   | 2 | flow (the cluster) | `config/<env>/<flow>/application.flow.yml` | no |
   | 3 | app in this flow | `config/<env>/<flow>/<AppName>/application.app.yml` | yes |
   | 4 | instance | `config/<env>/<flow>/<AppName>/<AppInstance>/application.instance.yml` | yes |
   | 5 | secrets | the environment (compose) or `/secrets/` (Kubernetes) ([ADR-0013](0013-secrets.md)) | — |

   Environment variables override every file in Spring Boot. They are therefore reserved for the identity, the
   container settings and secrets, and never used to set an application property.
3. **Nothing is shared above the flow.** There is no env-wide layer and no layer shared across envs.
   - A value that is the same in every env is a jar default. It ships with the code and reaches each env with a
     release.
   - A value shared inside an env is a flow value, because one flow in one env is one cluster.
4. **Layers are files, named by level:**
   - **`application.<layer>.yml`** is what the app reads. These are the only files of the tree that reach the
     container.
   - **`_<tool>.<layer>.<ext>`** files are read on the host by a deploy tool and never mounted:
     `_docker-compose.<layer>.env` and `_docker-compose.<layer>.yml`
     ([ADR-0012](0012-compose-template-and-generated-env.md)), and `_helm-values.<layer>.yaml` (provisional,
     [ADR-0019](0019-kubernetes-and-helm-are-provisional.md)). The leading `_` marks deploy-tool files and sorts
     them first.
   - `<layer>` is `flow`, `app` or `instance`, and MUST match the level of the directory the file is in.
5. **What each directory may hold** (anything else is an error):

   | Directory | Files |
   |---|---|
   | `config/` | `<env>/`, `README.md` |
   | `config/<env>/` | `<flow>/`, `known_hosts` ([ADR-0028](0028-host-pool-deployment.md)) |
   | `config/<env>/<flow>/` | `workflows-config.yml` (dev envs: required, [ADR-0027](0027-continuous-deployment-to-dev-and-the-deployment-record.md)); optional `application.flow.yml`, `_docker-compose.flow.env`, `_docker-compose.flow.yml`; `<AppName>/` |
   | `config/<env>/<flow>/<AppName>/` | required `application.app.yml`, `_helm-values.app.yaml`; optional `_docker-compose.app.env`, `_docker-compose.app.yml`; `<AppInstance>/` |
   | `…/<AppInstance>/` | required `application.instance.yml`, `_docker-compose.instance.env`, `_helm-values.instance.yaml`; optional `_docker-compose.instance.yml`; no subdirectories |

6. **Each layer is mounted as one read-only file, always at the same container path:**
   - `/config/flow/application.yml` (a missing flow layer mounts `/dev/null`, an empty file);
   - `/config/common/application.yml`;
   - `/config/instance/application.yml`.

   Every app's jar defaults MUST declare exactly this import list:

   ```yaml
   spring:
     config:
       import:
         - optional:file:/config/flow/application.yml
         - optional:file:/config/common/application.yml
         - optional:file:/config/instance/application.yml
         - optional:configtree:/secrets/
   ```

7. **What goes where:**
   - Application properties (endpoints, topics, table names, intervals, log levels) belong in the YAML layers.
   - Container settings belong in the env layers ([ADR-0012](0012-compose-template-and-generated-env.md)).
   - Secrets belong nowhere in the tree ([ADR-0013](0013-secrets.md)).
8. **Every deployable app MUST be configured in `local`,** so that it runs on a laptop and in the integration tests.

## Alternatives considered

- **An env-wide shared layer.** Nothing is shared at env level; flows are separate clusters, and the layer only
  widens the blast radius of an edit.
- **A layer shared by all envs.** One edit reaches dev and prod at once. Values shared by every env belong in the
  jar and reach each env with a release.
- **Layer directories mounted whole.** A flow directory holds every app and instance of the flow: mounting it
  exposes all of them to each container.
- **Spring profiles per env.** Configuration compiled into the jar: a change needs a rebuild, and profiles do not
  scale to instances.
- **A configuration server.** One more runtime dependency, and the reviewed files in git stop being the record.
- **App configuration in `.env` files.** Environment variables beat every YAML file, which would invert the
  layering.

## Consequences

- A new instance is one directory with three files (plus its deploy-inventory target in a dev env).
- An edit's reach is visible from its path: a flow file reaches every app of that cluster, never another flow or
  env.
- A configuration-only change needs no rebuild. In this repository it runs config-lint, and on `main` a dev
  deploy.
- The configuration repository needs the same rules and a way to run them (open decision: config-lint learns its
  apps from Gradle subprojects, which a configuration-only repository does not have).
- This repository's config-lint still accepts promoted-env directories (known gap).
