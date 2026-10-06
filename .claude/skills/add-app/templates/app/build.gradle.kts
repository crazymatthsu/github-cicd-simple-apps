// __APP_NAME__ (ADR-0007): __APP_SUMMARY__. Built on the runtime module: identity, the masked configuration summary and
// the actuator contract (ADR-0015, ADR-0016).
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    // Only with integration tests (src/integrationTest/java and a stack in test-infra/compose/stacks.yml, ADR-0025):
    // id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":app-runtime"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.bundles.observability)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":app-runtime")))
}
