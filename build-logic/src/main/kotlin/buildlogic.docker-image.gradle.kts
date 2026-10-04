// `buildlogic.docker-image` (D1 §6.4, D3 §6.4–§6.7, D4 §6.2): buildImage, pushImage, printImageRef.
//
//   ./gradlew :source-database:buildImage      # docker buildx / podman build
//   ./gradlew -q :source-database:printImageRef
//
// ONE shared Dockerfile for every app (R-0007): the build context staged under build/docker/ holds exactly
// `Dockerfile` (docker/spring-boot.Dockerfile of the root), `entrypoint.sh` (docker/entrypoint.sh) and
// `application.jar` (bootJar), so the Dockerfile is generic and an app carries no image files of its own. A
// module-local docker/Dockerfile is a documented override, not the norm: when it exists it wins. By hand:
// `./gradlew :<AppName>:stageDockerContext`, then `docker buildx build build/docker` from the subproject.
// Tags come from buildlogic.git-version (D4 §6.2); labels and build args from project.version and git (D3 §6.5).
//
// Properties: -Pimage.registry (env IMAGE_REGISTRY, default ghcr.io/crazymatthsu), -Pimage.tags=a,b,
// -Pimage.engine=auto|docker|podman (env CONTAINER_ENGINE), -Pimage.requireEngine=true (default when CI=true),
// -Pimage.arg.BASE_IMAGE=<ref> (env BASE_IMAGE; -Pimage.arg.<ARG>=<ref> for any other build argument),
// -Pimage.extraArgs="--cache-from ...", -Pimage.allowLocalPush=true, -Pimage.sourceUrl=<repo url>,
// -Pimage.pushAttempts=3 (retries of a failed `push`; pushes of one build run one at a time, see ImagePushLock),
// -PpushConvenienceTags=false (pushImage leaves out the floating tags main / latest / X / X.Y, e.g. so that
// CI moves `main` only after the system test; the immutable version and sha-<sha7> tags are always pushed).
// Outputs for workflows: build/image/refs.txt (every reference built), build/image/digest.txt (after push).
import buildlogic.BuildImageTask
import buildlogic.DockerImageExtension
import buildlogic.ImagePushLock
import buildlogic.PrintImageRefTask
import buildlogic.PushImageTask
import buildlogic.buildlogicProperty
import org.gradle.api.provider.Provider

plugins {
    base
}

val image = extensions.create<DockerImageExtension>("dockerImage")
image.registry.convention(
    providers.gradleProperty("image.registry")
        .orElse(providers.environmentVariable("IMAGE_REGISTRY"))
        .orElse("ghcr.io/crazymatthsu"),
)
// Images are <registry>/<project>/<AppName> (D12 §6.7): the project is the release line — the parent Gradle
// path when an app is nested (the demo monorepo's :deephaven-connectors:source-kafka -> "deephaven-connectors"),
// else the root project, i.e. the repository (:source-kafka -> "github-cicd-simple-apps", platform.yml).
image.group.convention(path.removePrefix(":").split(':').dropLast(1).joinToString("/").ifEmpty { rootProject.name })
image.imageName.convention(name)
image.dockerfile.convention("Dockerfile")
image.baseImageArg.convention("BASE_IMAGE")

// Task properties only ever receive plain values or providers whose lambdas capture their own parameters:
// the configuration cache cannot serialise references to this script.
val githubServer: String? = providers.environmentVariable("GITHUB_SERVER_URL").orNull
val githubRepository: String? = providers.environmentVariable("GITHUB_REPOSITORY").orNull
val githubRunId: String? = providers.environmentVariable("GITHUB_RUN_ID").orNull
val sourceUrlValue: String = providers.gradleProperty("image.sourceUrl").orNull
    ?: if (githubServer != null && githubRepository != null) "$githubServer/$githubRepository"
    else "https://github.com/crazymatthsu/github-cicd-simple-apps"
val buildUrlValue: String = if (githubServer != null && githubRepository != null && githubRunId != null)
    "$githubServer/$githubRepository/actions/runs/$githubRunId" else "local"
val versionValue: String = version.toString()
val gitShaValue: String = buildlogicProperty("gitSha", "unknown")
val versionKindValue: String = buildlogicProperty("versionKind", "LOCAL")
val imageTagList: List<String> = providers.gradleProperty("image.tags").orNull
    ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
    ?: buildlogicProperty("imageTags", "local").split(',')

