// `buildlogic.java-conventions` (ADR-0007): every JVM subproject. Java 21 toolchain, the Spring Boot BOM as
// a platform, JUnit Platform, JaCoCo with a low (ratchet-up-only) threshold, reproducible archives, the group of
// platform.yml, and the values of platform.yml that the running app reads as a resource (ADR-0003, ADR-0030, ADR-0042).
import buildlogic.PlatformIdentityTask
import buildlogic.catalogLibrary
import buildlogic.platformList
import buildlogic.platformValue

plugins {
    java
    jacoco
}

group = platformValue("group")

// META-INF/platform/identity.properties: the regions, stages and flows of platform.yml, which ConnectorIdentity checks
// the instance's identity against at start-up (ADR-0003); its property_prefixes, which ConfigurationSummary shows, and
// its secret_properties, which SecretMasker masks (ADR-0042).
val platformIdentity = tasks.register<PlatformIdentityTask>("generatePlatformIdentity") {
    description = "Writes the platform.yml values the app reads into META-INF/platform/identity.properties."
    regions = platformList("regions")
    stages = platformList("stages")
    flows = platformList("flows")
    propertyPrefixes = platformList("propertyPrefixes")
    secretProperties = platformList("secretProperties")
    outputDir = layout.buildDirectory.dir("generated/platform-resources")
}
sourceSets.named("main") { resources.srcDir(platformIdentity) }

java {
    toolchain {
        // The JDK is provided by the ci-build image (CI) or the developer's installation; auto-download is off
        // in gradle.properties (ADR-0007). The vendor is not pinned so that any installed JDK 21 matches; pin it
        // to the runtime base image's vendor (Temurin, ADR-0009) once every build host uses the ci-build image.
        languageVersion = JavaLanguageVersion.of(21)
    }
}

val springBootBom = catalogLibrary("spring-boot-dependencies")

dependencies {
    // Versions of Spring, Jackson, Micrometer, JUnit, the SQL Server driver ... come from the Boot BOM (ADR-0007).
    "implementation"(platform(springBootBom))
    "annotationProcessor"(platform(springBootBom))
    "testImplementation"(catalogLibrary("junit-jupiter"))
    "testRuntimeOnly"(catalogLibrary("junit-platform-launcher"))
}

plugins.withId("java-test-fixtures") {
    dependencies { "testFixturesImplementation"(platform(springBootBom)) }
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-parameters", "-Xlint:all,-processing,-serial"))
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    // Deterministic defaults for tests; the identity and time zone come from the environment at runtime.
    systemProperty("user.timezone", "UTC")
    systemProperty("file.encoding", "UTF-8")
    testLogging {
        events("failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Coverage: a report after every test run and a deliberately low floor that only ever ratchets up (ADR-0007).
tasks.named<Test>("test") { finalizedBy(tasks.named("jacocoTestReport")) }
tasks.named<JacocoReport>("jacocoTestReport") {
    dependsOn(tasks.named("test"))
    reports {
        xml.required = true
        html.required = true
    }
}
tasks.named<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn(tasks.named("test"))
    violationRules {
        rule {
            limit {
                counter = "INSTRUCTION"
                minimum = providers.gradleProperty("coverage.minimum").orElse("0.20").get().toBigDecimal()
            }
        }
    }
}
tasks.named("check") { dependsOn(tasks.named("jacocoTestCoverageVerification")) }

// Reproducible archives (ADR-0007): no timestamps, stable entry order; the version travels in the manifest.
tasks.withType<AbstractArchiveTask>().configureEach {
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}
tasks.withType<Jar>().configureEach {
    manifest {
        attributes(
            "Implementation-Title" to project.name,
            "Implementation-Version" to project.version.toString(),
        )
    }
}
