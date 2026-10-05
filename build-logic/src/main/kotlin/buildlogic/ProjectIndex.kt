package buildlogic

import org.gradle.api.GradleException
import org.gradle.api.Project

/**
 * CI reads the projects from the build files, before Gradle runs (scripts/ci/projects.py, ADR-0031): a project produces
 * an image when its build file applies `buildlogic.docker-image`, and joins the integration-test matrix when it applies
 * `buildlogic.integration-test`. This is that reading, and the plugins use it to refuse being applied anywhere else.
 */
object ProjectIndex {
    private val BLOCK_COMMENT = Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL)

    /** Whether [buildFileText] applies `id("<pluginId>")`, comments ignored, as projects.py reads it. */
    fun applies(buildFileText: String, pluginId: String): Boolean {
        val code = BLOCK_COMMENT.replace(buildFileText, "").lines().joinToString("\n") { it.substringBefore("//") }
        return Regex("\\bid\\(\\s*\"" + Regex.escape(pluginId) + "\"\\s*\\)").containsMatchIn(code)
    }
}

/**
 * Fails the build unless this project's own build file applies [pluginId] in its plugins block. A plugin applied
 * through another plugin would build an image, or integration tests, that CI never runs, publishes or releases.
 */
internal fun Project.requireAppliedInBuildFile(pluginId: String) {
    val buildFile = layout.projectDirectory.file("build.gradle.kts")
    val text = providers.fileContents(buildFile).asText.orNull.orEmpty()
    if (!ProjectIndex.applies(text, pluginId)) {
        throw GradleException("$path applies $pluginId, but its build.gradle.kts does not: CI derives the image and " +
            "integration-test projects from the build files (scripts/ci/projects.py, ADR-0031), so apply it in the " +
            "project's own plugins block, never through another plugin")
    }
}
