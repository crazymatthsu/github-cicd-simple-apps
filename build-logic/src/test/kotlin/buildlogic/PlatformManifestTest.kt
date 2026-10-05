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
    """.trimIndent()

    private fun problems(text: String): String = assertThrows<IllegalArgumentException> { PlatformManifest.parse(text) }.message!!

    @Test
    fun `a valid manifest parses into the values the tooling reads`() {
        val manifest = PlatformManifest.parse(valid)
        assertEquals(PlatformManifest("v1", "app", "ghcr.io/acme", "payments-apps", "com.acme.payments", "services",
            listOf("compose"), "ledger-feed", listOf("us-dev", "jp-dev"), listOf("us", "jp"), listOf("dev", "qa", "prod"),
            listOf("cash")), manifest)
        assertEquals(mapOf("registry" to "ghcr.io/acme", "project" to "payments-apps", "group" to "com.acme.payments",
            "appsDir" to "services", "kinds" to "compose", "referenceApp" to "ledger-feed", "devEnvs" to "us-dev,jp-dev",
            "regions" to "us,jp", "stages" to "dev,qa,prod", "flows" to "cash"), manifest.asProperties())
    }

    @Test
    fun `the repository's own platform_yml is valid`() {
        val manifest = PlatformManifest.parse(File("../${PlatformManifest.FILE}").readText())
        // Parsing is the check; the values are this repository's own.
        assertTrue(manifest.project.isNotEmpty() && manifest.referenceApp.isNotEmpty(), manifest.toString())
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
            .replace("reference_app: ledger-feed\n", ""))
        for (expected in listOf(
            "projects[0].name 'Payments_Apps' is not valid",
            "projects[0].group 'com.acme-payments' is not valid",
            "projects[0].apps_dir '/services' is not valid",
            "projects[0].kinds: 'nomad' is not a runtime (compose, helm)",
            "projects[0].kinds: 'compose' is listed twice",
            "projects[0].reference_app is required (a string)",
            "stages: 'pre-prod' is not valid",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
    }

    @Test
    fun `a file that is not a YAML mapping is rejected`() {
        assertTrue(problems("- a\n- b\n").contains("must be a mapping"))
        assertTrue(problems("registry: [unclosed\n").contains("does not parse"))
    }
}
