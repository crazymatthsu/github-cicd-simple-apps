# Connector Helm chart (`Chart.yaml` name = the AppName)

The chart of one connector app. `source-database`, `source-kafka` and `source-amps` carry identical copies
under `apps/<AppName>/helm/<AppName>/`; only `Chart.yaml` (name, description) and
`image.repository` differ. One Helm release per AppInstance of the config tree ([ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md)): the
directory `config/<env>/<flow>/<AppName>/<AppInstance>/` becomes the release `<AppName>-<AppInstance>` in the
namespace `<flow>` ([ADR-0003](../../../../docs/adr/0003-identity-tuple-names-every-instance.md)), with one Deployment (`replicas: 1`), its ConfigMap, Service and ServiceAccount.
The `Secret` with the credentials is never templated from values ([ADR-0013](../../../../docs/adr/0013-secrets.md)): the deployer creates
`<release>-secrets`, or the `ExternalSecret` of the EKS design does ([ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md)).

Deploy, lint or render an instance with the one deployer, never with a hand-written `helm` line (example:
`source-database`):

```bash
scripts/helm-deploy-instance.sh us-dev cash source-database trades-db-to-amps --tag 0.1.0-rc.39 --mode template
scripts/helm-deploy-instance.sh us-dev cash source-database trades-db-to-amps --tag 0.1.0-rc.39 --mode lint
scripts/helm-deploy-instance.sh local cash source-database trades-db-to-amps --tag local \
  --secret-user sa --secret-password "$SA_PASSWORD"          # --mode deploy (default); --dry-run prints it
helm test source-database-trades-db-to-amps -n cash --logs   # the smoke test alone
```

## Flag list (`scripts/helm-deploy-instance.sh`, [ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md))

| Flag | Source | Layer ([ADR-0011](../../../../docs/adr/0011-configuration-tree-and-spring-layers.md)) |
|---|---|---|
| chart `values.yaml` | this directory | values layer 1 |
| `-f config/<env>/<flow>/<AppName>/_helm-values.app.yaml` | sizing, `env.TZ` | values layer 2 |
| `-f config/<env>/<flow>/<AppName>/<AppInstance>/_helm-values.instance.yaml` | `image.tag`, `identity`, `env.APP_*`, `JAVA_OPTS`, `LOG_LEVEL_ROOT` | values layer 3 |
| `--set-string image.tag=<tag>` | the deployed tag (`--tag`) | wins over layer 3 |
| `--set-file appConfig.flow=config/<env>/<flow>/application.flow.yml` | only when the file exists (the cluster layer, [ADR-0011](../../../../docs/adr/0011-configuration-tree-and-spring-layers.md)) | `/config/flow/application.yml` |
| `--set-file appConfig.common=.../<AppName>/application.app.yml` | required | `/config/common/application.yml` |
| `--set-file appConfig.instance=.../<AppInstance>/application.instance.yml` | required | `/config/instance/application.yml` |
| `--set-file appFiles.<layer>.<file>=<path>` | any other file of those three directories (not `application.*.yml`, the `_`-prefixed deploy-tool files, `workflows-config.yml`, `README.md`; config-lint allows none today), `.` in the name escaped as `\.` | `/config/<layer>/<file>` |

`--mode deploy` adds: the namespace with the `restricted` Pod Security labels, the `Secret`
`<release>-secrets` (`spring.datasource.username`, `spring.datasource.password`), `helm lint`,
`helm upgrade --install --create-namespace --rollback-on-failure --wait --timeout 5m` (a first install runs
without `--rollback-on-failure`: nothing to restore, and its failed pods stay for the diagnostics),
`kubectl rollout status` and `helm test --logs`; a failure after the upgrade rolls back to the previous
revision. `--help` has the details and exit codes.

## Objects

| Object | Name | Notes |
|---|---|---|
| ServiceAccount | `<release>` | no token mounted; IRSA / Vault identity left to the EKS design ([ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md); `serviceAccount.annotations`) |
| ConfigMap | `<release>-config` | keys `<layer>.application.yml` and `<layer>.<file>`; projected to `/config/<layer>/<file>` |
| Deployment | `<release>` | `Recreate`, probes on the actuator, restricted security context, `checksum/config` annotation |
| Service | `<release>` | ClusterIP, port `http` → 8080 (actuator: health, metrics) |
| Job (helm test) | `<release>-smoke-test` | curl from the app image: readiness `UP`, `/actuator/info` identity tuple and `complete: true` |
| NetworkPolicy, PodDisruptionBudget, ServiceMonitor, ExternalSecret | `<release>` | off by default (`enabled` flags); the PDB also needs `replicaCount > 1` |

