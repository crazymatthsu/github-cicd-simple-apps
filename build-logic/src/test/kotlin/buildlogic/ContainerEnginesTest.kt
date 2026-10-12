package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File
import java.nio.file.Files

class ContainerEnginesTest {
    private fun runner(vararg ok: String): (List<String>) -> CommandResult = { cmd ->
        val line = cmd.joinToString(" ")
        if (ok.any { line.startsWith(it) }) CommandResult(0, "ok")
        else if (line.endsWith("--version")) CommandResult(127, "not found")
        else if (cmd.first() == "podman") CommandResult(125, "Error: unable to connect to Podman socket: connection refused")
        else CommandResult(1, "Client: Docker Engine\nCannot connect to the Docker daemon at unix:///var/run/docker.sock")
    }

    private val both = arrayOf("podman --version", "podman info", "docker --version", "docker info", "docker buildx version")

    @Test
    fun `podman with a service is preferred`() {
        val probe = ContainerEngines.detect("auto", runner(*both))
        assertEquals(EngineProbe.Found(Engine(EngineKind.PODMAN, buildx = false)), probe)
    }

    @Test
    fun `a podman CLI without a service falls back to docker with buildx`() {
        val probe = ContainerEngines.detect("auto", runner("podman --version", "docker --version", "docker info", "docker buildx version"))
        assertEquals(EngineProbe.Found(Engine(EngineKind.DOCKER, buildx = true)), probe)
    }

    @Test
    fun `docker is taken when podman is absent`() {
        val probe = ContainerEngines.detect("", runner("docker --version", "docker info"))
        assertEquals(EngineProbe.Found(Engine(EngineKind.DOCKER, buildx = false)), probe)
    }

    @Test
    fun `a named engine is the only one tried`() {
        assertEquals(EngineProbe.Found(Engine(EngineKind.DOCKER, buildx = true)), ContainerEngines.detect("docker", runner(*both)))
        val probe = ContainerEngines.detect("podman", runner("docker --version", "docker info")) as EngineProbe.Missing
        assertEquals(listOf("podman: CLI not found on the PATH"), probe.reasons)
    }

    @Test
    fun `nothing usable explains why`() {
        val probe = ContainerEngines.detect("auto", runner("podman --version")) as EngineProbe.Missing
        assertEquals(2, probe.reasons.size)
        assertTrue(probe.reasons[0].contains("podman: CLI found but the service is not reachable (Error: unable to connect"), probe.reasons[0])
        assertTrue(probe.reasons[1].contains("docker: CLI not found"), probe.reasons[1])
    }

    @Test
    fun `config-lint renders with podman's compose first`() {
        assertEquals(listOf(listOf("podman", "compose"), listOf("podman-compose"), listOf("docker", "compose"), listOf("docker-compose")),
            ContainerEngines.composeCandidates("auto"))
        assertEquals(listOf(listOf("podman", "compose"), listOf("podman-compose")), ContainerEngines.composeCandidates("podman"))
        assertEquals(listOf(listOf("docker", "compose")), ContainerEngines.composeCandidates("docker"))
        assertEquals(emptyList<List<String>>(), ContainerEngines.composeCandidates("none"))
    }

    @Test
    fun `podman builds keep the docker manifest format`() {
        val cmd = ContainerEngines.buildCommand(Engine(EngineKind.PODMAN, false), File("/ctx"), "Dockerfile",
            listOf("r/a:1", "r/a:sha-1"), mapOf("GIT_SHA" to "x"), mapOf("k" to "v"), listOf("--pull"))
        assertEquals(listOf("podman", "build", "--format", "docker", "--file", "/ctx/Dockerfile",
            "--tag", "r/a:1", "--tag", "r/a:sha-1", "--build-arg", "GIT_SHA=x", "--label", "k=v", "--pull", "/ctx"), cmd)
    }

    @Test
    fun `buildx loads the result into the local image store`() {
        val cmd = ContainerEngines.buildCommand(Engine(EngineKind.DOCKER, true), File("/ctx"), "Dockerfile",
            listOf("r/a:1"), emptyMap(), emptyMap(), emptyList())
        assertEquals(listOf("docker", "buildx", "build", "--load", "--file", "/ctx/Dockerfile", "--tag", "r/a:1", "/ctx"), cmd)
    }

    @Test
    fun `the base image default is read from the Dockerfile`() {
        val file = Files.createTempFile("Dockerfile", "").toFile()
        file.writeText("# c\nARG BASE_IMAGE=ghcr.io/o/base/jre21:latest\nFROM \${BASE_IMAGE}\n")
        assertEquals("ghcr.io/o/base/jre21:latest", ContainerEngines.argDefault(file, "BASE_IMAGE"))
        assertEquals(null, ContainerEngines.argDefault(file, "DEEPHAVEN_IMAGE"))
    }
}
