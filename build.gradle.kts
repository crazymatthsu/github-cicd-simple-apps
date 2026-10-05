// Root project: aggregate tasks only (ADR-0007). Conventions live in build-logic/, never here.
//
//   ./gradlew build                 compile, unit tests, coverage floor, bootJar (no ITs, no images)
//   ./gradlew configLint            lint the config/ tree (ADR-0014)
//   ./gradlew -q printVersion       project.version from git (ADR-0008)
//   ./gradlew buildImages           buildImage of every app (ADR-0009)
//   ./gradlew pushImages            pushImage of the same, tags from ADR-0010 (never a local build)
//   ./gradlew integrationTest       every app's compose lifecycle + ITs, one stack at a time (ADR-0025)
//   ./gradlew devUp / devDown       the local dependency stack (ADR-0025)
plugins {
    base
    id("buildlogic.config-lint")
}

/** Every subproject task with this name, resolved once all projects are configured. */
fun subprojectTasks(taskName: String) = provider { subprojects.mapNotNull { it.tasks.findByName(taskName) } }

tasks.register("buildImages") {
    group = "container image"
    description = "Builds the image of every app."
    dependsOn(subprojectTasks("buildImage"))
}

tasks.register("pushImages") {
    group = "container image"
    description = "Pushes every image with the tags of this build (ADR-0010)."
    dependsOn(subprojectTasks("pushImage"))
}

tasks.register("integrationTest") {
    group = "verification"
    description = "Runs every app's integration tests with its compose stack (not part of check)."
    dependsOn(subprojectTasks("integrationTest"))
}

tasks.register("devUp") {
    group = "integration test"
    description = "Starts the local dependency stack of every app (compose project local-dev)."
    dependsOn(subprojectTasks("devUp"))
}

tasks.register("devDown") {
    group = "integration test"
    description = "Stops the local dependency stack."
    dependsOn(subprojectTasks("devDown"))
}

tasks.register("printVersion") {
    group = "help"
    description = "Prints project.version derived from git (ADR-0008): the repository's one release line."
    val value = version.toString() // a local copy: the action must not capture the script (configuration cache)
    inputs.property("version", value)
    doLast { println(value) }
}

// The build-logic tests (version scheme, config-lint rules, engine detection) are part of `check`.
tasks.named("check") { dependsOn(gradle.includedBuild("build-logic").task(":check")) }

// Gradle-managed stacks publish the same localhost ports (local-ports.yml): the apps' compose lifecycles
// run one after another, never side by side, even with --parallel.
gradle.projectsEvaluated {
    subprojects.filter { it.plugins.hasPlugin("buildlogic.integration-test") }.sortedBy { it.path }
        .zipWithNext { previous, next ->
            next.tasks.named("composeUp") { mustRunAfter(previous.tasks.named("composeDown")) }
            next.tasks.named("devUp") { mustRunAfter(previous.tasks.named("devUp")) }
            next.tasks.named("devDown") { mustRunAfter(previous.tasks.named("devDown")) }
        }
}
