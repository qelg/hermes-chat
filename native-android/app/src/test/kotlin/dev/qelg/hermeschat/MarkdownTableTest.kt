package dev.qelg.hermeschat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownTableTest {

    @Test
    fun tableExtractedAsTableBlock() {
        val html = """<p>Alles klar, hier eine einfache Markdown-Tabelle:</p>
<table>
<thead>
<tr><th>Name</th><th>Typ</th><th>Version</th><th>Status</th></tr>
</thead>
<tbody>
<tr><td>nginx</td><td>Webserver</td><td>1.26.3</td><td>\u2705 aktiv</td></tr>
<tr><td>postgresql</td><td>Datenbank</td><td>16.4</td><td>\u2705 aktiv</td></tr>
</tbody>
</table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(2, blocks.size)
        assertTrue("First block should be HTML paragraph", blocks[0] is MarkdownBlock.Html)
        assertTrue("Second block should be Table", blocks[1] is MarkdownBlock.Table)

        val table = blocks[1] as MarkdownBlock.Table
        assertEquals(3, table.rows.size) // header + 2 data rows
        assertEquals(4, table.rows[0].size) // 4 columns
        assertEquals("Name", table.rows[0][0])
        assertEquals("nginx", table.rows[1][0])
        assertTrue("Should contain emoji", table.rows[1][3].contains("\u2705"))
    }

    @Test
    fun emptyTableFallsBackToHtml() {
        val html = """<table>
<tr></tr>
</table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        assertTrue("Empty table should fall back to Html block", blocks[0] is MarkdownBlock.Html)
        assertTrue("Fallback should not be empty", (blocks[0] as MarkdownBlock.Html).content.isNotEmpty())
    }

    @Test
    fun noTablePassesThrough() {
        val html = "<p>Hello world</p>"
        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        assertEquals("Hello world", (blocks[0] as MarkdownBlock.Html).content)
    }

    @Test
    fun tableWithPipeCharacterInCell() {
        val html = """<table>
<thead>
<tr><th>Command</th><th>Description</th></tr>
</thead>
<tbody>
<tr><td>ls | grep foo</td><td>pipe example</td></tr>
</tbody>
</table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(2, table.rows.size) // header + 1 data row
        assertTrue("Should preserve pipe character", table.rows[1][0].contains("|"))
    }

    @Test
    fun singleRowTable() {
        val html = """<table>
<thead>
<tr><th>A</th><th>B</th></tr>
</thead>
<tbody>
<tr><td>1</td><td>2</td></tr>
</tbody>
</table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(2, table.rows.size)
        assertEquals(listOf("A", "B"), table.rows[0])
        assertEquals(listOf("1", "2"), table.rows[1])
    }

    @Test
    fun tableWithEscapedHtmlInCells() {
        val html = """<table>
<thead>
<tr><th>Code</th></tr>
</thead>
<tbody>
<tr><td>&lt;div&gt;hello&lt;/div&gt;</td></tr>
</tbody>
</table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertTrue("Should preserve &lt; entity", table.rows[1][0].contains("&lt;"))
    }

    @Test
    fun compactTableNoWhitespace() {
        val html = "<table><thead><tr><th>X</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>"

        val blocks = extractTableBlocks(html)
        assertEquals(1, blocks.size)
        val table = blocks[0] as MarkdownBlock.Table
        assertEquals(2, table.rows.size)
        assertEquals("X", table.rows[0][0])
        assertEquals("1", table.rows[1][0])
    }

    @Test
    fun mixedContentTableAndParagraphs() {
        val html = """<p>Intro text</p>
<table>
<thead>
<tr><th>Col</th></tr>
</thead>
<tbody>
<tr><td>Val</td></tr>
</tbody>
</table>
<p>Outro text</p>"""

        val blocks = extractTableBlocks(html)
        assertEquals(3, blocks.size) // paragraph, table, paragraph
        assertTrue("First should be Html", blocks[0] is MarkdownBlock.Html)
        assertTrue("Second should be Table", blocks[1] is MarkdownBlock.Table)
        assertTrue("Third should be Html", blocks[2] is MarkdownBlock.Html)

        assertTrue(
            "Intro paragraph preserved",
            (blocks[0] as MarkdownBlock.Html).content.contains("Intro"),
        )
        assertEquals(
            listOf(listOf("Val")),
            (blocks[1] as MarkdownBlock.Table).rows.drop(1), // skip header
        )
        assertTrue(
            "Outro paragraph preserved",
            (blocks[2] as MarkdownBlock.Html).content.contains("Outro"),
        )
    }

    @Test
    fun multipleConsecutiveTables() {
        val html = """<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>
<table><thead><tr><th>B</th></tr></thead><tbody><tr><td>2</td></tr></tbody></table>"""

        val blocks = extractTableBlocks(html)
        assertEquals(2, blocks.size)
        assertTrue("First should be Table", blocks[0] is MarkdownBlock.Table)
        assertTrue("Second should be Table", blocks[1] is MarkdownBlock.Table)
        assertEquals("A", (blocks[0] as MarkdownBlock.Table).rows[0][0])
        assertEquals("B", (blocks[1] as MarkdownBlock.Table).rows[0][0])
    }
}
