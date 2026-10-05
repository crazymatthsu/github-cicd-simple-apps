package buildlogic

import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.artifacts.MinimalExternalModuleDependency
import org.gradle.api.artifacts.VersionCatalog
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.api.provider.Provider
import org.gradle.kotlin.dsl.getByType

/** Access to `gradle/libs.versions.toml` from precompiled script plugins (no type-safe accessors there). */
internal val Project.catalog: VersionCatalog
    get() = extensions.getByType<VersionCatalogsExtension>().named("libs")

internal fun Project.catalogLibrary(alias: String): Provider<MinimalExternalModuleDependency> =
    catalog.findLibrary(alias).orElseThrow { IllegalStateException("libs.versions.toml has no library '$alias'") }

/** Extra property written by the buildlogic.git-version settings plugin, with a fallback. */
internal fun Project.buildlogicProperty(name: String, fallback: String): String =
    (findProperty("buildlogic.$name") as String?)?.takeIf { it.isNotBlank() } ?: fallback

/** A project value of platform.yml, handed over by the buildlogic.platform settings plugin (ADR-0030). */
internal fun Project.platformValue(key: String): String =
    (findProperty("buildlogic.platform.$key") as String?)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("buildlogic.platform.$key is not set: settings.gradle.kts must apply the " +
            "buildlogic.platform settings plugin, which reads platform.yml (ADR-0030)")

/** A list value of platform.yml (see [platformValue]). */
internal fun Project.platformList(key: String): List<String> = platformValue(key).split(',').filter { it.isNotBlank() }
