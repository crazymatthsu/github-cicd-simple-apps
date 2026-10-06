package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.File

class PlatformManifestTest {
    private val valid = """
        platform: v1
        kind: app
        registry: ghcr.io/acme
        projects:
          - name: payments-apps   # = the repository name
            group: com.acme.payments
            apps_dir: services
            kinds: [compose]
            reference_app: ledger-feed
        dev_envs: [us-dev, jp-dev]  # a comment after the list
        regions: [us, jp]
        stages: [dev, qa, prod]
        flows: [cash]
        property_prefixes: [payments, ledger-feed.sink]
        secret_properties: [payments.feed.username, payments.kafka.sasl]  # and every key below them
    """.trimIndent()

    private fun problems(text: String): String = assertThrows<IllegalArgumentException> { PlatformManifest.parse(text) }.message!!

    @Test
    fun `a valid manifest parses into the values the tooling reads`() {
        val manifest = PlatformManifest.parse(valid)
        assertEquals(PlatformManifest("v1", "app", "ghcr.io/acme", "payments-apps", "com.acme.payments", "services",
            listOf("compose"), "ledger-feed", listOf("us-dev", "jp-dev"), listOf("us", "jp"), listOf("dev", "qa", "prod"),
            listOf("cash"), listOf("payments", "ledger-feed.sink"), listOf("payments.feed.username", "payments.kafka.sasl")),
            manifest)
        assertEquals(mapOf("registry" to "ghcr.io/acme", "project" to "payments-apps", "group" to "com.acme.payments",
            "appsDir" to "services", "kinds" to "compose", "referenceApp" to "ledger-feed", "devEnvs" to "us-dev,jp-dev",
            "regions" to "us,jp", "stages" to "dev,qa,prod", "flows" to "cash",
            "propertyPrefixes" to "payments,ledger-feed.sink",
            "secretProperties" to "payments.feed.username,payments.kafka.sasl"), manifest.asProperties())
    }

