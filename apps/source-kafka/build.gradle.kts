// source-kafka (ADR-0007): Kafka -> Deephaven / AMPS. Hello world for now: identity, masked configuration
// summary and the actuator contract; no Kafka client yet.
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":connectors-framework"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.bundles.observability)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":connectors-framework")))
    integrationTestImplementation(testFixtures(project(":connectors-framework")))
}
