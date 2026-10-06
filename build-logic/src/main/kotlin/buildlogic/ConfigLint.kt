package buildlogic

import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.File

/**
 * config-lint (ADR-0014): checks 1–6 and 9–12 over the config tree; 7 and 8 are reported as TODO.
 * Pure over the file system plus the optional [ComposeRenderer], [HelmRunner] and [ManifestValidator], so that
 * it is unit-tested.
 */
enum class Severity { ERROR, WARN, TODO }

data class Finding(val check: Int, val severity: Severity, val path: String, val message: String) {
    override fun toString(): String = "${severity.name.padEnd(5)} check ${check.toString().padStart(2)}  $path: $message"
}

/**
 * One `docker compose config` run (check 6): the compose files in merge order (the shared template first, ADR-0012) and
 * the instance's combined env, as run-compose.sh passes them.
 */
data class ComposeRenderRequest(
    val composeFiles: List<File>,
    val envFile: File,
    val project: String,
    val environment: Map<String, String>,
)

fun interface ComposeRenderer {
    /** Renders and validates; `null` when no compose CLI is available. */
    fun render(request: ComposeRenderRequest): CommandResult?
}

/** The two check-12 modes of `scripts/helm-deploy-instance.sh` (ADR-0019). */
enum class HelmMode(val flag: String) { LINT("lint"), TEMPLATE("template") }

/** One `scripts/helm-deploy-instance.sh <env> <flow> <app> <instance> --tag <tag> --mode lint|template` run. */
data class HelmRequest(
    val env: String,
    val flow: String,
    val app: String,
    val instance: String,
    val tag: String,
    val chart: File,
    val mode: HelmMode,
    /** [HelmMode.TEMPLATE] only: the file the manifests are rendered to (`--render-out`). */
    val renderOut: File? = null,
)

fun interface HelmRunner {
    /** Runs the deploy script; `null` when Helm is switched off (`-PconfigLint.helm=none`). Exit 5: no usable Helm 4. */
    fun run(request: HelmRequest): CommandResult?
}

fun interface ManifestValidator {
    /** kubeconform over rendered manifests (JSON output with summary); `null` when kubeconform is not available. */
    fun validate(rendered: File): CommandResult?
}

/**
 * What config-lint checks names and envs against: the identity vocabulary and the runtimes of platform.yml
 * (ADR-0003, ADR-0030), and the envs the checked tree may hold (ADR-0004).
 */
data class LintScope(
    val regions: Set<String>,
    val stages: Set<String>,
    val flows: Set<String>,
    val kinds: Set<String>,
    /** The envs the tree may hold besides `local` (platform.yml `dev_envs`); null: every env of the vocabulary. */
    val envs: Set<String>?,
) {
    /** `local`, or `<region>-<stage>` with a region and a stage of the vocabulary. */
    fun isEnv(env: String): Boolean =
        env == LOCAL || (env.substringBefore('-', "") in regions && env.substringAfter('-', "") in stages)

    /** Every stage but dev is promoted, so its tags are immutable (ADR-0004, ADR-0010). */
    fun isPromoted(env: String): Boolean = env != LOCAL && env.substringAfter('-', "") != DEV_STAGE

    /** Helm is a runtime of the project (`kinds` includes `helm`): only then do the Helm checks run (ADR-0036). */
    val helmEnabled: Boolean get() = HELM in kinds

    companion object {
        const val LOCAL = "local"
        const val DEV_STAGE = "dev"
        const val HELM = "helm"
    }
}

object ConfigRules {
    val TOKEN = Regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
    const val MAX_APP_NAME = 20
    const val MAX_APP_INSTANCE = 32
    const val MAX_RELEASE_NAME = 53
    /** The layer directories before ADR-0011, reported with the file names that replace them. */
    const val APP_COMMON = "app-common"
    const val COMMON = "_common"

    /** ADR-0011: the layers are files, named `<kind>.<layer>.<ext>` and allowed only in the directory of their level. */
    enum class Layer(val id: String) { FLOW("flow"), APP("app"), INSTANCE("instance") }
    fun application(layer: Layer) = "application.${layer.id}.yml"
    fun composeEnv(layer: Layer) = "_docker-compose.${layer.id}.env"
    fun composeOverride(layer: Layer) = "_docker-compose.${layer.id}.yml"
    fun helmValues(layer: Layer) = "_helm-values.${layer.id}.yaml"
    fun layerFiles(layer: Layer): Set<String> = when (layer) {
        Layer.FLOW -> setOf(application(layer), composeEnv(layer), composeOverride(layer))
        else -> setOf(application(layer), composeEnv(layer), composeOverride(layer), helmValues(layer))
    }
    /** A layer file of any level: a misplaced one is reported with the directory it belongs in. */
    val LAYER_FILE = Regex("""^(application|_docker-compose|_helm-values)\.(flow|app|instance)\.(yml|yaml|env)$""")
    const val TARGETS = "workflows-config.yml"

    /** ADR-0012: the only variables an env layer may carry (plus `*_HOST_PORT`). */
    val COMPOSE_ENV_ALLOWED = setOf(
        "IMAGE_REPO", "IMAGE_TAG", "APP_ENV", "APP_FLOW", "APP_NAME", "APP_INSTANCE",
        "JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT", "LOGS_DIR", "DATA_DIR", "MEM_LIMIT",
    )
    val HOST_PORT = Regex("^[A-Z][A-Z0-9_]*_HOST_PORT$")
    val FORBIDDEN_PREFIXES = listOf("SPRING_", "LOGGING_", "MANAGEMENT_", "CONNECTOR_")

    /** Variables `run-compose.sh` sets itself; no env layer may define them (ADR-0012). */
    val SCRIPT_VARIABLES = setOf("COMPOSE_ENV_FILE", "FLOW_APP_YML", "APP_APP_YML", "INSTANCE_APP_YML", "PROJECT",
        "INSTANCE_LOGS_DIR", "INSTANCE_DATA_DIR")
    /**
     * The env-layer variables that name the flow's host directories (ADR-0018); each instance mounts
     * `<dir>/<AppName>/<AppInstance>`, which `run-compose.sh` passes to the template as `INSTANCE_<name>`.
     */
    val HOST_DIRS = listOf("LOGS_DIR", "DATA_DIR")
    /** An absolute host path of plain segments: it is a bind-mount source and a `mkdir -p` argument. */
    val HOST_PATH = Regex("^(/[A-Za-z0-9._-]+)+/?$")
    val IDENTITY = listOf("APP_ENV", "APP_FLOW", "APP_NAME", "APP_INSTANCE")
    /** Only the instance layer sets these (and `*_HOST_PORT`): the image tag, the identity, the published ports. */
    val INSTANCE_ONLY = IDENTITY.toSet() + "IMAGE_TAG"

    /** ADR-0019: the app-facing subset — the only names a Helm values `env:` map may carry (check 4). */
    val VALUES_ENV_ALLOWED = IDENTITY.toSet() + setOf("JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT")
    /** Knobs both consumers set: the combined compose env and the values `env:` should agree (check 4 warns otherwise). */
    val SHARED_KNOBS = listOf("JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT")
    /** The script's exit code for "no usable Helm 4" (helm-deploy-instance.sh). */
    const val EXIT_TOOL = 5

    /** ADR-0013: secret properties; none of them may appear in any YAML layer. */
    val SECRET_PROPERTIES = listOf(
        "spring.datasource.username", "spring.datasource.password",
        "connector.amps.username", "connector.amps.password",
        "connector.kafka.sasl", "connector.deephaven.token", "connector.tls.keystore.password",
    )