    @Test
    fun `the property roots and the secret properties are dotted lower-case names on one top-level line`() {
        // ADR-0042: property_prefixes is non-empty, secret_properties may be [] (Spring's names are built in).
        val none = PlatformManifest.parse(valid.replace(Regex("(?m)^secret_properties:.*$"), "secret_properties: []"))
        assertEquals(emptyList<String>(), none.secretProperties)
        assertEquals("", none.asProperties()["secretProperties"])
        val messages = problems(valid
            .replace("property_prefixes: [payments, ledger-feed.sink]", "property_prefixes: []")
            .replace(Regex("(?m)^secret_properties:.*$"),
                "secret_properties: [payments.feed_user, 9lives.token, payments., payments.kafka.sasl, payments.kafka.sasl]"))
        for (expected in listOf(
            "property_prefixes is required (a non-empty list)",
            "secret_properties: 'payments.feed_user' is not valid",
            "secret_properties: '9lives.token' is not valid",
            "secret_properties: 'payments.' is not valid",
            "secret_properties: 'payments.kafka.sasl' is listed twice",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        // Both keys are required, and run-compose.sh reads them without a YAML parser.
        val missing = problems(valid.replace(Regex("(?m)^secret_properties:.*$"), "")
            .replace("property_prefixes: [payments, ledger-feed.sink]", "property_prefixes:\n  - Payments"))
        assertTrue(missing.contains("secret_properties is required (a list)"), missing)
        assertTrue(missing.contains("secret_properties must be a one-line list"), missing)
        assertTrue(missing.contains("property_prefixes: 'Payments' is not valid"), missing)
        assertTrue(missing.contains("property_prefixes must be a one-line list of unquoted words"), missing)
    }

    @Test
    fun `the repository's own platform_yml is valid`() {
        val manifest = PlatformManifest.parse(File("../${PlatformManifest.FILE}").readText())
        // Parsing is the check; the values are this repository's own.
        assertTrue(manifest.project.isNotEmpty(), manifest.toString())
    }

    @Test
    fun `every problem is reported at once`() {
        val messages = problems("""
            platform: v1
            kind: config
            registry: GHCR.io/Acme
            projects:
              - name: Payments_Apps
                group: com.acme-payments
                apps_dir: /services
                kinds: [compose, nomad, compose]
                reference_app: ledger-feed
              - name: second
            dev_envs: [eu-dev, us-qa]
            regions: [us, usa]
            stages: [qa, prod]
            flows:
              - cash
        """.trimIndent())
        for (expected in listOf(
            "kind 'config' is not supported",
            "registry 'GHCR.io/Acme' is not valid",
            "projects must list exactly one project",
            "regions: 'usa' is not valid",
            "stages must include `dev`",
            "dev_envs: 'us-qa' is not valid",
            "dev_envs: 'eu-dev' is not in a region of `regions`",
            "flows must be a one-line list of unquoted words at the top level",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        val quoted = problems(valid.replace("regions: [us, jp]", "regions: [\"us\", \"jp\"]")
            .replace("registry: ghcr.io/acme", "registry: \"ghcr.io/acme\""))
        assertTrue(quoted.contains("regions must be a one-line list of unquoted words"), quoted)
        assertTrue(quoted.contains("registry must be an unquoted value on one top-level line"), quoted)
    }

    @Test
    fun `the project's names, its runtimes and the required keys are checked`() {
        val messages = problems(valid
            .replace("name: payments-apps", "name: Payments_Apps")
            .replace("group: com.acme.payments", "group: com.acme-payments")
            .replace("apps_dir: services", "apps_dir: /services")
            .replace("kinds: [compose]", "kinds: [compose, nomad, compose]")
            .replace("stages: [dev, qa, prod]", "stages: [dev, pre-prod]")
            .replace("reference_app: ledger-feed", "reference_app: Ledger_Feed"))
        for (expected in listOf(
            "projects[0].name 'Payments_Apps' is not valid",
            "projects[0].group 'com.acme-payments' is not valid",
            "projects[0].apps_dir '/services' is not valid",
            "projects[0].kinds: 'nomad' is not a runtime (compose, helm)",
            "projects[0].kinds: 'compose' is listed twice",
            "projects[0].reference_app 'Ledger_Feed' is not valid",
            "stages: 'pre-prod' is not valid",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
    }

    @Test
    fun `a repository may deploy no env and have no reference app yet`() {
        // ADR-0035: dev_envs [] and no reference_app key; the deploy and the reference scenario are switched off.
        val manifest = PlatformManifest.parse(valid
            .replace("dev_envs: [us-dev, jp-dev]  # a comment after the list", "dev_envs: []  # none yet")
            .replace("    reference_app: ledger-feed\n", ""))
        assertEquals(emptyList<String>(), manifest.devEnvs)
        assertEquals("", manifest.referenceApp)
        assertEquals("", manifest.asProperties()["devEnvs"])
        assertEquals("", manifest.asProperties()["referenceApp"])
        assertEquals(null, manifest.referenceAppProblem(mapOf("ledger-feed" to "services", "lib" to "framework")))
        // The key itself stays required, and the other lists stay non-empty.
        val missing = problems(valid.replace("dev_envs: [us-dev, jp-dev]  # a comment after the list", "")
            .replace("flows: [cash]", "flows: []"))
        assertTrue(missing.contains("dev_envs is required (a list)"), missing)
        assertTrue(missing.contains("dev_envs must be a one-line list"), missing)
        assertTrue(missing.contains("flows is required (a non-empty list)"), missing)
    }

    @Test
    fun `a reference_app that is present must name an app`() {
        val empty = problems(valid.replace("reference_app: ledger-feed", "reference_app:"))
        assertTrue(empty.contains("projects[0].reference_app is required (a string)"), empty)
        val manifest = PlatformManifest.parse(valid)
        assertEquals(null, manifest.referenceAppProblem(mapOf("ledger-feed" to "services", "lib" to "framework")))
        assertEquals("platform.yml: reference_app 'ledger-feed' is not an app under services/ (ADR-0030)",
            manifest.referenceAppProblem(mapOf("ledger" to "services")))
        // A library is not an app (ADR-0006).
        assertEquals("platform.yml: reference_app 'ledger-feed' is not an app under services/ (ADR-0030)",
            manifest.referenceAppProblem(mapOf("ledger-feed" to "framework")))
    }

    @Test
    fun `a file that is not a YAML mapping is rejected`() {
        assertTrue(problems("- a\n- b\n").contains("must be a mapping"))
        assertTrue(problems("registry: [unclosed\n").contains("does not parse"))
    }
}
