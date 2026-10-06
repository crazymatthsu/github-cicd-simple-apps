// source-database (ADR-0007): JDBC (SQL Server) -> AMPS / Deephaven. Hello world for now: identity, masked
// configuration summary, the actuator contract and one start-up query (SELECT 1, SELECT COUNT(*) FROM
// connector.source.table) with credentials bound only from the environment or /secrets/ (ADR-0013).
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":app-runtime"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.spring.boot.starter.jdbc)
    implementation(libs.bundles.observability)
    runtimeOnly(libs.mssql.jdbc)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":app-runtime")))
    integrationTestImplementation(testFixtures(project(":app-runtime")))
    // The tests assert through the Deephaven Java client: a Flight session uploads, snapshots and releases (ADR-0038).
    integrationTestImplementation(libs.deephaven.java.client.flight.dagger)
}

// Arrow, under the Deephaven Flight client, reads direct buffers reflectively: JDK 16+ needs java.nio opened, or
// MemoryUtil fails to initialise (ADR-0038).
tasks.named<Test>("integrationTest") {
    jvmArgs("--add-opens=java.base/java.nio=ALL-UNNAMED")
}
