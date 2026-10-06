// `buildlogic.integration-test` (ADR-0007, ADR-0025, ADR-0038): every app with integration tests. It declares
// nothing about the project's dependencies: an app adds the test clients its tests use, and the stacks publish
// their endpoints and secrets through stacks.yml.
//
// - `integrationTest`: a JVM Test Suite with its own source set (src/integrationTest/java), never wired into
//   `check` (check only compiles it so it cannot rot).
// - `composeUp` / `composeDown`: Exec tasks calling the same script as the workflows,
//   `test-infra/compose/stack.sh up --project <gradle path> --local` and `stack.sh down --project <path>`;
//   integrationTest dependsOn composeUp and is finalizedBy composeDown, so the stack also goes down on failure.
//   The app image under test is built first (buildImage) and passed as APP_IMAGE. The tests run on the host JVM
//   with what the stacks publish to it (.state/<project>.host.env, written by stack.sh up), the app's actuator on
//   localhost and IT_TABLE_PREFIX.
//   `-Pcompose.managed=false` (CI: the workflow owns the stack and runs the tests in it-runner, whose
//   environment then applies unchanged) removes all of this from the graph; `-Pcompose.keep=true` keeps the
//   stack up for debugging.
// - `devUp` / `devDown`: the dependency stack for local work (ADR-0025), compose project `local-dev`
//   (or $COMPOSE_PROJECT_NAME) shared by every app, so one network serves `run-compose.sh local ...`.
import buildlogic.ComposeStackLock
import buildlogic.StackEnv
import buildlogic.buildlogicProperty
import buildlogic.catalogLibrary
import buildlogic.requireAppliedInBuildFile

plugins {
    id("buildlogic.java-conventions")
    `jvm-test-suite`
}

// CI knows the integration-test projects from their build files (ADR-0031): this plugin is applied there and nowhere else.
requireAppliedInBuildFile("buildlogic.integration-test")

val springBootBom = catalogLibrary("spring-boot-dependencies")
val junitJupiter = catalogLibrary("junit-jupiter")
val junitLauncher = catalogLibrary("junit-platform-launcher")

testing {
    suites {
        register<JvmTestSuite>("integrationTest") {
            useJUnitJupiter()
            dependencies {
                implementation(project())
                implementation(platform(springBootBom))
                implementation(junitJupiter)
                runtimeOnly(junitLauncher)
            }
            targets.all {
                testTask.configure {
                    description = "Runs src/integrationTest against the compose stack (ADR-0025); not part of check."
                    shouldRunAfter(tasks.named("test"))
                    // The stack is external state: never up-to-date, never from the build cache.
                    outputs.upToDateWhen { false }
                    outputs.cacheIf { false }
                }
            }
        }
    }
}

// check compiles the integration tests (no containers needed) but never runs them.
tasks.named("check") { dependsOn(tasks.named("integrationTestClasses")) }

val projectPath: String = path
val appName: String = name
val stackScript: File = rootDir.resolve("test-infra/compose/stack.sh")
val managed = providers.gradleProperty("compose.managed").map { it.toBoolean() }.orElse(true).get()
val keepStack = providers.gradleProperty("compose.keep").map { it.toBoolean() }.orElse(false).get()
val devProjectName = providers.environmentVariable("COMPOSE_PROJECT_NAME").orElse("local-dev")
val tablePrefixDefault = "it_${buildlogicProperty("gitSha7", "local")}_"
val stackLock = gradle.sharedServices.registerIfAbsent("composeStackLock", ComposeStackLock::class) {
    maxParallelUsages = 1
}
val imageRefsFile = layout.buildDirectory.file("image/refs.txt")

fun Exec.stackCommand(vararg args: String) {
    group = "integration test"
    workingDir = rootDir
    commandLine(listOf("bash", stackScript.path) + args.toList())
    usesService(stackLock)
    val script = stackScript
    doFirst {
        if (!script.isFile) {
            throw GradleException(
                "$script not found: the dependency stacks live in test-infra/compose/ (ADR-0025). " +
                    "Run with -Pcompose.managed=false when the stack is started elsewhere.",
            )
        }
    }
}

