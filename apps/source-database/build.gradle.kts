// source-database (ADR-0007): JDBC (SQL Server) -> AMPS / Deephaven. Hello world for now: identity, masked
// configuration summary, the actuator contract and one start-up query (SELECT 1, SELECT COUNT(*) FROM
// connector.source.table) with credentials bound only from the environment or /secrets/ (ADR-0013).
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":connectors-framework"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.spring.boot.starter.jdbc)
    implementation(libs.bundles.observability)
    runtimeOnly(libs.mssql.jdbc)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":connectors-framework")))
    integrationTestImplementation(testFixtures(project(":connectors-framework")))
}
