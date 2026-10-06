# connectors-framework

The library every connector app depends on ([ADR-0006](../../docs/adr/0006-apps-and-framework-modules.md)). Auto-configured (`AppRuntimeAutoConfiguration`):

| Piece | What it does |
|---|---|
| `ConnectorIdentity` | the tuple `<env>/<flow>/<AppName>/<AppInstance>` from `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE`, validated against the naming model ([ADR-0003](../../docs/adr/0003-identity-tuple-names-every-instance.md)); fails fast when `APP_NAME` is another app's |
| `ConnectorProperties` | `@ConfigurationProperties("connector")` + `@Validated`: `connector.source.*`, `connector.sink.type` (`amps`, `deephaven`, `stub`), `connector.sink.amps.*`, `connector.sink.deephaven.*` ([ADR-0011](../../docs/adr/0011-configuration-tree-and-spring-layers.md)) |
| `ConfigurationSummary`, `SecretMasker` | the start-up summary: identity, config layers found, every `connector.*` / `spring.datasource.*` value with secrets masked ([ADR-0013](../../docs/adr/0013-secrets.md)) |
| `PlatformApplication` | `main` helper; `--print-config` prints the summary and exits (`run-compose.sh app-config --offline`) |
| metrics, MDC | common tags `env`, `flow`, `app`, `instance` on every meter; `ConnectorMdc` puts them into the MDC |
| `AppHealthIndicator` | health contributor `app`, part of the readiness group (`readinessState,app`) |
| `AppInfoContributor`, `AppConfigEndpoint` | identity in the `app` section of `/actuator/info`; `/actuator/appconfig` returns the masked summary. The generic names that the runtime scripts read first ([ADR-0037](../../docs/adr/0037-runtime-scripts-read-generic-actuator-names.md), [ADR-0040](../../docs/adr/0040-actuator-contract-and-runtime-module-carry-generic-names.md)) |

Test fixtures (`testFixtures(project(":connectors-framework"))`):
`CanonicalJson`, `CompareRules`, `RowSetComparator`, `ComparisonResult` — the expected-output comparison of
[ADR-0026](../../docs/adr/0026-integration-test-data-and-comparison.md) — and `AbstractPlatformApplicationTest`, the actuator contract every app's unit test inherits.
