// Root settings (ADR-0006, ADR-0007, ADR-0008).
//
// Repositories: public repositories when ARTIFACTORY_URL is unset (the demo on GitHub-hosted runners),
// the JFrog virtual repositories when it is set (the enterprise). Credentials only ever come from the
// environment (ARTIFACTORY_USER / ARTIFACTORY_TOKEN), never from a file. No subproject declares a
// repository of its own (FAIL_ON_PROJECT_REPOS).

pluginManagement {
    includeBuild("build-logic")
    repositories {
        val artifactoryUrl = providers.environmentVariable("ARTIFACTORY_URL").orNull
        if (artifactoryUrl.isNullOrBlank()) {
            gradlePluginPortal()
            mavenCentral()
        } else {
            maven {
                name = "artifactoryPlugins"
                url = uri("${artifactoryUrl.trimEnd('/')}/" +
                    providers.environmentVariable("ARTIFACTORY_PLUGINS_REPO").getOrElse("gradle-plugins-virtual"))
                credentials {
                    username = providers.environmentVariable("ARTIFACTORY_USER").orNull
                    password = providers.environmentVariable("ARTIFACTORY_TOKEN").orNull
                }
            }
        }
    }
}

plugins {
    // Reads platform.yml: names the root project, includes every module under its apps_dir and framework/, and
    // hands the project values to every project (ADR-0030).
    id("buildlogic.platform")
    // Computes project.version from git for every project (ADR-0008); -Pversion=... overrides it.
    id("buildlogic.git-version")
}

dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        val artifactoryUrl = providers.environmentVariable("ARTIFACTORY_URL").orNull
        if (artifactoryUrl.isNullOrBlank()) {
            mavenCentral()
        } else {
            maven {
                name = "artifactoryLibs"
                url = uri("${artifactoryUrl.trimEnd('/')}/" +
                    providers.environmentVariable("ARTIFACTORY_LIBS_REPO").getOrElse("libs-virtual"))
                credentials {
                    username = providers.environmentVariable("ARTIFACTORY_USER").orNull
                    password = providers.environmentVariable("ARTIFACTORY_TOKEN").orNull
                }
            }
        }
    }
}

// No project value lives here: rootProject.name is platform.yml's project, and the modules are the directories under
// its apps_dir and framework/ that hold a build.gradle.kts (buildlogic.platform, ADR-0006, ADR-0030). Adding an app is
// a directory, never an edit here.
