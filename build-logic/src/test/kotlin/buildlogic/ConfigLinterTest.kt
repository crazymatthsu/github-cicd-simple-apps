package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class ConfigLinterTest {
    @TempDir
    lateinit var root: File

    /** The one compose template (ADR-0012); its comment names a required variable that must not count. */
    private val template: File by lazy {
        File(root, "docker/docker-compose.yml").apply {
            parentFile.mkdirs()
            writeText("# \${COMMENTED:?not a variable}\nservices:\n  app:\n    image: \${IMAGE_REPO:?x}/\${APP_NAME:?x}:\${IMAGE_TAG:?x}\n")
        }
    }
    /** source-database's own override: the secret it needs in every env. */
    private val appOverride: File by lazy {
        File(root, "source-database/docker/docker-compose.override.yml").apply {
            parentFile.mkdirs()
            writeText("services:\n  app:\n    environment:\n      SPRING_DATASOURCE_PASSWORD: \${SPRING_DATASOURCE_PASSWORD:?secret}\n")
        }
    }
    private val chart: File get() = File(root, "source-database/helm/source-database")
    private val config: File get() = File(root, "config")
    private val rendered: File get() = File(root, "rendered")

    private fun write(path: String, text: String) = File(config, path).apply { parentFile.mkdirs(); writeText(text) }

    private fun composeEnv(env: String, flow: String, app: String, instance: String, extra: String = "", tag: String = "local") =
        "IMAGE_REPO=ghcr.io/o/github-cicd-simple-apps\nIMAGE_TAG=$tag\nAPP_ENV=$env\nAPP_FLOW=$flow\nAPP_NAME=$app\n" +
            "APP_INSTANCE=$instance\nJAVA_OPTS=-XX:MaxRAMPercentage=60\nTZ=UTC\nACTUATOR_HOST_PORT=18081\n$extra"

    private fun instanceValues(env: String, instance: String, tag: String = "local", extraEnv: String = "") =
        "image:\n  tag: \"$tag\"\nidentity:\n  env: $env\n  flow: cash\n  app: source-database\n  instance: $instance\n" +
            "env:\n  APP_ENV: $env\n  APP_FLOW: cash\n  APP_NAME: source-database\n  APP_INSTANCE: $instance\n" +
            "  JAVA_OPTS: \"-XX:MaxRAMPercentage=60\"\n$extraEnv"

    private fun validInstance(env: String, instance: String, tag: String = "local") {
        write("$env/cash/source-database/application.app.yml", "connector:\n  source:\n    port: 1433\n")
        write("$env/cash/source-database/_helm-values.app.yaml", "resources:\n  limits:\n    memory: 768Mi\nenv:\n  TZ: UTC\n")
        write("$env/cash/source-database/$instance/application.instance.yml", "connector:\n  source:\n    host: db\n")
        write("$env/cash/source-database/$instance/_docker-compose.instance.env", composeEnv(env, "cash", "source-database", instance, tag = tag))
        write("$env/cash/source-database/$instance/_helm-values.instance.yaml", instanceValues(env, instance, tag))
    }

    /** A kubeconform answer in the shape of `-output json -summary`. */
    private fun kubeconform(valid: Int, skipped: Int = 0, resources: String = "") =
        "{\n  \"resources\": [$resources],\n  \"summary\": {\"valid\": $valid, \"invalid\": 0, \"errors\": 0, \"skipped\": $skipped}\n}\n"

    /** The vocabulary of this repository's platform.yml; `envs = null` as in the configuration repository, which holds every env. */
    private val everyEnv = LintScope(regions = setOf("us", "jp"), stages = setOf("dev", "qa", "uat", "prod", "parallel"),
        flows = setOf("cash", "deriv", "swap"), kinds = setOf("compose", "helm"), envs = null)

    private val helmRequests = mutableListOf<HelmRequest>()
    private val helmOk = HelmRunner { request -> helmRequests += request; CommandResult(0, "") }
    private val kubeconformOk = ManifestValidator { CommandResult(0, kubeconform(valid = 5)) }

    private fun linter(
        renderer: ComposeRenderer? = null,
        helm: HelmRunner? = helmOk,
        validator: ManifestValidator? = kubeconformOk,
        completeEnvs: Set<String> = emptySet(),
        requireRender: Boolean = false,
        charts: Map<String, File> = mapOf("source-database" to chart),
        scope: LintScope = everyEnv,
    ) = ConfigLinter(config, setOf("source-database"), scope, template, mapOf("source-database" to appOverride), completeEnvs,
        renderer, requireRender, charts, helm, validator, rendered)

    private fun lint(scope: LintScope = everyEnv, renderer: ComposeRenderer? = null): List<Finding> =
        linter(renderer, scope = scope).lint().filter { it.severity != Severity.TODO }

    private fun List<Finding>.checks() = map { it.check }.toSet()
    private fun List<Finding>.text() = joinToString("\n")

    @Test
    fun `the shared layer is the cluster's application_flow_yml in the flow directory, never under the env (ADR-0011)`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/application.flow.yml", "logging:\n  structured:\n    format:\n      console: ecs\n")
        assertEquals(emptyList<Finding>(), lint(), lint().text())
        write("local/_common/application.yml", "a: 1\n")
        write("local/cash/_common/application.yml", "a: 1\n")
        val messages = lint().text()
        assertTrue(messages.contains("config/local/_common/ removed: nothing is shared at the env level"), messages)
        assertTrue(messages.contains("config/local/cash/_common: the cluster layer is files now: config/local/cash/application.flow.yml"), messages)
    }

    @Test
    fun `a top-level _common is rejected because nothing is shared across envs (ADR-0011)`() {
        validInstance("local", "trades-db-to-amps")
        write("_common/source-database/application.yml", "connector:\n  source:\n    poll-interval: 15s\n")
        val messages = lint().text()
        assertTrue(messages.contains("config/_common/ removed: nothing is shared across envs (ADR-0011)"), messages)
        assertEquals(1, lint().count { it.check == 1 }, messages)
    }

    @Test
    fun `a valid tree has no findings and passes placeholders for the secrets to the renderer`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ndefaults: { kind: compose, user: deploy }\ntargets:\n" +
            "  - instance: source-database/trades-db-to-amps\n    host: dev-01.example.com\n")
        val requests = mutableListOf<ComposeRenderRequest>()
        val findings = lint { request -> requests += request; CommandResult(0, "") }
        assertEquals(emptyList<Finding>(), findings)
        assertEquals(2, requests.size)
        assertEquals("config-lint-placeholder", requests[0].environment["SPRING_DATASOURCE_PASSWORD"])
        assertFalse("COMMENTED" in requests[0].environment, "a variable in a comment is not required: ${requests[0].environment}")
        assertEquals("local-cash-source-database-trades-db-to-amps", requests[0].environment["PROJECT"])
        assertEquals(listOf(template, appOverride), requests[0].composeFiles)
        assertEquals(File(config, "local/cash/source-database/application.app.yml").absolutePath, requests[0].environment["APP_APP_YML"])
        assertFalse("FLOW_APP_YML" in requests[0].environment, "no flow layer: the template mounts /dev/null")
    }

    @Test
    fun `naming, identity and allow-list violations are reported`() {
        validInstance("local", "42")
        write("local/cash/source-database/42/_docker-compose.instance.env",
            composeEnv("local", "cash", "source-database", "other", "SPRING_DATASOURCE_PASSWORD=x\nFOO=1\nCOMPOSE_ENV_FILE=/x\n"))
        write("local/fx/source-database/application.app.yml", "a: 1\n")
        write("eu-dev/README.md", "x")
        val findings = lint()
        val messages = findings.text()
        assertTrue(findings.checks().containsAll(setOf(1, 4, 5)), messages)
        assertTrue(messages.contains("never a bare number"), messages)
        assertTrue(messages.contains("SPRING_DATASOURCE_PASSWORD is forbidden"), messages)
        assertTrue(messages.contains("FOO is not an allowed"), messages)
        assertTrue(messages.contains("COMPOSE_ENV_FILE is set by run-compose.sh"), messages)
        assertTrue(messages.contains("APP_INSTANCE=other does not match"), messages)
        assertTrue(messages.contains("flow 'fx'"), messages)
        assertTrue(messages.contains("env 'eu-dev' must be local or <region>-<stage> with a region of [us, jp]"), messages)
        assertTrue(helmRequests.isEmpty(), "an invalid AppInstance is never rendered: $helmRequests")
    }

    @Test
    fun `unknown apps, missing files and missing targets are reported`() {
        write("us-dev/cash/source-nothing/application.app.yml", "a: 1\n")
        write("us-dev/cash/source-database/application.app.yml", "a: 1\n")
        write("us-dev/cash/source-database/trades-db-to-amps/application.instance.yml", "a: 1\n")
        val messages = lint().text()
        assertTrue(messages.contains("'source-nothing' is not a deployable Gradle subproject"), messages)
        assertTrue(messages.contains("trades-db-to-amps/_docker-compose.instance.env: required file missing"), messages)
        assertTrue(messages.contains("us-dev/cash/workflows-config.yml: required in every flow of a *-dev env"), messages)
    }

    @Test
    fun `secrets in YAML and floating tags in prod fail`() {
        validInstance("us-prod", "positions-db-to-deephaven", tag = "latest")
        write("us-prod/cash/source-database/positions-db-to-deephaven/application.instance.yml",
            "spring:\n  datasource:\n    password: hunter2hunter2\n")
        val findings = lint()
        val messages = findings.text()
        assertTrue(findings.checks().containsAll(setOf(9, 10)), messages)
        assertTrue(messages.contains("'spring.datasource.password' is a secret property"), messages)
        assertTrue(messages.contains("IMAGE_TAG 'latest' in us-prod must be an immutable release tag"), messages)
        assertTrue(messages.contains("image.tag 'latest' in us-prod must be an immutable release tag"), messages)
    }

    // --- platform.yml (ADR-0030): the vocabulary, the runtimes and the envs of this repository ------------------------

    @Test
    fun `this repository holds local and its dev envs only, the promoted envs live in the configuration repository`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ntargets:\n  - instance: source-database/trades-db-to-amps\n" +
            "    kind: compose\n    host: h\n")
        validInstance("us-prod", "trades-db-to-amps", tag = "1.4.2")
        validInstance("jp-dev", "trades-db-to-amps")
        val findings = lint(scope = everyEnv.copy(envs = setOf("us-dev")))
        val messages = findings.text()
        assertEquals(listOf("config/jp-dev", "config/us-prod"), findings.map { it.path }.sorted(), messages)
        assertTrue(findings.all { it.check == 1 && it.severity == Severity.ERROR }, messages)
        assertTrue(messages.contains("env 'us-prod' does not belong in this repository, which holds only local and its dev envs " +
            "[us-dev]: the promoted envs live in the configuration repository"), messages)
        assertTrue(messages.contains("env 'jp-dev' is not a dev env of this repository: add it to platform.yml dev_envs [us-dev]"), messages)
    }

    @Test
    fun `with dev_envs empty the tree holds local only`() {
        // ADR-0035: a repository that deploys no env yet; check 1 still accepts local.
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        val findings = lint(scope = everyEnv.copy(envs = emptySet()))
        val messages = findings.text()
        assertEquals(listOf("config/us-dev"), findings.map { it.path }, messages)
        assertTrue(messages.contains("env 'us-dev' is not a dev env of this repository: add it to platform.yml dev_envs []"), messages)
    }

    @Test
    fun `the regions, stages and flows of platform_yml are the vocabulary`() {
        validInstance("local", "trades-db-to-amps")
        write("local/fx/source-database/application.app.yml", "a: 1\n")
        write("eu-dev/cash/source-database/application.app.yml", "a: 1\n")
        write("us-stage/cash/source-database/application.app.yml", "a: 1\n")
        val narrow = lint().filter { it.check == 1 }.text()
        assertTrue(narrow.contains("flow 'fx' must be one of [cash, deriv, swap] (platform.yml)"), narrow)
        assertTrue(narrow.contains("env 'eu-dev' must be local or <region>-<stage>"), narrow)
        assertTrue(narrow.contains("env 'us-stage' must be local or <region>-<stage> with a region of [us, jp] and a stage of " +
            "[dev, qa, uat, prod, parallel] (platform.yml)"), narrow)
        val wide = lint(scope = everyEnv.copy(regions = setOf("us", "eu"), stages = everyEnv.stages + "stage",
            flows = everyEnv.flows + "fx")).filter { it.check == 1 }.text()
        assertFalse(wide.contains("must be one of"), wide)
        assertFalse(wide.contains("must be local or"), wide)
    }

    @Test
    fun `uat and parallel are promoted stages, so their tags are immutable like qa and prod`() {
        validInstance("us-uat", "trades-db-to-amps", tag = "latest")
        validInstance("us-parallel", "trades-db-to-amps", tag = "0.1.0-rc.39")
        validInstance("us-qa", "trades-db-to-amps", tag = "1.4.2")
        val messages = lint().filter { it.check == 10 }.text()
        assertTrue(messages.contains("IMAGE_TAG 'latest' in us-uat must be an immutable release tag"), messages)
        assertTrue(messages.contains("image.tag 'latest' in us-uat must be an immutable release tag"), messages)
        assertTrue(messages.contains("IMAGE_TAG '0.1.0-rc.39' in us-parallel must be an immutable release tag"), messages)
        assertFalse(messages.contains("us-qa"), "1.4.2 is a release tag: $messages")
    }

    @Test
    fun `a target names a runtime of platform_yml kinds`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ntargets:\n" +
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n    host: h\n" +
            "  - instance: source-database/positions-db-to-deephaven\n    kind: helm\n    cluster: kind-ci\n")
        assertEquals(emptyList<Finding>(), lint().filter { it.check == 11 }, lint().text())
        val composeOnly = lint(scope = everyEnv.copy(kinds = setOf("compose"))).filter { it.check == 11 }
        assertEquals(1, composeOnly.size, composeOnly.text())
        assertTrue(composeOnly.single().message.contains("targets[1]: kind 'helm' is not a runtime of this project " +
            "(platform.yml kinds: compose)"), composeOnly.text())
    }

    @Test
    fun `targets must match the instance directories`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: deriv\ntargets:\n  - instance: source-database/gone\n    kind: compose\n" +
            "    host: h\n    user: Root!\n  - instance: source-database/trades-db-to-amps\n    kind: helm\n" +
            "  - instance: cash/source-database/positions-db-to-deephaven\n    kind: helm\n    cluster: kind-ci\n")
        val messages = lint().filter { it.check == 11 }.text()
        assertTrue(messages.contains("source-database/gone has no directory config/us-dev/cash/source-database/gone/"), messages)
        assertTrue(messages.contains("kind helm needs cluster"), messages)
        assertTrue(messages.contains("user 'Root!' is not a valid login name"), messages)
        assertTrue(messages.contains("flow: must be 'cash', the flow of its path (was 'deriv')"), messages)
        assertTrue(messages.contains("instance must be <AppName>/<AppInstance>, relative to the flow " +
            "(was 'cash/source-database/positions-db-to-deephaven')"), messages)
        assertTrue(messages.contains("instance source-database/positions-db-to-deephaven has no target (inventory drift)"), messages)
    }

    @Test
    fun `an env-level targets_yml is an error and every dev flow needs its own`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/workflows-config.yml", "env: us-dev\ntargets: []\n")
        val findings = lint().filter { it.check == 11 || it.check == 3 }
        val messages = findings.text()
        assertTrue(messages.contains("config/us-dev/workflows-config.yml: moved to config/us-dev/<flow>/workflows-config.yml"), messages)
        assertTrue(messages.contains("config/us-dev/cash/workflows-config.yml: required in every flow of a *-dev env"), messages)
        assertTrue(findings.all { it.severity == Severity.ERROR }, messages)
    }

    @Test
    fun `the old targets_yml name in a flow directory is reported as renamed`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/targets.yml", "env: us-dev\nflow: cash\ntargets: []\n")
        val messages = lint().filter { it.check == 11 || it.check == 3 }.text()
        assertTrue(messages.contains("config/us-dev/cash/targets.yml: renamed: the flow's deploy inventory is workflows-config.yml"), messages)
        assertTrue(messages.contains("config/us-dev/cash/workflows-config.yml: required in every flow of a *-dev env"), messages)
    }

    @Test
    fun `a failing render is an error and a missing compose CLI only a warning`() {
        validInstance("local", "trades-db-to-amps")
        val failed = lint { CommandResult(1, "services.app.image: invalid reference") }
        assertTrue(failed.any { it.check == 6 && it.severity == Severity.ERROR }, failed.text())
        val skipped = lint { null }
        assertTrue(skipped.any { it.check == 6 && it.severity == Severity.WARN }, skipped.text())
    }

    @Test
    fun `checks 7 and 8 are reported as TODO`() {
        validInstance("local", "trades-db-to-amps")
        val todo = ConfigLinter(config, setOf("source-database"), everyEnv, completeEnvs = emptySet()).lint()
            .filter { it.severity == Severity.TODO }
        assertEquals(listOf(7, 8), todo.map { it.check })
    }

    // --- ADR-0011, ADR-0012: layer files, env layers, the compose file chain ---------------------------------

    @Test
    fun `the env layers merge flow, app, instance into the env file check 6 renders with, after the whole -f chain`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/_docker-compose.flow.env", "IMAGE_REPO=ghcr.io/o/flow\nTZ=UTC\nJAVA_OPTS=-Xflow\n")
        write("local/cash/source-database/_docker-compose.app.env", "JAVA_OPTS=-Xapp\nMEM_LIMIT=1g\n")
        write("local/cash/_docker-compose.flow.yml", "services:\n  app:\n    mem_limit: \${MEM_LIMIT:-1g}\n")
        write("local/cash/source-database/trades-db-to-amps/_docker-compose.instance.yml", "services:\n  app:\n    cpus: 1\n")
        write("local/cash/application.flow.yml", "a: 1\n")
        var combined = ""
        val requests = mutableListOf<ComposeRenderRequest>()
        val findings = lint { request -> requests += request; combined = request.envFile.readText(); CommandResult(0, "") }
        assertEquals(emptyList<Finding>(), findings.filter { it.severity == Severity.ERROR }, findings.text())
        val vars = combined.lines().filter { it.isNotBlank() }.associate { it.substringBefore('=') to it.substringAfter('=') }
        // The instance layer wins per key (composeEnv sets IMAGE_REPO and JAVA_OPTS), the lower layers fill the rest.
        assertEquals("ghcr.io/o/github-cicd-simple-apps", vars["IMAGE_REPO"])
        assertEquals("-XX:MaxRAMPercentage=60", vars["JAVA_OPTS"])
        assertEquals("1g", vars["MEM_LIMIT"])
        assertEquals(listOf(template, appOverride, File(config, "local/cash/_docker-compose.flow.yml"),
            File(config, "local/cash/source-database/trades-db-to-amps/_docker-compose.instance.yml")), requests.single().composeFiles)
        assertEquals(File(config, "local/cash/application.flow.yml").absolutePath, requests.single().environment["FLOW_APP_YML"])
    }

    @Test
    fun `check 5 keeps the image tag, the identity and the ports in the instance layer`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/_docker-compose.flow.env", "IMAGE_TAG=main\nACTUATOR_HOST_PORT=18080\nTZ=UTC\n")
        write("local/cash/source-database/_docker-compose.app.env", "APP_INSTANCE=shared\nPROJECT=x\nJAVA_OPTS=-Xapp\n")
        val messages = lint().filter { it.check == 5 }.text()
        for (expected in listOf(
            "local/cash/_docker-compose.flow.env: IMAGE_TAG belongs in the instance layer only",
            "local/cash/_docker-compose.flow.env: ACTUATOR_HOST_PORT belongs in the instance layer only",
            "local/cash/source-database/_docker-compose.app.env: APP_INSTANCE belongs in the instance layer only",
            "local/cash/source-database/_docker-compose.app.env: PROJECT is set by run-compose.sh",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        assertFalse(messages.contains("TZ"), messages)
        assertFalse(messages.contains("JAVA_OPTS"), messages)
    }

    @Test
    fun `IMAGE_REPO may come from any layer but must come from one`() {
        validInstance("local", "trades-db-to-amps")
        val env = File(config, "local/cash/source-database/trades-db-to-amps/_docker-compose.instance.env")
        env.writeText(env.readText().lines().filterNot { it.startsWith("IMAGE_REPO=") }.joinToString("\n"))
        assertTrue(lint().text().contains("IMAGE_REPO missing in every env layer of the instance"), lint().text())
        write("local/cash/_docker-compose.flow.env", "IMAGE_REPO=ghcr.io/o/github-cicd-simple-apps\n")
        assertFalse(lint().text().contains("IMAGE_REPO missing"), lint().text())
    }

    @Test
    fun `layer files belong to the directory of their level, and the layout before ADR-0011 is named`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/source-database/application.instance.yml", "a: 1\n")
        write("local/cash/application.app.yml", "a: 1\n")
        write("local/cash/source-database/trades-db-to-amps/compose.env", "IMAGE_TAG=local\n")
        write("local/cash/source-database/trades-db-to-amps/values.yaml", "a: 1\n")
        write("local/cash/source-database/app-common/application.yml", "a: 1\n")
        write("local/cash/source-database/trades-db-to-amps/_docker/x.yml", "a: 1\n")
        write("local/cash/source-database/notes.txt", "x\n")
        write("local/cash/source-database/trades-db-to-amps/extra.env", "A=1\n")
        val messages = lint().text()
        for (expected in listOf(
            "local/cash/source-database/application.instance.yml: a instance-layer file in the app level's directory: it " +
                "belongs in config/<env>/<flow>/<AppName>/<AppInstance>/",
            "local/cash/application.app.yml: a app-layer file in the flow level's directory: it belongs in config/<env>/<flow>/<AppName>/",
            "trades-db-to-amps/compose.env: the layout before ADR-0011: rename it to _docker-compose.instance.env",
            "trades-db-to-amps/values.yaml: the layout before ADR-0011: rename it to _helm-values.instance.yaml",
            "local/cash/source-database/app-common: the app layer is files now",
            "trades-db-to-amps/_docker: layer directories are flat",
            "local/cash/source-database/notes.txt: unexpected file in the app level's directory",
            "trades-db-to-amps/extra.env: forbidden: the only env file of this level is _docker-compose.instance.env",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
    }

    @Test
    fun `LOGS_DIR and DATA_DIR are host paths, and every instance renders with its own directories (ADR-0018)`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ndefaults: { kind: compose, host: h }\ntargets:\n" +
            "  - instance: source-database/trades-db-to-amps\n  - instance: source-database/positions-db-to-deephaven\n")
        write("us-dev/cash/_docker-compose.flow.env", "LOGS_DIR=/logs/deploy/p/logs/\nDATA_DIR=/logs/deploy/p/data\n")
        val requests = mutableListOf<ComposeRenderRequest>()
        val findings = lint { request -> requests += request; CommandResult(0, "") }
        assertEquals(emptyList<Finding>(), findings, findings.text())
        val dirs = requests.associate { it.environment["APP_INSTANCE"] to (it.environment["INSTANCE_LOGS_DIR"] to it.environment["INSTANCE_DATA_DIR"]) }
        assertEquals(mapOf(
            "trades-db-to-amps" to ("/logs/deploy/p/logs/source-database/trades-db-to-amps" to
                "/logs/deploy/p/data/source-database/trades-db-to-amps"),
            "positions-db-to-deephaven" to ("/logs/deploy/p/logs/source-database/positions-db-to-deephaven" to
                "/logs/deploy/p/data/source-database/positions-db-to-deephaven"),
        ), dirs)

        write("us-dev/cash/_docker-compose.flow.env", "LOGS_DIR=logs\nDATA_DIR=/logs/../etc\n")
        write("us-dev/cash/source-database/_docker-compose.app.env", "INSTANCE_LOGS_DIR=/x\n")
        val messages = lint().filter { it.check == 5 }.text()
        assertTrue(messages.contains("LOGS_DIR=logs must be an absolute host path (ADR-0018)"), messages)
        assertTrue(messages.contains("DATA_DIR=/logs/../etc must be an absolute host path"), messages)
        assertTrue(messages.contains("INSTANCE_LOGS_DIR is set by run-compose.sh"), messages)
    }

    @Test
    fun `check 6 rejects relative paths in compose overrides, which resolve against docker`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/source-database/_docker-compose.app.yml", "services:\n  app:\n    volumes:\n      - ./certs:/certs:ro\n" +
            "      - \${CERTS_DIR:-/etc/certs}:/more:ro\n")
        appOverride.writeText("services:\n  app:\n    env_file:\n      - ../secrets.env\n")
        val findings = lint().filter { it.check == 6 }
        val messages = findings.text()
        assertEquals(2, findings.size, messages)
        assertTrue(messages.contains("source-database/_docker-compose.app.yml: './certs:/certs:ro' is a relative path"), messages)
        assertTrue(messages.contains("docker-compose.override.yml: '../secrets.env' is a relative path"), messages)
    }

    // --- ADR-0019: Helm values (checks 3, 4, 10) and helm (check 12) --------------------------------------

    @Test
    fun `check 3 requires the Helm values of the app and of every instance`() {
        validInstance("local", "trades-db-to-amps")
        File(config, "local/cash/source-database/_helm-values.app.yaml").delete()
        File(config, "local/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml").delete()
        val findings = lint().filter { it.check == 3 }
        val messages = findings.text()
        assertEquals(2, findings.size, messages)
        assertTrue(messages.contains("source-database/_helm-values.app.yaml: required file missing (Helm values layer 2"), messages)
        assertTrue(messages.contains("trades-db-to-amps/_helm-values.instance.yaml: required file missing (Helm values layer 3"), messages)
        assertTrue(helmRequests.isEmpty(), "no helm run without the values layers: $helmRequests")
    }

    @Test
    fun `check 4 compares identity, APP variables and image_tag with the path and the instance env layer`() {
        validInstance("us-dev", "trades-db-to-amps", tag = "0.1.0-rc.39")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ntargets:\n  - instance: source-database/trades-db-to-amps\n" +
            "    kind: compose\n    host: h\n")
        write("us-dev/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml",
            "image:\n  tag: \"0.1.0-rc.38\"\nidentity:\n  env: us-dev\n  flow: cash\n  app: source-database\n" +
                "  instance: positions-db-to-deephaven\nenv:\n  APP_ENV: us-dev\n  APP_FLOW: swap\n  APP_NAME: source-database\n" +
                "  JAVA_OPTS: \"-XX:MaxRAMPercentage=75\"\n  SPRING_DATASOURCE_PASSWORD: x\n  MEM_LIMIT: 1g\n  IMAGE_TAG: x\n")
        write("us-dev/cash/source-database/_helm-values.app.yaml",
            "image:\n  tag: \"0.1.0\"\nenv:\n  TZ: UTC\n  APP_INSTANCE: shared\n  ACTUATOR_HOST_PORT: \"18081\"\n")
        val findings = lint()
        val messages = findings.text()
        for (expected in listOf(
            "identity.instance=positions-db-to-deephaven does not match the directory path (trades-db-to-amps)",
            "env.APP_FLOW=swap does not match the directory path (cash)",
            "env.APP_INSTANCE=shared does not match the directory path (trades-db-to-amps)",
            "image.tag '0.1.0-rc.38' differs from IMAGE_TAG '0.1.0-rc.39' in _docker-compose.instance.env",
            "env.SPRING_DATASOURCE_PASSWORD is forbidden",
            "env.MEM_LIMIT is not an app-facing variable",
            "env.IMAGE_TAG is not an app-facing variable",
            "env.ACTUATOR_HOST_PORT is not an app-facing variable",
            "_helm-values.app.yaml: image.tag belongs in <AppInstance>/_helm-values.instance.yaml",
            "_helm-values.app.yaml: env.APP_INSTANCE belongs in <AppInstance>/_helm-values.instance.yaml",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        val divergent = findings.single { it.severity == Severity.WARN && it.check == 4 }
        assertTrue(divergent.message.contains("env.JAVA_OPTS=-XX:MaxRAMPercentage=75 differs from JAVA_OPTS=-XX:MaxRAMPercentage=60"),
            divergent.toString())
    }

    @Test
    fun `check 4 requires the identity map and every APP variable`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml", "image:\n  tag: \"local\"\nenv:\n  TZ: UTC\n")
        val messages = lint().filter { it.check == 4 }.text()
        assertTrue(messages.contains("identity missing: must restate the directory path"), messages)
        for (key in ConfigRules.IDENTITY) assertTrue(messages.contains("env.$key missing"), messages)
        assertTrue(messages.contains("JAVA_OPTS is set in the compose env layers (-XX:MaxRAMPercentage=60) but not in the values env"), messages)
    }

    @Test
    fun `check 10 applies the tag policy to image_tag`() {
        validInstance("us-prod", "trades-db-to-amps", tag = "1.4.2")
        validInstance("us-prod", "positions-db-to-deephaven", tag = "1.4.2")
        validInstance("local", "trades-db-to-amps", tag = "1.0")
        write("us-prod/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml",
            instanceValues("us-prod", "trades-db-to-amps", "1.4").replace("image:\n", "image:\n  digest: sha256:abc\n"))
        write("local/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml",
            instanceValues("local", "trades-db-to-amps").replace("tag: \"local\"", "tag: 1.0"))
        val findings = lint().filter { it.check == 10 }
        val messages = findings.text()
        assertTrue(messages.contains("image.tag '1.4' in us-prod must be an immutable release tag"), messages)
        assertTrue(messages.contains("image.digest 'sha256:abc' must be sha256:<64 hex digits>"), messages)
        assertTrue(messages.contains("image.tag must be a string: quote it (\"1.0\")"), messages)
        assertFalse(messages.contains("positions-db-to-deephaven"), "1.4.2 is a release tag: $messages")
    }

    @Test
    fun `check 12 lints and renders every instance through the deploy script, then runs kubeconform`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven", tag = "0.1.0-rc.39")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ntargets:\n  - instance: source-database/positions-db-to-deephaven\n" +
            "    kind: helm\n    cluster: kind-ci\n    namespace: \"{flow}\"\n")
        val validated = mutableListOf<File>()
        val findings = linter(validator = { file -> validated += file; CommandResult(0, kubeconform(valid = 5)) }).lint()
            .filter { it.severity != Severity.TODO }
        assertEquals(emptyList<Finding>(), findings)
        assertEquals(
            listOf("local/trades-db-to-amps/local/LINT", "local/trades-db-to-amps/local/TEMPLATE",
                "us-dev/positions-db-to-deephaven/0.1.0-rc.39/LINT", "us-dev/positions-db-to-deephaven/0.1.0-rc.39/TEMPLATE"),
            helmRequests.map { "${it.env}/${it.instance}/${it.tag}/${it.mode}" })
        assertTrue(helmRequests.all { it.chart == chart && it.flow == "cash" && it.app == "source-database" })
        assertEquals(listOf(null, File(rendered, "local/cash/source-database/trades-db-to-amps.yaml")),
            helmRequests.take(2).map { it.renderOut })
        assertEquals(helmRequests.mapNotNull { it.renderOut }, validated)
    }

    @Test
    fun `check 12 failures are errors, and a missing or old Helm is reported once`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("local", "positions-db-to-deephaven")
        val lintFails = linter(helm = { r -> CommandResult(if (r.mode == HelmMode.LINT) 1 else 0, "[ERROR] _helm-values.instance.yaml: - at '/env/SPRING_X': false schema") })
            .lint().filter { it.check == 12 }
        assertEquals(2, lintFails.size, lintFails.text())
        assertTrue(lintFails.all { it.severity == Severity.ERROR && it.message.contains("helm lint failed") }, lintFails.text())
        assertTrue(lintFails[0].message.contains("false schema"), lintFails.text())

        val templateFails = linter(helm = { r -> CommandResult(if (r.mode == HelmMode.TEMPLATE) 1 else 0, "Error: execution error: env.APP_ENV") })
            .lint().filter { it.check == 12 }
        assertTrue(templateFails.all { it.severity == Severity.ERROR && it.message.contains("helm template failed") }, templateFails.text())

        val oldHelm = CommandResult(5, "helm-deploy-instance: error: Helm v3.19.0 found: this script needs Helm 4")
        val warned = linter(helm = { oldHelm }).lint().filter { it.check == 12 }
        assertEquals(1, warned.size, warned.text())
        assertEquals(Severity.WARN, warned[0].severity)
        assertTrue(warned[0].message.contains("Helm v3.19.0 found"), warned.text())
        val required = linter(helm = { oldHelm }, requireRender = true).lint().filter { it.check == 12 }
        assertEquals(listOf(Severity.ERROR), required.map { it.severity })
        val off = linter(helm = null).lint().filter { it.check == 12 }
        assertEquals(1, off.size, off.text())
        assertTrue(off[0].message.contains("-PconfigLint.helm=none"), off.text())
    }

    @Test
    fun `check 12 reports kubeconform rejections, vacuous passes and its absence`() {
        validInstance("local", "trades-db-to-amps")
        val rejected = linter(validator = {
            CommandResult(1, kubeconform(valid = 4, resources = "{\"filename\": \"x.yaml\", \"kind\": \"Deployment\", \"name\": " +
                "\"source-database-trades-db-to-amps\", \"version\": \"apps/v1\", \"status\": \"statusInvalid\", \"msg\": \"\", " +
                "\"validationErrors\": [{\"path\": \"/spec/replicas\", \"msg\": \"expected integer\"}]}"))
        }).lint().filter { it.check == 12 }
        assertEquals(Severity.ERROR, rejected.single().severity)
        assertTrue(rejected.single().message.contains("Deployment source-database-trades-db-to-amps: statusInvalid /spec/replicas: expected integer"),
            rejected.text())

        val vacuous = linter(validator = { CommandResult(0, kubeconform(valid = 0, skipped = 5)) }).lint().filter { it.check == 12 }
        assertEquals(Severity.WARN, vacuous.single().severity)
        assertTrue(vacuous.single().message.contains("kubeconform validated no resource"), vacuous.text())

        val absent = linter(validator = null).lint().filter { it.check == 12 }
        assertEquals(Severity.WARN, absent.single().severity)
        assertTrue(absent.single().message.contains("kubeconform not available: 1 rendered instance(s)"), absent.text())
    }

    @Test
    fun `check 12 needs a chart per app, an error only in complete envs`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ntargets:\n  - instance: source-database/trades-db-to-amps\n" +
            "    kind: compose\n    host: h\n")
        val findings = linter(charts = emptyMap(), completeEnvs = setOf("local")).lint().filter { it.check == 12 }
        assertEquals(listOf("ERROR config/local/cash/source-database", "WARN config/us-dev/cash/source-database"),
            findings.map { "${it.severity} ${it.path}" }, findings.text())
        assertTrue(findings.all { it.message.contains("expected <subproject>/helm/source-database/Chart.yaml") })
        assertTrue(helmRequests.isEmpty(), "nothing to render without a chart: $helmRequests")
    }

    // --- ADR-0036: the Helm checks run only when platform.yml kinds includes helm ---------------------------------------

    private val composeOnly = everyEnv.copy(kinds = setOf("compose"))

    /** An instance as a repository without Helm holds it: no `_helm-values.*.yaml`. */
    private fun composeInstance(env: String, instance: String, tag: String = "local") {
        validInstance(env, instance, tag)
        File(config, "$env/cash/source-database/_helm-values.app.yaml").delete()
        File(config, "$env/cash/source-database/$instance/_helm-values.instance.yaml").delete()
    }

    private fun composeTarget(env: String, instance: String) = write("$env/cash/workflows-config.yml",
        "env: $env\nflow: cash\ntargets:\n  - instance: source-database/$instance\n    kind: compose\n    host: h\n")

    @Test
    fun `without helm in kinds no chart and no Helm values are required, and nothing is rendered with Helm`() {
        composeInstance("local", "trades-db-to-amps")
        composeInstance("us-dev", "trades-db-to-amps")
        composeTarget("us-dev", "trades-db-to-amps")
        val composeOk = ComposeRenderer { CommandResult(0, "") }
        // CI: requireRender, no Helm, no chart.
        val findings = linter(renderer = composeOk, helm = null, charts = emptyMap(), completeEnvs = setOf("local"),
            requireRender = true, scope = composeOnly).lint().filter { it.severity != Severity.TODO }
        assertEquals(emptyList<Finding>(), findings, findings.text())
        // A chart and Helm on the PATH change nothing: check 12 renders no instance.
        val withChart = linter(renderer = composeOk, completeEnvs = setOf("local"), scope = composeOnly).lint()
            .filter { it.severity != Severity.TODO }
        assertEquals(emptyList<Finding>(), withChart, withChart.text())
        assertTrue(helmRequests.isEmpty(), "no helm run without helm in kinds: $helmRequests")
        // With helm in kinds the same tree fails: the chart (check 12) and both values files (check 3).
        val helm = linter(renderer = composeOk, charts = emptyMap(), completeEnvs = setOf("local")).lint()
            .filter { it.severity == Severity.ERROR }
        assertEquals(listOf(3, 3, 3, 3, 12), helm.map { it.check }.sorted(), helm.text())
        assertTrue(helm.text().contains("local/cash/source-database: no Helm chart for 'source-database'"), helm.text())
    }

    @Test
    fun `without helm in kinds a Helm values file that exists is still checked, so a stale image_tag fails check 4`() {
        composeInstance("us-dev", "trades-db-to-amps", tag = "0.1.0-rc.39")
        composeTarget("us-dev", "trades-db-to-amps")
        write("us-dev/cash/source-database/trades-db-to-amps/_helm-values.instance.yaml",
            instanceValues("us-dev", "trades-db-to-amps", tag = "0.1.0-rc.38"))
        val errors = linter(charts = emptyMap(), scope = composeOnly).lint().filter { it.severity == Severity.ERROR }
        assertEquals(listOf(4), errors.map { it.check }, errors.text())
        assertTrue(errors.single().message.contains("image.tag '0.1.0-rc.38' differs from IMAGE_TAG '0.1.0-rc.39' in " +
            "_docker-compose.instance.env"), errors.text())
        assertTrue(helmRequests.isEmpty(), "checked, never rendered: $helmRequests")
    }

    // --- host pools (ADR-0028): check 11 on config/<env>/<flow>/workflows-config.yml ------------------------------------

    private fun flowTargets(pool: String, targets: String, flow: String = "cash") =
        "env: us-dev\nflow: $flow\n$pool\ntargets:\n$targets"
    private val cashPool = "pool:\n  hosts: [dev-cash-01.example.com, dev-cash-02.example.com]\n"

    @Test
    fun `check 11 accepts a pool whose compose targets have no host or one of its boxes`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", flowTargets(
            "pool:\n  hosts:\n    - dev-cash-01.example.com\n    - 10.0.0.2\n  user: deploy\n  keep: 3\n" +
                "defaults:\n  kind: compose\n  cluster: kind-ci",
            "  - instance: source-database/trades-db-to-amps\n" +
                "  - instance: source-database/positions-db-to-deephaven\n    host: 10.0.0.2\n"))
        write("us-dev/known_hosts", "# pinned host keys\ndev-cash-01.example.com,10.0.0.2 ssh-ed25519 " +
            "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n")
        val findings = lint()
        assertEquals(emptyList<Finding>(), findings.filter { it.check == 1 || it.check == 3 || it.check == 11 }, findings.text())
    }

    @Test
    fun `check 11 rejects a host that is not a box of the flow's pool`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", flowTargets(cashPool,
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n    host: dev-other-01.example.com\n"))
        val findings = lint().filter { it.check == 11 && it.severity == Severity.ERROR }
        assertEquals(1, findings.size, findings.text())
        assertEquals(Severity.ERROR, findings[0].severity)
        assertTrue(findings[0].message.contains("host 'dev-other-01.example.com' is not a box of the pool " +
            "(dev-cash-01.example.com, dev-cash-02.example.com)"), findings.text())
    }

    @Test
    fun `check 11 rejects bad host names, users, keeps and the gone root in a pool`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", flowTargets(
            "pool:\n  hosts: [Dev_Cash_01.example.com, dev-cash-02.example.com., 42]\n  user: Root!\n  root: /opt/platform\n  keep: 1\n" +
                "  port: 22",
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n"))
        val messages = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        for (expected in listOf(
            "pool.hosts[0]: 'Dev_Cash_01.example.com' is not a lower-case DNS name or IPv4 address",
            "pool.hosts[1]: 'dev-cash-02.example.com.' is not a lower-case DNS name or IPv4 address",
            "pool.hosts[2]: '42' is not a lower-case DNS name or IPv4 address",
            "pool.user 'Root!' is not a valid login name",
            "pool.root is gone (ADR-0018): every box holds the project's versions under /apps/<user>/versions/<project>/",
            "pool.keep '1' must be an integer of at least 2",
            "pool: unknown key 'port'",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        write("us-dev/cash/workflows-config.yml", flowTargets("pool:\n  hosts: []\n  keep: five",
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n"))
        val empty = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        assertTrue(empty.contains("pool.hosts must be a non-empty list"), empty)
        assertTrue(empty.contains("pool.keep 'five' must be an integer of at least 2"), empty)
    }

    @Test
    fun `check 11 rejects a box listed twice, or shared by two flows (a box serves one env and flow)`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", flowTargets(
            "pool:\n  hosts: [dev-01.example.com, dev-02.example.com, dev-01.example.com]",
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n"))
        write("us-dev/swap/workflows-config.yml", flowTargets("pool:\n  hosts: [dev-02.example.com, dev-03.example.com]",
            "", flow = "swap").replace("targets:\n", "targets: []\n"))
        write("us-dev/deriv/workflows-config.yml", flowTargets("pool:\n  hosts: [dev-03.example.com]",
            "", flow = "deriv").replace("targets:\n", "targets: []\n"))
        val findings = lint().filter { it.check == 11 && it.severity == Severity.ERROR }
        val messages = findings.text()
        assertTrue(messages.contains("cash/workflows-config.yml: pool.hosts[2]: dev-01.example.com is listed twice"), messages)
        assertTrue(messages.contains("swap/workflows-config.yml: pool.hosts: dev-02.example.com is also a box of flow 'cash': " +
            "a box serves exactly one <env>/<flow> (ADR-0018)"), messages)
        assertTrue(messages.contains("pool.hosts: dev-03.example.com is also a box of flow"), messages)
        assertEquals(3, findings.size, "dev-03 serves deriv and swap, which is no longer allowed (ADR-0018):\n$messages")
    }

    @Test
    fun `check 11 needs a host or a pool for every compose target`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", "env: us-dev\nflow: cash\ndefaults:\n  kind: compose\ntargets:\n" +
            "  - instance: source-database/trades-db-to-amps\n" +
            "  - instance: source-database/positions-db-to-deephaven\n    host: Not_A_Host\n")
        val messages = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        assertTrue(messages.contains("targets[0]: kind compose needs host, or a pool in this file"), messages)
        assertTrue(messages.contains("targets[1]: host 'Not_A_Host' is not a lower-case DNS name or IPv4 address"), messages)
    }

    @Test
    fun `check 11 warns about a pool without compose targets and checks namespaces and known_hosts`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/cash/workflows-config.yml", flowTargets(cashPool + "defaults:\n  kind: helm\n  cluster: kind-ci",
            "  - instance: source-database/trades-db-to-amps\n" +
                "  - instance: source-database/positions-db-to-deephaven\n    namespace: Cash_NS\n"))
        write("us-dev/known_hosts", "dev-cash-01.example.com ssh-ed25519\n")
        val findings = lint().filter { it.check == 11 }
        val warning = findings.single { it.severity == Severity.WARN }
        assertTrue(warning.message.contains("pool: flow 'cash' has no compose target"), findings.text())
        val errors = findings.filter { it.severity == Severity.ERROR }.map { "${it.path}: ${it.message}" }
        assertEquals(4, errors.size, findings.text())
        assertTrue(errors.any { it.contains("targets[1]: namespace 'Cash_NS' is not a DNS label") }, findings.text())
        assertTrue(errors.any { it.contains("known_hosts: line 1: expected") }, findings.text())
        // A malformed line pins nothing.
        assertTrue(errors.any { it.contains("box dev-cash-01.example.com of flow 'cash' has no line") }, findings.text())
        assertTrue(errors.any { it.contains("box dev-cash-02.example.com of flow 'cash' has no line") }, findings.text())
    }

    // --- pinned host keys (ADR-0028): every box of a pool has a line in config/<env>/known_hosts ---------------------

    private val hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

    private fun pinnedBoxErrors(knownHosts: String?): List<String> {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/cash/workflows-config.yml", flowTargets(cashPool,
            "  - instance: source-database/trades-db-to-amps\n    kind: compose\n"))
        val file = File(config, "us-dev/known_hosts")
        if (knownHosts == null) file.delete() else write("us-dev/known_hosts", knownHosts)
        return lint().filter { it.check == 11 && it.severity == Severity.ERROR }.map { it.message }
    }

    @Test
    fun `check 11 requires a pinned host key for every box of a pool`() {
        assertEquals(emptyList<String>(), pinnedBoxErrors(
            "# the reviewed ssh-keyscan lines\ndev-cash-01.example.com,10.0.0.1 $hostKey\ndev-cash-02.example.com $hostKey\n"))
        val missing = pinnedBoxErrors("dev-cash-01.example.com $hostKey\n")
        assertEquals(1, missing.size, missing.joinToString("\n"))
        assertTrue(missing.single().contains("box dev-cash-02.example.com of flow 'cash' has no line: the ssh transport"), missing.single())
        // A revoked key pins nothing; a hashed name cannot be reviewed.
        val revoked = pinnedBoxErrors("dev-cash-01.example.com $hostKey\n@revoked dev-cash-02.example.com $hostKey\n")
        assertTrue(revoked.single().contains("box dev-cash-02.example.com"), revoked.joinToString("\n"))
        val hashed = pinnedBoxErrors("dev-cash-01.example.com $hostKey\n|1|c2FsdA==|aGFzaA== $hostKey\n")
        assertTrue(hashed.any { it.contains("line 2: a hashed host name (ssh-keyscan -H) cannot be reviewed") }, hashed.joinToString("\n"))
        assertTrue(hashed.any { it.contains("box dev-cash-02.example.com") }, hashed.joinToString("\n"))
        val marker = pinnedBoxErrors("@trusted dev-cash-01.example.com $hostKey\n")
        assertTrue(marker.any { it.contains("line 1: unknown marker '@trusted'") }, marker.joinToString("\n"))
    }

    @Test
    fun `check 11 lets a cert-authority line cover the boxes its patterns match`() {
        assertEquals(emptyList<String>(), pinnedBoxErrors("@cert-authority *.example.com $hostKey\n"))
        val excluded = pinnedBoxErrors("@cert-authority *.example.com,!dev-cash-02.example.com $hostKey\n")
        assertTrue(excluded.single().contains("box dev-cash-02.example.com"), excluded.joinToString("\n"))
        val narrow = pinnedBoxErrors("@cert-authority dev-cash-0?.example.com $hostKey\n")
        assertEquals(emptyList<String>(), narrow)
    }

    @Test
    fun `check 11 warns, and does not fail, while the pool's env has no known_hosts`() {
        assertEquals(emptyList<String>(), pinnedBoxErrors(null))
        val warning = lint().single { it.check == 11 && it.severity == Severity.WARN }
        assertEquals("config/us-dev/known_hosts", warning.path)
        assertTrue(warning.message.contains("missing: the boxes of flow 'cash' have no pinned host key"), warning.message)
    }

    @Test
    fun `host patterns match as OpenSSH matches them`() {
        assertTrue(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "DEV-CASH-01.Example.com"))
        assertTrue(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "other.example.com,dev-cash-0?.example.com"))
        assertTrue(ConfigRules.matchesHostPatterns("10.0.0.2", "10.0.0.*"))
        assertTrue(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "[dev-cash-01.example.com]:22"))
        assertFalse(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "[dev-cash-01.example.com]:2222"))
        assertFalse(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "*.example.com,!dev-cash-01.example.com"))
        assertFalse(ConfigRules.matchesHostPatterns("dev-cash-01.example.com", "dev-cash-01"))
        assertFalse(ConfigRules.matchesHostPatterns("dev-cash-01xexample.com", "dev-cash-01.example.com"))
    }
}
