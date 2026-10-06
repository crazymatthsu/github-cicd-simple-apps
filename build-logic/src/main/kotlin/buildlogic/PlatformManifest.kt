package buildlogic

import org.gradle.api.GradleException
import org.gradle.api.IsolatedAction
import org.gradle.api.Project
import org.gradle.api.initialization.Settings
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.Serializable

/**
 * The repository manifest `platform.yml` (ADR-0030): every project value the shared tooling needs and the tree
 * cannot derive. Parsed and validated once per build by the `buildlogic.platform` settings plugin
 * ([PlatformSettings]); scripts and workflows read the same file.
 */
data class PlatformManifest(
    val platform: String,
    val kind: String,
    val registry: String,
    val project: String,
    val group: String,
    val appsDir: String,
    val kinds: List<String>,
    val referenceApp: String, // "" without reference_app: no reference scenario (ADR-0035)
    val devEnvs: List<String>, // empty for dev_envs: []: no env is deployed (ADR-0035)
    val regions: List<String>,
    val stages: List<String>,
    val flows: List<String>,
    /** The apps' own configuration roots (ADR-0042): the summary shows them, no env layer sets them. */
    val propertyPrefixes: List<String>,
    /** The project's secret properties (ADR-0042); may be empty, Spring's datasource names are built in. */
    val secretProperties: List<String>,
) : Serializable {
    companion object {
        const val FILE = "platform.yml"
        const val DEV_STAGE = "dev"
        val KINDS = setOf("compose", "helm")
        /** The keys that scripts read without a YAML parser: each a one-line flow sequence at the top level. */
        val LINE_LISTS = listOf("dev_envs", "regions", "stages", "flows", "property_prefixes", "secret_properties")

        private const val serialVersionUID = 1L
        private val TOKEN = Regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
        private val REGION = Regex("^[a-z]{2}$")
        /** One word: an env is `<region>-<stage>`, and the charts' schemas check that shape. */
        private val STAGE = Regex("^[a-z0-9]+$")
        /**
         * A Java package name of lower-case words: the group also prefixes every label (ADR-0041), as
         * `<group>.<name>` on an image or a compose resource and, reversed, as the domain of a Kubernetes label key.
         */
        private val GROUP = Regex("^[a-z][a-z0-9]{0,62}(\\.[a-z][a-z0-9]{0,62})*$")
        private val REGISTRY = Regex("^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)*$")
        private val DIRECTORY = Regex("^[a-z0-9][a-z0-9._-]*$")
        /**
         * A Spring property name in canonical form (ADR-0042): dotted lower-case kebab-case segments, the first one
         * starting with a letter, so that its environment-variable form is a valid variable name.
         */
        private val PROPERTY = Regex("^[a-z]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$")

        /** Parses and validates [text]; every problem is reported at once. */
        fun parse(text: String): PlatformManifest {
            val problems = mutableListOf<String>()
            val root = try {
                Yaml(SafeConstructor(LoaderOptions())).load<Any?>(text)
            } catch (e: Exception) {
                throw IllegalArgumentException("$FILE does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            }
            if (root !is Map<*, *>) throw IllegalArgumentException("$FILE must be a mapping")

            fun string(map: Map<*, *>, key: String, where: String, pattern: Regex? = null): String {
                val value = map[key]
                if (value !is String || value.isBlank()) {
                    problems += "$where$key is required (a string)"
                    return ""
                }
                if (pattern != null && !pattern.matches(value)) problems += "$where$key '$value' is not valid"
                return value
            }

            fun list(map: Map<*, *>, key: String, where: String, pattern: Regex, mayBeEmpty: Boolean = false): List<String> {
                val value = map[key]
                if (value !is List<*> || (value.isEmpty() && !mayBeEmpty)) {
                    problems += "$where$key is required (a ${if (mayBeEmpty) "" else "non-empty "}list)"
                    return emptyList()
                }
                val items = value.map { it?.toString().orEmpty() }
                items.filterNot { pattern.matches(it) }.forEach { problems += "$where$key: '$it' is not valid" }
                items.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
                    .forEach { problems += "$where$key: '$it' is listed twice" }
                return items
            }

            val platform = string(root, "platform", "")
            val kind = string(root, "kind", "")
            if (kind.isNotEmpty() && kind != "app") {
                problems += "kind '$kind' is not supported: only `app` repositories exist so far (ADR-0030)"
            }
            val registry = string(root, "registry", "", REGISTRY)
            val projects = root["projects"]
            val project = if (projects is List<*> && projects.size == 1 && projects[0] is Map<*, *>) {
                projects[0] as Map<*, *>
            } else {
                problems += "projects must list exactly one project: one repository is one project (ADR-0002)"
                emptyMap<String, Any>()
            }
            val name = string(project, "name", "projects[0].", TOKEN)
            val group = string(project, "group", "projects[0].")
            if (group.isNotEmpty() && (!GROUP.matches(group) || group.length > 253)) {
                problems += "projects[0].group '$group' is not valid: lower-case words of letters and digits, each starting " +
                    "with a letter, joined by dots (e.g. com.acme.payments); every label prefix derives from it (ADR-0041)"
            }
            val appsDir = string(project, "apps_dir", "projects[0].", DIRECTORY)
            val kinds = list(project, "kinds", "projects[0].", TOKEN)
            (kinds - KINDS).forEach { problems += "projects[0].kinds: '$it' is not a runtime (${KINDS.sorted().joinToString()})" }
            // Optional (ADR-0035): without the key there is no reference scenario; a key that is present names an app.
            val referenceApp = if (project.containsKey("reference_app")) string(project, "reference_app", "projects[0].", TOKEN) else ""
            val regions = list(root, "regions", "", REGION)
            val stages = list(root, "stages", "", STAGE)
            if (stages.isNotEmpty() && DEV_STAGE !in stages) problems += "stages must include `$DEV_STAGE`"
            val flows = list(root, "flows", "", TOKEN)
            // [] is valid (ADR-0035): the repository deploys no env yet.
            val devEnvs = list(root, "dev_envs", "", Regex("^[a-z]{2}-$DEV_STAGE$"), mayBeEmpty = true)
            devEnvs.filter { it.substringBefore('-') !in regions }
                .forEach { problems += "dev_envs: '$it' is not in a region of `regions`" }
            // ADR-0042: the apps' own configuration roots, and the project's secret properties. [] is valid for the
            // secrets: Spring's datasource names and the secret-looking segments are built into the tools.
            val propertyPrefixes = list(root, "property_prefixes", "", PROPERTY)
            val secretProperties = list(root, "secret_properties", "", PROPERTY, mayBeEmpty = true)
            // Scripts read these keys with awk, not a YAML parser (run-compose.sh runs on hosts without yq): one line
            // at the top level, unquoted words, dotted ones for the property names (`[]` too: whether a list may be
            // empty, and which words it may hold, is checked above).
            for (key in LINE_LISTS) {
                val line = Regex("^$key:[ \\t]*\\[[ \\t]*([a-z0-9.-]+([ \\t]*,[ \\t]*[a-z0-9.-]+)*)?[ \\t]*\\][ \\t]*(#.*)?$")
                if (text.lineSequence().none { line.matches(it) }) {
                    problems += "$key must be a one-line list of unquoted words at the top level, e.g. `$key: [a, b]` " +
                        "(scripts read it without a YAML parser)"
                }
            }
            // setup-build-env reads the registry without a YAML parser too (a job container may lack yq).
            if (text.lineSequence().none { Regex("^registry:[ \\t]+[a-z0-9.:/_-]+[ \\t]*(#.*)?$").matches(it) }) {
                problems += "registry must be an unquoted value on one top-level line, e.g. `registry: ghcr.io/acme` " +
                    "(read without a YAML parser)"
            }
            // The scripts read the group without a YAML parser too (ADR-0041): the first `group:` line, unquoted.
            val groupKey = Regex("^[ \\t]*(-[ \\t]+)?group:")
            val groupLine = text.lineSequence().firstOrNull { groupKey.containsMatchIn(it) }
            if (group.isNotEmpty() && groupLine?.replace(groupKey, "")?.substringBefore('#')?.trim() != group) {
                problems += "projects[0].group must be an unquoted value on a line of its own, the first `group:` line, " +
                    "e.g. `    group: com.acme.payments` (read without a YAML parser)"
            }
            if (problems.isNotEmpty()) {
                throw IllegalArgumentException("$FILE is not valid (ADR-0030):\n" + problems.joinToString("\n") { "  - $it" })
            }
            return PlatformManifest(platform, kind, registry, name, group, appsDir, kinds, referenceApp, devEnvs, regions,
                stages, flows, propertyPrefixes, secretProperties)
        }
    }

    /**
     * Why `reference_app` does not fit the modules found ([modules]: name to parent directory), or null. No reference
     * app is valid (ADR-0035); one that is declared must be an app under `apps_dir` (ADR-0030).
     */
    fun referenceAppProblem(modules: Map<String, String>): String? =
        if (referenceApp.isEmpty() || modules[referenceApp] == appsDir) null
        else "$FILE: reference_app '$referenceApp' is not an app under $appsDir/ (ADR-0030)"
}

/** What every project receives as `buildlogic.platform.<key>` extra properties (lists comma-separated). */
fun PlatformManifest.asProperties(): Map<String, String> = linkedMapOf(
    "registry" to registry,
    "project" to project,
    "group" to group,
    "appsDir" to appsDir,
    "kinds" to kinds.joinToString(","),
    "referenceApp" to referenceApp,
    "devEnvs" to devEnvs.joinToString(","),
    "regions" to regions.joinToString(","),
    "stages" to stages.joinToString(","),
    "flows" to flows.joinToString(","),
    "propertyPrefixes" to propertyPrefixes.joinToString(","),
    "secretProperties" to secretProperties.joinToString(","),
)

/** Hands the manifest to every project before its build script runs (an isolated action: plain data only). */
class ApplyPlatform(private val properties: Map<String, String>) : IsolatedAction<Project> {
    override fun execute(project: Project) {
        val extra = project.extensions.extraProperties
        properties.forEach { (key, value) -> extra["buildlogic.platform.$key"] = value }
    }
}

/** Entry point of the `buildlogic.platform` settings plugin (ADR-0030). */
object PlatformSettings {
    fun apply(settings: Settings) {
        val providers = settings.providers
        val text = providers.fileContents(settings.layout.rootDirectory.file(PlatformManifest.FILE)).asText.orNull
            ?: throw GradleException("${PlatformManifest.FILE} not found at the repository root: it holds the project values (ADR-0030)")
        val manifest = try {
            PlatformManifest.parse(text)
        } catch (e: IllegalArgumentException) {
            throw GradleException(e.message ?: "${PlatformManifest.FILE} is not valid", e)
        }

        // ADR-0002 rule 2: the repository name, rootProject.name and the project of the manifest are one string.
        settings.rootProject.name = manifest.project
        val repository = providers.environmentVariable("GITHUB_REPOSITORY").orNull?.substringAfter('/')
        if (repository != null && repository != manifest.project) {
            throw GradleException("The repository is '$repository' but ${PlatformManifest.FILE} names the project " +
                "'${manifest.project}': they must be equal (ADR-0002)")
        }

        // Modules (ADR-0006): every directory under apps_dir and framework/ that holds a build.gradle.kts is a
        // top-level project named after its directory. Adding a module is a directory, never an edit here.
        val modules = mutableMapOf<String, String>()
        for (parent in listOf(manifest.appsDir, "framework")) {
            settings.rootDir.resolve(parent).listFiles { file -> file.isDirectory && file.resolve("build.gradle.kts").isFile }
                ?.sortedBy { it.name }
                ?.forEach { dir ->
                    modules.put(dir.name, parent)?.let { other ->
                        throw GradleException("Module '${dir.name}' exists in both $other/ and $parent/: project names must be unique (ADR-0006)")
                    }
                    settings.include(dir.name)
                    settings.project(":${dir.name}").projectDir = dir
                }
        }
        manifest.referenceAppProblem(modules)?.let { throw GradleException(it) }
        settings.gradle.lifecycle.beforeProject(ApplyPlatform(manifest.asProperties()))
    }
}