    val DOCKER_TAG = Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
    val RELEASE_TAG = Regex("""^\d+\.\d+\.\d+(@sha256:[0-9a-f]{64})?$""")
    val DIGEST = Regex("^sha256:[0-9a-f]{64}$")
    /** What `helm-deploy-instance.sh --tag` accepts: a tag, optionally pinned by digest. */
    val TAG_REFERENCE = Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}(@sha256:[0-9a-f]{64})?$")
    /** The Kubernetes version the rendered manifests are validated against (kubeconform, check 12). */
    const val KUBERNETES_VERSION = "1.37.0"

    /** Check 11: a compose host, also every box of a flow's pool (ADR-0028) — a lower-case DNS name or an IPv4 address. */
    val HOST_NAME = Regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
    /** Check 11: the SSH user of a compose host or pool (ADR-0018: `deploy`, whose forced command is run-compose.sh). */
    val LOGIN = Regex("^[a-z_][a-z0-9_-]{0,31}$")
    /**
     * Check 11: a pool's install root — absolute, plain path segments only (it appears in rsync targets and SSH
     * command lines), never `.` or `..`.
     */
    const val POOL_USER = "deploy"
    /** ADR-0018: versions kept per box under `/apps/<user>/versions/<project>/`; `pool.keep` (default 5, at least 2). */
    const val POOL_KEEP_DEFAULT = 5
    const val POOL_KEEP_MIN = 2
    /** A helm target's namespace once "{flow}" is substituted: a DNS label (ADR-0027; the flow name by default). */
    val NAMESPACE = Regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
    /** `config/<env>/known_hosts`: `[@marker] <host patterns> <key type> <base64 key> [comment]` (ssh-keyscan format). */
    val SSH_KEY_TYPE = Regex("^(ssh|ecdsa|sk)-[A-Za-z0-9@._-]+$")
    val BASE64 = Regex("^[A-Za-z0-9+/]+={0,3}$")
    /** The markers of a known_hosts line: a CA whose signed host keys are trusted, or a revoked key. */
    val KNOWN_HOSTS_MARKERS = setOf("@cert-authority", "@revoked")
    private val HOST_WITH_PORT = Regex("^\\[(.+)]:([0-9]+)$")

    /**
     * Whether [host] matches the comma-separated host [patterns] of a known_hosts line, as OpenSSH matches them: `*` and
     * `?` wildcards, case-insensitive; a matching `!` pattern excludes the host; `[host]:port` names a port other than
     * 22, which the pools' SSH connections do not use.
     */
    fun matchesHostPatterns(host: String, patterns: String): Boolean {
        var matched = false
        for (raw in patterns.split(',')) {
            val negated = raw.startsWith("!")
            var pattern = raw.removePrefix("!").lowercase()
            val withPort = HOST_WITH_PORT.matchEntire(pattern)
            if (withPort != null) {
                if (withPort.groupValues[2] != "22") continue
                pattern = withPort.groupValues[1]
            }
            val regex = Regex(pattern.split('*').joinToString(".*") { part -> part.split('?').joinToString(".") { Regex.escape(it) } })
            if (regex.matches(host.lowercase())) {
                if (negated) return false
                matched = true
            }
        }
        return matched
    }

    val SECRET_VALUE_PATTERNS = listOf(
        Regex("-----BEGIN [A-Z ]*PRIVATE KEY-----") to "PEM private key",
        Regex("\\bAKIA[0-9A-Z]{16}\\b") to "AWS access key id",
        Regex("\\bgh[pousr]_[A-Za-z0-9]{36,}\\b") to "GitHub token",
        Regex("\\bxox[baprs]-[A-Za-z0-9-]{10,}") to "Slack token",
        Regex("(?i)\\b(password|passwd|pwd|secret|token|api[-_]?key)\\b\\s*[:=]\\s*['\"]?(?!\\$\\{)[^\\s'\"#]{4,}") to
            "literal value for a secret-looking key",
        Regex("(?i)jdbc:[^\\s]*;password=[^;\\s\${]+") to "password inside a JDBC URL",
    )

    fun normalise(key: String): String = key.lowercase().replace("-", "").replace("_", "")

    fun isSecretProperty(key: String): Boolean {
        val k = normalise(key)
        return SECRET_PROPERTIES.any { s -> val n = normalise(s); k == n || k.startsWith("$n.") }
    }
}