val repositoryRef: Provider<String> = image.registry.zip(image.group) { registry, group ->
    if (group.isBlank()) registry.trimEnd('/') else "${registry.trimEnd('/')}/$group"
}.zip(image.imageName) { prefix, imageName -> "$prefix/$imageName" }
val allImageRefs: Provider<List<String>> = repositoryRef.zip(providers.provider { imageTagList.toList() }) { repo, tags ->
    tags.map { "$repo:$it" }
}
val imageLabels: Provider<Map<String, String>> = image.imageName.zip(
    providers.provider {
        mapOf(
            "version" to versionValue, "sha" to gitShaValue, "kind" to versionKindValue.lowercase(),
            "source" to sourceUrlValue, "build" to buildUrlValue,
        )
    },
) { imageName, facts ->
    mapOf(
        "org.opencontainers.image.title" to imageName,
        "org.opencontainers.image.description" to "$imageName (github-cicd-simple-apps, Deephaven connectors)",
        "org.opencontainers.image.version" to facts.getValue("version"),
        "org.opencontainers.image.revision" to facts.getValue("sha"),
        "org.opencontainers.image.source" to facts.getValue("source"),
        "com.example.app" to imageName,
        "com.example.git-sha" to facts.getValue("sha").take(7),
        "com.example.build-url" to facts.getValue("build"),
        "com.example.version-kind" to facts.getValue("kind"),
    )
}
// -Pimage.arg.<ARG>=<ref>; for the apps' BASE_IMAGE also the environment variable BASE_IMAGE (CI exports the
// jre21 base it resolved or bootstrapped). Every other build argument comes from -Pimage.arg.<ARG> only: an
// environment variable of the same name may mean something else (DEEPHAVEN_IMAGE is test-infra's server image).
val argProperties: Provider<Map<String, String>> = providers.gradlePropertiesPrefixedBy("image.arg.")
val baseImageEnvironment: Provider<String> = providers.environmentVariable("BASE_IMAGE").orElse("")
val baseImageOverride: Provider<String> = image.baseImageArg.zip(argProperties.zip(baseImageEnvironment) { p, e -> p to e }) { arg, (props, env) ->
    props["image.arg.$arg"]?.takeIf { it.isNotBlank() } ?: if (arg == "BASE_IMAGE") env else ""
}
val engineChoiceProvider: Provider<String> = providers.gradleProperty("image.engine")
    .orElse(providers.environmentVariable("CONTAINER_ENGINE")).orElse("auto")
val requireEngineProvider: Provider<Boolean> = providers.gradleProperty("image.requireEngine").map { it.toBoolean() }
    .orElse(providers.environmentVariable("CI").map { it == "true" })
    .orElse(false)
val extraArgsProvider: Provider<List<String>> = providers.gradleProperty("image.extraArgs")
    .map { it.trim().split(Regex("\\s+")).filter(String::isNotEmpty) }
    .orElse(emptyList())

val sharedDockerfile = layout.settingsDirectory.file("docker/spring-boot.Dockerfile")
val sharedEntrypoint = layout.settingsDirectory.file("docker/entrypoint.sh")
val moduleDockerfile = layout.projectDirectory.file("docker/Dockerfile")
val dockerfileToUse = if (moduleDockerfile.asFile.exists()) moduleDockerfile else sharedDockerfile

val stageDockerContext = tasks.register<Sync>("stageDockerContext") {
    group = "container image"
    description = "Stages the minimal image build context (Dockerfile, entrypoint.sh, application.jar) under build/docker/."
    into(layout.buildDirectory.dir("docker"))
    from(dockerfileToUse) { rename { "Dockerfile" } }
    from(sharedEntrypoint)
}
plugins.withId("org.springframework.boot") {
    stageDockerContext.configure { from(tasks.named("bootJar")) { rename { "application.jar" } } }
}

val buildImage = tasks.register<BuildImageTask>("buildImage") {
    group = "container image"
    description = "Builds the image with docker buildx or podman build (no-op with a message when no engine is usable)."
    contextDir.fileProvider(stageDockerContext.map { it.destinationDir })
    dockerfile = image.dockerfile
    imageRefs = allImageRefs
    engineChoice = engineChoiceProvider
    requireEngine = requireEngineProvider
    baseImageArg = image.baseImageArg
    baseImage = baseImageOverride
    extraArgs = extraArgsProvider
    buildArgs = mapOf("APP_VERSION" to versionValue, "GIT_SHA" to gitShaValue, "BUILD_URL" to buildUrlValue)
    labels = imageLabels
    refsFile = layout.buildDirectory.file("image/refs.txt")
}

val pushedImageRefs: Provider<List<String>> = run {
    val keepFloating = providers.gradleProperty("pushConvenienceTags").map { it.toBoolean() }.orElse(true).get()
    val floatingTag = Regex("""^(main|latest|\d+|\d+\.\d+)$""")
    allImageRefs.map { refs -> if (keepFloating) refs else refs.filterNot { floatingTag.matches(it.substringAfterLast(':')) } }
}

val pushLock = gradle.sharedServices.registerIfAbsent("imagePushLock", ImagePushLock::class) {
    maxParallelUsages = 1
}

tasks.register<PushImageTask>("pushImage") {
    group = "container image"
    description = "Pushes every tag of this build (never a local build); -PpushConvenienceTags=false skips main / latest."
    dependsOn(buildImage)
    usesService(pushLock)
    pushAttempts = providers.gradleProperty("image.pushAttempts").map(String::toInt).orElse(3)
    imageRefs = pushedImageRefs
    versionKind = versionKindValue
    allowLocalPush = providers.gradleProperty("image.allowLocalPush").map { it.toBoolean() }.orElse(false)
    engineChoice = engineChoiceProvider
    requireEngine = requireEngineProvider
    digestFile = layout.buildDirectory.file("image/digest.txt")
}

tasks.register<PrintImageRefTask>("printImageRef") {
    group = "container image"
    description = "Prints the primary image reference <registry>/<group>/<AppName>:<tag> (use -q)."
    imageRef = allImageRefs.map { it.first() }
}