Every object carries `app.kubernetes.io/name`, `app.kubernetes.io/instance` (the release),
`app.kubernetes.io/managed-by: Helm` and `platform.example.com/{env,flow,app,instance}` from `identity`.
The pods of the connector add `app.kubernetes.io/component: connector` (the selector); the test Job has
`smoke-test`, so it never joins the Service.

## Values

| Key | Default | Meaning |
|---|---|---|
| `replicaCount` | `1` | one consumer per pipeline |
| `image.repository` | `ghcr.io/crazymatthsu/github-cicd-simple-apps/<AppName>` | required; JFrog or the ECR mirror on EKS ([ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md)) |
| `image.tag` | `""` | required (schema): instance values, `--set-string image.tag=<tag>` from the deployer |
| `image.digest` | `""` | `sha256:…` pins the image: `repository@digest` ([ADR-0010](../../../../docs/adr/0010-image-tags-digests-promotion-retention.md)) |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | `[{ name: … }]` for a private registry |
| `serviceAccount.create`, `.name`, `.annotations`, `.automountToken` | `true`, `""`, `{}`, `false` | |
| `identity.env`, `.flow`, `.app`, `.instance` | `""` | required, from the instance values; labels and the helm test; must equal `env.APP_*`, `app` the chart name |
| `env` | `{}` | container environment as a map (rendered sorted); `SPRING_*`, `CONNECTOR_*_PASSWORD` and other secret-bearing names are rejected |
| `appConfig.<layer>` | `{}` | `flow`, `common` (required), `instance` (required): `application.yml` contents |
| `appFiles.<layer>.<file>` | `{}` | other layer files (`logback.xml`, `*.properties`) |
| `secrets.existingSecret` | `""` | default `<release>-secrets`, mounted at `/secrets/` (mode 0400, `optional: false`) |
| `secrets.externalSecret.enabled`, `.storeRef`, `.storeKind`, `.vaultPath`, `.refreshInterval` | `false`, `vault-<env>`, `ClusterSecretStore`, `<env>/<flow>/<app>/<instance>`, `1m` | left to the EKS design ([ADR-0019](../../../../docs/adr/0019-kubernetes-and-helm-are-provisional.md)) |
| `service.port` | `8080` | Service port `http` |
| `probes.startup` | liveness path, every 5 s, 24 failures | 2-minute start budget ([ADR-0015](../../../../docs/adr/0015-actuator-health-and-metrics-contract.md)) |
| `probes.readiness`, `probes.liveness` | `/actuator/health/readiness`, `/actuator/health/liveness`, every 10 s, 3 failures, 3 s timeout | [ADR-0015](../../../../docs/adr/0015-actuator-health-and-metrics-contract.md) |
| `resources` | requests `250m` / `1Gi`, limits `1Gi` | memory request = limit; `_helm-values.app.yaml` sets it per env + flow |
| `strategy` | `{ type: Recreate }` | `RollingUpdate` only for idempotent pipelines |
| `terminationGracePeriodSeconds` | `30` | graceful shutdown ([ADR-0015](../../../../docs/adr/0015-actuator-health-and-metrics-contract.md)) |
| `podSecurityContext`, `securityContext` | non-root 10001, `fsGroup` 10001, `RuntimeDefault` seccomp; read-only root, no privilege escalation, all capabilities dropped | Pod Security Standard `restricted` |
| `tmp.sizeLimit`, `logs.sizeLimit`, `data.sizeLimit` | `256Mi` | emptyDir `/tmp`, `/app/logs` and `/app/data` |
| `topologySpread.*` | enabled, `topology.kubernetes.io/zone`, skew 1, `ScheduleAnyway` | instances of one app spread across zones |
| `reloader.enabled` | `false` | Reloader annotation for the ESO-owned Secret |
| `serviceMonitor.enabled`, `.interval`, `.path`, `.labels` | `false`, `30s`, `/actuator/prometheus`, `{}` | Prometheus Operator |
| `podDisruptionBudget.enabled`, `.maxUnavailable` | `false`, `1` | rendered only with `replicaCount > 1` |
| `networkPolicy.enabled`, `.ingressNamespaces`, `.egress` | `false`, `[monitoring]`, `[]` | ingress from the release's own pods and those namespaces; egress DNS plus the given rules |

`values.schema.json` rejects unknown top-level keys and unknown keys in the chart's own sections, so a
misspelt key fails `helm lint` / `helm template` in config-lint check 12 ([ADR-0014](../../../../docs/adr/0014-config-lint-enforces-the-config-contract.md)) before any deploy. `helm lint`
does not evaluate the chart's `fail` guards (identity vs `env.APP_*`, `identity.app` vs the chart): `helm
template`, which config-lint runs as well, and `helm upgrade` do.