class ConfigLinter(
    private val configRoot: File,
    /** Deployable AppNames: the subprojects that apply `buildlogic.docker-image` (ADR-0006). */
    private val apps: Set<String>,
    /** The vocabulary, runtimes and envs of platform.yml the tree is checked against (ADR-0030). */
    private val scope: LintScope,
    /** The one compose template, `docker/docker-compose.yml` (ADR-0012); null: check 6 has nothing to render. */
    private val template: File? = null,
    /** AppName -> its `<subproject>/docker/docker-compose.override.yml`, for the apps that have one. */
    private val appOverrides: Map<String, File> = emptyMap(),
    /**
     * Envs in which every deployable app must have configuration (check 2, "vice versa") and, when Helm is a runtime,
     * a Helm chart (check 12: ERROR there, WARN elsewhere).
     */
    private val completeEnvs: Set<String> = setOf("local"),
    private val renderer: ComposeRenderer? = null,
    /** When true, a missing compose CLI (check 6) or Helm (check 12) fails instead of warning. */
    private val requireRender: Boolean = false,
    /** AppName -> its chart directory (`<subproject>/helm/<AppName>/`), for the apps that have one (check 12). */
    private val charts: Map<String, File> = emptyMap(),
    /** `scripts/helm-deploy-instance.sh --mode lint|template` (check 12); null: Helm switched off. */
    private val helm: HelmRunner? = null,
    /** kubeconform over the rendered manifests (check 12); null: not available. */
    private val validator: ManifestValidator? = null,
    /** Where check 12 keeps `<env>/<flow>/<AppName>/<AppInstance>.yaml`; null: temporary files. */
    private val renderDir: File? = null,
) {
    private val findings = mutableListOf<Finding>()
    private val yaml = Yaml(SafeConstructor(LoaderOptions()))
    /**
     * `helm` is one of platform.yml `kinds` (ADR-0036). Without it no chart and no `_helm-values.*.yaml` is required and
     * check 12 renders nothing; a values file that exists is still checked (checks 3, 4, 10).
     */
    private val helmEnabled = scope.helmEnabled
    private var helmSkipped = false
    private var unvalidated = 0

    private fun rel(file: File): String = file.relativeTo(configRoot.parentFile ?: configRoot).path

    private fun error(check: Int, file: File, message: String) { findings += Finding(check, Severity.ERROR, rel(file), message) }
    private fun warn(check: Int, file: File, message: String) { findings += Finding(check, Severity.WARN, rel(file), message) }

    fun lint(): List<Finding> {
        findings.clear()
        helmSkipped = false
        unvalidated = 0
        if (!configRoot.isDirectory) {
            error(3, configRoot, "config tree not found")
            return findings.toList()
        }
        val children = configRoot.listFiles().orEmpty().sortedBy { it.name }
        for (child in children) {
            when {
                child.isFile && child.name == "README.md" -> Unit
                child.isDirectory && child.name == ConfigRules.COMMON -> error(1, child, "config/_common/ removed: nothing is shared " +
                    "across envs (ADR-0011); a default that is the same everywhere belongs in the jar (layer 1), a cluster's shared " +
                    "settings in config/<env>/<flow>/application.flow.yml")
                child.isDirectory -> lintEnv(child)
                else -> error(1, child, "unexpected file at the top of config/ (only <env>/ and README.md)")
            }
        }
        for ((app, override) in appOverrides.toSortedMap()) {
            if (app in apps && override.isFile) lintComposeOverride(override)
        }
        configRoot.walkTopDown().filter { it.isFile }.sortedBy { it.path }.forEach { scanSecrets(it) }
        if (unvalidated > 0) {
            warn(12, configRoot, "kubeconform not available: $unvalidated rendered instance(s) not validated against the " +
                "Kubernetes ${ConfigRules.KUBERNETES_VERSION} schemas (CI installs it)")
        }
        findings += Finding(7, Severity.TODO, "config", "merged-configuration validation against " +
            "spring-configuration-metadata.json is not implemented yet (ADR-0014 check 7)")
        findings += Finding(8, Severity.TODO, "config", "parity report across the envs is not " +
            "implemented yet (ADR-0014 check 8)")
        return findings.toList()
    }

    // --- layers (ADR-0011: files named application.<layer>.yml, _docker-compose.<layer>.env / .yml, -------
    // --- _helm-values.<layer>.yaml in the directory of their level) ---------------------------------------

    private fun lintEnv(envDir: File) {
        val env = envDir.name
        if (!scope.isEnv(env)) {
            error(1, envDir, "env '$env' must be local or <region>-<stage> with a region of ${scope.regions.toList()} " +
                "and a stage of ${scope.stages.toList()} (platform.yml)")
            return
        }
        val envs = scope.envs
        if (envs != null && env != LintScope.LOCAL && env !in envs) {
            error(1, envDir, if (scope.isPromoted(env)) {
                "env '$env' does not belong in this repository, which holds only local and its dev envs ${envs.sorted()}: " +
                    "the promoted envs live in the configuration repository (ADR-0004)"
            } else {
                "env '$env' is not a dev env of this repository: add it to platform.yml dev_envs ${envs.sorted()} (ADR-0004)"
            })
            return
        }
        val appsSeen = mutableSetOf<String>()
        val pools = mutableListOf<FlowPool>()
        var knownHosts: List<KnownHost>? = null
        for (child in envDir.listFiles().orEmpty().sortedBy { it.name }) {
            when {
                child.isFile && (child.name == ConfigRules.TARGETS || child.name == "targets.yml") -> error(11, child, "moved to config/$env/<flow>/workflows-config.yml: one " +
                    "deploy inventory per flow (env, flow, pool, defaults, targets; ADR-0027)")
                child.isFile && child.name == "README.md" -> Unit
                child.isFile && child.name == "known_hosts" -> knownHosts = lintKnownHosts(child)
                child.isDirectory && child.name == ConfigRules.COMMON -> error(1, child, "config/$env/_common/ removed: nothing is " +
                    "shared at the env level, the cluster <env>/<flow> is the first shared layer: config/$env/<flow>/application.flow.yml " +
                    "and _docker-compose.flow.env / .yml (ADR-0011)")
                child.isDirectory && child.name in scope.flows -> lintFlow(child, env, appsSeen)?.let { pools += it }
                child.isDirectory -> error(1, child, "flow '${child.name}' must be one of ${scope.flows.toList()} (platform.yml)")
                else -> error(1, child, "unexpected file in config/$env/ (expected known_hosts, <flow>/)")
            }
        }
        if (env in completeEnvs) {
            for (app in apps.sorted()) {
                if (app !in appsSeen) error(2, envDir, "deployable app '$app' has no configuration in env '$env' (every app must)")
            }
        }
        checkSharedBoxes(pools)
        checkPinnedBoxes(envDir, pools, knownHosts)
    }

    /**
     * The files of one level's directory: its own layer files (YAML parses, overrides use no relative path), the
     * [extra] names it also holds; anything else is an error, a layer file of another level with where it belongs.
     */
    private fun lintLayerFiles(dir: File, layer: ConfigRules.Layer, extra: Set<String> = emptySet()) {
        val own = ConfigRules.layerFiles(layer)
        for (file in dir.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.name }) {
            val name = file.name
            val other = ConfigRules.LAYER_FILE.matchEntire(name)?.groupValues?.get(2)
            when {
                name in extra -> Unit
                name == ConfigRules.composeEnv(layer) -> Unit // parsed by the caller (checks 4, 5, 10)
                name == ConfigRules.composeOverride(layer) -> lintComposeOverride(file)
                name in own -> lintYaml(file)
                other != null && other != layer.id -> error(1, file, "a $other-layer file in the ${layer.id} level's directory: " +
                    "it belongs in ${levelDirectory(other)} (ADR-0011)")
                name == "compose.env" || name == "values.yaml" || name == "application.yml" -> error(1, file,
                    "the layout before ADR-0011: rename it to ${renamed(name, layer)}")
                name == ".env" || name.endsWith(".env") -> error(3, file, "forbidden: the only env file of this level is " +
                    "${ConfigRules.composeEnv(layer)} (ADR-0012)")
                else -> error(1, file, "unexpected file in the ${layer.id} level's directory (allowed: " +
                    "${(own + extra).sorted().joinToString()})")
            }
        }
    }

    private fun levelDirectory(layer: String) = when (layer) {
        "flow" -> "config/<env>/<flow>/"
        "app" -> "config/<env>/<flow>/<AppName>/"
        else -> "config/<env>/<flow>/<AppName>/<AppInstance>/"
    }

    private fun renamed(name: String, layer: ConfigRules.Layer) = when (name) {
        "compose.env" -> ConfigRules.composeEnv(layer)
        "values.yaml" -> ConfigRules.helmValues(layer)
        else -> ConfigRules.application(layer)
    }

    /** An env layer of [dir] when it exists, parsed and checked (check 5); empty when absent or malformed. */
    private fun envLayer(dir: File, layer: ConfigRules.Layer): Map<String, String> {
        val file = File(dir, ConfigRules.composeEnv(layer))
        if (!file.isFile) return emptyMap()
        val vars = parseEnvFile(file) ?: return emptyMap()
        checkEnvLayer(file, vars, layer)
        return vars
    }

    /** Returns the flow's pool (check 11) when its workflows-config.yml declares one. */
    private fun lintFlow(flowDir: File, env: String, appsSeen: MutableSet<String>): FlowPool? {
        val instances = mutableListOf<String>()
        lintLayerFiles(flowDir, ConfigRules.Layer.FLOW, extra = setOf(ConfigRules.TARGETS, "targets.yml"))
        File(flowDir, "targets.yml").takeIf { it.isFile }?.let {
            error(11, it, "renamed: the flow's deploy inventory is workflows-config.yml (ADR-0027)")
        }
        val flowEnv = envLayer(flowDir, ConfigRules.Layer.FLOW)
        for (appDir in flowDir.listFiles().orEmpty().filter { it.isDirectory }.sortedBy { it.name }) {
            if (appDir.name == ConfigRules.COMMON) {
                error(1, appDir, "the cluster layer is files now: config/$env/${flowDir.name}/application.flow.yml and " +
                    "_docker-compose.flow.env / .yml (ADR-0011)")
                continue
            }
            val app = appDir.name
            appsSeen += app
            checkAppName(appDir)
            if (helmEnabled && app in apps && app !in charts) {
                val message = "no Helm chart for '$app': expected <subproject>/helm/$app/Chart.yaml (ADR-0019)"
                if (env in completeEnvs) error(12, appDir, message) else warn(12, appDir, message)
            }
            lintLayerFiles(appDir, ConfigRules.Layer.APP)
            val appYml = File(appDir, ConfigRules.application(ConfigRules.Layer.APP))
            val values = File(appDir, ConfigRules.helmValues(ConfigRules.Layer.APP))
            if (!appYml.isFile) error(3, appYml, "required file missing")
            var commonEnv: Map<String, String> = emptyMap()
            if (!values.isFile) { if (helmEnabled) error(3, values, "required file missing (Helm values layer 2, ADR-0019)") }
            else loadValues(values)?.let { commonEnv = checkCommonValues(values, it) }
            val commonComplete = appYml.isFile && values.isFile
            val appEnv = envLayer(appDir, ConfigRules.Layer.APP)
            for (instDir in appDir.listFiles().orEmpty().filter { it.isDirectory }.sortedBy { it.name }) {
                if (instDir.name == ConfigRules.APP_COMMON) {
                    error(1, instDir, "the app layer is files now: ${rel(appDir)}/application.app.yml, _helm-values.app.yaml " +
                        "and _docker-compose.app.env / .yml (ADR-0011)")
                    continue
                }
                instances += "$app/${instDir.name}"
                lintInstance(instDir, env, flowDir.name, app, commonEnv, commonComplete, flowEnv + appEnv)
            }
        }
        val targetsFile = File(flowDir, ConfigRules.TARGETS)
        return when {
            env.endsWith("-dev") && !targetsFile.isFile -> {
                error(3, targetsFile, "required in every flow of a *-dev env (the flow's deploy-dev inventory, ADR-0027)")
                null
            }
            env.endsWith("-dev") -> lintTargets(targetsFile, env, flowDir.name, instances)
            targetsFile.isFile -> {
                warn(11, targetsFile, "only *-dev envs are deployed from workflows-config.yml; this file is ignored")
                lintTargets(targetsFile, env, flowDir.name, instances)
            }
            else -> null
        }
    }

    private fun checkAppName(appDir: File) {
        val app = appDir.name
        if (!ConfigRules.TOKEN.matches(app) || app.length > ConfigRules.MAX_APP_NAME) {
            error(1, appDir, "AppName must match ${ConfigRules.TOKEN.pattern} and be at most ${ConfigRules.MAX_APP_NAME} characters")
        }
        if (app !in apps) {
            error(2, appDir, "'$app' is not a deployable Gradle subproject (known: ${apps.sorted().joinToString()})")
        }
    }

    private fun lintInstance(
        dir: File, env: String, flow: String, app: String, commonEnv: Map<String, String>, commonComplete: Boolean,
        sharedEnv: Map<String, String>,
    ) {
        val instance = dir.name
        val nameProblem = when {
            !ConfigRules.TOKEN.matches(instance) -> "AppInstance must match ${ConfigRules.TOKEN.pattern}"
            instance.all { it.isDigit() } -> "AppInstance is a business-logic name, never a bare number (ADR-0003)"
            instance.length > ConfigRules.MAX_APP_INSTANCE ->
                "AppInstance is ${instance.length} characters, at most ${ConfigRules.MAX_APP_INSTANCE}"
            "$app-$instance".length > ConfigRules.MAX_RELEASE_NAME ->
                "'$app-$instance' exceeds the ${ConfigRules.MAX_RELEASE_NAME}-character Helm release budget"
            else -> null
        }
        nameProblem?.let { error(1, dir, it) }
        for (sub in dir.listFiles().orEmpty().filter { it.isDirectory }.sortedBy { it.name }) {
            error(1, sub, "layer directories are flat: nested directory not allowed")
        }
        lintLayerFiles(dir, ConfigRules.Layer.INSTANCE)
        val instanceEnv = File(dir, ConfigRules.composeEnv(ConfigRules.Layer.INSTANCE))
        val appYml = File(dir, ConfigRules.application(ConfigRules.Layer.INSTANCE))
        val valuesFile = File(dir, ConfigRules.helmValues(ConfigRules.Layer.INSTANCE))
        if (!appYml.isFile) error(3, appYml, "required file missing")
        // The combined env of the instance: flow < app < instance, the later layer winning per key (ADR-0012).
        var vars: Map<String, String>? = null
        if (!instanceEnv.isFile) {
            error(3, instanceEnv, "required file missing (the image tag, the identity and the actuator port)")
        } else {
            val own = parseEnvFile(instanceEnv)
            if (own != null) {
                checkEnvLayer(instanceEnv, own, ConfigRules.Layer.INSTANCE)
                checkInstanceEnv(instanceEnv, own, env, flow, app, instance)
                vars = sharedEnv + own
                if (vars["IMAGE_REPO"].isNullOrBlank()) error(5, instanceEnv, "IMAGE_REPO missing in every env layer of the instance")
                render(dir, instanceEnv, vars, env, flow, app, instance)
            }
        }
        var values: Map<*, *>? = null
        if (!valuesFile.isFile) {
            if (helmEnabled) error(3, valuesFile, "required file missing (Helm values layer 3, ADR-0019)")
        } else {
            values = loadValues(valuesFile)
            values?.let { checkInstanceValues(valuesFile, it, commonEnv, vars, env, flow, app, instance) }
        }
        if (helmEnabled && nameProblem == null && commonComplete && appYml.isFile && valuesFile.isFile) {
            helmRender(dir, env, flow, app, instance, renderTag(values, vars))
        }
    }

    private fun lintYaml(file: File): List<Any?>? {
        val documents = try {
            yaml.loadAll(file.readText()).toList()
        } catch (e: Exception) {
            error(3, file, "YAML does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            return null
        }
        for (doc in documents) {
            for (key in flatten(doc)) {
                if (ConfigRules.isSecretProperty(key)) {
                    error(9, file, "'$key' is a secret property (ADR-0013): it arrives from the environment or " +
                        "/secrets/, never from the config tree")
                }
            }
        }
        return documents
    }

    /**
     * A compose override (check 6, ADR-0012): YAML that parses and no relative path — compose resolves a relative path of
     * any `-f` file against the first file's directory (`docker/`), not the override's own.
     */
    private fun lintComposeOverride(file: File) {
        val documents = lintYaml(file) ?: return
        for (value in documents.flatMap { scalars(it) }.distinct()) {
            if (value.startsWith("./") || value.startsWith("../")) {
                error(6, file, "'$value' is a relative path, which compose resolves against docker/, not this file's " +
                    "directory: use a variable-based absolute path")
            }
        }
    }

    private fun scalars(node: Any?): List<String> = when (node) {
        is Map<*, *> -> node.values.flatMap { scalars(it) }
        is List<*> -> node.flatMap { scalars(it) }
        is String -> listOf(node)
        else -> emptyList()
    }

    private fun flatten(node: Any?, prefix: String = ""): List<String> = when (node) {
        is Map<*, *> -> node.entries.flatMap { (k, v) ->
            val key = if (prefix.isEmpty()) k.toString() else "$prefix.$k"
            flatten(v, key).ifEmpty { listOf(key) }
        }
        is List<*> -> node.flatMapIndexed { i, v -> flatten(v, "$prefix[$i]") }
        else -> if (prefix.isEmpty()) emptyList() else listOf(prefix)
    }

    // --- env layers (_docker-compose.<layer>.env) -------------------------------------------------------

    /** `KEY=VALUE` lines, `#` comments; null (after reporting) when the file is malformed. */
    internal fun parseEnvFile(file: File): Map<String, String>? {
        val vars = linkedMapOf<String, String>()
        var ok = true
        file.readLines().forEachIndexed { index, raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val match = Regex("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$").matchEntire(line)
            if (match == null) {
                error(5, file, "line ${index + 1} is not KEY=VALUE")
                ok = false
                return@forEachIndexed
            }
            val (key, value) = match.destructured
            if (key in vars) error(5, file, "line ${index + 1}: $key defined twice")
            vars[key] = value.trim().removeSurrounding("\"").removeSurrounding("'")
        }
        return if (ok) vars else null
    }

    /** Check 5: the allow-list of an env layer; the instance-only variables and the ports in the instance layer only. */
    private fun checkEnvLayer(file: File, vars: Map<String, String>, layer: ConfigRules.Layer) {
        for ((key, value) in vars) {
            val port = ConfigRules.HOST_PORT.matches(key)
            when {
                ConfigRules.FORBIDDEN_PREFIXES.any { key.startsWith(it) } ->
                    error(5, file, "$key is forbidden in an env layer (SPRING_/LOGGING_/MANAGEMENT_/CONNECTOR_ belong " +
                        "in YAML; secrets are passed through from the shell, ADR-0012)")
                key in ConfigRules.SCRIPT_VARIABLES ->
                    error(5, file, "$key is set by run-compose.sh and must not appear in an env layer")
                key !in ConfigRules.COMPOSE_ENV_ALLOWED && !port ->
                    error(5, file, "$key is not an allowed compose variable (ADR-0012)")
                layer != ConfigRules.Layer.INSTANCE && (port || key in ConfigRules.INSTANCE_ONLY) ->
                    error(5, file, "$key belongs in the instance layer only (_docker-compose.instance.env, ADR-0012)")
                port && value.toIntOrNull()?.let { it in 1024..65535 } != true ->
                    error(5, file, "$key=$value must be a port in 1024..65535 (rootless Podman, ADR-0017)")
                key in ConfigRules.HOST_DIRS && (!ConfigRules.HOST_PATH.matches(value) || value.split('/').any { it == ".." }) ->
                    error(5, file, "$key=$value must be an absolute host path (ADR-0018)")
            }
        }
    }

    /** Checks 4 and 10 on the instance layer: the identity restates the path, IMAGE_TAG obeys the tag policy. */
    private fun checkInstanceEnv(file: File, vars: Map<String, String>, env: String, flow: String, app: String, instance: String) {
        val expected = mapOf("APP_ENV" to env, "APP_FLOW" to flow, "APP_NAME" to app, "APP_INSTANCE" to instance)
        for ((key, value) in expected) {
            val actual = vars[key]
            if (actual == null) error(4, file, "$key missing (must restate the directory path: $value)")
            else if (actual != value) error(4, file, "$key=$actual does not match the directory path ($value)")
        }
        val tag = vars["IMAGE_TAG"]
        if (tag == null) error(10, file, "IMAGE_TAG missing") else checkTag(file, "IMAGE_TAG", tag, env)
    }

    /** Check 10: the tag policy, identical for `IMAGE_TAG` (the instance env layer) and `image.tag` (its Helm values). */
    private fun checkTag(file: File, what: String, tag: String, env: String) {
        val bareTag = tag.substringBefore('@')
        if (!ConfigRules.DOCKER_TAG.matches(bareTag)) error(10, file, "$what '$tag' is not a valid image tag")
        val immutableEnv = scope.isPromoted(env)
        if (immutableEnv && !ConfigRules.RELEASE_TAG.matches(tag)) {
            error(10, file, "$what '$tag' in $env must be an immutable release tag X.Y.Z (optionally " +
                "@sha256:<digest>); floating tags are allowed only in *-dev and local (ADR-0010)")
        }
    }

    // --- _helm-values.<layer>.yaml (checks 3, 4, 10; Helm is deferred, ADR-0019: the rules are unchanged) ----

    /** A values file as a map; null when it does not parse (check 3 reports that through [lintYaml]). */
    private fun loadValues(file: File): Map<*, *>? {
        val documents = try {
            yaml.loadAll(file.readText()).toList()
        } catch (e: Exception) {
            return null
        }
        return when {
            documents.size > 1 -> { error(3, file, "a Helm values file holds one YAML document"); null }
            documents.isEmpty() || documents[0] == null -> emptyMap<String, Any>()
            documents[0] is Map<*, *> -> documents[0] as Map<*, *>
            else -> { error(3, file, "must be a YAML mapping (Helm values)"); null }
        }
    }

    /** Check 4: the `env:` map carries only app-facing variables (ADR-0019); returns its scalar entries. */
    private fun valuesEnv(file: File, values: Map<*, *>): Map<String, String> {
        val env = values["env"] ?: return emptyMap()
        if (env !is Map<*, *>) {
            error(4, file, "env: must be a map NAME: value (the container environment, ADR-0019)")
            return emptyMap()
        }
        val result = linkedMapOf<String, String>()
        for ((k, v) in env) {
            val key = k.toString()
            when {
                ConfigRules.FORBIDDEN_PREFIXES.any { key.startsWith(it) } ->
                    error(4, file, "env.$key is forbidden: SPRING_/LOGGING_/MANAGEMENT_/CONNECTOR_ settings belong in " +
                        "YAML, secrets in the Secret mounted at /secrets/ (ADR-0011, ADR-0013)")
                key !in ConfigRules.VALUES_ENV_ALLOWED ->
                    error(4, file, "env.$key is not an app-facing variable (ADR-0019; allowed: " +
                        "${ConfigRules.VALUES_ENV_ALLOWED.sorted().joinToString()})")
            }
            when (v) {
                null -> Unit
                is Map<*, *>, is List<*> -> error(4, file, "env.$key must be a single value")
                else -> result[key] = v.toString()
            }
        }
        return result
    }

    /** _helm-values.app.yaml: shared values only — the tag and the identity belong to the instance. */
    private fun checkCommonValues(file: File, values: Map<*, *>): Map<String, String> {
        if ((values["image"] as? Map<*, *>)?.containsKey("tag") == true) {
            error(10, file, "image.tag belongs in <AppInstance>/_helm-values.instance.yaml (written back per instance with IMAGE_TAG, ADR-0019)")
        }
        if (values.containsKey("identity")) error(4, file, "identity belongs in <AppInstance>/_helm-values.instance.yaml (the instance's path)")
        val env = valuesEnv(file, values)
        if ("APP_INSTANCE" in env) error(4, file, "env.APP_INSTANCE belongs in <AppInstance>/_helm-values.instance.yaml")
        return env
    }

    private fun checkInstanceValues(
        file: File, values: Map<*, *>, commonEnv: Map<String, String>, vars: Map<String, String>?,
        env: String, flow: String, app: String, instance: String,
    ) {
        // Check 4: identity restated equals the path, in `identity` and in the APP_* variables.
        val path = linkedMapOf("env" to env, "flow" to flow, "app" to app, "instance" to instance)
        when (val identity = values["identity"]) {
            null -> error(4, file, "identity missing: must restate the directory path { env: $env, flow: $flow, app: $app, instance: $instance }")
            !is Map<*, *> -> error(4, file, "identity must be a map { env, flow, app, instance }")
            else -> for ((key, want) in path) {
                val got = identity[key]?.toString()
                if (got == null) error(4, file, "identity.$key missing (must restate the directory path: $want)")
                else if (got != want) error(4, file, "identity.$key=$got does not match the directory path ($want)")
            }
        }
        val effective = commonEnv + valuesEnv(file, values)
        for ((key, want) in ConfigRules.IDENTITY.zip(path.values)) {
            val got = effective[key]
            if (got == null) error(4, file, "env.$key missing (must restate the directory path: $want)")
            else if (got != want) error(4, file, "env.$key=$got does not match the directory path ($want)")
        }
        // Check 4 (warning): compose and Kubernetes should run the instance with the same knobs.
        if (vars != null) {
            for (key in ConfigRules.SHARED_KNOBS) {
                val composeValue = vars[key] ?: continue
                val helmValue = effective[key]
                if (helmValue == null) {
                    warn(4, file, "$key is set in the compose env layers ($composeValue) but not in the values env (app or instance)")
                } else if (helmValue != composeValue) {
                    warn(4, file, "env.$key=$helmValue differs from $key=$composeValue in the compose env layers")
                }
            }
        }
        // Checks 10 and 4: image.tag obeys the tag policy and equals IMAGE_TAG (one record, ADR-0019).
        val image = values["image"]
        val tag = (image as? Map<*, *>)?.get("tag")
        when {
            image != null && image !is Map<*, *> -> error(10, file, "image must be a map (image.tag, image.digest)")
            tag == null -> error(10, file, "image.tag missing: the instance's image tag, equal to IMAGE_TAG in _docker-compose.instance.env (ADR-0019)")
            tag !is String -> error(10, file, "image.tag must be a string: quote it (\"$tag\")")
            else -> {
                checkTag(file, "image.tag", tag, env)
                val composeTag = vars?.get("IMAGE_TAG")
                if (composeTag != null && composeTag != tag) {
                    error(4, file, "image.tag '$tag' differs from IMAGE_TAG '$composeTag' in _docker-compose.instance.env: both record " +
                        "the deployed tag and are written back together (ADR-0019)")
                }
            }
        }
        val digest = (image as? Map<*, *>)?.get("digest")?.toString()
        if (!digest.isNullOrEmpty() && !ConfigRules.DIGEST.matches(digest)) {
            error(10, file, "image.digest '$digest' must be sha256:<64 hex digits> (ADR-0010)")
        }
    }

    // --- check 6: render --------------------------------------------------------------------------------

    private val templateVariable = Regex("""\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?+][^}]*)?}""")

    /**
     * Check 6 (ADR-0012): `compose config` over the instance's compose files in run-compose.sh's merge order — the shared
     * template, the app's override, the flow / app / instance overrides — with its combined env written to a file, as
     * run-compose.sh passes them.
     */
    private fun render(dir: File, instanceEnv: File, vars: Map<String, String>, env: String, flow: String, app: String, instance: String) {
        val base = template ?: return
        val r = renderer ?: return
        if (app !in apps) return // check 2 already reported it
        val appDir = dir.parentFile
        val flowDir = appDir.parentFile
        val files = listOfNotNull(
            base,
            appOverrides[app]?.takeIf { it.isFile },
            File(flowDir, ConfigRules.composeOverride(ConfigRules.Layer.FLOW)).takeIf { it.isFile },
            File(appDir, ConfigRules.composeOverride(ConfigRules.Layer.APP)).takeIf { it.isFile },
            File(dir, ConfigRules.composeOverride(ConfigRules.Layer.INSTANCE)).takeIf { it.isFile },
        )
        val combined = File.createTempFile("config-lint-$app-$instance-", ".env").apply { deleteOnExit() }
        combined.writeText(vars.entries.joinToString("") { "${it.key}=${it.value}\n" })
        val environment = linkedMapOf(
            "APP_ENV" to env, "APP_FLOW" to flow, "APP_NAME" to app, "APP_INSTANCE" to instance,
            "COMPOSE_ENV_FILE" to combined.absolutePath,
            "APP_APP_YML" to File(appDir, ConfigRules.application(ConfigRules.Layer.APP)).absolutePath,
            "INSTANCE_APP_YML" to File(dir, ConfigRules.application(ConfigRules.Layer.INSTANCE)).absolutePath,
            "PROJECT" to "$env-$flow-$app-$instance",
        )
        File(flowDir, ConfigRules.application(ConfigRules.Layer.FLOW)).takeIf { it.isFile }
            ?.let { environment["FLOW_APP_YML"] = it.absolutePath }
        // The instance's host directories, as run-compose.sh derives them (ADR-0018).
        for (key in ConfigRules.HOST_DIRS) {
            vars[key]?.takeIf { it.isNotBlank() }?.let { environment["INSTANCE_$key"] = "${it.trimEnd('/')}/$app/$instance" }
        }
        // Placeholders for every required variable nobody else provides: the secrets passed through the shell.
        val text = files.joinToString("\n") { f -> f.readLines().filterNot { it.trimStart().startsWith("#") }.joinToString("\n") }
        for (match in templateVariable.findAll(text)) {
            val (name, modifier) = match.destructured
            val required = modifier.startsWith(":?") || modifier.startsWith("?")
            if (required && name !in environment && name !in vars) environment[name] = "config-lint-placeholder"
        }
        val result = r.render(ComposeRenderRequest(files, combined, "lint-$env-$flow-$app-$instance", environment))
        combined.delete()
        when {
            result == null && requireRender -> error(6, instanceEnv, "no compose CLI (docker compose / podman compose) to render the compose files")
            result == null -> warn(6, instanceEnv, "render skipped: no compose CLI (docker compose / podman compose) found")
            result.exitCode != 0 -> error(6, instanceEnv, "`compose config` failed for ${files.joinToString(" + ") { rel(it) }}:\n" +
                result.output.lineSequence().filter { it.isNotBlank() }.joinToString("\n") { "      $it" })
        }
    }

    // --- check 12: helm lint, helm template, kubeconform ------------------------------------------------

    /** The tag check 12 renders with: the instance's image.tag, else IMAGE_TAG, when the deploy script accepts it. */
    private fun renderTag(values: Map<*, *>?, vars: Map<String, String>?): String {
        val fromValues = (values?.get("image") as? Map<*, *>)?.get("tag") as? String
        return listOfNotNull(fromValues, vars?.get("IMAGE_TAG")).firstOrNull { ConfigRules.TAG_REFERENCE.matches(it) }
            ?: "config-lint"
    }

    private fun indented(output: String): String =
        output.lineSequence().filter { it.isNotBlank() }.joinToString("\n") { "      $it" }

    /** No usable Helm: reported once for the whole run (the same cause for every instance). */
    private fun helmUnavailable(dir: File, reason: String) {
        if (helmSkipped) return
        helmSkipped = true
        val message = "helm lint / helm template skipped for every instance: $reason"
        if (requireRender) error(12, dir, message) else warn(12, dir, message)
    }

    /**
     * Check 12 (ADR-0014, ADR-0019): `helm lint` and `helm template` of one instance through
     * scripts/helm-deploy-instance.sh — the flag list has one implementation — then kubeconform over the result.
     * `helm lint` does not evaluate the chart's `fail` guards; `helm template` does.
     */
    private fun helmRender(dir: File, env: String, flow: String, app: String, instance: String, tag: String) {
        val chart = charts[app] ?: return // reported once per app directory
        if (helmSkipped) return
        val runner = helm
        if (runner == null) {
            helmUnavailable(dir, "Helm is switched off (-PconfigLint.helm=none)")
            return
        }
        fun run(mode: HelmMode, out: File?): CommandResult? {
            val result = runner.run(HelmRequest(env, flow, app, instance, tag, chart, mode, out))
            when {
                result == null -> helmUnavailable(dir, "Helm is switched off (-PconfigLint.helm=none)")
                result.exitCode == ConfigRules.EXIT_TOOL ->
                    helmUnavailable(dir, "no usable Helm 4 (-PconfigLint.helm=auto|none|<path>):\n${indented(result.output)}")
                result.exitCode != 0 -> error(12, dir, "helm ${mode.flag} failed (scripts/helm-deploy-instance.sh $env $flow $app " +
                    "$instance --tag $tag --mode ${mode.flag}):\n${indented(result.output)}")
                else -> return result
            }
            return null
        }
        run(HelmMode.LINT, null) ?: return
        val out = renderDir?.let { File(it, "$env/$flow/$app/$instance.yaml") }
            ?: File.createTempFile("config-lint-$app-$instance-", ".yaml").apply { deleteOnExit() }
        out.parentFile.mkdirs()
        run(HelmMode.TEMPLATE, out) ?: return
        val result = validator?.validate(out)
        if (result == null) {
            unvalidated++
            return
        }
        val summary = kubeconformSummary(result.output)
        when {
            result.exitCode != 0 -> error(12, dir, "kubeconform (-strict, Kubernetes ${ConfigRules.KUBERNETES_VERSION}) " +
                "rejected ${rel(out)}:\n${indented(kubeconformProblems(result.output) ?: result.output)}")
            summary != null && (summary["valid"] ?: 0) == 0 ->
                warn(12, dir, "kubeconform validated no resource of ${rel(out)} (skipped: ${summary["skipped"]}; no schemas " +
                    "for Kubernetes ${ConfigRules.KUBERNETES_VERSION}?)")
        }
    }

    /** `{"resources": [...], "summary": {"valid": n, ...}}` of `kubeconform -output json -summary`, when it parses. */
    private fun kubeconformJson(output: String): Map<*, *>? {
        val json = output.substring(output.indexOf('{').takeIf { it >= 0 } ?: return null)
        return try { yaml.load<Any?>(json) as? Map<*, *> } catch (e: Exception) { null }
    }

    private fun kubeconformSummary(output: String): Map<String, Int>? =
        (kubeconformJson(output)?.get("summary") as? Map<*, *>)?.entries
            ?.associate { (k, v) -> k.toString() to ((v as? Number)?.toInt() ?: 0) }

    private fun kubeconformProblems(output: String): String? =
        (kubeconformJson(output)?.get("resources") as? List<*>)?.filterIsInstance<Map<*, *>>()?.joinToString("\n") { r ->
            val errors = (r["validationErrors"] as? List<*>)?.filterIsInstance<Map<*, *>>()
                ?.joinToString("; ") { "${it["path"]}: ${it["msg"]}" }
            "${r["kind"]} ${r["name"]}: ${r["status"]} ${errors ?: r["msg"] ?: ""}".trimEnd()
        }?.takeIf { it.isNotBlank() }

    // --- check 9: secret scan ---------------------------------------------------------------------------

    private fun scanSecrets(file: File) {
        if (!file.isFile || file.length() > 1_000_000) return
        val lines = try { file.readLines() } catch (e: Exception) { return }
        lines.forEachIndexed { index, line ->
            if (line.trimStart().startsWith("#")) return@forEachIndexed
            for ((pattern, what) in ConfigRules.SECRET_VALUE_PATTERNS) {
                if (pattern.containsMatchIn(line)) error(9, file, "line ${index + 1} looks like a secret ($what)")
            }
        }
    }

    // --- check 11: config/<env>/<flow>/workflows-config.yml (ADR-0027) and the host pool of ADR-0028 ----------------

    /** The `pool` of one flow: the boxes of `<env>/<flow>`, reached as [user], the bundle under [root]. */
    private data class Pool(val hosts: List<String>, val user: String, val keep: Int)
    private data class FlowPool(val file: File, val flow: String, val pool: Pool)

    /** Lints one flow's inventory; returns its pool, if it declares one. [instances] are `<AppName>/<AppInstance>`. */
    private fun lintTargets(file: File, env: String, flow: String, instances: List<String>): FlowPool? {
        val doc = try {
            yaml.load<Any?>(file.readText())
        } catch (e: Exception) {
            error(11, file, "YAML does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            return null
        }
        if (doc !is Map<*, *>) {
            error(11, file, "must be a mapping with env, flow, pool, defaults, targets")
            return null
        }
        (doc.keys.map { it.toString() } - setOf("env", "flow", "pool", "defaults", "targets")).forEach {
            error(11, file, "unknown top-level key '$it' (allowed: env, flow, pool, defaults, targets)")
        }
        if (doc["env"]?.toString() != env) error(11, file, "env: must be '$env', the env of its path (was '${doc["env"]}')")
        if (doc["flow"]?.toString() != flow) error(11, file, "flow: must be '$flow', the flow of its path (was '${doc["flow"]}')")
        val pool = if (doc.containsKey("pool")) lintPool(file, doc["pool"]) else null
        val flowPool = pool?.let { FlowPool(file, flow, it) }
        // `user`: the SSH user of a compose host (ADR-0018: `deploy`, the default of the deploy-dev job).
        val entryKeys = setOf("kind", "host", "user", "cluster", "namespace")
        val defaults = doc["defaults"] ?: emptyMap<String, Any>()
        if (defaults !is Map<*, *>) {
            error(11, file, "defaults: must be a mapping")
            return flowPool
        }
        (defaults.keys.map { it.toString() } - entryKeys).forEach { error(11, file, "defaults: unknown key '$it'") }
        val targets = doc["targets"]
        if (targets !is List<*>) {
            error(11, file, "targets: must be a list")
            return flowPool
        }
        val listed = mutableSetOf<String>()
        var composeTargets = 0
        targets.forEachIndexed { index, entry ->
            val where = "targets[$index]"
            if (entry !is Map<*, *>) {
                error(11, file, "$where must be a mapping")
                return@forEachIndexed
            }
            (entry.keys.map { it.toString() } - (entryKeys + "instance")).forEach { error(11, file, "$where: unknown key '$it'") }
            val instance = entry["instance"]?.toString()
            if (instance == null || !Regex("^[a-z0-9-]+/[a-z0-9-]+$").matches(instance)) {
                error(11, file, "$where: instance must be <AppName>/<AppInstance>, relative to the flow (was '$instance')")
                return@forEachIndexed
            }
            if (!listed.add(instance)) error(11, file, "$where: $instance listed twice")
            if (instance !in instances) error(11, file, "$where: $instance has no directory config/$env/$flow/$instance/")
            val effective = defaults.entries.associate { it.key.toString() to it.value } + entry.entries.associate { it.key.toString() to it.value }
            effective["user"]?.toString()?.let { user ->
                if (!ConfigRules.LOGIN.matches(user)) error(11, file, "$where: user '$user' is not a valid login name")
            }
            val kind = effective["kind"]?.toString()
            if ((kind == "compose" || kind == "helm") && kind !in scope.kinds) {
                error(11, file, "$where: kind '$kind' is not a runtime of this project (platform.yml kinds: " +
                    "${scope.kinds.joinToString()})")
            }
            when (kind) {
                "compose" -> {
                    composeTargets++
                    lintComposePlacement(file, where, effective["host"]?.toString()?.takeIf { it.isNotBlank() },
                        entry["user"]?.toString(), pool)
                }
                "helm" -> {
                    if (effective["cluster"]?.toString().isNullOrBlank()) error(11, file, "$where: kind helm needs cluster")
                    // namespace: the flow name by default (ADR-0027); the literal "{flow}" stands for it.
                    val namespace = (effective["namespace"]?.toString() ?: flow).replace("{flow}", flow)
                    if (!ConfigRules.NAMESPACE.matches(namespace)) {
                        error(11, file, "$where: namespace '$namespace' is not a DNS label (RFC 1123, at most 63 characters)")
                    }
                }
                else -> error(11, file, "$where: kind must be compose or helm (was '$kind')")
            }
        }
        (instances - listed).sorted().forEach { error(11, file, "instance $it has no target (inventory drift)") }
        if (pool != null && composeTargets == 0) {
            warn(11, file, "pool: flow '$flow' has no compose target, so nothing is deployed to its boxes")
        }
        return flowPool
    }

    /**
     * A compose target runs on its own `host` (or `defaults.host`), or on a box of the flow's `pool` (ADR-0028): there
     * `host` is the recorded placement — optional, and when present one of the pool's boxes.
     */
    private fun lintComposePlacement(file: File, where: String, host: String?, ownUser: String?, pool: Pool?) {
        when {
            host == null && pool == null -> error(11, file, "$where: kind compose needs host, or a pool in this file")
            host != null && !ConfigRules.HOST_NAME.matches(host) ->
                error(11, file, "$where: host '$host' is not a lower-case DNS name or IPv4 address")
            host != null && pool != null && pool.hosts.isNotEmpty() && host !in pool.hosts ->
                error(11, file, "$where: host '$host' is not a box of the pool (${pool.hosts.joinToString()}); " +
                    "a pooled instance runs on one of its flow's boxes")
        }
        if (pool != null && ownUser != null && ownUser != pool.user) {
            warn(11, file, "$where: user '$ownUser' is ignored: every box of the pool is reached as '${pool.user}'")
        }
    }

    /** `pool`: {hosts, user?, keep?} (ADR-0018, ADR-0028); null after reporting when it is not a mapping. */
    private fun lintPool(file: File, node: Any?): Pool? {
        if (node !is Map<*, *>) {
            error(11, file, "pool: must be a mapping with hosts, user, keep")
            return null
        }
        if (node.containsKey("root")) {
            error(11, file, "pool.root is gone (ADR-0018): every box holds the project's versions under /apps/<user>/versions/<project>/ " +
                "(<version>/ per deploy, current the live one) — remove the key")
        }
        (node.keys.map { it.toString() } - setOf("hosts", "user", "keep", "root")).forEach {
            error(11, file, "pool: unknown key '$it' (allowed: hosts, user, keep)")
        }
        val hosts = mutableListOf<String>()
        val list = node["hosts"]
        if (list !is List<*> || list.isEmpty()) {
            error(11, file, "pool.hosts must be a non-empty list of host names (the boxes of the flow)")
        } else {
            list.forEachIndexed { i, item ->
                val name = item?.toString().orEmpty()
                when {
                    item !is String || !ConfigRules.HOST_NAME.matches(name) ->
                        error(11, file, "pool.hosts[$i]: '$name' is not a lower-case DNS name or IPv4 address")
                    name in hosts -> error(11, file, "pool.hosts[$i]: $name is listed twice")
                    else -> hosts += name
                }
            }
        }
        val user = node["user"]?.toString() ?: ConfigRules.POOL_USER
        if (!ConfigRules.LOGIN.matches(user)) error(11, file, "pool.user '$user' is not a valid login name")
        val keepNode = node["keep"]
        val keep = (keepNode as? Int) ?: ConfigRules.POOL_KEEP_DEFAULT
        if (keepNode != null && (keepNode !is Int || keepNode < ConfigRules.POOL_KEEP_MIN)) {
            error(11, file, "pool.keep '$keepNode' must be an integer of at least ${ConfigRules.POOL_KEEP_MIN} " +
                "(the versions kept per box under /apps/<user>/versions/<project>/, ADR-0018)")
        }
        return Pool(hosts, user, keep)
    }

    /** A box serves exactly one `<env>/<flow>` (ADR-0018): its `current` version is one cluster's; two pools cannot share it. */
    private fun checkSharedBoxes(pools: List<FlowPool>) {
        val owner = mutableMapOf<String, String>()
        for ((file, flow, pool) in pools) {
            for (host in pool.hosts) {
                val other = owner.putIfAbsent(host, flow)
                if (other != null) {
                    error(11, file, "pool.hosts: $host is also a box of flow '$other': a box serves exactly one <env>/<flow> " +
                        "(ADR-0018) — its /apps/<user>/versions/<project>/current is one cluster's")
                }
            }
        }
    }

    /** A well-formed line of `config/<env>/known_hosts`: its marker, if any, and its host patterns. */
    private data class KnownHost(val marker: String?, val patterns: String)

    /** `config/<env>/known_hosts` (ADR-0028): the pinned host keys of the SSH transport — public keys only. */
    private fun lintKnownHosts(file: File): List<KnownHost> {
        val entries = mutableListOf<KnownHost>()
        file.readLines().forEachIndexed { index, raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val words = line.split(Regex("\\s+"))
            val marker = words.first().takeIf { it.startsWith("@") }
            val fields = if (marker != null) words.drop(1) else words
            when {
                marker != null && marker !in ConfigRules.KNOWN_HOSTS_MARKERS ->
                    error(11, file, "line ${index + 1}: unknown marker '$marker' (@cert-authority or @revoked)")
                fields.size < 3 || !ConfigRules.SSH_KEY_TYPE.matches(fields[1]) || !ConfigRules.BASE64.matches(fields[2]) ->
                    error(11, file, "line ${index + 1}: expected '<host>[,<host>...] <key type> <base64 key>' (ssh-keyscan format)")
                fields[0].startsWith("|") ->
                    error(11, file, "line ${index + 1}: a hashed host name (ssh-keyscan -H) cannot be reviewed: commit the " +
                        "plain ssh-keyscan line (ADR-0028)")
                else -> entries += KnownHost(marker, fields[0])
            }
        }
        return entries
    }

    /**
     * Every box of a pool has a pinned host key (ADR-0028): the ssh transport and the pool guard accept no other, so a box
     * without a matching line fails only at deploy time. A `@cert-authority` line covers the boxes its patterns match; a
     * `@revoked` line covers none. Without the file no box can be reached over SSH yet, which is only a warning.
     */
    private fun checkPinnedBoxes(envDir: File, pools: List<FlowPool>, knownHosts: List<KnownHost>?) {
        if (pools.isEmpty()) return
        val file = File(envDir, "known_hosts")
        if (knownHosts == null) {
            warn(11, file, "missing: the boxes of ${pools.joinToString { "flow '${it.flow}'" }} have no pinned host key, so " +
                "the ssh transport refuses to deploy to them until their reviewed ssh-keyscan lines are added (ADR-0028)")
            return
        }
        for ((_, flow, pool) in pools) {
            for (host in pool.hosts) {
                if (knownHosts.none { it.marker != "@revoked" && ConfigRules.matchesHostPatterns(host, it.patterns) }) {
                    error(11, file, "box $host of flow '$flow' has no line: the ssh transport and the pool guard would refuse " +
                        "it; add its reviewed ssh-keyscan line, or a @cert-authority line that covers it (ADR-0028)")
                }
            }
        }
    }
}
