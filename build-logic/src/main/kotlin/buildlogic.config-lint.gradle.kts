// `buildlogic.config-lint` (ADR-0014): root task `configLint` over the config/ tree. Checks 1–6 and 9–12
// run here; 7 (merged configuration vs spring-configuration-metadata.json) and 8 (parity across envs) are
// reported as TODO. A deployable app is a subproject that applies `buildlogic.docker-image` (ADR-0012: every app is
// run from the one compose template docker/docker-compose.yml, plus its optional
// <subproject>/docker/docker-compose.override.yml); its name is the AppName directory expected in the tree, and its
// Helm chart is <subproject>/helm/<AppName>/Chart.yaml (ADR-0019). The Helm checks run only when platform.yml
// kinds includes helm (ADR-0036).
//
//   ./gradlew configLint                      # render check 6 with docker compose / podman compose if present,
//                                             # check 12 with helm (and kubeconform) if present
//   -PconfigLint.compose=none|docker|podman   # choose or disable the compose CLI for check 6
//   -PconfigLint.helm=auto|none|<path>        # Helm 4 for check 12: from the PATH, off, or this binary
//   -PconfigLint.requireRender=true           # fail when no compose CLI / Helm 4 exists (default when CI=true)
//   -PconfigLint.completeEnvs=local           # envs in which every deployable app must have configuration and a chart
//                                             # (a chart only when kinds includes helm)
//
// Check 12 runs scripts/helm-deploy-instance.sh --mode lint and --mode template per instance and keeps the
// manifests in build/reports/config-lint/rendered/<env>/<flow>/<AppName>/<AppInstance>.yaml; kubeconform
// (-strict, Kubernetes 1.37.0) validates them when it is on the PATH.
import buildlogic.ConfigLintTask
import buildlogic.platformList

// Evaluated lazily, once every subproject is configured: whether a subproject applies the plugin is known only then.
val deployableApps: Provider<List<Project>> = provider {
    subprojects.filter { it.pluginManager.hasPlugin("buildlogic.docker-image") }.sortedBy { it.name }
}
val overrideFiles: Provider<Map<String, File>> = deployableApps.map { projects ->
    projects.associate { it.name to it.projectDir.resolve("docker/docker-compose.override.yml") }
        .filterValues { it.isFile }
}
val appCharts: Provider<Map<String, File>> = deployableApps.map { projects ->
    projects.associate { it.name to it.projectDir.resolve("helm/${it.name}") }
        .filterValues { it.resolve("Chart.yaml").isFile }
}

tasks.register<ConfigLintTask>("configLint") {
    group = "verification"
    description = "Lints the config/ tree (ADR-0014 checks 1–6, 9–12; 7–8 TODO)."
    configDir = layout.projectDirectory.dir("config")
    apps = deployableApps.map { projects -> projects.map { it.name }.toSet() }
    // The vocabulary, runtimes and dev envs of platform.yml (ADR-0030): names are checked against them, and an env
    // other than local and the dev envs does not belong in this repository (ADR-0004).
    regions = platformList("regions")
    stages = platformList("stages")
    flows = platformList("flows")
    kinds = platformList("kinds")
    devEnvs = platformList("devEnvs")
    template = layout.projectDirectory.file("docker/docker-compose.yml")
    appOverrides = overrideFiles.map { files -> files.mapValues { it.value.absolutePath } }
    appOverrideFiles.from(overrideFiles.map { it.values })
    completeEnvs = providers.gradleProperty("configLint.completeEnvs")
        .map { it.split(',').map(String::trim).filter(String::isNotEmpty).toSet() }
        .orElse(setOf("local"))
    composeCli = providers.gradleProperty("configLint.compose").orElse("auto")
    requireRender = providers.gradleProperty("configLint.requireRender").map { it.toBoolean() }
        .orElse(providers.environmentVariable("CI").map { it == "true" })
        .orElse(false)
    reportFile = layout.buildDirectory.file("reports/config-lint/config-lint.txt")
    charts = appCharts.map { files -> files.mapValues { it.value.absolutePath } }
    chartFiles.from(appCharts.map { it.values })
    helmCli = providers.gradleProperty("configLint.helm").orElse("auto")
    helmScript = layout.projectDirectory.file("scripts/helm-deploy-instance.sh")
    renderDir = layout.buildDirectory.dir("reports/config-lint/rendered")
}
