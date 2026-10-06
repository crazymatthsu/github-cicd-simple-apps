package buildlogic

import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters
import java.io.File

/**
 * Serialises every task that drives `test-infra/compose/stack.sh` within one build: a laptop has one set of
 * published localhost ports (local-ports.yml), so two stacks must never be started at the same time.
 */
abstract class ComposeStackLock : BuildService<BuildServiceParameters.None>

/**
 * The KEY=value files `stack.sh up` writes under `test-infra/compose/.state/` (ADR-0025, ADR-0038): the state file
 * `<project>.env` (what `up` recorded: the app image, the actuator port) and `<project>.host.env` (what the project's
 * stacks publish to a test JVM on the host, from their `env` and `local_env` entries in stacks.yml, generated
 * secrets included). The plugin passes the second on to the tests unchanged, without knowing what it holds.
 */
object StackEnv {
    private val key = Regex("[A-Za-z_][A-Za-z0-9_]*")

    /** The variables of [lines]: `#` comments and lines that are not KEY=value are skipped; the last value wins. */
    fun parse(lines: List<String>): Map<String, String> {
        val env = LinkedHashMap<String, String>()
        for (raw in lines) {
            val line = raw.trim()
            val name = line.substringBefore('=', "")
            if (line.startsWith("#") || !key.matches(name)) continue
            env[name] = unquote(line.substringAfter('='))
        }
        return env
    }

    /** [parse] of a file, or nothing when it does not exist. */
    fun read(file: File): Map<String, String> = if (file.isFile) parse(file.readLines()) else emptyMap()

    // The state file is written with bash's %q, which quotes nothing in the values read here; a value in matching
    // quotes loses them.
    private fun unquote(value: String): String =
        if (value.length >= 2 && value.first() == value.last() && value.first() in "'\"") {
            value.substring(1, value.length - 1)
        } else {
            value
        }
}