val composeUp = tasks.register<Exec>("composeUp") {
    description = "Starts this subproject's test stack: stack.sh up --project $projectPath --local."
    stackCommand("up", "--project", projectPath, "--local")
    val refs = imageRefsFile
    val prefix = tablePrefixDefault
    doFirst {
        val exec = this as Exec
        exec.environment("IT_TABLE_PREFIX", System.getenv("IT_TABLE_PREFIX") ?: prefix)
        // The app image built by buildImage in this build (tag `local`), unless the caller chose one.
        val refsFile = refs.get().asFile
        if (System.getenv("APP_IMAGE").isNullOrBlank() && refsFile.isFile) {
            refsFile.readLines().firstOrNull { it.isNotBlank() }?.let { exec.environment("APP_IMAGE", it) }
        }
    }
}

val composeDown = tasks.register<Exec>("composeDown") {
    description = "Stops this subproject's test stack and removes its volumes: stack.sh down --project $projectPath."
    stackCommand("down", "--project", projectPath)
}

if (managed) {
    tasks.named<Test>("integrationTest") {
        dependsOn(composeUp)
        if (!keepStack) finalizedBy(composeDown)
        val prefix = tablePrefixDefault
        // What composeUp recorded (stack.sh up): the state file (the app image under test, the actuator port that
        // the app publishes) and what the stacks publish to a JVM on the host. The project name follows stack.sh:
        // COMPOSE_PROJECT_NAME, else local-<app>.
        val stateBase = rootDir.resolve(
            "test-infra/compose/.state/" +
                (System.getenv("COMPOSE_PROJECT_NAME")?.takeIf { it.isNotBlank() } ?: "local-$appName"),
        ).path
        val stateFile = File("$stateBase.env")
        val hostEnvFile = File("$stateBase.host.env")
        doFirst {
            if (!hostEnvFile.isFile) {
                throw GradleException("$hostEnvFile is missing: composeUp (stack.sh up) writes it (ADR-0038).")
            }
            val state = StackEnv.read(stateFile)
            // The tests run on this JVM: the stacks' endpoints on the ports local-ports.yml publishes, and their
            // secrets, as stacks.yml declares them (env, with local_env).
            val env = StackEnv.read(hostEnvFile).toMutableMap()
            env["IT_TABLE_PREFIX"] = System.getenv("IT_TABLE_PREFIX") ?: prefix
            // The app under test (ADR-0025), when the stack includes it: its actuator on the published port.
            val appImage = System.getenv("APP_IMAGE")?.takeIf { it.isNotBlank() } ?: state["APP_IMAGE"]
            if (appImage != null) {
                env["APP_IMAGE"] = appImage
                env["IT_APP_HOST"] = "localhost"
                (System.getenv("ACTUATOR_HOST_PORT")?.takeIf { it.isNotBlank() } ?: state["ACTUATOR_HOST_PORT"])
                    ?.let { env["IT_APP_PORT"] = it }
            }
            (this as Test).environment(env)
        }
    }
    composeDown.configure { mustRunAfter(tasks.named("integrationTest")) }
    // Component ITs exercise the app image (ADR-0025): build it first when this project has one.
    plugins.withId("buildlogic.docker-image") {
        composeUp.configure { dependsOn(tasks.named("buildImage")) }
    }
}

tasks.register<Exec>("devUp") {
    description = "Starts the dependency stack for local development (ADR-0025): stack.sh up --project $projectPath --local."
    stackCommand("up", "--project", projectPath, "--local")
    val composeProject = devProjectName.get()
    environment("COMPOSE_PROJECT_NAME", composeProject)
    doLast {
        logger.lifecycle(
            "Dependencies are up (compose project $composeProject; the stacks' variables, generated secrets " +
                "included, are in test-infra/compose/.state/$composeProject.env). Run an app against them with, e.g.:\n" +
                "  DEPS_NETWORK=${composeProject}_default scripts/run-compose.sh local <flow> $appName <AppInstance> start",
        )
    }
}

tasks.register<Exec>("devDown") {
    description = "Stops the local dependency stack: stack.sh down."
    stackCommand("down")
    environment("COMPOSE_PROJECT_NAME", devProjectName.get())
}
