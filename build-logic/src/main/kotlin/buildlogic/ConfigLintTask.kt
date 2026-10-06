package buildlogic

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.MapProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations
import org.gradle.work.DisableCachingByDefault
import java.io.ByteArrayOutputStream
import java.io.File
import javax.inject.Inject

/** Root task `configLint` (ADR-0014): runs [ConfigLinter] and fails on any ERROR finding. */
@DisableCachingByDefault(because = "Cheap, and checks 6 and 12 depend on the local compose CLI, Helm and kubeconform")
abstract class ConfigLintTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val configDir: DirectoryProperty

    /** Deployable AppNames: the subprojects that apply `buildlogic.docker-image` (ADR-0006). */
    @get:Input
    abstract val apps: SetProperty<String>

    /** The identity vocabulary of platform.yml (ADR-0003, ADR-0030). */
    @get:Input
    abstract val regions: ListProperty<String>

    @get:Input
    abstract val stages: ListProperty<String>

    @get:Input
    abstract val flows: ListProperty<String>

    /** The runtimes a deploy target may name (platform.yml `projects[0].kinds`). */
    @get:Input
    abstract val kinds: ListProperty<String>

    /** The dev envs of platform.yml: with `local`, the only envs this repository's tree may hold (ADR-0004). */
    @get:Input
    abstract val devEnvs: ListProperty<String>

    /** The apps' property roots (platform.yml `property_prefixes`): forbidden in env form, checks 4 and 5 (ADR-0042). */
    @get:Input
    abstract val propertyPrefixes: ListProperty<String>

    /** The project's secret properties (platform.yml `secret_properties`): check 9 (ADR-0013, ADR-0042). */
    @get:Input
    abstract val secretProperties: ListProperty<String>

    /** The one compose template, `docker/docker-compose.yml` (ADR-0012). */
    @get:InputFile
    @get:Optional
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val template: RegularFileProperty

    /** Deployable AppName -> absolute path of its `docker/docker-compose.override.yml`, for the apps that have one. */
    @get:Internal
    abstract val appOverrides: MapProperty<String, String>

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val appOverrideFiles: ConfigurableFileCollection

    @get:Input
    abstract val completeEnvs: SetProperty<String>

    /** `auto`, `docker`, `podman` or `none` (`-PconfigLint.compose`). */
    @get:Input
    abstract val composeCli: Property<String>

    /** Fail checks 6 / 12 when no compose CLI / Helm 4 exists (`-PconfigLint.requireRender`, default CI=true). */
    @get:Input
    abstract val requireRender: Property<Boolean>

    /** Deployable AppName -> absolute path of its chart directory (`<subproject>/helm/<AppName>/`), check 12. */
    @get:Internal
    abstract val charts: MapProperty<String, String>

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val chartFiles: ConfigurableFileCollection

    /** `auto` (helm on the PATH), `none` or the path of a Helm 4 binary (`-PconfigLint.helm`). */
    @get:Input
    abstract val helmCli: Property<String>

    /** scripts/helm-deploy-instance.sh, the one implementation of the Helm flag list (ADR-0019). */
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val helmScript: RegularFileProperty

    /** Check 12's `helm template` output, `<env>/<flow>/<AppName>/<AppInstance>.yaml` (the config-lint job's artefact). */
    @get:OutputDirectory
    abstract val renderDir: DirectoryProperty

    @get:OutputFile
    abstract val reportFile: RegularFileProperty

    @get:Inject
    abstract val execOperations: ExecOperations

    private fun exec(command: List<String>, environment: Map<String, String>? = null): CommandResult {
        val out = ByteArrayOutputStream()
        return try {
            val result = execOperations.exec {
                commandLine(command)
                if (environment != null) setEnvironment(environment)
                standardOutput = out
                errorOutput = out
                isIgnoreExitValue = true
            }
            CommandResult(result.exitValue, out.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            CommandResult(127, e.message ?: e.toString())
        }
    }

    private fun composeCommand(): List<String>? {
        val candidates = when (composeCli.get()) {
            "none" -> emptyList()
            "docker" -> listOf(listOf("docker", "compose"))
            "podman" -> listOf(listOf("podman", "compose"), listOf("podman-compose"))
            else -> listOf(listOf("docker", "compose"), listOf("podman", "compose"), listOf("docker-compose"), listOf("podman-compose"))
        }
        return candidates.firstOrNull { exec(it + "version").exitCode == 0 }
    }

    /** The variables the deploy script and Helm may read; nothing else of the developer's shell leaks in. */
    private fun helmEnvironment(configRoot: File): Map<String, String> {
        val keys = listOf("PATH", "HOME", "TMPDIR", "LANG", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
            "HELM_CACHE_HOME", "HELM_CONFIG_HOME", "HELM_DATA_HOME")
        val env = keys.mapNotNull { key -> System.getenv(key)?.let { key to it } }.toMap(LinkedHashMap())
        env["CONFIG_ROOT"] = configRoot.absolutePath
        helmCli.get().takeUnless { it == "auto" || it == "none" }?.let { env["HELM_BIN"] = it }
        return env
    }

    /**
     * An executable on the build's current PATH. A long-lived daemon resolves bare names with the PATH it was
     * started with, so a tool installed since (kubeconform, helm) is looked up here instead.
     */
    private fun onPath(name: String): String? =
        System.getenv("PATH").orEmpty().split(File.pathSeparator).filter { it.isNotEmpty() }
            .map { File(it, name) }.firstOrNull { it.isFile && it.canExecute() }?.absolutePath

    private fun helmVersion(): String? {
        val choice = helmCli.get()
        if (choice == "none") return null
        val binary = (if (choice == "auto") onPath("helm") else choice) ?: return null
        return exec(listOf(binary, "version", "--template", "{{.Version}}")).takeIf { it.exitCode == 0 }?.output?.trim()
    }

    @TaskAction
    fun lint() {
        val compose = composeCommand()
        // A controlled environment: the developer's shell must not leak IMAGE_TAG & co. into the render.
        val baseEnv = listOf("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR", "CONTAINERS_CONF")
            .mapNotNull { key -> System.getenv(key)?.let { key to it } }.toMap()
        val renderer = compose?.let { cmd ->
            ComposeRenderer { request ->
                exec(
                    cmd + listOf("-p", request.project, "--env-file", request.envFile.path) +
                        request.composeFiles.flatMap { listOf("-f", it.path) } + listOf("config", "--quiet"),
                    baseEnv + request.environment,
                )
            }
        }
        // Check 12: helm lint / template through the deploy script, kubeconform when it is on the PATH.
        val configRoot = configDir.get().asFile
        val script = helmScript.get().asFile
        val helmEnv = helmEnvironment(configRoot)
        val helmRunner = if (helmCli.get() == "none") null else HelmRunner { r ->
            exec(listOf("bash", script.path, r.env, r.flow, r.app, r.instance, "--tag", r.tag, "--mode", r.mode.flag,
                "--chart", r.chart.path) + (r.renderOut?.let { listOf("--render-out", it.path) } ?: emptyList()), helmEnv)
        }
        val kubeconform = onPath("kubeconform")?.takeIf { exec(listOf(it, "-v")).exitCode == 0 }
        val validator = kubeconform?.let { cmd ->
            ManifestValidator { file ->
                exec(listOf(cmd, "-strict", "-ignore-missing-schemas", "-kubernetes-version", ConfigRules.KUBERNETES_VERSION,
                    "-summary", "-output", "json", file.path))
            }
        }
        val rendered = renderDir.get().asFile.apply { deleteRecursively(); mkdirs() }
        val scope = LintScope(
            regions = regions.get().toSet(),
            stages = stages.get().toSet(),
            flows = flows.get().toSet(),
            kinds = kinds.get().toSet(),
            envs = devEnvs.get().toSet(),
            propertyPrefixes = propertyPrefixes.get(),
            secretProperties = secretProperties.get(),
        )
        val linter = ConfigLinter(
            configRoot = configRoot,
            apps = apps.get(),
            scope = scope,
            template = template.orNull?.asFile,
            appOverrides = appOverrides.get().mapValues { File(it.value) },
            completeEnvs = completeEnvs.get(),
            renderer = renderer ?: ComposeRenderer { null },
            requireRender = requireRender.get(),
            charts = charts.get().mapValues { File(it.value) },
            helm = helmRunner,
            validator = validator,
            renderDir = rendered,
        )
        val findings = linter.lint()
        val errors = findings.count { it.severity == Severity.ERROR }
        val warnings = findings.count { it.severity == Severity.WARN }
        // Without helm in platform.yml kinds the Helm checks are skipped, and the summary says so once (ADR-0036).
        val helmChecks = if (scope.helmEnabled) {
            ", helm ${helmVersion() ?: "none"}, kubeconform ${if (kubeconform != null) "yes" else "none"}"
        } else {
            "; Helm checks skipped (platform.yml kinds: ${kinds.get().joinToString()}): no chart or _helm-values file " +
                "required, no helm lint / helm template / kubeconform (ADR-0036)"
        }
        val header = "config-lint: ${findings.size} finding(s): $errors error(s), $warnings warning(s); " +
            "render with ${compose?.joinToString(" ") ?: "no compose CLI"}$helmChecks"
        val report = (listOf(header) + findings.map { it.toString() }).joinToString("\n", postfix = "\n")
        reportFile.get().asFile.apply { parentFile.mkdirs() }.writeText(report)
        findings.forEach { if (it.severity == Severity.ERROR) logger.error(it.toString()) else logger.lifecycle(it.toString()) }
        logger.lifecycle(header)
        if (errors > 0) throw GradleException("config-lint found $errors error(s); report: ${reportFile.get().asFile}")
    }
}
