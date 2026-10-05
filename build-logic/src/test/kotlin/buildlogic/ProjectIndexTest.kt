package buildlogic

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The reading CI shares with the build (scripts/ci/projects.py, ADR-0031); both must agree on these cases. */
class ProjectIndexTest {
    private val plugin = "buildlogic.docker-image"

    @Test
    fun `a plugin applied in the plugins block counts`() {
        assertTrue(ProjectIndex.applies("plugins {\n    id(\"buildlogic.spring-boot-app\")\n    id(\"$plugin\")\n}\n", plugin))
        assertTrue(ProjectIndex.applies("plugins { id( \"$plugin\" ) }", plugin))
        assertTrue(ProjectIndex.applies("plugins {\n    id(\"$plugin\") // the image (ADR-0009)\n}\n", plugin))
    }

    @Test
    fun `comments, other plugins and look-alikes do not count`() {
        assertFalse(ProjectIndex.applies("plugins {\n    // id(\"$plugin\")\n}\n", plugin))
        assertFalse(ProjectIndex.applies("plugins {\n    /* id(\"$plugin\")\n    */\n}\n", plugin))
        assertFalse(ProjectIndex.applies("plugins {\n    id(\"$plugin-extra\")\n    id(\"buildlogic.docker\")\n}\n", plugin))
        assertFalse(ProjectIndex.applies("plugins {\n    id(\"buildlogic.docker-imageX\")\n}\n", plugin))
        assertFalse(ProjectIndex.applies("plugins {\n    android(\"$plugin\")\n}\n", plugin))
    }
}
