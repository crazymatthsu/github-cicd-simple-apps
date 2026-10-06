package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.io.File
import java.nio.file.Files

/** The files stack.sh up writes for the test JVM (ADR-0038), read the way the integration-test plugin reads them. */
class StackEnvTest {
    @Test
    fun `KEY=value lines in order, comments and blank lines skipped`() {
        val env = StackEnv.parse(listOf(
            "# Written by stack.sh up: the env entries of the stacks (stacks.yml) with local_env, for a JVM on the host.",
            "IT_DEEPHAVEN_HOST=localhost",
            "",
            "IT_SA_PASSWORD=It-0f1e-Aa1",
            "SPRING_DATASOURCE_PASSWORD=It-0f1e-Aa1",
        ))
        assertEquals(listOf("IT_DEEPHAVEN_HOST", "IT_SA_PASSWORD", "SPRING_DATASOURCE_PASSWORD"), env.keys.toList())
        assertEquals("It-0f1e-Aa1", env["SPRING_DATASOURCE_PASSWORD"])
    }

    @Test
    fun `a value keeps its own equals signs and loses matching quotes, the last line of a key wins`() {
        val env = StackEnv.parse(listOf("URL=jdbc:x://h;a=b", "Q='quoted'", "D=\"double\"", "HALF='x", "P=1", "P=2"))
        assertEquals(mapOf("URL" to "jdbc:x://h;a=b", "Q" to "quoted", "D" to "double", "HALF" to "'x", "P" to "2"), env)
    }

    @Test
    fun `lines that are not KEY=value are ignored`() {
        val env = StackEnv.parse(listOf("=x", "1A=x", "A B=x", "just text", "  # indented comment", "EMPTY="))
        assertEquals(mapOf("EMPTY" to ""), env)
    }

    @Test
    fun `a missing file is empty, an existing one is parsed`() {
        assertEquals(emptyMap<String, String>(), StackEnv.read(File("/nonexistent/stack-env-test.host.env")))
        val file = Files.createTempFile("local-app", ".host.env").toFile()
        file.writeText("# header\nIT_KAFKA_HOST=localhost\nIT_KAFKA_PORT=9092\n")
        assertEquals(mapOf("IT_KAFKA_HOST" to "localhost", "IT_KAFKA_PORT" to "9092"), StackEnv.read(file))
        file.delete()
    }
}
